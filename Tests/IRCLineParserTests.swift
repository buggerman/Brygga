// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import XCTest
@testable import BryggaCore

class IRCLineParserTests: XCTestCase {

	// MARK: - Basic Commands

	func testPRIVMSG() {
		let result = IRCLineParser.parse(":nick!user@host PRIVMSG #channel :Hello world")!

		XCTAssertEqual(result.command, "PRIVMSG")
		XCTAssertEqual(result.commandNumeric, 0)
		XCTAssertEqual(result.params, ["#channel", "Hello world"])
		XCTAssertEqual(result.senderNickname, "nick")
		XCTAssertEqual(result.senderUsername, "user")
		XCTAssertEqual(result.senderAddress, "host")
		XCTAssertFalse(result.senderIsServer)
		XCTAssertEqual(result.senderString, "nick!user@host")
	}

	func testJOIN() {
		let result = IRCLineParser.parse(":nick!user@host JOIN #channel")!

		XCTAssertEqual(result.command, "JOIN")
		XCTAssertEqual(result.params, ["#channel"])
		XCTAssertEqual(result.senderNickname, "nick")
	}

	func testPART() {
		let result = IRCLineParser.parse(":nick!user@host PART #channel :Leaving")!

		XCTAssertEqual(result.command, "PART")
		XCTAssertEqual(result.params, ["#channel", "Leaving"])
	}

	func testNICK() {
		let result = IRCLineParser.parse(":oldnick!user@host NICK newnick")!

		XCTAssertEqual(result.command, "NICK")
		XCTAssertEqual(result.params, ["newnick"])
		XCTAssertEqual(result.senderNickname, "oldnick")
	}

	func testQUIT() {
		let result = IRCLineParser.parse(":nick!user@host QUIT :Quit message here")!

		XCTAssertEqual(result.command, "QUIT")
		XCTAssertEqual(result.params, ["Quit message here"])
	}

	func testMODE() {
		let result = IRCLineParser.parse(":nick!user@host MODE #channel +o othernick")!

		XCTAssertEqual(result.command, "MODE")
		XCTAssertEqual(result.params, ["#channel", "+o", "othernick"])
	}

	func testKICK() {
		let result = IRCLineParser.parse(":nick!user@host KICK #channel target :reason")!

		XCTAssertEqual(result.command, "KICK")
		XCTAssertEqual(result.params, ["#channel", "target", "reason"])
	}

	func testNOTICE() {
		let result = IRCLineParser.parse(":irc.server.com NOTICE * :*** Looking up your hostname")!

		XCTAssertEqual(result.command, "NOTICE")
		XCTAssertEqual(result.params, ["*", "*** Looking up your hostname"])
		XCTAssertTrue(result.senderIsServer)
		XCTAssertEqual(result.senderNickname, "irc.server.com")
	}

	// MARK: - Numeric Replies

	func testNumericWelcome() {
		let result = IRCLineParser.parse(":server.name 001 mynick :Welcome to the IRC Network")!

		XCTAssertEqual(result.command, "001")
		XCTAssertEqual(result.commandNumeric, 1)
		XCTAssertEqual(result.params, ["mynick", "Welcome to the IRC Network"])
	}

	func testNumericISUPPORT() {
		let result = IRCLineParser.parse(":server.name 005 mynick NETWORK=TestNet :are supported")!

		XCTAssertEqual(result.commandNumeric, 5)
		XCTAssertEqual(result.params[1], "NETWORK=TestNet")
	}

	func testNumericNickInUse() {
		let result = IRCLineParser.parse(":server.name 433 * newnick :Nickname is already in use")!

		XCTAssertEqual(result.commandNumeric, 433)
	}

	// MARK: - Sender Parsing

	func testServerSender() {
		let result = IRCLineParser.parse(":irc.server.com NOTICE * :message")!

		XCTAssertTrue(result.senderIsServer)
		XCTAssertEqual(result.senderNickname, "irc.server.com")
		XCTAssertNil(result.senderUsername)
		XCTAssertNil(result.senderAddress)
	}

	func testFullHostmask() {
		let result = IRCLineParser.parse(":nick!~user@192.168.1.1 PRIVMSG #chan :test")!

		XCTAssertEqual(result.senderNickname, "nick")
		XCTAssertEqual(result.senderUsername, "~user")
		XCTAssertEqual(result.senderAddress, "192.168.1.1")
		XCTAssertFalse(result.senderIsServer)
	}

	func testCloakedHost() {
		let result = IRCLineParser.parse(":nick!user@user/cloak PRIVMSG #chan :test")!

		XCTAssertEqual(result.senderAddress, "user/cloak")
	}

	func testIPv6Address() {
		let result = IRCLineParser.parse(":nick!user@2001:db8::1 PRIVMSG #chan :test")!

		XCTAssertEqual(result.senderNickname, "nick")
		XCTAssertEqual(result.senderUsername, "user")
		XCTAssertEqual(result.senderAddress, "2001:db8::1")
	}

	func testNoSender() {
		let result = IRCLineParser.parse("PING server.name")!

		XCTAssertNil(result.senderString)
		XCTAssertNil(result.senderNickname)
		XCTAssertEqual(result.command, "PING")
		XCTAssertEqual(result.params, ["server.name"])
	}

	// MARK: - Parameters

	func testTrailingWithColons() {
		let result = IRCLineParser.parse(":nick!user@host PRIVMSG #chan :Hello: world: test")!

		XCTAssertEqual(result.params[1], "Hello: world: test")
	}

	func testEmptyTrailing() {
		let result = IRCLineParser.parse(":nick!user@host PRIVMSG #chan :")!

		XCTAssertEqual(result.params[1], "")
	}

	func testNoParams() {
		let result = IRCLineParser.parse(":irc.server.com QUIT")!

		XCTAssertTrue(result.params.isEmpty)
	}

	func testMultipleMiddleParams() {
		let result = IRCLineParser.parse(":server 353 nick = #channel :user1 user2 user3")!

		XCTAssertEqual(result.params.count, 4)
		XCTAssertEqual(result.params[0], "nick")
		XCTAssertEqual(result.params[1], "=")
		XCTAssertEqual(result.params[2], "#channel")
		XCTAssertEqual(result.params[3], "user1 user2 user3")
	}

	// MARK: - Command Normalization

	func testCommandUppercased() {
		let result = IRCLineParser.parse(":nick!user@host privmsg #chan :test")!

		XCTAssertEqual(result.command, "PRIVMSG")
	}

	func testMixedCaseUppercased() {
		let result = IRCLineParser.parse(":nick!user@host NoTiCe #chan :test")!

		XCTAssertEqual(result.command, "NOTICE")
	}

	func testNumericNotUppercased() {
		let result = IRCLineParser.parse(":server 001 nick :Welcome")!

		XCTAssertEqual(result.command, "001")
	}

	// MARK: - IRCv3 Message Tags

	func testSimpleTags() {
		let result = IRCLineParser.parse("@time=2024-01-01T00:00:00.000Z :nick!user@host PRIVMSG #chan :test")!

		XCTAssertEqual(result.tags["time"], "2024-01-01T00:00:00.000Z")
		XCTAssertEqual(result.command, "PRIVMSG")
	}

	func testMultipleTags() {
		let result = IRCLineParser.parse("@aaa=bbb;ccc;example.com/ddd=eee :nick!user@host PRIVMSG #chan :test")!

		XCTAssertEqual(result.tags["aaa"], "bbb")
		XCTAssertEqual(result.tags["ccc"], "")
		XCTAssertEqual(result.tags["example.com/ddd"], "eee")
	}

	func testTagValueUnescaping() {
		// \: → ;  \s → space  \\ → \  \n → newline
		let result = IRCLineParser.parse("@key=hello\\sworld\\:\\\\end\\n :nick!user@host PRIVMSG #chan :test")!

		XCTAssertEqual(result.tags["key"], "hello world;\\end\n")
	}

	func testTagsWithNoSender() {
		let result = IRCLineParser.parse("@batch=abc123 PING :timestamp")!

		XCTAssertEqual(result.tags["batch"], "abc123")
		XCTAssertNil(result.senderString)
		XCTAssertEqual(result.command, "PING")
	}

	// MARK: - Edge Cases

	func testEmptyLine() {
		XCTAssertNil(IRCLineParser.parse(""))
	}

	func testOnlyColon() {
		XCTAssertNil(IRCLineParser.parse(":"))
	}

	func testOnlyTagsNoCommand() {
		XCTAssertNil(IRCLineParser.parse("@tag=value"))
	}

	func testOnlySenderNoCommand() {
		XCTAssertNil(IRCLineParser.parse(":nick!user@host"))
	}

	func testERROR() {
		let result = IRCLineParser.parse(":irc.server.com ERROR :Closing Link: nick[host] (Quit: leaving)")!

		XCTAssertEqual(result.command, "ERROR")
		XCTAssertEqual(result.params[0], "Closing Link: nick[host] (Quit: leaving)")
	}
}
