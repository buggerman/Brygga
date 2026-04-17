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
	}
}

// MARK: - Placeholder views

struct SidebarView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		VStack {
			if appState.servers.isEmpty {
				ContentUnavailableView {
					Label("No Servers", systemImage: "network")
				} description: {
					Text("Add a server to get started.")
				} actions: {
					Button("Add Server\u{2026}") { }
				}
			} else {
				List(selection: Binding(
					get: { appState.selection },
					set: { appState.selection = $0 }
				)) {
					Text("Server list goes here")
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

struct ChatView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		VStack(spacing: 0) {
			if let channel = appState.selectedChannel {
				// Topic bar
				HStack {
					Text(channel.name)
						.font(.headline)
					Text("—")
						.foregroundStyle(.secondary)
					Text(channel.topic.isEmpty ? "No topic set" : channel.topic)
						.foregroundStyle(.secondary)
						.lineLimit(1)
					Spacer()
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.background(.regularMaterial)

				Divider()

				// Message list
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 2) {
						ForEach(channel.messages) { message in
							MessageRow(message: message)
						}
					}
					.padding(12)
				}

				Divider()

				// Input
				HStack {
					Text(appState.selectedServer?.nickname ?? "")
						.foregroundStyle(.secondary)
					Image(systemName: "chevron.right")
						.foregroundStyle(.secondary)
						.font(.system(size: 10))
					TextField("Message", text: .constant(""))
						.textFieldStyle(.plain)
						.font(.system(.body, design: .monospaced))
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
			} else {
				ContentUnavailableView {
					Label("No Channel Selected", systemImage: "bubble.left.and.bubble.right")
				} description: {
					Text("Select a channel from the sidebar to start chatting.")
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

			Text(message.sender)
				.font(.system(.body, design: .monospaced))
				.foregroundStyle(Color.accentColor)

			Text(message.content)
				.font(.system(.body, design: .monospaced))
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}

struct UserListView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		if let channel = appState.selectedChannel, !channel.users.isEmpty {
			List(channel.users) { user in
				HStack {
					Text(user.prefix)
						.foregroundStyle(.secondary)
					Text(user.nickname)
				}
			}
		} else {
			ContentUnavailableView("No Users", systemImage: "person.2")
		}
	}
}
