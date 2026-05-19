# Design docs

Architectural decisions worth remembering. Each entry: one file, lead with the decision, follow with the alternatives considered and why they lost.

## Catalogue

- [Core beliefs](core-beliefs.md) — the agent-first operating principles for this project.

## When to add an entry

Add a design doc when:
- A choice constrains future work and the reasoning isn't obvious from the code (e.g. "why `@Observable` not `ObservableObject`", "why per-process shell wrappers vs. bundled integration assets", "why a unix socket and not XPC").
- A trade-off was made between two reasonable options and the loser deserves to be remembered (so future-you doesn't re-litigate it).

Don't add a design doc for:
- A bug fix — the commit message + inline comment cover it.
- A purely tactical decision (variable name, file split) — covered by `docs/CODING_STANDARDS.md`.
- A user-visible feature — `CHANGELOG.md` is the system of record.

## Format

```markdown
# <decision name>

## Decision
<1–3 sentences>

## Why
<the constraint or motivation>

## Alternatives considered
- **<alternative>** — rejected because <reason>.

## Consequences
<what this commits us to>
```
