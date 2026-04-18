/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation
import Observation

@Observable
public final class Server: Identifiable {
	public let id: String
	public var name: String
	public var host: String
	public var port: Int
	public var useTLS: Bool
	public var nickname: String
	public var saslAccount: String?
	public var saslPassword: String?
	public var channels: [Channel] = []
	public var messages: [Message] = []
	public var channelListing: [ChannelListing] = []
	public var isListingInProgress: Bool = false
	public var ignoreList: [String] = []
	public var state: ConnectionState = .disconnected
	public var isExpanded: Bool = true

	public init(
		name: String,
		host: String,
		port: Int = 6697,
		useTLS: Bool = true,
		nickname: String,
		saslAccount: String? = nil,
		saslPassword: String? = nil
	) {
		self.id = UUID().uuidString
		self.name = name
		self.host = host
		self.port = port
		self.useTLS = useTLS
		self.nickname = nickname
		self.saslAccount = saslAccount
		self.saslPassword = saslPassword
	}

	public enum ConnectionState: Equatable, Sendable {
		case disconnected
		case connecting
		case connected
		case registered   // successful USER/NICK + welcome
		case disconnecting
	}

	public var isActive: Bool {
		switch state {
		case .connected, .registered: return true
		default: return false
		}
	}
}

/// A single entry from a `LIST` response — a channel known to the server.
public struct ChannelListing: Identifiable, Sendable, Equatable {
	public let id: UUID
	public let name: String
	public let userCount: Int
	public let topic: String

	public init(name: String, userCount: Int, topic: String) {
		self.id = UUID()
		self.name = name
		self.userCount = userCount
		self.topic = topic
	}
}
