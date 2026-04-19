# mIRC Feature Parity Plan

Brygga aims for **feature parity with mIRC** for everything a daily-driver IRC user expects, while being deliberately modern-native (macOS 26, SwiftUI, Liquid Glass) and excluding obsolete or Windows-specific features. This document is the reference for what's in scope, out of scope, and in what order.

## Already shipped

Everything a mIRC daily-driver expects, minus DCC and mIRC scripting.

### Connection and protocol

- TLS connect on 6697 via `NWConnection`
- SASL authentication — **EXTERNAL** preferred when a PKCS#12 client certificate is configured and the server advertises it (TLS client auth via `sec_protocol_options_set_local_identity`); otherwise **SCRAM-SHA-256** when advertised (RFC 7677 exchange with PBKDF2 via CommonCrypto + HMAC/SHA-256 via CryptoKit); falls back to **PLAIN**
- IRCv3 CAP negotiation: `sasl`, `server-time`, `multi-prefix`, `userhost-in-names`, `chghost`, `account-tag`, `account-notify`, `away-notify`, `invite-notify`, `batch`, `chathistory` / `draft/chathistory`, `message-tags`
- `server-time` tag → accurate message timestamps across reconnects
- `userhost-in-names` → fills `User.username` / `hostname` on NAMES
- `chghost` → live host updates after services login
- `account-notify` / `account-tag` → tracks services-auth state on users
- `away-notify` → `User.isAway` + `awayMessage` updates without WHOIS
- `chathistory` → on own-JOIN, requests `CHATHISTORY LATEST <channel> * 100` to fill missed backlog; de-duped per session, reset on each 001 welcome
- `message-tags` → enables the IRCv3 typing indicator (`+typing` client tag via TAGMSG)
- Clean `QUIT` on app termination; auto-reconnect with exponential backoff; user-initiated disconnect sticks
- Outbound token-bucket flood protection (1200-byte burst, 300 bytes/sec) with PONG bypass
- Long-message chunking: PRIVMSG / ACTION split at space boundaries to respect the 512-byte IRC line limit; never splits mid-UTF-8

### Commands

- `/join`, `/part`, `/nick`, `/me`, `/msg`, `/query`, `/topic`, `/quit`, `/disconnect`, `/list`
- `/whois` with formatted 311/312/313/317/318/319/330/335/378/379/671 numeric output
- `/away [msg]` + 305/306 handling
- `/invite <nick> [#channel]` with auto-join-on-invite preference
- `/ignore <nick|mask>` + `/unignore` + list
- `/notify <nick>` buddy list with 60s ISON polling
- `/perform` — per-server raw-line command list fired after 001
- Slash fallthrough sends raw IRC lines

### Windowing and navigation

- Two-column `NavigationSplitView` with auto-hiding user-list inspector (hides for PMs and the server console)
- **Detachable tabs** — `Cmd+Shift+D` pops the selected channel into its own `WindowGroup` window, sharing `AppState`
- **Favorites / pinned channels** — right-click → *Pin to Favorites* puts channels in a top sidebar section; `Cmd+1…9` jumps to the first nine pinned channels; persisted per server
- **Quick switcher** — `Cmd+K` opens a filterable list of every channel/PM across servers; Enter jumps, Escape cancels
- **Quick join** — `Cmd+J` opens a small sheet (server picker when multiple are connected) that sends JOIN
- **Previous / next channel** — `Cmd+[` / `Cmd+]` cycle through the ordered sidebar list, wrapping at the ends
- **Find in buffer** — `Cmd+F` filters the current channel with match count
- **Find across all channels** — `Cmd+Shift+F` opens a modal sheet searching every server/channel/query (content + senders), capped at 300 most-recent hits, click to navigate
- Sidebar context menu on server rows — Connect / Disconnect / Remove Server
- User-list context menu — Whois / Query / Op / Deop / Voice / Devoice / Kick / Kick+Ban / Ignore
- Inline topic editing — click the topic bar → edit → Enter sends TOPIC
- `/list` channel browser with search + click-to-join

### Chat rendering and input

- Stable per-nick colors (FNV-1a hashed into a 16-color palette)
- mIRC control-code rendering: `^B` bold, `^I` italic, `^U` underline, `^S` strikethrough, `^V` reverse, `^O` reset, `^K<fg>[,<bg>]` with the mIRC 16-color palette
- URL and email detection — clickable, underlined, accent-colored
- **Inline link previews** — `LinkPreviewStore` fetches `og:title` / `og:description` / `og:image`, Twitter card meta, and raw `image/*` thumbnails (capped at 2 MB / 10 s, http + https only); default on, privacy-noted in Preferences
- **Typing indicator** — IRCv3 `+typing` TAGMSG, throttled (active every 3 s, done on submit / empty draft), row above the InputBar auto-expires via `TimelineView`
- **Emoji autocomplete** — ~300 curated Slack/Discord-style shortcodes; `:word:` auto-replaces to the glyph, Tab cycles through `:pref` matches
- **Markdown-style input** — `*bold*` / `_italic_` / `~strike~` rewritten to mIRC control codes on send; toggle in Preferences → General (default on)
- Nick-mention highlight with accent gutter + Dock badge + macOS notifications
- Custom highlight keywords (configurable in Preferences)
- Line marker — horizontal divider showing where you last read a channel when returning
- Tab nick completion with cycling
- Up / down input history (per-InputBar)
- CTCP auto-responses with per-sender cooldown: VERSION, PING, TIME, CLIENTINFO, SOURCE
- MOTD display
- `/away` moon indicator on sidebar server row and console header
- **Status bar** — footer row showing the focused server's connection state (colored dot), nickname, live lag (from a 30 s client-initiated PING → PONG roundtrip), and total channel count

### Persistence and storage

- Per-server + per-channel config in `~/Library/Application Support/Brygga/servers.json`: host, port, TLS, nick, SASL creds, client-cert path + passphrase, auto-join list, open queries, ignore list, notify list, perform commands, pinned channels
- Scrollback persistence as JSONL, rehydrated on launch
- Opt-in plain-text disk logging under `~/Documents/Brygga Logs/<network>/<channel>.log`

### Preferences

Seven panes, opened via `Cmd+,`:

- **General** — show joins/parts, auto-join-on-invite, fetch link previews
- **Identity** — default nick / user name / real name for the Connect sheet
- **Appearance** — timestamp format (System / 12-hour / 24-hour), colorize nicknames toggle
- **Notifications** — highlight keywords list
- **Ignore** — per-server ignore-list table editor with add/remove
- **Logging** — disk-logging toggle, log-folder path, Reveal-in-Finder button
- **Servers** — list of saved servers with summary (host, TLS, nick, joined channels, perform count) and a Remove button

Inline-editing the Servers list (host / port / SASL / perform) is the one thing not yet covered — that UI lands when there's demand.

### Distribution

- `release.yml` publishes a macOS `.dmg` on:
  - **Every push to `main`** → rolling `latest` prerelease (tag deleted + recreated at the new commit, so friends can bookmark `releases/tag/latest` for always-current).
  - **Tag push `v*`** → permanent, non-prerelease release at that tag for archival versions.
- Pipeline: `swift test` → `Scripts/build-app.sh release` with `VERSION` / `BUILD_NUMBER` injected into `Info.plist` → ad-hoc `codesign --sign -` → `hdiutil` UDZO DMG → `softprops/action-gh-release@v2`.
- No paid Apple Developer cert — first launch needs right-click → Open (GateKeeper). Notarization is deliberately out of scope.
- `ci.yml` runs `swift build` + `swift test` on every push / PR using the runner's default Xcode.

## Coming up

Polish items still on the list, in the order we'd do them next:

1. **Liquid Glass tuning** on chat surface, sidebar, and inspector.

## Out of scope (deliberate)

Not building these, and not feeling bad about it:

- **DCC** — Send, Get, Chat, Fserve, DCC Server, Passive DCC, SOCKS5-passthrough. Superseded by HTTP upload services (imgur, catbox, 0x0.st, private file share).
- **mIRC scripting language** — aliases-as-code, popups-as-scripts, remote event handlers, `$identifiers`, `%vars`, timers, hash tables, binary-file manipulation, regex DSL, `/raw` scripting, `@window` custom dialogs. Massive security and implementation surface. If users need automation, they run a bot.
- **DLL / COM / DDE** — Windows-only, deprecated paradigms.
- **Event sounds** — `.wav` / `.mid` / `.mp3` playback, `/sound`, `/splay`, beep-on-event. macOS notification sound is enough.
- **Microsoft Agent TTS** — dead platform.
- **SOCKS4/5 / HTTP proxy** — not a 2026 problem. If users need a proxy, they use system-level networking.
- **Identd server** — no modern network requires it.
- **URL catcher window** — separate catch-all URL list. We detect inline instead.
- **Custom popup scripts** — mIRC's scriptable right-click menus. Plain `.contextMenu` is enough.
- **Toolbars / wallpaper / button themes / picture windows** — Liquid Glass native look only.
- **mIRC `.ini` file compatibility** — JSON and modern formats throughout.
- **Fileserve (Fserve)** — DCC-adjacent.
