// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation
import Network

/// A single IRC server connection.
///
/// Thread-safe by construction (actor). Uses Network.framework with async/await
/// and exposes parsed incoming messages via an `AsyncStream<IRCLineParserResult>`.
public actor IRCConnection {
	// MARK: - Configuration

	public nonisolated let host: String
	public nonisolated let port: UInt16
	public nonisolated let useTLS: Bool
	public nonisolated let nickname: String
	public nonisolated let username: String
	public nonisolated let realName: String
	public nonisolated let saslAccount: String?
	public nonisolated let saslPassword: String?
	/// Absolute path to a PKCS#12 file carrying the client certificate +
	/// private key used for TLS client auth (required by SASL EXTERNAL).
	/// `nil` disables client-cert presentation and EXTERNAL.
	public nonisolated let clientCertificatePath: String?
	public nonisolated let clientCertificatePassphrase: String?
	/// soju netid this connection is locked to via `BOUNCER BIND`.
	/// When set and the `soju.im/bouncer-networks` cap is negotiated,
	/// `BOUNCER BIND <netid>` is sent during registration before
	/// `CAP END`. `nil` for non-bouncer connections and for the
	/// unbound discovery / control connection of a bouncer.
	public nonisolated let bouncerNetID: String?

	// MARK: - State

	public enum State: Sendable, Equatable {
		case disconnected
		case connecting
		case registering // connected at TCP, waiting for 001 (welcome)
		case active // welcome received
		case disconnecting
		case failed(String)
	}

	public private(set) var state: State = .disconnected

	// MARK: - Streams

	/// Parsed incoming IRC messages. The stream finishes when the connection
	/// is disconnected.
	public nonisolated let messages: AsyncStream<IRCLineParserResult>

	private let messageContinuation: AsyncStream<IRCLineParserResult>.Continuation

	/// State changes as they occur.
	public nonisolated let stateChanges: AsyncStream<State>

	private let stateContinuation: AsyncStream<State>.Continuation

	// MARK: - Internals

	private var connection: NWConnection?
	private var receiveBuffer = Data()
	private var readTask: Task<Void, Never>?

	private let queue = DispatchQueue(label: "com.brygga.IRCConnection")

	// MARK: - Init

	public init(
		host: String,
		port: UInt16 = 6697,
		useTLS: Bool = true,
		nickname: String,
		username: String? = nil,
		realName: String? = nil,
		saslAccount: String? = nil,
		saslPassword: String? = nil,
		clientCertificatePath: String? = nil,
		clientCertificatePassphrase: String? = nil,
		bouncerNetID: String? = nil,
	) {
		self.host = host
		self.port = port
		self.useTLS = useTLS
		self.nickname = nickname
		self.username = username ?? nickname
		self.realName = realName ?? nickname
		self.saslAccount = saslAccount
		self.saslPassword = saslPassword
		self.clientCertificatePath = clientCertificatePath
		self.clientCertificatePassphrase = clientCertificatePassphrase
		self.bouncerNetID = bouncerNetID

		var msgContinuation: AsyncStream<IRCLineParserResult>.Continuation!
		messages = AsyncStream { continuation in
			msgContinuation = continuation
		}
		messageContinuation = msgContinuation

		var stateCont: AsyncStream<State>.Continuation!
		stateChanges = AsyncStream { continuation in
			stateCont = continuation
		}
		stateContinuation = stateCont
	}

	deinit {
		messageContinuation.finish()
		stateContinuation.finish()
	}

	// MARK: - Public API

	/// Opens the TCP (or TLS) connection and registers with the server using
	/// NICK + USER. Completes when the connection becomes ready at the TCP
	/// level. Observe `stateChanges` to know when `.active` is reached (after
	/// the server sends 001 RPL_WELCOME).
	public func connect() async throws {
		switch state {
		case .disconnected, .failed:
			break // reconnect OK from these states
		default:
			throw ConnectionError.invalidState("cannot connect from \(state)")
		}

		// Reset leftover state from a prior session.
		readTask?.cancel()
		readTask = nil
		connection?.cancel()
		connection = nil
		receiveBuffer.removeAll()
		resetRateBucket()

		setState(.connecting)

		let parameters: NWParameters
		if useTLS {
			let tlsOptions = NWProtocolTLS.Options()
			if let certPath = clientCertificatePath, !certPath.isEmpty {
				do {
					let identity = try ClientIdentity.load(
						path: certPath,
						passphrase: clientCertificatePassphrase,
					)
					sec_protocol_options_set_local_identity(
						tlsOptions.securityProtocolOptions,
						identity,
					)
				} catch {
					setState(.failed("client cert load failed: \(error)"))
					throw error
				}
			}
			parameters = NWParameters(tls: tlsOptions)
		} else {
			parameters = .tcp
		}
		let endpointHost = NWEndpoint.Host(host)
		guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
			setState(.failed("invalid port \(port)"))
			throw ConnectionError.invalidPort(Int(port))
		}

		let conn = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
		connection = conn

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			let resumer = SingleShotResumer(continuation: continuation)

			conn.stateUpdateHandler = { [weak self] nwState in
				switch nwState {
				case .ready:
					resumer.resume(.success(()))
					Task { [weak self] in await self?.onReady() }
				case let .failed(error):
					let reason = error.localizedDescription
					resumer.resume(.failure(ConnectionError.networkFailed(reason)))
					Task { [weak self] in await self?.onFailed(reason) }
				case .cancelled:
					resumer.resume(.failure(ConnectionError.cancelled))
				default:
					break
				}
			}

			conn.start(queue: queue)
		}
	}

	/// Send a raw IRC protocol line. The trailing `\r\n` is appended
	/// automatically, and any embedded CR / LF in the caller's line is
	/// stripped first to prevent IRC command injection — otherwise a
	/// user-supplied `/topic`, `/away`, `/me`, leave-reason, PRIVMSG
	/// body, etc. could smuggle a second wire command via pasted or
	/// adversarial text.
	public func send(_ line: String, bypassRateLimit: Bool = false) async throws {
		guard let conn = connection else {
			throw ConnectionError.notConnected
		}

		let sanitized = line
			.replacingOccurrences(of: "\r", with: "")
			.replacingOccurrences(of: "\n", with: " ")
		let payload = Data((sanitized + "\r\n").utf8)

		if !bypassRateLimit {
			await acquireTokens(payload.count)
		}

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			conn.send(content: payload, completion: .contentProcessed { error in
				if let error {
					continuation.resume(throwing: ConnectionError.networkFailed(error.localizedDescription))
				} else {
					continuation.resume()
				}
			})
		}
	}

	// MARK: - Outbound flood protection (token bucket)

	/// Max outbound bytes allowed in a burst.
	private static let rateMaxTokens: Double = 1200
	/// Steady-state refill rate (bytes / second).
	private static let rateRefillPerSec: Double = 300

	private var rateTokens: Double = rateMaxTokens
	private var rateLastRefill: Date = .init()

	private func acquireTokens(_ count: Int) async {
		let need = Double(count)
		refillTokens()
		if rateTokens < need {
			let deficit = need - rateTokens
			let waitSec = max(deficit / Self.rateRefillPerSec, 0)
			try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
			refillTokens()
		}
		rateTokens = max(0, rateTokens - need)
	}

	private func refillTokens() {
		let now = Date()
		let elapsed = now.timeIntervalSince(rateLastRefill)
		rateTokens = min(Self.rateMaxTokens, rateTokens + elapsed * Self.rateRefillPerSec)
		rateLastRefill = now
	}

	private func resetRateBucket() {
		rateTokens = Self.rateMaxTokens
		rateLastRefill = Date()
	}

	/// Sends QUIT (best-effort) and tears down the connection.
	public func disconnect(quitMessage: String? = nil) async {
		guard state != .disconnected, state != .disconnecting else { return }

		setState(.disconnecting)

		if let conn = connection, conn.state == .ready {
			let quitLine = quitMessage.map { "QUIT :\($0)" } ?? "QUIT"
			try? await send(quitLine)
		}

		readTask?.cancel()
		readTask = nil

		connection?.cancel()
		connection = nil
		receiveBuffer.removeAll()

		setState(.disconnected)
	}

	// MARK: - Private lifecycle

	/// Caps we ask for during CAP LS. Servers that support them will include
	/// them in their LS response; we then request the intersection.
	private static let desiredCaps: Set<String> = [
		"sasl",
		"server-time",
		"multi-prefix",
		"userhost-in-names",
		"chghost",
		"account-tag",
		"account-notify",
		"away-notify",
		"invite-notify",
		"batch",
		"chathistory",
		"draft/chathistory",
		"message-tags",
		// soju-style bouncer discovery + live state notifications.
		// Negotiated together so we can list networks once on welcome
		// and then react to BOUNCER NETWORK push messages without
		// re-polling. Servers that aren't bouncers simply won't
		// advertise these and the client falls through unaffected.
		"soju.im/bouncer-networks",
		"soju.im/bouncer-networks-notify",
	]

	public private(set) var enabledCaps: Set<String> = []
	private var supportedCaps: Set<String> = []
	private var capNegotiationActive: Bool = false

	/// SASL mechanisms advertised by the server via `CAP LS sasl=…`.
	/// Empty when the server didn't list any — we fall back to PLAIN in that
	/// case for compatibility with servers that advertise bare `sasl`.
	private var saslMechanisms: [String] = []
	/// Mechanism we chose to use for the current handshake.
	private var saslMechanism: String?
	/// Live SCRAM-SHA-256 state machine, populated only when `saslMechanism`
	/// is SCRAM-SHA-256.
	private var scramClient: SCRAMSHA256Client?

	private var useSasl: Bool {
		// EXTERNAL only needs a TLS client identity — no password required.
		if let certPath = clientCertificatePath, !certPath.isEmpty { return true }
		guard let account = saslAccount, !account.isEmpty,
		      let password = saslPassword, !password.isEmpty else { return false }
		return true
	}

	private func onReady() async {
		setState(.registering)
		// Always negotiate capabilities, even without SASL creds — we want
		// server-time, multi-prefix, away-notify, etc. regardless.
		capNegotiationActive = true
		supportedCaps = []
		enabledCaps = []
		saslMechanisms = []
		saslMechanism = nil
		scramClient = nil
		try? await send("CAP LS 302")
		try? await send("NICK \(nickname)")
		try? await send("USER \(username) 0 * :\(realName)")
		startReadLoop()
	}

	private func onFailed(_ reason: String) {
		setState(.failed(reason))
		readTask?.cancel()
		readTask = nil
		connection?.cancel()
		connection = nil
	}

	private func setState(_ newState: State) {
		guard state != newState else { return }
		state = newState
		stateContinuation.yield(newState)
	}

	private func startReadLoop() {
		guard readTask == nil else { return }
		readTask = Task { [weak self] in
			await self?.readLoop()
		}
	}

	private func readLoop() async {
		while !Task.isCancelled {
			guard let conn = connection else { break }

			let chunk: Data?
			do {
				chunk = try await receiveChunk(conn)
			} catch {
				onFailed("read error: \(error.localizedDescription)")
				break
			}

			guard let data = chunk, !data.isEmpty else {
				// EOF
				onFailed("connection closed by peer")
				break
			}

			receiveBuffer.append(data)
			drainBuffer()
		}
		// Do NOT finish messageContinuation here — the stream must stay
		// alive across reconnect cycles. It's only finished on deinit.
	}

	private func receiveChunk(_ conn: NWConnection) async throws -> Data? {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
			conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
				if let error {
					continuation.resume(throwing: error)
				} else if isComplete, data == nil || data?.isEmpty == true {
					continuation.resume(returning: nil)
				} else {
					continuation.resume(returning: data)
				}
			}
		}
	}

	private func drainBuffer() {
		// Split on \n and tolerate bare \r by trimming it.
		while let range = receiveBuffer.firstRange(of: Data([0x0A])) {
			var line = receiveBuffer[..<range.lowerBound]
			if line.last == 0x0D { // trim trailing \r
				line = line.dropLast()
			}
			receiveBuffer.removeSubrange(..<range.upperBound)

			guard let text = String(data: Data(line), encoding: .utf8)
				?? String(data: Data(line), encoding: .isoLatin1)
			else {
				continue
			}

			guard !text.isEmpty else { continue }

			// Built-in PING handler so the connection stays alive even if the
			// consumer hasn't wired its own responder yet. PONG bypasses the
			// outbound rate limiter — being slow to reply risks a server-side
			// timeout disconnect.
			if text.hasPrefix("PING ") {
				let reply = "PONG " + text.dropFirst(5)
				Task { [weak self] in
					try? await self?.send(reply, bypassRateLimit: true)
				}
			}

			if let parsed = IRCLineParser.parse(text) {
				// Drive capability + SASL handshake internally; still yield the
				// lines so the UI's server console can log them.
				if capNegotiationActive {
					handleCapLine(parsed)
				}
				// Post-registration CAP NEW / CAP DEL always tracked.
				handleCapUpdate(parsed)
				// Registration complete when 001 (RPL_WELCOME) arrives.
				if parsed.commandNumeric == 1, state == .registering {
					setState(.active)
				}
				messageContinuation.yield(parsed)
			}
		}
	}

	/// Pre-001 CAP negotiation. Drives LS → REQ → ACK → (optional SASL) → END.
	private func handleCapLine(_ msg: IRCLineParserResult) {
		switch msg.command {
		case "CAP":
			guard msg.params.count >= 2 else { return }
			let subcommand = msg.params[1].uppercased()
			switch subcommand {
			case "LS":
				handleCapLS(msg)
			case "ACK":
				handleCapACK(msg)
			case "NAK":
				finishCapNegotiation()
			default:
				break
			}
		case "AUTHENTICATE":
			handleAuthenticate(msg)
		default:
			break
		}
		switch msg.commandNumeric {
		case 903:
			// RPL_SASLSUCCESS — end cap negotiation so 001 can follow.
			finishCapNegotiation()
		case 902, 904, 905, 906, 907:
			// SASL failure — still end so the connection can proceed (unauthed).
			finishCapNegotiation()
		default:
			break
		}
	}

	private func handleCapLS(_ msg: IRCLineParserResult) {
		// Multi-line LS: params[2] is "*" for continuation; final line has caps in params[2].
		let isContinuation = msg.params.count >= 4 && msg.params[2] == "*"
		let capsField = msg.params.last ?? ""
		for token in capsField.split(separator: " ") {
			let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			let name = String(parts[0])
			supportedCaps.insert(name)
			// Pick up the SASL mechanism list when the server advertises it
			// as `sasl=PLAIN,SCRAM-SHA-256,EXTERNAL`.
			if name == "sasl", parts.count == 2 {
				saslMechanisms = parts[1]
					.split(separator: ",")
					.map { $0.uppercased() }
			}
		}
		if isContinuation { return }

		let toRequest = Self.desiredCaps.intersection(supportedCaps)
		if toRequest.isEmpty {
			finishCapNegotiation()
			return
		}
		let list = toRequest.sorted().joined(separator: " ")
		Task { [weak self] in try? await self?.send("CAP REQ :\(list)") }
	}

	/// Dispatches an incoming `AUTHENTICATE …` line to the active mechanism's
	/// state machine. Supports PLAIN (single round) and SCRAM-SHA-256 (three
	/// rounds: client-first → server-first → client-final → server-final).
	private func handleAuthenticate(_ msg: IRCLineParserResult) {
		guard let payload = msg.params.first else { return }
		switch saslMechanism {
		case "EXTERNAL":
			// EXTERNAL: the client identity has already been presented in the
			// TLS handshake. Reply to `+` with a single `+` (empty authzid)
			// so the server uses the cert's subject.
			guard payload == "+" else { return }
			Task { [weak self] in try? await self?.send("AUTHENTICATE +") }

		case "PLAIN":
			// PLAIN: server → "+", we → base64("\0user\0pass").
			guard payload == "+",
			      let account = saslAccount,
			      let password = saslPassword else { return }
			let blob = "\0\(account)\0\(password)"
			let encoded = Data(blob.utf8).base64EncodedString()
			Task { [weak self] in try? await self?.send("AUTHENTICATE \(encoded)") }

		case "SCRAM-SHA-256":
			guard scramClient != nil else { return }
			if payload == "+" {
				// Server ready for client-first-message.
				let clientFirst = scramClient!.clientFirstMessage()
				let encoded = Data(clientFirst.utf8).base64EncodedString()
				Task { [weak self] in try? await self?.send("AUTHENTICATE \(encoded)") }
				return
			}
			// Base64-decode the server's payload and route by step.
			guard let decoded = Data(base64Encoded: payload),
			      let serverMessage = String(data: decoded, encoding: .utf8)
			else {
				abortSasl()
				return
			}
			if serverMessage.hasPrefix("v=") {
				// server-final-message — verify signature; let 903 close cap.
				do {
					try scramClient!.verifyServerFinal(serverMessage)
				} catch {
					abortSasl()
				}
				return
			}
			// Otherwise: server-first-message. Compute and send client-final.
			do {
				let clientFinal = try scramClient!.clientFinalMessage(serverFirst: serverMessage)
				let encoded = Data(clientFinal.utf8).base64EncodedString()
				Task { [weak self] in try? await self?.send("AUTHENTICATE \(encoded)") }
			} catch {
				abortSasl()
			}

		default:
			break
		}
	}

	/// Abort the in-flight SASL exchange by sending `AUTHENTICATE *` and let
	/// the 904/906 numeric close cap negotiation.
	private func abortSasl() {
		scramClient = nil
		Task { [weak self] in try? await self?.send("AUTHENTICATE *") }
	}

	private func handleCapACK(_ msg: IRCLineParserResult) {
		let acked = (msg.params.last ?? "")
			.split(separator: " ")
			.map { String($0) }
		enabledCaps.formUnion(acked)

		if enabledCaps.contains("sasl"), useSasl {
			let mech = preferredSaslMechanism()
			saslMechanism = mech
			if mech == "SCRAM-SHA-256",
			   let account = saslAccount, let password = saslPassword
			{
				scramClient = SCRAMSHA256Client(username: account, password: password)
			}
			Task { [weak self] in try? await self?.send("AUTHENTICATE \(mech)") }
		} else {
			finishCapNegotiation()
		}
	}

	/// Preferred mechanism given `saslMechanisms`: EXTERNAL wins when a
	/// client cert is configured and the server advertises it; then
	/// SCRAM-SHA-256 over PLAIN. Falls back to PLAIN when the server
	/// advertised no mechanism list.
	private func preferredSaslMechanism() -> String {
		let hasCert = (clientCertificatePath?.isEmpty == false)
		if hasCert, saslMechanisms.contains("EXTERNAL") { return "EXTERNAL" }
		if saslMechanisms.contains("SCRAM-SHA-256") { return "SCRAM-SHA-256" }
		return "PLAIN"
	}

	/// Handle post-registration CAP NEW / CAP DEL so our `enabledCaps` stays current.
	private func handleCapUpdate(_ msg: IRCLineParserResult) {
		guard msg.command == "CAP", msg.params.count >= 2 else { return }
		let subcommand = msg.params[1].uppercased()
		let capsField = msg.params.last ?? ""
		let caps = Set(capsField.split(separator: " ").map {
			String($0.split(separator: "=").first ?? "")
		})
		switch subcommand {
		case "NEW":
			supportedCaps.formUnion(caps)
			let toRequest = Self.desiredCaps.intersection(caps)
			guard !toRequest.isEmpty else { return }
			let list = toRequest.sorted().joined(separator: " ")
			Task { [weak self] in try? await self?.send("CAP REQ :\(list)") }
		case "DEL":
			enabledCaps.subtract(caps)
			supportedCaps.subtract(caps)
		default:
			break
		}
	}

	private func finishCapNegotiation() {
		guard capNegotiationActive else { return }
		capNegotiationActive = false
		// soju spec: BOUNCER BIND must be sent before registration
		// completes (i.e. before CAP END). Only fire when the cap was
		// actually negotiated — bouncerNetID can survive on a Server
		// whose underlying bouncer isn't currently advertising the cap
		// (e.g. soju upgrade pending), and BIND on a non-bouncer would
		// be an error.
		let bind = bouncerNetID
		let capsHave = enabledCaps.contains("soju.im/bouncer-networks")
		Task { [weak self] in
			if let bind, !bind.isEmpty, capsHave {
				try? await self?.send("BOUNCER BIND \(bind)")
			}
			try? await self?.send("CAP END")
		}
	}

	// MARK: - Errors

	public enum ConnectionError: Error, Sendable, Equatable {
		case invalidState(String)
		case invalidPort(Int)
		case networkFailed(String)
		case cancelled
		case notConnected
	}
}

/// Serializes a single-shot `CheckedContinuation` resume across the
/// NWConnection state-update callbacks. NWConnection invokes its handler on
/// the serial queue we pass to `conn.start`, so concurrent access isn't an
/// issue — but Swift 6 strict concurrency requires a `Sendable` capture.
private final class SingleShotResumer: @unchecked Sendable {
	private var resumed = false
	private let continuation: CheckedContinuation<Void, Error>

	init(continuation: CheckedContinuation<Void, Error>) {
		self.continuation = continuation
	}

	func resume(_ result: Result<Void, Error>) {
		guard !resumed else { return }
		resumed = true
		continuation.resume(with: result)
	}
}
