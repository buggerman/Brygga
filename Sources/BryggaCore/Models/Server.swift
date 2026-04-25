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
	/// Per-channel overrides for the "collapse presence runs" preference,
	/// keyed by lowercased channel name. A present entry wins over the
	/// global `PreferencesKeys.collapsePresenceRuns` default; absence means
	/// "inherit". Persisted via `ServerConfig.channelPresenceCollapse`.
	public var presenceCollapseOverrides: [String: Bool] = [:]
	/// Server-assigned IRCv3 `msgid` of the most recent message Brygga
	/// has observed in each channel, keyed by lowercased channel name.
	/// On reconnect / cold start, used as the anchor for `CHATHISTORY
	/// AFTER msgid=<id>` so the server replays exactly what we missed
	/// while disconnected — closing the gap the JOIN-time `LATEST 100`
	/// heuristic leaves. Persisted via
	/// `ServerConfig.channelLastSeenMsgID`.
	public var lastSeenMsgIDs: [String: String] = [:]
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
	/// Networks advertised by a soju-style bouncer fronting this
	/// connection. Populated on welcome via `BOUNCER LISTNETWORKS`
	/// when the `soju.im/bouncer-networks` cap is negotiated; updated
	/// in real time via `soju.im/bouncer-networks-notify`. Empty for
	/// non-bouncer servers. Transient — discovered fresh each
	/// connect; not persisted.
	public var bouncerNetworks: [BouncerNetwork] = []
	/// soju netid this connection is locked to via `BOUNCER BIND`.
	/// Set on Server entries the user adds from a discovered network
	/// in the bouncer-networks popover; the connection sends BIND
	/// during CAP negotiation so all subsequent chat traffic is
	/// scoped to that single upstream network. `nil` for non-bouncer
	/// servers and for the discovery / control Server entry of a
	/// bouncer (the unbound connection that fronts LISTNETWORKS).
	/// Persisted via `ServerConfig.bouncerNetID`.
	public var bouncerNetID: String?

	public init(
		id: String? = nil,
		name: String,
		host: String,
		port: Int = 6697,
		useTLS: Bool = true,
		nickname: String,
		saslAccount: String? = nil,
		saslPassword: String? = nil,
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
		case registered // successful USER/NICK + welcome
		case disconnecting
	}

	public var isActive: Bool {
		switch state {
		case .connected, .registered: true
		default: false
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
		id = UUID()
		self.name = name
		self.userCount = userCount
		self.topic = topic
	}
}
