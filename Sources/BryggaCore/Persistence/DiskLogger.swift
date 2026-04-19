/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation

/// Opt-in human-readable disk logger. Distinct from `ScrollbackStore`
/// (which writes JSONL for app rehydration); this one writes plain text
/// that the user can grep / open / share.
///
/// Files land under `~/Documents/Brygga Logs/<network>/<target>.log`.
public actor DiskLogger {

	public static let shared = DiskLogger()

	private let root: URL
	private nonisolated let tsFormatter: DateFormatter

	public init(root: URL? = nil) {
		if let root = root {
			self.root = root
		} else {
			let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
				?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
			self.root = docs.appendingPathComponent("Brygga Logs", isDirectory: true)
		}
		try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)

		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH:mm:ss"
		f.locale = Locale(identifier: "en_US_POSIX")
		f.timeZone = TimeZone.current
		self.tsFormatter = f
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
