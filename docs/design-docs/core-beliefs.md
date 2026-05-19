# Core beliefs

The operating principles behind kooky's architecture and the conventions that fall out of them.

## 1. Local by default. No exceptions for "convenience."

No telemetry, no analytics, no cloud sync, no accounts. Crash reports stay on the user's disk. State stays on the user's disk. The user owns their data and we don't need to know anything about how they use the app.

**Consequence:** there is no field diagnostic channel. We can't iterate on phantom problems — every change has to be defensible from first principles or measurable locally.

## 2. User-authored files are sacrosanct.

When kooky writes into user-config space (`~/.copilot/`, `$XDG_CONFIG_HOME/opencode/plugin/`), it stamps a marker (`kooky-managed-do-not-edit` text or `_kookyManaged` JSON field) and refuses to overwrite anything without it. A user's same-named file is preserved at the cost of the feature.

**Consequence:** removing a managed file from disk re-enables kooky writing it on next launch — predictable. A user file accidentally named the same blocks our feature *silently*, by design.

## 3. The user's existing tools win.

kooky imports `~/.config/ghostty/config` once, then owns its copy. We don't fight the user's `~/.zshrc` — we source it. The wrapper rc layers on top, never replaces. PATH prepends our wrapper dir but the rest of the user's environment is preserved verbatim.

**Consequence:** every shell-integration change has to consider what happens when the user's rc has already done something to the same surface (PROMPT, `PROMPT_COMMAND`, `chpwd`).

## 4. Comments explain *why*, not *what*.

The codebase reads top-to-bottom with rich rationale comments. Every non-obvious choice carries a sentence or two about the failure mode it avoids, the OS quirk it works around, or the alternative that was tried and discarded. This is the documentation that survives refactors — code can be renamed, but the *reason* doesn't.

**Consequence:** new code is expected to match the density. PR review pays attention to "why is this here" comments, not "what does this do" comments.

## 5. One source of truth, mechanically enforced.

- `AppInfo.displayVersion` is *the* version. `Info.plist` is generated.
- `WorkspaceStore` is *the* runtime state. `Session` / `Workspace` / `Pane` reach for their owning store through closures, not back-pointers.
- `KookyShellIntegration` is *the* shell-wrapper generator. Hooks for new agents go through `hooksObject` / `bracketWrapperScript`, not bespoke shell strings sprinkled across the codebase.

**Consequence:** when something is wrong, there is one place to fix it.

## 6. Tests verify the model. The UI is the user's job to verify.

113 unit tests against the protocol surface; zero UI tests. The TerminalEngine protocol exists specifically so the state machine can be tested without spawning a real PTY. The UI is checked by running the app — golden paths listed in `docs/TESTING.md`.

**Consequence:** anything load-bearing belongs behind the protocol, not behind a SwiftUI view. View code is "as simple as it can be" because we don't test it.

## 7. Failure modes are designed, not discovered.

`KookyHook` exits 0 vs. 1 on a deliberate semantic split (acceptable failure vs. retry-needed). `resolvedSpawnCwd` falls back to `$HOME` instead of trapping. Same-value `@Observable` guards exist on hot setters. Closed-tab stack is bounded. Persistence is debounced. These are *patterns*, not point fixes — match them when adding new hot paths.

## 8. Small surface area.

Zero external Swift dependencies. One binary dependency (libghostty), and that's because GPU-accelerated terminal rendering isn't something we want to maintain ourselves. The KookyHook CLI deliberately doesn't link KookyKit — keeps the binary fast and lets hooks load with minimal startup overhead.

**Consequence:** "what if we used <library>" gets a high bar. The maintenance cost of a dependency is paid forever.
