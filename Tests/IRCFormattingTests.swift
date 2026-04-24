// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

final class IRCFormattingTests: XCTestCase {
	func testStripControlCodesRemovesBoldItalicUnderline() {
		let input = "\u{02}bold\u{02} and \u{1D}italic\u{1D} and \u{1F}under\u{1F}"
		XCTAssertEqual(IRCFormatting.stripControlCodes(input), "bold and italic and under")
	}

	func testStripControlCodesRemovesColorSequences() {
		let input = "\u{03}04red\u{03} back \u{03}04,02fg+bg\u{03} end"
		XCTAssertEqual(IRCFormatting.stripControlCodes(input), "red back fg+bg end")
	}

	func testStripControlCodesKeepsCommaWhenNotPartOfColor() {
		// A bare ^K followed by non-digits resets colors; the literal comma
		// survives because it's not a bg separator.
		let input = "\u{03}3,meh"
		XCTAssertEqual(IRCFormatting.stripControlCodes(input), ",meh")
	}

	func testStripControlCodesRemovesResetAndReverse() {
		let input = "a\u{0F}b\u{16}c\u{1E}d"
		XCTAssertEqual(IRCFormatting.stripControlCodes(input), "abcd")
	}

	func testStripControlCodesIsIdentityForPlainText() {
		let input = "hello, world — no control codes here"
		XCTAssertEqual(IRCFormatting.stripControlCodes(input), input)
	}
}
