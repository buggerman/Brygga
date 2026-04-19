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

	/// Fires every time an incoming message is flagged as a highlight
	/// (mention of our nick, or any PM). The UI can use this to post
	/// notifications or update Dock badges.
	public var onHighlight: ((Channel, Message) -> Void)?

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
		stopNotifyPolling()
		runTask?.cancel()
		runTask = nil
	}

	/// User-initiated disconnect that keeps the session/server in place but
	/// suppresses auto-reconnect. Call `reconnect()` to bring it back.
	public func disconnect(quitMessage: String? = nil) async {
		userDisconnected = true
		reconnectTask?.cancel()
		reconnectTask = nil
		await connection.disconnect(quitMessage: quitMessage)
	}

	/// Clears the user-initiated-disconnect flag and attempts to bring the
	/// connection back up. Auto-reconnect resumes on subsequent drops.
	public func reconnect() {
		userDisconnected = false
		reconnectAttempt = 0
		reconnectTask?.cancel()
		reconnectTask = nil
		Task { [weak self] in
			guard let self = self else { return }
			do {
				try await self.connection.connect()
			} catch {
				self.recordServer(Message(
					sender: "**",
					content: "reconnect failed: \(error)",
					kind: .server
				))
				self.scheduleReconnectIfNeeded()
			}
		}
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

	/// Sends an IRCv3 typing indicator (`+typing=active|paused|done`) to the
	/// given target. Silently drops if the server hasn't negotiated
	/// `message-tags` — the TAGMSG is still a valid IRC command but the
	/// server is free to reject unknown tags.
	public func sendTyping(state: String, to target: String) async throws {
		try await connection.send("@+typing=\(state) TAGMSG \(target)")
	}

	public func sendMessage(to target: String, content: String) async throws {
		for chunk in splitMessage(content, for: target) {
			try await connection.send("PRIVMSG \(target) :\(chunk)")
		}
	}

	public func sendAction(to target: String, action: String) async throws {
		// ACTION wraps add \u{0001}ACTION ... \u{0001} — 9 extra bytes.
		let maxBytes = max(safeBodyLimit(for: target) - 9, 50)
		for line in action.split(whereSeparator: \.isNewline).map(String.init) {
			for chunk in chunkMessage(line, maxBytes: maxBytes) {
				try await connection.send("PRIVMSG \(target) :\u{0001}ACTION \(chunk)\u{0001}")
			}
		}
	}

	// MARK: - Outbound message chunking

	/// Splits `content` into UTF-8-safe chunks that each fit within the IRC
	/// 512-byte line budget for a PRIVMSG to `target`. Newlines in the input
	/// become chunk boundaries (IRC doesn't allow raw LF in a single line).
	public func splitMessage(_ content: String, for target: String) -> [String] {
		let maxBytes = safeBodyLimit(for: target)
		var result: [String] = []
		for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
			result.append(contentsOf: chunkMessage(line, maxBytes: maxBytes))
		}
		// Drop trailing empty chunks from trailing newlines, keep at least one
		// so an intentionally-blank message still sends.
		while let last = result.last, last.isEmpty, result.count > 1 {
			result.removeLast()
		}
		return result
	}

	/// IRC's per-line limit is 512 bytes including the server-added prefix
	/// (`:nick!user@host `) and the trailing `\r\n`. We don't know our exact
	/// hostname without a WHOIS, so we assume a conservative upper bound.
	private func safeBodyLimit(for target: String) -> Int {
		let nick = server.nickname
		let user = connection.username
		let hostnameAssumed = 70   // conservative max; most cloaks are ~25
		let prefixBytes = 1 + nick.utf8.count + 1 + user.utf8.count + 1 + hostnameAssumed + 1
		let commandBytes = "PRIVMSG ".utf8.count + target.utf8.count + " :".utf8.count
		let trailerBytes = 2   // \r\n
		let budget = 512 - prefixBytes - commandBytes - trailerBytes
		return max(budget, 50)
	}

	/// Greedy chunker: fills each chunk up to `maxBytes` of UTF-8, preferring
	/// to break at the last space in the final ~40% of the chunk when one
	/// exists, otherwise at the next codepoint boundary.
	private func chunkMessage(_ content: String, maxBytes: Int) -> [String] {
		guard maxBytes > 0 else { return [content] }
		if content.utf8.count <= maxBytes { return [content] }

		var chunks: [String] = []
		var remaining = content

		while !remaining.isEmpty {
			if remaining.utf8.count <= maxBytes {
				chunks.append(remaining)
				break
			}

			var bytesSoFar = 0
			var lastSpace: String.Index? = nil
			var cutoff: String.Index = remaining.startIndex

			for idx in remaining.indices {
				let charBytes = remaining[idx].utf8.count
				if bytesSoFar + charBytes > maxBytes { break }
				bytesSoFar += charBytes
				if remaining[idx] == " " { lastSpace = idx }
				cutoff = remaining.index(after: idx)
			}

			if let space = lastSpace {
				let spaceUTF8 = space.samePosition(in: remaining.utf8) ?? remaining.utf8.startIndex
				let spaceOffset = remaining.utf8.distance(from: remaining.utf8.startIndex, to: spaceUTF8)
				// Only prefer the last-space split if it's in the final ~40%.
				if spaceOffset >= (bytesSoFar * 6 / 10) {
					chunks.append(String(remaining[..<space]))
					remaining = String(remaining[remaining.index(after: space)...])
					continue
				}
			}

			chunks.append(String(remaining[..<cutoff]))
			remaining = String(remaining[cutoff...])
		}

		return chunks
	}

	/// Returns the channel object for the given target (channel name or nickname),
	/// creating a new query tab if one doesn't exist.
	@discardableResult
	public func openQuery(_ target: String) -> Channel {
		if let existing = server.channels.first(where: { $0.name == target }) {
			return existing
		}
		let channel = Channel(name: target)
		channel.isPinned = server.pinnedChannels.contains(target.lowercased())
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
		case "TAGMSG":  handleTagmsg(message)
		case "NOTICE":  handleNotice(message)
		case "JOIN":    handleJoin(message)
		case "PART":    handlePart(message)
		case "QUIT":    handleQuit(message)
		case "NICK":    handleNick(message)
		case "TOPIC":   handleTopic(message)
		case "KICK":    handleKick(message)
		case "INVITE":  handleInvite(message)
		case "CHGHOST": handleChghost(message)
		case "ACCOUNT": handleAccount(message)
		case "AWAY":    handleAway(message)
		case "BATCH":   break  // IRCv3 batches — ignored for now, messages flow through normally
		case "CAP":     break  // CAP traffic is handled in IRCConnection; suppress server-log noise here
		default:
			// Surface unhandled protocol traffic in the server console so users
			// can see what the server is saying.
			let text = "\(message.command) " + message.params.joined(separator: " ")
			recordServer(Message(sender: "<<", content: text, kind: .server))
		}
	}

	/// Logs an outgoing raw line to the server console and sends it.
	public func sendRawEchoed(_ line: String) async throws {
		recordServer(Message(sender: ">>", content: line, kind: .server))
		try await connection.send(line)
	}

	// MARK: - Scrollback

	/// Persist-through append for a channel message. UI and disk scrollback
	/// stay in sync.
	public func record(_ message: Message, in channel: Channel) {
		channel.messages.append(message)
		let sid = server.id
		let target = channel.name
		Task {
			await ScrollbackStore.shared.append(serverId: sid, target: target, message: message)
		}
		logToDiskIfEnabled(message, target: target)
	}

	/// Persist-through append for the server console.
	public func recordServer(_ message: Message) {
		server.messages.append(message)
		let sid = server.id
		Task {
			await ScrollbackStore.shared.append(serverId: sid, target: "__server__", message: message)
		}
		logToDiskIfEnabled(message, target: "server")
	}

	private func logToDiskIfEnabled(_ message: Message, target: String) {
		guard UserDefaults.standard.bool(forKey: PreferencesKeys.diskLoggingEnabled) else { return }
		let network = server.name
		let line = Self.formatLogLine(message)
		let ts = message.timestamp
		Task {
			await DiskLogger.shared.append(network: network, target: target, line: line, timestamp: ts)
		}
	}

	private static func formatLogLine(_ msg: Message) -> String {
		switch msg.kind {
		case .privmsg:       return "<\(msg.sender)> \(msg.content)"
		case .action:        return "* \(msg.sender) \(msg.content)"
		case .notice:        return "-\(msg.sender)- \(msg.content)"
		case .server:
			let sender = msg.sender.isEmpty ? "" : "\(msg.sender) "
			return "-- \(sender)\(msg.content)"
		case .join:          return "* \(msg.sender) \(msg.content)"
		case .part:          return "* \(msg.sender) \(msg.content)"
		case .quit:          return "* \(msg.sender) \(msg.content)"
		case .nick:          return "* \(msg.sender) \(msg.content)"
		case .kick:          return "* \(msg.content)"
		case .topic:         return "* \(msg.sender) changed topic to: \(msg.content)"
		case .mode:          return "* \(msg.sender) \(msg.content)"
		}
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
		recordServer(Message(
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
			recordServer(Message(
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
			// 001's first param is the nick the server assigned us. The server is
			// authoritative — on some networks (e.g., Ergo with
			// force-nick-equals-account) our SASL-authenticated nick may differ
			// from what we sent in NICK. Keep `server.nickname` in sync so
			// `isOwnMessage` correctly identifies our own JOIN/PART/NICK echoes.
			if let serverAssignedNick = message.params.first, !serverAssignedNick.isEmpty {
				server.nickname = serverAssignedNick
			}
			appendServerLog(message)
			for name in autoJoinChannels {
				Task { try? await join(name) }
			}
			notifyOnline = []
			chathistoryRequested = []
			startNotifyPolling()
			for line in server.performCommands {
				Task { try? await connection.send(line) }
			}
		case 332:
			handleTopicReply(message)
		case 353:
			handleNamesReply(message)
		case 366:
			break
		case 303:
			handleISONReply(message)
		case 305:
			// RPL_UNAWAY — we're no longer marked away.
			server.isAway = false
			server.awayMessage = nil
			appendServerLog(message)
		case 306:
			// RPL_NOWAWAY — we've been marked away.
			server.isAway = true
			appendServerLog(message)
		case 311: handleWhoisUser(message)
		case 312: handleWhoisServer(message)
		case 313: appendWhois(message, format: "is an IRC operator")
		case 317: handleWhoisIdle(message)
		case 318: appendWhois(message, format: "End of WHOIS")
		case 319: handleWhoisChannels(message)
		case 330: handleWhoisAccount(message)
		case 335: appendWhois(message, format: "is a bot")
		case 378: handleWhoisHost(message)
		case 379: handleWhoisModes(message)
		case 671: appendWhois(message, format: "is using a secure connection")
		case 321:
			// RPL_LISTSTART — begin a fresh listing.
			server.channelListing = []
			server.isListingInProgress = true
		case 322:
			// RPL_LIST — one channel entry: params = [me, name, userCount, topic]
			guard message.params.count >= 3 else { break }
			let name = message.params[1]
			let count = Int(message.params[2]) ?? 0
			let topic = message.params.count > 3 ? message.params[3] : ""
			server.channelListing.append(ChannelListing(
				name: name,
				userCount: count,
				topic: topic
			))
		case 323:
			// RPL_LISTEND — sort by user count descending.
			server.channelListing.sort { $0.userCount > $1.userCount }
			server.isListingInProgress = false
		default:
			appendServerLog(message)
		}
	}

	private func appendServerLog(_ message: IRCLineParserResult) {
		let sender = message.senderNickname ?? message.senderString ?? "server"
		// Trailing param (if any) is usually the human-readable text.
		let text = message.params.last ?? ""
		recordServer(Message(sender: sender, content: text, kind: .server))
	}

	private func handlePrivmsg(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let target = message.params[0]
		let body = message.params[1]
		let sender = message.senderNickname ?? message.senderString ?? ""

		// Drop messages from ignored senders entirely — no record, no highlight,
		// no notification. Presence events (JOIN/PART/QUIT) still render so the
		// view of the channel stays truthful.
		if isIgnored(sender: sender, mask: message.senderString) { return }

		// CTCP detection — bodies wrapped in \x01.
		let content: String
		let kind: Message.Kind
		if body.hasPrefix("\u{0001}") {
			var inner = body.dropFirst()
			if inner.last == "\u{0001}" { inner = inner.dropLast() }
			let parts = inner.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
			let ctcpCmd = (parts.first.map(String.init) ?? "").uppercased()
			let ctcpArgs = parts.count > 1 ? String(parts[1]) : ""

			if ctcpCmd == "ACTION" {
				content = ctcpArgs
				kind = .action
			} else {
				// Any other CTCP is metadata, not chat — auto-respond and suppress.
				handleCTCPRequest(command: ctcpCmd, args: ctcpArgs, from: sender)
				return
			}
		} else {
			content = body
			kind = .privmsg
		}

		// Highlight: incoming message mentions our nick as a whole word.
		let isHighlight = !isOwnMessage(sender) && mentionsOwnNick(content)
		let msg = Message(
			timestamp: messageTimestamp(message),
			sender: sender,
			content: content,
			kind: kind,
			isHighlight: isHighlight
		)

		if target.hasPrefix("#") || target.hasPrefix("&") {
			if let channel = server.channels.first(where: { $0.name == target }) {
				record(msg, in: channel)
				if !isOwnMessage(sender) {
					channel.unreadCount += 1
					if isHighlight {
						channel.highlightCount += 1
						onHighlight?(channel, msg)
					}
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
				channel.isPinned = server.pinnedChannels.contains(queryName.lowercased())
				server.channels.append(channel)
				onChannelsChanged?()
			}
			record(msg, in: channel)
			channel.unreadCount += 1
			// PMs are inherently "for you" — always a highlight.
			channel.highlightCount += 1
			onHighlight?(channel, msg)
		}
	}

	// MARK: - chathistory

	/// Channel names (lowercased) for which we've already requested history
	/// this session. Cleared on each 001 welcome so reconnects re-request.
	private var chathistoryRequested: Set<String> = []

	private func requestChathistoryIfNeeded(for channel: Channel) {
		let name = channel.name
		let key = name.lowercased()
		guard !chathistoryRequested.contains(key) else { return }
		let conn = connection
		Task { [weak self] in
			let caps = await conn.enabledCaps
			guard caps.contains("chathistory") || caps.contains("draft/chathistory") else { return }
			self?.chathistoryRequested.insert(key)
			try? await conn.send("CHATHISTORY LATEST \(name) * 100")
		}
	}

	// MARK: - Perform (post-welcome commands)

	public func addPerform(_ line: String) {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		server.performCommands.append(trimmed)
		onChannelsChanged?()
	}

	@discardableResult
	public func removePerform(_ line: String) -> Bool {
		let before = server.performCommands.count
		server.performCommands.removeAll { $0 == line }
		let removed = server.performCommands.count != before
		if removed { onChannelsChanged?() }
		return removed
	}

	public func clearPerform() {
		guard !server.performCommands.isEmpty else { return }
		server.performCommands = []
		onChannelsChanged?()
	}

	// MARK: - Notify / buddy list

	private var notifyOnline: Set<String> = []
	private var notifyPollTask: Task<Void, Never>?
	private static let notifyPollInterval: TimeInterval = 60

	public func addNotify(_ nick: String) {
		let trimmed = nick.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		let lc = trimmed.lowercased()
		guard !server.notifyList.contains(where: { $0.lowercased() == lc }) else { return }
		server.notifyList.append(trimmed)
		onChannelsChanged?()
	}

	@discardableResult
	public func removeNotify(_ nick: String) -> Bool {
		let lc = nick.lowercased()
		let before = server.notifyList.count
		server.notifyList.removeAll { $0.lowercased() == lc }
		let removed = server.notifyList.count != before
		if removed {
			notifyOnline.remove(lc)
			onChannelsChanged?()
		}
		return removed
	}

	private func startNotifyPolling() {
		stopNotifyPolling()
		notifyPollTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: UInt64(Self.notifyPollInterval * 1_000_000_000))
				guard let self = self, !Task.isCancelled else { return }
				await self.sendNotifyPoll()
			}
		}
		// Fire one immediate poll so we don't wait 60s to see initial status.
		Task { [weak self] in await self?.sendNotifyPoll() }
	}

	private func stopNotifyPolling() {
		notifyPollTask?.cancel()
		notifyPollTask = nil
	}

	private func sendNotifyPoll() async {
		let nicks = server.notifyList
		guard !nicks.isEmpty else { return }
		try? await connection.send("ISON \(nicks.joined(separator: " "))")
	}

	/// 303 RPL_ISON — params: [me, :online nick1 nick2 ...]
	private func handleISONReply(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let onlineList = message.params[1]
			.split(separator: " ")
			.map { String($0).lowercased() }
		let nowOnline = Set(onlineList)
		let watched = Set(server.notifyList.map { $0.lowercased() })
		let effective = nowOnline.intersection(watched)

		// Original-case lookup for display.
		let byLower: [String: String] = Dictionary(
			uniqueKeysWithValues: server.notifyList.map { ($0.lowercased(), $0) }
		)

		let justCameOn = effective.subtracting(notifyOnline).sorted()
		let justLeft = notifyOnline.subtracting(effective).sorted()

		for lc in justCameOn {
			let display = byLower[lc] ?? lc
			recordServer(Message(sender: display, content: "is online", kind: .server))
		}
		for lc in justLeft {
			let display = byLower[lc] ?? lc
			recordServer(Message(sender: display, content: "went offline", kind: .server))
		}

		notifyOnline = effective
	}

	// MARK: - Ignore list

	/// Add a nickname or hostmask pattern to the ignore list. Idempotent.
	public func addIgnore(_ pattern: String) {
		let trimmed = pattern.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		let lc = trimmed.lowercased()
		guard !server.ignoreList.contains(where: { $0.lowercased() == lc }) else { return }
		server.ignoreList.append(trimmed)
		onChannelsChanged?()
	}

	/// Remove a nickname or hostmask pattern from the ignore list. Case-insensitive.
	@discardableResult
	public func removeIgnore(_ pattern: String) -> Bool {
		let lc = pattern.lowercased()
		let before = server.ignoreList.count
		server.ignoreList.removeAll { $0.lowercased() == lc }
		let removed = server.ignoreList.count != before
		if removed { onChannelsChanged?() }
		return removed
	}

	/// True if `nick` (or `mask`, if provided) matches any entry in the ignore list.
	/// Entries containing `*`, `!`, or `@` are treated as hostmask globs matched
	/// against `mask` (nick!user@host). Plain entries are exact-nick matches.
	public func isIgnored(sender nick: String, mask: String?) -> Bool {
		let lcNick = nick.lowercased()
		let lcMask = mask?.lowercased()
		for entry in server.ignoreList {
			let lcEntry = entry.lowercased()
			let isGlob = lcEntry.contains("*") || lcEntry.contains("!") || lcEntry.contains("@")
			if isGlob {
				if let lcMask = lcMask, Self.globMatch(pattern: lcEntry, input: lcMask) {
					return true
				}
			} else if lcEntry == lcNick {
				return true
			}
		}
		return false
	}

	/// Simple IRC-style glob: `*` matches any run, `?` matches one character,
	/// everything else is literal.
	private static func globMatch(pattern: String, input: String) -> Bool {
		var regex = "^"
		for c in pattern {
			switch c {
			case "*": regex += ".*"
			case "?": regex += "."
			case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "\\", "|":
				regex += "\\\(c)"
			default:
				regex.append(c)
			}
		}
		regex += "$"
		return input.range(of: regex, options: .regularExpression) != nil
	}

	// MARK: - CTCP auto-responses

	/// Tracks the last time we replied to each requester, to avoid being
	/// exploited as a flood amplifier.
	private var ctcpReplyCooldown: [String: Date] = [:]
	private static let ctcpCooldownInterval: TimeInterval = 10

	/// The VERSION reply string, built once at first access.
	private static let ctcpVersionReply: String = {
		let v = ProcessInfo.processInfo.operatingSystemVersion
		let osString = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
		let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
		return "Brygga \(bundleVersion) (\(osString))"
	}()

	/// Handle an incoming CTCP request and, if known, send the canonical
	/// NOTICE reply. Unknown CTCPs are silently ignored.
	private func handleCTCPRequest(command: String, args: String, from sender: String) {
		guard !isOwnMessage(sender) else { return }

		let key = sender.lowercased()
		let now = Date()
		if let last = ctcpReplyCooldown[key],
		   now.timeIntervalSince(last) < Self.ctcpCooldownInterval {
			return
		}

		let reply: String?
		switch command {
		case "VERSION":
			reply = Self.ctcpVersionReply
		case "PING":
			// Echo the payload unchanged — that's what the peer measures RTT against.
			reply = args
		case "TIME":
			let f = ISO8601DateFormatter()
			f.formatOptions = [.withInternetDateTime]
			reply = f.string(from: now)
		case "CLIENTINFO":
			reply = "VERSION PING TIME CLIENTINFO SOURCE"
		case "SOURCE":
			reply = "https://github.com/buggerman/Brygga"
		default:
			reply = nil
		}

		guard let reply = reply else { return }
		ctcpReplyCooldown[key] = now

		// Breadcrumb in the server console so the user can see that their
		// client answered a CTCP request — matches the mIRC convention.
		recordServer(Message(
			sender: sender,
			content: "CTCP \(command) — replied",
			kind: .server
		))

		let payload = "\u{0001}\(command) \(reply)\u{0001}"
		Task { [weak self] in
			try? await self?.connection.send("NOTICE \(sender) :\(payload)")
		}
	}

	// MARK: - /whois numerics

	/// Appends a `.server` log line rendered as `* <targetNick> <content>`.
	/// NickColor automatically colors the target nick.
	private func appendWhois(_ message: IRCLineParserResult, format content: String) {
		guard message.params.count >= 2 else { return }
		let target = message.params[1]
		recordServer(Message(
			timestamp: messageTimestamp(message),
			sender: target,
			content: content,
			kind: .server
		))
	}

	/// 311 RPL_WHOISUSER — params: [me, nick, user, host, "*", :realname]
	private func handleWhoisUser(_ message: IRCLineParserResult) {
		guard message.params.count >= 6 else { return }
		let user = message.params[2]
		let host = message.params[3]
		let realname = message.params[5]
		appendWhois(message, format: "(\(user)@\(host)) — \(realname)")
	}

	/// 312 RPL_WHOISSERVER — params: [me, nick, server, :serverinfo]
	private func handleWhoisServer(_ message: IRCLineParserResult) {
		guard message.params.count >= 4 else { return }
		let serverName = message.params[2]
		let info = message.params[3]
		appendWhois(message, format: "on \(serverName) (\(info))")
	}

	/// 317 RPL_WHOISIDLE — params: [me, nick, idleSeconds, signonUnix?, :seconds idle, signon time]
	private func handleWhoisIdle(_ message: IRCLineParserResult) {
		guard message.params.count >= 3, let idle = Int(message.params[2]) else { return }
		let idleText = formatDuration(seconds: idle)
		if message.params.count >= 4, let signon = TimeInterval(message.params[3]) {
			let date = Date(timeIntervalSince1970: signon)
			let formatter = DateFormatter()
			formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
			appendWhois(message, format: "idle \(idleText), signed on \(formatter.string(from: date))")
		} else {
			appendWhois(message, format: "idle \(idleText)")
		}
	}

	/// 319 RPL_WHOISCHANNELS — params: [me, nick, :channels-with-prefixes]
	private func handleWhoisChannels(_ message: IRCLineParserResult) {
		guard message.params.count >= 3 else { return }
		let channels = message.params[2]
			.split(separator: " ")
			.map(String.init)
			.joined(separator: ", ")
		appendWhois(message, format: "on \(channels)")
	}

	/// 330 RPL_WHOISACCOUNT — params: [me, nick, account, :is logged in as]
	private func handleWhoisAccount(_ message: IRCLineParserResult) {
		guard message.params.count >= 3 else { return }
		let account = message.params[2]
		appendWhois(message, format: "is logged in as \(account)")
	}

	/// 378 RPL_WHOISHOST — params: [me, nick, :is connecting from *@host ip]
	private func handleWhoisHost(_ message: IRCLineParserResult) {
		guard message.params.count >= 3 else { return }
		appendWhois(message, format: message.params[2])
	}

	/// 379 RPL_WHOISMODES — params: [me, nick, :is using modes ...]
	private func handleWhoisModes(_ message: IRCLineParserResult) {
		guard message.params.count >= 3 else { return }
		appendWhois(message, format: message.params[2])
	}

	private func formatDuration(seconds: Int) -> String {
		let h = seconds / 3600
		let m = (seconds % 3600) / 60
		let s = seconds % 60
		if h > 0 { return "\(h)h \(m)m \(s)s" }
		if m > 0 { return "\(m)m \(s)s" }
		return "\(s)s"
	}

	// MARK: - IRCv3 extension handlers

	/// INVITE <us> <channel> — server telling us we've been invited by someone.
	/// Log to the server console; auto-join if the preference is on.
	private func handleInvite(_ message: IRCLineParserResult) {
		// Expected params: [invitee, channel]. Some networks put channel in trailing.
		guard message.params.count >= 2 else { return }
		let invitee = message.params[0]
		let channelName = message.params[1]
		let inviter = message.senderNickname ?? message.senderString ?? "?"

		// Only act on invites addressed to us.
		guard invitee.lowercased() == server.nickname.lowercased() else { return }

		recordServer(Message(
			timestamp: messageTimestamp(message),
			sender: inviter,
			content: "invited you to \(channelName)",
			kind: .server
		))

		if UserDefaults.standard.bool(forKey: PreferencesKeys.autoJoinOnInvite) {
			Task { try? await join(channelName) }
		}
	}

	/// CHGHOST <newuser> <newhost> — user's username/host changed (typically after SASL or vhost assignment).
	private func handleChghost(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let nick = message.senderNickname ?? ""
		let newUser = message.params[0]
		let newHost = message.params[1]
		for channel in server.channels {
			if let user = channel.users.first(where: { $0.nickname == nick }) {
				user.username = newUser
				user.hostname = newHost
			}
		}
	}

	/// ACCOUNT <accountname|*> — notifies when a user logs in/out of a services account.
	private func handleAccount(_ message: IRCLineParserResult) {
		guard let value = message.params.first else { return }
		let nick = message.senderNickname ?? ""
		let account: String? = (value == "*") ? nil : value
		for channel in server.channels {
			if let user = channel.users.first(where: { $0.nickname == nick }) {
				user.account = account
			}
		}
	}

	/// AWAY [:message] — server-to-client notification that a user's away state changed.
	private func handleAway(_ message: IRCLineParserResult) {
		let nick = message.senderNickname ?? ""
		let reason = message.params.first
		let isAway = reason != nil && !(reason?.isEmpty ?? true)
		for channel in server.channels {
			if let user = channel.users.first(where: { $0.nickname == nick }) {
				user.isAway = isAway
				user.awayMessage = isAway ? reason : nil
			}
		}
	}

	/// Returns the server-provided timestamp (IRCv3 `server-time` tag) if present,
	/// otherwise the current local time. Falls back gracefully for servers without
	/// `server-time` enabled.
	private func messageTimestamp(_ msg: IRCLineParserResult) -> Date {
		if let raw = msg.tags["time"] {
			let formatter = ISO8601DateFormatter()
			formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			if let d = formatter.date(from: raw) { return d }
			formatter.formatOptions = [.withInternetDateTime]
			if let d = formatter.date(from: raw) { return d }
		}
		return Date()
	}

	/// True if `content` mentions our own nickname *or* any user-configured
	/// highlight keyword as a whole word (case-insensitive).
	private func mentionsOwnNick(_ content: String) -> Bool {
		var terms: [String] = []
		if !server.nickname.isEmpty { terms.append(server.nickname) }

		let raw = UserDefaults.standard.string(forKey: PreferencesKeys.highlightKeywordsRaw) ?? ""
		for line in raw.split(whereSeparator: \.isNewline) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if !trimmed.isEmpty { terms.append(trimmed) }
		}
		guard !terms.isEmpty else { return false }

		for term in terms {
			let escaped = NSRegularExpression.escapedPattern(for: term)
			let pattern = "(?:^|[^A-Za-z0-9_-])\(escaped)(?:[^A-Za-z0-9_-]|$)"
			guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
				continue
			}
			let range = NSRange(content.startIndex..., in: content)
			if regex.firstMatch(in: content, range: range) != nil {
				return true
			}
		}
		return false
	}

	/// Handles an incoming TAGMSG carrying an IRCv3 `+typing` client tag.
	/// `active` keeps the sender visible in the indicator for 6s; `paused`
	/// and `done` clear them immediately.
	private func handleTagmsg(_ message: IRCLineParserResult) {
		guard let target = message.params.first,
		      let typing = message.tags["+typing"],
		      let nick = message.senderNickname,
		      !isOwnMessage(nick) else { return }

		let channelName: String
		if target.hasPrefix("#") || target.hasPrefix("&") {
			channelName = target
		} else {
			// TAGMSG to our own nick → treat as a query and attribute to the sender.
			channelName = nick
		}
		guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }

		switch typing {
		case "active":
			channel.typingUsers[nick] = Date().addingTimeInterval(6)
		case "paused", "done":
			channel.typingUsers.removeValue(forKey: nick)
		default:
			break
		}
	}

	private func handleNotice(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let target = message.params[0]
		let body = message.params[1]
		let sender = message.senderNickname ?? message.senderString ?? "*"

		// Ignore list suppresses NOTICE the same as PRIVMSG.
		if isIgnored(sender: sender, mask: message.senderString) { return }
		let msg = Message(
			timestamp: messageTimestamp(message),
			sender: sender,
			content: body,
			kind: .notice
		)

		if target.hasPrefix("#") || target.hasPrefix("&") {
			if let channel = server.channels.first(where: { $0.name == target }) {
				record(msg, in: channel)
			}
		} else {
			// Server / user-directed notice — show in the server console.
			recordServer(msg)
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
				channel.isPinned = server.pinnedChannels.contains(channelName.lowercased())
				server.channels.append(channel)
			}
			channel.isJoined = true
			onChannelsChanged?()
			requestChathistoryIfNeeded(for: channel)
		} else {
			guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }
			if !channel.users.contains(where: { $0.nickname == nick }) {
				let user = User(nickname: nick)
				user.username = message.senderUsername
				user.hostname = message.senderAddress
				channel.users.append(user)
			}
			record(Message(sender: nick, content: "joined \(channelName)", kind: .join), in: channel)
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
			record(Message(sender: nick, content: text, kind: .part), in: channel)
		}
	}

	private func handleQuit(_ message: IRCLineParserResult) {
		let nick = message.senderNickname ?? ""
		let reason = message.params.first ?? ""

		for channel in server.channels where channel.users.contains(where: { $0.nickname == nick }) {
			channel.users.removeAll(where: { $0.nickname == nick })
			let text = reason.isEmpty ? "quit" : "quit (\(reason))"
			record(Message(sender: nick, content: text, kind: .quit), in: channel)
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
				record(Message(sender: oldNick, content: "is now known as \(newNick)", kind: .nick), in: channel)
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
		record(Message(sender: nick, content: "changed topic to: \(topic)", kind: .topic), in: channel)
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
		record(Message(sender: kicker, content: text, kind: .kick), in: channel)
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
			let (modes, rest) = parsePrefix(String(raw))
			// With userhost-in-names enabled, each entry can be "nick!user@host".
			let nick: String
			var username: String?
			var hostname: String?
			if let bangIdx = rest.firstIndex(of: "!"),
			   let atIdx = rest.firstIndex(of: "@"),
			   bangIdx < atIdx {
				nick = String(rest[..<bangIdx])
				username = String(rest[rest.index(after: bangIdx)..<atIdx])
				hostname = String(rest[rest.index(after: atIdx)...])
			} else {
				nick = rest
			}
			if !channel.users.contains(where: { $0.nickname == nick }) {
				let user = User(nickname: nick)
				user.modes = modes
				user.username = username
				user.hostname = hostname
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
