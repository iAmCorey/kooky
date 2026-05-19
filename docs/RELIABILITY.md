# Reliability

The codebase already handles several recurring failure modes. The patterns below are load-bearing — read before changing the affected sites.

## Hook IPC: retry vs. accept

`KookyHook` returns:
- `0` on success **and** on "caller is outside kooky / args malformed" — both mean "no retry needed."
- `1` on actual IPC failure (kooky restarting, socket gone, write error).

The shell-side env hook in `envStatusBlock` uses this to decide whether to advance its dedup cache. Without the distinction, a single transient failure (kooky restarting between two prompts) would freeze the cache permanently and the status bar would silently stop updating.

**Pattern to keep:** any new IPC consumer should preserve the same exit code policy — don't conflate "no work to do" with "I tried and failed."

## Debounced persistence

`WorkspaceStore.scheduleSave` cancels the prior pending save and schedules a new one 1s out. Coalesces bursts (e.g. drag-reorder fires per intermediate position) into a single disk write. `flushPersistence` is called from `applicationWillTerminate` to drain the debounce; force a flush from anywhere else only when you need synchronous durability.

**Don't** call `persistence.save(snapshot())` directly — always go through `scheduleSave`.

## Same-value observable guards

`@Observable` setters notify on every assignment, even when the new value equals the old. With hooks that fire per-turn (Claude SessionStart + UserPromptSubmit), this can produce dozens of UI updates per second. Pattern:

```swift
if session.activityState != event.activityState {
    session.activityState = event.activityState
}
```

Applied throughout `WorkspaceStore.applyHookEvent`, `applyConversationId`, `refreshGitStatus`, `refreshEnvironment`. Add a same-value guard whenever a setter sits on a hot path.

## Cwd resolution fallback

`resolvedSpawnCwd(_:)` returns the saved path **if the directory still exists**, otherwise `$HOME`. Without it, kooky would spawn a shell at a deleted project path and the new tab would die one frame later with a confusing one-line error. Used by `addWorkspace`, `addTab`, `reopenLastClosedTab`, and the persistence-restore path.

## Agent revert on hook end

`applyHookEvent` only reverts `session.agent` to `.terminal` on `.ended` when the reporting agent matches what the session is currently running (or `baseAgentId` matches for customs). Otherwise a Codex run inside a Claude tab — or a delayed `ended` from a previous agent — would wipe the still-active icon.

For customs, the wrapper-end revert reads `AgentTemplate.baseAgentId` from the **template snapshot taken at spawn time**. A mid-run Settings edit/delete cannot leave the tab pill stuck.

## Graceful degradation when a binary is missing

The shared `wrapperPreamble` in `ShellIntegration.swift`:
1. Searches `$PATH` skipping its own dir.
2. If no binary found, prints `\033[33m<name> is not installed.\033[0m` to stderr, calls `KookyHook <slug> ended` so the tab icon reverts to Terminal, and exits 127.

**Don't** assume an agent is installed — every code path that spawns one must tolerate "not found" without crashing the tab.

## Persistence schema migration

Two existing migrations live in `Persistence.swift`:
- `PersistedWorkspace.init(from:)` accepts a legacy `tabs: [PersistedTab]` shape (pre-split-pane) and wraps it into a single-pane root.
- `PersistedTab.conversationId` is `decodeIfPresent` so pre-resume `state.json` files still load.

**Pattern:** new fields go through `decodeIfPresent`. Major shape changes get a CodingKeys-based bifurcated decoder.

## libghostty surface lifecycle

Engines do not survive PTY exit. Restored sessions spawn a fresh `LibghosttyEngine` and `start(config:)` it in the persisted cwd. Don't try to rehydrate scrollback or in-flight processes — they're gone.

## Closed-tab stack capping

`recentlyClosed` is capped at `closedTabHistoryLimit = 50` in `WorkspaceStore`. Unbounded growth would be a slow leak over a long session. The stack is **runtime-only** — closed tabs do not survive an app restart.

## Status bar memoization

`_kooky_env_status` in `envStatusBlock` skips the `kooky-hook env` IPC when no env key differs from the prior send, and caches `node --version` against the resolved `node` binary path + `NVM_BIN`. Without (a), every shell prompt would fork a subprocess; without (b), every prompt would pay V8 cold-start (~50–200ms).

When adding a new env field surfaced via the prompt hook, update both:
1. The `envKeys` array in `HookServer.swift` (server-side).
2. The `_kooky_env_now` composite key in `envStatusBlock` (client-side dedup).

Asymmetry between them silently drops events or oversends.

## OSC 133 marker re-injection

`__kooky_133_precmd` re-injects the `\e]133;B\a` marker into `PROMPT` on every prompt redraw. Starship / Powerlevel10k-style themes rebuild `PROMPT` each `precmd`, dropping our suffix; without the re-injection, cursor-click-to-move and jump-to-prompt go silently dormant for those users.

## What to escalate

- New persistence fields without `decodeIfPresent` — will break older `state.json`.
- Direct `persistence.save` calls outside `scheduleSave` / `flushPersistence`.
- New shell hooks that don't respect the `KOOKY_HOOK_BIN` exit-code policy.
- Removing same-value guards on `@Observable` setters in hot paths.
