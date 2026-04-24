# Privacy

Brygga is an IRC client. It connects to IRC servers you choose and exchanges messages with those servers and the people on them. Beyond that, it collects nothing.

## What Brygga sends, and where

- Your typed messages, IRC commands, nickname, user name, real name, and SASL account go to the IRC servers you connect to. Those are third-party services governed by their own privacy policies; Brygga does not see, intercept, or relay any of that traffic to its developer or to any other party.
- When the **Fetch link previews** preference is on (default), Brygga makes HTTPS requests to URLs that appear in chat to retrieve `og:title`, `og:description`, and a thumbnail. This discloses your IP address to the host of each URL. Disable the preference in **Preferences → General** to stop these requests; existing cached previews remain visible until app restart.
- When you click a URL in chat, the system opens it in your default browser. Brygga does not handle the click itself.

## What Brygga stores, and where

All of it is local to your Mac, in your home directory. None of it is uploaded anywhere by Brygga.

- **Server configuration** at `~/Library/Application Support/Brygga/servers.json`. Plaintext JSON containing per-server: name, host, port, TLS flag, nickname, SASL account name, auto-join channel list, open private-message tabs, ignore list, notify (buddy) list, perform-on-connect commands, pinned-channels list, optional client-certificate file path, and per-channel collapse-presence-runs overrides.
- **Secrets** (SASL passwords, client-certificate passphrases) live in the macOS Keychain under service `org.buggerman.Brygga`, account `<server-id>.<field>`. They are never written to `servers.json`.
- **Scrollback** at `~/Library/Application Support/Brygga/scrollback/<server-id>/<channel-or-target>.log`. Up to 500 most-recent messages per channel, JSONL.
- **Plain-text disk logs** (opt-out, default on) at `~/Library/Logs/Brygga/<network>/<channel>.log`. Disable in **Preferences → Logging**.
- **Preferences** (timestamp format, highlight keywords, etc.) in `UserDefaults` — `~/Library/Preferences/org.buggerman.Brygga.plist`.

The Mac App Store build runs in the Apple App Sandbox. The same paths are redirected by the OS into `~/Library/Containers/org.buggerman.Brygga/Data/Library/...` — same bytes, different location, isolated from other apps.

## What Brygga does not do

- No analytics. No telemetry. No crash reporting back to the developer.
- No third-party SDKs. No tracking. No advertising.
- No accounts on Brygga-developer-operated servers — there are no developer-operated servers.
- No remote configuration. No automatic data sharing with anyone other than the IRC servers and link-preview hosts that *you* choose to interact with.
- No microphone, camera, contacts, calendar, photos, location, or notification access beyond local highlight banners.

## Children's privacy

Brygga is not directed at children under 13 and does not knowingly collect personal information from anyone. The IRC networks Brygga connects to are public services with their own age policies.

## Updates

When this policy changes the change will be visible in the file's Git history at <https://github.com/buggerman/Brygga/blob/main/docs/PRIVACY.md>. The "Last updated" line below reflects the most recent edit.

---

Last updated: 2026-04-25
