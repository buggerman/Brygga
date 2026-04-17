/* *********************************************************************
 *  Brygga — A modern IRC client for macOS
 *  Copyright (c) 2026 Brygga contributors
 *  BSD 3-Clause License
 *********************************************************************** */

import Foundation
import Observation

/// Root application state. Holds all servers, channels, and selection.
/// SwiftUI views observe this directly.
@Observable
public final class AppState {
	/// Connected and disconnected servers.
	public var servers: [Server] = []

	/// Currently selected item (server or channel) identified by `id`.
	public var selection: String?

	public init() { }

	/// Convenience: the channel that's currently selected, if any.
	public var selectedChannel: Channel? {
		guard let id = selection else { return nil }
		for server in servers {
			if let ch = server.channels.first(where: { $0.id == id }) {
				return ch
			}
		}
		return nil
	}

	/// Convenience: the server whose row is selected, OR the server owning the
	/// currently selected channel.
	public var selectedServer: Server? {
		guard let id = selection else { return nil }
		if let server = servers.first(where: { $0.id == id }) {
			return server
		}
		for server in servers {
			if server.channels.contains(where: { $0.id == id }) {
				return server
			}
		}
		return nil
	}
}
