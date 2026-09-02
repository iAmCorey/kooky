# kooky

[![License](https://img.shields.io/github/license/iAmCorey/kooky?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-007AFF?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/iAmCorey/kooky/total?style=flat-square)](https://github.com/iAmCorey/kooky/releases)
[![Stars](https://img.shields.io/github/stars/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/stargazers)

> *A minimal modern terminal for AI coding.*

🇬🇧 English  ·  🇨🇳 [中文](README_CN.md)  ·  🇯🇵 [日本語](README_JA.md)

![kooky](img/screenshot-1.png)

A minimal modern terminal built for AI coding. Sidebar workspaces; horizontal / vertical split panes; one-click agent launch; per-agent activity readout; live workspace state with one-click Node and branch switching. Open-source, MIT-licensed. No accounts, no telemetry; app state stays local. GPU rendering via [libghostty](https://github.com/ghostty-org/ghostty).

**[Download latest](https://github.com/iAmCorey/kooky/releases/latest)**  ·  [Changelog](CHANGELOG.md)

---

## Features

**Vertical tabs, split panes & windows.** Sidebar workspaces with three-state collapse (`⌘⌃S`); drag the sidebar's right edge to widen it, and the width sticks per window. Each pane owns its own tab strip and active tab; split it right or down from the two buttons on its tab bar, or with ⌘D / ⌘⇧D. Rename a tab with ⌘R, a workspace with ⌘⇧R. `⌘⇧N` opens another window. Drag a tab to reorder it, move it across panes, or drop it into a different window — the live session moves whole, scrollback and running process intact. State persists across launches; every open window is restored. Open any folder as a new workspace: drop it onto the sidebar from Finder, or use ⌘O. Press `⌘⇧E` to zoom the active pane to fullscreen and back — the other panes slide off-screen but their processes keep running.

![Vertical tabs on the left, one pane split into four](img/screenshot-2.png)

**Tell your workspaces apart.** Right-click a workspace and give it a colour — seven presets, or **Custom Tag…** for your own colour plus a name. It shows as a stripe down the left edge of the row, in both sidebar widths, and clicking the colour it already has clears it. Tags carry into the agent panel too, so every agent in one project reads as a group in a list otherwise sorted by who needs you first (switch that off under Settings → Appearance). Hovering a workspace shows its title, any `#tag`, which agents are running, and where it lives.

**One-click AI agent sessions.** Pick one from the `+` menu; the agent boots before your first prompt prints. All fifteen resume their conversation across kooky restarts using each CLI's exact session ID, so closing and reopening a tab picks up where you left off.

| Agent | Command | Waiting dot | Tool pill | Session history |
| --- | --- | :---: | :---: | :---: |
| Claude Code | `claude` | ✓ | ✓ | ✓ |
| Codex | `codex` | ✓ | ✗ | ✓ |
| Gemini CLI | `gemini` | ✓ | ✗ | ✓ |
| OpenCode | `opencode` | ✓ | ✗ | ✓ |
| Amp | `amp` | ✓ | ✗ | ✗ |
| Cursor CLI | `cursor-agent` | ✓ | ✗ | ✓ |
| Copilot CLI | `copilot` | ✓ | ✗ | ✓ |
| Grok Build | `grok` | ✗ | ✗ | ✓ |
| Antigravity CLI | `agy` | ✓ | ✗ | ✗ |
| Kimi Code | `kimi` | ✓ | ✗ | ✓ |
| Pi | `pi` | ✓ | ✓ | ✓ |
| Oh My Pi (new) | `omp` | ✓ | ✓ | ✓ |
| Reasonix (new) | `reasonix` | ✓ | ✓ | ✓ |
| Kiro CLI | `kiro-cli` | ✗ | ✗ | ✓ |
| Droid | `droid` | ✓ | ✗ | ✓ |

**Waiting dot** turns amber the moment the agent stops and needs an answer, including a pending tool approval; Grok Build and Kiro CLI expose no such signal, so their dot only reports running and finished. **Tool pill** shows the tool running right now in the pane status bar. **Session history** marks the agents whose past conversations can be browsed and resumed from the agent panel's history page — see below. Hide any agent you don't use under Settings → Agents.

![Every supported agent, each toggleable in Settings](img/screenshot-4.png)

**Bring your own agent.** Not on that list? Add it in Settings → Agents: a name and a command is enough to put it in the `+` menu and launch it like any other tab. Base it on a built-in agent and it also inherits that agent's launch binary, brand mark, and activity tracking — the sidebar dot is reported by the built-in's wrapper, so a standalone command runs fine but stays dark. Either way you can upload your own logo (PNG, JPEG, or SVG; 64×64 recommended), and it shows up on tabs, the sidebar, the agent panel, and Quick Open. Claude-based entries can carry their own environment variables, so a mirror or proxy endpoint becomes a real agent instead of a shell alias.

**Git worktrees.** Right-click any git workspace → "Create Worktree…" to spin one up on a new branch (or check out an existing one). Each worktree shows up nested under its source repo in the sidebar with its own tabs + agent — let Claude work on a feature branch without touching what's running on main. To bring in a worktree you created from the command line, use the same sheet's adopt mode; sidebar entries whose directory is gone get cleaned up at launch.

**SSH workspaces.** File → New SSH Workspace… (or ⌘P) creates a workspace that lives on a remote machine: every new tab, split, and restored tab reconnects to the same host on its own. Agent tabs start their agent on the remote — with the remote's own shell setup loaded, so tools installed through nvm and friends are found. Paste a local file or screenshot and kooky uploads it first, then pastes a path the remote agent can actually open. Connections to the same host are shared: extra tabs attach instantly, and password-authenticated hosts work throughout, pasting included.

**Keep-awake.** Your Mac won't fall asleep under a working agent. A breathing status light in the top bar cycles three notches: Off; Auto — awake while an agent works or an SSH session is live, lid closed included (one-time admin authorization), asleep again the moment the work ends; and Always — a caffeinate you can see, awake until you switch it down. Flip sleep-disable anywhere else (`sudo pmset`, another tool) and the dial follows within seconds, in both directions.

**Recent projects.** kooky remembers every folder you open a workspace on — no setup, no manual adding. Reopen one from File → Open Recent, or press ⌘P and type the project's name: closed projects show up as "recent" entries and reopen with a single Enter. Deleted folders hide automatically, and worktree / SSH directories never clutter the list.

**Right-click a selection → "Ask <agent>".** Select an error / log line / file path, right-click, pick any agent — a new tab spawns with the selection already submitted as the first prompt. Zero ⌘C / ⌘V to go from "what is this" to an actual answer.

**Quick Open (⌘P).** Fuzzy-search across every window's workspaces, tabs, agents, Terminal presets, and recent project folders from one floating panel. Type to filter, ↑↓ to navigate, Enter to jump or spawn. Triggers from ⌘P or the search pill in the top chrome.

**Sidebar file tree.** A toggle at the bottom of the sidebar swaps the workspace list for a file tree of the active workspace's folder. Expand directories, double-click to open a file, right-click for Reveal in Finder / Copy Path / Insert Path into Terminal (file rows also get Open) — or just drag a file or folder straight into the terminal to insert its escaped path, same as a Finder drag. Changed files show their `+X −Y` line counts (the same numbers the status bar totals), and a collapsed folder rolls up its subtree's changes. The tree follows the active tab's directory (worktree workspaces stay pinned to their worktree folder) and refreshes live as files change on disk.

**Friction-free input.** Selecting text copies it to the clipboard the moment you release the mouse — no ⌘C needed, on every machine regardless of your Ghostty config (turn it off under Settings → General → Clipboard). Hold ⌘ and click a local file path such as `/path/file.swift:42` to open it in your preferred editor; web links can use a preferred browser (Settings → General → Open With). Hold ⌘ over any URL — or an OSC 8 hyperlink — and a badge reveals the full target before you click. Middle-click pastes. Click anywhere on the zsh prompt to move the shell cursor there (no modifier needed, same UX as ghostty.app). Drag a file or folder from Finder onto any pane to drop its escaped absolute path at the cursor. Prefer Option as Alt/Meta for zellij or Emacs bindings? Set `macos-option-as-alt` (`true` / `"left"` / `"right"`) in settings.json — unset keeps macOS-native special characters. With splits open, `focus-follows-mouse` moves keyboard focus to the pane under the pointer, and `mouse-hide-while-typing` hides the cursor while you type.

**Clipboard & input security.** Pasting text that could run commands the moment it lands — multi-line content outside bracketed-paste framing — shows a confirmation with a content preview first, so a booby-trapped `curl … | sh` copied from a webpage can't execute on ⌘V. Remote programs reading your clipboard over OSC 52 (tmux, nvim over SSH) need your approval first, and `clipboard-write = ask` guards writes the same way. While you type a sudo or ssh password, kooky holds macOS secure keyboard input so other processes can't monitor keystrokes.

**Prompt composer (⌘L).** A chat-style box rises from the bottom of the pane for writing a long, multi-line prompt without a stray Return firing it off mid-thought. Return sends it to the current agent (or shell), Shift+Return adds a newline, Esc cancels and keeps your draft. Open it with ⌘L or the compose button in the pane status bar.

**Agent activity readout.** Sidebar dot tracks each agent in real time — running (blue), waiting on you (amber), idle (none). Tab + workspace dots also turn red when the last command exited non-zero; hover for `exit N · 12.4s`. For the agents marked above, the pane status bar also shows the tool the agent is running right now (Bash / Edit / Read / etc.) and how long — click the pill for the full session history; failed calls turn red immediately. Toggle the pill per agent in Settings → Status Bar.

**Works with zsh, bash, and fish.** Manually-typed agent detection, cwd tracking, the status-bar slots, and one-click agent launch behave the same across all three shells — and keep working even alongside shell autocomplete tools like Fig / Amazon Q / kiro.

**Notifications.** When an agent in a tab you're not looking at starts waiting on you, or a command there fails, kooky posts a macOS notification — turn each kind on or off in Settings → Notifications. Terminal programs can post their own too (OSC 9/777, `printf '\e]9;done\a'`): they banner when the tab isn't visible and land in the inbox either way. The terminal bell (`\a`) requests Dock attention by default; `bell-features` adds a system beep or a custom sound. A bell in the top bar (⇧⌘I) keeps a running inbox of those alerts across every window — who's waiting, what failed, what finished — with a red dot when something's unread. Click an entry to jump straight to that tab; switching to a tab clears its alerts on its own.

![The notification center, collected across every window](img/screenshot-3.png)

**Agent panel.** A right-side sidebar — toggle in the top bar, three collapse states like the left one — lists every agent across all your windows at once, sorted by who needs you first: waiting on you, then failed, then running, then idle. Click any row to jump straight to that tab; compact mode shrinks it to a rail of status-tinted icons.

**Session history.** Flip the agent panel to its second page — the clock at the bottom — to browse past conversations from most of the built-in agents (see the table above), newest first, including ones started outside kooky. Search by title or project, filter by agent or narrow to the current workspace, and click a row to pick that conversation back up: a new tab opens in the conversation's own folder and resumes it with the agent's exact session ID.

![Search and resume any past Claude Code or Codex conversation](img/screenshot-5.webp)

**Session Info.** The agent panel's third page — the ⓘ at the bottom — inspects the active tab: workspace, directory, remote host, git branch / repo / diff, Python venv, Node version, proxy, a live process tree with CPU, memory, and listening ports, the last completed command with its exit code and duration (zsh/fish), and the terminal title. It's hands-on, too: hover a field to copy its full value, click a port to open it in your browser, right-click a process to copy its PID or end it, and a failed command in a local session grows an **Ask AI** button that hands the command, exit code, and directory to your agent in a new tab. Sections collapse and stay collapsed across restarts, everything updates live as you work, and command lines are kept in memory only — never written to disk.

**Menu bar agent glance.** An optional Kooky item in the macOS menu bar shows the live agent count only while agents are present. Open it to see every active agent tab with its project path, jump straight to one, open Kooky or Settings, change Keep Awake, or quit. Toggle it under Settings → General → `show-in-menu-bar`.

**Open in your editor or terminal.** A split button in the top bar hands the current tab's directory to another app. Click the icon to reopen in your last-used app, or the chevron to pick from any supported app installed on your Mac: VS Code · Cursor · Windsurf · Zed · Sublime Text · Antigravity · Trae · Kiro · Xcode · IntelliJ IDEA · PyCharm · WebStorm · Terminal · iTerm · Ghostty · Warp · Finder. Reorder or hide them under Settings → Open in.

**Live workspace state.** Pane status bar shows the git repo + branch + diff (`N files +X −Y`), Python venv, Node version, active proxy (`https_proxy` / `http_proxy` / `all_proxy`), and — when you SSH into a remote — the `user@host` you're logged into (turn it on under Settings → General). Auto-refreshes when an agent's Bash tool or another terminal switches branches. Click the Node or branch pill to switch versions / branches without typing; click the repo pill to open it on GitHub (GitLab / Bitbucket too), copy its URL, or reveal it in Finder; click the proxy pill to see and copy the full `name=value`.

**SwiftUI-native, minimal chrome.** Onest + JetBrains Mono. Custom About panel, native menus with shortcut hints, full IME support.

**Paired Light + Dark themes.** Pick a terminal palette for Light and another for Dark, then choose System / Light / Dark independently. System follows macOS live and switches both the terminal and the whole window. More than 40 built-in palettes include **Ghostty Dark**, Ayu, Catppuccin, Everforest, GitHub, Gruvbox, Material, Night Owl, Nord, Rosé Pine, and other open-source themes also available in Codex Desktop. Theme files in `~/.config/ghostty/themes` appear automatically in the matching Light or Dark picker. Built-in selections use a `kooky:` namespace, so a same-named custom Ghostty theme remains yours after upgrading. Upgrades also preserve the old Default behavior: if you never chose a theme, kooky keeps inheriting your Ghostty config until you change Appearance. Programs that ask "is this terminal dark?" (nvim's background autodetect, delta) get the answer from your active kooky theme, and `theme = light:X,dark:Y` conditional themes in an inherited Ghostty config resolve correctly.

**Configurable.** Settings (`⌘,`) also covers font, cursor, background opacity (pairs with liquid-glass or a numeric `background-blur` for the traditional frosted look on any macOS), default new-tab behavior, Terminal presets, agents, Open in, and the pane status bar. Opt into `confirm-close-surface` and closing a tab with a running process asks first. Appearance changes update every open window immediately.

**Deep links.** Other apps can reopen an agent conversation in kooky: `kooky://resume?agent=<agent>&id=<conversation-id>[&cwd=<path>]` jumps to the tab when the conversation is already open, otherwise resumes it in a new tab at its own project directory (`agent` takes the same ids as the History panel: `claude-code`, `codex`, `copilot`, `cursor`, `opencode`, `kiro`, `gemini`, …). The optional `cwd` lets links reach conversations older than the session scan keeps. Conversation ids are strictly validated and links can't carry prompts or commands; a refused link explains why in a sheet. Percent-encode spaces in `cwd` as `%20` (`+` is not decoded).

**Local by default.** No accounts, no telemetry, no cloud sync. Kooky keeps its own state on your device.

**libghostty-powered.** GPU-accelerated cell rendering, same engine as ghostty — synced to your display's refresh rate, so scrolling stays smooth and tear-free on 120Hz / ProMotion screens.

## CLI

`kooky-cli` drives a running kooky from scripts and other local apps — open a tab and run a command, resume an agent conversation, list / focus / close tabs:

```sh
kooky-cli open --cwd ~/Github/vibex -e "npx @deepseek-ai/dsh web"   # new tab: cd there, run the command
kooky-cli open --cwd ~/Github/vibex --agent claude-code             # new tab running an agent template
kooky-cli open --agent claude-code                                  # no --cwd: opens where the active workspace already is
kooky-cli open --agent preset-1                                     # a Terminal preset brings its own directory
kooky-cli open -e "npm run dev" --title "dev server" --no-focus     # named tab, opened in the background
kooky-cli resume --agent codex --id <conversation-id>               # same semantics as kooky://resume
kooky-cli list --json                                               # windows → workspaces → tabs, with ids
kooky-cli focus --tab <session-uuid>                                # bring a tab to the front
kooky-cli close --tab <session-uuid>                                # in-app confirmation rules apply
kooky-cli rename --tab <session-uuid> --title <title>               # set a tab's title
kooky-cli status                                                    # version + health; exit 1 when not running
```

Every command except `status` launches kooky first when it isn't running. Exit code 0 means the request was accepted; any failure prints one reason line on stderr. `--agent` takes the same template ids as Settings → Agents (built-ins, customs, and Terminal presets). `--cwd` is optional: without it the tab opens where the active workspace already is, and a Terminal preset uses its own pinned directory — pass `--cwd` to override either. `--title` outranks the tab's automatic title, exactly like renaming it by hand; `--no-focus` opens the tab without bringing kooky forward (even when the CLI launches kooky first) or switching what you're looking at — the tab is already running in the background; `focus` brings it forward whenever you want.

The binary ships inside the app at `Kooky.app/Contents/MacOS/kooky-cli`, and kooky refreshes a stable copy at `~/Library/Application Support/kooky/bin/kooky-cli` on every launch — point external tools at that one: the path survives app updates, and macOS Gatekeeper kills unnotarized helper binaries exec'd from inside `/Applications`, which the Application Support copy sidesteps. Want it on your PATH? Symlink it:

```sh
ln -s ~/Library/Application\ Support/kooky/bin/kooky-cli /usr/local/bin/kooky-cli
```

Commands only flow through kooky's local, owner-only socket — `kooky://` URLs still can't carry commands.

## Install

Download the latest `.dmg` from [Releases](https://github.com/iAmCorey/kooky/releases). Open it and drag `Kooky.app` to `Applications`.

**First launch is blocked by Gatekeeper** because the build is adhoc-signed (no Apple Developer ID yet — public-distribution signing and notarization will come when there are real users). You'll see *"Kooky cannot be opened because Apple cannot check it for malicious software"* or *"is damaged and cannot be opened"*. Pick whichever bypass works for you:

<details>
<summary><b>Path A — System Settings <i>(recommended)</i></b></summary>

1. Double-click `Kooky.app`. If shows the warning. Dismiss it.
2. **System Settings → Privacy & Security**, scroll to **Security**.
3. Click **Open Anyway** next to *"Kooky was blocked to protect your Mac"*. Enter your password.
4. Double-click `Kooky.app` again → click **Open**. Done.
</details>

<details>
<summary><b>Path B — Terminal (one-liner)</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/Kooky.app
```
</details>

<details>
<summary><b>Path C — when "Open Anyway" doesn't appear at all</b></summary>

Sequoia sometimes hides the Open Anyway button entirely for adhoc-signed apps. Re-enable the legacy "Anywhere" option, then redo Path A:

```sh
sudo spctl --global-disable      # macOS 15+; older systems use --master-disable
# System Settings → Privacy & Security → "Allow applications from" → Anywhere
# Open Kooky.app → it now launches
sudo spctl --global-enable       # turn Gatekeeper back on
```

This is **system-wide** while disabled. Re-enable as soon as kooky launches once (the per-app whitelist persists).
</details>

macOS only blocks the first launch. After that, Spotlight / Dock / Finder all work normally.

## Build from source

Requires Xcode 26+ and macOS 14+ (Sonoma — `@Observable` is the floor).

```sh
./scripts/setup-libghostty.sh        # one-time: fetch the libghostty xcframework
swift build
swift run                            # dev mode
swift test                           # 850+ unit tests
./scripts/bench.sh                   # performance benchmarks (release build, results in bench-history.jsonl)

./scripts/build-app.sh               # writes dist/Kooky.app
./scripts/build-dmg.sh --build       # writes dist/Kooky-vX.Y.Z.dmg
```

`Vendor/` and `dist/` are gitignored. The libghostty setup script is idempotent.

## Star History

[![Star History Chart](https://api.star-history.com/chart?repos=iAmCorey/kooky&type=date&legend=top-left&sealed_token=ZX5h8laOXIE38b__FRNpP7ae52yRupThIRrcgidF7RI0OOzVcsKIo1iJ_iDp6UcMoxzNCL99N3RY__N7TFUszIgxzljBSBRRiAPYPt9QC9lKf7X3ShAQJg)](https://www.star-history.com/?type=date&repos=iAmCorey%2Fkooky)

## License

MIT — see [LICENSE](LICENSE). Bundled third-party assets retain their upstream licenses; see [NOTICE.md](NOTICE.md).
