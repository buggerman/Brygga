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
				Button("Join Channel\u{2026}") { }
					.keyboardShortcut("j", modifiers: [.command])
				Button("Leave Channel") { }
					.keyboardShortcut("w", modifiers: [.command])
			}
		}
	}
}
