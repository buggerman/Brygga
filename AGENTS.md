# AGENTS.md

Rules for AI coding agents working in this repo. Read before editing.

## Mission

Brygga is a native macOS IRC client written in pure Swift + SwiftUI. The goal is **feature parity with mIRC, reimagined for macOS** — see [`docs/PARITY.md`](docs/PARITY.md) for what's in scope, out of scope, and why.

## Platform targets

- **Deployment floor:** macOS 15 Sequoia. Official DMGs are Apple Silicon (arm64) only; Intel (x86_64) is source-compatible and users may build their own, but it's untested in CI.
- **Build toolchain:** Xcode 26 / Swift 6.2, strict concurrency on.
- **Policy:** use the newest API that solves the problem; do **not** add `@available` guards. If a new feature needs a newer OS, bump the deployment floor in `Package.swift` + `Scripts/build-app.sh` (`LSMinimumSystemVersion`) in one edit. Today's floor is macOS 15 because `.containerBackground(_:for: .window)` is 15+.
- **Design direction:** Liquid Glass on macOS 26; everything in use falls back gracefully on 15 via standard materials.
- No prebuilt Intel binaries. No pre-Sequoia fallbacks.

## Layout

- `Sources/BryggaCore/` — library target. IRC protocol, `IRCConnection` (actor) + `IRCSession` (`@MainActor`), `@Observable` models (`Server`, `Channel`, `User`, `Message`), persistence (`ServerStore`, `ScrollbackStore`, `DiskLogger`), `LinkPreviewStore`, `KnownNetworks`, `EmojiShortcodes`, `MarkdownInputTransform`, `PreferencesKeys`, `SCRAMSHA256`, `ClientIdentity`.
- `Sources/Brygga/` — executable target. `@main` entry point, `BryggaApp` scene graph, all SwiftUI views, `AppDelegate` adapter.
- `Tests/` — XCTest. **Only** `@testable import BryggaCore`. Importing the `Brygga` target breaks linkage because of `@main`. There is no UI-test target.
- `Resources/` — icon source art, generated `AppIcon.iconset/`, `AppIcon.icns`. Don't hand-regenerate unless the source art changes.
- `Scripts/build-app.sh` — wraps the SPM-built binary into `build/Brygga.app` with a proper `Info.plist`. A raw `swift run Brygga` does **not** activate as a GUI app — always use the script or the bundle.
- `.github/workflows/ci.yml` — build + test on every push/PR (macOS 26 runner, Xcode 26).
- `.github/workflows/release.yml` — rolling `nightly` prerelease on every push to `main`; stable release on `v*` tag push.

## Build & test

```sh
swift build                 # library + executable
swift test                  # all tests must pass before commit
./Scripts/build-app.sh      # produces build/Brygga.app
open build/Brygga.app       # launch with a Dock icon
./build/Brygga.app/Contents/MacOS/Brygga   # run inline to see stderr
```

## Architecture invariants (do not violate)

- **`IRCConnection`** is an `actor`. It owns the `NWConnection` and is the only place network I/O runs. Config properties (`host`, `port`, `nickname`, `saslAccount`, `clientCertificatePath`, …) are `nonisolated let`.
- **`IRCSession`** is `@MainActor`. It consumes `connection.messages` / `connection.stateChanges` (both `AsyncStream`) in `Task { @MainActor … for await … }` loops spawned from `start()`, and mutates `@Observable` models that SwiftUI renders.
- **`AppState`** is the single `@MainActor @Observable` root. It owns `servers: [Server]` and `sessions: [String: IRCSession]` keyed by `server.id`.
- All model mutation must happen on the main actor so SwiftUI observation fires on the right thread.
- Do **not** introduce Objective-C, ObjC bridging, C interop, or `@objc` on new APIs. Pure Swift by design.

## Persistence

Config file: `~/Library/Application Support/Brygga/servers.json`, owned by `ServerStore`.

`ServerConfig` fields (all optional on decode via `decodeIfPresent` for forward/backward compatibility):

```
name, host, port, useTLS, nickname,
saslAccount, saslPassword,
clientCertificatePath, clientCertificatePassphrase,
autoJoinChannels, openQueries,
ignoreList, notifyList, performCommands, pinnedChannels
```

- `AppState.persist()` writes on any change that affects any of the above: `addServer`, `removeServer`, own JOIN/PART/KICK/NICK, query-tab creation (incoming PM or outgoing `/msg` / `/query`), pin toggle, ignore/notify/perform edits.
- Writes are suppressed while `isRestoring == true` during `AppState.restoreFromStore()` to avoid torn snapshots on launch.

Other on-disk state:
- **Scrollback JSONL** — `~/Library/Application Support/Brygga/scrollback/<serverId>/<sanitizedTarget>.log`. Owned by `ScrollbackStore` actor. Written on every `record(_:in:)` / `recordServer(_:)`; read back at launch by `AppState.restoreFromStore()`.
- **Plain-text disk logs** — opt-out, `~/Library/Logs/Brygga/<network>/<channel>.log` (canonical macOS app-log path). Owned by `DiskLogger` actor, which runs a one-time migration from the pre-0.1.1 `~/Documents/Brygga Logs/` on first construction. Gated by `PreferencesKeys.diskLoggingEnabled` (default `true` — read via `UserDefaults.standard.object(forKey:) as? Bool ?? true`).
- **Preferences** — `UserDefaults` under keys defined in `PreferencesKeys`.

### Scrollback-restore invariant (agents keep tripping on this)

`AppState.restoreFromStore()` must pre-create `Channel` objects for **both** `autoJoinChannels` and `openQueries` before the async rehydrate `Task` runs. Without the auto-join pre-creation, the JOIN reply builds a fresh empty Channel and the user sees no history on relaunch. The JOIN handler is idempotent — it reuses any existing `Channel(name:)` — so pre-creation is safe.

## SwiftUI gotchas

- Use `@Bindable var appState = appState` inside a view body when you need `$`-bindings to an `@Environment`-injected `@Observable`.
- `@Observable` requires *reading* a property inside the view body for observation to register. Binding alone doesn't suffice.
- `NavigationSplitViewVisibility.doubleColumn` in a 3-column split view hides the **sidebar**, not the detail. For a trailing pane, either use a 2-column split with an inline `HStack { detail; userList }`, or `.inspector(isPresented:)`.
- `.containerBackground(_:for: .window)` is macOS 15+.
- `.glassEffect()` / `GlassEffectContainer` are macOS 26+. We don't use them yet; if you do, bump the deployment floor.
- SPM does **not** auto-define `DEBUG`. `#if DEBUG` blocks are compiled out in both `swift build` and `swift build -c release`. Use runtime flags or always-on diagnostics.
- `@State` may be preserved across what looks like view re-creation when SwiftUI reuses identity. If you want clean state on selection change, add `.id(<something-that-changes>)` to the view.
- `UNUserNotificationCenter.current()` throws when `Bundle.main.bundleURL.pathExtension != "app"` (i.e. running in xctest). Guard before calling.

## IRC etiquette (do not ignore)

- Do **not** hammer public IRC networks with reconnect loops during development. Libera will K-line (network-wide ban) after a few rapid reconnects and bans last ~24h.
- For iteration, run a local ircd: `brew install ergo && ergo mkcerts && ergo run`, then point Brygga at `127.0.0.1:6697`.
- IRC protocol parsing is tested offline: feed a raw line through `IRCLineParser.parse` then into `IRCSession.handle`. Tests must not open sockets.
- Clean shutdown is load-bearing: `BryggaAppDelegate.applicationShouldTerminate` returns `.terminateLater`, calls `appState.disconnectAll(quitMessage: "Brygga")`, then `NSApp.reply(toApplicationShouldTerminate: true)`. Do not remove.

## Code style

- Tabs for indentation (match existing files).
- SPDX header on every `.swift` file — two lines, no block comment:

  ```swift
  // SPDX-License-Identifier: BSD-3-Clause
  // Copyright (c) 2026 Brygga contributors
  ```

  Full license text lives in `LICENSE.md` at repo root. Do not reintroduce the old BSD-prose banner.
- Prefer `@Observable` over `ObservableObject`. Prefer `async`/`await` over completion handlers; bridge with `withCheckedThrowingContinuation` at the Network.framework boundary.
- No force-unwrap outside tests or clearly invariant cases. No `try!` in production code. No `fatalError` except for compile-time-impossible states.
- Doc comments (`///`) on every `public` symbol.
- Default to no comments. Only comment the **why** — a non-obvious constraint, invariant, or workaround. Don't narrate the what.
- Named locals over anonymous closures where the name adds signal. Avoid `prefix` / `suffix` as local-variable names (shadows `Collection.prefix(_:)` / `suffix(_:)` and derails Swift 6.2 overload resolution).

## Commits, branches, PRs

- Default branch: `main`. Feature work goes on a branch; never force-push `main`.
- **No AI attribution**: never add `Co-Authored-By: Claude` (or similar) to commits, code, or PRs. This includes trailers, footers, and PR bodies.
- Commit messages: one-line imperative summary, optional body. No emoji prefixes. No conventional-commits `feat:` / `fix:` prefixes.
- `swift test` must pass before every commit.

### Pull requests

- **One logical change per PR.** No drive-by refactors or bundled feature + cleanup. Open a follow-up if you notice something.
- **Branch names:** short kebab-case — `reconnect-on-drop`, `sasl-auth`, `fix-pm-inspector`. No dates, no usernames, no ticket IDs unless there's a real issue link.
- **Title:** one-line imperative under 70 chars. Examples: `Add SASL PLAIN authentication`, `Fix PM tabs losing focus on reconnect`. No `[WIP]`, no emoji.
- **Body** uses these exact headings:

  ```markdown
  ## Summary
  1–3 bullets on what this PR does and why.

  ## Changes
  Bulleted list of the concrete edits. Cite the most important file paths.

  ## Test plan
  - `swift build` — passes
  - `swift test` — N tests pass (state the count)
  - Manual verification steps for any UI change, each as a checklist item
  - Screenshots or screen recordings for visible UI changes

  ## Risk / rollback
  Anything a reviewer should worry about, and how to revert if it breaks.
  ```

- **Screenshots required** for any change that alters window chrome, sidebar, chat area, inspector, or any visible control. Recordings beat screenshots for state / selection / animation changes.
- **Test plan is mandatory.** Docs-only PRs write `N/A, docs only`. Behaviour changes require reviewer-reproducible manual steps.
- **CI must be green** before requesting review. Open as Draft for WIP; flip to Ready when CI passes and the body is complete.
- **Do not merge your own PR** unless it's docs-only or the user explicitly asks. Default: push, wait for review.
- **`Closes #N`** only when the PR fully resolves the issue. Otherwise `Refs #N`.
- Squash or rebase; no merge commits on `main`. History stays linear.

## Release channels

- **Stable**: manual `v*` tag push. `github.com/buggerman/Brygga/releases/latest` surfaces the newest one via GitHub's built-in "Latest release" badge.
- **Nightly**: rolling prerelease at tag `nightly`, rebuilt on every push to `main`. Tag is deleted and recreated per push so the URL is always current. Includes the 7-char commit SHA in the release title for traceability.
- Both DMGs are ad-hoc codesigned (`codesign --sign -`). First launch needs right-click → Open; if Gatekeeper still refuses, `xattr -cr /Applications/Brygga.app` clears the quarantine attribute. Proper Developer-ID notarization is out of scope.

## What not to do

- Do not create `.app` bundles by hand — use `Scripts/build-app.sh`.
- Do not regenerate `AppIcon.icns` unless the source art changes.
- Do not introduce Objective-C, ObjC bridging, or C interop.
- Do not add `@available` guards; bump the deployment floor instead.
- Do not hammer Libera / OFTC / other public networks during dev loops.
- Do not skip commit hooks (`--no-verify`).
- Do not add AI attribution anywhere in the history.
