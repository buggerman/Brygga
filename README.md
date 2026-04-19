# Brygga

A modern, fast, feature-rich IRC client for macOS — built with Swift and SwiftUI.

Brygga is in early development. The core client works end-to-end (connect, join, send, receive, persist) but many features you'd expect from a mature IRC client are still missing.

## Requirements

- macOS 26 or later (earlier versions not supported — Brygga uses Liquid Glass)
- Apple Silicon only (arm64 — no Intel builds)
- Xcode 26 or later (for building from source)
- Swift 6.0+

## Download

The rolling **[latest release](https://github.com/buggerman/Brygga/releases/tag/latest)** is rebuilt automatically on every push to `main`. Grab the `.dmg`, drag **Brygga.app** to `/Applications`, then right-click → **Open** on first launch (the binary is ad-hoc signed, not Developer-ID notarized).

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
- Two-column `NavigationSplitView` with auto-hiding user-list inspector, detachable channel windows (`Cmd+Shift+D`), pinned favorites (`Cmd+1…9`), in-buffer find (`Cmd+F`), cross-channel find (`Cmd+Shift+F`), tab nick completion, emoji autocomplete (`:smile:` → 😄)
- IRCv3 typing indicator (`+typing` TAGMSG), inline OG / image link previews, mIRC control-code rendering, stable per-nick colors, highlight notifications with Dock badge, per-channel line marker
- Preferences: show-joins/parts, auto-join-on-invite, link-previews, identity defaults, timestamp format, colorize nicknames, highlight keywords, ignore list, disk logging, saved servers
- Persistence: servers + channels + preferences in `~/Library/Application Support/Brygga`, scrollback as JSONL, opt-in plain-text logs under `~/Documents/Brygga Logs`

Full list and what's still on the backlog lives in [docs/PARITY.md](docs/PARITY.md).

## Roadmap

The remaining polish items, in the order we'd tackle them next — directional, not a commitment:

1. Markdown-style input (`*bold*` → `^B`) as an optional toggle
2. Keyboard shortcuts — `Cmd+K` switch channel, `Cmd+J` quick join, `Cmd+[` / `Cmd+]` prev/next channel
3. Status bar — connection state, lag, server ping
4. Liquid Glass tuning on chat surface, sidebar, and inspector

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
