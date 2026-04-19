// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import XCTest
@testable import BryggaCore

final class IRCConnectionTests: XCTestCase {

	func testInitialState() async {
		let conn = IRCConnection(host: "irc.example.org", nickname: "bryggauser")
		let state = await conn.state
		XCTAssertEqual(state, .disconnected)
	}

	func testDefaultsPortAndTLS() async {
		let conn = IRCConnection(host: "irc.example.org", nickname: "bryggauser")
		let port = conn.port
		let useTLS = conn.useTLS
		XCTAssertEqual(port, 6697)
		XCTAssertTrue(useTLS)
	}

	func testUsernameDefaultsToNickname() async {
		let conn = IRCConnection(host: "irc.example.org", nickname: "alice")
		XCTAssertEqual(conn.username, "alice")
		XCTAssertEqual(conn.realName, "alice")
	}

	func testCustomUsernameAndRealName() async {
		let conn = IRCConnection(
			host: "irc.example.org",
			nickname: "alice",
			username: "a",
			realName: "Alice Liddell"
		)
		XCTAssertEqual(conn.username, "a")
		XCTAssertEqual(conn.realName, "Alice Liddell")
	}

	func testSendBeforeConnectThrows() async {
		let conn = IRCConnection(host: "irc.example.org", nickname: "alice")
		do {
			try await conn.send("PING :test")
			XCTFail("expected notConnected error")
		} catch IRCConnection.ConnectionError.notConnected {
			// expected
		} catch {
			XCTFail("unexpected error: \(error)")
		}
	}

	func testDisconnectFromDisconnectedIsNoOp() async {
		let conn = IRCConnection(host: "irc.example.org", nickname: "alice")
		await conn.disconnect()
		let state = await conn.state
		XCTAssertEqual(state, .disconnected)
	}
}
