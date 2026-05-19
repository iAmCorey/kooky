# Releasing

Releases are local, manual, adhoc-signed. There is no Apple Developer ID yet — public-distribution signing + notarization is deferred until kooky has real users.

## Version is a single source of truth

`Sources/KookyKit/App/AppInfo.swift` holds `displayVersion` as a `static let`. Bumping it propagates to:

- The About panel (`AppDelegate.handleAbout`)
- `scripts/build-app.sh` which greps it into `Info.plist` (both `CFBundleShortVersionString` and `CFBundleVersion`)
- `scripts/build-dmg.sh --build` which uses the same value for the DMG filename

**Never edit `Info.plist` directly** — `build-app.sh` regenerates it every build.

## Release steps

1. Bump `displayVersion` in `Sources/KookyKit/App/AppInfo.swift`.
2. Add a CHANGELOG entry under a new `## vX.Y.Z — YYYY-MM-DD` heading. Match the prose style of existing entries: one or two short paragraphs per change, lead with the user-visible effect, follow with the under-the-hood detail when it earns a sentence. No bullet salads. Dates in ISO format.
3. `swift test` — full suite must pass.
4. `./scripts/build-app.sh` — produces `dist/Kooky.app`. Open it; smoke-test for a minute (new tab, agent launch, split, settings, quit).
5. `./scripts/build-dmg.sh --build` — produces `dist/Kooky-vX.Y.Z.dmg`.
6. Commit, tag `vX.Y.Z`, push.
7. Upload the DMG to the GitHub release.

## Build outputs

| Path | Purpose | Gitignored |
|---|---|---|
| `.build/` | SPM build cache | Yes |
| `Vendor/GhosttyKit.xcframework` | Prebuilt libghostty; fetched by `scripts/setup-libghostty.sh` | Yes (entire `Vendor/`) |
| `dist/Kooky.app` | App bundle | Yes |
| `dist/Kooky-vX.Y.Z.dmg` | Distribution image | Yes |

## What `build-app.sh` actually does

1. `swift build -c release`.
2. Verifies `Kooky`, `KookyHook`, and `Kooky_KookyKit.bundle` (SPM resource bundle) exist.
3. Assembles `dist/Kooky.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}`. Both binaries live in `MacOS/` so `Bundle.module` finds resources next to the executable; the SPM resource bundle is copied into `Contents/Resources/` (Bundle.module's first-lookup path) and promoted to canonical macOS bundle layout (`Contents/Info.plist` + `Contents/Resources/*`) because SPM ships it flat and codesign's bundle validator rejects the flat shape.
4. Builds `AppIcon.icns` from the largest source PNG in `branding/icons/` via `sips` + `iconutil`.
5. Adhoc-signs inside-out (resource bundle → binaries → app).

## Adhoc signing limits

Adhoc signature (`codesign --sign -`) is enough for **personal-machine launches**. Public distribution requires a real Developer ID + notarytool run. First-launch on a third-party Mac is blocked by Gatekeeper and surfaces "is damaged" or "cannot be opened" — README documents the three workarounds.

`xattr -d com.apple.quarantine /Applications/Kooky.app` is the simplest user-side bypass.

## libghostty refresh

`scripts/setup-libghostty.sh` fetches the prebuilt `GhosttyKit.xcframework` from upstream and lands it in `Vendor/`. Idempotent — safe to re-run. Run it before the first `swift build` on a fresh clone.

To pin a different libghostty version, edit the URL/version inside `setup-libghostty.sh` and re-run.

## Pre-tag checklist

- [ ] `displayVersion` bumped
- [ ] CHANGELOG entry written (one heading + 1–3 short paragraphs)
- [ ] `swift test` clean
- [ ] `swift build -c release` clean
- [ ] `./scripts/build-app.sh` produces a launchable `.app`
- [ ] Manual smoke: open + new tab + launch one agent + split + quit + relaunch (state restored)
- [ ] `./scripts/build-dmg.sh --build` produces an installable `.dmg`
- [ ] Commit, tag `vX.Y.Z`, push, attach DMG to release
