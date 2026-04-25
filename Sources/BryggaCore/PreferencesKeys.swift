// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// Canonical `UserDefaults` keys for user preferences. Defined in the core
/// module so both the SwiftUI `PreferencesView` (writer) and the
/// `@MainActor IRCSession` (reader) share identical strings.
public enum PreferencesKeys {
	public static let showJoinsParts = "brygga.showJoinsParts"
	/// Global default for collapsing consecutive JOIN / PART / QUIT / NICK
	/// messages into one compacted row with a disclosure triangle. Per-channel
	/// overrides live on `Server.presenceCollapseOverrides` and win over the
	/// global default when set. Defaults to true.
	public static let collapsePresenceRuns = "brygga.collapsePresenceRuns"
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

	/// Rewrite `*bold*` / `_italic_` / `~strike~` to mIRC control codes
	/// just before a message is sent. Defaults to true.
	public static let markdownInputEnabled = "brygga.markdownInputEnabled"

	/// Share the IRCv3 typing indicator (`+typing` client tag via TAGMSG)
	/// with other users on channels and in queries. Matches Halloy's
	/// `buffer.typing.share`. Defaults to true. Receiving is always on.
	public static let shareTypingEnabled = "brygga.shareTypingEnabled"

	/// Default PART message appended to `/leave` / `/part` / Cmd+W when the
	/// user doesn't supply one explicitly. Clear the field in Preferences
	/// to opt out of sending any reason by default.
	public static let defaultLeaveMessage = "brygga.defaultLeaveMessage"

	/// Shipped default for `defaultLeaveMessage`. Both the `@AppStorage`
	/// initial value in `GeneralPane` and the `UserDefaults` read site in
	/// `IRCSession.part(_:reason:)` use this constant so they stay in sync.
	public static let defaultLeaveMessageFallback =
		"Brygga (https://github.com/buggerman/Brygga) - A modern, fast, feature-rich IRC client for macOS"

	/// Per-server dismissal flag for the soju-bouncer onboarding banner.
	/// The full key is built as `"\(bouncerOnboardingDismissedPrefix)\(server.id)"`
	/// and stores a `Bool`. Once set, the banner stays hidden across launches
	/// for that server even if the bouncer keeps advertising new networks.
	public static let bouncerOnboardingDismissedPrefix = "brygga.bouncerOnboarding.dismissed."
}
