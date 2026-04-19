/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation

/// Converts a small markdown-style dialect into mIRC control codes just
/// before a message is sent. Supports:
///
///   *text*  → ^B bold
///   _text_  → ^I italic
///   ~text~  → ^S strikethrough
///
/// Delimiters are ignored when they're surrounded by word characters —
/// so `user_name` or `a*b*c` stay untouched while `*hello*` or
/// ` _world_ ` convert. Enabled via `PreferencesKeys.markdownInputEnabled`
/// (default on); toggle off in Preferences → General.
public enum MarkdownInputTransform {
	private static let boldCode   = "\u{02}"  // ^B
	private static let italicCode = "\u{1D}"  // ^I
	private static let strikeCode = "\u{1E}"  // ^S

	/// Rewrites each markdown run in `text` to the matching mIRC
	/// control-code pair. Safe to run on any input — unmatched delimiters
	/// are left alone.
	public static func markdownToIRC(_ text: String) -> String {
		var result = text
		result = apply(
			pattern: #"(?<!\w)\*([^*\r\n]+?)\*(?!\w)"#,
			replacement: "\(boldCode)$1\(boldCode)",
			to: result
		)
		result = apply(
			pattern: #"(?<!\w)_([^_\r\n]+?)_(?!\w)"#,
			replacement: "\(italicCode)$1\(italicCode)",
			to: result
		)
		result = apply(
			pattern: #"(?<!\w)~([^~\r\n]+?)~(?!\w)"#,
			replacement: "\(strikeCode)$1\(strikeCode)",
			to: result
		)
		return result
	}

	private static func apply(pattern: String, replacement: String, to text: String) -> String {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
		let range = NSRange(text.startIndex..., in: text)
		return regex.stringByReplacingMatches(
			in: text,
			range: range,
			withTemplate: replacement
		)
	}
}
