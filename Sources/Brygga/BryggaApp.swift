/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import AppKit
import BryggaCore

final class BryggaAppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
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
