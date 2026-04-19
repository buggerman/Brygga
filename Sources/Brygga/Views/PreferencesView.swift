/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import AppKit
import BryggaCore

/// The root Preferences window, wired from `BryggaApp`'s `Settings` scene.
struct PreferencesView: View {
	var body: some View {
		TabView {
			GeneralPane()
				.tabItem { Label("General", systemImage: "gear") }
			IdentityPane()
				.tabItem { Label("Identity", systemImage: "person.crop.circle") }
			AppearancePane()
				.tabItem { Label("Appearance", systemImage: "paintbrush") }
			NotificationsPane()
				.tabItem { Label("Notifications", systemImage: "bell") }
			IgnorePane()
				.tabItem { Label("Ignore", systemImage: "hand.raised") }
			LoggingPane()
				.tabItem { Label("Logging", systemImage: "doc.text") }
			ServersPane()
				.tabItem { Label("Servers", systemImage: "server.rack") }
		}
		.frame(width: 600, height: 440)
	}
}

// MARK: - General

struct GeneralPane: View {
	@AppStorage(PreferencesKeys.showJoinsParts) private var showJoinsParts = true
	@AppStorage(PreferencesKeys.autoJoinOnInvite) private var autoJoinOnInvite = false
	@AppStorage(PreferencesKeys.linkPreviewsEnabled) private var linkPreviewsEnabled = true
	@AppStorage(PreferencesKeys.markdownInputEnabled) private var markdownInputEnabled = true
	@AppStorage(PreferencesKeys.shareTypingEnabled) private var shareTypingEnabled = true
	@AppStorage(PreferencesKeys.defaultLeaveMessage) private var defaultLeaveMessage =
		PreferencesKeys.defaultLeaveMessageFallback

	var body: some View {
		Form {
			Section("Channels") {
				Toggle("Show joins and parts in channels", isOn: $showJoinsParts)
				Toggle("Auto-join channels when invited", isOn: $autoJoinOnInvite)
			}
			Section {
				Toggle("Fetch link previews for URLs in messages", isOn: $linkPreviewsEnabled)
			} footer: {
				Text("Fetches the page title, description, and thumbnail for URLs shared in chat. Each fetch discloses your IP to the remote host.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section {
				Toggle("Markdown-style input formatting", isOn: $markdownInputEnabled)
			} footer: {
				Text("Converts `*bold*`, `_italic_`, and `~strike~` to mIRC control codes as the message is sent.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section {
				Toggle("Share typing indicator with others", isOn: $shareTypingEnabled)
			} footer: {
				Text("Sends an IRCv3 `+typing` tag so other users can see when you're composing a message. Incoming typing indicators from others are always shown regardless of this setting.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section {
				TextField("Default leave message", text: $defaultLeaveMessage, axis: .vertical)
					.lineLimit(2...4)
			} footer: {
				Text("Appended to `/leave`, `/part`, and Cmd+W when you don't supply your own reason. Clear the field to leave without any reason.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}

// MARK: - Identity

struct IdentityPane: View {
	@AppStorage(PreferencesKeys.defaultNickname) private var defaultNickname: String = ""
	@AppStorage(PreferencesKeys.defaultUserName) private var defaultUserName: String = ""
	@AppStorage(PreferencesKeys.defaultRealName) private var defaultRealName: String = ""

	var body: some View {
		Form {
			Section {
				TextField("Nickname",  text: $defaultNickname,  prompt: Text(NSUserName()))
				TextField("User name", text: $defaultUserName,  prompt: Text("same as nickname"))
				TextField("Real name", text: $defaultRealName,  prompt: Text("optional"))
			} header: {
				Text("Default identity")
			} footer: {
				Text("Pre-fills the Connect sheet when you add a new server.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}

// MARK: - Appearance

struct AppearancePane: View {
	@AppStorage(PreferencesKeys.timestampFormat) private var timestampFormat: String = "system"
	@AppStorage(PreferencesKeys.nickColorsEnabled) private var nickColorsEnabled: Bool = true

	var body: some View {
		Form {
			Section("Timestamps") {
				Picker("Format", selection: $timestampFormat) {
					Text("System default").tag("system")
					Text("12-hour").tag("12h")
					Text("24-hour").tag("24h")
				}
			}
			Section("Nicknames") {
				Toggle("Colorize nicknames in messages and user list", isOn: $nickColorsEnabled)
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}

// MARK: - Notifications

struct NotificationsPane: View {
	@AppStorage(PreferencesKeys.highlightKeywordsRaw) private var keywordsRaw: String = ""

	var body: some View {
		Form {
			Section {
				TextEditor(text: $keywordsRaw)
					.font(.system(.body, design: .monospaced))
					.frame(minHeight: 140)
			} header: {
				Text("Highlight keywords")
			} footer: {
				Text("One keyword per line. Messages mentioning any of these trigger a highlight and notification. Your own nickname is always a highlight.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}

// MARK: - Ignore

@MainActor
struct IgnorePane: View {
	@Environment(AppState.self) private var appState
	@State private var selectedServerID: String?
	@State private var newEntry: String = ""

	private var selectedServer: Server? {
		guard let id = selectedServerID else { return nil }
		return appState.servers.first { $0.id == id }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Picker("Server", selection: $selectedServerID) {
				Text("—").tag(String?.none)
				ForEach(appState.servers) { server in
					Text(server.name).tag(Optional(server.id))
				}
			}
			.padding(.horizontal, 20)
			.padding(.top, 16)

			if let server = selectedServer {
				List {
					ForEach(server.ignoreList, id: \.self) { entry in
						Text(entry)
							.font(.system(.body, design: .monospaced))
					}
					.onDelete { indices in
						let targets = indices.map { server.ignoreList[$0] }
						for target in targets {
							_ = appState.sessions[server.id]?.removeIgnore(target)
						}
					}
				}
				.frame(minHeight: 200)

				HStack {
					TextField("nickname or hostmask (e.g. *!*@spam.example.com)",
					          text: $newEntry)
						.textFieldStyle(.roundedBorder)
						.onSubmit { addIgnore(to: server) }
					Button("Add") { addIgnore(to: server) }
						.disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
				}
				.padding(.horizontal, 20)
				.padding(.bottom, 16)
			} else {
				Spacer()
				ContentUnavailableView(
					"No server selected",
					systemImage: "server.rack",
					description: Text("Add a server first, or pick one from the menu above.")
				)
				Spacer()
			}
		}
		.onAppear {
			if selectedServerID == nil {
				selectedServerID = appState.servers.first?.id
			}
		}
	}

	private func addIgnore(to server: Server) {
		let trimmed = newEntry.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		appState.sessions[server.id]?.addIgnore(trimmed)
		newEntry = ""
	}
}

// MARK: - Logging

struct LoggingPane: View {
	@AppStorage(PreferencesKeys.diskLoggingEnabled) private var diskLoggingEnabled = true

	private var logFolder: URL {
		let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
		return docs.appendingPathComponent("Brygga Logs", isDirectory: true)
	}

	var body: some View {
		Form {
			Section("Disk logging") {
				Toggle("Write plain-text logs", isOn: $diskLoggingEnabled)
			}
			Section {
				LabeledContent("Folder") {
					Text(logFolder.path)
						.font(.system(.caption, design: .monospaced))
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
						.lineLimit(1)
						.truncationMode(.middle)
				}
				HStack {
					Spacer()
					Button("Reveal in Finder") {
						try? FileManager.default.createDirectory(
							at: logFolder,
							withIntermediateDirectories: true
						)
						NSWorkspace.shared.activateFileViewerSelecting([logFolder])
					}
				}
			} footer: {
				Text("Logs land under Brygga Logs/<network>/<channel>.log. Each line is timestamped and human-readable.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}

// MARK: - Servers

@MainActor
struct ServersPane: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if appState.servers.isEmpty {
				Spacer()
				ContentUnavailableView(
					"No servers",
					systemImage: "server.rack",
					description: Text("Use Server → New Server\u{2026} in the main window to add one.")
				)
				Spacer()
			} else {
				List {
					ForEach(appState.servers) { server in
						ServerRowDetail(server: server)
							.padding(.vertical, 2)
					}
				}
			}
		}
	}
}

@MainActor
private struct ServerRowDetail: View {
	@Environment(AppState.self) private var appState
	let server: Server

	var body: some View {
		HStack(alignment: .top) {
			VStack(alignment: .leading, spacing: 2) {
				Text(server.name).font(.headline)
				Text("\(server.host):\(server.port)\(server.useTLS ? " · TLS" : "")")
					.font(.caption)
					.foregroundStyle(.secondary)
				if !server.nickname.isEmpty {
					Text("nick: \(server.nickname)")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				let joined = server.channels.filter { $0.isJoined && !$0.isPrivateMessage }.map(\.name)
				if !joined.isEmpty {
					Text("joined: \(joined.joined(separator: ", "))")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				if !server.performCommands.isEmpty {
					Text("perform: \(server.performCommands.count) line(s)")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			Button(role: .destructive) {
				appState.removeServer(id: server.id)
			} label: {
				Label("Remove", systemImage: "trash")
			}
			.buttonStyle(.borderless)
		}
	}
}
