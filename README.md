# Brygga

A modern, fast, feature-rich IRC client for macOS — built with Swift and SwiftUI.

Brygga is in early development. The core client works end-to-end (connect, join, send, receive, persist) but many features you'd expect from a mature IRC client are still missing.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15.4 or later (for building from source)
- Swift 5.9+

## Building

```sh
# Library + executable
swift build

# Run tests
swift test

# Produce a runnable .app bundle at build/Brygga.app
./Scripts/build-app.sh

# Launch
open build/Brygga.app
```

A raw `swift run Brygga` launches the binary as a background process — it will not open a window. Always run the built `.app` bundle.

## Current capabilities

- TLS connection to IRC servers (Network.framework, TLS by default on 6697)
- RFC 1459 + IRCv3 message-tag parsing
- Two-column layout with an inspector user list for channels
- Server console with raw incoming/outgoing logging
- Channel join/part/kick, topic display, user list with mode prefixes
- Private messages (query tabs), auto-opened on incoming or `/msg`
- Slash commands: `/join`, `/part`, `/nick`, `/me`, `/msg`, `/query`, and raw
- Persistence across launches: servers, joined channels, open queries
- Clean `QUIT` on app termination

## Not yet implemented

- Reconnect on socket drop
- SASL / NickServ authentication
- Preferences UI
- Notifications
- Scrollback persistence and history search
- Multi-window / detachable tabs
- Logging to disk

## Architecture

Brygga is split into two Swift Package Manager targets:

- `BryggaCore` — library. IRC protocol parser, `IRCConnection` actor (network I/O), `IRCSession` (`@MainActor`, wraps the connection and mutates `@Observable` models), persistence.
- `Brygga` — executable. SwiftUI views and the `@main` entry point.

Models (`Server`, `Channel`, `User`, `Message`) are `@Observable` and live on the main actor. The `actor`/`@MainActor` boundary is crossed via `AsyncStream` for incoming IRC messages and connection state changes.

Configuration lives in `~/Library/Application Support/Brygga/servers.json`.

## Contributing

See [AGENTS.md](AGENTS.md) for the rules AI coding agents (and humans) should follow when working in this repo.

## License

BSD 3-Clause. See source file headers.
