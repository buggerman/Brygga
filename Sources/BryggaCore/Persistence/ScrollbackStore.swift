// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// Persists per-channel message history as JSON-lines under
/// `~/Library/Application Support/Brygga/scrollback/<serverId>/<target>.log`.
///
/// Appends are fire-and-forget from the caller's perspective — each append
/// is scheduled onto this actor, so message order is preserved without
/// blocking the main actor.
public actor ScrollbackStore {

	public static let shared = ScrollbackStore()

	private let root: URL
	private let encoder: JSONEncoder
	private let decoder: JSONDecoder

	public init(root: URL? = nil) {
		let base: URL
		if let root = root {
			base = root
		} else {
			let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
				?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
			base = support.appendingPathComponent("Brygga/scrollback", isDirectory: true)
		}
		self.root = base
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

		let enc = JSONEncoder()
		enc.dateEncodingStrategy = .iso8601
		self.encoder = enc

		let dec = JSONDecoder()
		dec.dateDecodingStrategy = .iso8601
		self.decoder = dec
	}

	/// Append a single message to the log for `target` under `serverId`.
	public func append(serverId: String, target: String, message: Message) {
		do {
			let url = try fileURL(serverId: serverId, target: target)
			var data = try encoder.encode(message)
			data.append(0x0A) // newline

			if FileManager.default.fileExists(atPath: url.path) {
				let handle = try FileHandle(forWritingTo: url)
				try handle.seekToEnd()
				try handle.write(contentsOf: data)
				try handle.close()
			} else {
				try data.write(to: url, options: .atomic)
			}
		} catch {
			// Best-effort — scrollback write failures shouldn't crash the app.
		}
	}

	/// Load up to `limit` most-recent messages for a target, oldest-first.
	public func load(serverId: String, target: String, limit: Int = 500) -> [Message] {
		guard let url = try? fileURL(serverId: serverId, target: target),
		      FileManager.default.fileExists(atPath: url.path),
		      let data = try? Data(contentsOf: url) else {
			return []
		}
		let lines = data.split(separator: 0x0A)
		let tail = lines.suffix(limit)
		var result: [Message] = []
		result.reserveCapacity(tail.count)
		for slice in tail {
			guard !slice.isEmpty else { continue }
			if let msg = try? decoder.decode(Message.self, from: Data(slice)) {
				result.append(msg)
			}
		}
		return result
	}

	/// Remove the scrollback file for a given target (e.g., when a server is
	/// removed or a query is closed).
	public func clear(serverId: String, target: String) {
		if let url = try? fileURL(serverId: serverId, target: target) {
			try? FileManager.default.removeItem(at: url)
		}
	}

	/// Remove an entire server's scrollback directory.
	public func clearServer(serverId: String) {
		let dir = root.appendingPathComponent(sanitize(serverId), isDirectory: true)
		try? FileManager.default.removeItem(at: dir)
	}

	// MARK: - Helpers

	private func fileURL(serverId: String, target: String) throws -> URL {
		let serverDir = root.appendingPathComponent(sanitize(serverId), isDirectory: true)
		try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
		return serverDir.appendingPathComponent("\(sanitize(target)).log")
	}

	/// Keeps only filename-safe characters. Everything else becomes `_`.
	private func sanitize(_ raw: String) -> String {
		var out = ""
		out.reserveCapacity(raw.count)
		for char in raw {
			if char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." {
				out.append(char)
			} else {
				out.append("_")
			}
		}
		return out.isEmpty ? "_" : out
	}
}
