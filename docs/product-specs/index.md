# Product specs

User-facing feature specs. Each entry: a single file describing what the feature does, the user-visible behavior, the edge cases, and what *isn't* in scope.

## Catalogue

_No specs yet._ Features to date are captured in `CHANGELOG.md` and `README.md` — that's been sufficient. Add an entry here when:
- A feature is complex enough that the changelog entry doesn't capture the full behavior.
- Multiple sessions will land the feature in pieces (each piece references the spec).
- A future "what does this feature actually do" question is foreseeable.

## Format

```markdown
# <feature name>

## What it is
<1–3 sentences, user-facing>

## User-visible behavior
- <bullet list of triggers + effects>

## Edge cases
- <edge case>: <how it's handled>

## Not in scope
- <thing a reader might assume is part of this but isn't>

## Open questions
- <unresolved decisions; remove when answered>
```
