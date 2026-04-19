# mIRC Feature Parity Plan

Brygga aims for **feature parity with mIRC** for everything a daily-driver IRC user expects, while being deliberately modern-native (macOS 26, SwiftUI, Liquid Glass) and excluding obsolete or Windows-specific features. This document is the reference for what's in scope, out of scope, and in what order.

## Already shipped

Phase 1 is effectively complete — everything a mIRC daily-driver expects (minus DCC and scripting) is in place.

### Connection and identity
- TLS connect on 6697 via `NWConnection`
- SASL authentication — SCRAM-SHA-256 preferred when the server advertises it (RFC 7677 exchange with PBKDF2 via CommonCrypto and HMAC/SHA-256 via CryptoKit), falls back to PLAIN otherwise
- IRCv3 CAP negotiation: `sasl`, `server-time`, `multi-prefix`, `userhost-in-names`, `chghost`, `account-tag`, `account-notify`, `away-notify`, `invite-notify`, `batch`, `chathistory` / `draft/chathistory`
- `server-time` tag used for message timestamps (accurate scrollback across reconnects)
- `userhost-in-names` → populates `User.username` / `hostname` on NAMES
- `chghost` → live host updates after services login
- `account-notify` / `account-tag` → tracks services-auth state on users
- `away-notify` → `User.isAway` + `awayMessage` updates without WHOIS
- `chathistory` → on own-JOIN, requests `CHATHISTORY LATEST <channel> * 100` to fill missed backlog from the server; de-duped per session and reset on each 001 welcome
- Clean `QUIT` on app termination
- Auto-reconnect with exponential backoff
- User-initiated disconnect that stays disconnected
- Outbound token-bucket flood protection (1200-byte burst, 300 bytes/sec) with PONG bypass
- Long-message chunking: PRIVMSG/ACTION split at space boundaries to respect the 512-byte IRC line limit; never splits mid-UTF-8

### Commands
- `/join`, `/part`, `/nick`, `/me`, `/msg`, `/query`, `/topic`, `/quit`, `/disconnect`, `/list`
- `/whois` with formatted 311/312/313/317/318/319/330/335/378/379/671 numeric output
- `/away [msg]` + 305/306 handling
- `/invite <nick> [#channel]` with auto-join-on-invite preference
- `/ignore <nick|mask>` + `/unignore` + list
- `/notify <nick>` buddy list with 60s ISON polling
- `/perform` — per-server raw-line command list fired after 001
- Slash fallthrough sends raw IRC lines

### UX
- Two-column `NavigationSplitView` with user-list inspector (auto-hides for PMs and server console)
- Per-server + per-channel persistence: host, port, TLS, nick, SASL creds, auto-join list, open queries, ignore list, notify list, perform commands
- Scrollback persistence as JSONL, rehydrated on launch
- Opt-in plain-text disk logging under `~/Documents/Brygga Logs/<network>/<channel>.log`
- Stable per-nick colors (FNV-1a hashed into a 16-color palette)
- mIRC control-code rendering: `^B` bold, `^I` italic, `^U` underline, `^S` strikethrough, `^V` reverse, `^O` reset, `^K<fg>[,<bg>]` with the mIRC 16-color palette
- URL and email detection in messages — clickable, underlined, accent-colored
- Nick-mention highlight with accent gutter + Dock badge + macOS notifications
- Custom highlight keywords (user-configurable in Preferences)
- Line marker — horizontal divider showing where you last read a channel when returning
- Find in buffer (`Cmd+F`) with live filter + match count
- Tab nick completion with cycling
- Up/down input history (per-InputBar)
- `/list` channel browser with search + click-to-join
- Sidebar context menu on server rows — Connect / Disconnect / Remove Server
- User-list context menu — Whois / Query / Op / Deop / Voice / Devoice / Kick / Kick+Ban / Ignore
- Inline topic editing — click the topic bar → edit → Enter sends TOPIC
- MOTD display
- CTCP auto-responses with per-sender cooldown: VERSION, PING, TIME, CLIENTINFO, SOURCE
- Preferences window (`Cmd+,`) — General pane (show joins/parts, auto-join-on-invite, disk logging) + Notifications pane (highlight keywords)
- `/away` moon indicator on sidebar server row and console header

### Distribution
- GitHub Actions `release.yml` publishes a macOS `.dmg` on:
  - **Every push to `main`** → rolling `latest` prerelease (tag deleted + recreated at the new commit, so friends can bookmark `releases/tag/latest` for always-current).
  - **Tag push `v*`** → permanent, non-prerelease release at that tag for archival versions.
- Pipeline: `swift test` → `Scripts/build-app.sh release` with `VERSION` / `BUILD_NUMBER` injected into `Info.plist` → ad-hoc codesign (`codesign --sign -`) → `hdiutil` UDZO DMG → `softprops/action-gh-release@v2`.
- No paid Apple Developer cert. First launch needs right-click → Open (GateKeeper). Notarization is deliberately out of scope.
- `ci.yml` runs `swift build` + `swift test` on every push/PR using the runner's default Xcode.

## Phase 1 — complete

Phase 1 is done. The Preferences window now has seven panes:

- **General** — show joins/parts, auto-join-on-invite
- **Identity** — default nick / user name / real name for the Connect sheet
- **Appearance** — timestamp format (System / 12-hour / 24-hour), colorize nicknames toggle
- **Notifications** — highlight keywords list
- **Ignore** — per-server ignore-list table editor with add/remove
- **Logging** — disk-logging toggle, log-folder path, Reveal-in-Finder button
- **Servers** — list of saved servers with summary (host, TLS, nick, joined channels, perform count) and a Remove button

Opened via `Cmd+,` like any macOS settings window. Inline-editing the Servers list (host / port / SASL / perform) is the one thing not yet covered — that UI lands in a Phase 2 pass when there's demand.

## Phase 2 — Modern-native wins

These aren't in mIRC or are awkward in mIRC; they're where Brygga earns its "modern" label.

1. **IRCv3 typing indicator** for servers supporting the cap.
2. **Inline link previews** — image / OG-title fetch for URLs (opt-in, off by default).
3. **Find across all channels** (`Cmd+Shift+F`).
4. ~~**Detachable tabs** (`Cmd+Shift+D` pops a channel into its own window).~~ Shipped — each channel gets its own `WindowGroup` window reusing `TopicBar` / `MessageList` / `InputBar` over a shared `AppState`.
5. ~~**Favorites / pinned channels** in the sidebar.~~ Shipped — right-click → Pin to Favorites moves channels into a top sidebar section, `Cmd+1…9` jumps to the first nine pinned channels, pin state is persisted per server in `servers.json`.
6. ~~**SASL SCRAM-SHA-256** — stronger than PLAIN; Ergo supports it.~~ Shipped — auto-selected when the server advertises it in `CAP LS sasl=…`; verified against the RFC 7677 test vector.
7. **SASL EXTERNAL** — client-certificate auth for networks that allow it.

## Phase 3 — Polish

1. Emoji autocomplete (`:smile:` → 😄).
2. Markdown-style input (`*bold*` → `^B`) as an optional toggle.
3. Keyboard shortcuts — `Cmd+K` switch channel, `Cmd+J` quick join, `Cmd+[` / `Cmd+]` prev/next channel.
4. Status bar — connection state, lag, server ping.
5. Liquid Glass tuning on chat surface, sidebar, and inspector.

## Out of scope (deliberate)

Not building these, and not feeling bad about it:

- **DCC** — Send, Get, Chat, Fserve, DCC Server, Passive DCC, SOCKS5-passthrough. Superseded by HTTP upload services (imgur, catbox, 0x0.st, private file share).
- **mIRC scripting language** — aliases-as-code, popups-as-scripts, remote event handlers, `$identifiers`, `%vars`, timers, hash tables, binary-file manipulation, regex DSL, `/raw` scripting, `@window` custom dialogs. Massive security and implementation surface. If users need automation, they run a bot.
- **DLL / COM / DDE** — Windows-only, deprecated paradigms.
- **Event sounds** — `.wav`/`.mid`/`.mp3` playback, `/sound`, `/splay`, beep-on-event. macOS notification sound is enough.
- **Microsoft Agent TTS** — dead platform.
- **SOCKS4/5 / HTTP proxy** — not a 2026 problem. If users need a proxy, they use system-level networking.
- **Identd server** — no modern network requires it.
- **URL catcher window** — separate catch-all URL list. We detect inline instead.
- **Custom popup scripts** — mIRC's scriptable right-click menus. Plain `.contextMenu` is enough.
- **Toolbars / wallpaper / button themes / picture windows** — Liquid Glass native look only.
- **mIRC `.ini` file compatibility** — JSON and modern formats throughout.
- **Fileserve (Fserve)** — DCC-adjacent.

## Suggested next commit order

Phase 2 is up. Recommended path:

1. **IRCv3 typing indicator** (Phase 2 #1).
2. **Find across all channels** (Phase 2 #3) — `Cmd+Shift+F`.
3. **Inline link previews** (Phase 2 #2) — image / OG fetch, opt-in.
4. **SASL EXTERNAL** (Phase 2 #7) — client-cert auth.

Then Phase 3 polish: emoji autocomplete, markdown-style input, channel-switching shortcuts, status bar, Liquid Glass tuning.
