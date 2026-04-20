// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// Result of parsing a single IRC protocol line.
public struct IRCLineParserResult: Sendable, Equatable {
	public let tags: [String: String]
	public let senderString: String?
	public let command: String
	public let commandNumeric: Int
	public let params: [String]
	public let senderNickname: String?
	public let senderUsername: String?
	public let senderAddress: String?
	public let senderIsServer: Bool
}

/// Pure Swift IRC line parser.
/// Parses raw IRC protocol lines per RFC 1459 Section 2.3.1 with IRCv3 message tags.
///
/// Line format: [@tags] [:prefix] <command> [params...] [:trailing]
public enum IRCLineParser {
	/// Parse a raw IRC protocol line into its components.
	/// Returns nil if the line is malformed (empty command, etc.)
	public static func parse(_ line: String) -> IRCLineParserResult? {
		guard !line.isEmpty else { return nil }

		var remainder = Substring(line)

		// 1. Parse IRCv3 message tags
		var tags: [String: String] = [:]
		if remainder.hasPrefix("@") {
			guard let spaceIndex = remainder.firstIndex(of: " ") else { return nil }

			let tagString = remainder[remainder.index(after: remainder.startIndex) ..< spaceIndex]
			tags = parseTags(tagString)

			remainder = remainder[spaceIndex...].drop(while: { $0 == " " })
		}

		// 2. Parse sender prefix
		var senderString: String? = nil
		if remainder.hasPrefix(":") {
			guard let spaceIndex = remainder.firstIndex(of: " ") else { return nil }

			senderString = String(remainder[remainder.index(after: remainder.startIndex) ..< spaceIndex])

			if senderString?.isEmpty ?? true { return nil }

			remainder = remainder[spaceIndex...].drop(while: { $0 == " " })
		}

		// 3. Parse command
		let command: String
		if let spaceIndex = remainder.firstIndex(of: " ") {
			command = String(remainder[..<spaceIndex])
			remainder = remainder[remainder.index(after: spaceIndex)...]
		} else {
			command = String(remainder)
			remainder = ""
		}

		guard !command.isEmpty else { return nil }

		// Normalize: numeric commands stay as-is, text commands uppercased
		let isNumeric = command.allSatisfy(\.isNumber)
		let normalizedCommand = isNumeric ? command : command.uppercased()
		let commandNumeric = isNumeric ? (Int(command) ?? 0) : 0

		// 4. Parse parameters
		var params: [String] = []
		while !remainder.isEmpty {
			if remainder.hasPrefix(":") {
				// Trailing parameter — everything after the colon
				params.append(String(remainder.dropFirst()))
				break
			} else if let spaceIndex = remainder.firstIndex(of: " ") {
				params.append(String(remainder[..<spaceIndex]))
				remainder = remainder[remainder.index(after: spaceIndex)...]
			} else {
				params.append(String(remainder))
				break
			}
		}

		// 5. Parse sender hostmask components
		var nickname: String? = nil
		var username: String? = nil
		var address: String? = nil
		var isServer = false

		if let sender = senderString {
			let parsed = parseHostmask(sender)
			nickname = parsed.nickname
			username = parsed.username
			address = parsed.address
			isServer = parsed.isServer
		}

		return IRCLineParserResult(
			tags: tags,
			senderString: senderString,
			command: normalizedCommand,
			commandNumeric: commandNumeric,
			params: params,
			senderNickname: nickname,
			senderUsername: username,
			senderAddress: address,
			senderIsServer: isServer,
		)
	}

	// MARK: - Private

	/// Parse IRCv3 message tags: "key1=value1;key2;key3=value3"
	private static func parseTags(_ raw: Substring) -> [String: String] {
		var result: [String: String] = [:]

		for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
			if let equalsIndex = part.firstIndex(of: "=") {
				let key = String(part[..<equalsIndex])
				let value = String(part[part.index(after: equalsIndex)...])
				result[key] = unescapeTagValue(value)
			} else {
				result[String(part)] = ""
			}
		}

		return result
	}

	/// Unescape IRCv3 tag values per the spec:
	/// \: → ; \s → space \\ → \ \r → CR \n → LF
	private static func unescapeTagValue(_ value: String) -> String {
		guard value.contains("\\") else { return value }

		var result = ""
		result.reserveCapacity(value.count)

		var iterator = value.makeIterator()
		while let char = iterator.next() {
			if char == "\\" {
				if let next = iterator.next() {
					switch next {
					case ":": result.append(";")
					case "s": result.append(" ")
					case "\\": result.append("\\")
					case "r": result.append("\r")
					case "n": result.append("\n")
					default:
						result.append(char)
						result.append(next)
					}
				} else {
					result.append(char)
				}
			} else {
				result.append(char)
			}
		}

		return result
	}

	/// Parse a hostmask string "nick!user@host" into components.
	/// If the string doesn't contain ! and @, it's treated as a server name.
	private static func parseHostmask(_ hostmask: String) -> (nickname: String, username: String?, address: String?, isServer: Bool) {
		guard let bangIndex = hostmask.firstIndex(of: "!") else {
			return (nickname: hostmask, username: nil, address: nil, isServer: true)
		}

		guard let atIndex = hostmask.lastIndex(of: "@"),
		      atIndex > bangIndex
		else {
			return (nickname: hostmask, username: nil, address: nil, isServer: true)
		}

		let nick = String(hostmask[..<bangIndex])
		let user = String(hostmask[hostmask.index(after: bangIndex) ..< atIndex])
		let host = String(hostmask[hostmask.index(after: atIndex)...])

		guard !nick.isEmpty, !user.isEmpty, !host.isEmpty else {
			return (nickname: hostmask, username: nil, address: nil, isServer: true)
		}

		return (nickname: nick, username: user, address: host, isServer: false)
	}
}
