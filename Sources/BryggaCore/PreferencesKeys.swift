/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation

/// Canonical `UserDefaults` keys for user preferences. Defined in the core
/// module so both the SwiftUI `PreferencesView` (writer) and the
/// `@MainActor IRCSession` (reader) share identical strings.
public enum PreferencesKeys {
	public static let showJoinsParts = "brygga.showJoinsParts"
	public static let highlightKeywordsRaw = "brygga.highlightKeywordsRaw"
	public static let autoJoinOnInvite = "brygga.autoJoinOnInvite"
	public static let diskLoggingEnabled = "brygga.diskLoggingEnabled"

	// Identity defaults, pre-filling the Connect sheet.
	public static let defaultNickname = "brygga.defaultNickname"
	public static let defaultUserName = "brygga.defaultUserName"
	public static let defaultRealName = "brygga.defaultRealName"

	// Appearance.
	/// "system" | "12h" | "24h"
	public static let timestampFormat = "brygga.timestampFormat"
	public static let nickColorsEnabled = "brygga.nickColorsEnabled"

	/// Fetch titles / images for URLs in messages. Defaults to true — see
	/// `GeneralPane` for the opt-out toggle. Reads are capped at 2 MB and
	/// timed out at 10 s; only http and https schemes are followed.
	public static let linkPreviewsEnabled = "brygga.linkPreviewsEnabled"
}
