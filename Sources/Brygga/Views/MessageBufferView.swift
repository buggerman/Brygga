// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import AppKit
import BryggaCore
import SwiftUI

/// Non-editable message buffer backed by `NSTextView`, giving the chat
/// view native macOS drag-select across rows, ⌘A, ⌘C, Find, and a right-click
/// menu. Replaces the SwiftUI `LazyVStack { MessageRow }` rendering that
/// could only select text within a single message due to SwiftUI's
/// per-`Text` selection limit.
///
/// Feed the view a `[Message]` plus a few presentation options. On append
/// it scrolls to the bottom if the user was already pinned there (mIRC
/// behaviour); otherwise it leaves the scroll position alone so the user
/// can read history without being snatched back to live.
@MainActor
struct MessageBufferView: NSViewRepresentable {
	let messages: [Message]
	let lastReadMessageID: UUID?
	let nickColorsEnabled: Bool
	let timestampFormat: String
	let linkPreviewsEnabled: Bool
	let linkPreviews: LinkPreviewStore?
	let collapsePresenceRuns: Bool

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSScrollView {
		let textView = NSTextView(frame: .zero)
		textView.isEditable = false
		textView.isSelectable = true
		textView.isRichText = true
		textView.drawsBackground = false
		textView.allowsUndo = false
		textView.isAutomaticLinkDetectionEnabled = false
		textView.isAutomaticDataDetectionEnabled = false
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticTextReplacementEnabled = false
		textView.isAutomaticSpellingCorrectionEnabled = false
		textView.isAutomaticTextCompletionEnabled = false
		textView.usesFontPanel = false
		textView.usesFindBar = true
		textView.isIncrementalSearchingEnabled = true
		textView.textContainerInset = NSSize(width: 12, height: 12)
		textView.textContainer?.lineFragmentPadding = 0
		textView.textContainer?.widthTracksTextView = true
		textView.autoresizingMask = [.width]
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.linkTextAttributes = [
			.foregroundColor: NSColor.controlAccentColor,
			.underlineStyle: NSUnderlineStyle.single.rawValue,
			.cursor: NSCursor.pointingHand,
		]
		textView.delegate = context.coordinator

		let scroll = NSScrollView(frame: .zero)
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = false
		scroll.drawsBackground = false
		scroll.documentView = textView
		scroll.contentView.postsBoundsChangedNotifications = true

		context.coordinator.textView = textView
		context.coordinator.scrollView = scroll
		return scroll
	}

	func updateNSView(_: NSScrollView, context: Context) {
		context.coordinator.apply(
			messages: messages,
			lastReadMessageID: lastReadMessageID,
			nickColorsEnabled: nickColorsEnabled,
			timestampFormat: timestampFormat,
			linkPreviewsEnabled: linkPreviewsEnabled,
			linkPreviews: linkPreviews,
			collapsePresenceRuns: collapsePresenceRuns,
		)
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		weak var textView: NSTextView?
		weak var scrollView: NSScrollView?

		private var renderedIDs: [UUID] = []
		private var renderedLastReadID: UUID?
		private var messagesByID: [UUID: Message] = [:]
		private var nickColorsEnabled = true
		private var timestampFormat = "system"
		private var linkPreviewsEnabled = true
		private var collapsePresenceRuns = false
		private weak var linkPreviewStore: LinkPreviewStore?
		/// IDs of presence runs that the user has explicitly expanded in
		/// the buffer. A run's id is the id of its first message (see
		/// `foldPresenceRuns`), so this set survives appends that merely
		/// extend an existing run.
		private var expandedRunIDs: Set<UUID> = []

		/// Cached decoded image bytes, keyed by the `imageURL` of the
		/// preview they illustrate. Images fetched once per Coordinator
		/// lifetime; when the view goes off-screen and back, the cache is
		/// reused until the Coordinator itself is torn down.
		private var images: [URL: NSImage] = [:]
		private var inFlightImages: Set<URL> = []

		/// The most-recent `apply` inputs, kept so the Coordinator can
		/// re-render itself when an image fetch completes or the link
		/// preview store mutates — neither of which routes through
		/// SwiftUI's `updateNSView`.
		private var lastApply: ApplyArgs?
		private var hasSubscribedToStore = false

		private let urlDetector = try? NSDataDetector(
			types: NSTextCheckingResult.CheckingType.link.rawValue,
		)

		private struct ApplyArgs {
			let messages: [Message]
			let lastReadMessageID: UUID?
			let nickColorsEnabled: Bool
			let timestampFormat: String
			let linkPreviewsEnabled: Bool
			let collapsePresenceRuns: Bool
		}

		func apply(
			messages: [Message],
			lastReadMessageID: UUID?,
			nickColorsEnabled: Bool,
			timestampFormat: String,
			linkPreviewsEnabled: Bool,
			linkPreviews: LinkPreviewStore?,
			collapsePresenceRuns: Bool,
		) {
			linkPreviewStore = linkPreviews
			lastApply = ApplyArgs(
				messages: messages,
				lastReadMessageID: lastReadMessageID,
				nickColorsEnabled: nickColorsEnabled,
				timestampFormat: timestampFormat,
				linkPreviewsEnabled: linkPreviewsEnabled,
				collapsePresenceRuns: collapsePresenceRuns,
			)
			render()
			if linkPreviews != nil, linkPreviewsEnabled, !hasSubscribedToStore {
				hasSubscribedToStore = true
				subscribeToPreviewStore()
			}
			kickOffPreviewFetches(for: messages, enabled: linkPreviewsEnabled)
		}

		private func render() {
			guard
				let args = lastApply,
				let textView,
				let storage = textView.textStorage
			else { return }

			let optionsChanged = args.nickColorsEnabled != nickColorsEnabled
				|| args.timestampFormat != timestampFormat
				|| args.lastReadMessageID != renderedLastReadID
				|| args.linkPreviewsEnabled != linkPreviewsEnabled
				|| args.collapsePresenceRuns != collapsePresenceRuns
			nickColorsEnabled = args.nickColorsEnabled
			timestampFormat = args.timestampFormat
			linkPreviewsEnabled = args.linkPreviewsEnabled
			collapsePresenceRuns = args.collapsePresenceRuns

			let newIDs = args.messages.map(\.id)
			// In collapse mode, appending a single message can change the
			// shape of a pre-existing run at the tail (e.g. extending it or
			// closing it), so skip the append fast-path and always rebuild.
			let canAppend = !optionsChanged
				&& !args.collapsePresenceRuns
				&& newIDs.starts(with: renderedIDs)
				&& newIDs.count > renderedIDs.count

			let wasAtBottom = isScrolledToBottom()

			if canAppend {
				let tail = Array(args.messages.suffix(args.messages.count - renderedIDs.count))
				let appendText = NSMutableAttributedString()
				for message in tail {
					appendText.append(attributed(for: message, lastReadID: args.lastReadMessageID))
				}
				storage.append(appendText)
			} else {
				let full = NSMutableAttributedString()
				if args.collapsePresenceRuns {
					for entry in foldPresenceRuns(args.messages) {
						full.append(attributed(forEntry: entry, lastReadID: args.lastReadMessageID))
					}
				} else {
					for message in args.messages {
						full.append(attributed(for: message, lastReadID: args.lastReadMessageID))
					}
				}
				storage.setAttributedString(full)
			}

			messagesByID = Dictionary(uniqueKeysWithValues: args.messages.map { ($0.id, $0) })
			renderedIDs = newIDs
			renderedLastReadID = args.lastReadMessageID

			if wasAtBottom || !canAppend {
				scrollToBottom()
			}
		}

		// MARK: - Entry rendering (collapse mode)

		private func attributed(forEntry entry: ChatEntry, lastReadID: UUID?) -> NSAttributedString {
			switch entry {
			case let .message(m):
				attributed(for: m, lastReadID: lastReadID)
			case let .presenceRun(id, messages):
				attributedForRun(id: id, messages: messages, lastReadID: lastReadID)
			}
		}

		private func attributedForRun(
			id: UUID,
			messages: [Message],
			lastReadID: UUID?,
		) -> NSAttributedString {
			let out = NSMutableAttributedString()
			let expanded = expandedRunIDs.contains(id)
			let isCollapsible = messages.count > 1

			out.append(summaryLine(
				runID: id,
				messages: messages,
				expanded: expanded,
				showTriangle: isCollapsible,
			))

			if expanded, isCollapsible {
				for message in messages {
					out.append(attributed(for: message, lastReadID: nil))
				}
			}

			// The "new" divider applies to whichever original message carries
			// lastReadID — if that message lives inside this run, drop the
			// divider after the whole run so read/unread stays separated.
			if let lastReadID, messages.contains(where: { $0.id == lastReadID }) {
				out.append(lineMarker())
			}

			return out
		}

		private func summaryLine(
			runID: UUID,
			messages: [Message],
			expanded: Bool,
			showTriangle: Bool,
		) -> NSAttributedString {
			let font = NSFont.monospacedSystemFont(
				ofSize: NSFont.systemFontSize,
				weight: .regular,
			)
			let tsFont = NSFont.monospacedSystemFont(
				ofSize: NSFont.smallSystemFontSize,
				weight: .regular,
			)

			let out = NSMutableAttributedString()

			// Empty timestamp column so the summary aligns with message rows.
			out.append(NSAttributedString(string: "        ", attributes: [
				.font: tsFont,
				.foregroundColor: NSColor.secondaryLabelColor,
			]))

			if showTriangle {
				let triangle = expanded ? "▾ " : "▸ "
				var triAttrs: [NSAttributedString.Key: Any] = [
					.font: font,
					.foregroundColor: NSColor.tertiaryLabelColor,
				]
				if let url = URL(string: "brygga-toggle-run://\(runID.uuidString)") {
					triAttrs[.link] = url
				}
				out.append(NSAttributedString(string: triangle, attributes: triAttrs))
			} else {
				// Preserve alignment with collapsible rows.
				out.append(NSAttributedString(string: "  ", attributes: [
					.font: font,
				]))
			}

			let summary = presenceRunSummary(messages)
			out.append(NSAttributedString(string: summary + "\n", attributes: [
				.font: font,
				.foregroundColor: NSColor.secondaryLabelColor,
			]))

			out.addAttribute(
				.bryggaMessageID,
				value: runID,
				range: NSRange(location: 0, length: out.length),
			)
			return out
		}

		/// Rebuild the buffer using the last inputs. Used by async callbacks —
		/// image fetch completions and link-preview store observations — that
		/// don't route through SwiftUI's update cycle.
		private func reapply() {
			guard lastApply != nil else { return }
			// Force a full rebuild even when the message list hasn't grown —
			// the preview attachments may have changed.
			renderedIDs = []
			render()
		}

		private func subscribeToPreviewStore() {
			guard let store = linkPreviewStore else { return }
			withObservationTracking {
				_ = store.cache
			} onChange: { [weak self] in
				Task { @MainActor [weak self] in
					guard let self else { return }
					reapply()
					subscribeToPreviewStore()
				}
			}
		}

		private func kickOffPreviewFetches(for messages: [Message], enabled: Bool) {
			guard enabled, let store = linkPreviewStore else { return }
			for message in messages {
				guard let url = firstPreviewableURL(in: message.content) else { continue }
				store.fetchIfNeeded(url)
			}
		}

		// MARK: - Attributed building

		private func attributed(for message: Message, lastReadID: UUID?) -> NSAttributedString {
			let out = NSMutableAttributedString()
			let ts = timestampText(for: message.timestamp)
			let bodyFont = NSFont.monospacedSystemFont(
				ofSize: NSFont.systemFontSize,
				weight: .regular,
			)
			let tsFont = NSFont.monospacedSystemFont(
				ofSize: NSFont.smallSystemFontSize,
				weight: .regular,
			)

			out.append(.init(string: "[\(ts)]  ", attributes: [
				.font: tsFont,
				.foregroundColor: NSColor.secondaryLabelColor,
			]))

			switch message.kind {
			case .privmsg:
				out.append(.init(string: "<\(message.sender)> ", attributes: [
					.font: bodyFont,
					.foregroundColor: nickColor(for: message.sender),
				]))
				out.append(ircAttributed(
					message.content,
					baseFont: bodyFont,
					baseColor: NSColor.labelColor,
				))

			case .notice:
				out.append(.init(string: "-\(message.sender)- ", attributes: [
					.font: bodyFont,
					.foregroundColor: NSColor.systemOrange,
				]))
				out.append(ircAttributed(
					message.content,
					baseFont: bodyFont,
					baseColor: NSColor.systemOrange,
				))

			case .action:
				out.append(.init(string: "* ", attributes: [
					.font: bodyFont,
					.foregroundColor: NSColor.secondaryLabelColor,
				]))
				let italicBody = italicVariant(of: bodyFont)
				out.append(.init(string: "\(message.sender) ", attributes: [
					.font: italicBody,
					.foregroundColor: nickColor(for: message.sender),
				]))
				out.append(ircAttributed(
					message.content,
					baseFont: italicBody,
					baseColor: NSColor.labelColor,
				))

			default:
				out.append(.init(string: "* \(message.sender) \(message.content)", attributes: [
					.font: bodyFont,
					.foregroundColor: NSColor.secondaryLabelColor,
				]))
			}

			out.append(.init(string: "\n"))

			if let previewParagraph = linkPreviewAttachment(for: message) {
				out.append(previewParagraph)
			}

			let fullRange = NSRange(location: 0, length: out.length)
			out.addAttribute(.bryggaMessageID, value: message.id, range: fullRange)

			if message.isHighlight {
				out.addAttribute(
					.backgroundColor,
					value: NSColor.controlAccentColor.withAlphaComponent(0.15),
					range: fullRange,
				)
			}

			// The "new" divider sits *after* the last-read message so it
			// visually separates read from unread.
			if let lastReadID, message.id == lastReadID {
				out.append(lineMarker())
			}

			return out
		}

		private func linkPreviewAttachment(for message: Message) -> NSAttributedString? {
			guard
				linkPreviewsEnabled,
				let store = linkPreviewStore,
				let url = firstPreviewableURL(in: message.content),
				let preview = store.preview(for: url),
				preview.status == .loaded
			else { return nil }

			let image = loadedImage(for: preview)
			let cell = LinkPreviewAttachmentCell(preview: preview, image: image)
			let attachment = NSTextAttachment()
			attachment.attachmentCell = cell

			let attachmentString = NSMutableAttributedString(attachment: attachment)

			let para = NSMutableParagraphStyle()
			para.firstLineHeadIndent = 68
			para.headIndent = 68
			para.paragraphSpacing = 4
			para.paragraphSpacingBefore = 2

			let paragraph = NSMutableAttributedString()
			paragraph.append(attachmentString)
			paragraph.append(NSAttributedString(string: "\n"))
			paragraph.addAttribute(
				.paragraphStyle,
				value: para,
				range: NSRange(location: 0, length: paragraph.length),
			)
			// Clicking the attachment follows the URL.
			paragraph.addAttribute(
				.link,
				value: url,
				range: NSRange(location: 0, length: attachmentString.length),
			)
			return paragraph
		}

		/// Return the cached `NSImage` for the preview if any. If the preview
		/// points at an image URL and we haven't fetched it yet, kick off the
		/// fetch and return `nil` — the Coordinator will reapply once the
		/// image lands.
		private func loadedImage(for preview: LinkPreview) -> NSImage? {
			let imageURL = preview.imageURL ?? (preview.isDirectImage ? preview.url : nil)
			guard let imageURL else { return nil }
			if let cached = images[imageURL] { return cached }
			fetchImage(imageURL)
			return nil
		}

		private func fetchImage(_ url: URL) {
			guard images[url] == nil, !inFlightImages.contains(url) else { return }
			guard let scheme = url.scheme?.lowercased(),
			      scheme == "http" || scheme == "https" else { return }
			inFlightImages.insert(url)

			Task { [weak self] in
				let data = await Self.downloadImageBytes(for: url)
				await MainActor.run {
					guard let self else { return }
					self.inFlightImages.remove(url)
					if let data, let image = NSImage(data: data) {
						self.images[url] = image
						self.reapply()
					}
				}
			}
		}

		private static func downloadImageBytes(for url: URL) async -> Data? {
			var request = URLRequest(url: url, timeoutInterval: 10)
			request.setValue("Brygga/0.1 (macOS IRC client)", forHTTPHeaderField: "User-Agent")
			let session = URLSession(configuration: .ephemeral)
			defer { session.invalidateAndCancel() }
			guard let (data, response) = try? await session.data(for: request),
			      let http = response as? HTTPURLResponse,
			      (200 ..< 400).contains(http.statusCode),
			      data.count <= 2 * 1024 * 1024
			else { return nil }
			return data
		}

		private func firstPreviewableURL(in text: String) -> URL? {
			guard let detector = urlDetector, !text.isEmpty else { return nil }
			let range = NSRange(text.startIndex..., in: text)
			var found: URL?
			detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
				guard let url = match?.url, let scheme = url.scheme?.lowercased() else { return }
				if scheme == "http" || scheme == "https" {
					found = url
					stop.pointee = true
				}
			}
			return found
		}

		private func ircAttributed(
			_ text: String,
			baseFont: NSFont,
			baseColor: NSColor,
		) -> NSAttributedString {
			let runs = IRCFormatting.parse(text)
			let out = NSMutableAttributedString()
			for run in runs {
				var font = baseFont
				if run.style.bold {
					font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
				}
				if run.style.italic {
					font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
				}
				var attrs: [NSAttributedString.Key: Any] = [
					.font: font,
					.foregroundColor: baseColor,
				]
				if run.style.underline {
					attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
				}
				if run.style.strikethrough {
					attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
				}
				var fgIdx = run.style.foreground
				var bgIdx = run.style.background
				if run.style.reverse {
					(fgIdx, bgIdx) = (bgIdx ?? 0, fgIdx ?? 99)
				}
				if let fg = fgIdx, let rgb = IRCFormatting.color(for: fg) {
					attrs[.foregroundColor] = NSColor(
						srgbRed: CGFloat(rgb.red),
						green: CGFloat(rgb.green),
						blue: CGFloat(rgb.blue),
						alpha: 1.0,
					)
				}
				if let bg = bgIdx, let rgb = IRCFormatting.color(for: bg) {
					attrs[.backgroundColor] = NSColor(
						srgbRed: CGFloat(rgb.red),
						green: CGFloat(rgb.green),
						blue: CGFloat(rgb.blue),
						alpha: 1.0,
					)
				}
				out.append(NSAttributedString(string: run.text, attributes: attrs))
			}
			detectLinks(in: out)
			return out
		}

		private func detectLinks(in attributed: NSMutableAttributedString) {
			guard let detector = urlDetector else { return }
			let plain = attributed.string
			let range = NSRange(plain.startIndex..., in: plain)
			detector.enumerateMatches(in: plain, options: [], range: range) { match, _, _ in
				guard let match, let url = match.url else { return }
				let scheme = url.scheme?.lowercased()
				guard scheme == "http" || scheme == "https" || scheme == "mailto" else { return }
				attributed.addAttribute(.link, value: url, range: match.range)
			}
		}

		private func lineMarker() -> NSAttributedString {
			let para = NSMutableParagraphStyle()
			para.alignment = .center
			para.paragraphSpacing = 2
			para.paragraphSpacingBefore = 2
			return NSAttributedString(string: "── new ──\n", attributes: [
				.font: NSFont.systemFont(ofSize: 10, weight: .medium),
				.foregroundColor: NSColor.controlAccentColor,
				.paragraphStyle: para,
			])
		}

		private func italicVariant(of font: NSFont) -> NSFont {
			NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
		}

		private func nickColor(for nick: String) -> NSColor {
			if !nickColorsEnabled { return NSColor.controlAccentColor }
			return NSColor(NickColor.color(for: nick))
		}

		private func timestampText(for date: Date) -> String {
			switch timestampFormat {
			case "12h":
				let f = DateFormatter()
				f.dateFormat = "h:mm a"
				f.locale = Locale(identifier: "en_US_POSIX")
				return f.string(from: date)
			case "24h":
				let f = DateFormatter()
				f.dateFormat = "HH:mm"
				f.locale = Locale(identifier: "en_US_POSIX")
				return f.string(from: date)
			default:
				return date.formatted(date: .omitted, time: .shortened)
			}
		}

		// MARK: - Scroll

		private func isScrolledToBottom() -> Bool {
			guard let scrollView, let doc = scrollView.documentView else { return true }
			let visible = scrollView.contentView.documentVisibleRect
			let threshold: CGFloat = 40
			return visible.maxY >= doc.frame.height - threshold
		}

		private func scrollToBottom() {
			guard let textView, let scrollView else { return }
			if let container = textView.textContainer {
				textView.layoutManager?.ensureLayout(for: container)
			}
			let docHeight = textView.frame.height
			let visibleHeight = scrollView.contentView.bounds.height
			let y = max(0, docHeight - visibleHeight)
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
			scrollView.reflectScrolledClipView(scrollView.contentView)
		}

		// MARK: - NSTextViewDelegate

		/// Intercepts clicks on the disclosure triangle of a collapsed
		/// presence run. The triangle carries a `.link` attribute pointing
		/// at `brygga-toggle-run://<uuid>`; returning `false` tells AppKit
		/// we've handled the click and suppresses any URL-open attempt.
		func textView(
			_: NSTextView,
			clickedOnLink link: Any,
			at _: Int,
		) -> Bool {
			guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
				return false
			}
			if url.scheme == "brygga-toggle-run" {
				let idString = url.host ?? url.absoluteString.replacingOccurrences(
					of: "brygga-toggle-run://",
					with: "",
				)
				if let uuid = UUID(uuidString: idString) {
					if expandedRunIDs.contains(uuid) {
						expandedRunIDs.remove(uuid)
					} else {
						expandedRunIDs.insert(uuid)
					}
					reapply()
				}
				return false
			}
			// Any other URL: let AppKit open it normally.
			return true
		}

		func textView(
			_ view: NSTextView,
			menu: NSMenu,
			for _: NSEvent,
			at charIndex: Int,
		) -> NSMenu? {
			guard let storage = view.textStorage, charIndex < storage.length else {
				return menu
			}
			let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
			guard
				let id = attrs[.bryggaMessageID] as? UUID,
				let message = messagesByID[id]
			else { return menu }

			menu.addItem(.separator())

			let copyMessage = NSMenuItem(
				title: "Copy Message",
				action: #selector(copyAction(_:)),
				keyEquivalent: "",
			)
			copyMessage.target = self
			copyMessage.representedObject = plainLogLine(for: message)
			menu.addItem(copyMessage)

			let copyText = NSMenuItem(
				title: "Copy Text",
				action: #selector(copyAction(_:)),
				keyEquivalent: "",
			)
			copyText.target = self
			copyText.representedObject = IRCFormatting.stripControlCodes(message.content)
			menu.addItem(copyText)

			let copyNick = NSMenuItem(
				title: "Copy Nickname",
				action: #selector(copyAction(_:)),
				keyEquivalent: "",
			)
			copyNick.target = self
			copyNick.representedObject = message.sender
			menu.addItem(copyNick)

			return menu
		}

		@objc private func copyAction(_ sender: NSMenuItem) {
			guard let text = sender.representedObject as? String else { return }
			let pb = NSPasteboard.general
			pb.clearContents()
			pb.setString(text, forType: .string)
		}

		private func plainLogLine(for message: Message) -> String {
			let body = IRCFormatting.stripControlCodes(message.content)
			let ts = timestampText(for: message.timestamp)
			switch message.kind {
			case .privmsg: return "[\(ts)] <\(message.sender)> \(body)"
			case .notice: return "[\(ts)] -\(message.sender)- \(body)"
			case .action: return "[\(ts)] * \(message.sender) \(body)"
			default: return "[\(ts)] * \(message.sender) \(body)"
			}
		}
	}
}

// MARK: - Link preview attachment cell

/// Custom `NSTextAttachmentCell` that draws a compact link-preview card
/// inline in the chat buffer: rounded background, optional thumbnail on
/// the left, site name + title + summary on the right. For direct-image
/// previews the thumbnail fills the whole card. Non-destructive — if the
/// image hasn't loaded yet the cell draws a placeholder rectangle.
///
/// Deliberately *not* `@MainActor` — `NSTextAttachmentCell`'s core methods
/// (`cellSize`, `draw(withFrame:in:)`, `cellBaselineOffset`) are declared
/// nonisolated in AppKit and are invoked by the layout manager from its
/// own scheduling. The cell holds only immutable value types so nonisolated
/// access is safe.
final class LinkPreviewAttachmentCell: NSTextAttachmentCell {
	private let preview: LinkPreview
	private let previewImage: NSImage?

	private nonisolated static let cardWidth: CGFloat = 420
	private nonisolated static let cardHeight: CGFloat = 80
	private nonisolated static let directImageMaxHeight: CGFloat = 240
	private nonisolated static let directImageMaxWidth: CGFloat = 420
	private nonisolated static let padding: CGFloat = 10
	private nonisolated static let cornerRadius: CGFloat = 8
	private nonisolated static let thumbSize: CGFloat = 60

	init(preview: LinkPreview, image: NSImage?) {
		self.preview = preview
		previewImage = image
		super.init(textCell: "")
	}

	@available(*, unavailable)
	required init(coder _: NSCoder) {
		fatalError("init(coder:) not supported")
	}

	override func cellSize() -> NSSize {
		if preview.isDirectImage, let previewImage {
			let aspect = previewImage.size.height / max(previewImage.size.width, 1)
			let width = min(Self.directImageMaxWidth, previewImage.size.width)
			let height = min(Self.directImageMaxHeight, width * aspect)
			return NSSize(width: width, height: height)
		}
		return NSSize(width: Self.cardWidth, height: Self.cardHeight)
	}

	override func cellBaselineOffset() -> NSPoint {
		// Drop the card below the text baseline so it reads like a separate
		// paragraph attached to the message above.
		NSPoint(x: 0, y: -cellSize().height + 2)
	}

	override func draw(withFrame cellFrame: NSRect, in _: NSView?) {
		if preview.isDirectImage, let previewImage {
			drawDirectImage(previewImage, in: cellFrame)
		} else {
			drawCard(in: cellFrame)
		}
	}

	private func drawDirectImage(_ image: NSImage, in frame: NSRect) {
		NSGraphicsContext.saveGraphicsState()
		let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
		path.addClip()
		image.draw(
			in: frame,
			from: .zero,
			operation: .sourceOver,
			fraction: 1.0,
			respectFlipped: true,
			hints: [.interpolation: NSImageInterpolation.high.rawValue],
		)
		NSGraphicsContext.restoreGraphicsState()
	}

	private func drawCard(in frame: NSRect) {
		NSGraphicsContext.saveGraphicsState()
		defer { NSGraphicsContext.restoreGraphicsState() }

		let cardRect = frame.insetBy(dx: 0.5, dy: 0.5)
		let path = NSBezierPath(
			roundedRect: cardRect,
			xRadius: Self.cornerRadius,
			yRadius: Self.cornerRadius,
		)
		NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
		path.fill()
		NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
		path.lineWidth = 1
		path.stroke()

		var textOriginX = cardRect.origin.x + Self.padding

		if let previewImage {
			let thumbRect = NSRect(
				x: cardRect.origin.x + Self.padding,
				y: cardRect.origin.y + (cardRect.height - Self.thumbSize) / 2,
				width: Self.thumbSize,
				height: Self.thumbSize,
			)
			let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4)
			thumbPath.setClip()
			previewImage.draw(
				in: thumbRect,
				from: .zero,
				operation: .sourceOver,
				fraction: 1.0,
				respectFlipped: true,
				hints: [.interpolation: NSImageInterpolation.high.rawValue],
			)
			textOriginX = thumbRect.maxX + Self.padding
		} else if preview.imageURL != nil {
			// Placeholder while the image loads.
			let thumbRect = NSRect(
				x: cardRect.origin.x + Self.padding,
				y: cardRect.origin.y + (cardRect.height - Self.thumbSize) / 2,
				width: Self.thumbSize,
				height: Self.thumbSize,
			)
			NSColor.quaternaryLabelColor.setFill()
			NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4).fill()
			textOriginX = thumbRect.maxX + Self.padding
		}

		NSGraphicsContext.restoreGraphicsState()
		NSGraphicsContext.saveGraphicsState()

		let textMaxX = cardRect.maxX - Self.padding
		let textRect = NSRect(
			x: textOriginX,
			y: cardRect.origin.y + Self.padding,
			width: max(0, textMaxX - textOriginX),
			height: cardRect.height - Self.padding * 2,
		)

		drawCardText(in: textRect)
	}

	private func drawCardText(in rect: NSRect) {
		let site = preview.siteName ?? preview.url.host ?? preview.url.absoluteString
		let siteAttrs: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 10, weight: .regular),
			.foregroundColor: NSColor.secondaryLabelColor,
		]
		var y = rect.origin.y
		let siteAttr = NSAttributedString(string: site, attributes: siteAttrs)
		let siteSize = siteAttr.boundingRect(
			with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
			options: [.usesLineFragmentOrigin],
		).size
		siteAttr.draw(in: NSRect(
			x: rect.origin.x, y: y,
			width: rect.width, height: siteSize.height,
		))
		y += siteSize.height + 2

		if let title = preview.title, !title.isEmpty {
			let titleAttrs: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 13, weight: .medium),
				.foregroundColor: NSColor.labelColor,
				.paragraphStyle: truncatingParagraph(lines: 2),
			]
			let titleAttr = NSAttributedString(string: title, attributes: titleAttrs)
			let titleRect = NSRect(
				x: rect.origin.x, y: y,
				width: rect.width, height: rect.maxY - y,
			)
			titleAttr.draw(in: titleRect)
			let titleSize = titleAttr.boundingRect(
				with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
				options: [.usesLineFragmentOrigin],
			).size
			y += min(titleSize.height, rect.maxY - y) + 2
		}

		if let summary = preview.summary, !summary.isEmpty, y < rect.maxY {
			let summaryAttrs: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 11, weight: .regular),
				.foregroundColor: NSColor.secondaryLabelColor,
				.paragraphStyle: truncatingParagraph(lines: 2),
			]
			let summaryAttr = NSAttributedString(string: summary, attributes: summaryAttrs)
			let summaryRect = NSRect(
				x: rect.origin.x, y: y,
				width: rect.width, height: rect.maxY - y,
			)
			summaryAttr.draw(in: summaryRect)
		}
	}

	private func truncatingParagraph(lines: Int) -> NSParagraphStyle {
		let p = NSMutableParagraphStyle()
		p.lineBreakMode = .byTruncatingTail
		p.maximumLineHeight = 0
		_ = lines
		return p
	}
}

private extension NSAttributedString.Key {
	/// Marker attribute placed across the entire paragraph range of a
	/// message so the right-click handler can recover which `Message` the
	/// click landed inside.
	static let bryggaMessageID = NSAttributedString.Key("brygga.messageID")
}
