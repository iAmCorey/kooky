import Foundation

/// We don't bundle ghostty's shell-integration assets, so we ship a small zsh
/// wrapper that:
///   1. sources the user's real `~/.zshrc` so their config still applies, then
///   2. installs a `chpwd` hook that emits OSC 7 (`\e]7;file://host/path\e\\`).
///
/// Libghostty's `GHOSTTY_ACTION_PWD` then fires whenever the shell `cd`s, which
/// is what `WorkspaceStore` listens to for cwd-tracking.
enum KookyShellIntegration {
    /// POSIX single-quote wrap (escape internal `'` by `'\''`). Safe for
    /// arbitrary file paths and argv-style values; reused by anyone that
    /// builds a shell-command string for `engine.sendInput` or PTY spawn.
    static func quote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Backslash-escape every POSIX shell metacharacter — matches the
    /// `\ ` / `\'` style Finder uses when dragging a file onto Terminal.app
    /// or ghostty.app. Picks this over `quote(_:)` for the drag-and-drop
    /// path so the user sees the same untouched-looking path they'd see in
    /// any other macOS terminal, rather than a surrounding pair of quotes.
    /// Non-ASCII bytes (Chinese / emoji / accented chars) pass through
    /// unescaped — every modern shell accepts them as raw UTF-8.
    ///
    /// Edge case: filenames with embedded newlines are legal on macOS but
    /// POSIX shells eat `\<newline>` as line-continuation, dropping both
    /// chars instead of preserving the literal newline. We fall back to
    /// `quote(_:)` for those — visible quotes are uglier than `\ `, but
    /// silent path corruption is worse.
    static func backslashEscape(_ s: String) -> String {
        if s.contains("\n") {
            return quote(s)
        }
        var result = ""
        result.reserveCapacity(s.count)
        for char in s {
            if shellMetacharacters.contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }

    private static let shellMetacharacters: Set<Character> = [
        " ", "\t", "\n", "\\", "\"", "'", "`", "$",
        "(", ")", "|", "&", ";", "<", ">", "*", "?",
        "[", "]", "{", "}", "~", "!", "#",
    ]

    static let zshPath = "/bin/zsh"
    static let bashPath = "/bin/bash"
    static let zdotdirKey = "ZDOTDIR"

    /// Directory we prepend to spawned-shell `PATH` so wrapper scripts (e.g.
    /// `claude` shim) get found before the real binaries on disk.
    static let kookyBinDirectory: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    /// Path to the generated Claude Code hooks JSON. Passed to `claude` via
    /// `--settings <path>` by the wrapper script when `KOOKY_SURFACE_ID` is set.
    static let claudeHooksPath: String = {
        hooksDirectory.appendingPathComponent("claude.json").path
    }()

    /// Path to the kooky-managed Gemini system-defaults file. Surfaced to
    /// gemini-cli via `GEMINI_CLI_SYSTEM_SETTINGS_PATH`. Hook arrays merge
    /// with CONCAT semantics across tiers (verified in google-gemini/gemini-cli
    /// `settingsSchema.ts`), so this layers on top of user hooks instead of
    /// replacing them — non-intrusive.
    static let geminiDefaultsPath: String = {
        hooksDirectory.appendingPathComponent("gemini-defaults.json").path
    }()

    /// Path to the kooky-managed Copilot hooks file. Copilot CLI auto-loads
    /// every `~/.copilot/hooks/*.json` and merges events across files, so a
    /// dedicated `kooky.json` co-exists with anything the user has dropped
    /// in there. Pure path computation — the directory is materialised
    /// (and the file written) only when `~/.copilot/` already exists, so
    /// non-Copilot users don't get an empty kooky-owned vendor dir in their
    /// home. We don't honor `COPILOT_HOME` from the user's shell here —
    /// kooky.app runs out-of-process, can't see interactive shell env — so
    /// users who customise `COPILOT_HOME` would drop the file themselves.
    static let copilotHooksPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/kooky.json").path
    }()

    /// XDG plugin directory OpenCode auto-loads at startup. Honors
    /// `XDG_CONFIG_HOME` when set (the OpenCode launch is a child of the same
    /// shell, so a user-relocated config dir routes consistently between us
    /// and OpenCode); falls back to `~/.config`.
    static let opencodePluginPath: String = {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        let dir = base.appendingPathComponent("opencode/plugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kooky.ts").path
    }()

    private static let hooksDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky/hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Absolute path to the bundled `KookyHook` helper binary. Lives next to
    /// the main executable for both `swift run` (`.build/<config>/`) and
    /// `.app` bundles (`Contents/MacOS/`).
    static let kookyHookBinaryPath: String = {
        guard let exe = Bundle.main.executablePath else { return "" }
        let dir = (exe as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("KookyHook")
    }()

    /// Per-session env vars our wrappers + hook helper read. Caller supplies
    /// the surface UUID; everything else is process-wide. PATH prepends
    /// `kookyBinDirectory` so wrapper shims resolve before the real binaries.
    static func kookyEnvironment(for sessionId: UUID) -> [String: String] {
        let parentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        var env: [String: String] = [
            "KOOKY_SURFACE_ID": sessionId.uuidString,
            "KOOKY_HOOKS_PATH": claudeHooksPath,
            "KOOKY_BIN_DIR": kookyBinDirectory,
            "KOOKY_HOOK_BIN": kookyHookBinaryPath,
            "PATH": "\(kookyBinDirectory):\(parentPath)",
            // Gemini CLI loads this as the lowest-precedence settings tier,
            // but its hooks arrays use CONCAT-merge — so our entries fire
            // alongside whatever the user has in `~/.gemini/settings.json`,
            // not instead of. The file is ours, regenerated each launch.
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": geminiDefaultsPath,
            // libghostty defaults TERM to "xterm-ghostty"; not every system
            // ships its terminfo. Pinning to xterm-256color gives all TUIs a
            // well-known capability profile.
            "TERM": "xterm-256color",
        ]
        // Preserve the user's original ZDOTDIR (if they had one — rare, mostly
        // dotfile organizers). The wrapper rc consumes this to restore ZDOTDIR
        // after sourcing ~/.zshrc; child installer scripts then see the real
        // value (or no ZDOTDIR at all) and write PATH exports to ~/.zshrc
        // instead of our ephemeral wrapper rc.
        if let original = ProcessInfo.processInfo.environment["ZDOTDIR"], !original.isEmpty {
            env["KOOKY_ORIGINAL_ZDOTDIR"] = original
        }
        return env
    }

    /// Writes wrapper shims, hook configs, and the OpenCode plugin to disk.
    /// Idempotent — call on every app launch so each agent's hook command
    /// tracks the latest `KookyHook` location.
    static func installAgentHooks() {
        writeWrapper(name: "claude", script: claudeWrapperScript)
        writeWrapper(name: "codex", script: codexWrapperScript)
        // Gemini doesn't need a wrapper — `GEMINI_CLI_SYSTEM_SETTINGS_PATH`
        // in the spawned shell is enough for hooks to fire from gemini itself.
        writeWrapper(name: "opencode", script: bracketWrapperScript(slug: "opencode"))
        writeWrapper(name: "amp", script: bracketWrapperScript(slug: "amp"))
        writeWrapper(name: "cursor-agent", script: bracketWrapperScript(slug: "cursor-agent"))
        writeWrapper(name: "copilot", script: bracketWrapperScript(slug: "copilot"))

        let hookCmd = kookyHookBinaryPath
        writeJSON(at: claudeHooksPath, object: claudeHooksObject(hookCmd: hookCmd))
        writeJSON(at: geminiDefaultsPath, object: geminiDefaultsObject(hookCmd: hookCmd))
        installCopilotHooksIfPresent(hookCmd: hookCmd)
        writeManagedFile(at: opencodePluginPath, contents: opencodePluginScript)
    }

    /// Writes the Copilot hooks JSON only when the user already has a
    /// `~/.copilot/` directory — i.e. they've at least run Copilot CLI once.
    /// Skips otherwise so kooky doesn't pre-stage a vendor namespace for
    /// users who may never install Copilot. Installing Copilot later then
    /// requires one kooky restart to pick up the hooks (acceptable: the
    /// bracket wrapper still gives running/ended on the first run).
    private static func installCopilotHooksIfPresent(hookCmd: String) {
        let copilotHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
        guard FileManager.default.fileExists(atPath: copilotHome.path) else { return }
        let hooksDir = copilotHome.appendingPathComponent("hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        writeManagedJSON(at: copilotHooksPath, object: copilotHooksObject(hookCmd: hookCmd))
    }

    /// Wired via `claude --settings <path>`. SessionStart promotes manually-typed
    /// `claude` immediately; without it the tab icon waits for the user's first
    /// prompt.
    static func claudeHooksObject(hookCmd: String) -> [String: Any] {
        hooksObject(slug: "claude", hookCmd: hookCmd, events: [
            "SessionStart":      .running,
            "UserPromptSubmit":  .running,
            "Stop":              .attention,
            "Notification":      .attention,
            "SessionEnd":        .ended,
        ])
    }

    /// Gemini's hook event names diverge from Claude's (BeforeAgent / AfterAgent
    /// instead of UserPromptSubmit / Stop). Hook scripts must not write to
    /// stdout — `KookyHook` only writes to its socket so this is safe.
    /// SessionStart promotes manually-typed `gemini` to `.gemini` immediately,
    /// same pattern as Claude.
    static func geminiDefaultsObject(hookCmd: String) -> [String: Any] {
        hooksObject(slug: "gemini", hookCmd: hookCmd, events: [
            "SessionStart": .running,
            "BeforeAgent":  .running,
            "AfterAgent":   .attention,
            "Notification": .attention,
            "SessionEnd":   .ended,
        ])
    }

    /// Copilot CLI's hooks schema diverges from Claude/Gemini's enough that
    /// it doesn't fit `hooksObject`: top-level `version: 1`, camelCase event
    /// names, no inner `{"hooks": [...]}` wrapper, and the command goes in
    /// a `bash` field (not `command`). Event mapping mirrors Claude's
    /// (sessionStart / userPromptSubmitted → running; agentStop / notification
    /// → attention; sessionEnd → ended). The `_kookyManaged` sentinel is the
    /// JSON-friendly equivalent of the text marker — `writeManagedJSON` reads
    /// it back to decide whether the file is ours to overwrite.
    static func copilotHooksObject(hookCmd: String) -> [String: Any] {
        let events: [(String, HookEvent)] = [
            ("sessionStart",        .running),
            ("userPromptSubmitted", .running),
            ("agentStop",           .attention),
            ("notification",        .attention),
            ("sessionEnd",          .ended),
        ]
        var hooks: [String: Any] = [:]
        let quotedCmd = quote(hookCmd)
        for (event, state) in events {
            hooks[event] = [
                ["type": "command", "bash": "\(quotedCmd) copilot \(state.rawValue)", "timeoutSec": 5]
            ]
        }
        return ["version": 1, "_kookyManaged": managedFileMarker, "hooks": hooks]
    }

    /// Builds a `claude --settings`-style hooks object for any agent that
    /// follows the `{"hooks": {<EventName>: [{"hooks": [{"type": "command",
    /// "command": "..."}]}]}}` shape (Claude Code, Gemini CLI). Routing
    /// `HookEvent` cases through `.rawValue` keeps the wrapper-emitted strings
    /// in sync with the receiver in `HookServer`.
    private static func hooksObject(
        slug: String,
        hookCmd: String,
        events: [String: HookEvent]
    ) -> [String: Any] {
        var hooks: [String: Any] = [:]
        // Claude / Gemini run `command` through `/bin/sh -c`, so an unquoted
        // `KookyHook` path breaks the moment the app lives under a path with
        // spaces or shell metacharacters (e.g. `/Applications/Kooky 2.app/…`).
        let quotedCmd = quote(hookCmd)
        for (event, state) in events {
            hooks[event] = [["hooks": [["type": "command", "command": "\(quotedCmd) \(slug) \(state.rawValue)"]]]]
        }
        return ["hooks": hooks]
    }

    /// Marker we embed at the top of every kooky-generated user-config file
    /// (currently the OpenCode plugin). `writeManagedFile` reads existing
    /// files and refuses to overwrite anything that doesn't carry this tag —
    /// so a user's same-named plugin stays untouched on upgrade.
    private static let managedFileMarker = "kooky-managed-do-not-edit"

    private static func writeJSON(at path: String, object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Writes a file in user-config space (e.g. OpenCode plugin) only when
    /// either the path is unused or the existing content carries our marker.
    /// A user-owned file with the same name is left alone — better to skip a
    /// feature than nuke their plugin.
    private static func writeManagedFile(at path: String, contents: String) {
        let url = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.contains(managedFileMarker) {
            return
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// JSON variant of `writeManagedFile` — preserves a user-authored
    /// `kooky.json` that happens to live at the same path by looking for the
    /// `_kookyManaged` sentinel field. The Copilot hooks dir is user-owned
    /// (`~/.copilot/hooks/`), so a same-named user file is plausible enough
    /// to guard against. A corrupt-or-non-JSON file at the same path is
    /// treated as ours to overwrite — same policy `writeManagedFile` uses
    /// for non-UTF-8 / marker-less text. The alternative (silently skipping)
    /// would leave the user without working hooks and no signal as to why.
    private static func writeManagedJSON(at path: String, object: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (parsed["_kookyManaged"] as? String) != managedFileMarker {
            return
        }
        writeJSON(at: path, object: object)
    }

    private static func writeWrapper(name: String, script: String) {
        let path = (kookyBinDirectory as NSString).appendingPathComponent(name)
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    /// Common bash header for every wrapper: locate the real binary on
    /// `$PATH` skipping our own dir, abort if missing.
    private static func wrapperPreamble(binary: String) -> String {
        """
        #!/usr/bin/env bash
        self_dir="$(cd "$(dirname "$0")" && pwd)"
        real=""
        IFS=:
        for dir in $PATH; do
            [[ "$dir" == "$self_dir" ]] && continue
            if [[ -x "$dir/\(binary)" ]]; then
                real="$dir/\(binary)"
                break
            fi
        done
        unset IFS

        if [[ -z "$real" ]]; then
            printf '\\n  \\033[33m%s is not installed.\\033[0m\\n\\n' "\(binary)" >&2
            # The new-tab path eagerly sets session.agent based on the template,
            # expecting bracket wrapper to ping `running` next. We never got
            # there — revert the icon so it doesn't lie about what's running.
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" \(binary) ended 2>/dev/null
            fi
            exit 127
        fi
        """
    }

    /// Inside a kooky session ($KOOKY_SURFACE_ID set), injects --settings so
    /// Claude Code's hooks report state back to the app via the bundled
    /// KookyHook helper. Outside, transparent passthrough.
    private static let claudeWrapperScript = """
    \(wrapperPreamble(binary: "claude"))

    if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOKS_PATH" ]]; then
        exec "$real" --settings "$KOOKY_HOOKS_PATH" "$@"
    fi
    exec "$real" "$@"
    """

    /// Codex doesn't expose a Claude-style hooks settings file we can override
    /// per-invocation, but it does have `notify = ["cmd", "arg", ...]` in
    /// config.toml — fired after each agent turn with a JSON payload appended
    /// as the final argv. We override `notify` inline via `-c` so user's
    /// ~/.codex/config.toml is left untouched. The single signal we get is
    /// "turn complete" which we map to `attention`.
    private static let codexWrapperScript = """
    \(wrapperPreamble(binary: "codex"))

    if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
        # Codex doesn't expose SessionStart / SessionEnd lifecycle hooks
        # we can override per-invocation. Bracket the run from the wrapper:
        # send `running` before codex starts (immediate icon promotion),
        # then `ended` after exit (revert to terminal). Mid-run state
        # transitions still come from Codex's `notify` config below.
        "$KOOKY_HOOK_BIN" codex running 2>/dev/null
        "$real" -c "notify=[\\"$KOOKY_HOOK_BIN\\",\\"codex\\",\\"attention\\"]" "$@"
        status=$?
        "$KOOKY_HOOK_BIN" codex ended 2>/dev/null
        exit $status
    fi
    exec "$real" "$@"
    """

    /// Generic bracket wrapper for agents we can't drive mid-run state from
    /// (no hook system or no installed plugin yet). Sends `running` before
    /// exec and `ended` after exit; activity dot stays green for the whole
    /// run, then drops to idle on quit. Used for `amp` (no plugin) and
    /// `opencode` — opencode's plugin upgrades mid-run state once installed.
    static func bracketWrapperScript(slug: String) -> String {
        """
        \(wrapperPreamble(binary: slug))

        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
            "$KOOKY_HOOK_BIN" \(slug) running 2>/dev/null
            "$real" "$@"
            status=$?
            "$KOOKY_HOOK_BIN" \(slug) ended 2>/dev/null
            exit $status
        fi
        exec "$real" "$@"
        """
    }

    /// OpenCode auto-loads any `.ts`/`.js` file in
    /// `$XDG_CONFIG_HOME/opencode/plugin/` (or `~/.config/opencode/plugin/`)
    /// at startup. The plugin runs in opencode's own Bun runtime, inherits
    /// KOOKY_SURFACE_ID + KOOKY_HOOK_BIN from the shell, and shells out to
    /// KookyHook on each lifecycle event. The first-line marker
    /// (`managedFileMarker`) lets `writeManagedFile` recognise the file as
    /// kooky-generated on upgrade — a user's own `kooky.ts` plugin would
    /// not carry the marker and stays untouched.
    static let opencodePluginScript = """
    // \(managedFileMarker) — pings KookyHook on prompt-submit and turn-end so
    // the sidebar agent dot tracks per-session activity. Safe to delete; will
    // be regenerated next time kooky launches.
    export const KookyPlugin = async ({ $ }) => {
      const surface = process.env.KOOKY_SURFACE_ID
      const hookBin = process.env.KOOKY_HOOK_BIN
      if (!surface || !hookBin) return {}

      const ping = async (state) => {
        try { await $`${hookBin} opencode ${state}`.quiet() } catch {}
      }

      return {
        "chat.message": async () => { await ping("running") },
        event: async ({ event }) => {
          if (event?.type === "session.idle") await ping("attention")
        },
      }
    }
    """

    enum DetectedUserShell { case zsh, bash, other }

    static var detectedUserShell: DetectedUserShell {
        let path = ProcessInfo.processInfo.environment["SHELL"] ?? zshPath
        if path.hasSuffix("/zsh") { return .zsh }
        if path.hasSuffix("/bash") { return .bash }
        return .other
    }

    /// Path to a tiny launcher script that re-execs bash as an interactive,
    /// non-login shell with our `--rcfile`. Required because libghostty starts
    /// every `command` as a login shell (`argv[0]` prefixed with `-`), and
    /// login bash ignores `--rcfile` entirely (it reads `~/.bash_profile`
    /// instead). The launcher is a degenerate `bash` itself, so it gets the
    /// login prefix; it then `exec`s a fresh bash without the prefix.
    static let bashLauncherPath: String = {
        let dir = NSTemporaryDirectory()
        let launcherPath = dir.appending("kooky-bash-launch-\(getpid()).sh")
        let rcfilePath = dir.appending("kooky-bashrc-\(getpid())")

        let bashrc = """
        # Default word-jump bindings; readline doesn't bind Ctrl/Alt+arrow on
        # macOS by default. See the matching block in zshDirectory.
        bind '"\\e[1;5D": backward-word'     # Ctrl+Left
        bind '"\\e[1;5C": forward-word'      # Ctrl+Right
        bind '"\\e[1;3D": backward-word'     # Alt+Left
        bind '"\\e[1;3C": forward-word'      # Alt+Right

        # bash is launched as interactive non-login (`--rcfile` is incompatible
        # with `-l`), so it would normally skip the login rc chain. macOS users
        # traditionally put PATH / env in ~/.bash_profile (Apple Terminal starts
        # bash as login), so without this they'd see env vars vanish. Replay
        # the first existing login rc, matching bash's own lookup order.
        _kooky_login_rc_loaded=
        for _kooky_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [[ -r "$_kooky_rc" ]]; then
                source "$_kooky_rc"
                _kooky_login_rc_loaded=1
                break
            fi
        done
        unset _kooky_rc

        # No login rc existed, so its standard `source ~/.bashrc` chain never
        # ran — fall back so the user's interactive config still loads. Skip
        # when a login rc was found: bash login shells don't auto-source
        # .bashrc, and the user's profile chain (if they want it) handles
        # that. Avoids double-load when .bash_profile already chained .bashrc
        # (NVM / oh-my-bash / PROMPT_COMMAND duplication = 150-300ms).
        if [[ -z "$_kooky_login_rc_loaded" && -r "$HOME/.bashrc" ]]; then
            source "$HOME/.bashrc"
        fi
        unset _kooky_login_rc_loaded

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOSTNAME" "$PWD"; }
        \(envStatusBlock)

        \(agentLaunchBlock)

        # __kooky_agent_launch goes FIRST so the agent owns the terminal
        # before _kooky_osc7_pwd / _kooky_env_status fire — they re-run on
        # the next prompt cycle (when the agent exits) and catch the
        # post-agent state. Order within PROMPT_COMMAND is positional.
        PROMPT_COMMAND="__kooky_agent_launch;_kooky_osc7_pwd;_kooky_env_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        _kooky_osc7_pwd
        _kooky_env_status
        """
        writeFile(at: rcfilePath, contents: bashrc)

        let launcher = """
        #!/bin/bash
        exec \(bashPath) --rcfile "\(rcfilePath)" -i

        """
        writeFile(at: launcherPath, contents: launcher, executable: true)
        return launcherPath
    }()

    /// Path to a per-process directory containing our wrapper `.zshrc`. Pass
    /// this as `ZDOTDIR` when spawning zsh so it loads the wrapper instead of
    /// `~/.zshrc` directly.
    static let zshDirectory: String = {
        let dir = NSTemporaryDirectory().appending("kooky-zsh-\(getpid())")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir), withIntermediateDirectories: true
        )
        let zshrc = """
        # Default word-jump bindings. zsh ZLE only binds Alt+B/F by default;
        # most other terminals (iTerm2, ghostty, Apple Terminal) remap the
        # Ctrl/Alt+arrow sequences to ESC+B/F so users don't notice. kooky
        # binds them directly here. Placed before sourcing ~/.zshrc so user
        # rc files retain final say if they override the same sequences.
        bindkey '^[[1;5D' backward-word    # Ctrl+Left
        bindkey '^[[1;5C' forward-word     # Ctrl+Right
        bindkey '^[[1;3D' backward-word    # Alt+Left
        bindkey '^[[1;3C' forward-word     # Alt+Right

        # Restore ZDOTDIR to the user's original (almost always unset) *before*
        # replaying their rc chain. zsh has already consumed ZDOTDIR to locate
        # this wrapper rc — changing it now is safe and ensures any
        # `$ZDOTDIR/...` reference inside .zshenv / .zprofile / .zshrc
        # (compinit's `.zcompdump`, plugin caches, znap/zinit roots, HISTFILE
        # overrides) resolves to real `$HOME` instead of our ephemeral
        # kooky-zsh-<pid> dir. Also stops `curl | bash`-style installers
        # (opencode, rustup) from writing PATH exports to our ephemeral rc.
        if [[ -n "$KOOKY_ORIGINAL_ZDOTDIR" ]]; then
            export ZDOTDIR="$KOOKY_ORIGINAL_ZDOTDIR"
            unset KOOKY_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi

        # macOS `/etc/zshrc` (already ran) resolved HISTFILE against our
        # ephemeral ZDOTDIR; `cleanup()` deletes that dir on quit, taking
        # history with it. Reset to the real path *before* user rc so a user
        # HISTFILE override in any of the three files below still wins.
        export HISTFILE="$HOME/.zsh_history"

        # Replay the rc files zsh would have run if ZDOTDIR had pointed at the
        # user's real dir. Resolve via `${ZDOTDIR:-$HOME}` after each source —
        # so users who park their zsh config in a custom dir (e.g.
        # `~/.config/zsh` via parent-shell ZDOTDIR, or via `export ZDOTDIR=...`
        # inside .zshenv itself) get the full chain. Re-resolve after each
        # source because .zshenv / .zprofile may mutate ZDOTDIR.
        [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
        [[ -r "${ZDOTDIR:-$HOME}/.zprofile" ]] && source "${ZDOTDIR:-$HOME}/.zprofile"
        [[ -r "${ZDOTDIR:-$HOME}/.zshrc" ]] && source "${ZDOTDIR:-$HOME}/.zshrc"

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        autoload -Uz add-zsh-hook
        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOST" "$PWD" }
        add-zsh-hook chpwd _kooky_osc7_pwd
        _kooky_osc7_pwd

        \(envStatusBlock)

        \(osc133Block)

        # Agent launch via zle-line-init — fires AFTER the entire
        # precmd_functions chain completes (so Powerlevel10k's
        # `_p9k_precmd` has finalized instant-prompt and restored stdio)
        # and BEFORE zle reads input. BUFFER + accept-line submits the
        # launch command as if the user typed it. See `agentLaunchBlock`
        # docs for the long-form rationale.
        autoload -Uz add-zle-hook-widget
        __kooky_zle_line_init_launch() {
            [[ -n "$KOOKY_AGENT_LAUNCHED" ]] && return 0
            [[ -z "$KOOKY_AGENT" ]] && return 0
            export KOOKY_AGENT_LAUNCHED=1
            BUFFER="$KOOKY_AGENT"
            unset KOOKY_AGENT
            zle accept-line
        }
        add-zle-hook-widget zle-line-init __kooky_zle_line_init_launch
        """
        writeFile(at: (dir as NSString).appendingPathComponent(".zshrc"), contents: zshrc)
        return dir
    }()

    /// Removes per-process temp files. Wired into `applicationWillTerminate`
    /// so wrappers don't accumulate in `NSTemporaryDirectory()` across runs.
    static func cleanup() {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory()
        let pid = getpid()
        for path in [
            dir.appending("kooky-bash-launch-\(pid).sh"),
            dir.appending("kooky-bashrc-\(pid)"),
            dir.appending("kooky-zsh-\(pid)"),
        ] {
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Internals

    /// Defines `__kooky_agent_launch` — used by the bash wrapper rc via
    /// PROMPT_COMMAND. zsh uses a different mechanism (zle-line-init +
    /// BUFFER + zle accept-line, inlined in `zshDirectory` below).
    ///
    /// Why zsh diverges: launching from precmd looked correct, but
    /// Powerlevel10k's main precmd hook (`_p9k_precmd`, the one that
    /// finalizes instant-prompt and restores stdio) appends to
    /// `precmd_functions` *lazily* — it can end up AFTER hooks we
    /// registered earlier from the wrapper rc. Agents then fire with
    /// p10k's stdio still redirected to its capture buffer, inherit a
    /// non-TTY stdout/stdin, and switch into non-interactive mode.
    /// Claude Code 2.x in that state errors with `Input must be
    /// provided either through stdin or as a prompt argument when using
    /// --print`. Codex / gemini hit analogous paths.
    ///
    /// `zle-line-init` fires once the entire precmd chain is done and
    /// zle is about to accept input — stdio is fully restored by then.
    /// Setting BUFFER + zle accept-line submits the launch command as
    /// if the user typed it, so the agent runs as a real foreground
    /// command with proper OSC 133 preexec/postexec bracketing.
    /// `KOOKY_AGENT_LAUNCHED` guards re-entry from agent-spawned
    /// subshells.
    static let agentLaunchBlock = """
        __kooky_agent_launch() {
            [[ -n "$KOOKY_AGENT_LAUNCHED" ]] && return 0
            [[ -z "$KOOKY_AGENT" ]] && return 0
            export KOOKY_AGENT_LAUNCHED=1
            local _kooky_cmd="$KOOKY_AGENT"
            unset KOOKY_AGENT
            # `eval` lets KOOKY_AGENT carry multi-word commands (e.g. an
            # editor + file path); single-word agent commands like `claude`
            # behave identically.
            eval "$_kooky_cmd"
        }
        """

    /// Two layers of memoization in this hook avoid heavy per-prompt work:
    /// (a) `node --version` is the dominant cost (~50-200ms for V8 cold-start
    ///     on every prompt). We cache its result against the resolved `node`
    ///     binary path + NVM_BIN — if neither changed, the cached version is
    ///     still valid.
    /// (b) the `kooky-hook env` IPC fork is skipped entirely when no env key
    ///     differs from the previous send. Most prompts have steady env, so
    ///     this turns the hook into a no-op the vast majority of the time.
    static let envStatusBlock = """
        _kooky_env_status() {
            [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" && -x "$KOOKY_HOOK_BIN" ]] || return 0
            local _kooky_node_path=""
            command -v node >/dev/null 2>&1 && _kooky_node_path="$(command -v node)"
            local _kooky_node_key="${_kooky_node_path}|${NVM_BIN:-}"
            if [[ "$_kooky_node_key" != "$_KOOKY_NODE_KEY_LAST" ]]; then
                _KOOKY_NODE_VERSION_LAST=""
                [[ -n "$_kooky_node_path" ]] && _KOOKY_NODE_VERSION_LAST="$("$_kooky_node_path" --version 2>/dev/null)"
                _KOOKY_NODE_KEY_LAST="$_kooky_node_key"
            fi
            # Accept both lowercase and uppercase forms — curl / git / requests
            # respect lowercase; some tools (and many corp setups) export
            # uppercase only. Fall through to uppercase when lowercase is unset.
            local _kooky_https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
            local _kooky_http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
            local _kooky_all_proxy="${all_proxy:-${ALL_PROXY:-}}"
            local _kooky_env_now="${VIRTUAL_ENV:-}|${CONDA_DEFAULT_ENV:-}|${NVM_BIN:-}|${NVM_DIR:-}|$_KOOKY_NODE_VERSION_LAST|$_kooky_https_proxy|$_kooky_http_proxy|$_kooky_all_proxy"
            [[ "$_kooky_env_now" == "$_KOOKY_ENV_LAST" ]] && return 0
            # Only advance the dedup cache when the IPC actually succeeded —
            # if kooky-hook returns non-zero (kooky restarting, socket gone
            # before the hook server bound), the next prompt will retry
            # instead of staying frozen at the unsent value.
            "$KOOKY_HOOK_BIN" env "${VIRTUAL_ENV:-}" "${CONDA_DEFAULT_ENV:-}" "${NVM_BIN:-}" "${NVM_DIR:-}" "$_KOOKY_NODE_VERSION_LAST" "$_kooky_https_proxy" "$_kooky_http_proxy" "$_kooky_all_proxy" 2>/dev/null \
                && _KOOKY_ENV_LAST="$_kooky_env_now"
            # Mask our internal IPC status so user precmd hooks downstream in
            # zsh's precmd_functions chain don't see `$?=1` and bleed it into
            # their prompt rendering. The dedup logic is internal — its
            # success/failure must not leak into the rest of the shell.
            return 0
        }
        """

    /// FinalTerm / OSC 133 prompt+command boundary markers. libghostty parses
    /// these and fires `GHOSTTY_ACTION_COMMAND_FINISHED` on `D` (per-tab
    /// last-command status + duration, scroll-to-prompt jumps), and uses
    /// `A;cl=line` to anchor `cursor-click-to-move` so option-/single-click
    /// on a prompt jumps the shell cursor to that column. Re-injects the
    /// `B` marker into PROMPT on every redraw because Starship / p10k-style
    /// themes rebuild PROMPT each `precmd` and would otherwise drop our suffix.
    private static let osc133Block = #"""
        __kooky_133_first=1
        __kooky_133_precmd() {
            local last=$?
            if (( ! __kooky_133_first )); then
                printf '\e]133;D;%s\a' "$last"
            fi
            __kooky_133_first=0
            # `cl=line` is ghostty's required marker metadata — without it
            # libghostty silently ignores the prompt sentinel and features
            # that depend on it (`cursor-click-to-move`, jump-to-prompt)
            # stay dormant. `\a` (BEL) terminator matches ghostty's own
            # zsh shell-integration script exactly.
            printf '\e]133;A;cl=line\a'
            # Wrap the OSC 133 B marker in zsh's zero-width brackets (%{ ... %}).
            # Without them zsh counts every byte of the escape sequence (ESC, ],
            # `133;B`, BEL) toward the PROMPT's visible width, miscalculates the
            # wrap column by ~8 cells, and ZLE redraws the input on the wrong
            # row the moment a long input wraps — wiping the first visible line.
            [[ "$PROMPT" != *$'\e]133;B\a'* ]] && PROMPT="${PROMPT}"$'%{\e]133;B\a%}'
            _kooky_env_status
            # Same masking concern as `_kooky_env_status` itself: the kooky
            # hooks must not leak `$?` into user prompts that downstream
            # precmd hooks may sample.
            return 0
        }
        __kooky_133_preexec() { printf '\e]133;C\a' }
        add-zsh-hook precmd __kooky_133_precmd
        add-zsh-hook preexec __kooky_133_preexec
        """#

    private static func writeFile(at path: String, contents: String, executable: Bool = false) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { chmod(path, 0o755) }
    }
}
