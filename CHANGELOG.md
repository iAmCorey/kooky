# Changelog

Notable changes per release. Tagged commits use `vX.Y.Z` shortform.

## v0.51.8 — 2026-09-02

- Fixed: quitting kooky with ⌘Q while an agent was running no longer turns that tab into a plain terminal on the next launch — the agent comes back and resumes its conversation, as it did before v0.50.1. Thanks @kaijianding for the diagnosis and a draft fix. (#70)

## v0.51.7 — 2026-09-02

- New: the session history panel can be narrowed to the current workspace — tick "only this workspace" under the agent chips to list only conversations that ran inside the active workspace's project (its git repository, or the workspace folder outside git), so a busy machine's history stops burying the project you're in. The agent chips follow the workspace filter, and the header count follows every filter that's active. Thanks @kaijianding for the idea and a draft implementation. (#71)

## v0.51.6 — 2026-09-01

- Fixed: the numeric keypad Enter key now sends Return instead of being ignored. (#67)
- New: middle-click a tab to close it. (#66)
- Fixed: resizing the left sidebar no longer makes the terminal jitter, and the right sidebar can be dragged again. (#65)
- Faster: clicking between tabs now switches immediately, without waiting on the double-click-to-zoom gesture. (#64)
- Fixed: Ghostty user theme files now load their complete configuration, so settings such as selection and cursor colors take effect. (#68)

## v0.51.5 — 2026-08-26

- Fixed: a tab opened with `kooky-cli open --no-focus` now actually starts working in the background — the shell (and any `-e` command or agent) runs immediately instead of waiting for the tab to be clicked, while everything the flag promised still holds: kooky stays in the background and what you're looking at doesn't change. Rendering stays paused for hidden tabs, so a busy background tab costs no GPU. (#59)

## v0.51.3 — 2026-08-24

- New: `kooky-cli open` takes `--title <title>` to name the tab from the start (it outranks the automatic title, exactly like renaming the tab by hand), and `--no-focus` to open it in the background — kooky isn't brought to the front (including when the CLI has to launch it first) and the tab doesn't replace what you're looking at; like kooky's own restored background tabs, it starts running when first shown, and `kooky-cli focus` brings it forward. A new `rename --tab <uuid> --title <title>` command retitles an existing tab. Requires this version of the app; an older kooky ignores the new options. (#57)

## v0.51.1 — 2026-08-21

- Improved: `kooky-cli open` no longer needs `--cwd`. Without it the tab opens where the active workspace already is, so `kooky-cli open` on its own means "give me a new tab" and `--agent` alone starts an agent right there. (#56)

## v0.51.0 — 2026-08-21

- New: `kooky-cli` — control kooky from scripts, launchers, and other apps. `open` opens a tab at a directory, optionally running a command or starting an agent there; `resume` reopens an agent conversation; `list` prints every window, workspace, and tab with their ids; `focus` and `close` target one tab; `status` reports whether kooky is running. Everything but `status` launches kooky first if it isn't running. See the README for the full command list and where the binary lives.

## v0.50.7 — 2026-08-18

- Fixed: Ctrl+Space, Ctrl+digit, and Ctrl+punctuation combos sent nothing at all — e.g. Ctrl+Space as a tmux prefix was dead. They now send the standard terminal bytes, and Ctrl+Option combos and the kitty keyboard protocol work too. Thanks @h0hmj for the report and a draft fix. (#54)

## v0.50.6 — 2026-08-18

- New: `kooky://` deep links — external tools can reopen an agent conversation in kooky. `kooky://resume?agent=<agent>&id=<conversation-id>[&cwd=<path>]` resumes the conversation in a new tab at its own project directory; if it's already open in a tab, kooky jumps there instead of spawning a duplicate. Works from a cold start, accepts the `cwd` parameter for conversations older than the session scan keeps, and every refused link explains itself in a visible sheet. Links can't inject prompts, commands, or arbitrary directories — conversation ids are strictly validated and only agents kooky already reads session stores for are accepted.
- Fixed: picking a workspace or creating a worktree via ⌘P now restores the target window from the Dock when it was minimized.

## v0.50.5 — 2026-08-12

- Fixed: switching windows could crash the whole app with a renderer segfault, typically on terminals that had been running for hours. The bundled terminal engine now guards the cursor render path, recovers cleanly from interrupted render updates, and no longer tears down its render state every frame on long-lived terminals. (#53)

## v0.50.4 — 2026-08-10

- Improved: refreshed the main-window UI with softer selection states, quieter dividers, clearer typography, and tighter spacing across tabs, workspaces, and the Agent panel.

## v0.50.3 — 2026-08-10

- Fixed: a workspace created while the app is running (⌘N or the sidebar `+`) showed up blank — no tab bar, no terminal — until the window was resized. New workspaces now appear immediately. (#52)

## v0.50.2 — 2026-08-08

- Fixed: a program updating the terminal title at output speed (e.g. a TUI ticking token counts into OSC 0/2) no longer pegs a CPU core on SwiftUI layout while it streams. Title changes now coalesce to a few updates per second — the first change still shows instantly, and the latest one always lands. (#51)

## v0.50.1 — 2026-08-07

- Fixed: closing a tab or window now reliably terminates its foreground agent processes, including Pi sessions that previously could survive the terminal and keep issuing requests in the background. App quit waits for terminal teardown without blocking the main thread. (#50)

## v0.50.0 — 2026-08-07

- Workspace switching is now instant: every workspace stays alive inside the window and switching simply reveals it — no flicker, no terminal re-mounting, and keyboard focus lands back on the pane you left.
- An open ⌘L composer or ⌘F search bar keeps its draft and keyboard focus across workspace switches.
- Hidden workspaces pause their terminal rendering, and restored background tabs start their shells only when first shown.
- Fixed: the ⌘F search bar was clipped at both edges in narrow split panes — it now adapts to the pane width.
- Fixed: the status-bar zoom and compose buttons could briefly tear (background moving before the icon) when toggling pane zoom.

## v0.49.0 — 2026-08-06

- Refined the UI with better alignment, consistent button and hover states, and polished sidebar, file-tree, Session Info, and status-bar styling across light and dark themes.

## v0.48.4 — 2026-08-06

- Faster: the sidebar file tree now performs every directory listing off the main thread and cancels queued work when hidden; Session Info refreshes only its process section; status-bar layout measurements and bundled-resource lookup are cached; and tabs in the same repository share Git status queries.
- Fixed: terminal panes now target a 200pt minimum width across window resizing, repeated splits, restored layouts, and divider dragging. The window expands only up to the current screen, nested pane trees reserve the correct space, and physically constrained layouts compress panes proportionally instead of pushing the rightmost pane off-screen.

## v0.48.3 — 2026-08-06

- Fixed: running Claude and Pi tool calls no longer drive a per-second SwiftUI layout loop that could peg a CPU core. The status-bar pill and history popover now show a stable running state, then switch to the final duration when the tool finishes; VoiceOver also avoids repeating the running status. (#49)

## v0.48.2 — 2026-08-06

- Improved: the Session Info "Last command" card reads tighter — short commands share one line with their duration and exit code, the exit code itself is tinted green or red, and the redundant pass/fail word and status dot are gone.

## v0.48.1 — 2026-08-05

- New: the Session Info panel is now hands-on — hover a field for a one-click copy of its full value, click a port chip to open it in the browser, and right-click a process to copy its PID or end it (with an in-menu confirm that double-checks the process is still the one you meant). Processes show live CPU and memory with busy rows highlighted, and ports sit on their own line under the process name.
- New: a failed command in a local session gets an "Ask AI" button — one click hands the command, exit code, and directory to an AI agent in a new tab. The button remembers the agent you last picked; its dropdown lists your enabled agents in Settings order.
- Improved: collapsed Session Info sections survive a relaunch, the process list no longer pops in after the page opens or shows another tab's processes during a switch, and SSH sessions say outright that remote processes aren't visible.

## v0.48.0 — 2026-08-05

- New: Session Info panel — a third page in the right sidebar inspecting the active tab: workspace, directory, remote host, git branch/repo/diff, Python venv, Node version, proxy, a live process tree showing what's running and which ports it listens on, the last completed command with its exit code and duration (zsh/fish), and the terminal title. Sections collapse, and everything updates live as you work. Command lines are kept in memory only and never written to disk.
- Fixed: on dark themes, the tab restored at app launch silently lost its shell integration — no failed-command red dot, no title or directory tracking, no agent detection — until it was closed and reopened. Restored tabs now spawn with their integration intact.

## v0.47.2 — 2026-08-04

- Fixed split-pane Composer focus: clicking or focusing a Composer now activates its pane immediately, while each tab keeps its own draft and sends to the correct session.
- Fixed terminal shortcuts while Settings, About, Quick Open, notifications, or a sheet is in front, so commands no longer mutate a terminal window hidden behind auxiliary UI; Reopen Closed Tab is disabled when there is nothing to reopen.
- Kept Quick Open and notification panels on-screen near display edges, anchored Settings file and folder pickers to the Settings window, and prevented hover cursors from getting stuck when UI disappears under the pointer.

## v0.47.1 — 2026-08-03

- Refined the main-window layout so the workspace header, pane tab bar, and Agent panel header share one aligned 40pt content baseline.
- Matched workspace and Agent panel row density with 11pt vertical padding, and clarified worktree hierarchy with indented child rows and an always-discoverable disclosure control.
- Made toolbar, Open In, and popover hover states theme-aware for consistent contrast across light and dark appearances.

## v0.47.0 — 2026-07-31

- New: native Simplified Chinese localization across kooky's settings, menus, sheets, popovers, notifications, status bar, command palette, and other app chrome; English remains the development language.
- New: Settings → General gains an app-language picker for Follow System, English, and 简体中文. It writes macOS's native per-app language preference and applies after a restart, preserving terminal sessions until the user chooses to restart.
- Fixed: Follow System now uses Foundation's localization matching, so unsupported variants such as Traditional Chinese fall back exactly as the app bundle does; the selected-language preview, restart copy, relative-time labels, and VoiceOver tool-count labels all use the correct target language.
- Fixed: runtime names such as git branches, installed apps, Node versions, and custom agents stay verbatim instead of being mistaken for localization keys.

## v0.46.0 — 2026-07-29

- New: paste protection. Pasting text that could run commands the moment it lands shows a confirmation with a content preview first (`clipboard-paste-protection`, on by default). ⌘W / Esc cancel; file, image, and SSH-upload pastes are unaffected.
- New: OSC 52 clipboard support, guarded — remote programs (tmux, nvim over SSH) can read your clipboard after you approve it, and `clipboard-write = ask` asks before a program replaces your clipboard.
- New: secure keyboard input at password prompts — typing a sudo/ssh password blocks other processes from monitoring keystrokes (`macos-auto-secure-input`, on by default).
- New: the terminal bell works. `\a` requests Dock attention by default; `bell-features` configures a system beep or a custom sound (`bell-audio-path`, `bell-audio-volume`).
- New: desktop notifications from terminal programs (OSC 9/777) — a system banner when the tab isn't visible, and every notification lands in kooky's notification inbox either way.
- New: `mouse-hide-while-typing` — the pointer disappears while you type, reappears on movement.
- New: middle-click pastes, through the same protected paste path as ⌘V.
- New: `focus-follows-mouse` — with splits open, hovering any part of a pane moves keyboard focus there without a click. Hovering never steals the caret from the composer or search field.
- New: terminal programs get the right light/dark answer (CSI ?996n queries, mode 2031 reports) — nvim/delta-style auto theming follows your kooky theme, and `theme = light:X,dark:Y` conditional themes in an inherited ghostty config resolve correctly.
- New: window translucency without Liquid Glass — `background-opacity` takes effect with liquid-glass or a numeric `background-blur` (the traditional frosted look, any macOS), and Settings → appearance gains a background-opacity slider.
- New: `confirm-close-surface` — opt in and closing a tab with a running process asks first. Off by default: agent tabs are long-running by nature.
- New: link previews — ⌘-hover a URL (or an OSC 8 hyperlink) and a badge shows the full target, revealing where "click me" text really points.
- Fixed: switching macOS input sources refreshes the terminal's keyboard mapping immediately, so Option-as-Alt stays correct after a layout change.

## v0.45.10 — 2026-07-29

- New: terminal programs get the right light/dark answer. kooky reports its active theme's appearance to the terminal (CSI ?996n queries, mode 2031 reports), so nvim/delta-style auto theming follows your kooky theme — and `theme = light:X,dark:Y` conditional themes in an inherited ghostty config resolve correctly.
- New: window translucency without Liquid Glass. `background-opacity` takes effect when paired with a frosting layer — liquid-glass or a numeric `background-blur` (the traditional frosted look, works on any macOS). Bare opacity with no frosting stays opaque by design. Settings → appearance gains a background-opacity slider that shows and can override an inherited value.
- New: `confirm-close-surface` — opt in and closing a tab with a running process (vim, a build, an agent) asks first, in kooky's own confirm sheet. Off by default: agent tabs are long-running by nature and shouldn't tax ⌘W.

## v0.45.9 — 2026-07-29

- New: the terminal bell works. `\a` requests Dock attention by default; `bell-features` configures a system beep or a custom sound file (`bell-audio-path`, `bell-audio-volume`).
- New: desktop notifications from terminal programs (OSC 9/777, `printf '\e]9;done\a'`) — a system banner when the tab isn't visible, and every notification lands in kooky's notification inbox either way. Kooky's master notification toggle is respected.
- New: `mouse-hide-while-typing` — the pointer disappears while you type, reappears on movement.
- New: middle-click pastes, through the same protected paste path as ⌘V.
- New: `focus-follows-mouse` — with splits open, hovering any part of a pane (terminal, tab bar, status bar) moves keyboard focus there without a click. Hovering never steals the caret while you're typing in the composer or search field.

## v0.45.8 — 2026-07-29

- New: paste protection. Pasting text that could run commands the moment it lands (multi-line content outside bracketed-paste framing) now shows a confirmation with a content preview first (`clipboard-paste-protection`, on by default). ⌘W / Esc cancel; file, image, and SSH-upload pastes are unaffected.
- New: OSC 52 clipboard support, guarded — remote programs (tmux, nvim over SSH) can read your clipboard after you approve it, and `clipboard-write = ask` asks before a program replaces your clipboard.
- New: secure keyboard input at password prompts — typing a sudo/ssh password now blocks other processes from monitoring keystrokes (`macos-auto-secure-input`, on by default).
- Fixed: switching macOS input sources now refreshes the terminal's keyboard mapping immediately, so Option-as-Alt stays correct after a layout change.

## v0.45.7 — 2026-07-29

- Fixed: `macos-option-as-alt` now works. Set it under `terminal` in settings.json (`true` / `false` / `"left"` / `"right"`) to send Option+letter to terminal programs as Alt/ESC sequences (zellij, tmux, emacs bindings); with `"left"`, the right Option keeps typing macOS special characters. When unset, kooky keeps the macOS-native behavior — Option types special characters — instead of inheriting ghostty's per-keyboard-layout guess. (#46)

## v0.45.6 — 2026-07-29

- Fixed: new tabs opening as a bare shell — no aliases, no PATH, no prompt theme — after kooky ran for a few days. macOS periodically deletes temp files it considers stale, taking kooky's zsh/bash shell-integration bridge with it, and kooky never rebuilt it until the app was restarted. The bridge is now recreated on the spot whenever a terminal spawns; if that ever fails, new shells load your own config directly instead of pointing at a dead path. (#45)

## v0.45.5 — 2026-07-28

- Fixed: clicking a split pane now focuses it. Clicking anywhere in a pane — terminal content, its tab bar, or its status bar — moves keyboard focus there. Previously focus only moved via ⌘[/⌘] or tab switches, and with Liquid Glass enabled, clicks on the original pane after a split were swallowed entirely by the glass layer. Clicks that land in the search bar or the prompt composer keep their caret where you clicked.

## v0.45.4 — 2026-07-28

Performance round 2 — paste, file tree, and launch-path waste.

- Fixed: pasting a large screenshot froze the terminal for up to a second while it transcoded. The conversion now runs off the main thread and the path pastes when ready — ⌘V, right-click Paste, and the composer all covered, with a fallback to the clipboard's text when the image can't be converted.
- Faster: expanding a huge directory (10k+ entries) in the sidebar file tree no longer stalls the UI — the row opens instantly and its contents appear the moment the listing lands (measured: a 10k-entry folder used to block for ~235ms).
- Faster: resuming Codex tabs no longer re-walks the entire session history on every retry, so launch cost stops growing with months of Codex usage; steady-state launches skip rewriting ~30 unchanged config files; and the menu-bar agent counter stops re-rendering on every terminal title change.

## v0.45.3 — 2026-07-28

Performance round — a deep audit plus adversarial review, no new features.

- Fixed: a native memory leak in the terminal engine — every settings change and each system light/dark switch permanently leaked engine configuration memory, so long-lived instances grew forever. Settings changes also no longer run a redundant second per-pane update pass.
- Faster: tabs open in the same repository now share one git watcher — a commit refreshes all of them with a single git call instead of a burst of dozens of subprocesses, and fish users no longer pay a doubled git refresh on every prompt.
- Fixed: creating or removing a worktree could freeze the UI for seconds on slow filesystems and stall on very large git output; both now run fully off the main thread with reliable output handling.

## v0.45.2 — 2026-07-28

- Fixed: select-to-copy now works for everyone. kooky inherits your Ghostty config, so a `copy-on-select = false` there silently disabled it — text highlighted on selection but never reached the clipboard. (#32)
- New: Settings → General → Clipboard gains a `copy-on-select` toggle for turning it off deliberately.

## v0.45.1 — 2026-07-27

- New: Session history now covers thirteen agents — Pi, Oh My Pi, Kimi Code, OpenCode, Grok Build, Cursor CLI, Copilot CLI, Kiro CLI, Gemini CLI, Droid, and Reasonix join Claude Code and Codex. Each store is read in its agent's own on-disk format, and conversations started outside kooky appear too. Amp stores threads server-side and can't join; Antigravity is pending format verification.
- Fixed: Copilot CLI conversation resume — the CLI ships resume-by-id as `--resume=<id>`, not the `--session-id` flag kooky passed, so resumed Copilot tabs silently started fresh. History clicks and relaunch resume both work now.
- Fixed: the History pane keeps its agent filter and search text when the panel is collapsed or its mode is cycled — they no longer reset to "all".
- Faster: history scans read all stores in parallel and each Codex rollout once — a full scan of ~200 real conversations dropped from roughly half a second to ~0.15s, always off the main thread.

## v0.45.0 — 2026-07-27

- New: **Session history** — flip the agent panel to its second page (the clock at the bottom) to browse every Claude Code and Codex conversation on your Mac, newest first, including ones started outside kooky. Search by title or project, filter by agent, and click a row to pick the conversation back up: a new tab opens in the conversation's own folder and resumes it with the agent's exact session ID.
- Polish: the agent panel's top-bar toggle now uses the right-sidebar icon, mirroring the left sidebar's button.

## v0.44.0 — 2026-07-27

- New: an optional Kooky item in the macOS menu bar mirrors the live agent list across every window. The count appears only while agents are present; open the menu to see each tab title and project path on two lines, then pick one to jump straight to it.
- Convenience: the same menu provides Open Kooky, Settings, Keep Awake (Off / Auto / Always), and Quit. Turn the item on or off under Settings → General → `show-in-menu-bar`.

## v0.43.1 — 2026-07-27

- New: 28 additional MIT-licensed open-source terminal palettes — including Ayu, Catppuccin, Everforest, GitHub, Gruvbox, Material, Night Owl, Nord, One Dark Pro, and Rosé Pine Moon — bring the built-in collection to more than 40 themes. Attribution is included in `NOTICE.md`.
- Polish: Light and Dark theme menus are sorted alphabetically and use the clearer **Built-in** / **Custom** section labels.
- Compatibility: built-in selections now use an explicit `kooky:` namespace. Existing unprefixed values prefer a matching file in `~/.config/ghostty/themes` before falling back to an old built-in id, so adding a same-named built-in theme cannot silently replace a user's colors after upgrading.

## v0.43.0 — 2026-07-26

- New: Appearance now keeps two independent terminal palettes — one for Light and one for Dark — while System / Light / Dark is a separate mode. System follows macOS live, switching both the terminal and the whole window without reopening Settings.
- New: **Ghostty Dark** preserves the former zero-config Ghostty colours as an explicit bundled dark theme. Theme files in `~/.config/ghostty/themes` remain available and are placed in the Light or Dark picker from their background colour.
- Compatibility: upgrading users who left the old **Default** selected keep inheriting their existing Ghostty configuration until they choose a theme in Appearance. An explicitly selected legacy theme migrates to the matching Light or Dark slot instead of being overwritten.
- Fixed: switching Light → System, or changing macOS appearance while System is selected, no longer leaves chrome and terminal colours out of sync or produces a mixed pale-grey theme.

## v0.42.0 — 2026-07-26

- New: Oh My Pi (`omp`) joins the built-in agents — a fork of Pi that adds LSP, a real debugger, and subagents. Fully wired: the sidebar dot tracks whether it's working or waiting on you, the status bar shows the tool it's running right now, and conversations resume after a kooky restart.
- New: Reasonix (`reasonix`) joins the built-in agents — a DeepSeek-native coding agent. Same full support: activity dot, tool-call pill, and conversation resume.
- New: the sidebar dot now shows when Oh My Pi is waiting for you to approve a tool. It previously stayed on "working" for the whole approval prompt, so nothing told you it needed an answer.

## v0.41.1 — 2026-07-26

- Fixed: the Keep Awake status light no longer animates non-stop. It now pulses twice when you change the setting and then stays lit. Anything that keeps changing on screen — however few pixels it covers — holds the whole display at its full refresh rate, which showed up as high WindowServer CPU and battery drain on an otherwise idle terminal. (#39)

## v0.41.0 — 2026-07-26

- New: colour-tag a workspace to tell it apart at a glance. Right-click any workspace in the sidebar and pick one of seven colours, or **Custom Tag…** for your own colour and a name; the tag shows as a stripe down the left edge of the row in both sidebar widths. Click the colour it already has to clear it. (#43)
- New: tagged workspaces carry their colour into the agent panel too, so every agent belonging to one project reads as a group in a list that's otherwise sorted by who needs you first. Turn it off under Settings → Appearance → `show-agent-panel-tag`.
- Changed: a named tag appears as `#name` when you hover the workspace, alongside the title and location.

## v0.40.1 — 2026-07-25

- New: hovering a workspace in the sidebar now shows its title above its location, so several workspaces running the same agent — which look identical when the sidebar is narrowed to icons — can be told apart without opening them. Workspaces running more than one agent list which ones, and worktrees show their branch alongside the folder they live in. (#43)
- New: the agent panel shows hover text when expanded, not just when collapsed, and each row now leads with what the agent is working on instead of repeating the agent's name. Rows for an agent working over SSH name the remote host rather than the local folder the connection started from.
- Changed: tooltips throughout kooky appear after half a second instead of the system's much longer delay.

## v0.40.0 — 2026-07-25

- New: custom agents can use your own logo. Settings → Agents → expand a custom agent → **icon** → choose a PNG, JPEG, or SVG (64×64 or larger recommended). The icon shows up on tabs, the sidebar, the agent panel, Quick Open, and notifications. Clear it to fall back to the "based on" agent's mark. (#40)
- Fixed: clicking near the edge of the `choose` button in Settings → Terminals did nothing; the whole button is now clickable.

## v0.39.1 — 2026-07-24

- Fixed: ⌘W pressed while Settings, About, or another auxiliary window is in front now closes that window itself — panels and dialogs dismiss — instead of closing a terminal tab hidden behind it. ⌘⇧W no longer closes a hidden workspace either. (#38)

## v0.39.0 — 2026-07-23

- New: ⌘-click a file path printed in the terminal to open the underlying local file, including common `path:line[:column]` and `path#Lline[Ccolumn]` spellings. File links can use a preferred editor and web links a preferred browser under Settings → General → Open With; both fall back to the macOS default.
- Safety: file links are suppressed inside SSH / mosh sessions so a remote path can never accidentally open a same-named local file, while ordinary web links remain openable.
- Polish: Settings now uses clearer 18 pt subsection headings. The search-pill toggle moved to Appearance → Window Chrome, with the old `general.showSearchPill` setting migrated automatically.

## v0.38.0 — 2026-07-23

- New: automatic conversation resume now works across all 13 built-in AI agents. Codex, Gemini CLI, OpenCode, Amp, Cursor CLI, Copilot CLI, Grok Build, Antigravity CLI, Kimi Code, Kiro CLI, and Droid join Claude Code and Pi; each agent reopens with its own native session ID and resume command after restarting kooky.
- Fixed: OpenCode child-agent sessions can no longer replace the root conversation's resume ID, and restored Codex sessions reconnect their usage gauge to the original rollout.

## v0.37.6 — 2026-07-23

- Fixed: Pi conversations now resume reliably after reopening kooky — canonical session UUIDs are saved instead of timestamped transcript filenames, legacy IDs are migrated, and non-persistent Pi / Claude sessions are no longer recorded as resumable. (#37)

## v0.37.5 — 2026-07-23

- Fixed: the Keep Awake breathing light no longer drives full-window SwiftUI layout every frame; it now uses a compositor-backed Core Animation layer, preventing excessive idle CPU usage. (#35)

## v0.37.4 — 2026-07-23

- Fixed: Quick Open search pill overlap at narrow window widths, including compact and hidden sidebar states. (#36)

## v0.37.3 — 2026-07-21

- New: click the git diff pill (±) in the status bar to see which files changed — one row per file with its own +/− line counts, adding up to the totals on the pill. A "Show in File Tree" shortcut at the bottom jumps to the file tree, where changed files carry the same badges.
- Fixed: status bar pill menus (Node version, git branch, git repo, proxy) could open blank or show "No … found" even when the data existed — most visibly on macOS 26.5, where an affected menu could stay stuck that way permanently. Menus now display their content reliably every time they open.

## v0.37.2 — 2026-07-20

- Fixed: clicking the Node version, git branch, or git repo pill in the status bar could show a wrong empty menu ("No nvm versions found" / "No remote configured") even when versions, branches, or a remote existed. The menu now loads its list reliably every time it opens.

## v0.37.1 — 2026-07-19

- Fixed: programs running inside kooky that ask for macOS privacy-protected data — Calendars, Reminders, Contacts, Photos, Apple Events, local network, and more — now get the system permission prompt, and kooky appears under System Settings → Privacy & Security. Previously these requests were silently denied with no way to grant access. (#31)

## v0.37.0 — 2026-07-19

- New: git repo in the status bar — the pane status bar now shows the active tab's repository name. Click it to open the repo on GitHub (GitLab / Bitbucket and self-hosted instances are recognized too), copy the repo URL, or reveal the repo folder in Finder.
- The slot sits next to the git branch and can be reordered or hidden in Settings → Status Bar like every other slot.

## v0.36.0 — 2026-07-17

- New: keep-awake — kooky can stop your Mac from sleeping while work is running. A breathing status light sits at the top right; click it to cycle Off → Auto → Always (also in Settings → General).
- Auto keeps the Mac awake while an agent is working or an SSH session is connected — lid closed included, after a one-time admin authorization — and lets it sleep normally again the moment the work ends.
- Always keeps the Mac awake unconditionally until you switch it down, like a caffeinate you can see.
- Changes made outside kooky stay in sync: turning sleep-disable on in any terminal shows up as Always within seconds, turning it off externally switches the dial off.
- Fixed: an SSH session's remote-login state (status bar host, keep-awake) no longer drops after the first remote command finishes on hosts with their own shell integration.

## v0.35.0 — 2026-07-10

- New: recent project folders — kooky now remembers every folder you open a workspace on. Reopen one from File → Open Recent, or press ⌘P and type the project's name: folders you've closed show up as "recent" entries and reopen with a single Enter. (#28)
- The list keeps the 20 most recent folders with no setup: deleted folders hide automatically (and come back if the volume remounts), and worktree or SSH workspace directories are never recorded.

## v0.34.0 — 2026-07-10

- New: SSH workspaces — File → New SSH Workspace… (also in ⌘P) creates a workspace that lives on a remote machine: every new tab, split, and restored tab connects to the same host automatically.
- Agent tabs in an SSH workspace start their agent on the remote, with the remote's own shell setup loaded — so tools installed through nvm and friends are found.
- Pasting a local file or screenshot into an SSH workspace uploads it to the remote first and pastes the remote path, so an agent on the other side can actually open it. Uploads run in the background; a failed transfer beeps instead of pasting a dead local path.
- Connections to the same host are shared: extra tabs connect instantly, and password-authenticated workspaces can paste files too.
- SSH workspaces carry a network badge and their host in the sidebar; the new-tab menu labels entries "on SSH".

## v0.33.0 — 2026-07-10

- New: git changes show in the file tree — a modified file's row carries its `+X −Y` line counts (same numbers and colors as the status bar's diff, and they add up to its totals); a collapsed folder rolls up its subtree's changes.
- New: the sidebar is resizable — drag its right edge to widen it (the default width is the minimum), per-window width persists across restarts.
- Fixed: switching the sidebar from compact to hidden no longer flashes it at full width during the transition.
- Fixed: reading large git output (thousands of changed files or branches) could silently stall and drop the result — git output is now streamed while the command runs.

## v0.32.0 — 2026-07-08

- New: sidebar file tree — a toggle at the bottom of the sidebar switches between the workspace list and a file tree of the active workspace's folder. Expand directories, double-click to open a file, right-click for Open / Reveal in Finder / Copy Path / Insert Path into Terminal.
- Drag a file or folder from the tree into the terminal to insert its path — same as dragging from Finder.
- The tree follows the active tab's directory and refreshes live as files change on disk; symlinked project folders are supported.

## v0.31.6 — 2026-07-07

- Fixed: every modifier key press (Shift / Cmd / Option) triggered an internal AppKit exception — invisible in normal use, but undefined behavior that could corrupt a long-lived session, and the prime suspect for rare "app suddenly quits" crashes.
- New: crash black box — if kooky ever dies unexpectedly, its last words are saved to ~/Library/Logs/kooky/stderr.log so the cause can be diagnosed instead of lost.

## v0.31.5 — 2026-07-01

- Fixed: showing or hiding the sidebar or agent panel no longer flickers the terminal while it resizes. (#29)

## v0.31.4 — 2026-07-01

- Fixed: dragging a split divider to resize panes no longer flickers the prompt or clears scrollback on every frame — the resize fix now covers split dividers too, not just the window edge. (#29)

## v0.31.3 — 2026-07-01

- Fixed: resizing the window by dragging its edge no longer flickers the prompt or clears scrollback on every frame — the terminal now reflows once when you release the drag. (#29)

## v0.31.2 — 2026-06-30

- Performance: trims redundant per-prompt work — kooky skips re-detecting the project environment and re-saving state on shell prompts that don't change directory (git status and live change-tracking still refresh every prompt).

## v0.31.1 — 2026-06-30

- Fixed: scrolling Claude Code / Codex no longer stutters or tears on high-refresh (ProMotion / 120Hz) displays — rendering is now synced to the screen's refresh rate. (#29)

## v0.31.0 — 2026-06-29

- Status-bar icons refreshed: the Node version slot now shows a hexagon (Node's logo) and the git diff slot a ± symbol, for clearer glyphs at a glance.

## v0.30.0 — 2026-06-29

- New: Codex usage gauge — a Codex tab's status bar now shows how much of your 5-hour and weekly rate-limit windows are left (matching the Codex client), turning amber then red as you run low. Click it for the reset countdowns, your plan, and current context-window usage. Toggle it under Settings → Status Bar → Codex.

## v0.29.1 — 2026-06-29

- Settings reorganized: theme, font, cursor, and Liquid Glass moved into a new "Appearance" section, and the rest regrouped so each section does one thing.

## v0.29.0 — 2026-06-29

- New: "Open in" — a top-bar button opens the current tab's folder in your editor, terminal, or Finder. Click the icon to reopen in your last-used app, or the chevron to pick from any supported app installed on your Mac (VS Code, Cursor, Zed, iTerm, Ghostty, and more). Reorder or hide them under Settings → Open in.

## v0.28.2 — 2026-06-26

- New: Liquid Glass on macOS 26 — kooky's windows can take on the system's translucent glass material. Turn it on in Settings → General → liquid-glass (Regular or Clear). (#26)

## v0.28.1 — 2026-06-24

- New: six more built-in themes — Tokyo Night / Tokyo Day, Gruvbox Dark / Gruvbox Light, One Dark / One Light. The theme picker now groups choices by Dark and Light.

## v0.28.0 — 2026-06-24

- New: Droid (Factory.ai's coding CLI) is now a built-in agent — pick it from the `+` menu, and a manually-typed `droid` lights up the sidebar like the others.

## v0.27.0 — 2026-06-24

- New: fish shell support — fish users now get the same integration as zsh and bash (manually-typed agents light up the sidebar, cwd tracking, status-bar slots, one-click agent launch), and it keeps working alongside shell autocomplete tools like Fig / Amazon Q / kiro.
- Fixed: typing `gemini` by hand now lights its icon immediately, like every other agent.

## v0.26.8 — 2026-06-15

- Fixed: switching workspaces now keeps keyboard focus on the pane you left it on, instead of jumping to the last split pane (#24).

## v0.26.7 — 2026-06-15

- Fixed: the elapsed time on the Claude Code / Pi tool-call pill (and its popover) now shows hours and days for long spans — e.g. `2d 2:00:00` instead of a giant raw minute count like `3000:00`.

## v0.26.6 — 2026-06-15

- Fixed: an agent another tool launches in the background — e.g. `codex:review` running inside Claude Code in a kooky tab — no longer hangs. kooky's agent wrapper now steps aside for background, tool-driven calls instead of trying to report their status.

## v0.26.5 — 2026-06-09

- New: a "Remote Login" status-bar slot shows the `user@host` you're SSHed into. Toggle it in Settings → Status Bar (needs "remote agent detection" on under Settings → SSH).

## v0.26.4 — 2026-06-09

- New: hide the top-bar search box if you don't want it — Settings → General → "top bar search". ⌘P still opens search either way.

## v0.26.3 — 2026-06-09

- Polish: selected and hover states read more clearly now — stronger contrast on the active tab, workspace, buttons, and Settings rows, in both light and dark themes.

## v0.26.2 — 2026-06-09

- Polish: tidied up a handful of mismatched button-icon and input-field sizes across the sidebar, tab bar, and Settings so same-kind controls line up.

## v0.26.1 — 2026-06-09

- Pasting a file or image into the prompt composer now inserts its full path (same as ⌘V in the terminal), not just the filename.

## v0.26.0 — 2026-06-08

- **Prompt composer (⌘L)** — a chat-style box that rises from the bottom of the pane for writing long, multi-line prompts without a stray Return firing them off mid-thought. Return sends to the current agent (or shell), Shift+Return adds a newline, Esc cancels and keeps your draft. Open it with ⌘L or the compose button in the pane status bar.

## v0.25.0 — 2026-06-04

- **Agent panel** — a right-side sidebar (top-bar toggle, three collapse states like the left one) listing every agent across all your windows, sorted by who needs you first: waiting on you, then failed, running, idle. Click a row to jump straight to that tab; compact mode shrinks it to a rail of status-tinted icons.

## v0.24.1 — 2026-06-03

- **Notification center** — a bell in the top bar (⇧⌘I) collects agent alerts from every window: who's waiting on you, what failed, what finished. A red dot marks unread; click any entry to jump straight to that tab.
- Looking at a tab clears its alerts — whether you open it, jump in from the inbox, or just switch back to kooky — so a notification you've already seen doesn't keep the bell lit.

## v0.24.0 — 2026-06-03

- **Notifications** — get a macOS notification when an agent in a hidden tab starts waiting on you, or a command there fails. Turn each kind on or off in Settings → Notifications.
- Fixed: the red "command failed" dot now clears the moment you start your next command (type, paste, or recall from history), instead of lingering until that command finishes — which never happened for a long-running one like an agent.

## v0.23.0 — 2026-06-02

- **Kiro CLI** — AWS's `kiro-cli` agent joins the launcher. Pick it from the `+` menu or set it as your default agent; the sidebar activity dot tracks when it's running.

## v0.22.6 — 2026-06-02

- Right-click the Dock icon to open a new window, or jump straight to any workspace or tab across all your open windows.
- Quick Open (⌘P) now pops a minimized window back open when you jump to a tab inside it, instead of leaving it tucked in the Dock.

## v0.22.5 — 2026-06-02

- Rename a tab with ⌘R and a workspace with ⌘⇧R — the rename field opens right where you're working, instead of only through the right-click menu (which now shows the shortcuts too).

## v0.22.4 — 2026-06-02

- Fixed terminal text overflowing the pane after switching workspaces and back, when kooky is on a non-Retina external monitor — a follow-up to the display-scale fix in v0.19.2. (Relates to #8.)

## v0.22.3 — 2026-06-01

- Fixed agent activity not updating when you launch an agent by typing its command (`claude` / `codex` / …) directly in the terminal — macOS had been silently killing the small helper kooky uses to detect it. Claude's hooks and the tool-call pill are restored too.

## v0.22.2 — 2026-06-01

- Split a pane straight from its tab bar — two buttons on the right (split right / split down) do the same thing as ⌘D / ⌘⇧D, so splitting is right there instead of behind a shortcut.

## v0.22.1 — 2026-06-01

- Pi sessions now show the tool Pi is running right now in the pane status bar (`bash` / `read` / `edit` / etc.) with elapsed time — click the pill for the full session history, the same readout Claude Code already had.
- Settings → Status Bar lets you show or hide the tool-call pill per agent, so Claude Code and Pi toggle independently.

## v0.22.0 — 2026-06-01

- **Pi** — Earendil's `pi` coding agent ([pi.dev](https://pi.dev)) joins the launcher. Pick it from the `+` menu or set it as your default agent; the sidebar dot tracks when it's working and when it's waiting on you, and pi conversations resume across kooky restarts.

## v0.21.0 — 2026-06-01

- Remote agent detection over SSH (opt-in) — `ssh` into a machine from kooky and run an agent there (Claude, Codex, …), and the sidebar now shows that agent's icon and activity instead of treating the tab as a plain terminal. Turn it on in Settings → SSH. (Resolves #19.)

## v0.20.1 — 2026-05-30

- Agent icons now show on light themes — the monochrome marks (OpenCode, Cursor, Copilot, Grok, Kimi) were invisible on light color schemes and now adapt to the theme so they're visible everywhere.

## v0.20.0 — 2026-05-30

- **Kimi Code** — Moonshot AI's `kimi` CLI joins the agent launcher. Pick it from the `+` menu or set it as your default agent; the sidebar activity dot tracks when it's running.

## v0.19.3 — 2026-05-30

- **Custom Ghostty themes** — themes in your Ghostty themes folder now appear in Settings and recolor the terminal and whole window when selected. (Resolves #17.)

## v0.19.2 — 2026-05-29

- Fixed the layout breaking when you drag the window between displays with different scale factors (e.g. a Retina laptop screen and a 1x external monitor) — the terminal now re-flows to the new display's resolution instead of leaving a blank gutter on the right or letting input overflow the viewport. (Resolves #8.)

## v0.19.1 — 2026-05-29

- Fixed the terminal getting stuck mid-screen after a resize, fullscreen toggle, or the status bar appearing — when an agent like Claude Code is streaming output, the view now stays pinned to the latest output and the input box instead of stranding them below the fold. Scroll up to read history and it stays where you left it. (Resolves #7.)

## v0.19.0 — 2026-05-28

- Watch Claude Code work in real time — kooky now shows a pill in the bottom status bar with the tool Claude is running (Bash / Edit / Read / etc.), how long it's been running, and whether it succeeded or failed. Click the pill to see the full session history.
- Failed tool calls turn red immediately, not after a 60-second wait.
- Settings → Status Bar gets a Claude Code section with a toggle for the activity pill.

## v0.18.3 — 2026-05-28

- Worktree close is safe by default — closing a worktree now only removes it from the sidebar; the directory and branch stay on disk. Tick "also delete worktree directory and branch" in the confirm sheet for the v0.18.x destructive behaviour.
- Adopt existing worktrees — Create Worktree → "adopt" mode lists every `git worktree list` entry not already in the sidebar. Pick the ones you want kooky to manage.
- Kooky no longer auto-imports CLI-created worktrees at launch. Only worktrees you explicitly created or adopted show up in the sidebar.

## v0.18.2 — 2026-05-27

- Paste a file or image — copy a file in Finder (Cmd+C) and Cmd+V into kooky now pastes the full file path instead of just the filename, so Claude / Codex / Cursor can read it as an argument.
- Paste a screenshot — take a screenshot to the clipboard (Cmd+Ctrl+Shift+4), Cmd+V into kooky, and the image gets saved to `~/Library/Caches/kooky/pastes/` with its path pasted into the terminal. Drop a screenshot straight into a Claude prompt with no save-to-disk detour. (Resolves #15.)

## v0.18.1 — 2026-05-27

- Worktree sidebar polish — worktree rows now show a branch badge in their subtitle, source rows reveal a hover-only chevron for collapsing the worktree group, and the disclosure no longer steals a leading column from the (already narrow) sidebar.
- Right-click a worktree → "Go to Source Workspace" jumps back to the source repo. Right-click a source → "Refresh Worktrees" picks up worktrees you created in another terminal without restarting kooky.
- Closing a worktree now also cleans up its branch — `git branch -d` runs after `git worktree remove`. Merged branches go away (next worktree of the same name builds cleanly); unmerged branches stay (git itself refuses, no data loss). Reads the worktree's real current branch from git at delete time, so `git switch`ing inside the worktree no longer leaves the wrong branch behind.
- "Create Worktree…" sheet opens noticeably faster (git enumeration runs in parallel), and the existing-branch picker hides itself when every local branch is already checked out somewhere.
- Worktrees you created from the command line now spawn with your default agent (the one you picked in Settings → Agents) instead of a plain Terminal.

## v0.18.0 — 2026-05-26

- **Git worktrees** — right-click a git workspace → "Create Worktree…" to spin one up on a new branch (or check out an existing one). Each worktree gets its own sidebar entry nested under its source repo, its own tabs, and its own agent — work on a feature branch with Claude without touching what's running on main. Closing a worktree deletes the directory; closing a source repo removes its whole worktree group in one confirm. Worktrees you create from the command line show up automatically next launch.

## v0.17.0 — 2026-05-26

- **Theme picker** — choose a theme in Settings. Theme changes apply immediately across the terminal and the whole window.

## v0.16.3 — 2026-05-25

- **Pane zoom (⌘⇧E)** — expand the active pane to fill the workspace; the other panes slide off-screen but their processes keep running. Toggle from ⌘⇧E, the zoom button in each pane's bottom status bar, the View menu, or right-click → "Zoom Pane".

## v0.16.2 — 2026-05-25

- **Settings → Status Bar** — drag to reorder the pane bottom status bar's slots (Python venv / Node version / Proxy / Git branch / Git diff), toggle individual ones off, or hide the whole row. Reset to defaults if you change your mind.

## v0.16.1 — 2026-05-25

- Fixed the Quick Open search pill overlapping the sidebar toggle when the window was dragged narrow. The pill now stays in the drag-handle area and hides automatically when there isn't room for it — ⌘P and the File menu still open the palette.

## v0.16.0 — 2026-05-25

- **Quick Open (⌘P)** — fuzzy-search across every window's workspaces and tabs, plus every visible agent and Terminal preset. Type to filter, ↑↓ to navigate, Enter to jump; clicking a workspace or tab focuses its owning window, picking an agent or preset spawns a new tab with it. Triggers from ⌘P or the search pill in the top chrome.

## v0.15.0 — 2026-05-25

- **Terminal presets** — define "Terminal at <path>" entries that show up in the `+` menu, each opening a new tab at a fixed folder regardless of the active workspace. Configure under Settings → Terminals: name + path (with `~/foo` shorthand or a folder picker), drag to reorder, toggle visibility, delete. Handy when you keep jumping to the same project folders.
- Settings sidebar reorganized — first category renamed `General` (was `Terminal`) to make room for the new `Terminals` category in between. The `default-new-tab` picker moved to `General` since it now controls both presets and agents.

## v0.14.4 — 2026-05-24

- File → Open Folder… (⌘O) opens any folder as a new workspace.

## v0.14.3 — 2026-05-23

- Drag a folder from Finder onto the sidebar to open it as a new workspace.

## v0.14.2 — 2026-05-23

- Right-click any tab → "Move to New Window" sends it to its own new window — the terminal, scrollback, and any running process all come along.

## v0.14.1 — 2026-05-22

- Drag a tab from one window's tab bar onto another window's to move it across — the terminal, its scrollback, and any running process all come with it.

## v0.14.0 — 2026-05-22

- Multiple windows — press ⌘⇧N to open a new window. Each window keeps its own workspaces, tabs, and sidebar, and every open window is restored when you relaunch kooky.

## v0.13.0 — 2026-05-22

- Custom agents based on Claude Code can now carry their own environment variables — set `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` in a custom agent's new `env` field (Settings → Agents) to point it at a Claude-compatible mirror or proxy.

## v0.12.4 — 2026-05-21

- Fixed: arrow keys in `vim` (and other full-screen programs) now work over SSH to older remote machines.

## v0.12.3 — 2026-05-21

- The tab and sidebar name now follow the terminal title — `ssh` into a remote host and the tab shows its `user@host` instead of the local folder, then reverts when you exit.

## v0.12.2 — 2026-05-20

- Antigravity CLI joins the agent menu — Google's Go-based successor to Gemini CLI.
- Fixed: picking Antigravity from the `+` menu when only the IDE is installed now surfaces a clear CLI install hint instead of accidentally opening the IDE app.

## v0.12.1 — 2026-05-19

- Check for Updates in the Kooky menu — see what's new and download the latest DMG in one click.

## v0.12.0 — 2026-05-19

- Grok Build (xAI) joins the agent menu.

## v0.11.6 — 2026-05-18

- Fixed: shell history and Tab completion now survive kooky restarts.
- Fixed: environment variables in `~/.zshenv`, `~/.zprofile`, and `~/.bash_profile` now load in kooky terminals.

## v0.11.5 — 2026-05-18

- Fixed: long Chinese / Japanese / Korean inputs no longer leave a phantom space mid-line.
- Fixed: when a long input wraps to a second line, the first line no longer disappears.

## v0.11.4 — 2026-05-18

- Fixed: Chinese / Japanese / Korean IME candidate window now shows right under the cursor instead of flying off-screen.

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
