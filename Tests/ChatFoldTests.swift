// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

final class ChatFoldTests: XCTestCase {
	// MARK: - foldPresenceRuns

	func testEmptyInputProducesNoEntries() {
		XCTAssertTrue(foldPresenceRuns([]).isEmpty)
	}

	func testSinglePrivmsgPassesThrough() {
		let m = Message(sender: "alice", content: "hi", kind: .privmsg)
		let entries = foldPresenceRuns([m])
		XCTAssertEqual(entries.count, 1)
		if case let .message(got) = entries[0] {
			XCTAssertEqual(got.id, m.id)
		} else {
			XCTFail("expected .message")
		}
	}

	func testConsecutiveJoinsCollapseIntoOneRun() {
		let a = Message(sender: "alice", content: "", kind: .join)
		let b = Message(sender: "bob", content: "", kind: .join)
		let c = Message(sender: "carol", content: "", kind: .join)
		let entries = foldPresenceRuns([a, b, c])
		XCTAssertEqual(entries.count, 1)
		if case let .presenceRun(id, messages) = entries[0] {
			XCTAssertEqual(id, a.id, "run id is the id of its first message")
			XCTAssertEqual(messages.map(\.sender), ["alice", "bob", "carol"])
		} else {
			XCTFail("expected .presenceRun")
		}
	}

	func testPrivmsgBetweenPresenceSplitsRuns() {
		let j1 = Message(sender: "alice", content: "", kind: .join)
		let j2 = Message(sender: "bob", content: "", kind: .join)
		let say = Message(sender: "carol", content: "hi", kind: .privmsg)
		let q1 = Message(sender: "dave", content: "bye", kind: .quit)
		let entries = foldPresenceRuns([j1, j2, say, q1])
		XCTAssertEqual(entries.count, 3)
		guard case let .presenceRun(_, runA) = entries[0],
		      case .message = entries[1],
		      case let .presenceRun(_, runB) = entries[2]
		else {
			XCTFail("unexpected entry shape: \(entries)")
			return
		}
		XCTAssertEqual(runA.map(\.sender), ["alice", "bob"])
		XCTAssertEqual(runB.map(\.sender), ["dave"])
	}

	func testLengthOneRunStillBecomesPresenceRun() {
		let j = Message(sender: "alice", content: "", kind: .join)
		let entries = foldPresenceRuns([j])
		XCTAssertEqual(entries.count, 1)
		if case let .presenceRun(_, messages) = entries[0] {
			XCTAssertEqual(messages.count, 1)
		} else {
			XCTFail("expected .presenceRun for singleton")
		}
	}

	func testRunIDIsStableWhenMoreMessagesAppended() {
		let j1 = Message(sender: "alice", content: "", kind: .join)
		let j2 = Message(sender: "bob", content: "", kind: .join)
		let first = foldPresenceRuns([j1])
		let second = foldPresenceRuns([j1, j2])
		guard case let .presenceRun(id1, _) = first[0],
		      case let .presenceRun(id2, _) = second[0]
		else {
			XCTFail("expected runs")
			return
		}
		XCTAssertEqual(id1, id2, "run id must survive appends that extend the run")
	}

	func testAllPresenceKindsAreFolded() {
		let a = Message(sender: "alice", content: "", kind: .join)
		let b = Message(sender: "bob", content: "bye", kind: .part)
		let c = Message(sender: "carol", content: "quit reason", kind: .quit)
		let d = Message(sender: "dave", content: "deadbeef", kind: .nick)
		let entries = foldPresenceRuns([a, b, c, d])
		XCTAssertEqual(entries.count, 1)
		if case let .presenceRun(_, messages) = entries[0] {
			XCTAssertEqual(messages.count, 4)
		} else {
			XCTFail("expected single run containing all four presence kinds")
		}
	}

	// MARK: - presenceRunSummary

	func testSummaryForSingleJoin() {
		let a = Message(sender: "alice", content: "", kind: .join)
		XCTAssertEqual(presenceRunSummary([a]), "alice joined")
	}

	func testSummaryForMixedJoinAndPart() {
		let a = Message(sender: "alice", content: "", kind: .join)
		let b = Message(sender: "bob", content: "", kind: .part)
		XCTAssertEqual(presenceRunSummary([a, b]), "alice joined · bob left")
	}

	func testSummaryCollapsesJoinedThenLeftIntoOnePhrase() {
		let a = Message(sender: "alice", content: "", kind: .join)
		let b = Message(sender: "alice", content: "", kind: .quit)
		XCTAssertEqual(presenceRunSummary([a, b]), "alice joined and left")
	}

	func testSummaryFormatsNickChange() {
		let n = Message(sender: "alice", content: "al1ce", kind: .nick)
		XCTAssertEqual(presenceRunSummary([n]), "alice is now al1ce")
	}

	func testSummaryCountsWhenAboveThreeUniqueNicks() {
		let msgs = ["a", "b", "c", "d", "e"].map {
			Message(sender: $0, content: "", kind: .join)
		}
		XCTAssertEqual(presenceRunSummary(msgs), "5 users joined")
	}

	func testSummaryDedupesSameNickJoiningTwice() {
		let a1 = Message(sender: "alice", content: "", kind: .join)
		let a2 = Message(sender: "alice", content: "", kind: .join)
		let b = Message(sender: "bob", content: "", kind: .join)
		XCTAssertEqual(presenceRunSummary([a1, a2, b]), "alice, bob joined")
	}

	func testSummaryIgnoresEmptyNickTarget() {
		// Guard rail: an empty `content` on a .nick message shouldn't render.
		let n = Message(sender: "alice", content: "", kind: .nick)
		XCTAssertEqual(presenceRunSummary([n]), "")
	}
}
