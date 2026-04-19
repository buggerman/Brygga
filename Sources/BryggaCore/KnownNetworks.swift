// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// A curated IRC network entry. Drives the `Connect to Server` sheet's
/// "Network" picker so users don't have to remember hostnames.
public struct KnownNetwork: Identifiable, Hashable, Sendable {
	public var id: String { name }
	public let name: String
	public let host: String
	public let port: UInt16
	public let useTLS: Bool
	public let summary: String

	public init(name: String, host: String, port: UInt16, useTLS: Bool, summary: String) {
		self.name = name
		self.host = host
		self.port = port
		self.useTLS = useTLS
		self.summary = summary
	}
}

/// Built-in list of commonly-used IRC networks. Not exhaustive —
/// users can always pick "Custom\u{2026}" in the Connect sheet to type
/// anything. Ports default to 6697 + TLS; the handful that still don't
/// advertise TLS are listed on 6667 so the picker doesn't lie.
public enum KnownNetworks {
	public static let all: [KnownNetwork] = [
		KnownNetwork(
			name: "Libera.Chat",
			host: "irc.libera.chat",
			port: 6697,
			useTLS: true,
			summary: "Successor to freenode; many FOSS projects (Debian, Ubuntu, Fedora, KDE, GNOME) live here."
		),
		KnownNetwork(
			name: "OFTC",
			host: "irc.oftc.net",
			port: 6697,
			useTLS: true,
			summary: "Open and Free Technology Community; home of Debian, Tor, KiCad, Let\u{2019}s Encrypt."
		),
		KnownNetwork(
			name: "Hackint",
			host: "irc.hackint.org",
			port: 6697,
			useTLS: true,
			summary: "CCC-adjacent network; hackerspaces, CCC events, privacy and security projects."
		),
		KnownNetwork(
			name: "EFnet",
			host: "irc.efnet.org",
			port: 6697,
			useTLS: true,
			summary: "One of the oldest surviving IRC networks. No NickServ — nicks are first-come-first-served."
		),
		KnownNetwork(
			name: "IRCnet",
			host: "open.ircnet.net",
			port: 6667,
			useTLS: false,
			summary: "Classic European network. Plaintext only on most servers."
		),
		KnownNetwork(
			name: "Undernet",
			host: "irc.undernet.org",
			port: 6697,
			useTLS: true,
			summary: "General-purpose legacy network; heavy channel-services focus via X."
		),
		KnownNetwork(
			name: "DALnet",
			host: "irc.dal.net",
			port: 6697,
			useTLS: true,
			summary: "General chat, games, anime. Strong NickServ/ChanServ service layer."
		),
		KnownNetwork(
			name: "QuakeNet",
			host: "irc.quakenet.org",
			port: 6667,
			useTLS: false,
			summary: "Gaming-focused, historically tied to Quake and eSports communities."
		),
		KnownNetwork(
			name: "Rizon",
			host: "irc.rizon.net",
			port: 6697,
			useTLS: true,
			summary: "Anime, manga, fansubs, file sharing."
		),
		KnownNetwork(
			name: "SwiftIRC",
			host: "irc.swiftirc.net",
			port: 6697,
			useTLS: true,
			summary: "General-purpose community network."
		),
		KnownNetwork(
			name: "Snoonet",
			host: "irc.snoonet.org",
			port: 6697,
			useTLS: true,
			summary: "Reddit-adjacent communities and channel groups."
		),
		KnownNetwork(
			name: "GeekShed",
			host: "irc.geekshed.net",
			port: 6697,
			useTLS: true,
			summary: "General-purpose, tech- and fandom-leaning."
		),
		KnownNetwork(
			name: "Tilde Chat",
			host: "irc.tilde.chat",
			port: 6697,
			useTLS: true,
			summary: "Tildeverse / pubnix network; low-key, small, text-first."
		),
	]

	/// Lookup by hostname, case-insensitive. Returns `nil` when the
	/// host isn't in the curated list (i.e. it's a custom connection).
	public static func network(withHost host: String) -> KnownNetwork? {
		let lower = host.lowercased()
		return all.first { $0.host.lowercased() == lower }
	}
}
