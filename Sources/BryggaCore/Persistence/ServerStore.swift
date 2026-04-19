/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation

/// Loads and saves the list of configured servers to
/// `~/Library/Application Support/Brygga/servers.json`.
public enum ServerStore {

	public struct ServerConfig: Codable, Equatable {
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

		enum CodingKeys: String, CodingKey {
			case name, host, port, useTLS, nickname, autoJoinChannels, openQueries,
			     saslAccount, saslPassword, ignoreList, notifyList, performCommands
		}

		public init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			name = try c.decode(String.self, forKey: .name)
			host = try c.decode(String.self, forKey: .host)
			port = try c.decode(UInt16.self, forKey: .port)
			useTLS = try c.decode(Bool.self, forKey: .useTLS)
			nickname = try c.decode(String.self, forKey: .nickname)
			autoJoinChannels = try c.decode([String].self, forKey: .autoJoinChannels)
			openQueries = try c.decodeIfPresent([String].self, forKey: .openQueries) ?? []
			saslAccount = try c.decodeIfPresent(String.self, forKey: .saslAccount)
			saslPassword = try c.decodeIfPresent(String.self, forKey: .saslPassword)
			ignoreList = try c.decodeIfPresent([String].self, forKey: .ignoreList) ?? []
			notifyList = try c.decodeIfPresent([String].self, forKey: .notifyList) ?? []
			performCommands = try c.decodeIfPresent([String].self, forKey: .performCommands) ?? []
		}

		public init(
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
			performCommands: [String] = []
		) {
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
