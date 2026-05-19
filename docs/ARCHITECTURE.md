# Architecture

kooky is a single Swift package (`Package.swift`, swift-tools 6.2, macOS 14+) with three targets and one binary dependency.

## Targets

| Target | Kind | What it is |
|---|---|---|
| `Kooky` | executable | `Sources/Kooky/main.swift` — 7 lines. Owns `NSApplication` and an `AppDelegate`; all real code lives in `KookyKit` so tests can `@testable import` it (SPM does not allow importing executables). |
| `KookyHook` | executable | `Sources/KookyHook/main.swift` — tiny stand-alone CLI invoked from agent hook systems (Claude Code's `--settings` hooks, Codex's `notify`, Gemini's system settings, OpenCode's plugin, Copilot's hooks dir, plus generic bracket wrappers). Reads `$KOOKY_SURFACE_ID`, connects to the running app's unix socket, writes one JSON line, exits. Does **not** link `KookyKit` on purpose — keeps it fast and dependency-free. |
| `KookyKit` | library | All app code: UI, models, terminal engine wrapping, persistence, shell integration, IPC server. |
| `GhosttyKit` | binaryTarget | xcframework at `Vendor/GhosttyKit.xcframework`, not committed; populated by `scripts/setup-libghostty.sh`. |
| `KookyKitTests` | testTarget | 113 unit tests against `KookyKit`. |

`KookyKit` links: `c++`, `Metal`, `MetalKit`, `CoreText`, `CoreGraphics`, `CoreVideo`, `QuartzCore`, `IOSurface`, `Carbon`. libghostty bundles its own C++ deps (glslang, spirv-cross, imgui) and renders via Metal; Carbon for Text Input Services (active keyboard layout).

## KookyKit module layout

```
Sources/KookyKit/
├── App/         # AppDelegate, window setup, menu bar, settings UI, theme
├── Sessions/    # WorkspaceStore, Workspace/Pane/Session models, persistence, agents, IPC server
├── Terminal/    # libghostty bridge, pane-tree view, shell integration, scroll indicator
├── Sidebar/     # Vertical workspace list, hover/row styling
├── Settings/    # (currently empty — settings UI lives in App/)
└── Resources/   # Bundled icons + fonts (Bundle.module)
```

Module boundaries are conventional, not enforced by SPM (everything is in one target). Treat the directories as logical layers: `App` → `Sessions` + `Terminal` + `Sidebar` → `Sessions` → `Terminal` underpins everything else.

## Core data model

`WorkspaceStore` (`Sessions/WorkspaceStore.swift`, `@MainActor @Observable`) is the single source of truth at runtime. It owns `[Workspace]`, the active workspace id, the closed-tab LIFO stack (capped at 50, runtime-only), per-session `GitWatcher` instances, debounced save scheduling, and a `Persistence` impl.

```
Workspace (sidebar row)
└── root: PaneNode
    ├── .pane(Pane)             # leaf: owns [Session] tabs
    └── .split(orient, first, second, fraction)   # internal: binary tree
```

A `Session` is one tab: owns a `TerminalEngine` (libghostty surface), current cwd, agent template, conversation id (Claude only), last-command exit/duration, search state, git status, and live shell environment indicators.

Splits form a binary tree of `PaneNode`s. `⌘D` splits horizontal, `⌘⇧D` vertical, `⌘W` closes a tab and collapses an empty pane (sibling takes the parent's place). When closing, **object identity matters, not id equality** — after splitting, the root `PaneNode` keeps its id but its content becomes `.split`, and freshly-constructed children reuse the original `pane.id`.

## Terminal engine

`TerminalEngine` is a protocol (`Terminal/TerminalEngine.swift`); production uses `LibghosttyEngine` (1084 lines), the bridge to the libghostty C API.

Engines emit callbacks for: cwd change (OSC 7 / `GHOSTTY_ACTION_PWD`), focus (NSView first-responder), `OSC 133;D` command finish (exit code + duration), search lifecycle (start/end/total/selected), and clean process exit. `WorkspaceStore.wireSessionCallbacks` is the single site that hooks all of these together with per-session reactions.

Tests inject `TestEngine` (`Tests/KookyKitTests/TestEngine.swift`) via `WorkspaceStore(engineFactory:)`.

## Shell integration

We do not bundle ghostty's shell-integration assets. Instead `KookyShellIntegration` (`Terminal/ShellIntegration.swift`, ~650 lines, all `enum` static API) generates per-process wrapper rc files in `NSTemporaryDirectory()` on app launch:

- **zsh**: a `ZDOTDIR` directory with a wrapper `.zshrc` that sources `~/.zshrc`, restores the user's original `ZDOTDIR`, prepends `$KOOKY_BIN_DIR` to `PATH`, installs `chpwd` OSC 7 hook, the OSC 133 prompt+command boundary hook, the env-status hook (memoized), and conditionally launches `$KOOKY_AGENT`.
- **bash**: a launcher script that `exec`s bash with `--rcfile <path>` because libghostty starts every command as a login shell, which ignores `--rcfile`.

The wrapper rc also writes agent-specific hook config files (Claude Code `--settings`, Gemini `GEMINI_CLI_SYSTEM_SETTINGS_PATH`, Copilot `~/.copilot/hooks/kooky.json`, OpenCode plugin under `$XDG_CONFIG_HOME/opencode/plugin/kooky.ts`) and per-agent shim binaries in `~/Library/Application Support/kooky/bin/` (PATH-prepended so the shim is found first). Each shim:
1. Finds the real binary on `$PATH` skipping its own dir.
2. Falls back to `KookyHook <slug> ended` and a yellow "X is not installed" message if the binary is missing.
3. Wraps execution with `KOOKY_HOOK_BIN <slug> running` and `… ended` for bracket-style lifecycle, or injects the agent's native hook config when one exists.

User-config-space files (OpenCode plugin, Copilot hooks JSON) are written via `writeManagedFile` / `writeManagedJSON`, which only overwrite when the existing file carries the `kooky-managed-do-not-edit` marker or `_kookyManaged` JSON field. **A user's same-named file is preserved.**

`applicationWillTerminate` calls `KookyShellIntegration.cleanup()` to remove the per-process tempfiles.

## IPC: app ↔ hook

`HookServer` (`Sessions/HookServer.swift`) binds a unix socket at `~/Library/Application Support/kooky/socket` and reads one JSON line per connection. Three message kinds:

| `kind` | Payload | Effect on store |
|---|---|---|
| (default: `agent` + `event` fields) | `{agent, event, surface}` | `applyHookEvent` — updates `Session.agent` + `activityState` (running / attention / idle / ended → terminal revert). |
| `env` | `{VIRTUAL_ENV, CONDA_DEFAULT_ENV, NVM_*, KOOKY_NODE_VERSION, *_proxy, surface}` | `applyShellEnvironment` — drives the status bar pills. |
| `conversationId` | `{conversationId, surface}` | `applyConversationId` — persisted on `Session.conversationId` for `--resume <id>` (Claude only today). |

Routing is per-session: every shell + agent inherits `KOOKY_SURFACE_ID = <session UUID>` so messages always attribute correctly even with many concurrent tabs.

`KookyHook` exit codes are deliberate:
- `0` = success **or** caller is outside kooky / args malformed (no retry needed).
- `1` = IPC failed (kooky restarting, socket gone). The shell-side env hook uses this to skip advancing its dedup cache so the next prompt re-attempts — without it, a single transient failure would freeze the status bar permanently.

## Persistence

`Persistence` protocol (`Sessions/Persistence.swift`); production = `FilePersistence` writing pretty/sorted JSON to `~/Library/Application Support/kooky/state.json`. Tests use `InMemoryPersistence`.

`PersistedWorkspace` has a custom decoder that accepts a legacy flat `tabs: [PersistedTab]` shape (pre-split-pane releases) and wraps it into a single-pane root. `PersistedTab.conversationId` is `decodeIfPresent` so pre-resume releases still load.

Saves are debounced 1s via `WorkspaceStore.scheduleSave`; `flushPersistence` is called from `applicationWillTerminate`.

## Settings

`KookySettingsModel` (`@MainActor @Observable`, singleton via `.shared`) is the runtime view of `~/.kooky/settings.json`. JSONC-tolerant (`JSONSerialization.json5Allowed`).

Two layers in the schema:
- **kooky-specific** keys: `agents.order`, `agents.hidden`, `agents.default`, `agents.options[id]`, `agents.custom[]`, `agents.resumeConversations`, etc.
- **`terminal.*`**: flattened to ghostty's `key = value` flat format and pushed via `ghostty_config_load_string` *after* `ghostty_config_load_default_files`, so kooky-side keys layer on top of `~/.config/ghostty/config`.

First-launch onboarding (`KookyOnboarding.runIfNeeded`) imports an existing `~/.config/ghostty/config` if found, otherwise writes a commented default template.

## Hot paths to know

- **Cwd tracking**: shell OSC 7 → libghostty `GHOSTTY_ACTION_PWD` → `engine.onPwdChange` → `Session.currentDirectory` + workspace cwd + git refresh + env refresh + git-watcher rebind + scheduleSave.
- **Agent promotion**: user types `claude` in a Terminal tab → claude wrapper's `SessionStart` hook fires → `applyHookEvent(.claudeCode, .running, sid)` → `session.agent = .claudeCode`. Manual launch beats waiting for a first prompt.
- **Right-click "Ask <agent>"**: selection → POSIX-quoted prompt → `AgentTemplate.makeSessionConfig(initialPrompt:)` → spawned with `KOOKY_AGENT="claude -- 'selection'"` (or `-p`/`-x` flag form for Copilot/Amp).
- **Resume**: Claude pipes `session_id` on each hook event → `KookyHook` reads stdin → emits `conversationId` payload → `applyConversationId` persists. Next launch / `⌘⇧T`: `--resume <id>` prepended to `KOOKY_AGENT`, gated by `resumeConversations` setting.
