/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation

/// Parses mIRC control codes (bold, italic, underline, strikethrough,
/// reverse, color) into a sequence of styled runs. Framework-agnostic: the
/// output is a plain value type so the view layer can map it to whatever
/// styling primitive it prefers (SwiftUI `AttributedString`, `NSAttributedString`,
/// raw Text modifiers).
public enum IRCFormatting {

	/// A single contiguous span of text sharing one style.
	public struct Run: Sendable, Equatable {
		public let text: String
		public let style: Style

		public init(text: String, style: Style) {
			self.text = text
			self.style = style
		}
	}

	public struct Style: Sendable, Equatable {
		public var bold: Bool
		public var italic: Bool
		public var underline: Bool
		public var strikethrough: Bool
		public var reverse: Bool
		public var foreground: Int?
		public var background: Int?

		public init(
			bold: Bool = false,
			italic: Bool = false,
			underline: Bool = false,
			strikethrough: Bool = false,
			reverse: Bool = false,
			foreground: Int? = nil,
			background: Int? = nil
		) {
			self.bold = bold
			self.italic = italic
			self.underline = underline
			self.strikethrough = strikethrough
			self.reverse = reverse
			self.foreground = foreground
			self.background = background
		}

		public static let plain = Style()
	}

	// MARK: - Control-code byte values
	// These are the standard mIRC / IRCv3 formatting control bytes.
	private static let bold: Character           = "\u{02}"
	private static let color: Character          = "\u{03}"
	private static let reset: Character          = "\u{0F}"
	private static let monospace: Character      = "\u{11}"   // rare; we treat as no-op
	private static let reverse: Character        = "\u{16}"
	private static let italic: Character         = "\u{1D}"
	private static let strikethrough: Character  = "\u{1E}"
	private static let underline: Character      = "\u{1F}"

	/// Parse `text` into a sequence of styled runs. Plain text (no control
	/// codes) returns a single run with the default style.
	public static func parse(_ text: String) -> [Run] {
		var runs: [Run] = []
		var current = ""
		var style = Style()
		let chars = Array(text)
		var i = 0

		func flush() {
			if !current.isEmpty {
				runs.append(Run(text: current, style: style))
				current = ""
			}
		}

		while i < chars.count {
			let c = chars[i]
			switch c {
			case bold:
				flush()
				style.bold.toggle()
				i += 1
			case italic:
				flush()
				style.italic.toggle()
				i += 1
			case underline:
				flush()
				style.underline.toggle()
				i += 1
			case strikethrough:
				flush()
				style.strikethrough.toggle()
				i += 1
			case reverse:
				flush()
				style.reverse.toggle()
				i += 1
			case reset:
				flush()
				style = Style()
				i += 1
			case monospace:
				// Our renderer is already monospace; treat as no-op.
				i += 1
			case color:
				flush()
				i += 1
				// Read 1–2 digit foreground number.
				var fgStr = ""
				while i < chars.count && chars[i].isASCII && chars[i].isNumber && fgStr.count < 2 {
					fgStr.append(chars[i])
					i += 1
				}
				if let fg = Int(fgStr) {
					style.foreground = fg
					// Optional ",bg" follow-up. The comma is consumed only if
					// it's actually followed by digits — otherwise a literal
					// comma in "color3,meh" would be swallowed.
					if i < chars.count && chars[i] == "," {
						let afterComma = i + 1
						var bgStr = ""
						var j = afterComma
						while j < chars.count && chars[j].isASCII && chars[j].isNumber && bgStr.count < 2 {
							bgStr.append(chars[j])
							j += 1
						}
						if let bg = Int(bgStr) {
							style.background = bg
							i = j
						}
					}
				} else {
					// Bare ^K resets colors.
					style.foreground = nil
					style.background = nil
				}
			default:
				current.append(c)
				i += 1
			}
		}
		flush()
		return runs
	}

	// MARK: - mIRC 16-color palette (RGB in 0…1)

	public struct RGB: Sendable, Equatable {
		public let red: Double
		public let green: Double
		public let blue: Double
	}

	/// Standard mIRC palette indices 0–15. Indices 16–98 belong to the IRCv3
	/// extended palette and are not yet mapped; they resolve to `nil` and the
	/// renderer falls back to the default text color.
	public static func color(for index: Int) -> RGB? {
		switch index {
		case 0:  return RGB(red: 1.00, green: 1.00, blue: 1.00)  // white
		case 1:  return RGB(red: 0.00, green: 0.00, blue: 0.00)  // black
		case 2:  return RGB(red: 0.00, green: 0.00, blue: 0.50)  // blue
		case 3:  return RGB(red: 0.00, green: 0.58, blue: 0.00)  // green
		case 4:  return RGB(red: 1.00, green: 0.00, blue: 0.00)  // light red
		case 5:  return RGB(red: 0.50, green: 0.00, blue: 0.00)  // brown
		case 6:  return RGB(red: 0.61, green: 0.00, blue: 0.61)  // purple
		case 7:  return RGB(red: 0.99, green: 0.50, blue: 0.00)  // orange
		case 8:  return RGB(red: 1.00, green: 1.00, blue: 0.00)  // yellow
		case 9:  return RGB(red: 0.00, green: 0.99, blue: 0.00)  // light green
		case 10: return RGB(red: 0.00, green: 0.58, blue: 0.58)  // cyan
		case 11: return RGB(red: 0.00, green: 1.00, blue: 1.00)  // light cyan
		case 12: return RGB(red: 0.00, green: 0.00, blue: 0.99)  // light blue
		case 13: return RGB(red: 1.00, green: 0.00, blue: 1.00)  // pink
		case 14: return RGB(red: 0.50, green: 0.50, blue: 0.50)  // grey
		case 15: return RGB(red: 0.82, green: 0.82, blue: 0.82)  // light grey
		default: return nil
		}
	}
}
