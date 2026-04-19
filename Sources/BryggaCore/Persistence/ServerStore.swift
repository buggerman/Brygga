// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// Loads and saves the list of configured servers to
/// `~/Library/Application Support/Brygga/servers.json`.
public enum ServerStore {

	public struct ServerConfig: Codable, Equatable {
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

		enum CodingKeys: String, CodingKey {
			case id, name, host, port, useTLS, nickname, autoJoinChannels, openQueries,
			     saslAccount, saslPassword, ignoreList, notifyList, performCommands,
			     pinnedChannels, clientCertificatePath, clientCertificatePassphrase
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
			clientCertificatePassphrase: String? = nil
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
		}
	}

	public struct Snapshot: Codable, Equatable {
		public var servers: [ServerConfig]
	}

	public static func fileURL() -> URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		let dir = base.appendingPathComponent("Brygga", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("servers.json")
	}

	public static func load() -> Snapshot {
		let url = fileURL()
		guard let data = try? Data(contentsOf: url) else {
			return Snapshot(servers: [])
		}
		return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? Snapshot(servers: [])
	}

	public static func save(_ snapshot: Snapshot) {
		let url = fileURL()
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		guard let data = try? encoder.encode(snapshot) else { return }
		try? data.write(to: url, options: .atomic)
	}
}
