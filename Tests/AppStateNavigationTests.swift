// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

@MainActor
final class AppStateNavigationTests: XCTestCase {
	/// Build a `ServerStore` rooted at a unique temp directory. Critical
	/// for isolation: the production singleton would share the user's real
	/// `~/Library/Application Support/Brygga/servers.json`, and any test
	/// mutation that triggers `persist()` (e.g. `closePrivateMessage`)
	/// would overwrite that file with the test fixture data.
	private func makeStore() -> ServerStore {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("BryggaTests-\(UUID().uuidString)", isDirectory: true)
		return ServerStore(root: dir)
	}

	private func makeFixture() -> AppState {
		let state = AppState(store: makeStore())
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
		let state = AppState(store: makeStore())
		state.servers.removeAll()
		state.selection = nil
		state.selectAdjacentChannel(direction: 1)
		XCTAssertNil(state.selection)
	}

	/// Regression for the test-pollution bug: a test that triggers
	/// `persist()` must write to the injected store's path, not to the
	/// production `~/Library/Application Support/Brygga/servers.json`.
	func testPersistWritesToInjectedStoreNotProduction() {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("BryggaTests-\(UUID().uuidString)", isDirectory: true)
		let store = ServerStore(root: dir)
		let state = AppState(store: store)
		state.servers.removeAll()

		let pm = Channel(name: "carol")
		let owner = Server(name: "Test", host: "irc.example.org", nickname: "me")
		owner.channels = [pm]
		state.servers = [owner]
		state.selection = pm.id
		state.closePrivateMessage(channelID: pm.id)

		// File exists under the injected store's path...
		XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
		// ...and contains the post-mutation snapshot.
		let snapshot = store.load()
		XCTAssertEqual(snapshot.servers.count, 1)
		XCTAssertEqual(snapshot.servers.first?.openQueries, [])
	}
}
