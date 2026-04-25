// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

final class ScrollbackIndexTests: XCTestCase {
	private func makeIndex() -> ScrollbackIndex {
		// `:memory:` gives every test its own isolated SQLite database that
		// dies with the actor — no temp-file cleanup or shared state.
		ScrollbackIndex(path: ":memory:")
	}

	private func makeMessage(_ content: String, sender: String = "alice") -> Message {
		Message(sender: sender, content: content, kind: .privmsg)
	}

	func testIndexAndSearchSingleMessage() async {
		let index = makeIndex()
		let msg = makeMessage("the quick brown fox")
		await index.index(msg, serverID: "s1", target: "#test")

		let hits = await index.search("brown")
		XCTAssertEqual(hits.count, 1)
		XCTAssertEqual(hits.first?.messageID, msg.id)
		XCTAssertEqual(hits.first?.content, "the quick brown fox")
		XCTAssertEqual(hits.first?.target, "#test")
	}

	func testEmptyQueryReturnsNoHits() async {
		let index = makeIndex()
		await index.index(makeMessage("hello world"), serverID: "s1", target: "#test")

		let emptyHits = await index.search("")
		XCTAssertEqual(emptyHits.count, 0)
		let blankHits = await index.search("   ")
		XCTAssertEqual(blankHits.count, 0)
	}

	func testRepeatedIndexIsIdempotent() async {
		let index = makeIndex()
		let msg = makeMessage("once and only once")
		await index.index(msg, serverID: "s1", target: "#test")
		await index.index(msg, serverID: "s1", target: "#test")
		await index.index(msg, serverID: "s1", target: "#test")

		// Idempotent indexing is the contract that makes cold-start
		// backfill replay-safe; the hit count must stay at 1.
		let hits = await index.search("once")
		XCTAssertEqual(hits.count, 1)
	}

	func testServerScopeFiltersAcrossServers() async {
		let index = makeIndex()
		await index.index(makeMessage("apples"), serverID: "s1", target: "#a")
		await index.index(makeMessage("apples"), serverID: "s2", target: "#a")

		let allHits = await index.search("apples")
		XCTAssertEqual(allHits.count, 2)
		let s1Hits = await index.search("apples", scope: .server(id: "s1"))
		XCTAssertEqual(s1Hits.count, 1)
		let missingHits = await index.search("apples", scope: .server(id: "missing"))
		XCTAssertEqual(missingHits.count, 0)
	}

	func testChannelScopeFiltersWithinServer() async {
		let index = makeIndex()
		await index.index(makeMessage("topic"), serverID: "s1", target: "#general")
		await index.index(makeMessage("topic"), serverID: "s1", target: "#offtopic")

		let hits = await index.search(
			"topic",
			scope: .channel(serverID: "s1", target: "#general"),
		)
		XCTAssertEqual(hits.count, 1)
		XCTAssertEqual(hits.first?.target, "#general")
	}

	func testClearChannelRemovesOnlyThatChannel() async {
		let index = makeIndex()
		await index.index(makeMessage("alpha"), serverID: "s1", target: "#one")
		await index.index(makeMessage("alpha"), serverID: "s1", target: "#two")

		await index.clear(serverID: "s1", target: "#one")

		let hits = await index.search("alpha")
		XCTAssertEqual(hits.count, 1)
		XCTAssertEqual(hits.first?.target, "#two")
	}

	func testClearServerRemovesAllChannels() async {
		let index = makeIndex()
		await index.index(makeMessage("survives"), serverID: "s1", target: "#one")
		await index.index(makeMessage("survives"), serverID: "s1", target: "#two")
		await index.index(makeMessage("survives"), serverID: "s2", target: "#one")

		await index.clear(serverID: "s1")

		let hits = await index.search("survives")
		XCTAssertEqual(hits.count, 1)
		XCTAssertEqual(hits.first?.serverID, "s2")
	}

	func testFTSPhraseAndPrefixQueriesWork() async {
		let index = makeIndex()
		await index.index(makeMessage("error connecting to host"), serverID: "s1", target: "#a")
		await index.index(makeMessage("connection refused"), serverID: "s1", target: "#a")

		// Phrase query: only matches consecutive words.
		let phraseHits = await index.search("\"error connecting\"")
		XCTAssertEqual(phraseHits.count, 1)
		// Prefix query: matches "connecting" and "connection".
		let prefixHits = await index.search("connect*")
		XCTAssertEqual(prefixHits.count, 2)
	}

	func testColumnScopedSearchHonorsSenderField() async {
		let index = makeIndex()
		await index.index(makeMessage("hello", sender: "alice"), serverID: "s1", target: "#a")
		await index.index(makeMessage("alice rocks", sender: "bob"), serverID: "s1", target: "#a")

		let bySender = await index.search("sender:alice")
		XCTAssertEqual(bySender.count, 1)
		XCTAssertEqual(bySender.first?.sender, "alice")
	}

	func testHitsRoundTripTimestampAndKind() async {
		let index = makeIndex()
		let timestamp = Date(timeIntervalSinceReferenceDate: 700_000_000)
		let action = Message(timestamp: timestamp, sender: "carol", content: "waves", kind: .action)
		await index.index(action, serverID: "s1", target: "#a")

		let hit = await index.search("waves").first
		XCTAssertNotNil(hit)
		XCTAssertEqual(hit?.kind, .action)
		// ISO8601 round-trip is to second precision; `timeIntervalSinceReferenceDate`
		// drops sub-second so we compare with `.toleranceFor` semantics.
		XCTAssertEqual(hit?.timestamp.timeIntervalSinceReferenceDate ?? 0, 700_000_000, accuracy: 1.0)
	}
}
