/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import BryggaCore

/// The root Preferences window, wired from `BryggaApp`'s `Settings` scene.
/// First-cut scope: General + Notifications. Identity, Appearance, Logging,
/// Ignore, and per-server editors land in later passes.
struct PreferencesView: View {
	var body: some View {
		TabView {
			GeneralPane()
				.tabItem { Label("General", systemImage: "gear") }
			NotificationsPane()
				.tabItem { Label("Notifications", systemImage: "bell") }
		}
		.frame(width: 520, height: 380)
	}
}

struct GeneralPane: View {
	@AppStorage(PreferencesKeys.showJoinsParts) private var showJoinsParts = true
	@AppStorage(PreferencesKeys.autoJoinOnInvite) private var autoJoinOnInvite = false
	@AppStorage(PreferencesKeys.diskLoggingEnabled) private var diskLoggingEnabled = false

	var body: some View {
		Form {
			Section("Channels") {
				Toggle("Show joins and parts in channels", isOn: $showJoinsParts)
				Toggle("Auto-join channels when invited", isOn: $autoJoinOnInvite)
			}
			Section {
				Toggle("Write plain-text logs to disk", isOn: $diskLoggingEnabled)
			} header: {
				Text("Logging")
			} footer: {
				Text("Logs are written to ~/Documents/Brygga Logs/<network>/<channel>.log. This is in addition to the in-app scrollback (which always persists).")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}

struct NotificationsPane: View {
	@AppStorage(PreferencesKeys.highlightKeywordsRaw) private var keywordsRaw: String = ""

	var body: some View {
		Form {
			Section {
				TextEditor(text: $keywordsRaw)
					.font(.system(.body, design: .monospaced))
					.frame(minHeight: 140)
			} header: {
				Text("Highlight keywords")
			} footer: {
				Text("One keyword per line. Messages mentioning any of these trigger a highlight and notification. Your own nickname is always a highlight.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.padding()
	}
}

