import AppKit
import Foundation
import SwiftUI

/// How a CLI names and resumes one exact conversation.
///
/// Most agents take a flag followed by an id, while a few use a subcommand
/// (`codex resume <id>`, `amp threads continue <id>`) or an equals-style
/// option (`agy --conversation=<id>`). Grok is the outlier: it lets the
/// caller assign the id for a fresh session, which is both more reliable and
/// earlier than trying to discover the id from a later hook.
enum ConversationResumeStrategy: Hashable {
    case arguments([String])
    case optionEquals(String)
    case preallocated(newSessionArguments: [String], resumeArguments: [String])

    var preallocatesNewSessionId: Bool {
        if case .preallocated = self { return true }
        return false
    }

    func resumeFragment(conversationId: String) -> String {
        switch self {
        case .arguments(let arguments):
            return Self.argumentsFragment(arguments, conversationId: conversationId)
        case .optionEquals(let option):
            return " \(option)=\(Self.shellArgument(conversationId))"
        case .preallocated(_, let resumeArguments):
            return Self.argumentsFragment(resumeArguments, conversationId: conversationId)
        }
    }

    func newSessionFragment(conversationId: String) -> String {
        guard case .preallocated(let arguments, _) = self else { return "" }
        return Self.argumentsFragment(arguments, conversationId: conversationId)
    }

    private static func argumentsFragment(_ arguments: [String], conversationId: String) -> String {
        let prefix = arguments.joined(separator: " ")
        return " \(prefix) \(shellArgument(conversationId))"
    }

    /// Keep normal UUID/thread ids readable in process listings, but quote
    /// any unexpected value before it crosses the persisted-data → shell
    /// boundary.
    private static func shellArgument(_ value: String) -> String {
        let isSafe = !value.isEmpty && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "-._:@/".contains($0))
        }
        return isSafe ? value : KookyShellIntegration.quote(value)
    }
}

/// A named profile that turns into a `TerminalSessionConfig` when the user
/// picks it from the "+" menu. The shell starts under our wrapper `.zshrc`
/// (KookyShellIntegration), which sources the user's config, then — if
/// `KOOKY_AGENT` is set — invokes the agent inline. The user never sees the
/// shell prompt or the command echo, and on agent exit they land in a clean
/// shell prompt with their full PATH/aliases intact.
struct AgentTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    /// SF Symbol used when `iconAsset` is nil or fails to load.
    let symbol: String
    /// Filename (without extension) of a bundled PNG in `Resources/Icons/`.
    /// Sourced from github.com/lobehub/lobe-icons (MIT).
    let iconAsset: String?
    /// Brand-derived hue used for compact indicators (sidebar status pips).
    /// Picked from each lobe-icon's dominant fill so a row's pip group reads as
    /// the same family of marks shown elsewhere. sRGB hex.
    let tintHex: String?
    let initialCommand: String?
    /// For custom templates only — snapshot of `CustomAgentData.baseAgentId`
    /// taken at `fromCustom` time. Nil for builtins. Lives on the template
    /// (not on Session) because the wrapper-end revert in `applyHookEvent`
    /// must use the value present when the session *started*, not whatever
    /// the user has since changed in Settings → Agents (a mid-run
    /// edit/delete would otherwise leave the tab stuck in the custom-agent
    /// state forever).
    let baseAgentId: String?
    /// CLI flag the agent's binary expects when receiving a prompt argument.
    /// Nil = positional (`claude "<prompt>"`, the most common shape). Agents
    /// that need a flag set it on their builtin definition below — see the
    /// Copilot / Amp wirings. Drives the right-click "Ask <agent>" launch
    /// path via `makeSessionConfig(initialPrompt:)`. Templates with
    /// `initialCommand == nil` (Terminal) ignore this entirely.
    let promptLaunchFlag: String?
    /// Exact command shape used to resume a prior conversation. Nil means the
    /// template has no automatic-resume integration. Drives
    /// `makeSessionConfig(resumeId:)`, Grok's fresh-session preallocation,
    /// and `supportsResume`.
    let resumeStrategy: ConversationResumeStrategy?
    /// True when the agent feeds kooky per-tool-call activity — Claude via
    /// its `--settings` hooks (`PreToolUse` / `PostToolUse`), Pi via its
    /// extension's `tool_execution_start` / `_end` events. Drives the
    /// status-bar tool-call activity pill (`sessionWantsToolCallActivity`).
    /// Builtins set it explicitly; `fromCustom` inherits the base's value so
    /// a Claude-/Pi-based custom agent gets the pill too. Off for shells and
    /// agents without a tool feed (the pill simply never appears).
    let reportsToolCalls: Bool
    /// Environment the agent launches with — populated only for custom
    /// agents (`parseEnv(CustomAgentData.env)` in `fromCustom`); builtins
    /// are `[:]`. Snapshot-frozen at `fromCustom` like `baseAgentId`. v1
    /// consumes it for Claude-Code-based customs — `spawnSession` writes
    /// it into a per-agent Claude settings file.
    let extraEnv: [String: String]
    /// Pinned initial working directory snapshotted from `TerminalPreset.path`
    /// in `fromTerminalPreset`. Nil for builtins and customs. When set,
    /// `WorkspaceStore.addTab` uses it instead of the workspace cwd unless
    /// the caller passes an explicit `initialCwd` (right-click "Ask <agent>",
    /// `reopenLastClosedTab`). `~/` is expanded; a missing path falls back
    /// to `$HOME` via `resolvedSpawnCwd`.
    let extraCwd: String?

    /// True when this template launches a plain shell instead of an agent
    /// binary. Covers the default `.terminal` and every materialised
    /// `TerminalPreset`. Use this rather than `id == "terminal"` checks at
    /// call sites that need to distinguish shells from agents (the Ask-
    /// <agent> right-click, the "based on" Picker, etc.) — once presets
    /// exist there are many shell templates, not one.
    var isShell: Bool { initialCommand == nil }

    /// The builtin roster id this template answers to — a custom agent
    /// resolves to its frozen base, a builtin to itself. This is the key the
    /// per-agent settings, tool/usage gates, and deep-link matching all speak
    /// (the scanner roster only knows builtins), so every consumer must use
    /// this one spelling rather than re-deriving `baseAgentId ?? id`.
    var rosterId: String { baseAgentId ?? id }

    init(
        id: String,
        title: String,
        symbol: String,
        iconAsset: String?,
        tintHex: String?,
        initialCommand: String?,
        baseAgentId: String? = nil,
        promptLaunchFlag: String? = nil,
        resumeStrategy: ConversationResumeStrategy? = nil,
        reportsToolCalls: Bool = false,
        extraEnv: [String: String] = [:],
        extraCwd: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.iconAsset = iconAsset
        self.tintHex = tintHex
        self.initialCommand = initialCommand
        self.baseAgentId = baseAgentId
        self.promptLaunchFlag = promptLaunchFlag
        self.resumeStrategy = resumeStrategy
        self.reportsToolCalls = reportsToolCalls
        self.extraEnv = extraEnv
        self.extraCwd = extraCwd
    }

    var tint: Color? {
        tintHex.flatMap(Color.init(hex:))
    }

    /// Pi's session filename is `<timestamp>_<uuid>.jsonl`, but `pi
    /// --session` resolves the canonical UUID stored inside the JSONL
    /// header. Older kooky builds persisted the filename stem, so trim that
    /// legacy prefix for Pi and Pi-based custom agents. Unknown/future id
    /// shapes pass through unchanged.
    func normalizedConversationId(_ conversationId: String?) -> String? {
        guard
            let conversationId,
            id == Self.piID || baseAgentId == Self.piID
        else {
            return conversationId
        }

        let legacyPrefix = #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_"#
        guard let prefixRange = conversationId.range(of: legacyPrefix, options: .regularExpression) else {
            return conversationId
        }
        let candidate = String(conversationId[prefixRange.upperBound...])
        guard UUID(uuidString: candidate) != nil else { return conversationId }
        return candidate
    }

    /// Claude's `--no-session-persistence` still emits lifecycle hooks with
    /// a `session_id`, but that id cannot be resumed. Snapshot this at spawn
    /// time so the hook mirror cannot turn an ephemeral run into a persisted
    /// `--resume` target. Other agents keep their own capture semantics (Pi's
    /// extension already declines to report ids for ephemeral sessions).
    func persistsConversation(extraOptions: String?) -> Bool {
        guard id == Self.claudeCodeID || baseAgentId == Self.claudeCodeID else {
            return true
        }
        let flag = "--no-session-persistence"
        return !Self.containsShellWord(flag, in: initialCommand)
            && !Self.containsShellWord(flag, in: extraOptions)
    }

    /// Finds one literal argv without evaluating user-authored shell syntax.
    /// Quotes and escapes are folded into the current word; separators end it.
    private static func containsShellWord(_ target: String, in source: String?) -> Bool {
        guard let source else { return false }
        var quote: Character?
        var word = ""
        var escaped = false

        for character in source {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    word.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "#", word.isEmpty {
                break
            } else if character.isWhitespace || ";|&()<>".contains(character) {
                if word == target { return true }
                word = ""
            } else {
                word.append(character)
            }
        }
        return word == target
    }

    /// `extraOptions` is appended after `initialCommand` (space-separated)
    /// when forming `KOOKY_AGENT`. The wrapper rc's `eval` splits on
    /// whitespace, so the caller handles its own quoting for tokens that
    /// contain spaces.
    ///
    /// `resumeId`, when present and the template declares a resume strategy,
    /// inserts the agent-specific exact-session arguments into the launch
    /// command. `newSessionId` is used only by strategies that support caller-
    /// assigned ids (currently Grok).
    ///
    /// `initialPrompt`, when non-empty, drives the right-click "Ask <agent>"
    /// path: the prompt is POSIX-quoted and inserted into `KOOKY_AGENT` as
    /// the first argv after the binary name (or after `promptLaunchFlag`
    /// when that's set — Copilot's `-p`, Amp's `-x`). Mutually exclusive
    /// with `resumeId` — asking a fresh question shouldn't graft onto a
    /// stale conversation, so `initialPrompt` wins and `resumeId` is
    /// silently dropped when both are supplied.
    /// `rawLaunchCommand` (CLI `open -e`) is a caller-supplied shell command
    /// line that becomes KOOKY_AGENT verbatim — the same eval channel agent
    /// templates use, minus the template composition. Local-only semantics:
    /// when `sshHost` is also set the ssh composition wins and the raw
    /// command is dropped (running caller commands on a remote is not this
    /// parameter's job; the CLI targets local workspaces only).
    func makeSessionConfig(
        extraOptions: String? = nil,
        resumeId: String? = nil,
        newSessionId: String? = nil,
        initialPrompt: String? = nil,
        sshHost: String? = nil,
        rawLaunchCommand: String? = nil
    ) -> TerminalSessionConfig {
        // Pick a shell that has a kooky integration wrapper. Plain terminal
        // sessions respect $SHELL where we have a wrapper (zsh/bash/fish); other
        // shells (nu/...) get $SHELL too, just without cwd tracking.
        // Any session that carries a KOOKY_AGENT launch command — an agent
        // template, ANY template connecting to an `sshHost`, or a raw CLI
        // command — forces a wrapped shell so the auto-launch eval actually
        // runs; `.other` users get zsh as a working fallback.
        let needsLaunch = initialCommand != nil || sshHost != nil || rawLaunchCommand != nil
        var config: TerminalSessionConfig
        switch (KookyShellIntegration.detectedUserShell, needsLaunch) {
        case (.bash, _):
            // nil = launcher couldn't be (re)written (issue #45); fall back to
            // a plain login bash so the user's own config still loads.
            if let launcher = KookyShellIntegration.bashLauncherPath {
                config = .bashShell(launcher: launcher)
            } else {
                config = .defaultShell()
            }
        case (.zsh, _):
            config = .zshShell()
        case (.fish, _):
            config = .fishShell()
        case (.other, false):
            config = .defaultShell()
        case (.other, true):
            config = .zshShell()
        }
        if let sshHost {
            // SSH workspace tab: the local shell's one-shot launch is the
            // kooky-ssh connection; the template's own launch command rides
            // behind `--` and starts on the REMOTE via the ssh wrapper +
            // bootstrap. Built WITHOUT the resume id — conversation state
            // lives on this machine, so `--resume <local-id>` on the remote
            // could only fail at launch.
            let agentSuffix = launchCommand(
                extraOptions: extraOptions,
                resumeId: nil,
                newSessionId: nil,
                initialPrompt: initialPrompt
            )
                .map { " -- \($0)" } ?? ""
            config.environment["KOOKY_AGENT"] = "kooky-ssh \(KookyShellIntegration.quote(sshHost))\(agentSuffix)"
        } else if let rawLaunchCommand {
            config.environment["KOOKY_AGENT"] = rawLaunchCommand
        } else if let launch = launchCommand(
            extraOptions: extraOptions,
            resumeId: resumeId,
            newSessionId: newSessionId,
            initialPrompt: initialPrompt
        ) {
            config.environment["KOOKY_AGENT"] = launch
        }
        return config
    }

    /// The KOOKY_AGENT launch string for this template — binary + resume /
    /// prompt / extra-options fragments — or nil for plain shells. Single
    /// source for both the local launch and the remote (`kooky-ssh … -- <cmd>`)
    /// composition above.
    private func launchCommand(
        extraOptions: String?,
        resumeId: String?,
        newSessionId: String?,
        initialPrompt: String?
    ) -> String? {
        guard let initialCommand else { return nil }
        let trimmedExtras = extraOptions?.trimmingCharacters(in: .whitespaces) ?? ""
        let trimmedPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Resume arguments go between binary name and user options
        // (`claude --resume <id> --model opus`). This is load-bearing for
        // subcommand-shaped resumes such as `codex resume <id>`.
        // Suppressed when `initialPrompt` is present — "Ask <agent>"
        // is a fresh question, not a continuation.
        var resumeFragment = ""
        if
            trimmedPrompt.isEmpty,
            persistsConversation(extraOptions: extraOptions),
            let strategy = resumeStrategy,
            let id = normalizedConversationId(resumeId),
            !id.isEmpty
        {
            resumeFragment = strategy.resumeFragment(conversationId: id)
        } else if
            persistsConversation(extraOptions: extraOptions),
            let strategy = resumeStrategy,
            let id = normalizedConversationId(newSessionId),
            !id.isEmpty
        {
            resumeFragment = strategy.newSessionFragment(conversationId: id)
        }
        var promptFragment = ""
        if !trimmedPrompt.isEmpty {
            let quoted = KookyShellIntegration.quote(trimmedPrompt)
            if let flag = promptLaunchFlag {
                promptFragment = " \(flag) \(quoted)"
            } else {
                // POSIX `--` separator stops the CLI's argparse from
                // treating a prompt that starts with `-` as a flag.
                // Right-clicking `ls -la` output and asking Codex /
                // Claude would otherwise hit "unexpected argument
                // '-rw-r--r--@...'" on the first dashed line.
                promptFragment = " -- \(quoted)"
            }
        }
        let extrasFragment = trimmedExtras.isEmpty ? "" : " \(trimmedExtras)"
        return "\(initialCommand)\(resumeFragment)\(promptFragment)\(extrasFragment)"
    }

    var supportsResume: Bool {
        resumeStrategy != nil
    }

    var preallocatesConversationId: Bool {
        resumeStrategy?.preallocatesNewSessionId == true
    }

    /// Parses a `.env`-style block — one `KEY=VALUE` per line — into a
    /// dictionary. Blank lines and `#` comment lines are skipped, a leading
    /// `export` keyword is dropped (so a block pasted from `.zshrc` works),
    /// and the split is on the *first* `=` so values may contain `=`. A value
    /// wrapped in one matching pair of quotes is unwrapped. Keys that aren't
    /// valid shell identifiers are dropped, as are `KOOKY_`-prefixed keys —
    /// letting a custom agent set `KOOKY_SURFACE_ID` would misroute hook pings.
    static func parseEnv(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        // `\.isNewline` splits LF / CR / CRLF alike — `split(separator: "\n")`
        // misses the `\n` inside the `\r\n` grapheme cluster and would
        // collapse a CRLF block (Windows editor, web copy) into one bad value.
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("export"),
               let separator = trimmed.dropFirst("export".count).first, separator.isWhitespace {
                trimmed = String(trimmed.dropFirst("export".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidEnvKey(key) else { continue }
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, value.last == first,
               first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    /// `^[A-Za-z_][A-Za-z0-9_]*$`, and not kooky-internal (`KOOKY_` prefix).
    private static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first, !key.hasPrefix("KOOKY_") else { return false }
        guard first == "_" || (first.isASCII && first.isLetter) else { return false }
        return key.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }
}

extension AgentTemplate {
    /// The builtin Claude Code agent id. Call sites that gate Claude-
    /// specific behaviour (the custom-agent env block) compare against this
    /// rather than a bare `"claude-code"` literal.
    static let claudeCodeID = "claude-code"
    /// The builtin Pi id. Also marks custom templates whose resume ids use
    /// Pi's canonical UUID format.
    static let piID = "pi"

    static let terminal = AgentTemplate(
        id: "terminal",
        title: "Terminal",
        symbol: "terminal",
        iconAsset: nil,
        tintHex: nil,
        initialCommand: nil
    )

    static let claudeCode = AgentTemplate(
        id: claudeCodeID,
        title: "Claude Code",
        symbol: "sparkle",
        iconAsset: "claudecode",
        tintHex: "D97757",
        initialCommand: "claude",
        resumeStrategy: .arguments(["--resume"]),
        reportsToolCalls: true
    )

    static let codex = AgentTemplate(
        id: "codex",
        title: "Codex",
        symbol: "chevron.left.forwardslash.chevron.right",
        iconAsset: "codex",
        tintHex: "7A9DFF",
        initialCommand: "codex",
        resumeStrategy: .arguments(["resume"])
    )

    static let gemini = AgentTemplate(
        id: "gemini",
        title: "Gemini CLI",
        symbol: "diamond",
        iconAsset: "gemini",
        tintHex: "3186FF",
        initialCommand: "gemini",
        resumeStrategy: .arguments(["--resume"])
    )

    static let opencode = AgentTemplate(
        id: "opencode",
        title: "OpenCode",
        symbol: "curlybraces",
        iconAsset: "opencode",
        tintHex: "B0B0B0",
        initialCommand: "opencode",
        resumeStrategy: .arguments(["--session"])
    )

    static let amp = AgentTemplate(
        id: "amp",
        title: "Amp",
        symbol: "bolt.fill",
        iconAsset: "amp",
        tintHex: "E8B168",
        initialCommand: "amp",
        promptLaunchFlag: "-x",
        resumeStrategy: .arguments(["threads", "continue"])
    )

    static let cursor = AgentTemplate(
        id: "cursor",
        title: "Cursor CLI",
        symbol: "cube",
        iconAsset: "cursor",
        tintHex: "F54E00",
        initialCommand: "cursor-agent",
        resumeStrategy: .optionEquals("--resume")
    )

    static let copilot = AgentTemplate(
        id: "copilot",
        title: "Copilot CLI",
        symbol: "hexagon.fill",
        iconAsset: "githubcopilot",
        tintHex: "6E40C9",
        initialCommand: "copilot",
        promptLaunchFlag: "-p",
        // Upstream shipped resume-by-id as an extension of `--resume`
        // (github/copilot-cli#167); the CLI rejects `--session-id` outright.
        // The equals form is load-bearing: `--resume` takes an OPTIONAL value,
        // so the space form would read the id as a positional prompt.
        resumeStrategy: .optionEquals("--resume")
    )

    static let grok = AgentTemplate(
        id: "grok",
        title: "Grok Build",
        symbol: "x.square.fill",
        iconAsset: "grok",
        tintHex: "E8E8E8",
        initialCommand: "grok",
        resumeStrategy: .preallocated(
            newSessionArguments: ["--session-id"],
            resumeArguments: ["--resume"]
        )
    )

    /// Antigravity CLI — Google's Go-based successor to Gemini CLI; binary
    /// `agy`. The `.gemini` template stays in `builtin` alongside this one
    /// until 2026-06-18 when free/Pro access to Gemini CLI sunsets;
    /// Enterprise (Code Assist Standard/Enterprise) retains the old CLI.
    ///
    /// Naming-conflict footgun: Antigravity 2.0 IDE installs a VS-Code-
    /// style launcher *also* called `agy` at
    /// `~/.antigravity/antigravity/bin/agy`. With only the IDE installed,
    /// `agy` opens the GUI. The CLI installer puts its `agy` in
    /// `~/.local/bin/` (earlier on PATH), so installing the CLI resolves
    /// the conflict.
    ///
    /// `-i` (`--prompt-interactive`) is the right flag for Ask <agent>:
    /// runs the initial prompt and keeps the session alive. `-p`
    /// (`--print`) would single-shot exit.
    ///
    /// Antigravity's named hook collection reports `conversationId` to
    /// kooky; a restored tab launches with `--conversation=<id>`. The same
    /// hooks promote the wrapper's whole-run green state to per-turn
    /// running/attention.
    static let antigravity = AgentTemplate(
        id: "antigravity",
        title: "Antigravity CLI",
        symbol: "arrow.up.circle.fill",
        iconAsset: "antigravity",
        tintHex: "4285F4",
        initialCommand: "agy",
        promptLaunchFlag: "-i",
        resumeStrategy: .optionEquals("--conversation")
    )

    /// Kimi Code — Moonshot AI's coding CLI; binary `kimi` (npm
    /// `@moonshot-ai/kimi-code`). Kooky conservatively merges one delimited
    /// managed block into `~/.kimi-code/config.toml` after Kimi has created
    /// its home directory. Lifecycle hooks report `session_id` and upgrade
    /// the bracket wrapper's whole-run green state to per-turn
    /// running/attention.
    ///
    /// `-p` (`--prompt`) is Kimi's only prompt-passing flag and is
    /// non-interactive (streams the answer to stdout, then exits) — there's
    /// no interactive-with-prompt flag like Antigravity's `-i`, so
    /// "Ask Kimi" single-shots rather than seeding a live session. Restored
    /// tabs use the exact hook-reported id via `--session <id>`.
    static let kimi = AgentTemplate(
        id: "kimi",
        title: "Kimi Code",
        symbol: "moon.fill",
        iconAsset: "kimi",
        tintHex: "C9C3D6",
        initialCommand: "kimi",
        promptLaunchFlag: "-p",
        resumeStrategy: .arguments(["--session"])
    )

    /// Pi — Earendil's minimal terminal coding harness; binary `pi` (npm
    /// `@earendil-works/pi-coding-agent`). No JSON lifecycle hooks, but pi
    /// auto-loads TypeScript extensions with a rich event API, so kooky ships a
    /// managed `~/.pi/agent/extensions/kooky.ts` (see
    /// `piStyleExtensionScript(slug:)`) that
    /// maps pi's session / turn events to running / attention / ended (same
    /// model as the OpenCode plugin) AND reports the session id back so resume
    /// works (below). The bracket wrapper stays as the running/ended fallback +
    /// not-installed message.
    ///
    /// `-p` is pi's one-off non-interactive prompt (streams output then exits),
    /// so "Ask Pi" single-shots rather than seeding a live session. Resume IS
    /// wired: pi takes a launch-time `--session <id>`, and the
    /// extension hands kooky the current session id via
    /// `kooky-hook pi conversation <id>` — that reuses the generic
    /// `conversationId` path (persist on `Session` → prepend `--session <id>`
    /// next launch, gated by `agents.resumeConversations`), so the end result
    /// matches Claude's `--resume` without any Claude-specific JSON parsing.
    /// Model selection (`/model`) stays mid-session. The blocky π logo is
    /// monochrome (single fill, white-on-transparent) → registered in
    /// `AgentIcon.monochromeAssets` so it adapts to light themes.
    static let pi = AgentTemplate(
        id: piID,
        title: "Pi",
        symbol: "pi",
        iconAsset: "pi",
        tintHex: "C2C5CE",
        initialCommand: "pi",
        promptLaunchFlag: "-p",
        resumeStrategy: .arguments(["--session"]),
        reportsToolCalls: true
    )

    /// Oh My Pi — a fork of Pi (`can1357/oh-my-pi`, npm
    /// `@oh-my-pi/pi-coding-agent`, MIT) that adds LSP/DAP, subagents, and a
    /// Rust core; binary `omp` (curl / brew / bun installed). Because it
    /// descends from the same codebase as `.pi`, the extension API is
    /// identical, so kooky ships the same extension under omp's auto-load
    /// directory (`~/.omp/agent/extensions/`, see
    /// `installPiStyleExtensionIfPresent`) and gets attention state, tool-call
    /// pills, and resume rather than settling for the wrapper's running/ended.
    ///
    /// Prompt is positional — interactive `omp "<prompt>"` seeds the REPL,
    /// while `-p` / `--print` is the separate non-interactive single-shot
    /// (not what Ask wants), so Ask sends `omp -- "<prompt>"`. omp's argument
    /// parser honours the POSIX `--` separator, so a prompt starting with `-`
    /// is safe. Restored tabs launch with `--resume <id>`.
    ///
    /// The brand mark is a gradient π (pink → purple → cyan) on a near-black
    /// rounded tile — a full-color mark like codex / kiro, so it is
    /// deliberately NOT in `AgentIcon.monochromeAssets`; `tintHex` takes the
    /// gradient's midpoint purple for the sidebar pip.
    static let ohMyPi = AgentTemplate(
        id: "omp",
        title: "Oh My Pi",
        symbol: "pi",
        iconAsset: "omp",
        tintHex: "9B4DFF",
        initialCommand: "omp",
        resumeStrategy: .arguments(["--resume"]),
        reportsToolCalls: true
    )

    /// Reasonix — DeepSeek-native coding agent (`esengine/DeepSeek-Reasonix`,
    /// npm `reasonix` / Homebrew, MIT); a single static Go binary. Its hooks
    /// reuse Claude's event names and one-JSON-line-on-stdin contract, so the
    /// lifecycle mapping carries over wholesale; the per-entry schema is
    /// flatter, hence its own `reasonixHooksObject`. Tool payloads use their
    /// own field spelling — see `KookyHookKit.ToolPayloadKeys`.
    ///
    /// Prompt uses `-p`: Reasonix's argument parser states outright that
    /// "interactive sessions have no positional arguments", so unlike Droid /
    /// Kiro there is no way to seed a live REPL — Ask single-shots.
    ///
    /// Resume is fully wired: every hook payload carries `sessionId` (a field
    /// the published docs omit but `hook.Payload` defines), which
    /// `parseConversationId` mirrors, and `reasonix --resume <id>` takes that
    /// exact id.
    static let reasonix = AgentTemplate(
        id: "reasonix",
        title: "Reasonix",
        symbol: "brain",
        iconAsset: "reasonix",
        tintHex: "7A6BFF",
        initialCommand: "reasonix",
        promptLaunchFlag: "-p",
        resumeStrategy: .arguments(["--resume"]),
        reportsToolCalls: true
    )

    /// Kiro CLI — AWS's agentic coding CLI, the terminal sibling of the Kiro
    /// IDE; binary `kiro-cli` (curl-installed into `~/.local/bin`). We wrap
    /// `kiro-cli`, NOT `kiro`: the bare `kiro` command launches the Kiro IDE
    /// (a VS Code fork), so shimming it would hijack the editor — the distinct
    /// binary name means no readlink guard is needed (unlike Antigravity's
    /// `agy`). Kiro's dot still comes from the bracket wrapper's
    /// running/ended lifecycle; exact session ids are captured separately
    /// from a per-surface ACP trace selected with `KIRO_ACP_RECORD_PATH`.
    ///
    /// Prompt is positional (`kiro-cli -- "<prompt>"`) — `kiro-cli` with no
    /// subcommand defaults to `kiro-cli chat`, which takes the prompt as its
    /// first positional. (`--no-interactive` exists but single-shots like
    /// Kimi's `-p`, so it's not used for Ask.) Restored tabs launch with
    /// `--resume-id <id>`. The lobe-icon is
    /// the full-color brand mark (purple tile + white ghost), rendered as-is on
    /// every theme like the codex / gemini / amp / antigravity marks — so it's
    /// deliberately NOT in `AgentIcon.monochromeAssets`; `tintHex: "9046FF"`
    /// (brand purple) drives the sidebar pip.
    static let kiro = AgentTemplate(
        id: "kiro",
        title: "Kiro CLI",
        symbol: "cloud.fill",
        iconAsset: "kiro",
        tintHex: "9046FF",
        initialCommand: "kiro-cli",
        resumeStrategy: .arguments(["--resume-id"])
    )

    /// Droid — Factory.ai's agentic coding CLI; binary `droid`
    /// (curl-installed or npm `droid`). After Droid has created
    /// `~/.factory`, kooky merges its own matcher groups into `hooks.json`
    /// without replacing user hooks. The lifecycle feed reports
    /// `session_id` and supplies per-turn running/attention.
    ///
    /// Prompt is positional — interactive `droid "<prompt>"` starts the REPL
    /// seeded with that query (`droid exec "<prompt>"` is the separate
    /// headless single-shot, not what Ask wants), so `promptLaunchFlag` is nil
    /// and Ask sends `droid -- "<prompt>"`. Restored tabs launch with
    /// `--resume <id>`. The brand mark is the white
    /// pinwheel on a black tile; extracted to white-on-transparent and
    /// registered in `AgentIcon.monochromeAssets` so the theme-adaptive
    /// tinting handles light themes (same treatment as grok / kimi / pi).
    static let droid = AgentTemplate(
        id: "droid",
        title: "Droid",
        symbol: "asterisk",
        iconAsset: "droid",
        tintHex: "C9CDD3",
        initialCommand: "droid",
        resumeStrategy: .arguments(["--resume"])
    )

    /// The 16 templates shipped with kooky. User-defined custom agents are
    /// merged on top via `all` at runtime.
    static let builtin: [AgentTemplate] = [.terminal, .claudeCode, .codex, .gemini, .opencode, .amp, .cursor, .copilot, .grok, .antigravity, .kimi, .pi, .ohMyPi, .reasonix, .kiro, .droid]

    /// Builtin lookup by id — session-history resume, filter chips, and row
    /// icons all resolve records back to a template through this.
    static func builtin(id: String) -> AgentTemplate? {
        builtin.first { $0.id == id }
    }

    /// All templates available right now — `builtin` plus the user's custom
    /// agents from Settings → Agents. MainActor-isolated because it
    /// reads `KookySettingsModel.shared` to materialise custom entries.
    @MainActor
    static var all: [AgentTemplate] {
        builtin + KookySettingsModel.shared.customAgents.map(AgentTemplate.fromCustom)
    }

    /// Looks up a template by the slug an agent's hook system reports — the
    /// same string as the template's `initialCommand` (the binary name the
    /// user types). Returns nil for unknown slugs. MainActor because it
    /// pulls the live `all` (built-in + custom).
    @MainActor
    static func from(hookSlug: String) -> AgentTemplate? {
        all.first { $0.initialCommand == hookSlug }
    }

    /// All non-terminal templates resolved against the user's saved order.
    /// Templates absent from `model.agentOrder` (typically: a fresh kooky
    /// install, or an agent shipped in a newer version) are appended in
    /// their `AgentTemplate.all` position so nothing silently disappears.
    @MainActor
    static func ordered(model: KookySettingsModel) -> [AgentTemplate] {
        // Filter by exact terminal id, NOT `!isShell`: this list backs
        // `AgentReorderList.rows` (Settings → Agents), which must keep
        // half-configured customs (initialCommand still nil) visible so
        // the user can finish editing them. `visibleOrdered` does the
        // `initialCommand != nil` gate downstream for the `+` menu.
        let nonTerminal = all.filter { $0.id != AgentTemplate.terminal.id }
        // Use `uniquingKeysWith` so a hand-edited settings.json that puts a
        // custom agent on a builtin id (or two customs on the same id) lands
        // on the first occurrence instead of crashing the launcher. Builtin
        // entries are appended first in `all`, so they win the tie.
        let byId = Dictionary(nonTerminal.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let userOrderIds = model.agentOrder.filter { byId.keys.contains($0) }
        let userOrderSet = Set(userOrderIds)
        let missing = nonTerminal.filter { !userOrderSet.contains($0.id) }
        return userOrderIds.compactMap { byId[$0] } + missing
    }

    /// `+` menu order: pinned Terminal → presets → agents. The
    /// `initialCommand != nil` gate on agents skips half-configured
    /// customs (just-added with no command set) so the launch surface
    /// never spawns a bare Terminal that gets recorded as that custom.
    /// Blank-path presets are skipped for the same reason — they'd
    /// duplicate the default Terminal under a misleading label.
    @MainActor
    static func visibleOrdered(model: KookySettingsModel) -> [AgentTemplate] {
        let presets = model.terminalPresets
            .filter {
                !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !model.hiddenPresets.contains($0.id)
            }
            .map(AgentTemplate.fromTerminalPreset)
        let agents = ordered(model: model).filter {
            !model.hiddenAgents.contains($0.id) && $0.initialCommand != nil
        }
        return [.terminal] + presets + agents
    }

    /// Resolves the user's chosen default template for `+` / `⌘T`. Returns
    /// `nil` (meaning "no default, show the picker") when the saved id is
    /// missing, unknown, or points to an agent the user has since hidden.
    /// Looking the id up in `visibleOrdered` gives the stale-default-after-
    /// hide fallback for free; Terminal is always present there so it stays
    /// selectable even though it's not customisable from the Settings list.
    @MainActor
    static func defaultLaunchTemplate(model: KookySettingsModel) -> AgentTemplate? {
        guard let id = model.defaultAgentId else { return nil }
        return visibleOrdered(model: model).first { $0.id == id }
    }

    /// The Ask roster — every surface that offers "ask an agent" (the
    /// Session Info split button, the right-click "Ask <agent>" menu) starts
    /// from this: the `+` menu's agents in the user's own Settings → Agents
    /// order. Hidden agents are already gone via `visibleOrdered`; shells
    /// (Terminal + presets) are filtered HERE — there's nothing to ask them.
    @MainActor
    static func askAgents(model: KookySettingsModel) -> [AgentTemplate] {
        visibleOrdered(model: model).filter { !$0.isShell }
    }

    /// The user's default launch template resolved against the ask roster —
    /// nil when the default is a shell or unknown, because a shell simply
    /// isn't in the roster. Shared by `askAgent`'s middle clause and the
    /// right-click menu's "▸ Ask" first row, so the two can't drift.
    @MainActor
    static func askDefault(in agents: [AgentTemplate], model: KookySettingsModel) -> AgentTemplate? {
        guard let id = model.defaultAgentId else { return nil }
        return agents.first { $0.id == id }
    }

    /// The agent an "Ask AI" split button's PLAIN click targets: the last one
    /// the user picked from its menu (if still enabled) > the default launch
    /// template (if it IS an agent) > the first enabled agent. nil when every
    /// agent is hidden — the button hides with it. Takes the precomputed
    /// roster so one body evaluation builds it exactly once.
    @MainActor
    static func askAgent(in agents: [AgentTemplate], model: KookySettingsModel) -> AgentTemplate? {
        if let last = model.lastAskAgentId, let hit = agents.first(where: { $0.id == last }) {
            return hit
        }
        return askDefault(in: agents, model: model) ?? agents.first
    }

    /// Materialises a user-defined custom agent into a runtime `AgentTemplate`.
    /// When `baseAgentId` matches a builtin, the custom inherits that
    /// builtin's `iconAsset` / `symbol` / `tintHex` *and* its `initialCommand`
    /// when the user's own `command` is blank — so picking "Claude Code" as
    /// the base and leaving `command` empty launches the base's binary
    /// (`claude`) with the custom's options appended (`--model opus`). A
    /// `(none)` base with empty command stays nil so the `+` menu filter
    /// skips half-configured customs.
    static func fromCustom(_ data: CustomAgentData) -> AgentTemplate {
        let base = builtin.first { $0.id == data.baseAgentId }
        // `promptLaunchFlag` + resume strategy + `reportsToolCalls` follow the
        // base unconditionally — they're properties of the binary (Copilot
        // needs `-p`, Amp needs `-x`; Claude needs `--resume`, Grok needs
        // caller-assigned ids; Claude / Pi feed tool-call activity), not something the
        // user could meaningfully override per custom. Without inheritance, a
        // "Copilot Beta" custom built on Copilot would lose the flag and
        // right-click Ask would feed the prompt as a positional argv that
        // Copilot ignores; a "Claude Opus" custom would lose conversation
        // resume on relaunch and its tool-call pill.
        return AgentTemplate(
            id: data.id,
            title: data.title.isEmpty ? data.id : data.title,
            symbol: data.symbol.isEmpty ? (base?.symbol ?? "wand.and.stars") : data.symbol,
            iconAsset: data.iconAsset.isEmpty ? base?.iconAsset : data.iconAsset,
            tintHex: data.tintHex.isEmpty ? base?.tintHex : data.tintHex,
            initialCommand: data.command.isEmpty ? base?.initialCommand : data.command,
            baseAgentId: data.baseAgentId.isEmpty ? nil : data.baseAgentId,
            promptLaunchFlag: base?.promptLaunchFlag,
            resumeStrategy: base?.resumeStrategy,
            reportsToolCalls: base?.reportsToolCalls ?? false,
            extraEnv: parseEnv(data.env)
        )
    }

    /// Materialises a `TerminalPreset` into a synthetic Terminal-flavored
    /// `AgentTemplate`. `initialCommand` stays nil so `isShell` is true —
    /// the Ask-<agent> right-click filter and the "based on" Picker both
    /// skip these correctly. Title falls through `TerminalPreset.displayTitle`.
    static func fromTerminalPreset(_ preset: TerminalPreset) -> AgentTemplate {
        AgentTemplate(
            id: preset.id,
            title: preset.displayTitle,
            symbol: AgentTemplate.terminal.symbol,
            iconAsset: AgentTemplate.terminal.iconAsset,
            tintHex: AgentTemplate.terminal.tintHex,
            initialCommand: nil,
            extraCwd: preset.path.isEmpty ? nil : preset.path
        )
    }
}

/// User-defined agent entry. Stored in `settings.json` under
/// `agents.custom`; round-tripped through `KookySettingsModel.customAgents`.
struct CustomAgentData: Hashable, Identifiable {
    /// Slug — must be unique across builtin + custom. Generated as
    /// `custom-N` on creation; user-editable from Settings.
    var id: String
    /// Display title shown in the `+` menu and Settings row.
    var title: String
    /// Full launch command, e.g. `aichat --model gpt-4o`. Whitespace-split
    /// by the wrapper's `eval`, same as the `agents.options` field.
    var command: String
    /// `id` of a builtin agent whose icon / tint / SF Symbol the custom
    /// should inherit. Empty = no inheritance (generic `wand.and.stars` +
    /// no tint). Surfaced as the "based on" picker in Settings so a user
    /// can build "Claude Opus" variants that visually belong to the Claude
    /// family without touching iconAsset / tintHex directly.
    var baseAgentId: String
    /// Icon name, resolved by `AgentIcon.nsImage` against two namespaces:
    /// a bundled asset in `Resources/Icons/` (extension-less, e.g. `pi`), or
    /// a user-imported file in App Support written by `AgentIconStore` (always
    /// `<agentId>-<uuid8>.png`). Settings' "icon" row writes the latter;
    /// hand-editing settings.json is the only way to reach the former. Empty
    /// falls back to the `baseAgentId` builtin's iconAsset, or nil if no base.
    var iconAsset: String
    /// SF Symbol override. Power-user; UI hides this. Empty falls back to
    /// the base's symbol, then to `wand.and.stars`.
    var symbol: String
    /// sRGB hex (no `#`) for the sidebar pip tint. Power-user; UI hides
    /// this. Empty falls back to base's tintHex, then nil.
    var tintHex: String
    /// Extra environment variables for the agent, in `.env` syntax (one
    /// `KEY=VALUE` per line). Parsed into `AgentTemplate.extraEnv` by
    /// `AgentTemplate.parseEnv` at `fromCustom` time. v1 only takes effect
    /// for Claude-Code-based customs — written into a per-agent Claude
    /// settings file (`--settings`), never exported to the shell.
    var env: String

    init(
        id: String,
        title: String = "",
        command: String = "",
        baseAgentId: String = "",
        iconAsset: String = "",
        symbol: String = "",
        tintHex: String = "",
        env: String = ""
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.baseAgentId = baseAgentId
        self.iconAsset = iconAsset
        self.symbol = symbol
        self.tintHex = tintHex
        self.env = env
    }
}

/// User-defined "Terminal at <path>" entry. Stored in `settings.json` under
/// `terminals.presets`; round-tripped through `KookySettingsModel.terminalPresets`.
/// Materialised into a synthetic `AgentTemplate` by `AgentTemplate.fromTerminalPreset`
/// so the `+` menu and the spawn pipeline treat presets as Terminal-flavored
/// rows that happen to pin a cwd. Distinct from `CustomAgentData` on purpose
/// — presets aren't agents, they don't run a binary, they don't have hooks /
/// env / options; conflating them would put "Terminal at /foo" into the
/// "Custom Agents" mental model where it doesn't belong.
struct TerminalPreset: Hashable, Identifiable, Sendable {
    /// Slug — must be unique across builtin agents, custom agents, and other
    /// presets. Generated as `preset-N` on creation; user-editable from
    /// Settings is deferred (id stays stable, title carries the rename).
    var id: String
    /// Display name shown in the `+` menu. Falls back to the path's basename
    /// (or the preset id, if path is also empty) when blank.
    var title: String
    /// Initial working directory. Accepts `~/`-prefixed paths; expanded at
    /// spawn time. A missing path resolves to `$HOME` via `resolvedSpawnCwd`.
    var path: String

    init(id: String, title: String = "", path: String = "") {
        self.id = id
        self.title = title
        self.path = path
    }

    /// Effective name for both the Settings row's collapsed header and the
    /// `+` menu entry (via `AgentTemplate.fromTerminalPreset`): explicit
    /// title wins, else the path's basename, else the slug. Single source
    /// so a future tweak (e.g. trimming) can't drift between the two surfaces.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if !path.isEmpty {
            let basename = (path as NSString).lastPathComponent
            if !basename.isEmpty { return basename }
        }
        return id
    }
}
