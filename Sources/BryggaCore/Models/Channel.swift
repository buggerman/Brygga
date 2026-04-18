/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

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

	public init(name: String) {
		self.id = UUID().uuidString
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
	public var modes: Set<Character> = []   // o, h, v, q, a
	public var isAway: Bool = false

	public init(nickname: String) {
		self.id = nickname.lowercased()
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

	public init(timestamp: Date = Date(), sender: String, content: String, kind: Kind) {
		self.id = UUID()
		self.timestamp = timestamp
		self.sender = sender
		self.content = content
		self.kind = kind
	}

	public enum Kind: String, Sendable, Codable {
		case privmsg
		case notice
		case action       // /me
		case join
		case part
		case quit
		case nick
		case kick
		case topic
		case mode
		case server       // server notice / numeric
	}
}
