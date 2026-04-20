// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation
import Observation

/// Outcome of a single link-preview fetch. `.loading` is visible in the UI
/// as a spinner; `.failed` is indistinguishable from a URL with no preview
/// (the view renders nothing).
public enum LinkPreviewStatus: Sendable, Equatable {
	case loading
	case loaded
	case failed
}

/// A single inline link preview for a URL found in message scrollback.
public struct LinkPreview: Identifiable, Sendable, Equatable {
	public var id: URL {
		url
	}

	public let url: URL
	public var status: LinkPreviewStatus
	public var title: String?
	public var siteName: String?
	public var summary: String?
	public var imageURL: URL?
	/// True when the URL itself pointed at an image (`image/*` Content-Type).
	public var isDirectImage: Bool

	public init(
		url: URL,
		status: LinkPreviewStatus = .loading,
		title: String? = nil,
		siteName: String? = nil,
		summary: String? = nil,
		imageURL: URL? = nil,
		isDirectImage: Bool = false,
	) {
		self.url = url
		self.status = status
		self.title = title
		self.siteName = siteName
		self.summary = summary
		self.imageURL = imageURL
		self.isDirectImage = isDirectImage
	}
}

/// In-memory link-preview cache + fetcher. Shared across views so the same
/// URL appearing in multiple channels is only fetched once per launch.
///
/// Reads are capped at 2 MB and timed out at 10 s; only http and https
/// schemes are followed. HTML parsing is regex-based — we only need the
/// first `<title>` and a handful of `og:*` / `twitter:*` meta tags.
@MainActor
@Observable
public final class LinkPreviewStore {
	public private(set) var cache: [URL: LinkPreview] = [:]
	private var inFlight: Set<URL> = []

	private let maxBytes = 2 * 1024 * 1024
	private let htmlBytes = 256 * 1024
	private let timeout: TimeInterval = 10

	public init() {}

	/// Look up a cached preview. `nil` means "not fetched yet".
	public func preview(for url: URL) -> LinkPreview? {
		cache[url]
	}

	/// Begin fetching the preview if it isn't already cached or in flight.
	public func fetchIfNeeded(_ url: URL) {
		guard cache[url] == nil, !inFlight.contains(url) else { return }
		guard let scheme = url.scheme?.lowercased(),
		      scheme == "http" || scheme == "https" else { return }

		inFlight.insert(url)
		cache[url] = LinkPreview(url: url, status: .loading)

		Task {
			let result = await Self.fetchPreview(
				for: url,
				maxBytes: maxBytes,
				htmlBytes: htmlBytes,
				timeout: timeout,
			)
			self.inFlight.remove(url)
			self.cache[url] = result ?? LinkPreview(url: url, status: .failed)
		}
	}

	// MARK: - Network

	private static func fetchPreview(
		for url: URL,
		maxBytes: Int,
		htmlBytes: Int,
		timeout: TimeInterval,
	) async -> LinkPreview? {
		var request = URLRequest(url: url, timeoutInterval: timeout)
		request.setValue("Brygga/0.1 (macOS IRC client)", forHTTPHeaderField: "User-Agent")
		request.setValue("en", forHTTPHeaderField: "Accept-Language")

		let session = URLSession(configuration: .ephemeral)
		defer { session.invalidateAndCancel() }

		guard let (data, response) = try? await session.data(for: request),
		      let http = response as? HTTPURLResponse,
		      (200 ..< 400).contains(http.statusCode)
		else {
			return LinkPreview(url: url, status: .failed)
		}

		let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
			.lowercased()

		if contentType.hasPrefix("image/") {
			guard data.count <= maxBytes else {
				return LinkPreview(url: url, status: .failed)
			}
			return LinkPreview(
				url: url,
				status: .loaded,
				imageURL: url,
				isDirectImage: true,
			)
		}

		guard contentType.contains("text/html") || contentType.contains("application/xhtml") else {
			return LinkPreview(url: url, status: .failed)
		}

		// Truncate large HTML bodies before scanning — the tags we need are
		// virtually always in the first 256 KB.
		let bounded = data.prefix(htmlBytes)
		let html = decodeHTML(Data(bounded), contentType: contentType)

		let title = extractTitle(from: html)
		let ogTitle = extractMeta(property: "og:title", from: html) ?? extractMeta(name: "twitter:title", from: html)
		let ogDesc = extractMeta(property: "og:description", from: html) ?? extractMeta(name: "description", from: html)
		let ogSite = extractMeta(property: "og:site_name", from: html)
		let ogImage = extractMeta(property: "og:image", from: html) ?? extractMeta(name: "twitter:image", from: html)

		let resolvedImage: URL? = ogImage.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }

		let finalTitle = ogTitle ?? title
		if finalTitle == nil, ogDesc == nil, resolvedImage == nil {
			return LinkPreview(url: url, status: .failed)
		}
		return LinkPreview(
			url: url,
			status: .loaded,
			title: finalTitle?.decodingHTMLEntities().trimmingWhitespace(),
			siteName: ogSite?.decodingHTMLEntities().trimmingWhitespace(),
			summary: ogDesc?.decodingHTMLEntities().trimmingWhitespace(),
			imageURL: resolvedImage,
			isDirectImage: false,
		)
	}

	private static func decodeHTML(_ data: Data, contentType: String) -> String {
		// charset=… hint; fall back to UTF-8 and then ISO-8859-1 (latin1, which
		// never fails and matches what most old sites actually send).
		if let charsetRange = contentType.range(of: "charset=") {
			let rest = contentType[charsetRange.upperBound...]
			let name = rest.prefix { $0 != ";" && !$0.isWhitespace }
			if name.lowercased() != "utf-8", let encoding = stringEncoding(fromIANA: String(name)) {
				if let s = String(data: data, encoding: encoding) { return s }
			}
		}
		if let s = String(data: data, encoding: .utf8) { return s }
		return String(data: data, encoding: .isoLatin1) ?? ""
	}

	private static func stringEncoding(fromIANA name: String) -> String.Encoding? {
		let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
		if cfEncoding == kCFStringEncodingInvalidId { return nil }
		return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
	}

	// MARK: - Parsing helpers

	private static func extractTitle(from html: String) -> String? {
		firstMatch(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>")
	}

	private static func extractMeta(property: String, from html: String) -> String? {
		let escaped = NSRegularExpression.escapedPattern(for: property)
		// Handle both attribute orderings (property first vs content first).
		if let v = firstMatch(
			in: html,
			pattern: "<meta[^>]+property=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']*)[\"'][^>]*>",
		) { return v }
		return firstMatch(
			in: html,
			pattern: "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']\(escaped)[\"'][^>]*>",
		)
	}

	private static func extractMeta(name: String, from html: String) -> String? {
		let escaped = NSRegularExpression.escapedPattern(for: name)
		if let v = firstMatch(
			in: html,
			pattern: "<meta[^>]+name=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']*)[\"'][^>]*>",
		) { return v }
		return firstMatch(
			in: html,
			pattern: "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+name=[\"']\(escaped)[\"'][^>]*>",
		)
	}

	private static func firstMatch(in string: String, pattern: String) -> String? {
		guard let regex = try? NSRegularExpression(
			pattern: pattern,
			options: [.caseInsensitive, .dotMatchesLineSeparators],
		) else { return nil }
		let range = NSRange(string.startIndex..., in: string)
		guard let match = regex.firstMatch(in: string, range: range),
		      match.numberOfRanges >= 2,
		      let group = Range(match.range(at: 1), in: string) else { return nil }
		return String(string[group])
	}
}

// MARK: - String helpers

private extension String {
	func decodingHTMLEntities() -> String {
		// Minimal HTML entity decoder for the handful that commonly appear in
		// `<title>` and `og:*` text. `NSAttributedString`'s HTML importer is
		// heavier and must run on the main actor.
		let replacements: [(String, String)] = [
			("&amp;", "&"),
			("&lt;", "<"),
			("&gt;", ">"),
			("&quot;", "\""),
			("&#39;", "'"),
			("&apos;", "'"),
			("&nbsp;", " "),
			("&#x27;", "'"),
		]
		var out = self
		for (from, to) in replacements {
			out = out.replacingOccurrences(of: from, with: to)
		}
		return out
	}

	func trimmingWhitespace() -> String {
		trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
