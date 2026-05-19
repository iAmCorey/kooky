# Contributing

## Branches

`main` is the integration branch. Most work happens directly on `main`; feature branches are optional. The `gitignore` policy mirrors that — there are no per-branch agent context files in history.

## Commit style

Look at `git log --oneline -20` first — the existing style is the authority. Patterns that recur:

- Version bumps: bare `v0.11.3` (no prefix, no body).
- Doc changes: `docs: README — v0.10.8+ features + test count + Agents rename`.
- Otherwise short subject lines, lowercase, no emoji, no Conventional Commits framing. The author already pre-fills CHANGELOG.md so commit messages stay terse — the user-visible "why" lives there.

Always create new commits — never `--amend` published work.

## What goes where

| Surface | Belongs in |
|---|---|
| User-visible change | `CHANGELOG.md` (one entry per release tag, matching existing prose density). README.md when a new top-level feature lands. |
| Design rationale | Inline comment in the code at the point that needs it. Not a doc file. The codebase is comment-heavy by design. |
| Cross-file architectural decision | `docs/design-docs/` with an index entry. |
| In-progress multi-step work | `docs/exec-plans/active/<feature>-plan.md`. Move to `completed/` on merge. |
| Known tech debt | `docs/exec-plans/tech-debt-tracker.md`. |

## Invariants

These are non-negotiable; they're why kooky exists.

1. **Local-by-default.** No telemetry, no analytics, no cloud sync, no accounts. Anything that calls out to the network from app state belongs behind an explicit user toggle, and even then needs a strong reason.
2. **No new dependencies in `Package.swift`** without explicit discussion. The package has zero non-stdlib dependencies plus the libghostty binary target — keep it that way.
3. **A user's existing config is sacred.** kooky imports from `~/.config/ghostty/config` once, then owns its copy. Files written into user-config space (Copilot hooks, OpenCode plugin) require the `kooky-managed-do-not-edit` marker before kooky will overwrite them.
4. **`AppInfo.displayVersion` is the version.** Don't edit `Info.plist` directly.

## Pull requests

This is a small project — PRs are not the primary workflow. When one exists:
- Title should be the same shape as a commit subject (terse, lowercase).
- Body explains the *why* if it isn't obvious from the diff.
- No tickets, no Jira, no issue templates.

## Pre-merge checklist

- [ ] `swift test` passes locally.
- [ ] If you added a user-visible feature: README + CHANGELOG updated.
- [ ] If you changed the persistence schema: tested round-trip from an old `state.json` (use `decodeIfPresent` for new fields).
- [ ] No new `Package.swift` deps.
- [ ] No `print` / `console.log`-style debug output left behind.

## Where the harness docs are

- `docs/ARCHITECTURE.md` — package + module + IPC + persistence layout.
- `docs/CODING_STANDARDS.md` — concurrency rules, shell-string safety, comment style, forbidden patterns.
- `docs/TESTING.md` — how to run tests, what's covered, how to add more.
- `docs/RELEASING.md` — version bump → build → DMG → tag flow.
- `docs/SECURITY.md` — boundaries: socket scope, file writes, signing reality.
- `docs/RELIABILITY.md` — failure modes the code already handles and the patterns to keep using.
- `docs/QUALITY_SCORE.md` — current per-module grades + known gaps.
- `docs/design-docs/` — architectural decisions worth remembering.
- `docs/exec-plans/` — in-progress and completed multi-step plans + tech debt.
