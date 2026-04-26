// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// Loads and saves the list of configured servers as JSON. The default
/// instance reads/writes `~/Library/Application Support/Brygga/servers.json`;
/// tests construct their own `ServerStore(root: tempDir)` so they never touch
/// the user's real config. `AppState` requires a store to be passed in
/// explicitly — there is no `AppState()` default — so a test that forgets
/// to inject a temp store is a compile error rather than a silent prod
/// overwrite.
public final class ServerStore: Sendable {
	/// Default singleton, anchored at the production path. Used by the app
	/// executable; tests must construct their own instance.
	public static let shared = ServerStore()

	private let url: URL

	/// `root` is the directory that holds `servers.json`. `nil` resolves to
	/// the standard `~/Library/Application Support/Brygga/` location.
	public init(root: URL? = nil) {
		let dir: URL = if let root {
			root
		} else {
			(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
				?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
				.appendingPathComponent("Brygga", isDirectory: true)
		}
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		url = dir.appendingPathComponent("servers.json")
	}

	/// Absolute path of the backing JSON file. Useful for diagnostics and
	/// for the recovery utility.
	public var fileURL: URL {
		url
	}

	public func load() -> Snapshot {
		guard let data = try? Data(contentsOf: url) else {
			return Snapshot(servers: [])
		}
		return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? Snapshot(servers: [])
	}

	public func save(_ snapshot: Snapshot) {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		guard let data = try? encoder.encode(snapshot) else { return }
		try? data.write(to: url, options: .atomic)
	}

	public struct ServerConfig: Codable, Equatable, Sendable {
		/// Stable identifier for this server across launches. Keys the
		/// scrollback directory on disk (`scrollback/<id>/<target>.log`)
		/// so message history survives relaunches. `nil` when migrating
		/// from a pre-0.1.1 `servers.json` that never stored an id — in
		/// that case `AppState.addServer` assigns a fresh UUID which then
		/// lands in the next persist write.
		public var id: String?
		public var name: String
		public var host: String
		public var port: UInt16
		public var useTLS: Bool
		public var nickname: String
		public var autoJoinChannels: [String]
		public var openQueries: [String] = []
		public var saslAccount: String?
		public var saslPassword: String?
		public var ignoreList: [String] = []
		public var notifyList: [String] = []
		public var performCommands: [String] = []
		public var pinnedChannels: [String] = []
		public var clientCertificatePath: String?
		public var clientCertificatePassphrase: String?
		/// Optional per-channel overrides for the "collapse presence runs"
		/// preference. Keyed by lowercased channel name, value is the
		/// explicit override (true = collapse, false = don't collapse).
		/// Missing keys or a nil map mean "inherit the global default".
		public var channelPresenceCollapse: [String: Bool]?
		/// Per-channel IRCv3 `msgid` of the most-recent message Brygga
		/// has observed, keyed by lowercased channel name. Anchors
		/// `CHATHISTORY AFTER` on reconnect / cold start so the server
		/// replays only what we missed while disconnected.
		public var channelLastSeenMsgID: [String: String]?
		/// soju netid the connection is locked to via `BOUNCER BIND`.
		/// Set on Server entries the user added from a discovered
		/// network in the bouncer-networks popover; the connection
		/// sends BIND during CAP negotiation so all subsequent chat
		/// traffic is scoped to that single upstream network.
		/// `nil` for non-bouncer servers and for the bouncer's
		/// discovery / control connection.
		public var bouncerNetID: String?

		enum CodingKeys: String, CodingKey {
			case id, name, host, port, useTLS, nickname, autoJoinChannels, openQueries,
			     saslAccount, saslPassword, ignoreList, notifyList, performCommands,
			     pinnedChannels, clientCertificatePath, clientCertificatePassphrase,
			     channelPresenceCollapse, channelLastSeenMsgID, bouncerNetID
		}

		public init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			id = try c.decodeIfPresent(String.self, forKey: .id)
			name = try c.decode(String.self, forKey: .name)
			host = try c.decode(String.self, forKey: .host)
			port = try c.decode(UInt16.self, forKey: .port)
			useTLS = try c.decode(Bool.self, forKey: .useTLS)
			nickname = try c.decode(String.self, forKey: .nickname)
			autoJoinChannels = try c.decode([String].self, forKey: .autoJoinChannels)
			openQueries = try c.decodeIfPresent([String].self, forKey: .openQueries) ?? []
			saslAccount = try c.decodeIfPresent(String.self, forKey: .saslAccount)
			// saslPassword / clientCertificatePassphrase are still read for
			// one-time migration from pre-0.1.2 JSON that stored them in
			// plaintext — but they're no longer encoded. AppState picks up
			// whatever lands here, writes it to Keychain, and the next
			// persist drops it from disk.
			saslPassword = try c.decodeIfPresent(String.self, forKey: .saslPassword)
			ignoreList = try c.decodeIfPresent([String].self, forKey: .ignoreList) ?? []
			notifyList = try c.decodeIfPresent([String].self, forKey: .notifyList) ?? []
			performCommands = try c.decodeIfPresent([String].self, forKey: .performCommands) ?? []
			pinnedChannels = try c.decodeIfPresent([String].self, forKey: .pinnedChannels) ?? []
			clientCertificatePath = try c.decodeIfPresent(String.self, forKey: .clientCertificatePath)
			clientCertificatePassphrase = try c.decodeIfPresent(String.self, forKey: .clientCertificatePassphrase)
			channelPresenceCollapse = try c.decodeIfPresent([String: Bool].self, forKey: .channelPresenceCollapse)
			channelLastSeenMsgID = try c.decodeIfPresent([String: String].self, forKey: .channelLastSeenMsgID)
			bouncerNetID = try c.decodeIfPresent(String.self, forKey: .bouncerNetID)
		}

		/// Custom encode deliberately skips `saslPassword` and
		/// `clientCertificatePassphrase` — those live in Keychain now.
		/// Everything else uses `encodeIfPresent` so optionals don't
		/// clutter the JSON with explicit `null` entries.
		public func encode(to encoder: Encoder) throws {
			var c = encoder.container(keyedBy: CodingKeys.self)
			try c.encodeIfPresent(id, forKey: .id)
			try c.encode(name, forKey: .name)
			try c.encode(host, forKey: .host)
			try c.encode(port, forKey: .port)
			try c.encode(useTLS, forKey: .useTLS)
			try c.encode(nickname, forKey: .nickname)
			try c.encode(autoJoinChannels, forKey: .autoJoinChannels)
			try c.encode(openQueries, forKey: .openQueries)
			try c.encodeIfPresent(saslAccount, forKey: .saslAccount)
			try c.encode(ignoreList, forKey: .ignoreList)
			try c.encode(notifyList, forKey: .notifyList)
			try c.encode(performCommands, forKey: .performCommands)
			try c.encode(pinnedChannels, forKey: .pinnedChannels)
			try c.encodeIfPresent(clientCertificatePath, forKey: .clientCertificatePath)
			// saslPassword and clientCertificatePassphrase: intentionally omitted.
			try c.encodeIfPresent(channelPresenceCollapse, forKey: .channelPresenceCollapse)
			try c.encodeIfPresent(channelLastSeenMsgID, forKey: .channelLastSeenMsgID)
			try c.encodeIfPresent(bouncerNetID, forKey: .bouncerNetID)
		}

		public init(
			id: String? = nil,
			name: String,
			host: String,
			port: UInt16,
			useTLS: Bool,
			nickname: String,
			autoJoinChannels: [String],
			openQueries: [String],
			saslAccount: String? = nil,
			saslPassword: String? = nil,
			ignoreList: [String] = [],
			notifyList: [String] = [],
			performCommands: [String] = [],
			pinnedChannels: [String] = [],
			clientCertificatePath: String? = nil,
			clientCertificatePassphrase: String? = nil,
			channelPresenceCollapse: [String: Bool]? = nil,
			channelLastSeenMsgID: [String: String]? = nil,
			bouncerNetID: String? = nil,
		) {
			self.id = id
			self.name = name
			self.host = host
			self.port = port
			self.useTLS = useTLS
			self.nickname = nickname
			self.autoJoinChannels = autoJoinChannels
			self.openQueries = openQueries
			self.saslAccount = saslAccount
			self.saslPassword = saslPassword
			self.ignoreList = ignoreList
			self.notifyList = notifyList
			self.performCommands = performCommands
			self.pinnedChannels = pinnedChannels
			self.clientCertificatePath = clientCertificatePath
			self.clientCertificatePassphrase = clientCertificatePassphrase
			self.channelPresenceCollapse = channelPresenceCollapse
			self.channelLastSeenMsgID = channelLastSeenMsgID
			self.bouncerNetID = bouncerNetID
		}
	}

	public struct Snapshot: Codable, Equatable, Sendable {
		public var servers: [ServerConfig]
	}
}
