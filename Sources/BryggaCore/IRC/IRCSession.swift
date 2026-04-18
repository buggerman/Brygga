/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation

/// Bridges an `IRCConnection` to an observable `Server` model.
///
/// - Consumes the connection's `messages` and `stateChanges` streams.
/// - Translates protocol events (JOIN, PART, PRIVMSG, TOPIC, NAMES, etc.)
///   into mutations on `Server` / `Channel` / `User` models.
/// - Exposes convenience command methods (`join`, `part`, `sendMessage`).
///
/// Runs on the main actor so SwiftUI observation works without hops.
@MainActor
public final class IRCSession {

	public let server: Server
	public let connection: IRCConnection

	/// Channels to join automatically once the server registration completes.
	public var autoJoinChannels: [String] = []

	/// Invoked whenever the channel or join-state set changes — the UI can
	/// subscribe to persist the change.
	public var onChannelsChanged: (() -> Void)?

	/// If true, the session automatically reconnects after unexpected drops
	/// with exponential backoff. User-initiated disconnects (via `stop()`)
	/// suppress reconnect regardless.
	public var autoReconnect: Bool = true

	/// Set when the user explicitly disconnects. Blocks auto-reconnect.
	private var userDisconnected: Bool = false

	/// Backoff attempt counter. Reset to zero on successful registration.
	private var reconnectAttempt: Int = 0

	/// Pending reconnect Task, so we can cancel it.
	private var reconnectTask: Task<Void, Never>?

	private var runTask: Task<Void, Never>?

	public init(server: Server, connection: IRCConnection) {
		self.server = server
		self.connection = connection
	}

	// MARK: - Lifecycle

	public func start() {
		guard runTask == nil else { return }

		let stateTask = Task { @MainActor [weak self] in
			guard let self = self else { return }
			for await state in self.connection.stateChanges {
				self.syncState(state)
			}
		}

		let messageTask = Task { @MainActor [weak self] in
			guard let self = self else { return }
			for await message in self.connection.messages {
				self.handle(message)
			}
		}

		runTask = Task { [stateTask, messageTask] in
			_ = await (stateTask.value, messageTask.value)
		}
	}

	public func stop() {
		userDisconnected = true
		reconnectTask?.cancel()
		reconnectTask = nil
		runTask?.cancel()
		runTask = nil
	}

	// MARK: - Commands

	public func join(_ channel: String) async throws {
		try await connection.send("JOIN \(channel)")
	}

	public func part(_ channel: String, reason: String? = nil) async throws {
		if let reason = reason, !reason.isEmpty {
			try await connection.send("PART \(channel) :\(reason)")
		} else {
			try await connection.send("PART \(channel)")
		}
	}

	public func sendMessage(to target: String, content: String) async throws {
		try await connection.send("PRIVMSG \(target) :\(content)")
	}

	public func sendAction(to target: String, action: String) async throws {
		try await connection.send("PRIVMSG \(target) :\u{0001}ACTION \(action)\u{0001}")
	}

	/// Returns the channel object for the given target (channel name or nickname),
	/// creating a new query tab if one doesn't exist.
	@discardableResult
	public func openQuery(_ target: String) -> Channel {
		if let existing = server.channels.first(where: { $0.name == target }) {
			return existing
		}
		let channel = Channel(name: target)
		server.channels.append(channel)
		onChannelsChanged?()
		return channel
	}

	public func setNickname(_ nickname: String) async throws {
		try await connection.send("NICK \(nickname)")
	}

	// MARK: - Incoming message handling

	/// Dispatches a single parsed IRC message. Public for testability —
	/// call this directly from tests to simulate server input.
	public func handle(_ message: IRCLineParserResult) {
		if message.commandNumeric > 0 {
			handleNumeric(message)
			return
		}

		switch message.command {
		case "PRIVMSG": handlePrivmsg(message)
		case "NOTICE":  handleNotice(message)
		case "JOIN":    handleJoin(message)
		case "PART":    handlePart(message)
		case "QUIT":    handleQuit(message)
		case "NICK":    handleNick(message)
		case "TOPIC":   handleTopic(message)
		case "KICK":    handleKick(message)
		default:
			// Surface unhandled protocol traffic in the server console so users
			// can see what the server is saying.
			let text = "\(message.command) " + message.params.joined(separator: " ")
			server.messages.append(Message(sender: "<<", content: text, kind: .server))
		}
	}

	/// Logs an outgoing raw line to the server console and sends it.
	public func sendRawEchoed(_ line: String) async throws {
		server.messages.append(Message(sender: ">>", content: line, kind: .server))
		try await connection.send(line)
	}

	// MARK: - State sync

	private func syncState(_ state: IRCConnection.State) {
		switch state {
		case .disconnected, .failed:
			server.state = .disconnected
			scheduleReconnectIfNeeded()
		case .connecting:
			server.state = .connecting
		case .registering, .active:
			server.state = .connected
		case .disconnecting:
			server.state = .disconnecting
		}
	}

	private func scheduleReconnectIfNeeded() {
		guard autoReconnect, !userDisconnected, reconnectTask == nil else { return }
		// Exponential backoff: 1, 2, 4, 8, 16, 32, 60, 60…
		let steps: [UInt64] = [1, 2, 4, 8, 16, 32, 60]
		let seconds = steps[min(reconnectAttempt, steps.count - 1)]
		reconnectAttempt += 1
		server.messages.append(Message(
			sender: "**",
			content: "connection lost — reconnecting in \(seconds)s (attempt \(reconnectAttempt))",
			kind: .server
		))
		reconnectTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
			guard !Task.isCancelled else { return }
			await self?.performReconnect()
		}
	}

	private func performReconnect() async {
		reconnectTask = nil
		guard !userDisconnected else { return }
		do {
			try await connection.connect()
		} catch {
			server.messages.append(Message(
				sender: "**",
				content: "reconnect failed: \(error)",
				kind: .server
			))
			scheduleReconnectIfNeeded()
		}
	}

	// MARK: - Handlers

	private func handleNumeric(_ message: IRCLineParserResult) {
		switch message.commandNumeric {
		case 1:
			server.state = .registered
			reconnectAttempt = 0
			appendServerLog(message)
			for name in autoJoinChannels {
				Task { try? await join(name) }
			}
		case 332:
			handleTopicReply(message)
		case 353:
			handleNamesReply(message)
		case 366:
			break
		default:
			appendServerLog(message)
		}
	}

	private func appendServerLog(_ message: IRCLineParserResult) {
		let sender = message.senderNickname ?? message.senderString ?? "server"
		// Trailing param (if any) is usually the human-readable text.
		let text = message.params.last ?? ""
		server.messages.append(Message(sender: sender, content: text, kind: .server))
	}

	private func handlePrivmsg(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let target = message.params[0]
		let body = message.params[1]
		let sender = message.senderNickname ?? message.senderString ?? ""

		let isAction = body.hasPrefix("\u{0001}ACTION ") && body.hasSuffix("\u{0001}")
		let content: String
		let kind: Message.Kind
		if isAction {
			content = String(body.dropFirst(8).dropLast(1))
			kind = .action
		} else {
			content = body
			kind = .privmsg
		}

		let msg = Message(sender: sender, content: content, kind: kind)

		if target.hasPrefix("#") || target.hasPrefix("&") {
			if let channel = server.channels.first(where: { $0.name == target }) {
				channel.messages.append(msg)
				if !isOwnMessage(sender) {
					channel.unreadCount += 1
				}
			}
		} else {
			// PM / query — use sender as the query name.
			let queryName = sender
			let channel: Channel
			if let existing = server.channels.first(where: { $0.name == queryName }) {
				channel = existing
			} else {
				channel = Channel(name: queryName)
				server.channels.append(channel)
				onChannelsChanged?()
			}
			channel.messages.append(msg)
			channel.unreadCount += 1
		}
	}

	private func handleNotice(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let target = message.params[0]
		let body = message.params[1]
		let sender = message.senderNickname ?? message.senderString ?? "*"
		let msg = Message(sender: sender, content: body, kind: .notice)

		if target.hasPrefix("#") || target.hasPrefix("&") {
			if let channel = server.channels.first(where: { $0.name == target }) {
				channel.messages.append(msg)
			}
		} else {
			// Server / user-directed notice — show in the server console.
			server.messages.append(msg)
		}
	}

	private func handleJoin(_ message: IRCLineParserResult) {
		guard let channelName = message.params.first else { return }
		let nick = message.senderNickname ?? ""

		if isOwnMessage(nick) {
			let channel: Channel
			if let existing = server.channels.first(where: { $0.name == channelName }) {
				channel = existing
			} else {
				channel = Channel(name: channelName)
				server.channels.append(channel)
			}
			channel.isJoined = true
			onChannelsChanged?()
		} else {
			guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }
			if !channel.users.contains(where: { $0.nickname == nick }) {
				let user = User(nickname: nick)
				user.username = message.senderUsername
				user.hostname = message.senderAddress
				channel.users.append(user)
			}
			channel.messages.append(Message(sender: nick, content: "joined \(channelName)", kind: .join))
		}
	}

	private func handlePart(_ message: IRCLineParserResult) {
		guard let channelName = message.params.first else { return }
		let nick = message.senderNickname ?? ""
		let reason = message.params.count > 1 ? message.params[1] : ""

		guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }

		if isOwnMessage(nick) {
			channel.isJoined = false
			channel.users.removeAll()
			onChannelsChanged?()
		} else {
			channel.users.removeAll(where: { $0.nickname == nick })
			let text = reason.isEmpty ? "left \(channelName)" : "left \(channelName) (\(reason))"
			channel.messages.append(Message(sender: nick, content: text, kind: .part))
		}
	}

	private func handleQuit(_ message: IRCLineParserResult) {
		let nick = message.senderNickname ?? ""
		let reason = message.params.first ?? ""

		for channel in server.channels where channel.users.contains(where: { $0.nickname == nick }) {
			channel.users.removeAll(where: { $0.nickname == nick })
			let text = reason.isEmpty ? "quit" : "quit (\(reason))"
			channel.messages.append(Message(sender: nick, content: text, kind: .quit))
		}
	}

	private func handleNick(_ message: IRCLineParserResult) {
		guard let newNick = message.params.first else { return }
		let oldNick = message.senderNickname ?? ""

		if isOwnMessage(oldNick) {
			server.nickname = newNick
		}

		for channel in server.channels {
			if let user = channel.users.first(where: { $0.nickname == oldNick }) {
				user.nickname = newNick
				channel.messages.append(Message(sender: oldNick, content: "is now known as \(newNick)", kind: .nick))
			}
		}
	}

	private func handleTopic(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let channelName = message.params[0]
		let topic = message.params[1]
		let nick = message.senderNickname ?? ""

		guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }
		channel.topic = topic
		channel.messages.append(Message(sender: nick, content: "changed topic to: \(topic)", kind: .topic))
	}

	private func handleKick(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let channelName = message.params[0]
		let targetNick = message.params[1]
		let reason = message.params.count > 2 ? message.params[2] : ""
		let kicker = message.senderNickname ?? ""

		guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }

		if isOwnMessage(targetNick) {
			channel.isJoined = false
			channel.users.removeAll()
			onChannelsChanged?()
		} else {
			channel.users.removeAll(where: { $0.nickname == targetNick })
		}

		let text = reason.isEmpty
			? "\(kicker) kicked \(targetNick) from \(channelName)"
			: "\(kicker) kicked \(targetNick) from \(channelName) (\(reason))"
		channel.messages.append(Message(sender: kicker, content: text, kind: .kick))
	}

	private func handleTopicReply(_ message: IRCLineParserResult) {
		guard message.params.count >= 3 else { return }
		let channelName = message.params[1]
		let topic = message.params[2]
		if let channel = server.channels.first(where: { $0.name == channelName }) {
			channel.topic = topic
		}
	}

	private func handleNamesReply(_ message: IRCLineParserResult) {
		guard message.params.count >= 4 else { return }
		let channelName = message.params[2]
		let namesLine = message.params[3]

		guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }

		for raw in namesLine.split(separator: " ") {
			let (modes, nick) = parsePrefix(String(raw))
			if !channel.users.contains(where: { $0.nickname == nick }) {
				let user = User(nickname: nick)
				user.modes = modes
				channel.users.append(user)
			}
		}
	}

	// MARK: - Helpers

	private func isOwnMessage(_ nick: String) -> Bool {
		!nick.isEmpty && nick == server.nickname
	}

	private func parsePrefix(_ raw: String) -> (Set<Character>, String) {
		var modes: Set<Character> = []
		var nick = raw

		while let first = nick.first, IRCSession.prefixChars.contains(first) {
			switch first {
			case "~": modes.insert("q")
			case "&": modes.insert("a")
			case "@": modes.insert("o")
			case "%": modes.insert("h")
			case "+": modes.insert("v")
			default: break
			}
			nick.removeFirst()
		}

		return (modes, nick)
	}

	private static let prefixChars: Set<Character> = ["~", "&", "@", "%", "+"]
}
