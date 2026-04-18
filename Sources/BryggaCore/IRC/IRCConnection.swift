/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

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

	// MARK: - State

	public enum State: Sendable, Equatable {
		case disconnected
		case connecting
		case registering  // connected at TCP, waiting for 001 (welcome)
		case active       // welcome received
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
		realName: String? = nil
	) {
		self.host = host
		self.port = port
		self.useTLS = useTLS
		self.nickname = nickname
		self.username = username ?? nickname
		self.realName = realName ?? nickname

		var msgContinuation: AsyncStream<IRCLineParserResult>.Continuation!
		self.messages = AsyncStream { continuation in
			msgContinuation = continuation
		}
		self.messageContinuation = msgContinuation

		var stateCont: AsyncStream<State>.Continuation!
		self.stateChanges = AsyncStream { continuation in
			stateCont = continuation
		}
		self.stateContinuation = stateCont
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
		guard case .disconnected = state else {
			throw ConnectionError.invalidState("cannot connect from \(state)")
		}

		setState(.connecting)

		let parameters: NWParameters = useTLS ? .tls : .tcp
		let endpointHost = NWEndpoint.Host(host)
		guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
			setState(.failed("invalid port \(port)"))
			throw ConnectionError.invalidPort(Int(port))
		}

		let conn = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
		self.connection = conn

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			var resumed = false
			let resume: (Result<Void, Error>) -> Void = { result in
				guard !resumed else { return }
				resumed = true
				continuation.resume(with: result)
			}

			conn.stateUpdateHandler = { [weak self] nwState in
				switch nwState {
				case .ready:
					resume(.success(()))
					Task { [weak self] in await self?.onReady() }
				case .failed(let error):
					let reason = error.localizedDescription
					resume(.failure(ConnectionError.networkFailed(reason)))
					Task { [weak self] in await self?.onFailed(reason) }
				case .cancelled:
					resume(.failure(ConnectionError.cancelled))
				default:
					break
				}
			}

			conn.start(queue: queue)
		}
	}

	/// Send a raw IRC protocol line. The trailing `\r\n` is appended automatically.
	public func send(_ line: String) async throws {
		guard let conn = connection else {
			throw ConnectionError.notConnected
		}

		let payload = Data((line + "\r\n").utf8)

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			conn.send(content: payload, completion: .contentProcessed { error in
				if let error = error {
					continuation.resume(throwing: ConnectionError.networkFailed(error.localizedDescription))
				} else {
					continuation.resume()
				}
			})
		}
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

	private func onReady() async {
		setState(.registering)
		// IRC registration handshake (no PASS for now).
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

		messageContinuation.finish()
	}

	private func receiveChunk(_ conn: NWConnection) async throws -> Data? {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
			conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
				if let error = error {
					continuation.resume(throwing: error)
				} else if isComplete, (data == nil || data?.isEmpty == true) {
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
			if line.last == 0x0D {  // trim trailing \r
				line = line.dropLast()
			}
			receiveBuffer.removeSubrange(..<range.upperBound)

			guard let text = String(data: Data(line), encoding: .utf8)
				?? String(data: Data(line), encoding: .isoLatin1) else {
				continue
			}

			guard !text.isEmpty else { continue }

			// Built-in PING handler so the connection stays alive even if the
			// consumer hasn't wired its own responder yet.
			if text.hasPrefix("PING ") {
				let reply = "PONG " + text.dropFirst(5)
				Task { [weak self] in
					try? await self?.send(reply)
				}
			}

			if let parsed = IRCLineParser.parse(text) {
				// Registration complete when 001 (RPL_WELCOME) arrives.
				if parsed.commandNumeric == 1 && state == .registering {
					setState(.active)
				}
				messageContinuation.yield(parsed)
			}
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
