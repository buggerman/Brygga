// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation
import Observation

@Observable
public final class Channel: Identifiable {
	public let id: String
	public var name: String
	public var topic: String = ""
	public var modes: String = ""
	public var users: [User] = []
	public var messages: [Message] = []
	public var unreadCount: Int = 0
	public var highlightCount: Int = 0
	public var isJoined: Bool = false
	/// User-pinned favorite. Pinned channels appear in a dedicated section
	/// at the top of the sidebar and are reachable via Cmd+1…9. Persisted
	/// by name on the owning server's config.
	public var isPinned: Bool = false
	/// Message ID of the last message the user saw before navigating away.
	/// MessageList uses this to render a "new" divider above the first
	/// unread message when the user returns. Transient — not persisted.
	public var lastReadMessageID: UUID?
	/// Nickname → expiry timestamp. A user appears in the typing indicator
	/// until `Date.now > expiry`. Updated from incoming TAGMSG `+typing`
	/// client tags; transient — not persisted.
	public var typingUsers: [String: Date] = [:]
	/// `true` once `ScrollbackStore` has been consulted for this channel
	/// so we don't double-load when JOIN is received for a channel the
	/// restore path already rehydrated. Transient.
	public var scrollbackLoaded: Bool = false
	/// Whether the server (or bouncer) likely has more chathistory
	/// above the oldest message we currently hold locally. Set to
	/// `false` when a `CHATHISTORY BEFORE` request returns fewer rows
	/// than asked for, so the lazy-backfill code knows to stop firing.
	/// Transient — re-evaluated each session.
	public var hasMoreHistoryAbove: Bool = true
	/// `true` while a lazy `CHATHISTORY BEFORE` request is in flight.
	/// Drives the "Loading older messages…" banner. Transient.
	public var isLoadingHistory: Bool = false
	/// IRCv3 `msgid` of the oldest message held in `messages` for which
	/// the server might have more history above. Set when chathistory
	/// arrives so the next `BEFORE` request anchors against it.
	/// Transient.
	public var oldestKnownMsgID: String?

	public init(name: String) {
		id = UUID().uuidString
		self.name = name
	}

	public var isPrivateMessage: Bool {
		!name.hasPrefix("#") && !name.hasPrefix("&")
	}
}

@Observable
public final class User: Identifiable {
	public let id: String
	public var nickname: String
	public var username: String?
	public var hostname: String?
	public var account: String? // IRCv3 account-notify / account-tag
	public var modes: Set<Character> = [] // o, h, v, q, a
	public var isAway: Bool = false
	public var awayMessage: String?

	public init(nickname: String) {
		id = nickname.lowercased()
		self.nickname = nickname
	}

	public var prefix: String {
		if modes.contains("q") { return "~" }
		if modes.contains("a") { return "&" }
		if modes.contains("o") { return "@" }
		if modes.contains("h") { return "%" }
		if modes.contains("v") { return "+" }
		return ""
	}
}

public struct Message: Identifiable, Sendable, Codable {
	public let id: UUID
	public let timestamp: Date
	public let sender: String
	public let content: String
	public let kind: Kind
	public var isHighlight: Bool
	/// Server-assigned IRCv3 `msgid` tag, when the server provided
	/// one. Anchors `CHATHISTORY BEFORE`/`AFTER` queries and lets us
	/// dedup overlap between local scrollback and bouncer replays.
	/// `nil` for messages predating the IRCv3 `message-tags` cap or
	/// servers that don't set the tag.
	public let msgid: String?

	public init(
		timestamp: Date = Date(),
		sender: String,
		content: String,
		kind: Kind,
		isHighlight: Bool = false,
		msgid: String? = nil,
	) {
		id = UUID()
		self.timestamp = timestamp
		self.sender = sender
		self.content = content
		self.kind = kind
		self.isHighlight = isHighlight
		self.msgid = msgid
	}

	private enum CodingKeys: String, CodingKey {
		case id, timestamp, sender, content, kind, isHighlight, msgid
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		timestamp = try c.decode(Date.self, forKey: .timestamp)
		sender = try c.decode(String.self, forKey: .sender)
		content = try c.decode(String.self, forKey: .content)
		kind = try c.decode(Kind.self, forKey: .kind)
		isHighlight = try c.decodeIfPresent(Bool.self, forKey: .isHighlight) ?? false
		msgid = try c.decodeIfPresent(String.self, forKey: .msgid)
	}

	public enum Kind: String, Sendable, Codable {
		case privmsg
		case notice
		case action // /me
		case join
		case part
		case quit
		case nick
		case kick
		case topic
		case mode
		case server // server notice / numeric
	}
}
