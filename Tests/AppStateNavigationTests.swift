// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

@MainActor
final class AppStateNavigationTests: XCTestCase {
	/// Build a tempdir-rooted set of stores. Critical for isolation: the
	/// production singletons would share the user's real
	/// `~/Library/Application Support/Brygga/{servers.json,scrollback/,scrollback.sqlite}`,
	/// and any test mutation that triggers a write would land there. The
	/// recovery script (`Scripts/recover-scrollback.sh`) was written to
	/// dig users out of exactly that hole.
	private struct TestDeps {
		let server: ServerStore
		let scrollback: ScrollbackStore
		let scrollbackIndex: ScrollbackIndex
	}

	private func makeDeps() -> TestDeps {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("BryggaTests-\(UUID().uuidString)", isDirectory: true)
		return TestDeps(
			server: ServerStore(root: dir),
			scrollback: ScrollbackStore(root: dir.appendingPathComponent("scrollback", isDirectory: true)),
			scrollbackIndex: ScrollbackIndex(path: ":memory:"),
		)
	}

	/// Convenience for tests that only need the `ServerStore`.
	private func makeStore() -> ServerStore {
		makeDeps().server
	}

	private func makeFixture() -> AppState {
		let deps = makeDeps()
		let state = AppState(
			store: deps.server,
			scrollbackStore: deps.scrollback,
			scrollbackIndex: deps.scrollbackIndex,
		)
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
		let deps = makeDeps()
		let state = AppState(
			store: deps.server,
			scrollbackStore: deps.scrollback,
			scrollbackIndex: deps.scrollbackIndex,
		)
		state.servers.removeAll()
		state.selection = nil
		state.selectAdjacentChannel(direction: 1)
		XCTAssertNil(state.selection)
	}

	/// Regression for the test-pollution bug: a test that triggers
	/// `persist()` must write to the injected store's path, not to the
	/// production `~/Library/Application Support/Brygga/servers.json`.
	func testPersistWritesToInjectedStoreNotProduction() {
		let deps = makeDeps()
		let state = AppState(
			store: deps.server,
			scrollbackStore: deps.scrollback,
			scrollbackIndex: deps.scrollbackIndex,
		)
		state.servers.removeAll()
		// Convenience handles for the assertions below.
		let store = deps.server

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
