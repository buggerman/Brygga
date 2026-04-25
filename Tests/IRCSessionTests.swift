// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

@MainActor
final class IRCSessionTests: XCTestCase {
	private func makeSession(ownNick: String = "me") -> IRCSession {
		let server = Server(name: "Test", host: "irc.example.org", nickname: ownNick)
		let connection = IRCConnection(host: "irc.example.org", nickname: ownNick)
		return IRCSession(server: server, connection: connection)
	}

	private func parse(_ line: String) -> IRCLineParserResult {
		guard let result = IRCLineParser.parse(line) else {
			fatalError("test helper failed to parse line: \(line)")
		}
		return result
	}

	// MARK: - JOIN

	func testOwnJoinAddsChannel() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))

		XCTAssertEqual(session.server.channels.count, 1)
		let channel = session.server.channels[0]
		XCTAssertEqual(channel.name, "#test")
		XCTAssertTrue(channel.isJoined)
	}

	func testOtherJoinAddsUserToExistingChannel() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~alice@host JOIN #test"))

		let channel = session.server.channels[0]
		XCTAssertEqual(channel.users.count, 1)
		XCTAssertEqual(channel.users[0].nickname, "alice")
		XCTAssertEqual(channel.messages.last?.kind, .join)
	}

	// MARK: - channel name normalization

	func testNormalizedChannelNameAddsHashWhenMissing() {
		XCTAssertEqual(IRCSession.normalizedChannelName("linux"), "#linux")
	}

	func testNormalizedChannelNamePreservesExistingPrefixes() {
		XCTAssertEqual(IRCSession.normalizedChannelName("#linux"), "#linux")
		XCTAssertEqual(IRCSession.normalizedChannelName("&local"), "&local")
		XCTAssertEqual(IRCSession.normalizedChannelName("+modeless"), "+modeless")
		XCTAssertEqual(IRCSession.normalizedChannelName("!safe"), "!safe")
	}

	func testNormalizedChannelNameTrimsWhitespace() {
		XCTAssertEqual(IRCSession.normalizedChannelName("  linux  "), "#linux")
	}

	// MARK: - chathistory page size

	func testChathistoryPageSizeFallsBackToShippedDefault() {
		UserDefaults.standard.removeObject(forKey: PreferencesKeys.chathistoryPageSize)
		XCTAssertEqual(IRCSession.chathistoryPageSize(), PreferencesKeys.chathistoryPageSizeFallback)
	}

	func testChathistoryPageSizeHonorsConfiguredValue() {
		UserDefaults.standard.set(250, forKey: PreferencesKeys.chathistoryPageSize)
		defer { UserDefaults.standard.removeObject(forKey: PreferencesKeys.chathistoryPageSize) }
		XCTAssertEqual(IRCSession.chathistoryPageSize(), 250)
	}

	func testChathistoryPageSizeClampsOutOfRange() {
		UserDefaults.standard.set(99999, forKey: PreferencesKeys.chathistoryPageSize)
		XCTAssertEqual(IRCSession.chathistoryPageSize(), 500)
		UserDefaults.standard.set(0, forKey: PreferencesKeys.chathistoryPageSize)
		XCTAssertEqual(IRCSession.chathistoryPageSize(), 1)
		UserDefaults.standard.removeObject(forKey: PreferencesKeys.chathistoryPageSize)
	}

	// MARK: - chathistory

	func testServerDefaultsToChathistoryUnsupported() {
		let session = makeSession()
		XCTAssertFalse(session.server.supportsChathistory)
	}

	func testRequestMoreHistoryNoOpAtHeadOfHistory() {
		let session = makeSession()
		session.handle(parse(":me!~me@host JOIN #test"))
		let channel = session.server.channels[0]
		channel.hasMoreHistoryAbove = false

		session.requestMoreHistory(for: channel)

		// Head-of-history early-return must not flip the loading flag,
		// otherwise the UI would render a spinner that never resolves.
		XCTAssertFalse(channel.isLoadingHistory)
	}

	// MARK: - PART

	func testOwnPartMarksChannelLeft() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":me!~me@host PART #test :bye"))

		let channel = session.server.channels[0]
		XCTAssertFalse(channel.isJoined)
	}

	func testOtherPartRemovesUser() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~alice@host JOIN #test"))
		session.handle(parse(":alice!~alice@host PART #test"))

		let channel = session.server.channels[0]
		XCTAssertFalse(channel.users.contains(where: { $0.nickname == "alice" }))
	}

	// MARK: - PRIVMSG

	func testChannelPrivmsgAppendsAndIncrementsUnread() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~a@h PRIVMSG #test :hello"))

		let channel = session.server.channels[0]
		XCTAssertEqual(channel.messages.last?.content, "hello")
		XCTAssertEqual(channel.messages.last?.sender, "alice")
		XCTAssertEqual(channel.messages.last?.kind, .privmsg)
		XCTAssertEqual(channel.unreadCount, 1)
	}

	func testOwnPrivmsgDoesNotIncrementUnread() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":me!~me@host PRIVMSG #test :my own line"))

		let channel = session.server.channels[0]
		XCTAssertEqual(channel.unreadCount, 0)
	}

	func testActionPrivmsgMarkedAsAction() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~a@h PRIVMSG #test :\u{0001}ACTION waves\u{0001}"))

		let channel = session.server.channels[0]
		XCTAssertEqual(channel.messages.last?.content, "waves")
		XCTAssertEqual(channel.messages.last?.kind, .action)
	}

	// MARK: - MODE

	func testModeOpFlipsUserPrefix() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~a@h JOIN #test"))
		XCTAssertEqual(session.server.channels[0].users.first?.prefix, "")

		session.handle(parse(":chanserv!services@. MODE #test +o alice"))
		XCTAssertEqual(session.server.channels[0].users.first?.prefix, "@")
	}

	func testModeDeopClearsUserPrefix() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~a@h JOIN #test"))
		session.handle(parse(":chanserv!services@. MODE #test +o alice"))
		session.handle(parse(":chanserv!services@. MODE #test -o alice"))

		XCTAssertEqual(session.server.channels[0].users.first?.prefix, "")
	}

	func testModeMixedFlipsBothUsers() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~a@h JOIN #test"))
		session.handle(parse(":bob!~b@h JOIN #test"))
		session.handle(parse(":chanserv!services@. MODE #test +o-v alice bob"))

		let users = session.server.channels[0].users
		let alice = users.first(where: { $0.nickname == "alice" })!
		let bob = users.first(where: { $0.nickname == "bob" })!
		XCTAssertEqual(alice.prefix, "@")
		XCTAssertEqual(bob.prefix, "")
	}

	// MARK: - TAGMSG +typing

	func testTagmsgActiveAddsTypingUser() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse("@+typing=active :alice!~a@h TAGMSG #test"))

		let channel = session.server.channels[0]
		let expiry = channel.typingUsers["alice"]
		XCTAssertNotNil(expiry)
		XCTAssertGreaterThan(expiry!, Date())
	}

	func testTagmsgDoneClearsTypingUser() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse("@+typing=active :alice!~a@h TAGMSG #test"))
		session.handle(parse("@+typing=done :alice!~a@h TAGMSG #test"))

		XCTAssertNil(session.server.channels[0].typingUsers["alice"])
	}

	func testTagmsgFromSelfIsIgnored() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse("@+typing=active :me!~me@host TAGMSG #test"))

		XCTAssertTrue(session.server.channels[0].typingUsers.isEmpty)
	}

	func testPrivateMessageCreatesQueryChannel() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":alice!~a@h PRIVMSG me :hi there"))

		XCTAssertEqual(session.server.channels.count, 1)
		XCTAssertEqual(session.server.channels[0].name, "alice")
		XCTAssertEqual(session.server.channels[0].messages.last?.content, "hi there")
	}

	// MARK: - TOPIC

	func testTopicReplyUpdatesChannel() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":server.example 332 me #test :welcome topic"))

		XCTAssertEqual(session.server.channels[0].topic, "welcome topic")
	}

	// MARK: - NAMES (353)

	func testNamesReplyPopulatesUsers() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":server.example 353 me = #test :@alice +bob carol"))

		let channel = session.server.channels[0]
		XCTAssertEqual(channel.users.count, 3)

		let alice = channel.users.first(where: { $0.nickname == "alice" })
		XCTAssertTrue(alice?.modes.contains("o") ?? false)

		let bob = channel.users.first(where: { $0.nickname == "bob" })
		XCTAssertTrue(bob?.modes.contains("v") ?? false)

		let carol = channel.users.first(where: { $0.nickname == "carol" })
		XCTAssertTrue(carol?.modes.isEmpty ?? false)
	}

	// MARK: - NICK

	func testOwnNickChangeUpdatesServer() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host NICK newme"))

		XCTAssertEqual(session.server.nickname, "newme")
	}

	func testOtherNickChangeUpdatesUserInChannel() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~a@h JOIN #test"))
		session.handle(parse(":alice!~a@h NICK newalice"))

		let channel = session.server.channels[0]
		XCTAssertTrue(channel.users.contains(where: { $0.nickname == "newalice" }))
		XCTAssertFalse(channel.users.contains(where: { $0.nickname == "alice" }))
	}

	// MARK: - KICK

	func testKickRemovesUser() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":me!~me@host JOIN #test"))
		session.handle(parse(":alice!~a@h JOIN #test"))
		session.handle(parse(":op!~o@h KICK #test alice :reason"))

		let channel = session.server.channels[0]
		XCTAssertFalse(channel.users.contains(where: { $0.nickname == "alice" }))
		XCTAssertEqual(channel.messages.last?.kind, .kick)
	}

	// MARK: - Welcome (001)

	func testWelcomeMarksServerRegistered() {
		let session = makeSession(ownNick: "me")
		session.handle(parse(":server.example 001 me :Welcome"))
		XCTAssertEqual(session.server.state, .registered)
	}
}
