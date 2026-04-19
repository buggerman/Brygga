// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import XCTest
@testable import BryggaCore

final class MarkdownInputTransformTests: XCTestCase {

	func testBoldStarDelimiter() {
		XCTAssertEqual(
			MarkdownInputTransform.markdownToIRC("*hello*"),
			"\u{02}hello\u{02}"
		)
	}

	func testItalicUnderscoreDelimiter() {
		XCTAssertEqual(
			MarkdownInputTransform.markdownToIRC("say _hi_ now"),
			"say \u{1D}hi\u{1D} now"
		)
	}

	func testStrikeTildeDelimiter() {
		XCTAssertEqual(
			MarkdownInputTransform.markdownToIRC("~oops~"),
			"\u{1E}oops\u{1E}"
		)
	}

	func testMultipleRunsSameLine() {
		XCTAssertEqual(
			MarkdownInputTransform.markdownToIRC("*bold* and _italic_ and ~strike~"),
			"\u{02}bold\u{02} and \u{1D}italic\u{1D} and \u{1E}strike\u{1E}"
		)
	}

	func testUnderscoreInNicknameIsLeftAlone() {
		// user_name has word chars on both sides of each `_` — no match.
		let input = "hey user_name check this out"
		XCTAssertEqual(MarkdownInputTransform.markdownToIRC(input), input)
	}

	func testAsteriskInsideWordIsLeftAlone() {
		let input = "a*b*c"
		XCTAssertEqual(MarkdownInputTransform.markdownToIRC(input), input)
	}

	func testUnmatchedDelimiterIsLeftAlone() {
		let input = "this *is unfinished"
		XCTAssertEqual(MarkdownInputTransform.markdownToIRC(input), input)
	}

	func testDoesNotCrossNewlines() {
		let input = "*line1\nstill open*"
		XCTAssertEqual(MarkdownInputTransform.markdownToIRC(input), input)
	}

	func testEmptyStringPassesThrough() {
		XCTAssertEqual(MarkdownInputTransform.markdownToIRC(""), "")
	}
}
