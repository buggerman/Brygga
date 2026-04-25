// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// One upstream IRC network advertised by a soju-style bouncer through
/// the `soju.im/bouncer-networks` cap. Discovered via `BOUNCER
/// LISTNETWORKS` and updated through `BOUNCER NETWORK <netid> <attrs>`
/// notifications when the `soju.im/bouncer-networks-notify` cap is on.
///
/// Read-only in Layer 2A — Brygga surfaces the list in the sidebar so
/// the user knows the bouncer is fronting multiple networks. Layer 2B
/// will route channel state per network.
public struct BouncerNetwork: Identifiable, Sendable, Equatable {
	/// soju-assigned per-user "netid". Stable across sessions; the spec
	/// guarantees it doesn't change during the lifetime of the network.
	public let id: String
	/// Human-readable label set by the bouncer or the user (`name`
	/// attribute). Falls back to `host` when unset.
	public var name: String?
	/// Hostname of the upstream IRC server (`host` attribute).
	public var host: String?
	/// `connected` / `connecting` / `disconnected`. Read-only on the
	/// bouncer side. `unknown` covers attribute strings the bouncer
	/// emits that we don't recognise — Brygga ignores them per the
	/// spec's "Clients MUST ignore unknown attributes" rule.
	public var state: State
	/// Bouncer-supplied short error string when `state == .disconnected`.
	/// Optional; empty for connected networks.
	public var errorMessage: String?

	public enum State: String, Sendable, Equatable {
		case connected
		case connecting
		case disconnected
		case unknown
	}

	public init(
		id: String,
		name: String? = nil,
		host: String? = nil,
		state: State = .unknown,
		errorMessage: String? = nil,
	) {
		self.id = id
		self.name = name
		self.host = host
		self.state = state
		self.errorMessage = errorMessage
	}

	/// Build a network value from a raw attribute dictionary as parsed
	/// from `BOUNCER NETWORK <netid> name=…;state=…;…`. Unknown
	/// attribute keys are silently ignored.
	public init(id: String, attributes: [String: String]) {
		self.init(
			id: id,
			name: attributes["name"],
			host: attributes["host"],
			state: State(rawValue: attributes["state"] ?? "") ?? .unknown,
			errorMessage: attributes["error"],
		)
	}

	/// Apply a notification's incremental attribute update onto an
	/// existing network. Per the spec, attributes whose value is the
	/// empty string mean "removed"; attributes absent from the update
	/// keep their previous value.
	public mutating func merge(_ attributes: [String: String]) {
		if let n = attributes["name"] {
			name = n.isEmpty ? nil : n
		}
		if let h = attributes["host"] {
			host = h.isEmpty ? nil : h
		}
		if let s = attributes["state"] {
			state = State(rawValue: s) ?? .unknown
		}
		if let e = attributes["error"] {
			errorMessage = e.isEmpty ? nil : e
		}
	}
}
