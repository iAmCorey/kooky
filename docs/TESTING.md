# Testing

## Running tests

```sh
swift test                              # full suite (113 tests as of v0.11.3)
swift test --filter WorkspaceStoreTests # one test class
swift test --filter WorkspaceStoreTests.testReopenLastClosedTab  # one test
swift test --parallel                   # default-on in newer toolchains
```

Tests live in `Tests/KookyKitTests/`. There are no integration tests, UI tests, or snapshot tests — everything is unit-level against `KookyKit`'s public-and-internal API.

## Test infrastructure

Two test doubles do most of the work:

- **`TestEngine`** (`Tests/KookyKitTests/TestEngine.swift`) — a `TerminalEngine` impl that records calls and exposes hooks (`triggerPwdChange`, `triggerCommandFinished`, etc.) so tests can drive the store's callback wiring without a real PTY.
- **`InMemoryPersistence`** (`Tests/KookyKitTests/InMemoryPersistence.swift`) — keeps `PersistedState` in a property; tests assert on its contents to verify save/restore.

Standard test setup:

```swift
@MainActor
@Test
func exampleTest() async {
    let persistence = InMemoryPersistence()
    let store = WorkspaceStore(
        persistence: persistence,
        engineFactory: { TestEngine() },
        optionsProvider: { _ in nil },     // ignore developer's settings.json
        resumeProvider: { true }
    )
    // ...
}
```

Always pass all four injection points. Tests that read `KookySettingsModel.shared` are forbidden — they'd depend on whatever happens to be in `~/.kooky/settings.json` on the dev machine.

## What the suites cover

| File | Focus |
|---|---|
| `WorkspaceStoreTests` | Workspaces, tabs, panes, splits, cwd tracking, hook routing, persistence round-trip, drag/drop reorder, closed-tab stack |
| `AgentTemplateTests` | Template lookup, custom-agent inheritance, prompt quoting in `makeSessionConfig`, resume eligibility |
| `EnvironmentDetectorTests` | Live-shell env + project-file fallback (`.venv/`, `.nvmrc`, `.python-version`) |
| `GitStatusFetcherTests` | Real `git` subprocess against tmpdir repos — verifies branch + dirty file counts |
| `GitWatcherTests` | DispatchSource file watcher coalesces near-simultaneous events |
| `ShellIntegrationTests` | `quote` / `backslashEscape` / managed-file marker / hook-object shape for all agents |

`GitStatusFetcher` and `GitWatcher` tests use real filesystem operations in `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)` and `git init` via `Process`. Slowest tests in the suite; still well under a second each.

## Manual testing (the UI is not tested in CI)

There is no UI test harness. The `swift test` suite verifies the model layer. To exercise the UI:

```sh
swift run                               # dev mode, attaches to terminal
./scripts/build-app.sh                  # build a real .app bundle for drag/drop testing
```

Golden paths to check by hand when changing UI:
1. `⌘T` opens a new tab with the default agent (or Terminal if no default).
2. `⌘D` / `⌘⇧D` split right / down; `⌘W` closes a tab and collapses an empty pane.
3. Right-click a selection → "Ask <agent>" → new tab spawns with prompt already submitted.
4. Quit kooky mid-Claude conversation → relaunch → tab resumes via `--resume <id>`.
5. Drag a file from Finder onto a pane → escaped absolute path drops at cursor.
6. `cd` somewhere in shell → status bar git/branch/Node pills update within ~200ms.

## When tests fail

- **`@MainActor` isolation errors** at compile time: add `@MainActor` to the test function. Most tests need it because `WorkspaceStore`, `Session`, `TestEngine`, and `KookySettingsModel.shared` are all `@MainActor`.
- **State leaks across tests**: tests share `KookySettingsModel.shared`. If your test mutates it, restore the original value in a `defer` block or use the injection points so you don't touch the singleton at all.
- **`GitWatcher` flakes** on slow CI: the watcher relies on DispatchSource VNODE events which take a few hundred ms to fire. The existing tests already account for this — don't tighten the timeout without a real fix.

## Where to add tests

- Pure model + state-transition logic → `WorkspaceStoreTests` (or a new file in the same style).
- Anything touching `LibghosttyEngine` → can't be unit tested today (no engine mock for the libghostty C API beyond protocol level). Cover via the engine protocol's callback surface instead.
- New agent template → `AgentTemplateTests` (config shape, resume gating, prompt-flag handling).
