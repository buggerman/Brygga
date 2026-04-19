/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif
import UserNotifications

/// Root application state. Holds all servers, sessions, and selection.
/// SwiftUI views observe this directly.
@MainActor
@Observable
public final class AppState {
	/// Connected and disconnected servers.
	public var servers: [Server] = []

	/// Active IRC sessions keyed by `Server.id`.
	public var sessions: [String: IRCSession] = [:]

	/// Currently selected item (server or channel) identified by `id`.
	public var selection: String?

	/// Coordination flag for presenting the Connect Server sheet.
	public var showingConnectSheet: Bool = false

	/// Coordination flag for presenting the channel-list browser.
	public var showingChannelList: Bool = false

	public init() {
		restoreFromStore()
		requestNotificationPermission()
	}

	// MARK: - Notifications

	private func requestNotificationPermission() {
		UNUserNotificationCenter.current().requestAuthorization(
			options: [.alert, .sound, .badge]
		) { _, _ in }
	}

	/// Post a macOS banner for a highlight and bump the Dock badge.
	/// Suppresses the banner if the app is frontmost and that exact channel
	/// is already selected.
	private func notifyHighlight(_ message: Message, in channel: Channel) {
		let isForegroundedOnThisChannel: Bool = {
			#if canImport(AppKit)
			guard NSApp.isActive else { return false }
			#endif
			return selection == channel.id
		}()

		if !isForegroundedOnThisChannel {
			let content = UNMutableNotificationContent()
			content.title = channel.name
			content.body = "\(message.sender): \(message.content)"
			content.sound = .default
			let request = UNNotificationRequest(
				identifier: UUID().uuidString,
				content: content,
				trigger: nil
			)
			UNUserNotificationCenter.current().add(request)
		}
		refreshDockBadge()
	}

	/// Recomputes the total highlight count across all channels and updates
	/// the Dock badge. Call after any change to any channel's `highlightCount`.
	public func refreshDockBadge() {
		let total = servers.reduce(0) { acc, server in
			acc + server.channels.reduce(0) { $0 + $1.highlightCount }
		}
		#if canImport(AppKit)
		NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
		#endif
	}

	// MARK: - Persistence

	private var isRestoring: Bool = false

	private func restoreFromStore() {
		let snapshot = ServerStore.load()
		guard !snapshot.servers.isEmpty else { return }
		isRestoring = true
		defer { isRestoring = false }

		for config in snapshot.servers {
			let server = addServer(
				name: config.name,
				host: config.host,
				port: config.port,
				useTLS: config.useTLS,
				nickname: config.nickname,
				autoJoinChannels: config.autoJoinChannels,
				saslAccount: config.saslAccount,
				saslPassword: config.saslPassword,
				ignoreList: config.ignoreList,
				notifyList: config.notifyList,
				performCommands: config.performCommands,
				pinnedChannels: config.pinnedChannels
			)
			for nick in config.openQueries {
				let ch = Channel(name: nick)
				ch.isPinned = server.pinnedChannels.contains(nick.lowercased())
				server.channels.append(ch)
			}
			// Rehydrate scrollback for server console + every known channel.
			Task { [server] in
				let serverMessages = await ScrollbackStore.shared.load(
					serverId: server.id,
					target: "__server__"
				)
				await MainActor.run {
					server.messages.insert(contentsOf: serverMessages, at: 0)
				}
				for channel in server.channels {
					let msgs = await ScrollbackStore.shared.load(
						serverId: server.id,
						target: channel.name
					)
					await MainActor.run {
						channel.messages.insert(contentsOf: msgs, at: 0)
					}
				}
			}
		}
	}

	private func snapshot() -> ServerStore.Snapshot {
		let configs: [ServerStore.ServerConfig] = servers.map { server in
			let joined = server.channels
				.filter { $0.isJoined && !$0.isPrivateMessage }
				.map { $0.name }
			let queries = server.channels
				.filter { $0.isPrivateMessage }
				.map { $0.name }
			return ServerStore.ServerConfig(
				name: server.name,
				host: server.host,
				port: UInt16(server.port),
				useTLS: server.useTLS,
				nickname: server.nickname,
				autoJoinChannels: joined,
				openQueries: queries,
				saslAccount: server.saslAccount,
				saslPassword: server.saslPassword,
				ignoreList: server.ignoreList,
				notifyList: server.notifyList,
				performCommands: server.performCommands,
				pinnedChannels: server.pinnedChannels
			)
		}
		return ServerStore.Snapshot(servers: configs)
	}

	private func persist() {
		guard !isRestoring else { return }
		ServerStore.save(snapshot())
	}

	/// Look up a channel across all servers by ID. Returns `nil` if the given
	/// ID is a server row, a PM that no longer exists, or unknown.
	public func channel(byID id: String) -> Channel? {
		for server in servers {
			if let ch = server.channels.first(where: { $0.id == id }) {
				return ch
			}
		}
		return nil
	}

	/// Convenience: the channel that's currently selected, if any.
	public var selectedChannel: Channel? {
		guard let id = selection else { return nil }
		for server in servers {
			if let ch = server.channels.first(where: { $0.id == id }) {
				return ch
			}
		}
		return nil
	}

	/// Convenience: the server whose row is selected, OR the server owning the
	/// currently selected channel.
	public var selectedServer: Server? {
		guard let id = selection else { return nil }
		if let server = servers.first(where: { $0.id == id }) {
			return server
		}
		for server in servers {
			if server.channels.contains(where: { $0.id == id }) {
				return server
			}
		}
		return nil
	}

	/// The session for the currently selected server (or the server owning
	/// the selected channel).
	public var selectedSession: IRCSession? {
		guard let server = selectedServer else { return nil }
		return sessions[server.id]
	}

	// MARK: - Server lifecycle

	/// Adds a server, creates and starts a session, and kicks off the
	/// connection. Returns the newly-added Server.
	@discardableResult
	public func addServer(
		name: String,
		host: String,
		port: UInt16 = 6697,
		useTLS: Bool = true,
		nickname: String,
		autoJoinChannels: [String] = [],
		saslAccount: String? = nil,
		saslPassword: String? = nil,
		ignoreList: [String] = [],
		notifyList: [String] = [],
		performCommands: [String] = [],
		pinnedChannels: [String] = []
	) -> Server {
		let server = Server(
			name: name.isEmpty ? host : name,
			host: host,
			port: Int(port),
			useTLS: useTLS,
			nickname: nickname,
			saslAccount: saslAccount,
			saslPassword: saslPassword
		)
		server.ignoreList = ignoreList
		server.notifyList = notifyList
		server.performCommands = performCommands
		server.pinnedChannels = pinnedChannels.map { $0.lowercased() }
		let connection = IRCConnection(
			host: host,
			port: port,
			useTLS: useTLS,
			nickname: nickname,
			saslAccount: saslAccount,
			saslPassword: saslPassword
		)
		let session = IRCSession(server: server, connection: connection)
		session.autoJoinChannels = autoJoinChannels
		session.onChannelsChanged = { [weak self] in self?.persist() }
		session.onHighlight = { [weak self] channel, message in
			self?.notifyHighlight(message, in: channel)
		}
		session.start()

		servers.append(server)
		sessions[server.id] = session

		Task {
			do {
				try await connection.connect()
			} catch {
				server.state = .disconnected
			}
		}

		persist()
		return server
	}

	/// User-initiated disconnect for a single server. Keeps the server in
	/// the sidebar and persisted config, but suppresses auto-reconnect.
	public func disconnectServer(id: String, quitMessage: String? = "Brygga") async {
		guard let session = sessions[id] else { return }
		await session.disconnect(quitMessage: quitMessage)
	}

	/// Brings a previously-disconnected server back online.
	public func reconnectServer(id: String) {
		guard let session = sessions[id] else { return }
		session.reconnect()
	}

	/// Sends QUIT and tears down every active session. Call this before
	/// terminating the process so the server sees a clean client shutdown.
	public func disconnectAll(quitMessage: String? = nil) async {
		let snapshots = sessions.values.map { $0 }
		// Mark each session user-disconnected *before* tearing the socket down
		// so the reconnect loop doesn't schedule itself in the gap.
		for session in snapshots {
			session.stop()
		}
		await withTaskGroup(of: Void.self) { group in
			for session in snapshots {
				group.addTask {
					await session.connection.disconnect(quitMessage: quitMessage)
				}
			}
		}
	}

	/// Toggles the pinned state of a channel, updates the owning server's
	/// pinned-name list, and persists. Pinned channels appear in the
	/// sidebar's Favorites section and are reachable via Cmd+1…9.
	public func togglePin(channelID: String) {
		for server in servers {
			guard let channel = server.channels.first(where: { $0.id == channelID }) else { continue }
			channel.isPinned.toggle()
			let key = channel.name.lowercased()
			if channel.isPinned {
				if !server.pinnedChannels.contains(key) {
					server.pinnedChannels.append(key)
				}
			} else {
				server.pinnedChannels.removeAll { $0 == key }
			}
			persist()
			return
		}
	}

	/// Ordered list of pinned channels across every server. Used by the
	/// sidebar's Favorites section and the Cmd+1…9 keyboard shortcuts.
	public var pinnedChannels: [Channel] {
		servers.flatMap { server in
			server.channels.filter(\.isPinned)
		}
	}

	/// Disconnects and removes a server.
	public func removeServer(id: String) {
		if let session = sessions[id] {
			session.stop()
			Task {
				await session.connection.disconnect()
			}
		}
		sessions.removeValue(forKey: id)
		servers.removeAll(where: { $0.id == id })
		if selection == id {
			selection = nil
		}
		persist()
	}
}
