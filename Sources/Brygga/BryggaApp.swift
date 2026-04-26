// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import AppKit
import BryggaCore
import SwiftUI

final class BryggaAppDelegate: NSObject, NSApplicationDelegate {
	weak var appState: AppState?

	func applicationDidFinishLaunching(_: Notification) {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
		true
	}

	func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
		guard let appState, !appState.sessions.isEmpty else { return .terminateNow }
		Task { @MainActor in
			await appState.disconnectAll(quitMessage: "Brygga")
			NSApp.reply(toApplicationShouldTerminate: true)
		}
		return .terminateLater
	}
}

@main
struct BryggaApp: App {
	@NSApplicationDelegateAdaptor(BryggaAppDelegate.self) private var appDelegate
	@State private var appState = AppState(
		store: .shared,
		scrollbackStore: .shared,
		scrollbackIndex: .shared,
	)

	var body: some Scene {
		Window("Brygga", id: "main") {
			ContentView()
				.environment(appState)
				.frame(minWidth: 900, minHeight: 600)
				.containerBackground(.regularMaterial, for: .window)
				.onAppear { appDelegate.appState = appState }
		}
		.windowStyle(.titleBar)
		.defaultSize(width: 1200, height: 780)
		.commands {
			// Replace SwiftUI's default "About Brygga" with one that
			// surfaces the BSD-3-Clause notice in the credits area —
			// satisfies the binary-redistribution clause and the App
			// Store license-disclosure expectation.
			CommandGroup(replacing: .appInfo) {
				Button("About Brygga") { Acknowledgements.showAboutPanel() }
			}
			CommandMenu("Server") {
				Button("New Server\u{2026}") { appState.showingConnectSheet = true }
					.keyboardShortcut("n", modifiers: [.command, .shift])
				Button("Connect") {
					if let id = appState.selectedServer?.id {
						appState.reconnectServer(id: id)
					}
				}
				.disabled(appState.selectedServer == nil)
				Button("Disconnect") {
					if let id = appState.selectedServer?.id {
						Task { await appState.disconnectServer(id: id) }
					}
				}
				.disabled(appState.selectedServer == nil)
			}
			CommandMenu("Channel") {
				Button("Join Channel\u{2026}") { appState.showingQuickJoin = true }
					.keyboardShortcut("j", modifiers: [.command])
				// Cmd+W: PART for regular channels, close-tab for PMs.
				// `/part` doesn't apply to a query — sending it would be
				// a server-side error — so a PM tab needs the in-memory
				// removal path on `AppState`.
				Button(appState.selectedChannel?.isPrivateMessage == true
					? "Close Private Message"
					: "Leave Channel")
				{
					guard let channel = appState.selectedChannel else { return }
					if channel.isPrivateMessage {
						appState.closePrivateMessage(channelID: channel.id)
					} else if let session = appState.selectedSession {
						Task { try? await session.part(channel.name) }
					}
				}
				.keyboardShortcut("w", modifiers: [.command])
				.disabled(appState.selectedChannel == nil)
				Divider()
				Button("Switch Channel\u{2026}") { appState.showingQuickSwitcher = true }
					.keyboardShortcut("k", modifiers: [.command])
				Button("Previous Channel") { appState.selectAdjacentChannel(direction: -1) }
					.keyboardShortcut("[", modifiers: [.command])
				Button("Next Channel") { appState.selectAdjacentChannel(direction: 1) }
					.keyboardShortcut("]", modifiers: [.command])
			}
			CommandMenu("Favorites") {
				ForEach(0 ..< 9, id: \.self) { index in
					let pinned = appState.pinnedChannels
					Button(pinned.indices.contains(index) ? pinned[index].name : "Favorite \(index + 1)") {
						let current = appState.pinnedChannels
						guard current.indices.contains(index) else { return }
						appState.selection = current[index].id
					}
					.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
					.disabled(!pinned.indices.contains(index))
				}
			}
		}

		WindowGroup(id: "channel", for: String.self) { $channelID in
			if let id = channelID {
				DetachedChannelView(channelID: id)
					.environment(appState)
					.frame(minWidth: 600, minHeight: 400)
					.containerBackground(.regularMaterial, for: .window)
			}
		}

		Settings {
			PreferencesView()
				.environment(appState)
		}
	}
}
