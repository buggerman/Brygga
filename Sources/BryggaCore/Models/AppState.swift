// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

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

	/// Coordination flag for presenting the cross-channel Find sheet
	/// (`Cmd+Shift+F`).
	public var showingGlobalFind: Bool = false

	/// Coordination flag for the `Cmd+K` quick-switcher sheet.
	public var showingQuickSwitcher: Bool = false

	/// Coordination flag for the `Cmd+J` quick-join sheet.
	public var showingQuickJoin: Bool = false

	/// Shared input history for every `InputBar`. Up/Down arrow cycles
	/// through it in mIRC fashion. Bounded to 100 entries to keep state
	/// cheap and session-only (not persisted across launches).
	public var commandHistory: [String] = []

	/// Push a new entry onto `commandHistory`, collapsing consecutive
	/// duplicates and capping the list at 100 items.
	public func pushCommandHistory(_ line: String) {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		if commandHistory.last == trimmed { return }
		commandHistory.append(trimmed)
		if commandHistory.count > 100 {
			commandHistory.removeFirst(commandHistory.count - 100)
		}
	}

	/// Shared cache + fetcher for inline link previews. Views call
	/// `linkPreviews.fetchIfNeeded(url)` on appear and read
	/// `linkPreviews.preview(for: url)` to render. Off-by-default fetching
	/// is gated at the call site via `PreferencesKeys.linkPreviewsEnabled`.
	public let linkPreviews = LinkPreviewStore()

	public init() {
		restoreFromStore()
		requestNotificationPermission()
	}

	// MARK: - Notifications

	private func requestNotificationPermission() {
		// UNUserNotificationCenter requires a real `.app` bundle — in
		// `swift test` the "main bundle" is the xctest runner, and touching
		// the center throws an NSInternalInconsistencyException.
		guard Bundle.main.bundleURL.pathExtension == "app" else { return }
		UNUserNotificationCenter.current().requestAuthorization(
			options: [.alert, .sound, .badge],
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
				trigger: nil,
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

		// Tracks whether any ServerConfig arrived with a plaintext secret
		// field from a pre-Keychain `servers.json`. If so, we force one
		// `persist()` at the end of restore to scrub the legacy JSON even
		// if nothing else changes during this launch.
		var didMigrateSecrets = false

		for config in snapshot.servers {
			// Resolve secrets: Keychain wins; legacy JSON is a migration
			// fallback that gets scrubbed on the next write.
			let saslPwFromKeychain = config.id.flatMap { id in
				KeychainStore.secret(for: id, field: .saslPassword)
			}
			let certPpFromKeychain = config.id.flatMap { id in
				KeychainStore.secret(for: id, field: .certificatePassphrase)
			}
			let saslPassword = saslPwFromKeychain ?? config.saslPassword
			let certPassphrase = certPpFromKeychain ?? config.clientCertificatePassphrase

			if saslPwFromKeychain == nil, config.saslPassword?.isEmpty == false {
				didMigrateSecrets = true
			}
			if certPpFromKeychain == nil, config.clientCertificatePassphrase?.isEmpty == false {
				didMigrateSecrets = true
			}

			// Pass `id` through so the Server keeps the stable UUID stored
			// in `servers.json`. Without this, every launch mints a new
			// UUID, orphans the scrollback directory on disk, and the
			// user sees an empty buffer. `addServer` writes the resolved
			// secrets back to Keychain, which completes the migration.
			let server = addServer(
				id: config.id,
				name: config.name,
				host: config.host,
				port: config.port,
				useTLS: config.useTLS,
				nickname: config.nickname,
				autoJoinChannels: config.autoJoinChannels,
				saslAccount: config.saslAccount,
				saslPassword: saslPassword,
				ignoreList: config.ignoreList,
				notifyList: config.notifyList,
				performCommands: config.performCommands,
				pinnedChannels: config.pinnedChannels,
				clientCertificatePath: config.clientCertificatePath,
				clientCertificatePassphrase: certPassphrase,
			)
			// Pre-create Channel objects for auto-join channels so the async
			// scrollback rehydrate below has somewhere to land. Without this,
			// the channel doesn't exist until the server responds to our
			// JOIN, by which point the rehydrate has already iterated
			// `server.channels` and missed it — the user would see an empty
			// buffer on every launch. The JOIN handler is idempotent
			// (`if let existing = …`) so re-using these objects is safe.
			for name in config.autoJoinChannels {
				let ch = Channel(name: name)
				ch.isPinned = server.pinnedChannels.contains(name.lowercased())
				server.channels.append(ch)
			}
			for nick in config.openQueries {
				let ch = Channel(name: nick)
				ch.isPinned = server.pinnedChannels.contains(nick.lowercased())
				server.channels.append(ch)
			}
			// Rehydrate scrollback for server console + every known channel.
			Task { [server] in
				let serverMessages = await ScrollbackStore.shared.load(
					serverId: server.id,
					target: "__server__",
				)
				await MainActor.run {
					server.messages.insert(contentsOf: serverMessages, at: 0)
				}
				for channel in server.channels {
					let msgs = await ScrollbackStore.shared.load(
						serverId: server.id,
						target: channel.name,
					)
					await MainActor.run {
						channel.messages.insert(contentsOf: msgs, at: 0)
						channel.scrollbackLoaded = true
					}
				}
			}
		}

		isRestoring = false
		// Force-write the JSON once when we've pulled secrets out of
		// legacy plaintext so the scrubbed snapshot (no saslPassword /
		// clientCertificatePassphrase keys) lands on disk immediately
		// instead of waiting for the user's next config change.
		if didMigrateSecrets {
			persist()
		}
	}

	private func snapshot() -> ServerStore.Snapshot {
		let configs: [ServerStore.ServerConfig] = servers.map { server in
			let joined = server.channels
				.filter { $0.isJoined && !$0.isPrivateMessage }
				.map(\.name)
			let queries = server.channels
				.filter(\.isPrivateMessage)
				.map(\.name)
			return ServerStore.ServerConfig(
				id: server.id,
				name: server.name,
				host: server.host,
				port: UInt16(server.port),
				useTLS: server.useTLS,
				nickname: server.nickname,
				autoJoinChannels: joined,
				openQueries: queries,
				saslAccount: server.saslAccount,
				// Secrets stay out of servers.json. KeychainStore is the
				// only place plaintext passwords and passphrases live.
				// ServerConfig.encode(to:) also omits these keys, so this
				// is belt-and-braces.
				saslPassword: nil,
				ignoreList: server.ignoreList,
				notifyList: server.notifyList,
				performCommands: server.performCommands,
				pinnedChannels: server.pinnedChannels,
				clientCertificatePath: server.clientCertificatePath,
				clientCertificatePassphrase: nil,
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
		id: String? = nil,
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
		pinnedChannels: [String] = [],
		clientCertificatePath: String? = nil,
		clientCertificatePassphrase: String? = nil,
	) -> Server {
		let server = Server(
			id: id,
			name: name.isEmpty ? host : name,
			host: host,
			port: Int(port),
			useTLS: useTLS,
			nickname: nickname,
			saslAccount: saslAccount,
			saslPassword: saslPassword,
		)
		server.ignoreList = ignoreList
		server.notifyList = notifyList
		server.performCommands = performCommands
		server.pinnedChannels = pinnedChannels.map { $0.lowercased() }
		server.clientCertificatePath = clientCertificatePath
		server.clientCertificatePassphrase = clientCertificatePassphrase
		// Write-through secrets to Keychain on every addServer invocation
		// (restore, Connect sheet, test fixtures). Empty / nil values
		// become deletions, so clearing a password in the sheet removes
		// it from Keychain on the next persist cycle.
		KeychainStore.setSecret(saslPassword ?? "", for: server.id, field: .saslPassword)
		KeychainStore.setSecret(clientCertificatePassphrase ?? "", for: server.id, field: .certificatePassphrase)
		let connection = IRCConnection(
			host: host,
			port: port,
			useTLS: useTLS,
			nickname: nickname,
			saslAccount: saslAccount,
			saslPassword: saslPassword,
			clientCertificatePath: clientCertificatePath,
			clientCertificatePassphrase: clientCertificatePassphrase,
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
		let snapshots = sessions.values.map(\.self)
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

	/// Flat, in-sidebar-order list of selectable items: each server row
	/// followed by its channels. Used by `selectAdjacentChannel(direction:)`
	/// to drive the `Cmd+[` / `Cmd+]` previous / next navigation.
	public var selectableIDs: [String] {
		var ids: [String] = []
		for server in servers {
			ids.append(server.id)
			for channel in server.channels {
				ids.append(channel.id)
			}
		}
		return ids
	}

	/// Moves the sidebar selection up (direction `-1`) or down (`+1`) one
	/// row, wrapping at the ends. From an unselected state, `+1` jumps to
	/// the first item and `-1` jumps to the last. No-op on an empty list.
	public func selectAdjacentChannel(direction: Int) {
		let ids = selectableIDs
		guard !ids.isEmpty else { return }
		guard let current = selection,
		      let currentIndex = ids.firstIndex(of: current)
		else {
			selection = direction >= 0 ? ids.first : ids.last
			return
		}
		let nextIndex = ((currentIndex + direction) % ids.count + ids.count) % ids.count
		selection = ids[nextIndex]
	}

	/// Disconnects and removes a server.
	public func removeServer(id: String) {
		// Drop any Keychain entries before tearing the session down so
		// orphaned secrets don't linger.
		KeychainStore.deleteAllSecrets(for: id)
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
