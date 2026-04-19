# mIRC Feature Parity Plan

Brygga aims for **feature parity with mIRC** for everything a daily-driver IRC user expects, while being deliberately modern-native (macOS 26, SwiftUI, Liquid Glass) and excluding obsolete or Windows-specific features. This document is the reference for what's in scope, out of scope, and in what order.

## Already shipped

Phase 1 is effectively complete — everything a mIRC daily-driver expects (minus DCC and scripting) is in place.

### Connection and identity
- TLS connect on 6697 via `NWConnection`
- SASL PLAIN authentication during connection registration
- IRCv3 CAP negotiation: `sasl`, `server-time`, `multi-prefix`, `userhost-in-names`, `chghost`, `account-tag`, `account-notify`, `away-notify`, `invite-notify`, `batch`
- `server-time` tag used for message timestamps (accurate scrollback across reconnects)
- `userhost-in-names` → populates `User.username` / `hostname` on NAMES
- `chghost` → live host updates after services login
- `account-notify` / `account-tag` → tracks services-auth state on users
- `away-notify` → `User.isAway` + `awayMessage` updates without WHOIS
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

## Phase 1 — remaining

The only Phase 1 item still open is Preferences-window breadth. Functionality exists; UI coverage lags.

1. **Preferences window expansion** — currently has General + Notifications. Add:
   - **Identity** — default nick / user / real name used by the Connect sheet
   - **Appearance** — timestamp format (12h/24h), line spacing, nick-colors on/off toggle
   - **Ignore** — per-server ignore-list table editor (list mutation today requires `/ignore`)
   - **Logging** — currently a section inside General; promote to its own pane with log folder picker and a "reveal in Finder" button
   - **Servers** — edit saved servers (host, port, SASL creds, perform list, auto-join) without removing + re-adding

## Phase 2 — Modern-native wins

These aren't in mIRC or are awkward in mIRC; they're where Brygga earns its "modern" label.

1. **IRCv3 `chathistory`** — request server-side scrollback on channel open. Huge UX upgrade over "you weren't there, so you missed it".
2. **IRCv3 typing indicator** for servers supporting the cap.
3. **Inline link previews** — image / OG-title fetch for URLs (opt-in, off by default).
4. **Find across all channels** (`Cmd+Shift+F`).
5. **Detachable tabs** (`Cmd+Shift+D` pops a channel into its own window).
6. **Favorites / pinned channels** in the sidebar.
7. **SASL SCRAM-SHA-256** — stronger than PLAIN; Ergo supports it.
8. **SASL EXTERNAL** — client-certificate auth for networks that allow it.

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

Phase 1 closes with a proper Preferences expansion; Phase 2 opens with chathistory.

1. **Preferences expansion** — Identity, Appearance, per-server Ignore editor, Logging pane, Servers editor.
2. **IRCv3 `chathistory`** (Phase 2 #1) — fills the "you missed it" gap and benefits from the CAP plumbing already in place.
3. **Detachable tabs** (Phase 2 #5) — `Cmd+Shift+D` pops the selected channel into its own window.
4. **Favorites / pinned channels** (Phase 2 #6) — sidebar ordering + keyboard-first navigation.
5. **SASL SCRAM-SHA-256** (Phase 2 #7) — add after chathistory, before EXTERNAL.

Then the rest of Phase 2 and Phase 3 in whichever order the friend group starts asking for.
