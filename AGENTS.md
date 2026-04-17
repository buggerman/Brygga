# AGENTS.md

Rules for AI coding agents working in this repo. Read before editing.

## Project

Brygga is a native macOS IRC client written in pure Swift + SwiftUI. Target: macOS 14+. Default branch: `main`.

## Layout

- `Sources/BryggaCore/` — library target. IRC protocol, connection, session, models, persistence.
- `Sources/Brygga/` — executable target. SwiftUI views, `@main` entry point, AppDelegate adapter.
- `Tests/` — XCTest, `@testable import BryggaCore` only. Do **not** import the `Brygga` target from tests (the `@main` executable conflicts with XCTest linkage).
- `Resources/` — icon source art, generated iconset, `AppIcon.icns`.
- `Scripts/build-app.sh` — wraps the SPM binary into `build/Brygga.app` with a proper `Info.plist` and icon. A raw `swift run Brygga` does **not** activate as a GUI app — always use the script or the bundle.

## Build and test

- `swift build` — library + executable.
- `swift test` — full test suite. All tests must pass before commit.
- `./Scripts/build-app.sh` — produces `build/Brygga.app`. Use `open build/Brygga.app` to launch with a Dock icon. Use `./build/Brygga.app/Contents/MacOS/Brygga` from Terminal to capture `stderr` while debugging.
- CI runs on `macos-14` with Xcode 15.4 (`.github/workflows/ci.yml`).

## Architecture invariants

- `IRCConnection` is an `actor` — it owns the `NWConnection` and is the only place network I/O runs. Config properties (`host`, `port`, etc.) are `nonisolated let`.
- `IRCSession` is `@MainActor` — it mutates `@Observable` model objects (`Server`, `Channel`, `User`, `Message`) that SwiftUI consumes.
- Actor ↔ main-actor boundary uses `AsyncStream`: `connection.messages` and `connection.stateChanges`. The session spawns `Task { @MainActor … for await … }` loops in `start()`.
- `AppState` is the single `@MainActor @Observable` root. It owns `servers: [Server]` and `sessions: [String: IRCSession]` keyed by `server.id`.
- Model mutations must happen on the main actor so SwiftUI observation fires on the correct thread.

## SwiftUI gotchas

- `NavigationSplitViewVisibility.doubleColumn` in a 3-column split view **hides the sidebar**, not the detail. To hide a trailing pane conditionally, use `.inspector(isPresented:)` on a 2-column split view instead.
- Use `@Bindable var appState = appState` inside the view body when you need `$`-bindings to `@Environment`-injected observables.
- Sidebar rows render the raw channel name (e.g. `#libera`). Do not add a decorative `#` icon — the prefix is already part of the name.

## Persistence

- Config file: `~/Library/Application Support/Brygga/servers.json`.
- Owned by `ServerStore` (`Sources/BryggaCore/Persistence/ServerStore.swift`).
- Schema: `{ servers: [{ name, host, port, useTLS, nickname, autoJoinChannels, openQueries }] }`. `openQueries` is optional on decode for forward compatibility.
- Writes happen through `AppState.persist()` on: `addServer`, `removeServer`, own `JOIN`, own `PART`, own `KICK`, and query-tab creation (incoming PM or outgoing `/msg` / `/query`).
- Writes are suppressed while `isRestoring == true` during `AppState.init()`.

## Clean shutdown

- `BryggaAppDelegate.applicationShouldTerminate` returns `.terminateLater`, calls `appState.disconnectAll(quitMessage: "Brygga")`, then `NSApp.reply(toApplicationShouldTerminate: true)`. Do not remove this — dropping the socket without `QUIT` looks like a misbehaving client and can get the user K-lined.

## Testing discipline

- Do **not** hammer public IRC networks with reconnect loops during development. Libera will K-line after a few rapid reconnects and bans last ~24h.
- For iteration, run a local ircd: `brew install ergo && ergo mkcerts && ergo run`, then point Brygga at `127.0.0.1:6697`.
- IRC protocol parsing is tested offline via `IRCLineParser.parse` fed directly into `IRCSession.handle`. Tests must not open sockets.

## Code style

- Tabs for indentation (match existing files).
- File header block: see any existing `.swift` file for the BSD 3-Clause banner.
- Prefer `@Observable` over `ObservableObject`. Prefer `async`/`await` over completion handlers; bridge with `withCheckedThrowingContinuation` at the Network.framework boundary.
- No force-unwrap outside tests or clearly invariant cases. No `try!` in production code.
- Doc comments (`///`) on anything `public`.

## Commits, branches, PRs

- Main branch is `main`. Push feature work to a branch; do not force-push `main`.
- **No AI attribution**: do not add `Co-Authored-By: Claude` or similar trailers to commits, code, or PRs.
- Commit messages: one-line imperative summary, optional body. No emoji prefixes.
- Tests must pass (`swift test`) before every commit.

## Pull requests

- **One logical change per PR.** No drive-by refactors, unrelated formatting churn, or bundled feature + cleanup. If you notice something worth fixing outside the PR's scope, open a follow-up.
- **Branch naming**: short kebab-case describing the change — `reconnect-on-drop`, `sasl-auth`, `fix-pm-inspector`. No dates, no usernames, no ticket IDs unless there's an issue link.
- **Title**: one-line imperative under 70 characters, matching the commit style. Examples: `Add SASL PLAIN authentication`, `Fix PM tabs losing focus on reconnect`. No `[WIP]`, no emoji prefixes, no conventional-commits `feat:` / `fix:` prefixes — we don't use them here.
- **Body sections** (use these exact headings):

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

- **Screenshots required** for any change that alters the window chrome, sidebar, chat area, inspector, or any visible control. A recording is better than a screenshot for anything involving state transitions, selection, or animation.
- **Test plan is mandatory.** Every PR includes one, even for docs or refactors (state "N/A, docs only" if truly nothing to test). For behaviour changes, the plan must include manual steps a reviewer can run, not just "I ran tests locally".
- **CI must be green** before requesting review. Open as Draft if you're pushing work-in-progress; flip to Ready only when CI passes and the PR description is complete.
- **Do not merge your own PR** unless it's a docs-only change or the user has explicitly said to. Default is: push, wait for review.
- **Do not close issues from the PR body** unless the PR genuinely resolves the full issue. Use `Refs #N` for partial work, `Closes #N` only when the issue can actually be closed.
- **Squash or rebase** is fine; no merge commits on `main`. Keep history linear.
- **No AI attribution** anywhere — not in the title, not in the body, not in a trailer, not in a footer, not in commits on the branch. This repeats the commit rule because PR bodies are where agents most commonly break it.

## What not to do

- Do not create `.app` bundles by hand — use `Scripts/build-app.sh`.
- Do not regenerate `AppIcon.icns` unless the source art changes.
- Do not introduce Objective-C, ObjC bridging, or C interop. This project is pure Swift by design.
