/* *********************************************************************
 *
 * Unit tests for the emoji-shortcode auto-completion helper.
 *
 *********************************************************************** */

import XCTest
@testable import BryggaCore

final class EmojiShortcodesTests: XCTestCase {

	func testExactLookupReturnsEmoji() {
		XCTAssertEqual(EmojiShortcodes.emoji(for: "smile"), "\u{1F604}")
		XCTAssertEqual(EmojiShortcodes.emoji(for: "fire"), "\u{1F525}")
		XCTAssertEqual(EmojiShortcodes.emoji(for: "heart"), "\u{2764}")
	}

	func testLookupIsCaseInsensitive() {
		XCTAssertEqual(EmojiShortcodes.emoji(for: "SMILE"), "\u{1F604}")
		XCTAssertEqual(EmojiShortcodes.emoji(for: "Smile"), "\u{1F604}")
	}

	func testUnknownShortcodeReturnsNil() {
		XCTAssertNil(EmojiShortcodes.emoji(for: "definitely_not_an_emoji"))
	}

	func testMatchesPrefixReturnsSortedResults() {
		let matches = EmojiShortcodes.matches(prefix: "smi")
		XCTAssertTrue(matches.contains("smile"))
		XCTAssertTrue(matches.contains("smiley"))
		XCTAssertTrue(matches.contains("smirk"))
		XCTAssertEqual(matches, matches.sorted())
	}

	func testEmptyPrefixReturnsNothing() {
		XCTAssertTrue(EmojiShortcodes.matches(prefix: "").isEmpty)
	}
}
