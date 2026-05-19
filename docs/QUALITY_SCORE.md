# Quality score

Initial pass — no formal audit has been done. Grades reflect a read of the code in May 2026 with the v0.11.3 line count baseline.

## Modules

| Module | Grade | Notes |
|---|---|---|
| `App/` | A− | Menu DSL is clean (`buildMenu` / `selfRow` / `responderRow`). `AppDelegate` at 509 lines is the largest single file outside `LibghosttyEngine` / `KookySettingsUI` / `WorkspaceStore`; mostly menu wiring, splits naturally if it grows further. |
| `Sessions/` | A | `WorkspaceStore` (757 lines) holds a lot of orchestration but every method has clear scope; the `Workspace` / `Pane` / `Session` / `PaneNode` split is right. Persistence has clean migration story. |
| `Terminal/` | B+ | `LibghosttyEngine` (1084 lines) is the biggest file by a wide margin. Justified — it's the entire C-API bridge — but it's also the hardest place to navigate. Splitting along the callback surface (search lifecycle vs. cwd/focus vs. command-finished vs. paste/input) would help. |
| `Sidebar/` | A | Small, focused, idiomatic SwiftUI. |
| `Settings/` directory | N/A | Empty. The actual settings UI is in `App/KookySettingsUI.swift` (902 lines). Either move it here or delete the empty dir. |
| `ShellIntegration.swift` | A− | The wrapper-script generation is dense but well-commented. Long single file (647 lines) is hard to avoid — the per-agent hook objects all want to be in one place for consistency. |
| `KookyHook` target | A | 127 lines, no deps, well-commented exit-code policy. |
| Tests | A | 113 tests, good coverage of state transitions and shell-quoting edge cases. UI is unverified (acknowledged in `TESTING.md`). |

## Known gaps

- **No UI tests.** All UI verification is manual. Acceptable today given app size; revisit if regressions start slipping through.
- **`LibghosttyEngine.swift`** is at 1084 lines. Not a quality issue yet, but it's the single file most likely to bite if it grows further without a split.
- **Empty `Sources/KookyKit/Settings/` directory.** Either populate or remove.
- **Telemetry-free, by design.** Means no crash analytics from the field — `NSLog` to Console.app is the only diagnostic channel and only when a user manually checks.
- **`KookySettingsUI.swift`** at 902 lines mixes the window controller, the sidebar layout, the per-row editors, and the JSON-open-in-tab plumbing. Splitting along those four lines would help.
- **No CI configured** beyond local `swift test`. Adding GitHub Actions to run the test suite on PRs would be a low-friction win.
- **No formal lint config.** Swift's compiler warnings are the lint surface. Adding SwiftLint with a minimal rule set could codify some of the conventions in `docs/CODING_STANDARDS.md`.

## Re-grading cadence

This file is informational, not a gate. Re-score when:
- A file crosses 1200 lines.
- A new module is added under `Sources/KookyKit/`.
- An external audit (security or otherwise) lands.
- A new test category (UI / integration) is introduced or removed.
