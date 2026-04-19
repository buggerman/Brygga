// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// Opt-in human-readable disk logger. Distinct from `ScrollbackStore`
/// (which writes JSONL for app rehydration); this one writes plain text
/// that the user can grep / open / share.
///
/// Files land under `~/Library/Logs/Brygga/<network>/<target>.log`
/// (Apple's canonical app-log directory — not synced by iCloud, visible
/// in Console.app under User Reports). Logs previously written to
/// `~/Documents/Brygga Logs/` are migrated on first construction.
public actor DiskLogger {

	public static let shared = DiskLogger()

	private let root: URL
	private nonisolated let tsFormatter: DateFormatter

	public init(root: URL? = nil) {
		if let root = root {
			self.root = root
		} else {
			let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
				?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
			self.root = library
				.appendingPathComponent("Logs", isDirectory: true)
				.appendingPathComponent("Brygga", isDirectory: true)
		}
		try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
		Self.migrateLegacyDocumentsIfNeeded(into: self.root)

		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH:mm:ss"
		f.locale = Locale(identifier: "en_US_POSIX")
		f.timeZone = TimeZone.current
		self.tsFormatter = f
	}

	/// One-time move of logs from the pre-0.1.1 `~/Documents/Brygga Logs/`
	/// location into `~/Library/Logs/Brygga/`. No-op if the new dir
	/// already has content or the old dir doesn't exist. On move, leaves
	/// a `README.txt` breadcrumb in the old location pointing at the
	/// new one, so users with backup scripts tracking the old path
	/// aren't left wondering where the files went.
	private static func migrateLegacyDocumentsIfNeeded(into newRoot: URL) {
		let fm = FileManager.default
		let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
		let oldRoot = docs.appendingPathComponent("Brygga Logs", isDirectory: true)

		guard fm.fileExists(atPath: oldRoot.path) else { return }
		let oldEntries = (try? fm.contentsOfDirectory(atPath: oldRoot.path)) ?? []
		let newEntries = (try? fm.contentsOfDirectory(atPath: newRoot.path)) ?? []
		guard !oldEntries.isEmpty, newEntries.isEmpty else { return }

		for entry in oldEntries where entry != "README.txt" {
			let src = oldRoot.appendingPathComponent(entry)
			let dst = newRoot.appendingPathComponent(entry)
			try? fm.moveItem(at: src, to: dst)
		}

		// Breadcrumb so the old location explains itself.
		let readme = oldRoot.appendingPathComponent("README.txt")
		let message = """
		Brygga's disk logs moved to ~/Library/Logs/Brygga/ on first launch
		of 0.1.1+. That's the canonical macOS path for app logs (shown in
		Console.app, not synced by iCloud). The contents of this folder
		were moved there automatically; it's safe to delete what remains.
		"""
		try? message.write(to: readme, atomically: true, encoding: .utf8)
	}

	/// Append a single log line. `line` is the already-formatted human text
	/// (e.g. `<ElderRoot> hello`), `timestamp` is prepended as
	/// `[yyyy-MM-dd HH:mm:ss]`.
	public func append(network: String, target: String, line: String, timestamp: Date) {
		let ts = tsFormatter.string(from: timestamp)
		let fullLine = "[\(ts)] \(line)\n"
		guard let data = fullLine.data(using: .utf8) else { return }

		do {
			let url = try fileURL(network: network, target: target)
			if FileManager.default.fileExists(atPath: url.path) {
				let handle = try FileHandle(forWritingTo: url)
				try handle.seekToEnd()
				try handle.write(contentsOf: data)
				try handle.close()
			} else {
				try data.write(to: url, options: .atomic)
			}
		} catch {
			// Best-effort. Disk errors should never crash the client.
		}
	}

	private func fileURL(network: String, target: String) throws -> URL {
		let dir = root.appendingPathComponent(sanitize(network), isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("\(sanitize(target)).log")
	}

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
