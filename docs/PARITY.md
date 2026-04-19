# mIRC feature parity plan

**Target:** feature parity with mIRC, reimagined for macOS.

Brygga exists because mIRC is the benchmark for what a daily-driver IRC client should be able to do — and the Mac has never had an equivalent. The goal of this project is to cover everything a mIRC user expects, built native on macOS (Swift, SwiftUI, Liquid Glass on macOS 26, graceful fallback to standard materials on Sequoia) and without the Windows-era baggage.

Phase 1 / 2 / 3 are shipped. This document is the reference for what's in scope, out of scope, and in what order.

## Already shipped

Everything a mIRC daily-driver expects, minus DCC and the mIRC scripting language.

### Connection and protocol

- TLS connect on 6697 via `NWConnection`.
- SASL authentication, auto-selected per server:
  - **EXTERNAL** when a PKCS#12 client certificate is configured and the server advertises it (TLS client identity via `sec_protocol_options_set_local_identity`).
  - **SCRAM-SHA-256** when advertised — RFC 7677 exchange, PBKDF2 via CommonCrypto + HMAC/SHA-256 via CryptoKit.
  - **PLAIN** as the final fallback.
- IRCv3 CAP negotiation: `sasl`, `server-time`, `multi-prefix`, `userhost-in-names`, `chghost`, `account-tag`, `account-notify`, `away-notify`, `invite-notify`, `batch`, `chathistory` / `draft/chathistory`, `message-tags`.
- `server-time` → accurate message timestamps across reconnects.
- `userhost-in-names` → fills `User.username` / `hostname` on NAMES.
- `chghost` → live host updates after services login.
- `account-notify` / `account-tag` → tracks services-auth state on users.
- `away-notify` → `User.isAway` + `awayMessage` updates without WHOIS.
- `chathistory` → on own-JOIN, requests `CHATHISTORY LATEST <channel> * 100` to fill missed backlog; de-duped per session.
- `message-tags` → enables the IRCv3 typing indicator (`+typing` client tag via TAGMSG).
- MODE changes applied live — `+o` / `+v` / `+h` / `+a` / `+q` flip the corresponding user prefix (`@` / `+` / `%` / `&` / `~`) in the inspector as they land.
- Clean `QUIT` on app termination. Auto-reconnect with exponential backoff. User-initiated disconnect stays disconnected.
- Outbound token-bucket flood protection (1200-byte burst, 300 bytes/sec) with PONG bypass.
- Long-message chunking: PRIVMSG / ACTION split at space boundaries to respect the 512-byte IRC line limit; never splits mid-UTF-8.

### Commands

- `/join`, `/part`, `/nick`, `/me`, `/msg`, `/query`, `/topic`, `/quit`, `/disconnect`, `/list`.
- `/whois` with formatted 311/312/313/317/318/319/330/335/378/379/671 numeric output.
- `/away [msg]` + 305/306 handling.
- `/invite <nick> [#channel]` with auto-join-on-invite preference.
- `/ignore <nick|mask>` + `/unignore` + list.
- `/notify <nick>` buddy list with 60s ISON polling.
- `/perform` — per-server raw-line command list fired after 001.
- Unrecognised slashes fall through as raw IRC lines.

### Windowing and navigation

- Two-column `NavigationSplitView` with an inline user-list pane (hidden for PMs and the server console).
- Channel name + topic live in the **window title bar** (`.navigationTitle` / `.navigationSubtitle`) — no inline topic strip eating vertical space.
- Sidebar server rows are collapsible via a chevron; channel visibility persists per server.
- **Detachable tabs** — `Cmd+Shift+D` pops the selected channel into its own `WindowGroup` window sharing `AppState`.
- **Favorites / pinned channels** — right-click → *Pin to Favorites* puts channels in a dedicated top sidebar section; `Cmd+1…9` jumps to the first nine pinned channels; persisted per server.
- **Quick switcher** — `Cmd+K` opens a filterable list of every channel / PM across servers; Enter jumps.
- **Quick join** — `Cmd+J` opens a small sheet (server picker when multiple are connected) that sends JOIN.
- **Previous / next channel** — `Cmd+[` / `Cmd+]` cycle through the ordered sidebar list, wrapping at the ends.
- **Find in buffer** — `Cmd+F` filters the current channel with match count.
- **Find across all channels** — `Cmd+Shift+F` opens a modal sheet searching every server / channel / query (content + senders), capped at 300 most-recent hits; click a result to navigate.
- **Connect sheet** — curated **Known Networks** picker covering Libera.Chat, OFTC, Hackint, EFnet, IRCnet, Undernet, DALnet, QuakeNet, Rizon, SwiftIRC, Snoonet, GeekShed, Tilde Chat (or "Custom…" to type freely).
- Sidebar context menu on server rows — Connect / Disconnect / Remove Server.
- User-list context menu — Whois / Query / Op / Deop / Voice / Devoice / Kick / Kick+Ban / Ignore.
- `/list` channel browser with search + click-to-join.

### Chat rendering and input

- Stable per-nick colors (FNV-1a hashed into a 16-color palette).
- mIRC control-code rendering: `^B` bold, `^I` italic, `^U` underline, `^S` strikethrough, `^V` reverse, `^O` reset, `^K<fg>[,<bg>]` with the mIRC 16-color palette.
- URL and email detection — clickable, underlined, accent-colored.
- **Inline link previews** — `LinkPreviewStore` fetches `og:title` / `og:description` / `og:image`, Twitter card meta, and raw `image/*` thumbnails (capped at 2 MB / 10 s, http + https only). Default on, privacy-noted in Preferences.
- **Typing indicator** — IRCv3 `+typing` TAGMSG, throttled (active every 4 s, done on submit / empty draft / slash-command / channel switch). Status row above the InputBar auto-expires via `TimelineView`. Toggle in Preferences (share: on by default; receive: always on).
- **Emoji autocomplete** — ~300 curated Slack / Discord-style shortcodes; `:word:` auto-replaces to the glyph, Tab cycles through `:pref` matches.
- **Markdown-style input** — `*bold*` / `_italic_` / `~strike~` rewritten to mIRC control codes on send; toggle in Preferences → General (default on).
- Nick-mention highlight with accent gutter + Dock badge + macOS notifications.
- Custom highlight keywords (configurable in Preferences).
- Line marker — horizontal divider showing where the user last read a channel when returning.
- Tab nick completion with cycling.
- Up / down input history — shared across every InputBar in the app (survives channel switches, window swaps, PM ↔ channel transitions).
- CTCP auto-responses with per-sender cooldown: VERSION, PING, TIME, CLIENTINFO, SOURCE.
- MOTD display.
- `/away` moon indicator on the sidebar server row.

### Status bar

Footer row below the split view, visible in every window:

- Connection state dot (gray / yellow / orange / green / red), server name, `/nickname`.
- Live lag in milliseconds from a 30 s client-initiated `PING` → `PONG` round-trip.
- Member count of the focused channel (hidden for PMs and server consoles).
- Total channel count across all servers.

### Persistence and storage

- **Per-server + per-channel config** — `~/Library/Application Support/Brygga/servers.json` via `ServerStore`. Fields: host, port, TLS, nickname, SASL creds, client-cert path + passphrase, auto-join list, open queries, ignore list, notify list, perform commands, pinned channels. Every field is decoded with `decodeIfPresent` for forward/backward compatibility.
- **Scrollback** — JSONL at `~/Library/Application Support/Brygga/scrollback/<serverId>/<target>.log`. Rehydrated on launch; up to 500 most-recent lines per channel.
- **Plain-text disk logs** — opt-out (default on). `~/Library/Logs/Brygga/<network>/<channel>.log`, timestamped human-readable lines. First launch of 0.1.1+ auto-migrates logs from the pre-0.1.1 `~/Documents/Brygga Logs/` location.

### Preferences

Seven panes, opened via `Cmd+,`:

- **General** — show joins/parts, auto-join-on-invite, fetch link previews, markdown input, share typing indicator.
- **Identity** — default nick / user name / real name for the Connect sheet.
- **Appearance** — timestamp format (System / 12-hour / 24-hour), colorize nicknames toggle.
- **Notifications** — highlight keywords list.
- **Ignore** — per-server ignore-list table editor with add/remove.
- **Logging** — disk-logging toggle, log-folder path, Reveal-in-Finder button.
- **Servers** — list of saved servers with summary (host, TLS, nick, joined channels, perform count) and a Remove button.

Inline-editing the Servers list (host / port / SASL / perform) is the one thing not yet covered — that UI lands when there's demand.

### Distribution

Two release channels; both ad-hoc codesigned (`codesign --sign -`), no Developer-ID / notarization.

- **Stable** — manual `v*` tag push. `github.com/buggerman/Brygga/releases/latest` surfaces the newest one via GitHub's "Latest release" badge.
- **Nightly** — rolling prerelease at tag `nightly`, rebuilt on every push to `main`. Tag is deleted and recreated per push so the URL is always current. Title includes the 7-char commit SHA.

Pipeline: `swift test` → `Scripts/build-app.sh release` (injects `VERSION` / `BUILD_NUMBER` into `Info.plist`) → `hdiutil` UDZO DMG → `softprops/action-gh-release@v2`. `ci.yml` runs `swift build` + `swift test` on every push / PR. CI runs on a `macos-26` runner with Xcode 26 / Swift 6.2; binaries target macOS 15.

First launch needs right-click → **Open** (Gatekeeper). If that still refuses, `xattr -cr /Applications/Brygga.app` clears the quarantine attribute.

## Coming up

Phase 1 / 2 / 3 are all shipped. Further polish will surface from daily driving the client — nothing queued here right now.

## Out of scope (deliberate)

Not building these, and not feeling bad about it:

- **DCC** — Send, Get, Chat, Fserve, DCC Server, Passive DCC, SOCKS5-passthrough. Superseded by HTTP upload services (imgur, catbox, 0x0.st, private file share).
- **mIRC scripting language** — aliases-as-code, popups-as-scripts, remote event handlers, `$identifiers`, `%vars`, timers, hash tables, binary-file manipulation, regex DSL, `/raw` scripting, `@window` custom dialogs. Massive security and implementation surface. If users need automation, they run a bot.
- **DLL / COM / DDE** — Windows-only, deprecated paradigms.
- **Event sounds** — `.wav` / `.mid` / `.mp3` playback, `/sound`, `/splay`, beep-on-event. macOS notification sound is enough.
- **Microsoft Agent TTS** — dead platform.
- **SOCKS4/5 / HTTP proxy** — not a 2026 problem. If users need a proxy, they use system-level networking.
- **Identd server** — no modern network requires it.
- **URL catcher window** — separate catch-all URL list. Inline detection covers the use case.
- **Custom popup scripts** — mIRC's scriptable right-click menus. Plain `.contextMenu` is enough.
- **Toolbars / wallpaper / button themes / picture windows** — Liquid Glass native look only.
- **mIRC `.ini` file compatibility** — JSON and modern formats throughout.
- **Fileserve (Fserve)** — DCC-adjacent.
