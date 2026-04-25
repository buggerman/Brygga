// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation
import SQLite3

/// Where a search should look.
public enum SearchScope: Sendable, Equatable {
	case all
	case server(id: String)
	case channel(serverID: String, target: String)
}

/// One match returned by `ScrollbackIndex.search`. Contains everything the UI
/// needs to render a row and navigate to the source message.
public struct SearchHit: Sendable, Equatable {
	public let messageID: UUID
	public let serverID: String
	public let target: String
	public let timestamp: Date
	public let sender: String
	public let content: String
	public let kind: Message.Kind
	/// FTS5 BM25 score (lower = more relevant). Useful for tie-breaking when
	/// the UI presents results sorted by recency rather than rank.
	public let rank: Double

	public init(
		messageID: UUID,
		serverID: String,
		target: String,
		timestamp: Date,
		sender: String,
		content: String,
		kind: Message.Kind,
		rank: Double,
	) {
		self.messageID = messageID
		self.serverID = serverID
		self.target = target
		self.timestamp = timestamp
		self.sender = sender
		self.content = content
		self.kind = kind
		self.rank = rank
	}
}

/// SQLite + FTS5-backed full-text index over scrollback. Mirrors the writes
/// `ScrollbackStore` performs to the per-channel JSONL files so `search(_:)`
/// can return ranked matches across servers, channels, and PMs.
///
/// The unsafe `SQLite3` C surface (`OpaquePointer`, `sqlite3_*` calls,
/// `UnsafeMutablePointer`) is fully contained inside this actor — public
/// API takes/returns Swift value types only. See the **Pure Swift** rule
/// in `AGENTS.md` for the wrapping policy.
public actor ScrollbackIndex {
	public static let shared = ScrollbackIndex()

	private let path: String
	private var db: OpaquePointer?
	private var indexStmt: OpaquePointer?
	private var existsStmt: OpaquePointer?

	/// SQLite's `SQLITE_TRANSIENT` constant. Tells SQLite to copy the bound
	/// bytes immediately so the original Swift `String` storage doesn't have
	/// to outlive the bind. C macro doesn't survive the import; reconstruct it.
	private static let SQLITE_TRANSIENT = unsafeBitCast(
		OpaquePointer(bitPattern: -1),
		to: sqlite3_destructor_type.self,
	)

	/// `path == ":memory:"` opens an isolated in-process database — the test
	/// pathway. `nil` resolves to the standard on-disk location under
	/// Application Support so production callers don't have to know the path.
	public init(path: String? = nil) {
		if let path {
			self.path = path
		} else {
			let support = FileManager.default
				.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
				?? URL(fileURLWithPath: NSHomeDirectory())
				.appendingPathComponent("Library/Application Support")
			let dir = support.appendingPathComponent("Brygga", isDirectory: true)
			try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			self.path = dir.appendingPathComponent("scrollback.sqlite").path
		}
	}

	// No `deinit`-time cleanup: actor deinit is nonisolated under strict
	// concurrency and can't touch the non-Sendable `OpaquePointer` state.
	// `isolated deinit` (SE-0371) would fix this but requires macOS 15.4.
	// In practice the production instance is a singleton that never
	// deinits, and `:memory:` test instances are reclaimed at process
	// exit — SQLite handles that path cleanly.

	// MARK: - Public API

	/// Add `message` to the index. Idempotent: a second call with the same
	/// `Message.id` is a no-op so backfill replays don't double-count.
	public func index(_ message: Message, serverID: String, target: String) {
		ensureOpen()
		guard let db else { return }
		if alreadyIndexed(messageID: message.id) { return }

		if indexStmt == nil {
			let sql = """
			INSERT INTO messages
				(sender, content, msg_id, server_id, target, timestamp, kind)
			VALUES (?, ?, ?, ?, ?, ?, ?)
			"""
			var stmt: OpaquePointer?
			guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
			indexStmt = stmt
		}

		guard let stmt = indexStmt else { return }
		sqlite3_reset(stmt)
		bind(stmt, 1, message.sender)
		bind(stmt, 2, message.content)
		bind(stmt, 3, message.id.uuidString)
		bind(stmt, 4, serverID)
		bind(stmt, 5, target)
		bind(stmt, 6, ISO8601DateFormatter().string(from: message.timestamp))
		bind(stmt, 7, message.kind.rawValue)
		_ = sqlite3_step(stmt)
	}

	/// Run a full-text search. The query is passed verbatim to FTS5, so the
	/// caller gets phrase queries, prefix matches, column scoping, and
	/// boolean operators for free (`"foo bar"`, `bar*`, `sender:alice`,
	/// `term1 AND term2 NOT term3`). Results sort by BM25 rank, then by
	/// recency.
	public func search(_ query: String, scope: SearchScope = .all, limit: Int = 200) -> [SearchHit] {
		ensureOpen()
		guard let db else { return [] }
		let trimmed = query.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return [] }

		var sql = """
		SELECT msg_id, server_id, target, timestamp, sender, content, kind, bm25(messages) AS rank
		FROM messages
		WHERE messages MATCH ?
		"""
		var bindings: [String] = [trimmed]
		switch scope {
		case .all:
			break
		case let .server(id):
			sql += " AND server_id = ?"
			bindings.append(id)
		case let .channel(serverID, target):
			sql += " AND server_id = ? AND target = ?"
			bindings.append(serverID)
			bindings.append(target)
		}
		sql += " ORDER BY rank, timestamp DESC LIMIT \(max(1, min(1000, limit)))"

		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
		defer { sqlite3_finalize(stmt) }
		for (idx, value) in bindings.enumerated() {
			bind(stmt, Int32(idx + 1), value)
		}

		let isoParser = ISO8601DateFormatter()
		var hits: [SearchHit] = []
		while sqlite3_step(stmt) == SQLITE_ROW {
			guard
				let msgIDStr = column(stmt, 0),
				let serverID = column(stmt, 1),
				let target = column(stmt, 2),
				let timestampStr = column(stmt, 3),
				let sender = column(stmt, 4),
				let content = column(stmt, 5),
				let kindStr = column(stmt, 6),
				let messageID = UUID(uuidString: msgIDStr),
				let timestamp = isoParser.date(from: timestampStr),
				let kind = Message.Kind(rawValue: kindStr)
			else { continue }
			let rank = sqlite3_column_double(stmt, 7)
			hits.append(SearchHit(
				messageID: messageID,
				serverID: serverID,
				target: target,
				timestamp: timestamp,
				sender: sender,
				content: content,
				kind: kind,
				rank: rank,
			))
		}
		return hits
	}

	/// Drop indexed rows for a given target (when a query tab closes) or
	/// for an entire server (when the server is removed). `target == nil`
	/// means "everything under this server".
	public func clear(serverID: String, target: String? = nil) {
		ensureOpen()
		guard let db else { return }

		let sql = if target != nil {
			"DELETE FROM messages WHERE server_id = ? AND target = ?"
		} else {
			"DELETE FROM messages WHERE server_id = ?"
		}
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
		defer { sqlite3_finalize(stmt) }
		bind(stmt, 1, serverID)
		if let target {
			bind(stmt, 2, target)
		}
		_ = sqlite3_step(stmt)
	}

	// MARK: - Internals

	private func ensureOpen() {
		guard db == nil else { return }
		var handle: OpaquePointer?
		let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
		guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else { return }
		db = handle
		exec("PRAGMA journal_mode = WAL")
		exec("PRAGMA synchronous = NORMAL")
		exec("""
		CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
			sender,
			content,
			msg_id UNINDEXED,
			server_id UNINDEXED,
			target UNINDEXED,
			timestamp UNINDEXED,
			kind UNINDEXED,
			tokenize = 'unicode61 remove_diacritics 2'
		)
		""")
		exec("CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY, value TEXT)")
	}

	@discardableResult
	private func exec(_ sql: String) -> Bool {
		guard let db else { return false }
		return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
	}

	private func alreadyIndexed(messageID: UUID) -> Bool {
		guard let db else { return false }
		if existsStmt == nil {
			let sql = "SELECT 1 FROM messages WHERE msg_id = ? LIMIT 1"
			var stmt: OpaquePointer?
			guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
			existsStmt = stmt
		}
		guard let stmt = existsStmt else { return false }
		sqlite3_reset(stmt)
		bind(stmt, 1, messageID.uuidString)
		return sqlite3_step(stmt) == SQLITE_ROW
	}

	private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
		sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
	}

	private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
		guard let cString = sqlite3_column_text(stmt, index) else { return nil }
		return String(cString: cString)
	}
}
