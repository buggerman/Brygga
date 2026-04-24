# Mac App Store listing draft

Copy/paste source for the App Store Connect submission. Companion to [`APP_STORE.md`](APP_STORE.md) (high-level readiness checklist) and [`PRIVACY.md`](PRIVACY.md) (the public privacy policy whose URL goes into App Store Connect).

Refresh the version-specific bits (description, screenshots) before each release.

## Identity fields

| Field | Value | Notes |
|---|---|---|
| Bundle Identifier | `org.buggerman.Brygga` | Matches `Info.plist` today. Decision pending whether to split MAS into `org.buggerman.Brygga.mas` — see [`APP_STORE.md`](APP_STORE.md). |
| Primary Language | English (U.S.) | |
| Primary Category | Social Networking | Matches `LSApplicationCategoryType=public.app-category.social-networking` already in `Info.plist`. |
| Secondary Category | Productivity | Optional. |
| Copyright | `© 2026 Brygga contributors` | Matches `LICENSE.md`. |
| SKU | `brygga-mas-1` | Free-form internal identifier; stable across versions. |

## Storefront strings

### App name (≤ 30 chars)

> Brygga

### Subtitle (≤ 30 chars)

> Native macOS IRC client

(23 chars, leaves room for refinement.)

### Promotional text (≤ 170 chars, editable without re-submission)

> Native macOS IRC client. TLS + SASL out of the box. IRCv3 capabilities, drag-select chat buffer, inline link previews, mIRC formatting. Apple Silicon, macOS 15+.

### Keywords (≤ 100 chars, comma-separated)

> IRC,chat,libera,OFTC,SASL,IRCv3,SwiftUI,messaging,client,native,terminal,server

(76 chars; expand within budget if a term performs poorly in App Store search.)

### Description (≤ 4000 chars)

```
Brygga is a native macOS IRC client built in Swift and SwiftUI for the modern Mac. Connect to Libera.Chat, OFTC, EFnet, Hackint, and any other IRC network — TLS, SASL EXTERNAL / SCRAM-SHA-256 / PLAIN, IRCv3 capabilities, and a fast cross-row-selectable chat buffer that feels like macOS, not like a 1990s Windows app.

KEY FEATURES

• TLS and SASL out of the box. PKCS#12 client certificates for EXTERNAL auth.
• IRCv3 capabilities: server-time, multi-prefix, userhost-in-names, chghost, account-tag, account-notify, away-notify, batch, chathistory, message-tags.
• Native NSTextView-backed chat buffer with full drag-select across rows, ⌘A, ⌘C, and Find.
• Inline link previews — site name, title, description, thumbnail. Opt-out.
• mIRC control-code rendering: bold, italic, underline, strikethrough, reverse, 16-color palette.
• Stable per-nick colors hashed from the nickname.
• Collapsed join/leave runs with per-channel override.
• Tab-completion for nicknames, emoji shortcodes, and slash commands.
• Markdown-style input that rewrites to mIRC codes on send.
• Quick switcher (⌘K), find-in-buffer (⌘F), find-across-channels (⌘⇧F).
• Detachable channel windows, pinned favorites, command history.
• Local scrollback and plain-text logs survive relaunches.
• Highlight keywords, Dock badge, macOS notifications.
• /list channel browser, /whois, /ignore, /notify, perform commands.

DELIBERATELY OUT OF SCOPE

DCC file transfer, mIRC scripting language, custom popup scripts, event sounds, identd server, SOCKS/HTTP proxy. The full out-of-scope list and rationale lives in the project's PARITY.md on GitHub.

PRIVACY

Brygga collects no data. All your traffic goes directly to the IRC networks you choose. Local config, scrollback, and logs stay on your Mac. The full privacy policy is linked from this page.

REQUIREMENTS

• macOS 15 Sequoia or later.
• Apple Silicon. (Source-compatible on Intel; build your own from the project's GitHub.)
```

## URLs

| Field | URL |
|---|---|
| Privacy Policy URL | <https://github.com/buggerman/Brygga/blob/main/docs/PRIVACY.md> |
| Support URL | <https://github.com/buggerman/Brygga/issues> |
| Marketing URL (optional) | <https://github.com/buggerman/Brygga> |

## Age rating answers

Apple's age-rating questionnaire is for what the **app itself** ships with. Brygga ships with no built-in content — every visible message originates from third-party IRC networks the user chooses to connect to. The user-generated-content question is the one that drives the rating.

| Question | Answer | Note |
|---|---|---|
| Cartoon or Fantasy Violence | None | Text app, no rendered violence. |
| Realistic Violence | None | |
| Prolonged Graphic or Sadistic Realistic Violence | None | |
| Sexual Content or Nudity | None | App ships with none. UGC handled below. |
| Profanity or Crude Humor | None | App ships with none. UGC handled below. |
| Mature/Suggestive Themes | None | |
| Horror/Fear Themes | None | |
| Medical/Treatment Information | None | |
| Alcohol, Tobacco, or Drug Use or References | None | |
| Simulated Gambling | None | |
| Contests | None | |
| Unrestricted Web Access | **Yes** | Link previews fetch arbitrary URLs that appear in chat; `og:image` thumbnails render in-app. URLs the user clicks open in the system default browser, but the in-app thumbnail is sufficient to answer Yes here. |
| Gambling and Contests | None | |
| User-generated Content | **Yes — Frequent/Intense possible** | The whole point of the app is third-party-network chat. IRC channels can range from family-friendly to adult-only depending on the network and channel. Brygga itself has `/ignore` for blocking and a Report-user affordance routed at the project's GitHub issue tracker (Guideline 1.2). |

Expected age rating: **17+** (driven by Unrestricted Web Access + UGC). Consistent with other IRC / Matrix clients on the store.

## Screenshots

Mac App Store accepts up to 10 screenshots, default Light Mode + optional Dark Mode set. **Required dimensions: 1280×800 minimum, 2880×1800 retina recommended, 16:10 aspect.**

Recommended set (capture on a real Apple Silicon Mac running macOS 15 or 26):

1. **Hero shot** — main window, busy channel with link preview card visible, full sidebar on the left with at least three servers and several channels. The screenshot already in `docs/screenshot.png` is close to this — re-capture at 2880×1800 for the App Store.
2. **Connect sheet** — Known Networks picker open, showing Libera.Chat / OFTC / Hackint etc.
3. **Preferences → General** — toggle list visible (collapse joins/parts, link previews, markdown input, typing indicator).
4. **Quick switcher (⌘K)** — fuzzy search overlay on top of an active channel.
5. **/list channel browser** — channel list with member counts and topics.
6. **Detached channel window** — `⌘⇧D` view, demonstrating the multi-window feature.
7. **About panel** — surfacing the BSD-3-Clause notice (showcases licensing transparency for reviewers).
8. *(Optional)* Dark Mode hero shot.

Naming convention for the upload bundle: `1-hero.png`, `2-connect.png`, `3-prefs.png`, etc. Drop into App Store Connect in order.

## App Review Information

| Field | Value |
|---|---|
| Sign-In Required | No |
| Demo Account | N/A |
| Notes | Brygga is an IRC client. To exercise the full feature set, the reviewer can connect to Libera.Chat (`irc.libera.chat:6697`, TLS, no SASL needed for a guest) and join `#brygga`. The Report-User affordance is reachable via right-click on any user in the user list. |
| Contact First Name / Last Name | (fill in on submission day) |
| Contact Phone Number | (fill in on submission day) |
| Contact Email | (fill in on submission day) |

## Build & version fields

| Field | Source |
|---|---|
| Version | `CFBundleShortVersionString` from `Info.plist` (set by `VERSION` env var in `Scripts/build-app.sh`). E.g. `0.1.3`. |
| Build | `CFBundleVersion` (set by `BUILD_NUMBER` env var). Increment monotonically across MAS submissions even if the version stays the same. |
| Minimum OS | macOS 15.0 (`LSMinimumSystemVersion=15.0`). |
| Encryption Export Compliance | `ITSAppUsesNonExemptEncryption=false` — already in `Info.plist`, so App Store Connect skips the question. |

## What's New (release notes, ≤ 4000 chars)

Mirror the highlights from the corresponding annotated git tag (`git tag -n99 v<version>`). Trim to user-relevant changes; skip plumbing/refactor commits.
