# Coding standards

Swift 6.2, macOS 14 floor. SwiftUI + AppKit, with libghostty bridged through `GhosttyKit` (C interop).

## Concurrency

- **`@MainActor` by default** for anything touching `WorkspaceStore`, `Session`, terminal engines, or AppKit. Most types in `Sessions/` are `@MainActor`. `HookServer` is `@MainActor`; its `DispatchSource` is created on `.main` so handler invocations are already main-isolated.
- **`@Observable` macro** (not `ObservableObject` / `@Published`) — macOS 14+ floor exists specifically to allow this; do not regress.
- `@Bindable` on the consumer side when binding to `@Observable` properties.
- Same-value guards before assignments to `@Observable` properties when the setter is called frequently (e.g. hook events fire `.running` per Claude turn). Pattern:
  ```swift
  if session.activityState != event.activityState {
      session.activityState = event.activityState
  }
  ```
  Without this, every observer (sidebar, tab, status pill) re-renders even on no-op writes.

## Comments

The codebase already follows "comment the *why*, not the *what*" rigorously. Match the existing style:
- Lead with the surprising fact, then explain the reason (failure mode, alternative considered, OS quirk, libghostty behavior).
- No JSDoc-style boilerplate. No `// MARK:` unless the file is long enough to navigate by section (existing usage is in `WorkspaceStore`, `AppDelegate`).
- Don't restate the function name in the doc comment.
- Existing code rarely cites filenames / commit hashes in comments — keep it that way; rationale belongs in the code, history belongs in `git log`.

## Shell-string safety

Anywhere a string ends up in a shell command (PTY input, agent launch, wrapper script):
- **POSIX single-quote** via `KookyShellIntegration.quote(_:)` for argv-style values. Escapes internal `'` as `'\''`.
- **Backslash escape** via `backslashEscape(_:)` for paths that should look "untouched" (Finder drag-drop). Falls back to `quote` on embedded newlines (POSIX shells eat `\<newline>` as line continuation — would silently corrupt legal macOS paths).
- For positional prompts to agent CLIs, insert a POSIX `--` separator before the prompt unless the agent declares a `promptLaunchFlag` (Copilot `-p`, Amp `-x`). Stops argparse from treating user-selected text that starts with `-` as a flag.

## libghostty bridge

- `LibghosttyEngine` (1084 lines) is the single chokepoint to the C API. New libghostty actions go through `performAction(_:)` (`increase_font_size:1`, `clear_screen`, `start_search`, …) so behavior stays in one place.
- Forwarded callbacks: never call store-mutating code directly from a libghostty callback; the engine surfaces a `Callback?` closure (e.g. `onPwdChange`) and `WorkspaceStore.wireSessionCallbacks` is the only site that hooks them up. This keeps the engine model-agnostic and tests usable with `TestEngine`.
- Engines do not survive PTY exit. Restored sessions spawn a fresh engine and start in the persisted cwd; do not try to rehydrate scrollback.

## Managed user-config files

When kooky writes into user-config space (`~/.copilot/`, `$XDG_CONFIG_HOME/opencode/plugin/`):
- Embed the `kooky-managed-do-not-edit` marker (text files) or `_kookyManaged` sentinel field (JSON).
- Use `writeManagedFile` / `writeManagedJSON` exclusively — they refuse to overwrite anything without the marker so a user's same-named file is never destroyed.
- The Copilot hooks file is only written when `~/.copilot/` already exists (the user has run Copilot at least once). Don't pre-stage vendor dirs.

## Settings → libghostty layering

`KookySettings.apply(to:)` runs *after* `ghostty_config_load_default_files`. Last write wins, so user's kooky-side keys override anything in `~/.config/ghostty/config`. Don't reorder — the import path (`KookyOnboarding.importGhosttyConfig`) snapshots ghostty config into kooky's JSON, so the two stay independent after first launch.

## Versioning

`Sources/KookyKit/App/AppInfo.swift` holds `displayVersion` as a `static let` string. **It is the single source of truth.** `scripts/build-app.sh` greps it into `Info.plist`. The About panel reads it directly. Bump it before tagging — never edit `Info.plist` directly (that file is generated each build).

## Persistence schema

- New fields on `PersistedTab` / `PersistedWorkspace` must be `decodeIfPresent` so old `state.json` files still load (`conversationId` is the model — see `PersistedTab`).
- Use the legacy `tabs: [PersistedTab]` decode path in `PersistedWorkspace` as the example for handling future schema migrations: keep both code paths in the same `init(from:)`.

## Tests

- Tests are `@MainActor` whenever they touch the store / engines (most of them). The `TestEngine` is `@MainActor`.
- Wire `WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { true })` so tests stay independent of the developer's `~/.kooky/settings.json`.

## Forbidden

- **No telemetry, no analytics, no cloud sync.** kooky is local-by-default and that's not negotiable.
- **No new external dependencies** in `Package.swift` without explicit discussion. Current deps: zero. binaryTarget for libghostty is the only non-stdlib code.
- **No `print`** — use `NSLog` for diagnostics (matches existing `HookServer` / `KookySettings` style; goes to Console.app).
- **No `Task.sleep` for timing-based test fixtures** — drive callbacks directly via the engine protocol.
- **No `--no-verify` git commits.** Fix the hook failure.
