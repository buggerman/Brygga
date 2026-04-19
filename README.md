# Brygga

A modern, fast, feature-rich IRC client for macOS — built with Swift and SwiftUI.

Brygga is in early development. The core client works end-to-end (connect, join, send, receive, persist) but many features you'd expect from a mature IRC client are still missing.

## Requirements

- macOS 15 Sequoia or later (looks best on macOS 26 with Liquid Glass materials, but falls back gracefully to the standard `.bar` / `.thinMaterial` / `.regularMaterial` surfaces on earlier releases)
- Apple Silicon only (arm64 — no Intel builds)
- Xcode 26 or later (for building from source)
- Swift 6.0+

## Download

Brygga ships on two tracks:

- **Stable** — [latest release](https://github.com/buggerman/Brygga/releases/latest). Cut manually from a `v*` tag; changes infrequently. Use this unless you want the cutting edge.
- **Nightly** — [`releases/tag/nightly`](https://github.com/buggerman/Brygga/releases/tag/nightly). Rebuilt on every push to `main`; the tag is deleted and recreated each time so the URL is always current. Marked prerelease. Expect rough edges between commits.

Either way, grab the `.dmg`, drag **Brygga.app** to `/Applications`, then right-click → **Open** on first launch (the binary is ad-hoc signed, not Developer-ID notarized).

If Gatekeeper refuses to open it even after right-click → Open (e.g. *"Apple could not verify Brygga is free of malware"*), strip the quarantine attribute once and retry:

```sh
xattr -cr /Applications/Brygga.app
```

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

Brygga already covers everything a mIRC daily-driver expects, minus DCC and the mIRC scripting language. A non-exhaustive summary:

- TLS-by-default on 6697 via Network.framework, auto-reconnect with exponential backoff, outbound flood protection
- SASL **EXTERNAL** (TLS client certificate), **SCRAM-SHA-256** (RFC 7677), or **PLAIN** — auto-selected based on what the server advertises
- IRCv3 caps: `server-time`, `multi-prefix`, `userhost-in-names`, `chghost`, `account-tag` / `account-notify`, `away-notify`, `invite-notify`, `batch`, `chathistory` / `draft/chathistory`, `message-tags`
- Slash commands: `/join`, `/part`, `/nick`, `/me`, `/msg`, `/query`, `/topic`, `/whois`, `/away`, `/invite`, `/ignore`, `/notify`, `/list`, `/perform`, plus raw fallthrough
- Two-column `NavigationSplitView` with auto-hiding user-list inspector, detachable channel windows (`Cmd+Shift+D`), pinned favorites (`Cmd+1…9`), quick switcher (`Cmd+K`), quick join (`Cmd+J`), prev/next channel (`Cmd+[` / `Cmd+]`), in-buffer find (`Cmd+F`), cross-channel find (`Cmd+Shift+F`), tab nick completion, emoji autocomplete (`:smile:` → 😄)
- IRCv3 typing indicator (`+typing` TAGMSG), inline OG / image link previews, mIRC control-code rendering, markdown-style input (`*bold*` / `_italic_` / `~strike~`), stable per-nick colors, highlight notifications with Dock badge, per-channel line marker, status bar with live lag, Liquid Glass chrome across chat, sidebar, and windows
- Preferences: show-joins/parts, auto-join-on-invite, link-previews, identity defaults, timestamp format, colorize nicknames, highlight keywords, ignore list, disk logging, saved servers
- Persistence: servers + channels + preferences in `~/Library/Application Support/Brygga`, scrollback as JSONL, opt-in plain-text logs under `~/Documents/Brygga Logs`

Full list and what's still on the backlog lives in [docs/PARITY.md](docs/PARITY.md).

## Roadmap

Phase 1 / 2 / 3 of the [mIRC parity plan](docs/PARITY.md) are shipped. Further polish will surface from daily driving the client.

### Explicitly out of scope

- DCC file transfer (see [PARITY.md](docs/PARITY.md) for the full "out of scope" list)
- Objective-C or C interop — see [AGENTS.md](AGENTS.md)

## Architecture

Brygga is split into two Swift Package Manager targets:

- `BryggaCore` — library. IRC protocol parser, `IRCConnection` actor (network I/O), `IRCSession` (`@MainActor`, wraps the connection and mutates `@Observable` models), persistence.
- `Brygga` — executable. SwiftUI views and the `@main` entry point.

Models (`Server`, `Channel`, `User`, `Message`) are `@Observable` and live on the main actor. The `actor`/`@MainActor` boundary is crossed via `AsyncStream` for incoming IRC messages and connection state changes.

Configuration lives in `~/Library/Application Support/Brygga/servers.json`.

## Contributing

See [AGENTS.md](AGENTS.md) for the rules AI coding agents (and humans) should follow when working in this repo.

The mIRC feature-parity plan — what's in scope, out of scope, and in what order — lives in [docs/PARITY.md](docs/PARITY.md).

## License

BSD 3-Clause. See source file headers.
