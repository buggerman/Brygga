# Mac App Store readiness

What needs to be in place before Brygga can submit, what's done, and what's still gated by paying the $99/yr Apple Developer Program fee.

## Status

| Area | State | Where |
|---|---|---|
| App Sandbox entitlements | ✅ Done | `Brygga.entitlements` |
| Sandboxed build path | ✅ Done | `./Scripts/build-app.sh release --sandboxed` |
| Encryption-export declaration | ✅ Done | `ITSAppUsesNonExemptEncryption=false` in Info.plist |
| App Store category | ✅ Done | `LSApplicationCategoryType=public.app-category.social-networking` in Info.plist |
| About / Acknowledgements panel (BSD-3-Clause notice) | ✅ Done | `Sources/Brygga/Acknowledgements.swift` + `CommandGroup(replacing: .appInfo)` in `BryggaApp.swift` |
| Report-user affordance (Guideline 1.2) | ✅ Done | UserListView right-click → "Report User…" → `ReportLink.openUserReport` → `.github/ISSUE_TEMPLATE/user-report.yml` |
| App Privacy disclosure draft | ⏳ Pending | follow-up PR |
| App Store listing copy + age rating | ⏳ Pending | follow-up PR |
| Apple Distribution certificate | 🔒 Gated by $99/yr | submission day |
| Mac App Store provisioning profile | 🔒 Gated by $99/yr | submission day |
| App Store Connect listing | 🔒 Gated by $99/yr | submission day |
| Final review submission | 🔒 Gated by $99/yr | submission day |

## How to build the sandboxed variant locally

```sh
./Scripts/build-app.sh release --sandboxed
open build/Brygga.app
```

The bundle is ad-hoc signed with the entitlements declared in `Brygga.entitlements` applied. macOS recognises the App Sandbox flag and creates `~/Library/Containers/org.buggerman.Brygga/Data/Library/...` as the app's jail on first launch — anything Brygga reads or writes under `~/Library/Application Support/Brygga/`, `~/Library/Logs/Brygga/`, or scrollback paths gets transparently redirected into that container.

When the time comes to actually ship to MAS, replace the ad-hoc `--sign -` in `Scripts/build-app.sh` with a real Apple Distribution identity (`--sign "3rd Party Mac Developer Application: <Team Name>"`), add a provisioning profile at `build/Brygga.app/Contents/embedded.provisionprofile`, and run `productbuild --component build/Brygga.app /Applications --sign "3rd Party Mac Developer Installer: <Team Name>" Brygga.pkg` instead of `hdiutil`. That flow lands later — it's the part that needs the paid program.

## Distribution channels — coexistence

The DMG / Homebrew path stays unsandboxed and continues to work for users who install outside the App Store. Their existing data under `~/Library/Application Support/Brygga/...` is untouched.

The MAS build runs sandboxed and lives in its own container. Existing data is **not** visible across the boundary — sandbox containers are deliberately isolated. Users moving from DMG to MAS won't see their saved servers, scrollback, or ignore lists. Acceptable for the first MAS release; a one-time migration helper can land later.

**Bundle identifier.** Both channels currently share `org.buggerman.Brygga`. Decision pending: keep one ID (simpler, but LaunchServices may get confused if a user has both installed) or split (`org.buggerman.Brygga` for DMG, `org.buggerman.Brygga.mas` for MAS). Default to splitting on submission day if it ever causes problems.

## Entitlements rationale

The minimum set Brygga actually needs — declared in `Brygga.entitlements`:

| Key | Why |
|---|---|
| `com.apple.security.app-sandbox` | Master switch. Required for any MAS submission. |
| `com.apple.security.network.client` | Outbound TCP / TLS for `IRCConnection` (Network.framework) and `LinkPreviewStore` / image fetches (URLSession). |
| `com.apple.security.files.user-selected.read-only` | Read access to files the user picks via `NSOpenPanel` — used by ConnectSheet's "Choose…" button for the PKCS#12 client certificate. Read-only is the minimum needed: the bytes are copied once at connect time, never written back. |

Things deliberately **not** included:

- `com.apple.security.network.server` — we never accept inbound connections.
- `com.apple.security.files.downloads.*` / `documents.*` — Brygga doesn't touch those locations.
- `keychain-access-groups` — Brygga's `KeychainStore` uses generic-password class with service+account keys, which works in the sandbox's default per-app keychain partition without needing an explicit access group. Add one if a future feature requires sharing keychain items across apps.
- `com.apple.security.device.audio-input`, `device.camera`, `device.bluetooth`, etc. — not used.
- `com.apple.security.automation.apple-events` — not used.

The principle of least privilege is mostly enforced by App Review: the simpler the entitlement set, the smoother review goes.

## Pre-submission checklist (run on submission day)

When the user pays the $99 and is ready to submit:

1. Bump `LSApplicationCategoryType` if you want a different category (Productivity? Social Networking? Currently `public.app-category.social-networking`).
2. Replace ad-hoc signing with the Apple Distribution identity in `Scripts/build-app.sh` (or branch a parallel `Scripts/build-mas.sh`).
3. Acquire a Mac App Store provisioning profile from App Store Connect, drop it at `build/Brygga.app/Contents/embedded.provisionprofile` before signing.
4. Use `productbuild` to wrap the `.app` into a `.pkg` for upload.
5. Upload via `xcrun altool` or Transporter.app.
6. Fill in App Store Connect listing using the draft from PR 4.
7. Submit for review. Expect 1.2 (UGC) feedback; have the report-user affordance and the BSD-3-Clause notice ready in case the reviewer asks.
