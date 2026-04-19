// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation
import Security

/// Thin wrapper around the macOS Keychain for per-server secrets:
/// SASL passwords and PKCS#12 passphrases. Used in place of the
/// previous practice of storing them in plaintext inside
/// `~/Library/Application Support/Brygga/servers.json`.
///
/// Items land under `kSecClassGenericPassword` with
/// `kSecAttrService = "org.buggerman.Brygga"` and an account name
/// derived from `server.id` + the field kind (`.saslPassword`, etc.).
/// `AppState` handles read-through, write-through, and legacy-JSON
/// migration — callers outside that file shouldn't need this API.
public enum KeychainStore {

	public enum Field: String {
		case saslPassword
		case certificatePassphrase
	}

	private static let service = "org.buggerman.Brygga"

	/// Stable account name for a given server + field. Used as the
	/// `kSecAttrAccount` value.
	public static func account(for serverID: String, field: Field) -> String {
		"\(serverID).\(field.rawValue)"
	}

	/// Store `value` under the given account. Empty `value` deletes the
	/// entry. Returns `true` on success or when the entry was expectedly
	/// absent; `false` on a real Keychain error (e.g. no entitlement in a
	/// test harness, locked keychain).
	@discardableResult
	public static func setSecret(_ value: String, for serverID: String, field: Field) -> Bool {
		let account = account(for: serverID, field: field)
		if value.isEmpty {
			return deleteSecret(for: serverID, field: field)
		}
		let data = Data(value.utf8)

		// Try to update an existing item; if it isn't present, add a new one.
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		let updateStatus = SecItemUpdate(
			query as CFDictionary,
			[kSecValueData as String: data] as CFDictionary
		)
		if updateStatus == errSecSuccess { return true }
		guard updateStatus == errSecItemNotFound else { return false }

		var addQuery = query
		addQuery[kSecValueData as String] = data
		addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
		return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
	}

	/// Fetch the stored secret for the given account. `nil` if absent or
	/// unreadable.
	public static func secret(for serverID: String, field: Field) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account(for: serverID, field: field),
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		guard status == errSecSuccess,
		      let data = item as? Data,
		      let string = String(data: data, encoding: .utf8)
		else { return nil }
		return string
	}

	/// Remove the secret. No-op when it wasn't there.
	@discardableResult
	public static func deleteSecret(for serverID: String, field: Field) -> Bool {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account(for: serverID, field: field),
		]
		let status = SecItemDelete(query as CFDictionary)
		return status == errSecSuccess || status == errSecItemNotFound
	}

	/// Remove every secret associated with a server — called when
	/// `AppState.removeServer` tears a server down.
	public static func deleteAllSecrets(for serverID: String) {
		for field in [Field.saslPassword, .certificatePassphrase] {
			deleteSecret(for: serverID, field: field)
		}
	}
}
