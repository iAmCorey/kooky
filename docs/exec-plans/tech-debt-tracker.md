# Tech debt tracker

Prioritized list. Each entry: what the debt is, the cost of carrying it, and a rough size of the fix.

Status legend: 🔴 high (compounding) · 🟡 medium (annoying but stable) · 🟢 low (cosmetic).

## Items

### 🟡 `LibghosttyEngine.swift` is at 1084 lines

The single largest source file. All libghostty C-API integration in one place is *defensible* (helpful for "where does this callback come from"), but the file is hard to navigate. Natural splits along the callback surface: cwd/focus, command-finished (OSC 133), search lifecycle, paste/input/selection.

**Cost:** every change here is slower to make and review than it needs to be.
**Size of fix:** M — split into a folder, no behavior change.

### 🟡 `KookySettingsUI.swift` is at 902 lines

Mixes the window controller, sidebar layout, per-row editors, and the JSON-open-in-tab plumbing. Each is a clean unit.

**Cost:** Settings is one of the more frequently-changed surfaces — friction here is felt often.
**Size of fix:** M.

### 🟢 Empty `Sources/KookyKit/Settings/` directory

Either move `KookySettingsUI.swift` into it (and rename to reflect the four units above) or delete the empty dir.

**Cost:** zero — minor confusion when grepping for "Settings" code.
**Size of fix:** XS.

### 🟢 No CI

`swift test` runs locally only. A GitHub Actions workflow to run the suite on PRs would catch regressions without touching contributor workflow.

**Cost:** regressions in untouched modules can slip through to a release.
**Size of fix:** S — one workflow YAML.

### 🟢 No lint config

Swift's compiler warnings are the lint surface. SwiftLint with a minimal config would codify some of `docs/CODING_STANDARDS.md` (force-unwrap discipline, line-length budget) mechanically.

**Cost:** standards drift gets caught at code-review time, not before.
**Size of fix:** S — install + 30-line config.

## Adding an item

Keep entries short. The body should answer:
1. What's the debt?
2. What does carrying it cost?
3. How big is the fix?

Move resolved items out (delete; the git history is the record).
