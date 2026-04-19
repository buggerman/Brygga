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
		.sheet(isPresented: $appState.showingConnectSheet) {
			ConnectSheet()
				.environment(appState)
		}
		.sheet(isPresented: $appState.showingChannelList) {
			ChannelListSheet()
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

@MainActor
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
					draft: $draft,
					suggestions: channel.users.map { $0.nickname }
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
			appState.refreshDockBadge()
		}
	}

	private func submit(channel: Channel) {
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, let session = appState.selectedSession else { return }

		let sender = appState.selectedServer?.nickname ?? ""

		if trimmed.hasPrefix("/") {
			handleSlash(trimmed, session: session, channel: channel, sender: sender)
		} else {
			// Split the same way the wire split runs, so local echo matches
			// exactly what the server receives (and what other clients see).
			for chunk in session.splitMessage(trimmed, for: channel.name) where !chunk.isEmpty {
				let localEcho = Message(sender: sender, content: chunk, kind: .privmsg)
				session.record(localEcho, in: channel)
			}
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
	@AppStorage(PreferencesKeys.showJoinsParts) private var showJoinsParts = true

	private var visibleMessages: [Message] {
		if showJoinsParts { return channel.messages }
		return channel.messages.filter { msg in
			switch msg.kind {
			case .join, .part, .quit, .nick: return false
			default: return true
			}
		}
	}

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 2) {
					ForEach(visibleMessages) { message in
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

	private var actionAttributedString: AttributedString {
		var sender = AttributedString(message.sender + " ")
		sender.foregroundColor = NickColor.color(for: message.sender)
		var composed = sender
		composed.append(AttributedString.fromIRC(message.content))
		return composed
	}

	var body: some View {
		rowBody
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
			Text(message.timestamp.formatted(date: .omitted, time: .shortened))
				.font(.system(.caption, design: .monospaced))
				.foregroundStyle(.secondary)
				.frame(width: 52, alignment: .trailing)

			switch message.kind {
			case .privmsg:
				Text(message.sender)
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(NickColor.color(for: message.sender))
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

struct InputBar: View {
	let nickname: String
	@Binding var draft: String
	var placeholder: String = "Message"
	var suggestions: [String] = []
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
					// Any external edit resets completion cycle.
					if completionPrefix.isEmpty { return }
					if !draft.hasSuffix(completionMatches.indices.contains(completionIndex)
						? completionMatches[completionIndex] : "") {
						resetCompletion()
					}
				}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private func handleSubmit() {
		let trimmed = draft.trimmingCharacters(in: .whitespaces)
		if !trimmed.isEmpty {
			history.append(trimmed)
			if history.count > 100 { history.removeFirst(history.count - 100) }
		}
		historyIndex = nil
		resetCompletion()
		onSubmit()
	}

	// MARK: - Tab completion

	private func handleTab() {
		guard !suggestions.isEmpty else { return }

		// Starting a new cycle: find the word-under-cursor prefix.
		if completionPrefix.isEmpty {
			let (base, prefix) = splitLastWord(draft)
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
						.foregroundStyle(NickColor.color(for: user.nickname))
				}
			}
		} else {
			ContentUnavailableView("No Users", systemImage: "person.2")
		}
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
