/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation
import CryptoKit
import CommonCrypto

/// Client-side SCRAM-SHA-256 (RFC 7677) state machine without channel binding.
/// Drives the three-message exchange used by IRCv3 SASL:
/// 1. client sends `client-first-message`
/// 2. server replies `server-first-message`; client derives `client-final-message`
/// 3. server replies `server-final-message`; client verifies its signature
///
/// The username is sent as UTF-8 without full SASLprep. Most IRC networks
/// accept that; strict SASLprep compliance is out of scope for Brygga.
public struct SCRAMSHA256Client {
	public enum SCRAMError: Error, Equatable {
		case invalidState
		case malformedServerMessage
		case nonceMismatch
		case serverSignatureMismatch
	}

	private enum Step: Equatable {
		case initial
		case awaitingServerFirst(clientFirstBare: String)
		case awaitingServerFinal(expectedServerSignature: Data)
		case done
	}

	public let username: String
	public let password: String
	private let clientNonce: String
	private var step: Step = .initial

	public init(username: String, password: String, clientNonce: String? = nil) {
		self.username = username
		self.password = password
		self.clientNonce = clientNonce ?? Self.randomNonce()
	}

	/// Produce the plaintext `client-first-message`. The caller base64-encodes
	/// before sending over IRC's `AUTHENTICATE` command.
	public mutating func clientFirstMessage() -> String {
		let bare = "n=\(saslName(username)),r=\(clientNonce)"
		step = .awaitingServerFirst(clientFirstBare: bare)
		// gs2-header = "n,," → no channel binding, no authorization identity.
		return "n,,\(bare)"
	}

	/// Consume the plaintext `server-first-message` and produce the plaintext
	/// `client-final-message`.
	public mutating func clientFinalMessage(serverFirst: String) throws -> String {
		guard case .awaitingServerFirst(let clientFirstBare) = step else {
			throw SCRAMError.invalidState
		}
		let attrs = Self.parseAttributes(serverFirst)
		guard let fullNonce = attrs["r"], fullNonce.hasPrefix(clientNonce) else {
			throw SCRAMError.nonceMismatch
		}
		guard let saltB64 = attrs["s"], let salt = Data(base64Encoded: saltB64) else {
			throw SCRAMError.malformedServerMessage
		}
		guard let iterStr = attrs["i"], let iterations = Int(iterStr), iterations > 0 else {
			throw SCRAMError.malformedServerMessage
		}

		// c=biws is the base64 of the gs2-header "n,," (no channel binding).
		let channelBinding = "biws"
		let clientFinalWithoutProof = "c=\(channelBinding),r=\(fullNonce)"
		let authMessage = "\(clientFirstBare),\(serverFirst),\(clientFinalWithoutProof)"

		let saltedPassword = Self.pbkdf2SHA256(password: password, salt: salt, iterations: iterations, keyLength: 32)
		let clientKey = Self.hmacSHA256(key: saltedPassword, data: Data("Client Key".utf8))
		let storedKey = Data(SHA256.hash(data: clientKey))
		let clientSignature = Self.hmacSHA256(key: storedKey, data: Data(authMessage.utf8))
		let clientProof = Self.xor(clientKey, clientSignature)
		let serverKey = Self.hmacSHA256(key: saltedPassword, data: Data("Server Key".utf8))
		let serverSignature = Self.hmacSHA256(key: serverKey, data: Data(authMessage.utf8))

		step = .awaitingServerFinal(expectedServerSignature: serverSignature)
		return "\(clientFinalWithoutProof),p=\(clientProof.base64EncodedString())"
	}

	/// Verify the server's `v=<base64>` signature. Throws on mismatch.
	/// Uses a constant-time byte compare so a timing oracle can't be
	/// used to short-cut the server-signature check — defence in depth
	/// on top of the TLS tunnel SCRAM already runs inside.
	public mutating func verifyServerFinal(_ serverFinal: String) throws {
		guard case .awaitingServerFinal(let expected) = step else {
			throw SCRAMError.invalidState
		}
		let attrs = Self.parseAttributes(serverFinal)
		guard let verB64 = attrs["v"], let received = Data(base64Encoded: verB64) else {
			throw SCRAMError.malformedServerMessage
		}
		guard Self.constantTimeEquals(received, expected) else {
			throw SCRAMError.serverSignatureMismatch
		}
		step = .done
	}

	/// Length-checked byte-XOR-accumulate compare. Short-circuits **only**
	/// on length mismatch (which isn't secret); for equal-length inputs
	/// it visits every byte regardless of whether an early divergence
	/// was found.
	static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
		guard a.count == b.count else { return false }
		var diff: UInt8 = 0
		for i in 0..<a.count {
			diff |= a[i] ^ b[i]
		}
		return diff == 0
	}

	public var isFinished: Bool { step == .done }

	// MARK: - Primitives

	static func randomNonce(length: Int = 24) -> String {
		var bytes = [UInt8](repeating: 0, count: length)
		_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		// Base64 variant with `,` and `=` stripped so the nonce survives SCRAM
		// attribute parsing.
		return Data(bytes).base64EncodedString()
			.replacingOccurrences(of: "=", with: "")
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
	}

	static func hmacSHA256(key: Data, data: Data) -> Data {
		let symKey = SymmetricKey(data: key)
		let mac = HMAC<SHA256>.authenticationCode(for: data, using: symKey)
		return Data(mac)
	}

	static func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
		var derived = Data(count: keyLength)
		let passwordBytes = Array(password.utf8).map { Int8(bitPattern: $0) }
		let result = derived.withUnsafeMutableBytes { derivedBuf -> Int32 in
			salt.withUnsafeBytes { saltBuf -> Int32 in
				CCKeyDerivationPBKDF(
					CCPBKDFAlgorithm(kCCPBKDF2),
					passwordBytes, passwordBytes.count,
					saltBuf.bindMemory(to: UInt8.self).baseAddress, saltBuf.count,
					CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
					UInt32(iterations),
					derivedBuf.bindMemory(to: UInt8.self).baseAddress, keyLength
				)
			}
		}
		precondition(result == kCCSuccess, "PBKDF2 failed with \(result)")
		return derived
	}

	static func xor(_ a: Data, _ b: Data) -> Data {
		precondition(a.count == b.count)
		var out = Data(count: a.count)
		for i in 0..<a.count {
			out[i] = a[i] ^ b[i]
		}
		return out
	}

	/// Parse `key=value,key=value,...` into a dictionary. Only splits on the
	/// first `=` so base64 values containing `=` survive intact.
	static func parseAttributes(_ input: String) -> [String: String] {
		var out: [String: String] = [:]
		for pair in input.split(separator: ",", omittingEmptySubsequences: true) {
			if let eq = pair.firstIndex(of: "=") {
				let key = String(pair[..<eq])
				let value = String(pair[pair.index(after: eq)...])
				out[key] = value
			}
		}
		return out
	}

	/// Escape the two reserved SCRAM attribute characters per RFC 5802 §5.1.
	private func saslName(_ s: String) -> String {
		s.replacingOccurrences(of: "=", with: "=3D")
			.replacingOccurrences(of: ",", with: "=2C")
	}
}
