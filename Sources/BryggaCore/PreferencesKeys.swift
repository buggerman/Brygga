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
}
