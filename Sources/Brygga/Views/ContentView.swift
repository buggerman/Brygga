/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import BryggaCore

@MainActor
struct ContentView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		@Bindable var appState = appState

		VStack(spacing: 0) {
			NavigationSplitView {
				SidebarView()
					.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
			} detail: {
				ChatView()
					.inspector(isPresented: Binding(
						get: { shouldShowUserList },
						set: { _ in }
					)) {
						UserListView()
							.inspectorColumnWidth(min: 160, ideal: 200, max: 300)
					}
			}
			.navigationSplitViewStyle(.balanced)
			Divider()
			StatusBarView()
		}
		.sheet(isPresented: $appState.showingConnectSheet) {
			ConnectSheet()
				.environment(appState)
		}
		.sheet(isPresented: $appState.showingChannelList) {
			ChannelListSheet()
				.environment(appState)
		}
		.sheet(isPresented: $appState.showingGlobalFind) {
			GlobalFindSheet()
				.environment(appState)
		}
		.sheet(isPresented: $appState.showingQuickSwitcher) {
			QuickSwitcherSheet()
				.environment(appState)
		}
		.sheet(isPresented: $appState.showingQuickJoin) {
			QuickJoinSheet()
				.environment(appState)
		}
	}

	private var shouldShowUserList: Bool {
		guard let channel = appState.selectedChannel else { return false }
		return !channel.isPrivateMessage
	}
}

// MARK: - Sidebar

struct SidebarView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		@Bindable var appState = appState

		Group {
			if appState.servers.isEmpty {
				ContentUnavailableView {
					Label("No Servers", systemImage: "network")
				} description: {
					Text("Add a server to get started.")
				} actions: {
					Button("Add Server\u{2026}") {
						appState.showingConnectSheet = true
					}
				}
			} else {
				List(selection: $appState.selection) {
					let pinned = appState.pinnedChannels
					if !pinned.isEmpty {
						Section("Favorites") {
							ForEach(pinned) { channel in
								ChannelRow(channel: channel, serverName: serverName(for: channel))
									.tag(Optional(channel.id))
									.contextMenu {
										Button("Unpin") { appState.togglePin(channelID: channel.id) }
									}
							}
						}
					}

					ForEach(appState.servers) { server in
						ServerRow(server: server)
							.tag(Optional(server.id))
							.contextMenu {
								if server.state == .disconnected {
									Button("Connect") {
										appState.reconnectServer(id: server.id)
									}
								} else {
									Button("Disconnect") {
										Task { await appState.disconnectServer(id: server.id) }
									}
								}
								Divider()
								Button("Remove Server", role: .destructive) {
									appState.removeServer(id: server.id)
								}
							}

						ForEach(server.channels) { channel in
							ChannelRow(channel: channel)
								.tag(Optional(channel.id))
								.padding(.leading, 12)
								.contextMenu {
									Button(channel.isPinned ? "Unpin" : "Pin to Favorites") {
										appState.togglePin(channelID: channel.id)
									}
								}
						}
					}
				}
				.listStyle(.sidebar)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func serverName(for channel: Channel) -> String? {
		for server in appState.servers where server.channels.contains(where: { $0.id == channel.id }) {
			return server.name
		}
		return nil
	}
}

struct ServerRow: View {
	let server: Server

	var body: some View {
		HStack(spacing: 6) {
			Circle()
				.fill(stateColor)
				.frame(width: 8, height: 8)
			Text(server.name)
				.font(.system(size: 12, weight: .semibold))
			if server.isAway {
				Image(systemName: "moon.fill")
					.font(.system(size: 9))
					.foregroundStyle(.secondary)
			}
		}
	}

	private var stateColor: Color {
		switch server.state {
		case .registered, .connected: return .green
		case .connecting: return .yellow
		case .disconnecting: return .orange
		case .disconnected: return .gray
		}
	}
}

struct ChannelRow: View {
	let channel: Channel
	var serverName: String? = nil

	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 0) {
				Text(channel.name)
					.lineLimit(1)
				if let serverName {
					Text(serverName)
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}

			Spacer()

			if channel.highlightCount > 0 {
				Text("\(channel.highlightCount)")
					.font(.system(size: 10, weight: .bold))
					.foregroundStyle(.white)
					.padding(.horizontal, 6)
					.padding(.vertical, 1)
					.background(Capsule().fill(Color.red))
			} else if channel.unreadCount > 0 {
				Text("\(channel.unreadCount)")
					.font(.system(size: 10, weight: .bold))
					.foregroundStyle(.white)
					.padding(.horizontal, 6)
					.padding(.vertical, 1)
					.background(Capsule().fill(Color.gray))
			}
		}
	}
}

// MARK: - Typing indicator

/// Thin status row above the InputBar that renders who's currently typing in
/// the channel, based on IRCv3 `+typing` TAGMSG events. Uses a `TimelineView`
/// so the row disappears automatically when every typing entry's `expiry`
/// passes, without needing a separate cleanup Task on `Channel.typingUsers`.
struct TypingIndicatorView: View {
	let channel: Channel

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1)) { timeline in
			let active = channel.typingUsers
				.filter { $0.value > timeline.date }
				.map(\.key)
				.sorted()
			if !active.isEmpty {
				HStack {
					Text(message(for: active))
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.italic()
					Spacer()
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 3)
				.background(.bar)
			}
		}
	}

	private func message(for names: [String]) -> String {
		switch names.count {
		case 1:  return "\(names[0]) is typing\u{2026}"
		case 2:  return "\(names[0]) and \(names[1]) are typing\u{2026}"
		default: return "Several people are typing\u{2026}"
		}
	}
}

// MARK: - Status bar

/// Thin footer showing the focused server's connection state, nickname,
/// round-trip lag, and total channel count. Updates live off the
/// `@Observable` models.
@MainActor
struct StatusBarView: View {
	@Environment(AppState.self) private var appState

	private var focusedServer: Server? {
		appState.selectedServer ?? appState.servers.first
	}

	private var totalChannels: Int {
		appState.servers.reduce(0) { $0 + $1.channels.filter { !$0.isPrivateMessage }.count }
	}

	var body: some View {
		HStack(spacing: 10) {
			if let server = focusedServer {
				Circle()
					.fill(dotColor(for: server.state))
					.frame(width: 7, height: 7)
				Text("\(server.name)")
					.foregroundStyle(.primary)
				Text("/\(server.nickname)")
					.foregroundStyle(.secondary)
				if let lag = server.lag {
					Text("lag \(formatLag(lag))")
						.foregroundStyle(.secondary)
						.monospacedDigit()
				} else {
					Text(stateLabel(for: server.state))
						.foregroundStyle(.secondary)
				}
			} else {
				Circle()
					.fill(Color.gray)
					.frame(width: 7, height: 7)
				Text("No server")
					.foregroundStyle(.secondary)
			}

			Spacer()

			Text("\(totalChannels) channel\(totalChannels == 1 ? "" : "s")")
				.foregroundStyle(.secondary)
		}
		.font(.system(size: 11))
		.padding(.leading, 24)
		.padding(.trailing, 20)
		.padding(.vertical, 4)
		.frame(maxWidth: .infinity)
		.background(.bar)
	}

	private func dotColor(for state: Server.ConnectionState) -> Color {
		switch state {
		case .registered, .connected: return .green
		case .connecting:              return .yellow
		case .disconnecting:           return .orange
		case .disconnected:            return .gray
		}
	}

	private func stateLabel(for state: Server.ConnectionState) -> String {
		switch state {
		case .registered, .connected: return "connected"
		case .connecting:              return "connecting\u{2026}"
		case .disconnecting:           return "disconnecting\u{2026}"
		case .disconnected:            return "offline"
		}
	}

	private func formatLag(_ seconds: TimeInterval) -> String {
		let ms = seconds * 1000
		if ms < 1 { return "<1 ms" }
		if ms < 1000 { return "\(Int(ms)) ms" }
		return String(format: "%.2f s", seconds)
	}
}

// MARK: - Chat

@MainActor
struct ChatView: View {
	@Environment(AppState.self) private var appState
	@Environment(\.openWindow) private var openWindow
	@State private var draft: String = ""
	@State private var findQuery: String = ""
	@State private var isFinding: Bool = false
	@FocusState private var findFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			if let channel = appState.selectedChannel {
				TopicBar(channel: channel)
				Divider()
				if isFinding {
					FindBar(
						query: $findQuery,
						matchCount: matchCount(in: channel),
						onClose: closeFind
					)
					.focused($findFocused)
					Divider()
				}
				MessageList(channel: channel, findQuery: isFinding ? findQuery : "")
				TypingIndicatorView(channel: channel)
				Divider()
				InputBar(
					nickname: appState.selectedServer?.nickname ?? "",
					draft: $draft,
					suggestions: channel.users.map { $0.nickname },
					onTyping: { state in sendTyping(state, in: channel) }
				) {
					submit(channel: channel)
				}
			} else if let server = appState.selectedServer {
				ServerConsoleHeader(server: server)
				Divider()
				ServerMessageList(server: server)
				Divider()
				InputBar(
					nickname: server.nickname,
					draft: $draft,
					placeholder: "Type a command, e.g. /join #channel"
				) {
					submitServer(server: server)
				}
			} else {
				ContentUnavailableView {
					Label("No Channel Selected", systemImage: "bubble.left.and.bubble.right")
				} description: {
					Text("Select a server or channel from the sidebar to start chatting.")
				}
			}
		}
		.onChange(of: appState.selection) { oldValue, _ in
			draft = ""
			// Snap the just-left channel's read marker to its current last
			// message so returning later shows a "new" divider above anything
			// that arrived in the interim.
			if let oldID = oldValue, let leftChannel = appState.channel(byID: oldID) {
				leftChannel.lastReadMessageID = leftChannel.messages.last?.id
			}
			if let channel = appState.selectedChannel {
				channel.unreadCount = 0
				channel.highlightCount = 0
			}
			appState.refreshDockBadge()
		}
		.background {
			Button("Find") {
				isFinding = true
				findFocused = true
			}
			.keyboardShortcut("f", modifiers: .command)
			.hidden()

			Button("Detach") { detach() }
				.keyboardShortcut("d", modifiers: [.command, .shift])
				.hidden()

			Button("Find in All Channels") {
				appState.showingGlobalFind = true
			}
			.keyboardShortcut("f", modifiers: [.command, .shift])
			.hidden()
		}
	}

	private func matchCount(in channel: Channel) -> Int {
		guard !findQuery.isEmpty else { return 0 }
		let q = findQuery.lowercased()
		return channel.messages.reduce(0) { acc, msg in
			(msg.content.lowercased().contains(q) || msg.sender.lowercased().contains(q))
				? acc + 1
				: acc
		}
	}

	private func closeFind() {
		isFinding = false
		findQuery = ""
	}

	private func detach() {
		guard let channel = appState.selectedChannel else { return }
		openWindow(id: "channel", value: channel.id)
	}

	private func sendTyping(_ state: String, in channel: Channel) {
		guard let session = appState.selectedSession else { return }
		Task { try? await session.sendTyping(state: state, to: channel.name) }
	}

	private func submit(channel: Channel) {
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, let session = appState.selectedSession else { return }

		let sender = appState.selectedServer?.nickname ?? ""

		if trimmed.hasPrefix("/") {
			handleSlash(trimmed, session: session, channel: channel, sender: sender)
		} else {
			let markdownOn = UserDefaults.standard.object(forKey: PreferencesKeys.markdownInputEnabled) as? Bool ?? true
			let outgoing = markdownOn ? MarkdownInputTransform.markdownToIRC(trimmed) : trimmed
			// Split the same way the wire split runs, so local echo matches
			// exactly what the server receives (and what other clients see).
			for chunk in session.splitMessage(outgoing, for: channel.name) where !chunk.isEmpty {
				let localEcho = Message(sender: sender, content: chunk, kind: .privmsg)
				session.record(localEcho, in: channel)
			}
			Task {
				try? await session.sendMessage(to: channel.name, content: outgoing)
			}
		}
		draft = ""
	}

	private func submitServer(server: Server) {
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, let session = appState.selectedSession else { return }

		if trimmed.hasPrefix("/") {
			handleSlash(trimmed, session: session, channel: nil, sender: server.nickname)
		} else {
			// Without a channel context, treat raw text as a raw IRC line.
			Task { try? await session.connection.send(trimmed) }
		}
		draft = ""
	}

	private func handlePerformCommand(_ rest: String, session: IRCSession) {
		let arg = rest.trimmingCharacters(in: .whitespaces)
		if arg.isEmpty {
			let list = session.server.performCommands
			if list.isEmpty {
				session.recordServer(Message(sender: "*", content: "perform list is empty", kind: .server))
			} else {
				for (i, line) in list.enumerated() {
					session.recordServer(Message(sender: "*", content: "[\(i + 1)] \(line)", kind: .server))
				}
			}
			return
		}
		if arg == "-c" {
			session.clearPerform()
			session.recordServer(Message(sender: "*", content: "cleared perform list", kind: .server))
			return
		}
		if arg.hasPrefix("-r ") {
			let target = String(arg.dropFirst(3))
			let removed = session.removePerform(target)
			session.recordServer(Message(
				sender: "*",
				content: removed ? "removed from perform: \(target)" : "not in perform list: \(target)",
				kind: .server
			))
			return
		}
		session.addPerform(arg)
		session.recordServer(Message(sender: "*", content: "added to perform: \(arg)", kind: .server))
	}

	private func handleNotifyCommand(_ rest: String, session: IRCSession) {
		let arg = rest.trimmingCharacters(in: .whitespaces)
		if arg.isEmpty {
			let list = session.server.notifyList
			if list.isEmpty {
				session.recordServer(Message(sender: "*", content: "notify list is empty", kind: .server))
			} else {
				for nick in list {
					session.recordServer(Message(sender: "*", content: "watching: \(nick)", kind: .server))
				}
			}
			return
		}
		if arg.hasPrefix("-r ") {
			let target = String(arg.dropFirst(3)).trimmingCharacters(in: .whitespaces)
			let removed = session.removeNotify(target)
			session.recordServer(Message(
				sender: "*",
				content: removed ? "unwatched \(target)" : "not in notify list: \(target)",
				kind: .server
			))
			return
		}
		session.addNotify(arg)
		session.recordServer(Message(sender: "*", content: "watching \(arg)", kind: .server))
	}

	private func handleIgnore(_ rest: String, session: IRCSession) {
		let arg = rest.trimmingCharacters(in: .whitespaces)
		if arg.isEmpty {
			// List current ignores.
			let list = session.server.ignoreList
			if list.isEmpty {
				session.recordServer(Message(sender: "*", content: "ignore list is empty", kind: .server))
			} else {
				for entry in list {
					session.recordServer(Message(sender: "*", content: "ignoring: \(entry)", kind: .server))
				}
			}
			return
		}
		// Support "-r <pattern>" to remove.
		if arg.hasPrefix("-r ") {
			let target = String(arg.dropFirst(3)).trimmingCharacters(in: .whitespaces)
			let removed = session.removeIgnore(target)
			session.recordServer(Message(
				sender: "*",
				content: removed ? "unignored \(target)" : "not in ignore list: \(target)",
				kind: .server
			))
			return
		}
		session.addIgnore(arg)
		session.recordServer(Message(sender: "*", content: "ignoring \(arg)", kind: .server))
	}

	private func handleSlash(_ text: String, session: IRCSession, channel: Channel?, sender: String) {
		let parts = text.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
		let command = parts.first.map { $0.uppercased() } ?? ""
		let rest = parts.count > 1 ? String(parts[1]) : ""

		switch command {
		case "JOIN":
			let name = rest.isEmpty ? (channel?.name ?? "") : rest
			guard !name.isEmpty else { return }
			Task { try? await session.join(name) }
		case "PART":
			let name = rest.isEmpty ? (channel?.name ?? "") : rest
			guard !name.isEmpty else { return }
			Task { try? await session.part(name) }
		case "NICK":
			Task { try? await session.setNickname(rest) }
		case "QUIT", "DISCONNECT":
			// User-initiated — disable auto-reconnect and send QUIT cleanly.
			let reason = rest.isEmpty ? nil : rest
			Task { await session.disconnect(quitMessage: reason) }
		case "AWAY":
			let reason = rest.trimmingCharacters(in: .whitespaces)
			if reason.isEmpty {
				// Bare /away un-marks us.
				Task { try? await session.connection.send("AWAY") }
			} else {
				session.server.awayMessage = reason
				Task { try? await session.connection.send("AWAY :\(reason)") }
			}
		case "INVITE":
			let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
			guard let target = parts.first else { return }
			let channelName: String? = parts.count > 1 ? parts[1] : channel?.name
			guard let channelName = channelName else { return }
			Task { try? await session.connection.send("INVITE \(target) \(channelName)") }
		case "LIST":
			// Clear prior listing and open the browser; the sheet's task will
			// fire the LIST command against the server.
			session.server.channelListing = []
			session.server.isListingInProgress = true
			appState.showingChannelList = true
			let query = rest.isEmpty ? "LIST" : "LIST \(rest)"
			Task { try? await session.connection.send(query) }
		case "IGNORE":
			handleIgnore(rest, session: session)
		case "UNIGNORE":
			_ = session.removeIgnore(rest.trimmingCharacters(in: .whitespaces))
			session.recordServer(Message(
				sender: "*",
				content: "unignored \(rest)",
				kind: .server
			))
		case "NOTIFY":
			handleNotifyCommand(rest, session: session)
		case "PERFORM":
			handlePerformCommand(rest, session: session)
		case "ME":
			guard let channel = channel, !rest.isEmpty else { return }
			session.record(Message(sender: sender, content: rest, kind: .action), in: channel)
			Task { try? await session.sendAction(to: channel.name, action: rest) }
		case "MSG", "QUERY":
			let subs = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
			guard let first = subs.first else { return }
			let target = String(first)
			let body = subs.count > 1 ? String(subs[1]) : ""
			let query = session.openQuery(target)
			if !body.isEmpty {
				session.record(Message(sender: sender, content: body, kind: .privmsg), in: query)
				Task { try? await session.sendMessage(to: target, content: body) }
			}
			appState.selection = query.id
		default:
			Task { try? await session.connection.send(String(text.dropFirst())) }
		}
	}
}

struct ServerConsoleHeader: View {
	let server: Server

	var body: some View {
		HStack {
			Circle()
				.fill(stateColor)
				.frame(width: 8, height: 8)
			Text(server.name)
				.font(.headline)
			Text(server.host)
				.foregroundStyle(.secondary)
			if server.isAway {
				Label(server.awayMessage.map { "away — \($0)" } ?? "away",
				      systemImage: "moon.fill")
					.labelStyle(.titleAndIcon)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Text(server.nickname)
				.foregroundStyle(.secondary)
				.font(.system(.body, design: .monospaced))
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.regularMaterial)
	}

	private var stateColor: Color {
		switch server.state {
		case .registered, .connected: return .green
		case .connecting: return .yellow
		case .disconnecting: return .orange
		case .disconnected: return .gray
		}
	}
}

struct ServerMessageList: View {
	let server: Server

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 2) {
					ForEach(server.messages) { message in
						MessageRow(message: message)
							.id(message.id)
					}
				}
				.padding(12)
			}
			.onChange(of: server.messages.count) {
				if let last = server.messages.last {
					withAnimation(.easeOut(duration: 0.1)) {
						proxy.scrollTo(last.id, anchor: .bottom)
					}
				}
			}
		}
	}
}

@MainActor
struct TopicBar: View {
	let channel: Channel
	@Environment(AppState.self) private var appState
	@State private var isEditing = false
	@State private var draft = ""
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 8) {
			Text(channel.name)
				.font(.headline)
			Text("—")
				.foregroundStyle(.secondary)

			if isEditing {
				TextField("Topic", text: $draft)
					.textFieldStyle(.roundedBorder)
					.focused($focused)
					.onSubmit { submit() }
					.onExitCommand { cancel() }
				Button("Cancel") { cancel() }
					.buttonStyle(.borderless)
				Button("Set") { submit() }
					.buttonStyle(.borderedProminent)
			} else {
				Button {
					draft = channel.topic
					isEditing = true
					focused = true
				} label: {
					Text(channel.topic.isEmpty ? "(no topic — click to set)" : channel.topic)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				.buttonStyle(.plain)
				Spacer()
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.regularMaterial)
	}

	private func submit() {
		guard let session = appState.selectedSession else {
			cancel()
			return
		}
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		Task { try? await session.connection.send("TOPIC \(channel.name) :\(trimmed)") }
		isEditing = false
		draft = ""
	}

	private func cancel() {
		isEditing = false
		draft = ""
	}
}

struct MessageList: View {
	let channel: Channel
	var findQuery: String = ""
	@AppStorage(PreferencesKeys.showJoinsParts) private var showJoinsParts = true

	private var visibleMessages: [Message] {
		var messages: [Message]
		if showJoinsParts {
			messages = channel.messages
		} else {
			messages = channel.messages.filter { msg in
				switch msg.kind {
				case .join, .part, .quit, .nick: return false
				default: return true
				}
			}
		}
		if !findQuery.isEmpty {
			let q = findQuery.lowercased()
			messages = messages.filter {
				$0.content.lowercased().contains(q) || $0.sender.lowercased().contains(q)
			}
		}
		return messages
	}

	private var markerIndex: Int? {
		guard let markerID = channel.lastReadMessageID else { return nil }
		let idx = visibleMessages.firstIndex(where: { $0.id == markerID })
		// Only show the marker if there's at least one unread message after it.
		guard let idx = idx, idx < visibleMessages.count - 1 else { return nil }
		return idx
	}

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 2) {
					ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
						MessageRow(message: message)
							.id(message.id)
						if markerIndex == index {
							LineMarker()
						}
					}
				}
				.padding(12)
			}
			.onChange(of: channel.messages.count) {
				if let last = channel.messages.last {
					withAnimation(.easeOut(duration: 0.1)) {
						proxy.scrollTo(last.id, anchor: .bottom)
					}
				}
			}
		}
	}
}

/// In-channel "Find" bar. Triggered by Cmd+F in `ChatView`.
struct FindBar: View {
	@Binding var query: String
	let matchCount: Int
	let onClose: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(.secondary)
			TextField("Find in channel", text: $query)
				.textFieldStyle(.plain)
				.onExitCommand(perform: onClose)
				.onSubmit(onClose)
			if !query.isEmpty {
				Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Button(action: onClose) {
				Image(systemName: "xmark.circle.fill")
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.keyboardShortcut(.cancelAction)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(.regularMaterial)
	}
}

/// Horizontal divider showing where the user last read a channel. Appears
/// between the last-seen message and the first unread one.
struct LineMarker: View {
	var body: some View {
		HStack(spacing: 8) {
			Rectangle()
				.fill(Color.accentColor.opacity(0.6))
				.frame(height: 1)
			Text("new")
				.font(.caption.weight(.medium))
				.foregroundStyle(Color.accentColor)
			Rectangle()
				.fill(Color.accentColor.opacity(0.6))
				.frame(height: 1)
		}
		.padding(.vertical, 4)
	}
}

struct MessageRow: View {
	let message: Message
	@AppStorage(PreferencesKeys.nickColorsEnabled) private var nickColorsEnabled = true
	@AppStorage(PreferencesKeys.timestampFormat) private var timestampFormat: String = "system"
	@AppStorage(PreferencesKeys.linkPreviewsEnabled) private var linkPreviewsEnabled = true

	private func senderColor(_ nick: String) -> Color {
		nickColorsEnabled ? NickColor.color(for: nick) : Color.accentColor
	}

	private var timestampText: String {
		let date = message.timestamp
		switch timestampFormat {
		case "12h":
			let f = DateFormatter()
			f.dateFormat = "h:mm a"
			f.locale = Locale(identifier: "en_US_POSIX")
			return f.string(from: date)
		case "24h":
			let f = DateFormatter()
			f.dateFormat = "HH:mm"
			f.locale = Locale(identifier: "en_US_POSIX")
			return f.string(from: date)
		default:
			return date.formatted(date: .omitted, time: .shortened)
		}
	}

	private var actionAttributedString: AttributedString {
		var sender = AttributedString(message.sender + " ")
		sender.foregroundColor = senderColor(message.sender)
		var composed = sender
		composed.append(AttributedString.fromIRC(message.content))
		return composed
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			rowBody
			if linkPreviewsEnabled, let url = firstPreviewableURL(in: message.content) {
				LinkPreviewView(url: url)
					.padding(.leading, 68)
					.padding(.trailing, 16)
					.padding(.top, 2)
			}
		}
		.padding(.vertical, message.isHighlight ? 2 : 0)
		.padding(.horizontal, message.isHighlight ? 4 : 0)
		.background(
			message.isHighlight
				? Color.accentColor.opacity(0.15)
				: Color.clear
		)
		.overlay(alignment: .leading) {
			if message.isHighlight {
				Rectangle()
					.fill(Color.accentColor)
					.frame(width: 2)
			}
		}
	}

	@ViewBuilder
	private var rowBody: some View {
		HStack(alignment: .top, spacing: 8) {
			Text(timestampText)
				.font(.system(.caption, design: .monospaced))
				.foregroundStyle(.secondary)
				.frame(width: 52, alignment: .trailing)

			switch message.kind {
			case .privmsg:
				Text(message.sender)
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(senderColor(message.sender))
				Text(AttributedString.fromIRC(message.content))
					.font(.system(.body, design: .monospaced))
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			case .notice:
				Text("-\(message.sender)-")
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(.orange)
				Text(AttributedString.fromIRC(message.content))
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(.orange)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			case .action:
				Text("*")
					.foregroundStyle(.secondary)
				Text(actionAttributedString)
					.font(.system(.body, design: .monospaced))
					.italic()
					.frame(maxWidth: .infinity, alignment: .leading)
			default:
				Text("*")
					.foregroundStyle(.secondary)
				Text("\(message.sender) \(message.content)")
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}
}

// MARK: - Link preview

/// Returns the first HTTP/HTTPS URL found in `text`, or `nil`.
@MainActor
private let _linkDetector: NSDataDetector? = try? NSDataDetector(
	types: NSTextCheckingResult.CheckingType.link.rawValue
)

@MainActor
private func firstPreviewableURL(in text: String) -> URL? {
	guard let detector = _linkDetector, !text.isEmpty else { return nil }
	let range = NSRange(text.startIndex..., in: text)
	var found: URL?
	detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
		guard let url = match?.url, let scheme = url.scheme?.lowercased() else { return }
		if scheme == "http" || scheme == "https" {
			found = url
			stop.pointee = true
		}
	}
	return found
}

/// Inline preview for a single URL. Pulls data from
/// `AppState.linkPreviews`, kicks off a fetch on appear if nothing is
/// cached, and collapses to nothing on failure.
@MainActor
struct LinkPreviewView: View {
	let url: URL
	@Environment(AppState.self) private var appState

	var body: some View {
		let preview = appState.linkPreviews.preview(for: url)
		content(for: preview)
			.onAppear { appState.linkPreviews.fetchIfNeeded(url) }
	}

	@ViewBuilder
	private func content(for preview: LinkPreview?) -> some View {
		switch preview?.status {
		case .loaded:
			loadedBody(preview!)
		case .loading, .none:
			HStack(spacing: 6) {
				ProgressView().controlSize(.mini)
				Text(url.host ?? url.absoluteString)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.padding(.vertical, 2)
		case .failed:
			EmptyView()
		}
	}

	@ViewBuilder
	private func loadedBody(_ preview: LinkPreview) -> some View {
		if preview.isDirectImage {
			Link(destination: url) {
				AsyncImage(url: url) { phase in
					switch phase {
					case .success(let image):
						image
							.resizable()
							.scaledToFit()
							.frame(maxWidth: 400, maxHeight: 260, alignment: .leading)
							.clipShape(RoundedRectangle(cornerRadius: 6))
					case .failure:
						EmptyView()
					default:
						ProgressView().controlSize(.mini)
					}
				}
			}
			.buttonStyle(.plain)
		} else {
			Link(destination: url) {
				HStack(alignment: .top, spacing: 10) {
					if let imageURL = preview.imageURL {
						AsyncImage(url: imageURL) { phase in
							switch phase {
							case .success(let image):
								image
									.resizable()
									.scaledToFill()
									.frame(width: 60, height: 60)
									.clipShape(RoundedRectangle(cornerRadius: 4))
							default:
								RoundedRectangle(cornerRadius: 4)
									.fill(.quaternary)
									.frame(width: 60, height: 60)
							}
						}
					}
					VStack(alignment: .leading, spacing: 2) {
						Text(preview.siteName ?? url.host ?? url.absoluteString)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
						if let title = preview.title, !title.isEmpty {
							Text(title)
								.font(.system(.body, weight: .medium))
								.foregroundStyle(.primary)
								.lineLimit(2)
						}
						if let summary = preview.summary, !summary.isEmpty {
							Text(summary)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(3)
						}
					}
					Spacer(minLength: 0)
				}
				.padding(10)
				.background {
					RoundedRectangle(cornerRadius: 8)
						.fill(.regularMaterial)
				}
				.overlay {
					RoundedRectangle(cornerRadius: 8)
						.strokeBorder(.quaternary.opacity(0.8), lineWidth: 1)
				}
			}
			.buttonStyle(.plain)
		}
	}
}

struct InputBar: View {
	let nickname: String
	@Binding var draft: String
	var placeholder: String = "Message"
	var suggestions: [String] = []
	/// Invoked with `"active"` (throttled to once per 3 seconds while the
	/// draft is non-empty) and `"done"` (on submit or when the draft goes
	/// back to empty). `nil` disables typing notifications entirely.
	var onTyping: ((String) -> Void)? = nil
	let onSubmit: () -> Void

	// Completion cycle state.
	@State private var completionBase: String = ""
	@State private var completionPrefix: String = ""
	@State private var completionMatches: [String] = []
	@State private var completionIndex: Int = 0

	// Input history.
	@State private var history: [String] = []
	@State private var historyIndex: Int? = nil
	@State private var draftBeforeHistory: String = ""

	// Typing-indicator throttle.
	@State private var lastTypingSent: Date = .distantPast
	@State private var lastTypingState: String = "done"

	var body: some View {
		HStack(spacing: 6) {
			Text(nickname)
				.foregroundStyle(.secondary)
				.font(.system(.body, design: .monospaced))
			Image(systemName: "chevron.right")
				.foregroundStyle(.secondary)
				.font(.system(size: 10))

			TextField(placeholder, text: $draft)
				.textFieldStyle(.plain)
				.font(.system(.body, design: .monospaced))
				.onSubmit(handleSubmit)
				.onKeyPress(.tab) {
					handleTab()
					return .handled
				}
				.onKeyPress(.upArrow) {
					handleHistoryUp()
					return .handled
				}
				.onKeyPress(.downArrow) {
					handleHistoryDown()
					return .handled
				}
				.onChange(of: draft) { _, _ in
					autoReplaceEmojiShortcode()
					// Any external edit resets completion cycle.
					if completionPrefix.isEmpty {
						emitTypingForDraftChange()
						return
					}
					if !draft.hasSuffix(completionMatches.indices.contains(completionIndex)
						? completionMatches[completionIndex] : "") {
						resetCompletion()
					}
					emitTypingForDraftChange()
				}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.bar)
	}

	private func handleSubmit() {
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		if !trimmed.isEmpty {
			history.append(trimmed)
			if history.count > 100 { history.removeFirst(history.count - 100) }
		}
		historyIndex = nil
		resetCompletion()
		if lastTypingState != "done" {
			onTyping?("done")
			lastTypingState = "done"
		}
		onSubmit()
	}

	/// Throttled typing-indicator emitter. `active` once per 3 seconds while
	/// the draft is non-empty; `done` as soon as the draft is emptied.
	private func emitTypingForDraftChange() {
		guard onTyping != nil else { return }
		if draft.isEmpty {
			if lastTypingState != "done" {
				onTyping?("done")
				lastTypingState = "done"
			}
			return
		}
		let now = Date()
		if lastTypingState != "active" || now.timeIntervalSince(lastTypingSent) > 3 {
			onTyping?("active")
			lastTypingState = "active"
			lastTypingSent = now
		}
	}

	// MARK: - Tab completion

	private func handleTab() {
		let (base, prefix) = splitLastWord(draft)

		// Emoji branch: when the current word starts with `:`, Tab cycles
		// through shortcode matches (showing `:code:` in the draft); the
		// user then types/accepts to trigger the auto-replace into the
		// glyph itself.
		if prefix.hasPrefix(":") {
			let emojiPrefix = String(prefix.dropFirst())
			if completionPrefix.isEmpty || !completionPrefix.hasPrefix(":") {
				let matches = EmojiShortcodes.matches(prefix: emojiPrefix)
				guard !matches.isEmpty else { return }
				completionBase = base
				completionPrefix = prefix
				completionMatches = matches.map { ":\($0):" }
				completionIndex = 0
			} else {
				completionIndex = (completionIndex + 1) % completionMatches.count
			}
			draft = completionBase + completionMatches[completionIndex]
			return
		}

		// Nick branch (existing behavior).
		guard !suggestions.isEmpty else { return }
		if completionPrefix.isEmpty {
			let lowered = prefix.lowercased()
			let matches = suggestions.filter { $0.lowercased().hasPrefix(lowered) }
			guard !matches.isEmpty else { return }
			completionBase = base
			completionPrefix = prefix
			completionMatches = matches.sorted(by: { $0.lowercased() < $1.lowercased() })
			completionIndex = 0
		} else {
			completionIndex = (completionIndex + 1) % completionMatches.count
		}
		apply(match: completionMatches[completionIndex])
	}

	/// If the draft ends in `:shortcode:` for a known emoji, swap the whole
	/// run for the glyph. Called from `onChange(of: draft)`.
	private func autoReplaceEmojiShortcode() {
		guard draft.hasSuffix(":"), draft.count >= 3 else { return }
		// Find the matching opening `:` — there must be at least one character
		// in between and no whitespace.
		let trailing = draft.dropLast()
		guard let openIdx = trailing.lastIndex(of: ":") else { return }
		let shortcode = trailing[trailing.index(after: openIdx)...]
		guard !shortcode.isEmpty,
		      !shortcode.contains(" "),
		      !shortcode.contains(":") else { return }
		guard let emoji = EmojiShortcodes.emoji(for: String(shortcode)) else { return }
		// Replace the `:shortcode:` run with the emoji character.
		let replacementStart = openIdx
		let replacementEnd = draft.endIndex
		draft.replaceSubrange(replacementStart..<replacementEnd, with: emoji)
		resetCompletion()
	}

	private func apply(match: String) {
		// Add ": " after nick if it's at the start of the line (mIRC-style).
		let suffix = completionBase.isEmpty ? ": " : ""
		draft = completionBase + match + suffix
	}

	private func resetCompletion() {
		completionBase = ""
		completionPrefix = ""
		completionMatches = []
		completionIndex = 0
	}

	/// Split `s` at the last whitespace: returns (everythingUpToAndIncludingLastSpace, wordAfter).
	private func splitLastWord(_ s: String) -> (String, String) {
		if let lastSpace = s.lastIndex(where: { $0 == " " }) {
			let base = String(s[...lastSpace])
			let word = String(s[s.index(after: lastSpace)...])
			return (base, word)
		}
		return ("", s)
	}

	// MARK: - Input history

	private func handleHistoryUp() {
		guard !history.isEmpty else { return }
		if historyIndex == nil {
			draftBeforeHistory = draft
			historyIndex = history.count - 1
		} else if let idx = historyIndex, idx > 0 {
			historyIndex = idx - 1
		} else {
			return
		}
		if let idx = historyIndex {
			draft = history[idx]
		}
	}

	private func handleHistoryDown() {
		guard let idx = historyIndex else { return }
		if idx + 1 < history.count {
			historyIndex = idx + 1
			draft = history[idx + 1]
		} else {
			historyIndex = nil
			draft = draftBeforeHistory
		}
	}
}

// MARK: - Global find (cross-channel)

private struct GlobalFindMatch: Identifiable {
	let id = UUID()
	let serverName: String
	let channelName: String
	let channelID: String
	let message: Message
}

@MainActor
struct GlobalFindSheet: View {
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var query: String = ""
	@FocusState private var queryFocused: Bool

	private var matches: [GlobalFindMatch] {
		let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
		guard !needle.isEmpty else { return [] }
		var out: [GlobalFindMatch] = []
		for server in appState.servers {
			for channel in server.channels {
				for message in channel.messages
				where message.content.lowercased().contains(needle)
				   || message.sender.lowercased().contains(needle) {
					out.append(GlobalFindMatch(
						serverName: server.name,
						channelName: channel.name,
						channelID: channel.id,
						message: message
					))
				}
			}
		}
		// Newest first, capped so a huge scrollback doesn't freeze layout.
		return out.sorted(by: { $0.message.timestamp > $1.message.timestamp })
			.prefix(300)
			.map { $0 }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Find in All Channels")
					.font(.headline)
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.cancelAction)
			}
			.padding(.horizontal, 20)
			.padding(.top, 20)
			.padding(.bottom, 10)

			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField("Search across every channel and query\u{2026}", text: $query)
					.textFieldStyle(.plain)
					.focused($queryFocused)
					.onSubmit {
						if let first = matches.first { open(first) }
					}
			}
			.padding(10)
			.background(RoundedRectangle(cornerRadius: 6).fill(.thinMaterial))
			.padding(.horizontal, 20)
			.padding(.bottom, 8)

			Divider()

			if query.trimmingCharacters(in: .whitespaces).isEmpty {
				ContentUnavailableView {
					Label("Start typing", systemImage: "magnifyingglass")
				} description: {
					Text("Search content and senders across every channel and query.")
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if matches.isEmpty {
				ContentUnavailableView {
					Label("No matches", systemImage: "magnifyingglass")
				} description: {
					Text("Nothing in scrollback matches \u{201C}\(query)\u{201D}.")
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List(matches) { match in
					Button {
						open(match)
					} label: {
						GlobalFindMatchRow(match: match, needle: query)
					}
					.buttonStyle(.plain)
				}
				.listStyle(.plain)
			}
		}
		.frame(minWidth: 560, minHeight: 420)
		.onAppear { queryFocused = true }
	}

	private func open(_ match: GlobalFindMatch) {
		appState.selection = match.channelID
		dismiss()
	}
}

private struct GlobalFindMatchRow: View {
	let match: GlobalFindMatch
	let needle: String

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 6) {
				Text(match.serverName)
					.foregroundStyle(.secondary)
				Text("/")
					.foregroundStyle(.tertiary)
				Text(match.channelName)
					.foregroundStyle(.primary)
				Spacer()
				Text(match.message.timestamp, format: .dateTime.hour().minute())
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.font(.caption.weight(.medium))

			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text(match.message.sender)
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(.secondary)
				Text(snippet)
					.lineLimit(2)
			}
		}
		.padding(.vertical, 2)
	}

	/// Centre a ~80-char window around the first match so long lines don't
	/// push the hit off-screen.
	private var snippet: String {
		let content = match.message.content
		let needleLower = needle.lowercased()
		guard !needleLower.isEmpty,
		      let range = content.lowercased().range(of: needleLower)
		else { return content }
		let radius = 40
		let start = content.index(range.lowerBound, offsetBy: -radius, limitedBy: content.startIndex) ?? content.startIndex
		let end = content.index(range.upperBound, offsetBy: radius, limitedBy: content.endIndex) ?? content.endIndex
		let prefix = start > content.startIndex ? "\u{2026}" : ""
		let suffix = end < content.endIndex ? "\u{2026}" : ""
		return prefix + content[start..<end] + suffix
	}
}

// MARK: - Quick switcher (Cmd+K)

private struct QuickSwitcherItem: Identifiable {
	let id: String
	let serverName: String
	let channelName: String
	let isPrivateMessage: Bool
}

@MainActor
struct QuickSwitcherSheet: View {
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var query: String = ""
	@State private var selectedID: String?
	@FocusState private var queryFocused: Bool

	private var items: [QuickSwitcherItem] {
		var out: [QuickSwitcherItem] = []
		for server in appState.servers {
			for channel in server.channels {
				out.append(QuickSwitcherItem(
					id: channel.id,
					serverName: server.name,
					channelName: channel.name,
					isPrivateMessage: channel.isPrivateMessage
				))
			}
		}
		let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
		guard !needle.isEmpty else { return out }
		return out.filter {
			$0.channelName.lowercased().contains(needle) ||
			$0.serverName.lowercased().contains(needle)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Switch Channel")
					.font(.headline)
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.cancelAction)
			}
			.padding(.horizontal, 20)
			.padding(.top, 20)
			.padding(.bottom, 10)

			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField("Channel or server\u{2026}", text: $query)
					.textFieldStyle(.plain)
					.focused($queryFocused)
					.onSubmit { pickCurrent() }
			}
			.padding(10)
			.background(RoundedRectangle(cornerRadius: 6).fill(.thinMaterial))
			.padding(.horizontal, 20)
			.padding(.bottom, 8)

			Divider()

			List(items, selection: $selectedID) { item in
				HStack(spacing: 8) {
					Image(systemName: item.isPrivateMessage ? "person.circle" : "number")
						.foregroundStyle(.secondary)
					Text(item.channelName)
					Spacer()
					Text(item.serverName)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.contentShape(Rectangle())
				.tag(Optional(item.id))
				.onTapGesture {
					appState.selection = item.id
					dismiss()
				}
			}
			.listStyle(.plain)
		}
		.frame(minWidth: 480, minHeight: 360)
		.onAppear {
			queryFocused = true
			selectedID = items.first?.id
		}
		.onChange(of: query) { _, _ in
			selectedID = items.first?.id
		}
	}

	private func pickCurrent() {
		let id = selectedID ?? items.first?.id
		guard let id else { return }
		appState.selection = id
		dismiss()
	}
}

// MARK: - Quick join (Cmd+J)

@MainActor
struct QuickJoinSheet: View {
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var channel: String = ""
	@State private var serverID: String = ""
	@FocusState private var channelFocused: Bool

	private var eligibleServers: [Server] {
		appState.servers.filter { $0.isActive }
	}

	private var canSubmit: Bool {
		let trimmed = channel.trimmingCharacters(in: .whitespaces)
		return !trimmed.isEmpty && !serverID.isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Join Channel")
					.font(.headline)
				Spacer()
			}
			.padding(.horizontal, 20)
			.padding(.top, 20)
			.padding(.bottom, 10)

			Form {
				if eligibleServers.count > 1 {
					Picker("Server", selection: $serverID) {
						ForEach(eligibleServers) { server in
							Text(server.name).tag(server.id)
						}
					}
				}
				TextField("Channel", text: $channel, prompt: Text("#channel"))
					.focused($channelFocused)
					.onSubmit { submit() }
			}
			.formStyle(.grouped)
			.padding(.horizontal, 8)

			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Join") { submit() }
					.keyboardShortcut(.defaultAction)
					.disabled(!canSubmit)
			}
			.padding(20)
		}
		.frame(width: 420)
		.onAppear {
			channelFocused = true
			if serverID.isEmpty {
				serverID = appState.selectedServer?.id
					?? eligibleServers.first?.id
					?? ""
			}
		}
	}

	private func submit() {
		let trimmed = channel.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty,
		      let session = appState.sessions[serverID] else { return }
		let name = trimmed.hasPrefix("#") || trimmed.hasPrefix("&") ? trimmed : "#\(trimmed)"
		Task { try? await session.join(name) }
		dismiss()
	}
}

// MARK: - Channel list browser

@MainActor
struct ChannelListSheet: View {
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var filter: String = ""

	private var listings: [ChannelListing] {
		let all = appState.selectedServer?.channelListing ?? []
		guard !filter.isEmpty else { return all }
		let needle = filter.lowercased()
		return all.filter {
			$0.name.lowercased().contains(needle) ||
			$0.topic.lowercased().contains(needle)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Channel List")
					.font(.headline)
				if appState.selectedServer?.isListingInProgress == true {
					ProgressView().controlSize(.small)
				}
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.cancelAction)
			}
			.padding(.horizontal, 20)
			.padding(.top, 20)
			.padding(.bottom, 10)

			TextField("Filter channels or topics", text: $filter)
				.textFieldStyle(.roundedBorder)
				.padding(.horizontal, 20)
				.padding(.bottom, 10)

			Table(listings) {
				TableColumn("Channel") { listing in
					Text(listing.name).font(.system(.body, design: .monospaced))
				}
				.width(min: 120, ideal: 160)

				TableColumn("Users") { listing in
					Text("\(listing.userCount)")
				}
				.width(min: 60, ideal: 70)

				TableColumn("Topic") { listing in
					Text(listing.topic).lineLimit(1)
				}

				TableColumn("") { listing in
					Button("Join") {
						joinAndDismiss(listing.name)
					}
				}
				.width(min: 60, ideal: 70)
			}
			.frame(minHeight: 300)
		}
		.frame(width: 680, height: 480)
	}

	private func joinAndDismiss(_ name: String) {
		guard let session = appState.selectedSession else { return }
		Task { try? await session.join(name) }
		dismiss()
	}
}

// MARK: - User list

@MainActor
struct UserListView: View {
	@Environment(AppState.self) private var appState
	@AppStorage(PreferencesKeys.nickColorsEnabled) private var nickColorsEnabled = true

	private func color(for nick: String) -> Color {
		nickColorsEnabled ? NickColor.color(for: nick) : .primary
	}

	var body: some View {
		if let channel = appState.selectedChannel, !channel.users.isEmpty {
			List(channel.users) { user in
				HStack {
					Text(user.prefix)
						.foregroundStyle(.secondary)
						.font(.system(.body, design: .monospaced))
						.frame(width: 10, alignment: .leading)
					Text(user.nickname)
						.font(.system(.body, design: .monospaced))
						.foregroundStyle(color(for: user.nickname))
				}
				.contextMenu {
					userRowMenu(for: user.nickname, channelName: channel.name)
				}
			}
		} else {
			ContentUnavailableView("No Users", systemImage: "person.2")
		}
	}

	@ViewBuilder
	private func userRowMenu(for nick: String, channelName: String) -> some View {
		Button("Whois") { whois(nick) }
		Button("Query") { query(nick) }
		Divider()
		Menu("Channel mode") {
			Button("Op")       { setMode(channelName, "+o", nick) }
			Button("Deop")     { setMode(channelName, "-o", nick) }
			Button("Voice")    { setMode(channelName, "+v", nick) }
			Button("Devoice")  { setMode(channelName, "-v", nick) }
		}
		Divider()
		Button("Kick", role: .destructive) { kick(channelName, nick) }
		Button("Kick and Ban", role: .destructive) { kickBan(channelName, nick) }
		Divider()
		Button("Ignore") { ignore(nick) }
	}

	// MARK: - Actions

	private func whois(_ nick: String) {
		guard let session = appState.selectedSession else { return }
		Task { try? await session.connection.send("WHOIS \(nick)") }
	}

	private func query(_ nick: String) {
		guard let session = appState.selectedSession else { return }
		let channel = session.openQuery(nick)
		appState.selection = channel.id
	}

	private func setMode(_ channelName: String, _ modeChange: String, _ nick: String) {
		guard let session = appState.selectedSession else { return }
		Task { try? await session.connection.send("MODE \(channelName) \(modeChange) \(nick)") }
	}

	private func kick(_ channelName: String, _ nick: String) {
		guard let session = appState.selectedSession else { return }
		Task { try? await session.connection.send("KICK \(channelName) \(nick)") }
	}

	private func kickBan(_ channelName: String, _ nick: String) {
		guard let session = appState.selectedSession else { return }
		Task {
			try? await session.connection.send("MODE \(channelName) +b \(nick)!*@*")
			try? await session.connection.send("KICK \(channelName) \(nick)")
		}
	}

	private func ignore(_ nick: String) {
		guard let session = appState.selectedSession else { return }
		session.addIgnore(nick)
		session.recordServer(Message(sender: "*", content: "ignoring \(nick)", kind: .server))
	}
}

// MARK: - Nick colors

/// Stable nickname → color mapping. Hashes the lowercased nick with FNV-1a
/// (not Swift's randomized `Hasher`) so the same nick always renders with
/// the same color across launches and across machines.
enum NickColor {
	/// Curated palette of 16 hues that remain legible on both light and
	/// dark backgrounds. Avoids pure black/white/grey.
	static let palette: [Color] = [
		Color(red: 0.23, green: 0.49, blue: 1.00),   // blue
		Color(red: 0.18, green: 0.72, blue: 0.45),   // green
		Color(red: 0.94, green: 0.55, blue: 0.18),   // orange
		Color(red: 0.71, green: 0.35, blue: 0.77),   // purple
		Color(red: 0.18, green: 0.74, blue: 0.77),   // teal
		Color(red: 0.89, green: 0.35, blue: 0.52),   // pink
		Color(red: 0.83, green: 0.69, blue: 0.22),   // gold
		Color(red: 0.42, green: 0.35, blue: 0.80),   // slate blue
		Color(red: 0.76, green: 0.33, blue: 0.31),   // brick
		Color(red: 0.48, green: 0.60, blue: 0.31),   // olive
		Color(red: 0.35, green: 0.65, blue: 0.84),   // sky
		Color(red: 0.82, green: 0.42, blue: 0.54),   // rose
		Color(red: 0.48, green: 0.62, blue: 0.62),   // sage
		Color(red: 0.88, green: 0.55, blue: 0.23),   // ochre
		Color(red: 0.56, green: 0.43, blue: 0.72),   // lavender
		Color(red: 0.31, green: 0.62, blue: 0.49),   // jade
	]

	static func color(for nickname: String) -> Color {
		guard !nickname.isEmpty else { return palette[0] }
		var hash: UInt32 = 2_166_136_261
		for byte in nickname.lowercased().utf8 {
			hash ^= UInt32(byte)
			hash = hash &* 16_777_619
		}
		return palette[Int(hash % UInt32(palette.count))]
	}
}

// MARK: - mIRC control-code rendering

extension AttributedString {
	/// Builds a styled `AttributedString` from an IRC message body by
	/// parsing mIRC control codes (`^B`, `^I`, `^U`, `^R`, `^O`, `^K[,bg]`,
	/// `^S`) and mapping them onto SwiftUI attributes. URLs and email
	/// addresses are also detected and marked as clickable links.
	static func fromIRC(_ text: String) -> AttributedString {
		let runs = IRCFormatting.parse(text)
		var result = AttributedString()
		for run in runs {
			var piece = AttributedString(run.text)

			// Font: monospaced + optional bold/italic composition.
			var font = Font.system(.body, design: .monospaced)
			if run.style.bold { font = font.bold() }
			if run.style.italic { font = font.italic() }
			piece.font = font

			if run.style.underline { piece.underlineStyle = .single }
			if run.style.strikethrough { piece.strikethroughStyle = .single }

			// Reverse swaps fg/bg before we resolve colors.
			var fgIdx = run.style.foreground
			var bgIdx = run.style.background
			if run.style.reverse {
				(fgIdx, bgIdx) = (bgIdx ?? 0, fgIdx ?? 99)
			}
			if let fg = fgIdx, let rgb = IRCFormatting.color(for: fg) {
				piece.foregroundColor = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
			}
			if let bg = bgIdx, let rgb = IRCFormatting.color(for: bg) {
				piece.backgroundColor = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
			}

			result.append(piece)
		}
		applyLinkDetection(to: &result)
		return result
	}

	/// Scans the already-styled `attributed` for URLs and email addresses
	/// and overlays `.link`, underline, and accent color on matching ranges.
	private static func applyLinkDetection(to attributed: inout AttributedString) {
		let plain = String(attributed.characters)
		guard !plain.isEmpty else { return }
		guard let detector = try? NSDataDetector(
			types: NSTextCheckingResult.CheckingType.link.rawValue
		) else { return }

		let fullRange = NSRange(plain.startIndex..., in: plain)
		detector.enumerateMatches(in: plain, options: [], range: fullRange) { match, _, _ in
			guard let match = match, let url = match.url else { return }
			guard let swiftRange = Range(match.range, in: plain) else { return }
			let startOffset = plain.distance(from: plain.startIndex, to: swiftRange.lowerBound)
			let length = plain.distance(from: swiftRange.lowerBound, to: swiftRange.upperBound)
			let startIdx = attributed.characters.index(
				attributed.characters.startIndex,
				offsetBy: startOffset
			)
			let endIdx = attributed.characters.index(startIdx, offsetBy: length)
			attributed[startIdx..<endIdx].link = url
			attributed[startIdx..<endIdx].underlineStyle = .single
			attributed[startIdx..<endIdx].foregroundColor = Color.accentColor
		}
	}
}

// MARK: - Detached channel window

/// Single-channel view presented in its own window via the `channel`
/// `WindowGroup` scene. Mirrors the main-window `ChatView` but without
/// a sidebar, inspector, or selection coupling. Shares `AppState` by
/// reference, so messages / topic / user-list updates stay in sync.
@MainActor
struct DetachedChannelView: View {
	let channelID: String
	@Environment(AppState.self) private var appState
	@State private var draft: String = ""

	var body: some View {
		if let channel = appState.channel(byID: channelID),
		   let session = session(for: channel) {
			VStack(spacing: 0) {
				TopicBar(channel: channel)
				Divider()
				MessageList(channel: channel)
				TypingIndicatorView(channel: channel)
				Divider()
				InputBar(
					nickname: session.server.nickname,
					draft: $draft,
					suggestions: channel.users.map(\.nickname),
					onTyping: { state in
						Task { try? await session.sendTyping(state: state, to: channel.name) }
					}
				) {
					submit(channel: channel, session: session)
				}
			}
			.navigationTitle(channel.name)
		} else {
			ContentUnavailableView {
				Label("Channel not available", systemImage: "bubble.left")
			} description: {
				Text("The channel was closed or its server was removed.")
			}
		}
	}

	private func session(for channel: Channel) -> IRCSession? {
		for server in appState.servers where server.channels.contains(where: { $0.id == channel.id }) {
			return appState.sessions[server.id]
		}
		return nil
	}

	private func submit(channel: Channel, session: IRCSession) {
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		let sender = session.server.nickname

		if trimmed.hasPrefix("/") {
			// Detached windows forward slash input as raw IRC protocol. Full
			// slash-command dispatch (which mutates sidebar state) lives in the
			// main-window `ChatView`.
			Task { try? await session.connection.send(String(trimmed.dropFirst())) }
		} else {
			let markdownOn = UserDefaults.standard.object(forKey: PreferencesKeys.markdownInputEnabled) as? Bool ?? true
			let outgoing = markdownOn ? MarkdownInputTransform.markdownToIRC(trimmed) : trimmed
			for chunk in session.splitMessage(outgoing, for: channel.name) where !chunk.isEmpty {
				session.record(Message(sender: sender, content: chunk, kind: .privmsg), in: channel)
			}
			Task { try? await session.sendMessage(to: channel.name, content: outgoing) }
		}
		draft = ""
	}
}
