/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import BryggaCore

struct ContentView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		@Bindable var appState = appState

		NavigationSplitView {
			SidebarView()
				.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 400)
		} content: {
			ChatView()
				.navigationSplitViewColumnWidth(min: 400, ideal: 800)
		} detail: {
			UserListView()
				.navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
		}
		.navigationSplitViewStyle(.balanced)
		.sheet(isPresented: $appState.showingConnectSheet) {
			ConnectSheet()
				.environment(appState)
		}
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
					ForEach(appState.servers) { server in
						ServerRow(server: server)
							.tag(Optional(server.id))

						ForEach(server.channels) { channel in
							ChannelRow(channel: channel)
								.tag(Optional(channel.id))
								.padding(.leading, 12)
						}
					}
				}
				.listStyle(.sidebar)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
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

	var body: some View {
		HStack {
			Image(systemName: channel.isPrivateMessage ? "person.fill" : "number")
				.font(.system(size: 10))
				.foregroundStyle(.secondary)
				.frame(width: 14)

			Text(channel.name)
				.lineLimit(1)

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

// MARK: - Chat

struct ChatView: View {
	@Environment(AppState.self) private var appState
	@State private var draft: String = ""

	var body: some View {
		VStack(spacing: 0) {
			if let channel = appState.selectedChannel {
				TopicBar(channel: channel)
				Divider()
				MessageList(channel: channel)
				Divider()
				InputBar(
					nickname: appState.selectedServer?.nickname ?? "",
					draft: $draft
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
		.onChange(of: appState.selection) {
			draft = ""
			if let channel = appState.selectedChannel {
				channel.unreadCount = 0
				channel.highlightCount = 0
			}
		}
	}

	private func submit(channel: Channel) {
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, let session = appState.selectedSession else { return }

		let sender = appState.selectedServer?.nickname ?? ""

		if trimmed.hasPrefix("/") {
			handleSlash(trimmed, session: session, channel: channel, sender: sender)
		} else {
			let localEcho = Message(sender: sender, content: trimmed, kind: .privmsg)
			channel.messages.append(localEcho)
			Task {
				try? await session.sendMessage(to: channel.name, content: trimmed)
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
		case "ME":
			guard let channel = channel, !rest.isEmpty else { return }
			channel.messages.append(Message(sender: sender, content: rest, kind: .action))
			Task { try? await session.sendAction(to: channel.name, action: rest) }
		case "MSG":
			let subs = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
			if subs.count == 2 {
				let target = String(subs[0])
				let body = String(subs[1])
				Task { try? await session.sendMessage(to: target, content: body) }
			}
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

struct TopicBar: View {
	let channel: Channel

	var body: some View {
		HStack {
			Text(channel.name)
				.font(.headline)
			if !channel.topic.isEmpty {
				Text("—")
					.foregroundStyle(.secondary)
				Text(channel.topic)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer()
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.regularMaterial)
	}
}

struct MessageList: View {
	let channel: Channel

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 2) {
					ForEach(channel.messages) { message in
						MessageRow(message: message)
							.id(message.id)
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

struct MessageRow: View {
	let message: Message

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Text(message.timestamp.formatted(date: .omitted, time: .shortened))
				.font(.system(.caption, design: .monospaced))
				.foregroundStyle(.secondary)
				.frame(width: 52, alignment: .trailing)

			switch message.kind {
			case .privmsg:
				Text(message.sender)
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(Color.accentColor)
				Text(message.content)
					.font(.system(.body, design: .monospaced))
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			case .notice:
				Text("-\(message.sender)-")
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(.orange)
				Text(message.content)
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(.orange)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			case .action:
				Text("*")
					.foregroundStyle(.secondary)
				Text("\(message.sender) \(message.content)")
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

struct InputBar: View {
	let nickname: String
	@Binding var draft: String
	var placeholder: String = "Message"
	let onSubmit: () -> Void

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
				.onSubmit(onSubmit)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}
}

// MARK: - User list

struct UserListView: View {
	@Environment(AppState.self) private var appState

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
				}
			}
		} else {
			ContentUnavailableView("No Users", systemImage: "person.2")
		}
	}
}
