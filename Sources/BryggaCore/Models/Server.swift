// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

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
	/// Path to a PKCS#12 client certificate used for TLS client auth
	/// (enables SASL EXTERNAL). `nil` disables.
	public var clientCertificatePath: String?
	public var clientCertificatePassphrase: String?
	public var channels: [Channel] = []
	public var messages: [Message] = []
	public var channelListing: [ChannelListing] = []
	public var isListingInProgress: Bool = false
	public var ignoreList: [String] = []
	public var notifyList: [String] = []
	public var performCommands: [String] = []
	/// Lowercased names of user-pinned channels on this server. Mirrored
	/// onto `Channel.isPinned` whenever a channel with a matching name is
	/// created or the pin set changes.
	public var pinnedChannels: [String] = []
	public var isAway: Bool = false
	public var awayMessage: String?
	public var state: ConnectionState = .disconnected
	public var isExpanded: Bool = true
	/// Most recent measured round-trip time to the server (seconds) from
	/// our own `PING` / `PONG` pair. `nil` until the first pong arrives.
	public var lag: TimeInterval?
	/// Timestamp when the last client-initiated PING was sent; used both
	/// by the status bar ("last pinged 3s ago") and to detect a stale
	/// pong that should be discarded.
	public var lastPingAt: Date?

	public init(
		id: String? = nil,
		name: String,
		host: String,
		port: Int = 6697,
		useTLS: Bool = true,
		nickname: String,
		saslAccount: String? = nil,
		saslPassword: String? = nil
	) {
		// Accept a caller-supplied id so `AppState.restoreFromStore` can
		// rebind a server to its previous-launch UUID, which the
		// scrollback store uses as a directory key. Fresh servers fall
		// back to a new UUID.
		self.id = id ?? UUID().uuidString
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
