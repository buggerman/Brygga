/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import AppKit
import BryggaCore

final class BryggaAppDelegate: NSObject, NSApplicationDelegate {
	weak var appState: AppState?

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard let appState = appState, !appState.sessions.isEmpty else { return .terminateNow }
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
	@State private var appState = AppState()

	var body: some Scene {
		Window("Brygga", id: "main") {
			ContentView()
				.environment(appState)
				.frame(minWidth: 900, minHeight: 600)
				.containerBackground(.thinMaterial, for: .window)
				.onAppear { appDelegate.appState = appState }
		}
		.windowStyle(.titleBar)
		.commands {
			CommandMenu("Server") {
				Button("New Server\u{2026}") { }
					.keyboardShortcut("n", modifiers: [.command, .shift])
				Button("Connect") { }
				Button("Disconnect") { }
			}
			CommandMenu("Channel") {
				Button("Join Channel\u{2026}") { appState.showingQuickJoin = true }
					.keyboardShortcut("j", modifiers: [.command])
				Button("Leave Channel") { }
					.keyboardShortcut("w", modifiers: [.command])
				Divider()
				Button("Switch Channel\u{2026}") { appState.showingQuickSwitcher = true }
					.keyboardShortcut("k", modifiers: [.command])
				Button("Previous Channel") { appState.selectAdjacentChannel(direction: -1) }
					.keyboardShortcut("[", modifiers: [.command])
				Button("Next Channel") { appState.selectAdjacentChannel(direction: 1) }
					.keyboardShortcut("]", modifiers: [.command])
			}
			CommandMenu("Favorites") {
				ForEach(0..<9, id: \.self) { index in
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
					.containerBackground(.thinMaterial, for: .window)
			}
		}

		Settings {
			PreferencesView()
				.environment(appState)
		}
	}
}
