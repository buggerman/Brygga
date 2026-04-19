/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation
import Security
import Network

/// Errors produced while loading a PKCS#12 client certificate for SASL EXTERNAL.
public enum ClientIdentityError: Error, Equatable {
	case fileNotFound(String)
	case importFailed(OSStatus)
	case noIdentity
}

/// Loads a PKCS#12 (`.p12` / `.pfx`) file from disk and returns a
/// Network-framework `sec_identity_t` suitable for
/// `sec_protocol_options_set_local_identity(_:_:)` — the identity is
/// presented as the TLS client certificate during the handshake, which
/// is the prerequisite for SASL EXTERNAL authentication.
public enum ClientIdentity {
	public static func load(path: String, passphrase: String?) throws -> sec_identity_t {
		let expanded = (path as NSString).expandingTildeInPath
		let url = URL(fileURLWithPath: expanded)
		guard let data = try? Data(contentsOf: url) else {
			throw ClientIdentityError.fileNotFound(expanded)
		}

		var items: CFArray?
		let options: [String: Any] = [
			kSecImportExportPassphrase as String: passphrase ?? ""
		]
		let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
		guard status == errSecSuccess,
		      let array = items as? [[String: Any]],
		      let first = array.first,
		      let anyIdentity = first[kSecImportItemIdentity as String]
		else {
			throw ClientIdentityError.importFailed(status)
		}
		let secIdentity = anyIdentity as! SecIdentity
		guard let identity = sec_identity_create(secIdentity) else {
			throw ClientIdentityError.noIdentity
		}
		return identity
	}
}
