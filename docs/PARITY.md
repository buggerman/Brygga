# mIRC Feature Parity Plan

Brygga aims for **feature parity with mIRC** for everything a daily-driver IRC user expects, while being deliberately modern-native (macOS 26, SwiftUI, Liquid Glass) and excluding obsolete or Windows-specific features. This document is the reference for what's in scope, out of scope, and in what order.

## Already shipped

Core daily-driver capability is already in place:

- TLS connect on 6697 with modern TLS via `NWConnection`
- SASL PLAIN authentication during connection
- Auto-reconnect with exponential backoff
- User-initiated disconnect that stays disconnected
- Clean `QUIT` on app termination
- Per-server persistence (host, port, TLS, nick, SASL creds, auto-join list, open queries)
- Scrollback persistence as JSONL, rehydrated on launch
- Nick-mention highlight + Dock badge + macOS notifications
- Tab nick completion with cycling
- Up/down input history
- `/list` channel browser with search + click-to-join
- MOTD
- `/quit`, `/disconnect`, `/join`, `/part`, `/nick`, `/me`, `/msg`, `/query`, `/topic`
- Sidebar context menu — Connect / Disconnect / Remove Server
- Two-column `NavigationSplitView` with user-list inspector that auto-hides for PMs and server console

## Phase 1 — Essential parity

Goal: anything a mIRC daily-driver expects, minus DCC.

1. **IRCv3 capability negotiation beyond SASL** — `server-time`, `echo-message`, `account-tag`, `multi-prefix`, `userhost-in-names`, `chghost`, `account-notify`, `away-notify`, `invite-notify`, `batch`. Foundational; downstream polish depends on these.
2. **mIRC color-code rendering** — parse `^B` `^U` `^I` `^R` `^O` `^K` with the 16-color palette plus the 16–98 extended palette on message display. Input-side formatting can come later.
3. **URL detection + clickable hyperlinks** in rendered messages. Open in default browser.
4. **Nick colors** — stable hash → color, applied to sender in message rows and in the user list.
5. **`/whois` formatted output** — parse numerics 311/312/317/319/318/330 into a readable block or small overlay.
6. **`/away` command** with away indicator on your own server row; cancel-away-on-message option.
7. **`/ignore <nick>`** — per-server persisted ignore list; suppresses inbound from matching hostmasks.
8. **`/invite`** + auto-join-on-invite preference.
9. **Inline topic editing** — click the topic bar → edit in place → `TOPIC` on enter.
10. **User-list context menu** — right-click a nick → Whois / Query / Op / Deop / Voice / Kick / Kick+Ban / Ignore.
11. **CTCP auto-responses** — VERSION (reports `Brygga <version> macOS <version>`), PING (echo timestamp), TIME (ISO8601).
12. **Outbound flood protection** — token-bucket rate limit so a big paste won't trigger a server-side `KILL`.
13. **Long-message splitting** — PRIVMSG chunked to respect the 512-byte IRC line limit.
14. **Line marker** — horizontal bar where you last read a channel; visible when returning.
15. **Find in buffer** (`Cmd+F`) — scoped search across the current channel's scrollback.
16. **Highlight keywords** — user-configurable list beyond own nick; each match triggers highlight + notification.
17. **Preferences window** — first version with panes for Identity, Appearance, Notifications, Ignore, Highlight, Logging.
18. **Disk logging** — opt-in, plain-text `~/Documents/Brygga Logs/<network>/<channel>.log`; distinct from JSONL scrollback, human-readable.
19. **Notify / buddy list** — list of nicks to watch; uses the `WATCH` extension where supported, falls back to periodic `ISON`/WHOIS polling.
20. **Per-server `perform`** — list of commands to run automatically after 001 welcome (`MODE +x`, services login, etc.).

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

1. IRCv3 CAP expansion (`server-time` + `multi-prefix` + `userhost-in-names` + `echo-message` + `batch`). 80% of the modern-network polish.
2. mIRC color code renderer.
3. URL hyperlink detection.
4. Nick colors.
5. `/whois` formatted UI.
6. CTCP auto-responses.
7. `/ignore` list.
8. Preferences window (first cut).

Then the rest of Phase 1 in whichever order the friend group starts asking for.
