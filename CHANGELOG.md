# Changelog

Notable changes per release. Tagged commits use `vX.Y.Z` shortform.

## v0.11.6 — 2026-05-19

- Fixed: ⌘V (paste) and ⌘C (copy) now fire on non-Latin keyboard layouts — Russian, Greek, Dvorak, AZERTY, anything where the physical V/C keys produce different characters. The pane's `keyDown` used to match by `event.charactersIgnoringModifiers`, which despite the name still reflects the active keyboard layout: on a Russian layout that key produces «м», so the comparison against `"v"` silently no-op'd and the paste branch was skipped. Switched to physical keyCode matching (`kVK_ANSI_V` = 9, `kVK_ANSI_C` = 8), same pattern already used a few lines below for ⌘← / ⌘→ / ⌘⌫. Layout-independent by construction.

## v0.11.5 — 2026-05-19

- Fixed properly: agents launched from the `+` menu under Powerlevel10k's *instant prompt* feature no longer fail with `Input must be provided either through stdin or as a prompt argument when using --print`. v0.11.4 attempted this via a `precmd` hook, but p10k's main `_p9k_precmd` (the one that actually restores stdio) appends itself to `precmd_functions` lazily and ends up AFTER any hook the kooky wrapper rc registered — so the agent still inherited captured stdio. Switched zsh's launch path to a `zle-line-init` widget (via `add-zle-hook-widget`), which fires once the entire precmd chain is done and zle is ready to read input. Setting `BUFFER` + `zle accept-line` submits the launch command as if the user typed it, so the agent runs as a real foreground command with TTY stdio and proper OSC 133 preexec/postexec bracketing. bash continues to use `PROMPT_COMMAND` (no p10k-equivalent for bash to step on us).

## v0.11.4 — 2026-05-19

- Fixed: agents launched from the `+` menu (Claude Code, Codex, …) no longer fail with `Input must be provided either through stdin or as a prompt argument when using --print` when the user's `~/.zshrc` enables Powerlevel10k's *instant prompt* feature. The wrapper rc used to run `eval "$KOOKY_AGENT"` inline while parsing zshrc — but p10k redirects stdout/stderr into a capture buffer until the first prompt renders, so the agent inherited non-TTY stdio, silently switched into non-interactive mode, then errored because no input was piped. Launch is now deferred to a one-shot `precmd` hook (zsh) / `PROMPT_COMMAND` entry (bash) that fires only after p10k restores stdio. Plain (non-p10k) users see no behavioral change. *(Note: this fix was incomplete — see v0.11.5.)*

## v0.11.3 — 2026-05-16

- Drag a file or folder from Finder onto any kooky terminal pane → its path drops in at the cursor. Multi-file drag = space-separated paths.

## v0.11.2 — 2026-05-16

- Click anywhere on your zsh prompt to jump the cursor there.

## v0.11.1 — 2026-05-15

- Right-click menu redesigned to match kooky's brutalist style.
- Fixed: right-clicking selections that start with `-` no longer crashes the agent.
- Fixed: paste in the right-click menu now matches ⌘V behavior in zsh / vim.
- Fixed: right-clicking inside an inactive split now activates that pane first.

## v0.11.0 — 2026-05-15

- Right-click selection → "Ask <agent>". Select any text in a terminal, right-click, pick an agent → a new tab spawns with the selection as the first prompt.

## v0.10.8 — 2026-05-15

- Claude conversations resume across kooky restarts. Quit mid-conversation → next launch picks up where you left off.
- Settings → Agents → `resume-conversation-when-reopen` toggle.

## v0.10.7 — 2026-05-15

- GitHub Copilot tabs now show the mid-run "attention" dot.

## v0.10.6 — 2026-05-15

- Custom agents can inherit from a builtin — pick **Claude Code** as the base and your custom (e.g. "Claude Opus") inherits the icon, brand tint, and lifecycle tracking.
- Fixed: custom-based-on-Claude tabs now revert to Terminal when the agent exits.

## v0.10.5 — 2026-05-15

- Define your own agent. Settings → Agents → `+ add custom agent` wires any CLI as a first-class kooky agent.

## v0.10.4 — 2026-05-15

- GitHub Copilot CLI joins the agent menu.

## v0.10.3 — 2026-05-15

- Default agent for `+` and `⌘T`. Pick any agent in Settings → Agents → default to skip the popover.

## v0.10.2 — 2026-05-14

- Per-agent launch options. Each agent row in Settings has a chevron to add options like `--model opus`.

## v0.10.1 — 2026-05-14

- Customise the `+` menu — hide agents you don't use, reorder the rest.
- Settings UI redesigned with a brutalist-minimal aesthetic.

## v0.10.0 — 2026-05-14

- Cursor CLI joins the agent menu.

## v0.9.12 — 2026-05-14

- Cleaner "agent not installed" message.
- Fixed: tab icon reverts to Terminal when the agent's CLI is missing.

## v0.9.11 — 2026-05-14

- Mac-style text editing shortcuts in the shell:
  - `Cmd+←` / `Cmd+→` — beginning / end of line
  - `Option+←` / `Option+→` (or `Ctrl+←` / `Ctrl+→`) — jump by word
  - `Cmd+Backspace` — delete to start of line
  - `Option+Backspace` — delete previous word

## v0.9.10 — 2026-05-14

- Friendlier "agent not installed" message.
- Fixed: `curl | bash` installers now write to your real `~/.zshrc`.

## v0.9.9 — 2026-05-13

- Non-focused panes fully dim, including terminal content.

## v0.9.8 — 2026-05-13

- Spot the focused pane at a glance — non-focused panes dim their chrome.

## v0.9.7 — 2026-05-12

- New Settings window (`⌘,`) backed by `~/.kooky/settings.json`. v1 surfaces Font Family / Font Size / Cursor Style.
- First-launch onboarding offers to import `~/.config/ghostty/config`.

## v0.9.6 — 2026-05-12

- Smoother sidebar-collapse animation.
- Per-row Unset button in the proxy popover.
- New app icon.

## v0.9.5 — 2026-05-11

- `Shift+Enter` inserts a newline. Plain Enter still submits.
- About panel polish.

## v0.9.4 — 2026-05-11

- Status bar git state auto-refreshes during agent sessions.
- Network proxy slot in the status bar.
- Tab icon promotes when you manually launch an agent.

## v0.9.3 — 2026-05-11

- Tab icon promotes when you manually launch an agent inside a Terminal tab.

## v0.9.2 — 2026-05-11

- `exit` / `logout` closes the tab automatically.
- Reveal in Finder — right-click any tab pill or workspace row.
- Reopen Closed Tab (`⌘⇧T`).
- `⌃⇥` / `⌃⇧⇥` for per-pane tab cycling.

## v0.9.1 — 2026-05-11

- Reveal in Finder for tabs and workspaces.
- Reopen Closed Tab (`⌘⇧T`) restores agent + cwd + custom title.
- `⌃⇥` / `⌃⇧⇥` per-pane tab cycling.

## v0.9.0 — 2026-05-10

- Pane status bar showing live working-tree state — Python venv, Node version, git branch, git diff.
- Click the Node version pill → switch between installed nvm versions. Click the git branch pill → switch branches.

## v0.8.0 — 2026-05-10

- Find in scrollback (`⌘F`) per-pane. `⌘G` / `⌘⇧G` for next / previous match.
- Gemini CLI activity dot.
- OpenCode activity dot.
- Amp activity dot.

## v0.7.6 — 2026-05-09

- App icon.
- macOS 14 minimum (was 15).

## v0.7.5 — 2026-05-09

- `.app` bundle. Drag `dist/Kooky.app` into `/Applications` and launch from Spotlight.

## v0.7.4 — 2026-05-09

- Workspace-level command-failure dot — red dot on the sidebar row when any tab has a non-zero last exit.

## v0.7.3 — 2026-05-09

- Per-tab last-command status — small red dot when the most recent command exited non-zero. Hover for `exit N · 12.4s`.
- `⌘↑` / `⌘↓` to jump between prompts.

## v0.7.2 — 2026-05-09

- Manual rename for tabs and workspaces. Right-click → *Rename…*. Persists.

## v0.7.1 — 2026-05-09

- URL `⌘+click` opens in your default browser.
- Mouse shape follows libghostty (pointing-hand on URLs, resize on TUI splits).
- Font size shortcuts: `⌘=` increase, `⌘-` decrease, `⌘0` reset.
- Clear Pane (`⌘K`).
- Sidebar mode persists across launches.

## v0.7.0 — 2026-05-09

- Three-state sidebar (`full` / `compact` / `hidden`), `⌘⌃S` cycles.
- Top chrome strip with dedicated drag handle, sidebar toggle, traffic-light clearance.
- View menu becomes the navigation hub — Tab `⌘1`-`⌘9`, Workspace `⌥⌘1`-`⌥⌘9`, splits, sidebar toggle. New Help menu.
- Custom About panel.

## v0.6.0 — 2026-05-09

- Drag-reorder workspaces and tabs with animated drop indicators.
- Cross-pane tab move via drag.
- View menu with `Tab 1`-`9` and `Workspace 1`-`9` switches.
- Double-click tab bar zooms the window.
- Right-click menus show keyboard shortcut hints.

## v0.5.0 — 2026-05-08

- Recursive splits — `⌘D` splits right, `⌘⇧D` splits down, `⌘[` / `⌘]` cycles focus, `⌘W` closes a tab and collapses an empty pane.
- Right-click context menus on tabs and sidebar rows.
- Click-to-focus across panes.

## v0.4.0 — 2026-05-08

- Codex integration — sidebar shows the Codex icon while it's running.
- Auto-promote agent on hook — plain Terminal tabs that report a Claude / Codex hook upgrade to the matching template.
- IME — Chinese / Japanese / Korean / Vietnamese compose properly.

## v0.3.0 — 2026-05-08

- Agent activity dot in the sidebar — blue when processing, amber when waiting on input, hidden when idle.
- Real Claude Code integration.

## v0.2.0 — 2026-05-08

- Keyboard shortcuts: `⌘T` new tab, `⌘N` new workspace, `⌘W` close tab, `⌘⇧W` close workspace, `⌘1`-`⌘9` switch tab.
- Persistence — workspaces, tabs, agent type, and cwd survive relaunch.
- Hidden title bar; tab bar sits at the window top edge.

## v0.1.0 — 2026-05-08

First public release. Native macOS terminal with vertical-tab workspaces and one-click AI agent sessions (Claude Code / Codex / Gemini CLI / OpenCode / Amp).
