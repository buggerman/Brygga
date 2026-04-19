// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

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
	@State private var certPath: String = ""
	@State private var certPassphrase: String = ""

	/// Network picker selection. `""` is the "Custom\u{2026}" sentinel;
	/// any other value matches a `KnownNetwork.id`.
	@State private var selectedNetworkID: String = "Libera.Chat"

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
					Picker("Network", selection: $selectedNetworkID) {
						Text("Custom\u{2026}").tag("")
						ForEach(KnownNetworks.all) { net in
							Text(net.name).tag(net.id)
						}
					}
					.onChange(of: selectedNetworkID) { _, newID in
						applyNetwork(id: newID)
					}
					TextField("Name", text: $name, prompt: Text("Libera"))
					TextField("Host", text: $host)
						.onChange(of: host) { _, newHost in
							// Host edits that don't match a known network
							// flip the picker back to Custom.
							let matched = KnownNetworks.network(withHost: newHost)?.id ?? ""
							if matched != selectedNetworkID {
								selectedNetworkID = matched
							}
						}
					TextField("Port", text: $portText)
						.monospaced()
					TextField("Nickname", text: $nickname)
					Toggle("Use TLS", isOn: $useTLS)
				} footer: {
					if let network = KnownNetworks.all.first(where: { $0.id == selectedNetworkID }) {
						Text(network.summary)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Section("SASL (optional)") {
					TextField("Account", text: $saslAccount, prompt: Text("usually same as nickname"))
						.textContentType(.username)
					SecureField("Password", text: $saslPassword)
				}
				Section {
					HStack {
						TextField("Certificate (.p12)", text: $certPath, prompt: Text("no client certificate"))
							.truncationMode(.middle)
						Button("Choose\u{2026}") { chooseCert() }
					}
					SecureField("Passphrase", text: $certPassphrase)
						.disabled(certPath.isEmpty)
				} header: {
					Text("Client certificate (optional)")
				} footer: {
					Text("Enables SASL EXTERNAL. The certificate is presented during TLS and reused on every reconnect.")
						.font(.caption)
						.foregroundStyle(.secondary)
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
		let trimmedCertPath = certPath.trimmingCharacters(in: .whitespaces)
		let effectiveCertPath = trimmedCertPath.isEmpty ? nil : trimmedCertPath
		let effectiveCertPassphrase = (effectiveCertPath == nil || certPassphrase.isEmpty) ? nil : certPassphrase
		appState.addServer(
			name: name,
			host: host.trimmingCharacters(in: .whitespaces),
			port: port,
			useTLS: useTLS,
			nickname: nickname.trimmingCharacters(in: .whitespaces),
			saslAccount: account,
			saslPassword: password,
			clientCertificatePath: effectiveCertPath,
			clientCertificatePassphrase: effectiveCertPassphrase
		)
		dismiss()
	}

	/// Copy the selected network's defaults into the form fields. Preserves
	/// the user-chosen `name` if they already typed one (since names are
	/// purely for their own sidebar labelling). Empty id = Custom, no-op.
	private func applyNetwork(id: String) {
		guard let network = KnownNetworks.all.first(where: { $0.id == id }) else {
			return
		}
		host = network.host
		portText = String(network.port)
		useTLS = network.useTLS
		if name.trimmingCharacters(in: .whitespaces).isEmpty {
			name = network.name
		}
	}

	private func chooseCert() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.init(filenameExtension: "p12")!, .init(filenameExtension: "pfx")!]
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		panel.canChooseFiles = true
		if panel.runModal() == .OK, let url = panel.url {
			certPath = url.path
		}
	}
}
