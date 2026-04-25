// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

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

	/// Periodic client-initiated PING task that measures round-trip lag
	/// and keeps the connection warm. Started on 001, cancelled on stop.
	private var pingTask: Task<Void, Never>?

	/// Tokens of client-initiated PINGs waiting for a matching PONG, keyed
	/// by token string → send timestamp. Used to derive `Server.lag`.
	private var pendingPings: [String: Date] = [:]

	public init(server: Server, connection: IRCConnection) {
		self.server = server
		self.connection = connection
	}

	// MARK: - Lifecycle

	public func start() {
		guard runTask == nil else { return }

		let stateTask = Task { @MainActor [weak self] in
			guard let self else { return }
			for await state in connection.stateChanges {
				syncState(state)
			}
		}

		let messageTask = Task { @MainActor [weak self] in
			guard let self else { return }
			for await message in connection.messages {
				handle(message)
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
		stopPingLoop()
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
			guard let self else { return }
			do {
				try await connection.connect()
			} catch {
				recordServer(Message(
					sender: "**",
					content: "reconnect failed: \(error)",
					kind: .server,
				))
				scheduleReconnectIfNeeded()
			}
		}
	}

	// MARK: - Commands

	public func join(_ channel: String) async throws {
		try await connection.send("JOIN \(Self.normalizedChannelName(channel))")
	}

	/// Returns `raw` with a `#` prefix added when it doesn't already begin
	/// with one of the RFC 2811 channel-prefix characters (`# & + !`). Lets
	/// users type `/join linux` and land in `#linux` — the common case —
	/// while preserving explicit `&local`, `+modeless`, and `!safe` channels
	/// when the prefix is present.
	public static func normalizedChannelName(_ raw: String) -> String {
		let trimmed = raw.trimmingCharacters(in: .whitespaces)
		if let first = trimmed.first, "#&+!".contains(first) { return trimmed }
		return "#\(trimmed)"
	}

	public func part(_ channel: String, reason: String? = nil) async throws {
		// Fall back to the user's default leave message when no explicit
		// reason was provided. Empty-string stored value means the user
		// explicitly opted out of sending a default.
		let explicit = reason?.trimmingCharacters(in: .whitespaces)
		let effective: String?
		if let explicit, !explicit.isEmpty {
			effective = explicit
		} else {
			let stored = UserDefaults.standard.string(forKey: PreferencesKeys.defaultLeaveMessage)
				?? PreferencesKeys.defaultLeaveMessageFallback
			effective = stored.isEmpty ? nil : stored
		}
		if let message = effective {
			try await connection.send("PART \(channel) :\(message)")
		} else {
			try await connection.send("PART \(channel)")
		}
	}

	/// Sends an IRCv3 typing indicator (`+typing=active|paused|done`) to the
	/// given target. No-ops when:
	///  - the user has opted out via `PreferencesKeys.shareTypingEnabled`
	///    (matches Halloy's `buffer.typing.share` toggle), or
	///  - the server hasn't negotiated `message-tags` so we don't waste
	///    bytes and don't risk CLIENTTAGDENY.
	///
	/// Receiving `+typing` is not gated — other users' indicators always show.
	public func sendTyping(state: String, to target: String) async throws {
		let sharingEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.shareTypingEnabled) as? Bool ?? true
		guard sharingEnabled else { return }
		guard await connection.enabledCaps.contains("message-tags") else { return }
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
		let hostnameAssumed = 70 // conservative max; most cloaks are ~25
		let prefixBytes = 1 + nick.utf8.count + 1 + user.utf8.count + 1 + hostnameAssumed + 1
		let commandBytes = "PRIVMSG ".utf8.count + target.utf8.count + " :".utf8.count
		let trailerBytes = 2 // \r\n
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
		loadScrollbackIfNeeded(for: channel)
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
		case "TAGMSG": handleTagmsg(message)
		case "PONG": handlePong(message)
		case "NOTICE": handleNotice(message)
		case "JOIN": handleJoin(message)
		case "MODE": handleMode(message)
		case "PART": handlePart(message)
		case "QUIT": handleQuit(message)
		case "NICK": handleNick(message)
		case "TOPIC": handleTopic(message)
		case "KICK": handleKick(message)
		case "INVITE": handleInvite(message)
		case "CHGHOST": handleChghost(message)
		case "ACCOUNT": handleAccount(message)
		case "AWAY": handleAway(message)
		case "BATCH": handleBatch(message)
		case "BOUNCER": handleBouncer(message)
		case "CAP": break // CAP traffic is handled in IRCConnection; suppress server-log noise here
		default:
			// Surface unhandled protocol traffic in the server console so users
			// can see what the server is saying.
			let text = "\(message.command) " + message.params.joined(separator: " ")
			recordServer(Message(sender: "<<", content: text, kind: .server))
		}
	}

	// MARK: - Scrollback

	/// One-shot lazy load for channels created outside `restoreFromStore`'s
	/// pre-hydrate path — i.e. channels first seen via JOIN reply or the
	/// creation branch of openQuery / incoming PRIVMSG / TAGMSG. Guarded
	/// by `Channel.scrollbackLoaded` so repeated JOINs don't double-fill.
	public func loadScrollbackIfNeeded(for channel: Channel) {
		guard !channel.scrollbackLoaded else { return }
		channel.scrollbackLoaded = true
		let sid = server.id
		let target = channel.name
		Task { [weak channel] in
			let msgs = await ScrollbackStore.shared.load(serverId: sid, target: target)
			guard let channel, !msgs.isEmpty else { return }
			await MainActor.run {
				channel.messages.insert(contentsOf: msgs, at: 0)
			}
		}
	}

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
		// Default to logging on when the preference has never been set so
		// brand-new installs drop a paper trail into `~/Library/Logs/Brygga/`
		// without the user having to hunt for a toggle. Explicit opt-out
		// (set to `false` in Preferences → Logging) is honoured.
		let enabled = UserDefaults.standard.object(forKey: PreferencesKeys.diskLoggingEnabled) as? Bool ?? true
		guard enabled else { return }
		let network = server.name
		let line = Self.formatLogLine(message)
		let ts = message.timestamp
		Task {
			await DiskLogger.shared.append(network: network, target: target, line: line, timestamp: ts)
		}
	}

	private static func formatLogLine(_ msg: Message) -> String {
		switch msg.kind {
		case .privmsg: return "<\(msg.sender)> \(msg.content)"
		case .action: return "* \(msg.sender) \(msg.content)"
		case .notice: return "-\(msg.sender)- \(msg.content)"
		case .server:
			let sender = msg.sender.isEmpty ? "" : "\(msg.sender) "
			return "-- \(sender)\(msg.content)"
		case .join: return "* \(msg.sender) \(msg.content)"
		case .part: return "* \(msg.sender) \(msg.content)"
		case .quit: return "* \(msg.sender) \(msg.content)"
		case .nick: return "* \(msg.sender) \(msg.content)"
		case .kick: return "* \(msg.content)"
		case .topic: return "* \(msg.sender) changed topic to: \(msg.content)"
		case .mode: return "* \(msg.sender) \(msg.content)"
		}
	}

	// MARK: - State sync

	private func syncState(_ state: IRCConnection.State) {
		switch state {
		case .disconnected, .failed:
			server.state = .disconnected
			stopPingLoop()
			scheduleReconnectIfNeeded()
		case .connecting:
			server.state = .connecting
		case .registering, .active:
			server.state = .connected
		case .disconnecting:
			server.state = .disconnecting
			stopPingLoop()
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
			kind: .server,
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
				kind: .server,
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
			startPingLoop()
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
			pendingChathistoryBackfill.removeAll()
			pendingChathistoryAfter.removeAll()
			activeChathistoryBatches.removeAll()
			pendingChathistoryLimits.removeAll()
			// Mirror chathistory CAP support onto the @Observable Server so
			// SwiftUI can render the "Load earlier messages" affordance
			// without awaiting the connection actor on every body eval.
			// Cleared first so a reconnect to a server that no longer
			// negotiates the cap doesn't show a stale yes.
			server.supportsChathistory = false
			let conn = connection
			let mirrorTarget = server
			Task { @MainActor in
				let caps = await conn.enabledCaps
				mirrorTarget.supportsChathistory = caps.contains("chathistory")
					|| caps.contains("draft/chathistory")
			}
			startNotifyPolling()
			for line in server.performCommands {
				Task { try? await connection.send(line) }
			}
			requestBouncerNetworksIfNeeded()
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
				topic: topic,
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
			isHighlight: isHighlight,
			msgid: message.tags["msgid"],
		)

		// If this PRIVMSG belongs to a chathistory backfill batch we
		// initiated, divert it into the batch buffer instead of the live
		// append path. The buffer is flushed (with prepend semantics)
		// when the BATCH end line arrives.
		if let batchRef = message.tags["batch"],
		   var ctx = activeChathistoryBatches[batchRef]
		{
			ctx.buffer.append(msg)
			activeChathistoryBatches[batchRef] = ctx
			return
		}

		if target.hasPrefix("#") || target.hasPrefix("&") {
			if let channel = server.channels.first(where: { $0.name == target }) {
				record(msg, in: channel)
				// The sender just finished a message — their typing indicator
				// is implicitly cleared.
				channel.typingUsers.removeValue(forKey: sender)
				if !isOwnMessage(sender) {
					channel.unreadCount += 1
					if isHighlight {
						channel.highlightCount += 1
						onHighlight?(channel, msg)
					}
				}
				if let id = msg.msgid {
					server.lastSeenMsgIDs[channel.name.lowercased()] = id
					onChannelsChanged?()
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
				loadScrollbackIfNeeded(for: channel)
				onChannelsChanged?()
			}
			channel.typingUsers.removeValue(forKey: sender)
			record(msg, in: channel)
			channel.unreadCount += 1
			// PMs are inherently "for you" — always a highlight.
			channel.highlightCount += 1
			onHighlight?(channel, msg)
			if let id = msg.msgid {
				server.lastSeenMsgIDs[channel.name.lowercased()] = id
				onChannelsChanged?()
			}
		}
	}

	// MARK: - chathistory

	/// Channel names (lowercased) for which we've already requested history
	/// this session. Cleared on each 001 welcome so reconnects re-request.
	private var chathistoryRequested: Set<String> = []

	/// Buffers for in-flight chathistory backfill batches, keyed by the
	/// server-assigned BATCH reference. Filled from `handlePrivmsg`
	/// when an incoming PRIVMSG carries a `batch` tag matching one of
	/// these refs; flushed (with prepend semantics) when the matching
	/// `BATCH -<ref>` end line arrives.
	private var activeChathistoryBatches: [String: ChathistoryBatch] = [:]

	/// Lowercased channel names where the user has triggered a lazy
	/// "load older" request (`CHATHISTORY BEFORE`) and we are waiting
	/// for the server to open the matching batch. Distinguishes our
	/// backfill batches from the cold-start `LATEST 100` batch (which
	/// stays on the live append path so the existing UX is unaffected).
	private var pendingChathistoryBackfill: Set<String> = []

	/// Lowercased channel names where we've fired a `CHATHISTORY
	/// AFTER msgid=<lastSeen>` on JOIN and are waiting for the
	/// matching batch. Messages arriving in this batch are diverted
	/// from the live append path — they're historic gap-fill, not
	/// live traffic, so they don't bump unread counts or fire
	/// notifications.
	private var pendingChathistoryAfter: Set<String> = []

	/// Number of rows we asked for, keyed by lowercased channel name.
	/// Used at BATCH end to decide whether the result was definitively
	/// the head of the channel's history (got fewer rows than asked
	/// for → flip `hasMoreHistoryAbove` to `false`).
	private var pendingChathistoryLimits: [String: Int] = [:]

	private struct ChathistoryBatch {
		let target: String
		let direction: Direction
		var buffer: [Message] = []

		enum Direction {
			/// Lazy scroll-up backfill via `CHATHISTORY BEFORE`. Buffer
			/// is prepended to `channel.messages` on finalize.
			case before
			/// Cold-start gap fill via `CHATHISTORY AFTER msgid=<id>`.
			/// Buffer is merged into `channel.messages` in chronological
			/// order; `server.lastSeenMsgIDs` advances to the newest
			/// msgid in the batch.
			case after
		}
	}

	private func requestChathistoryIfNeeded(for channel: Channel) {
		let name = channel.name
		let key = name.lowercased()
		guard !chathistoryRequested.contains(key) else { return }
		let lastSeen = server.lastSeenMsgIDs[key]
		let conn = connection
		Task { [weak self] in
			let caps = await conn.enabledCaps
			guard caps.contains("chathistory") || caps.contains("draft/chathistory") else { return }
			self?.chathistoryRequested.insert(key)
			// When we know the most-recent msgid we observed last
			// session, fire AFTER to fetch only the gap. Otherwise
			// fall back to the cold-start LATEST 100. AFTER batches
			// get diverted via `pendingChathistoryAfter` so historic
			// messages don't bump unread/highlight counts; LATEST
			// stays on the live append path so the existing
			// notification heuristics keep working.
			if let lastSeen, !lastSeen.isEmpty {
				self?.pendingChathistoryAfter.insert(key)
				try? await conn.send("CHATHISTORY AFTER \(name) msgid=\(lastSeen) 100")
			} else {
				try? await conn.send("CHATHISTORY LATEST \(name) * 100")
			}
		}
	}

	/// Resolves the configured CHATHISTORY page size, falling back to the
	/// shipped default when the pref is unset. Clamped to `1...500` —
	/// most IRCv3 servers accept up to ~1000 per `BEFORE`, but 500 keeps
	/// a single round-trip responsive even on slow networks.
	public static func chathistoryPageSize() -> Int {
		let raw = UserDefaults.standard.object(forKey: PreferencesKeys.chathistoryPageSize) as? Int
			?? PreferencesKeys.chathistoryPageSizeFallback
		return max(1, min(500, raw))
	}

	/// Public entry point for the lazy "load older messages" affordance.
	/// Triggered by `MessageBufferView`'s scroll-near-top observer.
	/// Idempotent under concurrent calls — the in-flight guard on
	/// `Channel.isLoadingHistory` and the `pendingChathistoryBackfill`
	/// set together prevent overlapping requests for the same channel.
	public func requestMoreHistory(for channel: Channel) {
		guard channel.hasMoreHistoryAbove, !channel.isLoadingHistory else { return }
		let key = channel.name.lowercased()
		let limit = Self.chathistoryPageSize()
		// Anchor BEFORE on the oldest known msgid when we have one, falling
		// back to the oldest message's server-time when we only have a
		// timestamp, falling back to `*` (server picks "right now") when
		// the channel buffer is empty.
		let anchor = if let id = channel.oldestKnownMsgID, !id.isEmpty {
			"msgid=\(id)"
		} else if let id = channel.messages.compactMap(\.msgid).first {
			"msgid=\(id)"
		} else if let oldest = channel.messages.first {
			"timestamp=\(Self.ircTimestamp(oldest.timestamp))"
		} else {
			"*"
		}
		let target = channel.name
		let conn = connection
		channel.isLoadingHistory = true
		pendingChathistoryBackfill.insert(key)
		pendingChathistoryLimits[key] = limit
		Task { [weak self, weak channel] in
			let caps = await conn.enabledCaps
			guard caps.contains("chathistory") || caps.contains("draft/chathistory") else {
				await MainActor.run {
					channel?.isLoadingHistory = false
					self?.pendingChathistoryBackfill.remove(key)
					self?.pendingChathistoryLimits.removeValue(forKey: key)
				}
				return
			}
			try? await conn.send("CHATHISTORY BEFORE \(target) \(anchor) \(limit)")
		}
	}

	private func handleBatch(_ message: IRCLineParserResult) {
		guard let first = message.params.first else { return }
		if first.hasPrefix("+") {
			// Start: BATCH +ref <type> [<params>...]
			let ref = String(first.dropFirst())
			guard message.params.count >= 3 else { return }
			let type = message.params[1]
			guard type == "chathistory" || type == "draft/chathistory" else { return }
			let target = message.params[2]
			let key = target.lowercased()
			// Distinguish the three chathistory cases:
			// 1. BEFORE backfill (lazy scroll-up) → divert + prepend
			// 2. AFTER cold-start gap fill → divert + chronological merge
			// 3. LATEST cold-start (no anchor) → don't divert; messages
			//    flow through the live append path so existing UX
			//    preserves notifications + unread counts as today.
			let direction: ChathistoryBatch.Direction
			if pendingChathistoryBackfill.remove(key) != nil {
				direction = .before
			} else if pendingChathistoryAfter.remove(key) != nil {
				direction = .after
			} else {
				return
			}
			activeChathistoryBatches[ref] = ChathistoryBatch(
				target: target,
				direction: direction,
			)
		} else if first.hasPrefix("-") {
			let ref = String(first.dropFirst())
			guard let ctx = activeChathistoryBatches.removeValue(forKey: ref) else { return }
			finalizeChathistoryBatch(ctx)
		}
	}

	private func finalizeChathistoryBatch(_ ctx: ChathistoryBatch) {
		let key = ctx.target.lowercased()
		let requestedLimit = pendingChathistoryLimits.removeValue(forKey: key)
		guard let channel = server.channels.first(where: { $0.name.lowercased() == key }) else {
			return
		}
		channel.isLoadingHistory = false

		let received = ctx.buffer
		// Dedup against existing in-channel messages by msgid so an
		// overlap with what we already have doesn't double-show.
		let existing = Set(channel.messages.compactMap(\.msgid))
		let novel = received.filter { msg in
			guard let m = msg.msgid else { return true }
			return !existing.contains(m)
		}

		if !novel.isEmpty {
			switch ctx.direction {
			case .before:
				channel.messages.insert(contentsOf: novel, at: 0)
				if let oldest = novel.compactMap(\.msgid).first {
					channel.oldestKnownMsgID = oldest
				}
			case .after:
				// AFTER messages may interleave with live messages that
				// arrived during the JOIN handshake; merge in
				// chronological order via per-message insertion. Cheap
				// at the 500-row scrollback cap.
				for msg in novel {
					let idx = channel.messages.firstIndex {
						$0.timestamp > msg.timestamp
					} ?? channel.messages.endIndex
					channel.messages.insert(msg, at: idx)
				}
				// Advance lastSeen to the newest msgid we just absorbed
				// so the next reconnect anchors past it.
				if let newest = novel.compactMap(\.msgid).last {
					server.lastSeenMsgIDs[key] = newest
					onChannelsChanged?()
				}
			}
			let sid = server.id
			let target = ctx.target
			Task {
				for msg in novel {
					await ScrollbackStore.shared.append(
						serverId: sid,
						target: target,
						message: msg,
					)
				}
			}
		}

		// Server returned fewer rows than asked → that's the head of
		// the channel's history; stop firing further BEFORE-direction
		// backfill requests. (Doesn't apply to AFTER — that's about
		// how much we missed since reconnect, not channel-head.)
		if ctx.direction == .before,
		   let lim = requestedLimit,
		   received.count < lim
		{
			channel.hasMoreHistoryAbove = false
		}
	}

	/// IRCv3 server-time format: `YYYY-MM-DDTHH:mm:ss.sssZ` (UTC).
	private static func ircTimestamp(_ date: Date) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter.string(from: date)
	}

	// MARK: - bouncer-networks (soju)

	/// Send `BOUNCER LISTNETWORKS` once on welcome when the
	/// `soju.im/bouncer-networks` cap was negotiated, so we get the
	/// initial list of networks the bouncer is fronting. With
	/// `soju.im/bouncer-networks-notify` also negotiated the bouncer
	/// will additionally push BOUNCER NETWORK lines on changes —
	/// `handleBouncer` updates `server.bouncerNetworks` in either case.
	private func requestBouncerNetworksIfNeeded() {
		// BIND'd connections are scoped to a single upstream network;
		// they don't need (and shouldn't poll for) the full network
		// list. The discovery / control Server (no bouncerNetID)
		// is the canonical source of network state.
		guard server.bouncerNetID == nil else { return }
		let conn = connection
		Task { [weak self] in
			let caps = await conn.enabledCaps
			guard caps.contains("soju.im/bouncer-networks") else { return }
			await MainActor.run {
				self?.recordServer(Message(
					sender: "*",
					content: "discovering bouncer networks",
					kind: .server,
				))
			}
			try? await conn.send("BOUNCER LISTNETWORKS")
		}
	}

	private func handleBouncer(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let sub = message.params[0].uppercased()
		guard sub == "NETWORK" else {
			// Layer 2A is read-only: ignore ack lines for ADD / CHANGE /
			// DEL subcommands the user can't trigger yet, and FAIL
			// replies (those flow through the default unhandled path
			// for visibility in the server console).
			return
		}
		let netid = message.params[1]
		let attrsRaw = message.params.count >= 3 ? message.params[2] : ""

		// Per the spec, `BOUNCER NETWORK <netid> *` is a removal
		// notification. Drop the network from local state.
		if attrsRaw == "*" {
			if let idx = server.bouncerNetworks.firstIndex(where: { $0.id == netid }) {
				let removed = server.bouncerNetworks.remove(at: idx)
				let label = removed.name ?? removed.host ?? netid
				recordServer(Message(
					sender: "*",
					content: "bouncer network \(label) removed",
					kind: .server,
				))
			}
			return
		}

		let attributes = IRCLineParser.parseAttributeString(attrsRaw)
		if let idx = server.bouncerNetworks.firstIndex(where: { $0.id == netid }) {
			var existing = server.bouncerNetworks[idx]
			let priorState = existing.state
			existing.merge(attributes)
			server.bouncerNetworks[idx] = existing
			if priorState != existing.state {
				let label = existing.name ?? existing.host ?? netid
				recordServer(Message(
					sender: "*",
					content: "bouncer network \(label) → \(existing.state.rawValue)",
					kind: .server,
				))
			}
		} else {
			let new = BouncerNetwork(id: netid, attributes: attributes)
			server.bouncerNetworks.append(new)
			let label = new.name ?? new.host ?? netid
			recordServer(Message(
				sender: "*",
				content: "bouncer network \(label) (\(new.state.rawValue))",
				kind: .server,
			))
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
				guard let self, !Task.isCancelled else { return }
				await sendNotifyPoll()
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
			uniqueKeysWithValues: server.notifyList.map { ($0.lowercased(), $0) },
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
				if let lcMask, Self.globMatch(pattern: lcEntry, input: lcMask) {
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
		   now.timeIntervalSince(last) < Self.ctcpCooldownInterval
		{
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

		guard let reply else { return }
		ctcpReplyCooldown[key] = now

		// Breadcrumb in the server console so the user can see that their
		// client answered a CTCP request — matches the mIRC convention.
		recordServer(Message(
			sender: sender,
			content: "CTCP \(command) — replied",
			kind: .server,
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
			kind: .server,
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
			kind: .server,
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

	// MARK: - Lag measurement

	/// Begin the periodic client-initiated PING loop. Sends a PING every
	/// 30 s while the connection stays active; each tick's timestamp doubles
	/// as the token we match against the incoming PONG to compute lag.
	private func startPingLoop() {
		stopPingLoop()
		pingTask = Task { @MainActor [weak self] in
			while let self, !Task.isCancelled {
				guard server.isActive else { return }
				let token = "bryggaping\(Int(Date().timeIntervalSince1970 * 1000))"
				pendingPings[token] = Date()
				server.lastPingAt = Date()
				try? await connection.send("PING :\(token)")
				try? await Task.sleep(nanoseconds: 30_000_000_000)
			}
		}
	}

	private func stopPingLoop() {
		pingTask?.cancel()
		pingTask = nil
		pendingPings.removeAll()
		server.lag = nil
	}

	/// Match an incoming PONG against the outstanding PING tokens and
	/// publish the round-trip time on `server.lag`.
	private func handlePong(_ message: IRCLineParserResult) {
		guard let token = message.params.last,
		      let sentAt = pendingPings.removeValue(forKey: token) else { return }
		server.lag = Date().timeIntervalSince(sentAt)
	}

	/// Handles an incoming TAGMSG carrying an IRCv3 `+typing` client tag.
	/// `active` keeps the sender visible in the indicator for 6s; `paused`
	/// and `done` clear them immediately.
	private func handleTagmsg(_ message: IRCLineParserResult) {
		guard let target = message.params.first else { return }
		// Accept both the standardized `+typing` and the pre-standardization
		// `+draft/typing` tag name — some ircds still relay the draft form.
		let typing = message.tags["+typing"] ?? message.tags["+draft/typing"]
		guard let typing else { return }
		guard let nick = message.senderNickname, !isOwnMessage(nick) else { return }

		// Channel TAGMSG (target is a channel) lands in that channel's row.
		// Direct TAGMSG (target is our nick) lands in the sender's query tab;
		// the tab is auto-created so a typing indicator can show even before
		// the first PRIVMSG arrives.
		let channelName: String
		let isChannelTarget = target.hasPrefix("#") || target.hasPrefix("&")
		if isChannelTarget {
			channelName = target
		} else {
			channelName = nick
		}

		let channel: Channel
		if let existing = server.channels.first(where: { $0.name == channelName }) {
			channel = existing
		} else if !isChannelTarget {
			// Auto-open a query tab for incoming PM typing so the indicator
			// shows up somewhere the user can actually see it.
			channel = Channel(name: channelName)
			channel.isPinned = server.pinnedChannels.contains(channelName.lowercased())
			server.channels.append(channel)
			loadScrollbackIfNeeded(for: channel)
			onChannelsChanged?()
		} else {
			return
		}

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
			kind: .notice,
			msgid: message.tags["msgid"],
		)

		if target.hasPrefix("#") || target.hasPrefix("&") {
			if let channel = server.channels.first(where: { $0.name == target }) {
				record(msg, in: channel)
				if let id = msg.msgid {
					server.lastSeenMsgIDs[channel.name.lowercased()] = id
					onChannelsChanged?()
				}
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
			// Always consult scrollback here — covers both newly-created
			// channels and pre-created-but-not-rehydrated ones that the
			// restore path missed (e.g. because the user typed `/join`
			// before the rehydrate Task iterated the channel list).
			loadScrollbackIfNeeded(for: channel)
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

	/// Handles a channel MODE change. Applies `+o/+v/+h/+a/+q` prefix modes
	/// so the user list re-renders with the matching `@`/`+`/`%`/`&`/`~`.
	/// Channel-level modes without a user argument (e.g. `+n`, `+m`) and
	/// user-modes on our own nick are currently recorded as a system line
	/// but not parsed further.
	private func handleMode(_ message: IRCLineParserResult) {
		guard message.params.count >= 2 else { return }
		let target = message.params[0]
		let modeString = message.params[1]
		let arguments = Array(message.params.dropFirst(2))
		let setter = message.senderNickname ?? message.senderString ?? "server"

		// User-mode changes on our own nick don't have channel context —
		// just log them for visibility.
		guard target.hasPrefix("#") || target.hasPrefix("&") else {
			recordServer(Message(
				sender: "**",
				content: "\(setter) sets mode \(modeString) on \(target)",
				kind: .mode,
			))
			return
		}

		guard let channel = server.channels.first(where: { $0.name == target }) else { return }

		// Modes that take a nickname argument and map to a user-prefix flag.
		let prefixModes: Set<Character> = ["o", "v", "h", "a", "q"]
		// Modes that consume an argument but don't map to a prefix (bans,
		// channel keys, user limits, invex, excepts). We skip past their
		// argument so the indexing stays aligned.
		let argumentModes: Set<Character> = ["b", "e", "I", "k", "l", "f", "j"]

		var argIndex = 0
		var sign: Character = "+"
		var summaryParts: [String] = []

		for char in modeString {
			if char == "+" || char == "-" {
				sign = char
				continue
			}
			if prefixModes.contains(char) {
				guard argIndex < arguments.count else { break }
				let nick = arguments[argIndex]
				argIndex += 1
				if let user = channel.users.first(where: { $0.nickname == nick }) {
					if sign == "+" {
						user.modes.insert(char)
					} else {
						user.modes.remove(char)
					}
				}
				summaryParts.append("\(sign)\(char) \(nick)")
			} else if argumentModes.contains(char) {
				// Skip the argument; these don't affect the user list.
				if argIndex < arguments.count { argIndex += 1 }
				summaryParts.append("\(sign)\(char)")
			} else {
				summaryParts.append("\(sign)\(char)")
			}
		}

		let summary = summaryParts.joined(separator: " ")
		record(
			Message(
				sender: setter,
				content: "sets mode: \(summary)",
				kind: .mode,
			),
			in: channel,
		)
	}

	private func handlePart(_ message: IRCLineParserResult) {
		guard let channelName = message.params.first else { return }
		let nick = message.senderNickname ?? ""
		let reason = message.params.count > 1 ? message.params[1] : ""

		guard let channel = server.channels.first(where: { $0.name == channelName }) else { return }

		if isOwnMessage(nick) {
			channel.isJoined = false
			channel.users.removeAll()
			// Scrollback line so the user can see they left — otherwise
			// /part / /leave silently flips state with no feedback.
			let ownText = reason.isEmpty
				? "you left \(channelName)"
				: "you left \(channelName) (\(reason))"
			record(Message(sender: nick, content: ownText, kind: .part), in: channel)
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
			   bangIdx < atIdx
			{
				nick = String(rest[..<bangIdx])
				username = String(rest[rest.index(after: bangIdx) ..< atIdx])
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
