# Security

kooky is a local-only macOS terminal. There is no network surface, no auth, no remote control. Its security model is about not accidentally exfiltrating user data and not destroying user-owned files.

## Trust boundaries

| Boundary | Direction | Scope |
|---|---|---|
| kooky.app ↔ user's shell | Read+write PTY, env vars, OSC sequences | The shell is fully trusted; kooky renders what it sends. No content filtering. |
| kooky.app ↔ `KookyHook` over unix socket | Read JSON lines from socket | Socket lives in `~/Library/Application Support/kooky/socket` — user-mode unix perms only. `HookServer.parseMessage` requires a valid surface UUID; messages with unknown surfaces are silently dropped. |
| kooky.app ↔ disk | Read user config, write app state + per-process tempfiles + agent hook configs | Writes are confined to the paths below. |
| `KOOKY_SURFACE_ID` env var | Set per-session, inherited by all children | The session UUID is not a secret — it's a routing key inside one user's machine. Don't treat it as auth. |

## Paths kooky writes to

- `~/Library/Application Support/kooky/state.json` — workspaces, tabs, panes, conversation ids. Pretty/sorted JSON.
- `~/Library/Application Support/kooky/bin/<agent>` — wrapper shim scripts (chmod 755). Regenerated each launch.
- `~/Library/Application Support/kooky/hooks/{claude,gemini-defaults}.json` — agent hook configs. Regenerated each launch.
- `~/Library/Application Support/kooky/socket` — unix socket. Created at start, removed on stop.
- `~/.kooky/settings.json` — user-facing settings, JSONC-tolerant. Written on first launch from default template or imported ghostty config.
- `~/.copilot/hooks/kooky.json` — only when `~/.copilot/` already exists. Carries `_kookyManaged` marker; `writeManagedJSON` refuses to overwrite a user-authored same-named file.
- `$XDG_CONFIG_HOME/opencode/plugin/kooky.ts` (or `~/.config/opencode/plugin/kooky.ts`) — OpenCode plugin. Carries `kooky-managed-do-not-edit` marker; `writeManagedFile` refuses to overwrite a user-authored same-named file.
- `$TMPDIR/kooky-zsh-<pid>/.zshrc`, `$TMPDIR/kooky-bashrc-<pid>`, `$TMPDIR/kooky-bash-launch-<pid>.sh` — per-process shell wrappers. Removed in `applicationWillTerminate`.

## What kooky does *not* do

- No network calls from app state. Period. (The user's shell can do whatever it wants; that's outside the trust boundary.)
- No telemetry, no crash reporting, no analytics.
- No reading or modifying files outside the paths above and what the user explicitly drag-drops into a tab (paths only get *typed* into the PTY — kooky doesn't open them).
- No persistent storage of clipboard contents, selected text, or agent output. Right-click "Ask <agent>" reads the current libghostty selection synchronously and passes it to the new tab; nothing is cached.

## Signing

kooky binaries are **adhoc-signed** (`codesign --sign -`). This is enough for personal-machine launches but does not establish provenance for distribution. First-launch on a third-party Mac requires the user to bypass Gatekeeper (README documents the three paths). Public-distribution signing + notarization is a future step.

## Shell-string safety

Every string that becomes part of a shell command path uses the helpers in `KookyShellIntegration`:
- `quote(_:)` — POSIX single-quote, internal `'` becomes `'\''`. Safe for argv-style values.
- `backslashEscape(_:)` — for paths that should render unquoted. Falls back to `quote(_:)` when the path contains a literal newline (shells eat `\<newline>` as line continuation).

The right-click "Ask <agent>" path always quotes the prompt and inserts a POSIX `--` separator (unless the agent declares `promptLaunchFlag`), so a selection starting with `-` doesn't get treated as an argv flag.

## Prompt injection through repo content

Agents launched from kooky read the user's working tree the same way they would in any other terminal. kooky does not inspect or filter agent output. **If you run an untrusted agent on untrusted content, your terminal is no more vulnerable than any other terminal — and no less.**

## What to escalate

- Any change that adds a non-zero network surface (listening port other than the unix socket, outbound request, telemetry beacon).
- Any change that writes outside the paths listed above.
- Any change that lowers the marker policy on managed user-config files (i.e. would let kooky overwrite a user-authored file in `~/.copilot/` or `$XDG_CONFIG_HOME/opencode/plugin/`).
- Any change that disables the POSIX `--` separator on right-click prompts.
- Any change that links new C/C++ libraries beyond the current `linkedFramework` set.
