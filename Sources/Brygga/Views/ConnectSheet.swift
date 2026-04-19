/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import SwiftUI
import BryggaCore

@MainActor
struct ConnectSheet: View {
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss

	@State private var name: String = ""
	@State private var host: String = "irc.libera.chat"
	@State private var portText: String = "6697"
	@State private var nickname: String = Self.initialNickname()
	@State private var useTLS: Bool = true
	@State private var saslAccount: String = ""
	@State private var saslPassword: String = ""

	/// Picks the default nickname from preferences, falling back to the macOS
	/// user short name when the pref is blank.
	private static func initialNickname() -> String {
		let stored = UserDefaults.standard.string(forKey: PreferencesKeys.defaultNickname) ?? ""
		return stored.isEmpty ? NSUserName() : stored
	}

	private var port: UInt16? { UInt16(portText) }

	private var canSubmit: Bool {
		!host.trimmingCharacters(in: .whitespaces).isEmpty &&
		!nickname.trimmingCharacters(in: .whitespaces).isEmpty &&
		port != nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Connect to Server")
					.font(.headline)
				Spacer()
			}
			.padding(.horizontal, 20)
			.padding(.top, 20)
			.padding(.bottom, 10)

			Form {
				Section {
					TextField("Name", text: $name, prompt: Text("Libera"))
					TextField("Host", text: $host)
					TextField("Port", text: $portText)
						.monospaced()
					TextField("Nickname", text: $nickname)
					Toggle("Use TLS", isOn: $useTLS)
				}
				Section("SASL (optional)") {
					TextField("Account", text: $saslAccount, prompt: Text("usually same as nickname"))
						.textContentType(.username)
					SecureField("Password", text: $saslPassword)
				}
			}
			.formStyle(.grouped)
			.padding(.horizontal, 8)

			HStack {
				Spacer()
				Button("Cancel", role: .cancel) {
					dismiss()
				}
				.keyboardShortcut(.cancelAction)

				Button("Connect") {
					submit()
				}
				.keyboardShortcut(.defaultAction)
				.disabled(!canSubmit)
			}
			.padding(20)
		}
		.frame(width: 460)
	}

	private func submit() {
		guard let port = port else { return }
		let trimmedAccount = saslAccount.trimmingCharacters(in: .whitespaces)
		let account = trimmedAccount.isEmpty ? nil : trimmedAccount
		let password = saslPassword.isEmpty ? nil : saslPassword
		appState.addServer(
			name: name,
			host: host.trimmingCharacters(in: .whitespaces),
			port: port,
			useTLS: useTLS,
			nickname: nickname.trimmingCharacters(in: .whitespaces),
			saslAccount: account,
			saslPassword: password
		)
		dismiss()
	}
}
