/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import BryggaCore

@main
struct BryggaApp: App {
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
