// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

@MainActor
final class AppStateNavigationTests: XCTestCase {
	private func makeFixture() -> AppState {
		let state = AppState()
		state.servers.removeAll()
		state.selection = nil
		let s1 = Server(name: "ServerA", host: "a.example.org", nickname: "me")
		let s2 = Server(name: "ServerB", host: "b.example.org", nickname: "me")
		s1.channels = [Channel(name: "#a1"), Channel(name: "#a2")]
		s2.channels = [Channel(name: "#b1")]
		state.servers = [s1, s2]
		return state
	}

	func testClosePrivateMessageRemovesQueryAndAdvancesSelection() {
		let state = makeFixture()
		let pm = Channel(name: "alice")
		state.servers[0].channels.append(pm)
		state.selection = pm.id

		state.closePrivateMessage(channelID: pm.id)

		XCTAssertFalse(state.servers[0].channels.contains(where: { $0.id == pm.id }))
		XCTAssertEqual(state.selection, state.servers[0].id)
	}

	func testClosePrivateMessageNoOpOnRegularChannel() {
		let state = makeFixture()
		let regular = state.servers[0].channels[0]
		let originalCount = state.servers[0].channels.count

		state.closePrivateMessage(channelID: regular.id)

		// Closing a `#`-prefixed channel must not silently remove it —
		// regular channels use /part, not the close-tab flow.
		XCTAssertEqual(state.servers[0].channels.count, originalCount)
	}

	func testSelectableIDsIsInterleavedServerAndChannels() {
		let state = makeFixture()
		let ids = state.selectableIDs
		let expected = [
			state.servers[0].id,
			state.servers[0].channels[0].id,
			state.servers[0].channels[1].id,
			state.servers[1].id,
			state.servers[1].channels[0].id,
		]
		XCTAssertEqual(ids, expected)
	}

	func testSelectAdjacentFromUnselectedStartsAtFirst() {
		let state = makeFixture()
		XCTAssertNil(state.selection)
		state.selectAdjacentChannel(direction: 1)
		XCTAssertEqual(state.selection, state.servers[0].id)
	}

	func testNextAdvancesThroughTheList() {
		let state = makeFixture()
		state.selection = state.servers[0].id
		state.selectAdjacentChannel(direction: 1)
		XCTAssertEqual(state.selection, state.servers[0].channels[0].id)
	}

	func testNextWrapsAtEnd() {
		let state = makeFixture()
		state.selection = state.servers[1].channels[0].id
		state.selectAdjacentChannel(direction: 1)
		XCTAssertEqual(state.selection, state.servers[0].id)
	}

	func testPreviousWrapsAtStart() {
		let state = makeFixture()
		state.selection = state.servers[0].id
		state.selectAdjacentChannel(direction: -1)
		XCTAssertEqual(state.selection, state.servers[1].channels[0].id)
	}

	func testEmptyStateIsNoOp() {
		let state = AppState()
		state.servers.removeAll()
		state.selection = nil
		state.selectAdjacentChannel(direction: 1)
		XCTAssertNil(state.selection)
	}
}
