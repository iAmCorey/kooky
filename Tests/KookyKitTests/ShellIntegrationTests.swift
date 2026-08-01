import AppKit
import XCTest
@testable import KookyKit

/// Verifies the *content* the integration generates. Tests do not invoke
/// `installAgentHooks()` because that writes to user-config dirs using a
/// hookCmd derived from the running binary (xctest's helpers under
/// `/Applications/Xcode.app/...`), which would pollute and corrupt
/// real user config files. Self-heals on next kooky launch but better
/// avoided: the writers are trivial, the content getters are the
/// load-bearing surface.
final class ShellIntegrationTests: XCTestCase {
    private static let stubHook = "/usr/local/bin/KookyHook"

    func testGeminiDefaultsExposesAllFourLifecycleEvents() throws {
        let object = KookyShellIntegration.geminiDefaultsObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        let expected: [String: String] = [
            "BeforeAgent": "running",
            "AfterAgent": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ]
        for (event, state) in expected {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["type"] as? String, "command")
            XCTAssertEqual(
                inner["command"] as? String,
                "KOOKY_MANAGED_HOOK=1 '\(Self.stubHook)' gemini \(state) --hook-stdin"
            )
        }
    }

    func testClaudeHooksObjectStaysWiredAfterRefactor() throws {
        let object = KookyShellIntegration.claudeHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for (event, state) in [
            "UserPromptSubmit": "running",
            "Stop": "attention",
            "Notification": "attention",
            "SessionEnd": "ended",
        ] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(
                inner["command"] as? String,
                "KOOKY_MANAGED_HOOK=1 '\(Self.stubHook)' claude \(state) --hook-stdin"
            )
        }
    }

    func testClaudeWrapperScopesNoSessionPersistenceToActualInvocation() {
        let script = KookyShellIntegration.claudeWrapperScript
        let scan = #"if [[ "$_kooky_arg" == "--no-session-persistence" ]]; then"#
        let marker = "export KOOKY_CLAUDE_NO_SESSION_PERSISTENCE=1"
        let launch = #""$real" --settings "$KOOKY_HOOKS_PATH" "$@""#

        XCTAssertTrue(script.contains(scan))
        XCTAssertTrue(script.contains("unset KOOKY_CLAUDE_NO_SESSION_PERSISTENCE"))
        XCTAssertTrue(script.contains(#"[[ "$_kooky_arg" == "--" ]] && break"#))
        XCTAssertTrue(script.contains(marker))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: marker)?.lowerBound),
            try XCTUnwrap(script.range(of: launch)?.lowerBound),
            "marker must be inherited by Claude and its hook subprocesses"
        )
    }

    /// Tool-call lifecycle subscriptions added for the activity strip. These
    /// differ from lifecycle hooks: the third command argv preserves the raw
    /// event name (`PreToolUse` / `PostToolUse`) because `main.swift` reads
    /// stdin and routes through `KookyHookKit.parseToolEventPayload` for
    /// these — not a `HookEvent` rawValue.
    func testClaudeHooksObjectSubscribesToolCallEvents() throws {
        let object = KookyShellIntegration.claudeHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for event in ["PreToolUse", "PostToolUse"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(inner["type"] as? String, "command")
            // argv[2] = raw Claude event name (not a HookEvent rawValue)
            XCTAssertEqual(
                inner["command"] as? String,
                "KOOKY_MANAGED_HOOK=1 '\(Self.stubHook)' claude \(event) --hook-stdin"
            )
        }
    }

    /// Regression guard — Gemini wrapper doesn't expose tool-level hooks
    /// (per CLAUDE.md M5.x); its passthroughEvents stays empty. If we ever
    /// add tool events to Gemini, update this test deliberately.
    func testGeminiHooksObjectDoesNotSubscribeToolEvents() throws {
        let object = KookyShellIntegration.geminiDefaultsObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PostToolUse"])
    }

    func testBracketWrapperPassesThroughWhenSurfaceIdMissing() {
        let script = KookyShellIntegration.bracketWrapperScript(slug: "amp")

        XCTAssertTrue(script.contains("self_dir"), "must skip own dir on PATH walk")
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp running"))
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp ended"))
        XCTAssertTrue(script.contains("kooky-agent:amp:running"))
        XCTAssertTrue(script.contains("kooky-agent:amp:ended"))
        XCTAssertTrue(script.contains("KOOKY_AGENT_MARKERS"))
        XCTAssertTrue(script.contains("2>/dev/null > /dev/tty"), "OSC marker targets the tty (not a redirected agent's stdout), stderr silenced before the open so a missing tty can't leak")
        XCTAssertTrue(script.contains("[[ -n \"$KOOKY_AGENT_MARKERS\" ]] && printf"), "marker gated on KOOKY_AGENT_MARKERS so local sessions stay socket-only")
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testWrapperPassesThroughForBackgroundPipedCaller() {
        // A background / programmatic caller (a broker spawning the agent to
        // speak JSON-RPC over piped stdin+stdout) is not a session a human is
        // watching. The shared preamble must exec the real binary before any
        // instrumentation runs, so the wrapper never pings KookyHook.
        let script = KookyShellIntegration.bracketWrapperScript(slug: "amp")
        XCTAssertTrue(script.contains("if [[ ! -t 0 && ! -t 1 ]]; then"),
                      "preamble must pass through when both stdin and stdout are non-terminals")
    }

    func testCodexWrapperGuardsBackgroundCallBeforeInstrumenting() {
        // The reported hang: a broker spawns `codex app-server` (JSON-RPC over
        // piped stdin+stdout) and `codex:review` freezes. The guard must run
        // before the KookyHook ping and before the `-c notify` injection (which
        // would alter the codex the broker spawned).
        let script = KookyShellIntegration.codexWrapperScript
        let guardLine = "if [[ ! -t 0 && ! -t 1 ]]; then"
        XCTAssertTrue(script.contains(guardLine), "codex wrapper must pass through a pipe-driven background call")

        let guardIdx = script.range(of: guardLine)!.lowerBound
        let pingIdx = script.range(of: "\"$KOOKY_HOOK_BIN\" codex running")!.lowerBound
        let notifyIdx = script.range(of: "notify=")!.lowerBound
        XCTAssertLessThan(guardIdx, pingIdx, "tty guard must precede the KookyHook running ping")
        XCTAssertLessThan(guardIdx, notifyIdx, "tty guard must precede the -c notify injection")
    }

    func testAntigravityIDEShimCheckPrecedesTtyPassthrough() {
        // The generic pipe-driven passthrough must NOT run before agy's
        // IDE-launcher rejection — otherwise a background `agy` call (both fds
        // piped) would exec the resolved binary, reopening the GUI the wrapper
        // exists to block. The IDE-shim `case` must come first.
        let script = KookyShellIntegration.antigravityWrapperScript
        let ideIdx = script.range(of: "*/Antigravity.app/*")!.lowerBound
        let guardIdx = script.range(of: "if [[ ! -t 0 && ! -t 1 ]]; then")!.lowerBound
        XCTAssertLessThan(ideIdx, guardIdx, "IDE-shim rejection must precede the tty passthrough")
    }

    @MainActor
    func testAgentStatusMarkerParsesKnownAgentTitle() throws {
        let parsed = try XCTUnwrap(AgentStatusMarker.parseTitle("kooky-agent:codex:attention"))

        XCTAssertEqual(parsed.agent.id, AgentTemplate.codex.id)
        XCTAssertEqual(parsed.event, .attention)
        XCTAssertNil(AgentStatusMarker.parseTitle("kooky-agent:not-real:running"))
        XCTAssertNil(AgentStatusMarker.parseTitle("corey@web-prod: ~/srv"))
    }

    func testKimiWrapperBracketsRunningAndEnded() {
        // The wrapper remains the launch/exit fallback around Kimi's finer
        // TOML lifecycle hooks.
        let script = KookyShellIntegration.bracketWrapperScript(slug: "kimi")

        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" kimi running"))
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" kimi ended"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testGeminiWrapperBracketsRunningAndEnded() {
        // The wrapper gives an immediate launch promotion while Gemini's
        // system-settings hooks provide the finer per-turn state. Same-value
        // pings deduplicate.
        let script = KookyShellIntegration.bracketWrapperScript(slug: "gemini")

        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" gemini running"))
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" gemini ended"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testSshWrapperInjectsRemoteBootstrapForPlainInteractiveLogin() {
        let script = KookyShellIntegration.sshWrapperScript

        XCTAssertTrue(script.contains("KOOKY_DISABLE_SSH_AGENT_MARKERS"))
        XCTAssertTrue(script.contains("! -t 0 || ! -t 1"), "must skip non-interactive ssh transport")
        XCTAssertTrue(script.contains("remote_command="), "must append exactly one remote shell command")
        XCTAssertTrue(script.contains("sh -lc"), "remote command should run through POSIX sh")
        // NO exec on the interactive path: the wrapper waits for ssh so it
        // can emit the logout marker afterwards — the signal `remoteHost`'s
        // whole-connection lifetime hangs on. INT/QUIT are ignored in the
        // wrapper (ssh still gets them) so a Ctrl+C'd ssh can't abort the
        // script before the marker; ssh's exit status is preserved.
        XCTAssertTrue(script.contains("\"$real\" -t \"${_kooky_mux_opts[@]}\" \"${args[@]}\" \"$remote_command\""))
        XCTAssertFalse(script.contains("exec \"$real\" -t"), "interactive path must not exec — the logout marker comes after ssh returns")
        XCTAssertTrue(script.contains("trap '' INT QUIT"))
        XCTAssertTrue(script.contains(RemoteLoginMarker.logoutTitle))
        XCTAssertTrue(script.contains("exit \"$_kooky_ssh_status\""))
    }

    func testSshWrapperGatesAgentProtocolOnKookySshName() {
        let script = KookyShellIntegration.sshWrapperScript

        // The `--` remote-agent protocol must be locked to the kooky-ssh
        // filename. The public `ssh` shim shares this script; a manually
        // typed `ssh host -- cmd` must keep plain ssh semantics.
        XCTAssertTrue(script.contains(#""${0##*/}" == "kooky-ssh" && "$arg" == "--""#))
        // Agent argv is re-quoted and handed to the bootstrap via an `env`
        // prefix — a command, not `VAR=val cmd` shell syntax, so a csh /
        // old-fish remote login shell can still parse the remote command.
        XCTAssertTrue(script.contains("env KOOKY_REMOTE_AGENT="))
        XCTAssertTrue(script.contains(#"printf -v _kooky_remote_agent '%q '"#))
    }

    func testSshWrapperMultiplexesOnlyKookySshConnections() {
        let script = KookyShellIntegration.sshWrapperScript

        // The main connection's ControlPath must be the exact option set the
        // paste upload uses — same socket template is what lets the headless
        // scp ride the workspace's interactively authenticated connection
        // (password / passphrase auth workspaces can't paste otherwise).
        let muxLine = "_kooky_mux_opts=(\(KookyShellIntegration.sshMultiplexOptions.joined(separator: " ")))"
        XCTAssertTrue(script.contains(muxLine))
        XCTAssertTrue(
            KookyShellIntegration.sshMultiplexOptions.contains(
                "ControlPath=\(KookyShellIntegration.sshControlDirectory)/control-%C"
            )
        )
        // Gated on the kooky-ssh filename — the public `ssh` shim must not
        // silently switch manual ssh onto shared connections.
        XCTAssertTrue(script.contains("if [[ \"${0##*/}\" == \"kooky-ssh\" ]]; then"))
    }

    func testMoshWrapperReportsMissingAndNonzeroLaunchFailures() {
        let script = KookyShellIntegration.moshWrapperScript
        XCTAssertTrue(script.contains("mosh is not installed on this Mac"))
        XCTAssertTrue(script.contains("kooky-remote-failure:missing:mosh"))
        XCTAssertTrue(script.contains("kooky-remote-failure:exit:"))
        XCTAssertTrue(script.contains("kooky-remote-exit:"))
        XCTAssertTrue(script.contains("SECONDS < 15"))
        XCTAssertTrue(script.contains("exit \"$status\""))
    }

    func testSshWrapperPassesThroughRemoteCommandsAndTransportModes() {
        let script = KookyShellIntegration.sshWrapperScript

        // A no-remote-shell flag anywhere in a short-option group (e.g. `-fN`
        // in `ssh -fN -L …`) passes through untouched — regression guard for
        // clobbering combined-flag port forwards.
        XCTAssertTrue(script.contains("[NTVGQOW]) exec \"$real\" \"$@\""))
        // An explicit `-o RemoteCommand=…` is the user's own remote command;
        // don't override it with our bootstrap.
        XCTAssertTrue(script.contains("[Rr]emote[Cc]ommand*) exec \"$real\" \"$@\""))
        XCTAssertTrue(script.contains("remote_command_seen=1"))
        XCTAssertTrue(script.contains("if (( ! destination_seen || remote_command_seen )); then"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""))
    }

    func testRemoteAgentBootstrapWritesMarkerWrappers() {
        let script = KookyShellIntegration.remoteAgentBootstrapScript

        XCTAssertTrue(script.contains(#"_kooky_root="${TMPDIR:-/tmp}/kooky-agent-markers-"#))
        XCTAssertTrue(script.contains("for _kooky_slug in 'claude' 'codex'"))
        // Every builtin agent's binary must flow into the bootstrap (the slug
        // list derives from `builtin`), so a remote launch of any agent —
        // including future ones — emits markers. A new agent silently missing
        // from the SSH bootstrap fails here instead of shipping a dead shim.
        for binary in AgentTemplate.builtin.compactMap(\.initialCommand) {
            XCTAssertTrue(script.contains("'\(binary)'"),
                          "remote bootstrap must include a marker shim for '\(binary)'")
        }
        XCTAssertTrue(script.contains(#"printf '\033]2;kooky-agent:%s:running\a'"#))
        XCTAssertTrue(script.contains(#"printf '\033]2;kooky-agent:%s:ended\a'"#))
        XCTAssertTrue(script.contains("export KOOKY_AGENT_MARKERS=1"))
        XCTAssertTrue(script.contains(#"export PATH="$_kooky_bin:$PATH""#))
        XCTAssertTrue(script.contains("> /dev/tty"), "remote markers must target the tty, not the agent's redirected stdout")
        XCTAssertTrue(script.contains("export HISTFILE="), "remote zsh must reset HISTFILE off the ephemeral ZDOTDIR (else remote history is rm -rf'd on logout)")
    }

    func testRemoteBootstrapLaunchesRequestedAgentInEveryShellBranch() {
        let script = KookyShellIntegration.remoteAgentBootstrapScript

        // One eval site per shell branch (zsh rc, bash rc, POSIX fallback):
        // the agent must start AFTER the user's rc replay so PATH managers
        // like nvm are loaded — the whole reason agent launch rides the
        // bootstrap instead of a bare ssh remote command.
        let evalSites = script.components(separatedBy: "KOOKY_REMOTE_AGENT").count - 1
        XCTAssertGreaterThanOrEqual(evalSites, 6, "expected the launch block in all three shell branches")
        XCTAssertTrue(script.contains(#"eval "\$_kooky_remote_agent""#), "zsh/bash rc branches eval the agent command")
        XCTAssertTrue(script.contains(#"eval "$_kooky_remote_agent""#), "POSIX fallback branch evals the agent command")
        // Consumed exactly once — nested shells must not relaunch the agent.
        XCTAssertTrue(script.contains("unset KOOKY_REMOTE_AGENT"))
    }

    func testAntigravityWrapperGuardsAgainstIDEShim() {
        // Antigravity 2.0 IDE installs a launcher also called `agy` that
        // symlinks into `/Applications/Antigravity.app/...`. Without
        // detection, an IDE-only-installed user picking "Antigravity CLI"
        // from `+` would accidentally open the GUI app.
        let script = KookyShellIntegration.antigravityWrapperScript

        XCTAssertTrue(script.contains("readlink \"$real\""), "must resolve symlink one hop")
        XCTAssertTrue(script.contains("*/Antigravity.app/*"), "must match IDE launcher resolved path")
        XCTAssertTrue(script.contains("antigravity.google/cli/install.sh"), "must surface CLI install command")
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" agy ended"), "must revert tab icon on shim-detection bail")
        XCTAssertTrue(script.contains("exit 127"), "must mirror preamble's not-installed exit code")
    }

    func testAntigravityWrapperBracketsRunningAndEndedForRealCLI() {
        let script = KookyShellIntegration.antigravityWrapperScript

        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" agy running"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testCursorHooksMergePreservesUserEntriesAndAddsResumeIdCapture() throws {
        let existing: [String: Any] = [
            "version": 1,
            "custom": "keep-me",
            "hooks": [
                "stop": [["command": "user-stop-hook"]],
            ],
        ]
        let object = try XCTUnwrap(
            KookyShellIntegration.cursorHooksObject(existing: existing, hookCmd: Self.stubHook)
        )
        XCTAssertEqual(object["custom"] as? String, "keep-me")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["stop"] as? [[String: Any]])
        XCTAssertTrue(stop.contains { ($0["command"] as? String) == "user-stop-hook" })
        XCTAssertTrue(stop.contains {
            ($0["command"] as? String)?.contains("cursor-agent attention --hook-stdin") == true
        })
        let start = try XCTUnwrap((hooks["sessionStart"] as? [[String: Any]])?.last)
        XCTAssertTrue((start["command"] as? String)?.contains("KOOKY_MANAGED_HOOK=1") == true)
    }

    func testDroidHooksMergePreservesUserGroups() throws {
        let existing: [String: Any] = [
            "logoAnimation": "once",
            "hooks": [
                "SessionStart": [[
                    "matcher": "",
                    "hooks": [["type": "command", "command": "user-hook"]],
                ]],
            ],
        ]
        let object = try XCTUnwrap(
            KookyShellIntegration.droidHooksObject(existing: existing, hookCmd: Self.stubHook)
        )
        XCTAssertEqual(object["logoAnimation"] as? String, "once")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(String(describing: groups).contains("user-hook"))
        XCTAssertTrue(String(describing: groups).contains("droid running --hook-stdin"))
        XCTAssertTrue(KookyShellIntegration.droidSettingsPath.hasSuffix("/.factory/settings.json"))
    }

    func testReasonixHooksMergePreservesUnrelatedSettingsAndUserHooks() throws {
        // This file is the user's ENTIRE Reasonix global config — provider
        // setup, UI prefs, their own hooks — not a hooks-only file kooky owns.
        // Dropping a sibling key here would silently wipe real configuration,
        // so pin both an unrelated top-level key and a user hook under an
        // event kooky also writes.
        let existing: [String: Any] = [
            "theme": "dark",
            "providers": ["deepseek": ["model": "deepseek-pro"]],
            "hooks": [
                "Stop": [["command": "user-hook"]],
            ],
        ]
        let object = try XCTUnwrap(
            KookyShellIntegration.reasonixHooksObject(existing: existing, hookCmd: Self.stubHook)
        )

        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertNotNil(object["providers"], "must not drop unrelated config")

        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "kooky's entry must be added alongside the user's, not replace it")
        XCTAssertTrue(String(describing: stop).contains("user-hook"))
        XCTAssertTrue(String(describing: stop).contains("reasonix attention"))
    }

    func testReasonixHooksMapEveryLifecycleAndToolEvent() throws {
        let object = try XCTUnwrap(
            KookyShellIntegration.reasonixHooksObject(hookCmd: Self.stubHook)
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        // Notification is what makes a pending tool approval show up as
        // "waiting on you" — Reasonix emits it natively for that case.
        let expected: [String: String] = [
            "SessionStart":     "reasonix running",
            "UserPromptSubmit": "reasonix running",
            "Stop":             "reasonix attention",
            "StopFailure":      "reasonix attention",
            "Notification":     "reasonix attention",
            "SessionEnd":       "reasonix ended",
        ]
        for (event, fragment) in expected {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing \(event)")
            let command = try XCTUnwrap(entries.first?["command"] as? String)
            XCTAssertTrue(command.contains(fragment), "\(event) must map to \(fragment)")
        }

        // PostToolUseFailure is Reasonix's explicit tool-error event; without
        // it a failed call waits on the tool_response heuristic (or the 60s
        // stall timer) before the pill turns red.
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing \(event)")
            let entry = try XCTUnwrap(entries.first)
            let command = try XCTUnwrap(entry["command"] as? String)
            XCTAssertTrue(command.contains("reasonix \(event) --hook-stdin"),
                          "tool events must pipe their payload for the activity pill")
            XCTAssertEqual(entry["match"] as? String, "*", "must match every tool")
        }

        // Reasonix reads `timeout` as MILLISECONDS (Droid's is seconds). A
        // seconds-shaped value here would time out every single ping, and
        // PreToolUse/UserPromptSubmit are BLOCKING events — a timeout there
        // stalls the user's agent, not just the dot.
        for value in hooks.values {
            for entry in (value as? [[String: Any]] ?? []) {
                let timeout = try XCTUnwrap(entry["timeout"] as? Int)
                XCTAssertGreaterThanOrEqual(timeout, 1000, "timeout is milliseconds, not seconds")
                XCTAssertLessThanOrEqual(timeout, 5000, "must stay under Reasonix's blocking-event default")
            }
        }

        XCTAssertTrue(KookyShellIntegration.reasonixSettingsPath.hasSuffix("/.reasonix/settings.json"))
    }

    func testAntigravityHooksUseOwnedNamedCollection() throws {
        let object = KookyShellIntegration.antigravityHooksObject(
            existing: ["user-hook": ["enabled": true]],
            hookCmd: Self.stubHook
        )
        XCTAssertNotNil(object["user-hook"])
        let managed = try XCTUnwrap(object["kooky-managed-do-not-edit"] as? [String: Any])
        XCTAssertTrue(String(describing: managed["PreInvocation"]).contains("agy running --hook-stdin"))
        XCTAssertTrue(String(describing: managed["Stop"]).contains("agy attention --hook-stdin"))
    }

    func testKimiManagedTomlBlockIsIdempotentAndPreservesUserConfig() throws {
        let existing = """
        model = "kimi-for-coding"

        [[hooks]]
        event = "Notification"
        command = "user-notify"
        """
        let once = try XCTUnwrap(
            KookyShellIntegration.kimiConfigWithManagedHooks(existing: existing, hookCmd: Self.stubHook)
        )
        let twice = try XCTUnwrap(
            KookyShellIntegration.kimiConfigWithManagedHooks(existing: once, hookCmd: Self.stubHook)
        )
        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.hasPrefix(existing), "bytes outside kooky's managed block must stay untouched")
        XCTAssertTrue(twice.contains("user-notify"))
        XCTAssertEqual(twice.components(separatedBy: "hooks begin").count - 1, 1)
        XCTAssertTrue(twice.contains("kimi running --hook-stdin"))
        XCTAssertTrue(twice.contains("kimi attention --hook-stdin"))
    }

    func testKimiManagedTomlRejectsHalfMarker() {
        XCTAssertNil(
            KookyShellIntegration.kimiConfigWithManagedHooks(
                existing: "# kooky-managed-do-not-edit hooks begin\n",
                hookCmd: Self.stubHook
            )
        )
    }

    func testCopilotHooksReadSessionIdFromStdin() throws {
        let object = KookyShellIntegration.copilotHooksObject(hookCmd: Self.stubHook)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let start = try XCTUnwrap((hooks["sessionStart"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap(start["bash"] as? String)
        XCTAssertTrue(command.contains("copilot running --hook-stdin"))
        XCTAssertTrue(command.contains("KOOKY_MANAGED_HOOK=1"))
    }

    func testOpencodePluginShellsOutToHookBinForBothEvents() {
        let body = KookyShellIntegration.opencodePluginScript

        XCTAssertTrue(body.contains("chat.message"), "plugin must subscribe to per-prompt event")
        XCTAssertTrue(body.contains("session.idle"), "plugin must subscribe to turn-end event")
        XCTAssertTrue(body.contains(#"ping("running")"#))
        XCTAssertTrue(body.contains(#"ping("attention")"#))
        XCTAssertTrue(body.contains("opencode"), "plugin must pass agent slug to KookyHook")
        XCTAssertTrue(body.contains("conversation"), "plugin must report the exact session id")
        XCTAssertTrue(body.contains("sessionID"))
        XCTAssertTrue(body.contains("client.session.get"), "every indirect event must resolve its session metadata")
        XCTAssertTrue(body.contains("reportRootSession(sessionID)"))
        XCTAssertTrue(body.contains("reportRootSession(event?.properties?.sessionID)"))
        XCTAssertFalse(body.contains("reportSession(sessionID)"), "subagent ids must never bypass the root-session check")
        XCTAssertTrue(body.contains("!info?.parentID"), "subagent ids must not replace the root session id")
        XCTAssertTrue(body.contains("KOOKY_SURFACE_ID"))
        XCTAssertTrue(body.contains("kooky-managed-do-not-edit"), "plugin must carry the upgrade-safety marker")
    }

    func testAmpPluginReportsThreadIdAndPerTurnLifecycle() {
        let body = KookyShellIntegration.ampPluginScript
        XCTAssertTrue(body.contains(#"amp.on("session.start""#))
        XCTAssertTrue(body.contains("event?.thread?.id"))
        XCTAssertTrue(body.contains(#"["amp", "conversation", id]"#))
        XCTAssertTrue(body.contains(#"amp.on("agent.start""#))
        XCTAssertTrue(body.contains(#"amp.on("agent.end""#))
        XCTAssertTrue(body.contains("kooky-managed-do-not-edit"))
    }

    func testKiroWrapperScopesACPRecordingToKookyInvocation() {
        let body = KookyShellIntegration.kiroWrapperScript
        XCTAssertTrue(body.contains("KOOKY_KIRO_ACP_RECORD_PATH"))
        XCTAssertTrue(body.contains(#"KIRO_ACP_RECORD_PATH="$KOOKY_KIRO_ACP_RECORD_PATH" "$real" "$@""#))
        XCTAssertTrue(body.contains("\"$KOOKY_HOOK_BIN\" kiro-cli running"))
        XCTAssertTrue(body.contains("exec \"$real\" \"$@\""), "outside kooky it must stay transparent")
    }

    func testPiExtensionSubscribesLifecycleEventsAndPingsHook() {
        let body = KookyShellIntegration.piStyleExtensionScript(slug: "pi")

        // Subscribes to pi's session / turn lifecycle and maps each to a
        // KookyHook state — running while a turn runs, attention when it ends.
        XCTAssertTrue(body.contains("session_start"))
        XCTAssertTrue(body.contains("turn_start"))
        XCTAssertTrue(body.contains("turn_end"))
        XCTAssertTrue(body.contains("session_shutdown"))
        XCTAssertTrue(body.contains(#"ping("running")"#))
        XCTAssertTrue(body.contains(#"ping("attention")"#))
        XCTAssertTrue(body.contains(#"ping("ended")"#))
        XCTAssertTrue(body.contains(#"pi.exec(hookBin, ["pi""#), "must ping KookyHook with the pi slug")
        // Reports the session id so kooky can resume (`pi --session <id>`).
        XCTAssertTrue(body.contains("getSessionId"), "must read pi's canonical session id")
        XCTAssertTrue(
            body.contains("if (!manager || !manager.getSessionFile()) return"),
            "must not persist an id for pi's ephemeral --no-session mode"
        )
        XCTAssertTrue(
            body.contains("const id = manager.getSessionId()"),
            "must not derive the id from pi's timestamp-prefixed filename"
        )
        XCTAssertTrue(body.contains(#"["pi", "conversation", id]"#), "must report the session id for resume")
        XCTAssertTrue(body.contains("KOOKY_SURFACE_ID"))
        XCTAssertTrue(body.contains("KOOKY_HOOK_BIN"))
        XCTAssertTrue(body.contains("kooky-managed-do-not-edit"), "must carry the upgrade-safety marker")
    }

    func testPiExtensionReportsToolCallsForActivityPill() {
        let body = KookyShellIntegration.piStyleExtensionScript(slug: "pi")
        // Subscribes to pi's tool lifecycle and relays each to KookyHook's
        // `tool` argv branch (pre carries the identifier, post the ok/fail).
        XCTAssertTrue(body.contains("tool_execution_start"))
        XCTAssertTrue(body.contains("tool_execution_end"))
        XCTAssertTrue(body.contains(#"["pi", "tool", "pre""#), "pre must report the identifier")
        XCTAssertTrue(body.contains(#"["pi", "tool", "post""#), "post must report the result")
        XCTAssertTrue(body.contains("event.toolCallId"), "must thread pi's toolCallId for Pre/Post matching")
        XCTAssertTrue(body.contains(#"event.isError ? "fail" : "ok""#), "post maps isError → ok/fail")
        // identifier extraction uses pi's arg keys (`path`, not Claude's
        // `file_path`) and lowercase tool names.
        XCTAssertTrue(body.contains("toolIdentifier"))
        XCTAssertTrue(body.contains("args.command"))
        XCTAssertTrue(body.contains("args.path"))
        XCTAssertTrue(body.contains("args.pattern"))
    }

    func testPiStyleExtensionRoutesEveryPingToItsOwnSlug() {
        // Oh My Pi is a fork of Pi, so both agents share one extension script
        // with the slug substituted in. Every KookyHook argv the script emits
        // opens with that slug — it is what attributes the ping to a tab's
        // agent — so a single missed substitution would silently file omp's
        // lifecycle, tool calls, and (worst) its resume id under Pi instead:
        // omp's dot would never light and a Pi tab could be handed omp's
        // session id. Assert the negative too, so any argv left hardcoded
        // fails here rather than in the user's sidebar.
        let body = KookyShellIntegration.piStyleExtensionScript(slug: "omp")

        XCTAssertTrue(body.contains(#"pi.exec(hookBin, ["omp", state]"#), "lifecycle ping must carry the omp slug")
        XCTAssertTrue(body.contains(#"["omp", "conversation", id]"#), "resume id must be reported as omp's")
        XCTAssertTrue(body.contains(#"["omp", "tool", "pre""#), "tool pre must carry the omp slug")
        XCTAssertTrue(body.contains(#"["omp", "tool", "post""#), "tool post must carry the omp slug")
        XCTAssertFalse(
            body.contains(#"["pi""#),
            "no KookyHook argv may stay hardcoded to pi — that misattributes omp's events"
        )
        // The `pi` identifier itself is the extension API's own parameter name
        // (`export default function (pi)`), shared by both forks — it is not
        // the slug and must survive substitution.
        XCTAssertTrue(body.contains("export default function (pi)"), "extension factory arg is API, not slug")
    }

    func testPiStyleExtensionReportsPendingToolApprovalAsAttention() {
        // A tool waiting on approval blocks MID-turn, so `turn_end` never
        // fires — without its own subscription the tab stays on "running"
        // while the agent is in fact waiting on the user, costing the sidebar
        // dot and the notification. Resolving hands control back to the agent,
        // so that maps straight back to running.
        let body = KookyShellIntegration.piStyleExtensionScript(slug: "omp")

        XCTAssertTrue(
            body.contains(#"pi.on("tool_approval_requested", async () => { await ping("attention") })"#),
            "a pending approval must report attention, not stay on running"
        )
        XCTAssertTrue(
            body.contains(#"pi.on("tool_approval_resolved", async () => { await ping("running") })"#),
            "a resolved approval must return the tab to running"
        )
    }

    func testAgentLaunchBlockRevertsIconAfterAgentReturns() {
        let block = KookyShellIntegration.agentLaunchBlock
        // The eagerly-promoted tab/sidebar icon must revert when the foreground
        // agent exits — or never started, e.g. a user alias shadowing the PATH
        // wrapper so its own `ended` ping never fires.
        XCTAssertTrue(block.contains("eval \"$_kooky_cmd\""))
        XCTAssertTrue(block.contains(#"_kooky_agent_bin="${_kooky_cmd%% *}""#), "must derive the agent binary for the revert ping")
        XCTAssertTrue(block.contains(#""$KOOKY_HOOK_BIN" "$_kooky_agent_bin" ended"#), "must ping ended after the agent returns")
        // The revert ping must not clobber the agent's exit code — capture it
        // before, restore it after, so the first prompt's `$?` is the agent's.
        XCTAssertTrue(block.contains("_kooky_status=$?"), "must capture the agent exit status before the revert ping")
        XCTAssertTrue(block.contains("( exit $_kooky_status )"), "must restore the agent exit status after the ping")
    }

    func testEnvStatusBlockReportsLiveShellEnvironment() {
        let body = KookyShellIntegration.envStatusBlock

        XCTAssertTrue(body.contains("\"$KOOKY_HOOK_BIN\" env"))
        XCTAssertTrue(body.contains(#""${VIRTUAL_ENV:-}""#))
        XCTAssertTrue(body.contains(#""${CONDA_DEFAULT_ENV:-}""#))
        XCTAssertTrue(body.contains(#""${NVM_BIN:-}""#))
        XCTAssertTrue(body.contains(#""${NVM_DIR:-}""#))
        XCTAssertTrue(body.contains("--version"), "must invoke node --version")
        XCTAssertTrue(body.contains("_KOOKY_NODE_KEY_LAST"), "must memoize node version against path+NVM_BIN")
        XCTAssertTrue(body.contains("_KOOKY_ENV_LAST"), "must skip the kooky-hook IPC when env unchanged")
    }

    func testFishInitScriptPrependsWrapperPathAndTracksCwd() {
        let s = KookyShellIntegration.fishInitScript
        // The core fix for fish users: force the wrapper dir to the FRONT of PATH
        // so a manually-typed `claude` resolves to our shim (lights the dot) —
        // even when config.fish / fish_add_path left it mid-PATH behind
        // ~/.local/bin. Must dedupe + prepend, not a `contains`-guarded skip.
        XCTAssertTrue(s.contains(#"set -gx PATH "$KOOKY_BIN_DIR" (string match -v -- "$KOOKY_BIN_DIR" $PATH)"#), "must move the wrapper dir to the front, dropping any mid-PATH copy")
        XCTAssertTrue(s.contains(#"test "$PATH[1]" = "$KOOKY_BIN_DIR"; and return"#), "must skip when already first (no per-prompt PATH churn)")
        // PATH prepend lives in a fish_prompt hook so it runs AFTER config.fish.
        XCTAssertTrue(s.contains("function __kooky_prompt --on-event fish_prompt"), "PATH/cwd work must defer to a prompt hook (runs after config.fish)")
        // fish never emits OSC 7, so cwd tracking is always ours.
        XCTAssertTrue(s.contains(#"printf '\e]7;file://%s%s\e\\'"#), "must emit OSC 7 for cwd tracking")
    }

    func testFishInitScriptGuardsNonInteractiveShells() {
        // vendor_conf.d is read by non-interactive fish too; wiring prompt hooks
        // there would be wasted work — bail early.
        XCTAssertTrue(KookyShellIntegration.fishInitScript.contains("status is-interactive"))
    }

    func testFishInitScriptGatesOSC133OnLegacyFish() {
        let s = KookyShellIntegration.fishInitScript
        // fish 4+ emits OSC 133 natively — adding ours unconditionally would
        // double-mark every prompt. The version gate is load-bearing.
        XCTAssertTrue(s.contains(#"set -l __kooky_major (string split '.' -- $version)[1]"#))
        XCTAssertTrue(s.contains(#"test "$__kooky_major" -lt 4"#), "must only add OSC 133 on fish 3.x")
        XCTAssertTrue(s.contains(#"printf '\e]133;D;%s\a' $status"#), "the 3.x path must report command exit status")
    }

    func testFishInitScriptAutoLaunchesAgentAsOneShotPromptHook() {
        let s = KookyShellIntegration.fishInitScript
        // Agent launch defers to the first prompt (after config.fish) and removes
        // itself so it can't re-fire.
        XCTAssertTrue(s.contains("function __kooky_agent_launch --on-event fish_prompt"), "agent launch must be a prompt hook (runs after config.fish set up PATH/env)")
        XCTAssertTrue(s.contains("functions -e __kooky_agent_launch"), "must self-remove to stay one-shot")
        XCTAssertTrue(s.contains("eval $_kooky_cmd"), "must launch KOOKY_AGENT via eval for multi-word commands")
        XCTAssertTrue(s.contains("KOOKY_AGENT_LAUNCHED"), "must guard against subshell re-entry")
        XCTAssertTrue(s.contains(#""$KOOKY_HOOK_BIN" $_kooky_bin ended"#), "must ping ended after the agent returns")
    }

    func testCleanupRemovesOnlyCurrentPidTempFiles() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory()
        let pid = getpid()
        let mine = ["kooky-zsh-\(pid)", "kooky-bash-launch-\(pid).sh", "kooky-fish-init-\(pid).fish"]
        // Decoys: another process's file, and a non-kooky file — both must survive.
        let others = ["kooky-zsh-9999999", "notkooky-\(pid).txt"]
        for name in mine + others { fm.createFile(atPath: dir.appending(name), contents: Data()) }
        defer { for name in others { try? fm.removeItem(atPath: dir.appending(name)) } }

        KookyShellIntegration.cleanup()

        for name in mine {
            XCTAssertFalse(fm.fileExists(atPath: dir.appending(name)), "\(name) should be swept")
        }
        for name in others {
            XCTAssertTrue(fm.fileExists(atPath: dir.appending(name)), "\(name) must NOT be touched")
        }
    }

    @MainActor
    func testFishShellInjectsVendorConfViaXdgDataDirs() throws {
        // libghostty's spawn path ignores `.arguments`, and `-C` runs after
        // config.fish (swallowed by shell-wrapping autocomplete). So fish gets
        // its integration via XDG_DATA_DIRS → vendor_conf.d instead.
        let config = TerminalSessionConfig.fishShell()
        XCTAssertTrue(config.arguments.isEmpty, "must NOT rely on .arguments — libghostty drops it")
        let xdg = try XCTUnwrap(config.environment["XDG_DATA_DIRS"])
        XCTAssertTrue(xdg.hasPrefix("\(KookyShellIntegration.fishVendorDataRoot):"), "kooky data root must be prepended, preserving existing dirs")
        // The vendor conf must live where fish discovers it.
        XCTAssertTrue(KookyShellIntegration.fishVendorConfPath.hasSuffix("/fish/vendor_conf.d/kooky.fish"))
        XCTAssertTrue(KookyShellIntegration.fishVendorConfPath.hasPrefix(KookyShellIntegration.fishVendorDataRoot))
    }

    @MainActor
    func testInstallFishVendorConfWritesDiscoverableFile() throws {
        KookyShellIntegration.installFishVendorConf()
        let written = try String(contentsOfFile: KookyShellIntegration.fishVendorConfPath, encoding: .utf8)
        XCTAssertEqual(written, KookyShellIntegration.fishInitScript, "installed vendor conf must match the source script")
    }

    @MainActor
    func testHookServerParsesAgentPayload() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "agent": "claude",
            "event": "running",
            "surface": id.uuidString,
        ])

        guard case .agent(let agent, let event, let sessionId) = HookServer.parseMessage(data) else {
            return XCTFail("expected agent hook message")
        }
        XCTAssertEqual(agent, .claudeCode)
        XCTAssertEqual(event, .running)
        XCTAssertEqual(sessionId, id)
    }

    @MainActor
    func testHookServerParsesShellEnvironmentPayload() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "env",
            "surface": id.uuidString,
            "VIRTUAL_ENV": "/tmp/app/.venv",
            "CONDA_DEFAULT_ENV": "",
            "NVM_BIN": "/Users/corey/.nvm/versions/node/v20.1.0/bin",
            "NVM_DIR": "/Users/corey/.nvm",
            "KOOKY_NODE_VERSION": "v20.1.0",
        ])

        guard case .shellEnvironment(let env, let sessionId) = HookServer.parseMessage(data) else {
            return XCTFail("expected shell environment hook message")
        }
        XCTAssertEqual(sessionId, id)
        XCTAssertEqual(env["VIRTUAL_ENV"], "/tmp/app/.venv")
        XCTAssertEqual(env["NVM_BIN"], "/Users/corey/.nvm/versions/node/v20.1.0/bin")
        XCTAssertEqual(env["NVM_DIR"], "/Users/corey/.nvm")
        XCTAssertEqual(env["KOOKY_NODE_VERSION"], "v20.1.0")
    }

    func testBackslashEscapeLeavesPlainPathUntouched() {
        XCTAssertEqual(KookyShellIntegration.backslashEscape("/Users/corey/file.txt"), "/Users/corey/file.txt")
    }

    func testBackslashEscapeEscapesSpaceAndQuoteAndDollar() {
        XCTAssertEqual(
            KookyShellIntegration.backslashEscape("/Users/corey/My Folder/don't $cost"),
            #"/Users/corey/My\ Folder/don\'t\ \$cost"#
        )
    }

    func testBackslashEscapePassesThroughNonAscii() {
        // Chinese / emoji filenames are common on macOS; shells accept raw
        // UTF-8 so we don't escape them.
        XCTAssertEqual(KookyShellIntegration.backslashEscape("/tmp/项目/🚀.md"), "/tmp/项目/🚀.md")
    }

    func testClaudeCustomSettingsObjectCarriesHooksAndEnv() throws {
        let object = KookyShellIntegration.claudeCustomSettingsObject(
            env: ["ANTHROPIC_BASE_URL": "https://mirror.example.com"],
            hookCmd: Self.stubHook
        )
        // The env block Claude reads natively for the custom endpoint / key.
        let env = try XCTUnwrap(object["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://mirror.example.com")
        // Hooks must ride along — the per-agent file is the only settings
        // file passed to that session, so kooky's activity hooks have to be
        // in it too, not just the env block.
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        let inner = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            inner["command"] as? String,
            "KOOKY_MANAGED_HOOK=1 '\(Self.stubHook)' claude running --hook-stdin"
        )
    }

    func testBackslashEscapeFallsBackToQuoteOnNewlineToAvoidLineContinuation() {
        // POSIX: `\<newline>` is line continuation and gets dropped — so a
        // legitimate macOS filename containing `\n` would be silently
        // corrupted by the plain backslash-escape path. Codex P3 fix
        // (v0.11.3): fall back to single-quote wrap, which preserves the
        // literal newline.
        let escaped = KookyShellIntegration.backslashEscape("/tmp/multi\nline/file.txt")
        XCTAssertEqual(escaped, "'/tmp/multi\nline/file.txt'")
    }

    // MARK: - readTerminalPasteText / pasteboardHasTerminalPasteContent

    /// Create an isolated pasteboard so tests never touch `.general` or
    /// each other. `NSPasteboard(name:)` with a unique name returns a
    /// process-private board that AppKit cleans up on exit.
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let unique = "kooky-test-\(UUID().uuidString)"
        return NSPasteboard(name: NSPasteboard.Name(unique))
    }

    /// 1×1 transparent PNG — small valid PNG to exercise the image-spill path.
    private static let oneByOnePNG: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIA" +
        "AAoAAv/lxKUAAAAASUVORK5CYII="
    )!

    func testReadTerminalPasteTextReturnsRawStringForPlainText() {
        // String paste is the common case (Cmd+V on a shell command).
        // No backslash-escaping — `ls -la` must round-trip verbatim.
        let pb = makeIsolatedPasteboard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("ls -la", forType: .string)
        XCTAssertEqual(KookyShellIntegration.readTerminalPasteText(from: pb), "ls -la")
    }

    func testReadTerminalPasteTextReturnsEscapedPathForFileURL() {
        // Finder Copy on a file (including images) gives a fileURL on the
        // pasteboard. We backslash-escape the full disk path so the
        // shell / agent receives an addressable argument — not the bare
        // filename that `.string` would return.
        let pb = makeIsolatedPasteboard()
        let url = URL(fileURLWithPath: "/tmp/some folder/image one.png")
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        XCTAssertEqual(
            KookyShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/some\\ folder/image\\ one.png"
        )
    }

    func testReadTerminalPasteTextJoinsMultipleFileURLsWithSpace() {
        let pb = makeIsolatedPasteboard()
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])
        XCTAssertEqual(
            KookyShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/a.png /tmp/b.png"
        )
    }

    func testReadTerminalPasteTextSpillsPNGImageDataToCacheFile() throws {
        // Cmd+Ctrl+Shift+4 screenshots show up as raw PNG bytes with no
        // fileURL representation. Without spill-to-disk the agent has no
        // way to read the image — we cache it under
        // ~/Library/Caches/kooky/pastes/screenshot-*.png and paste the
        // escaped file path.
        let pb = makeIsolatedPasteboard()
        pb.declareTypes([.png], owner: nil)
        pb.setData(Self.oneByOnePNG, forType: .png)
        let pasted = try XCTUnwrap(KookyShellIntegration.readTerminalPasteText(from: pb))
        // Resolve the escape so we can `stat` the file.
        let rawPath = pasted.replacingOccurrences(of: "\\", with: "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawPath),
            "Expected pasted path to point at a real file on disk: \(rawPath)"
        )
        XCTAssertTrue(rawPath.contains("/kooky/pastes/screenshot-"))
        XCTAssertTrue(rawPath.hasSuffix(".png"))
        try? FileManager.default.removeItem(atPath: rawPath)
    }

    func testReadTerminalPasteTextSpillsTIFFImageDataAsPNG() throws {
        // Cmd+Shift+3 (full-screen-to-clipboard) and Preview "Copy" land
        // as TIFF on the pasteboard, not PNG — the TIFF→PNG re-encode
        // branch is the actual screenshot hot path. Without coverage
        // this can regress silently if someone tweaks the helper.
        let pb = makeIsolatedPasteboard()
        // Synthesise a 1×1 TIFF via NSBitmapImageRep so we exercise the
        // re-encode branch without bundling a binary fixture.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        )!
        let tiffData = try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))
        pb.declareTypes([.tiff], owner: nil)
        pb.setData(tiffData, forType: .tiff)
        let pasted = try XCTUnwrap(KookyShellIntegration.readTerminalPasteText(from: pb))
        let rawPath = pasted.replacingOccurrences(of: "\\", with: "")
        XCTAssertTrue(rawPath.hasSuffix(".png"))
        // Confirm we actually wrote PNG bytes (not TIFF with a .png suffix).
        let cached = try XCTUnwrap(FileManager.default.contents(atPath: rawPath))
        XCTAssertNotNil(NSBitmapImageRep(data: cached), "Cached file should parse as a bitmap image")
        let magic = cached.prefix(8)
        XCTAssertEqual(
            Array(magic),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "Cached file should have a PNG magic header, not TIFF"
        )
        try? FileManager.default.removeItem(atPath: rawPath)
    }

    func testReadTerminalPasteTextPrefersFileURLOverImageData() {
        // Finder Copy on an image populates both fileURL and TIFF/PNG.
        // fileURL must win — the user already has a real file on disk;
        // re-spilling the bytes to a cache file loses provenance + bloats
        // ~/Library/Caches.
        let pb = makeIsolatedPasteboard()
        let url = URL(fileURLWithPath: "/tmp/real-image.png")
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setData(Self.oneByOnePNG, forType: .png)
        XCTAssertEqual(
            KookyShellIntegration.readTerminalPasteText(from: pb),
            "/tmp/real-image.png"
        )
    }

    func testReadTerminalPasteTextReturnsNilForEmptyPasteboard() {
        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        XCTAssertNil(KookyShellIntegration.readTerminalPasteText(from: pb))
    }

    // MARK: - remote paste upload (SSH workspaces)

    func testRemotePasteUploadRunsMkdirThenScpAndReturnsRemotePath() async throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var commands: [(String, [String])] = []
            func record(_ exe: String, _ args: [String]) {
                lock.lock(); defer { lock.unlock() }
                commands.append((exe, args))
            }
        }
        let recorder = Recorder()
        KookyShellIntegration.remotePasteProcessRunnerOverride = { exe, args, _ in
            recorder.record(exe, args)
            return true
        }
        defer { KookyShellIntegration.remotePasteProcessRunnerOverride = nil }

        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/some folder/图 one.png") as NSURL])

        let upload = try XCTUnwrap(
            KookyShellIntegration.remotePasteUpload(from: pb, host: "deploy@example.com")
        )
        let uploaded = await upload()
        let pasted = try XCTUnwrap(uploaded)

        // Remote path, sanitized filename (non-ASCII → `_`, then leading
        // `._-` trimmed), no trace of the local dir.
        XCTAssertTrue(pasted.hasPrefix("/tmp/kooky-pastes-"), pasted)
        XCTAssertTrue(pasted.hasSuffix("/one.png"), pasted)
        XCTAssertFalse(pasted.contains("some"))

        XCTAssertEqual(recorder.commands.count, 2)
        XCTAssertEqual(recorder.commands[0].0, "/usr/bin/ssh")
        XCTAssertTrue(recorder.commands[0].1.contains("deploy@example.com"))
        XCTAssertTrue(recorder.commands[0].1.contains("--"))
        XCTAssertTrue(recorder.commands[0].1.last?.contains("mkdir -p -- '/tmp/kooky-pastes-") == true)
        // The mkdir ride-along sweep: expired paste dirs from earlier
        // sessions get removed without an extra connection.
        XCTAssertTrue(recorder.commands[0].1.last?.contains("-name 'kooky-pastes-*'") == true)
        XCTAssertTrue(recorder.commands[0].1.last?.contains("-mmin +60") == true)
        XCTAssertEqual(recorder.commands[1].0, "/usr/bin/scp")
        XCTAssertTrue(recorder.commands[1].1.contains("--"))
        XCTAssertTrue(recorder.commands[1].1.contains("/tmp/some folder/图 one.png"))
        XCTAssertTrue(recorder.commands[1].1.last?.hasPrefix("deploy@example.com:/tmp/kooky-pastes-") == true)
        // BatchMode so a passwordless-auth miss fails fast instead of
        // hanging the upload on an invisible prompt (the multiplex master —
        // shared with the workspace's own connection — is what carries
        // interactive-auth setups past this).
        XCTAssertTrue(recorder.commands[0].1.contains("BatchMode=yes"))
        XCTAssertTrue(recorder.commands[0].1.contains("ControlMaster=auto"))
        XCTAssertTrue(recorder.commands[1].1.contains(
            "ControlPath=\(KookyShellIntegration.sshControlDirectory)/control-%C"
        ))
    }

    func testRemotePasteUploadFailsClosedWhenTransferFails() async throws {
        KookyShellIntegration.remotePasteProcessRunnerOverride = { _, _, _ in false }
        defer { KookyShellIntegration.remotePasteProcessRunnerOverride = nil }

        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/real-image.png") as NSURL])

        let upload = try XCTUnwrap(
            KookyShellIntegration.remotePasteUpload(from: pb, host: "deploy@example.com")
        )
        let pasted = await upload()

        XCTAssertNil(pasted, "a failed upload must paste nothing — never the local path")
    }

    @MainActor
    func testRemotePasteFailureIsReportedWithoutDeliveringLocalPath() async {
        KookyShellIntegration.remotePasteProcessRunnerOverride = { _, _, _ in false }
        defer { KookyShellIntegration.remotePasteProcessRunnerOverride = nil }
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/private-local-path.png") as NSURL,
        ])
        let failure = expectation(description: "visible failure callback")
        var delivered: [String] = []

        XCTAssertTrue(KookyShellIntegration.paste(
            from: pasteboard,
            target: RemoteUploadTarget(destination: "deploy@example.com"),
            onRemoteFailure: { failure.fulfill() },
            deliver: { delivered.append($0) }
        ))
        await fulfillment(of: [failure], timeout: 2)

        XCTAssertTrue(delivered.isEmpty)
    }

    func testMoshRemotePasteUsesSameSSHPortIdentityAndMultiplexPathAsControl() async throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var commands: [(String, [String])] = []
            func record(_ executable: String, _ arguments: [String]) {
                lock.lock()
                commands.append((executable, arguments))
                lock.unlock()
            }
        }
        let recorder = Recorder()
        KookyShellIntegration.remotePasteProcessRunnerOverride = { executable, arguments, _ in
            recorder.record(executable, arguments)
            return true
        }
        defer { KookyShellIntegration.remotePasteProcessRunnerOverride = nil }

        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/real-image.png") as NSURL])
        let target = RemoteUploadTarget(
            destination: "deploy@example.com",
            sshPort: 2222,
            identityFile: "/tmp/key with spaces"
        )
        let upload = try XCTUnwrap(
            KookyShellIntegration.remotePasteUpload(from: pasteboard, target: target)
        )
        let result = await upload()
        XCTAssertNotNil(result)
        XCTAssertEqual(recorder.commands.count, 2)
        for (_, arguments) in recorder.commands {
            XCTAssertTrue(arguments.contains("2222"))
            XCTAssertTrue(arguments.contains("/tmp/key with spaces"))
            XCTAssertTrue(arguments.contains(
                "ControlPath=\(KookyShellIntegration.sshControlDirectory)/control-%C"
            ))
        }
    }

    func testRemotePasteUploadReturnsNilForPlainText() {
        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        pb.setString("echo hello", forType: .string)

        // Plain text stays a local paste — no subprocess, no upload closure.
        XCTAssertNil(KookyShellIntegration.remotePasteUpload(from: pb, host: "deploy@example.com"))
    }

    func testPasteboardHasTerminalPasteContentMatchesReadability() {
        // Gate must agree with `readTerminalPasteText` so the right-click
        // Paste menu enables exactly when the action will produce input.
        let emptyPb = makeIsolatedPasteboard()
        emptyPb.clearContents()
        XCTAssertFalse(KookyShellIntegration.pasteboardHasTerminalPasteContent(emptyPb))

        let stringPb = makeIsolatedPasteboard()
        stringPb.declareTypes([.string], owner: nil)
        stringPb.setString("x", forType: .string)
        XCTAssertTrue(KookyShellIntegration.pasteboardHasTerminalPasteContent(stringPb))

        let filePb = makeIsolatedPasteboard()
        filePb.clearContents()
        filePb.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertTrue(KookyShellIntegration.pasteboardHasTerminalPasteContent(filePb))

        let imagePb = makeIsolatedPasteboard()
        imagePb.declareTypes([.png], owner: nil)
        imagePb.setData(Self.oneByOnePNG, forType: .png)
        XCTAssertTrue(KookyShellIntegration.pasteboardHasTerminalPasteContent(imagePb))
    }

    // MARK: - $TMPDIR bridge self-heal (issue #45)
    //
    // macOS's periodic cleanup deletes $TMPDIR files not accessed for 3 days;
    // the bridge rcs are only read when a terminal spawns, so a long-lived
    // kooky loses them and every new tab got a bare shell. These pin the
    // rebuild-on-access fix. Safe against the running kooky instance: the
    // paths carry getpid(), which here is the xctest runner's pid.

    func testZshBridgeRebuildsAfterTmpdirCleanup() throws {
        let fm = FileManager.default
        let dir = try XCTUnwrap(KookyShellIntegration.zshDirectory)
        let rcPath = (dir as NSString).appendingPathComponent(".zshrc")
        XCTAssertTrue(fm.fileExists(atPath: rcPath))
        let original = try String(contentsOfFile: rcPath, encoding: .utf8)

        // The issue's second-scale repro: delete just the rc.
        try fm.removeItem(atPath: rcPath)
        let dirAgain = try XCTUnwrap(KookyShellIntegration.zshDirectory)
        XCTAssertEqual(dirAgain, dir)
        XCTAssertEqual(try String(contentsOfFile: rcPath, encoding: .utf8), original)

        // Cleanup also prunes emptied directories — heal from that too.
        try fm.removeItem(atPath: dir)
        _ = try XCTUnwrap(KookyShellIntegration.zshDirectory)
        XCTAssertEqual(try String(contentsOfFile: rcPath, encoding: .utf8), original)
    }

    func testBashLauncherRebuildsAfterTmpdirCleanup() throws {
        let fm = FileManager.default
        let launcher = try XCTUnwrap(KookyShellIntegration.bashLauncherPath)
        // Pins the kooky-bashrc-<pid> naming alongside the launcher's: both
        // are what `cleanup()`'s glob sweeps and what the issue-#45 repro
        // command targets — a rename should trip this line.
        let rcfile = NSTemporaryDirectory().appending("kooky-bashrc-\(getpid())")
        XCTAssertTrue(fm.fileExists(atPath: launcher))
        XCTAssertTrue(fm.fileExists(atPath: rcfile))
        let originalLauncher = try String(contentsOfFile: launcher, encoding: .utf8)
        let originalRc = try String(contentsOfFile: rcfile, encoding: .utf8)

        try fm.removeItem(atPath: launcher)
        try fm.removeItem(atPath: rcfile)
        let launcherAgain = try XCTUnwrap(KookyShellIntegration.bashLauncherPath)
        XCTAssertEqual(launcherAgain, launcher)
        XCTAssertEqual(try String(contentsOfFile: launcher, encoding: .utf8), originalLauncher)
        XCTAssertEqual(try String(contentsOfFile: rcfile, encoding: .utf8), originalRc)
        XCTAssertTrue(fm.isExecutableFile(atPath: launcher))
    }

    /// Private named pasteboard — never touches the user's real clipboard.
    private func makeTextPasteboard(_ text: String) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("kooky-test-\(UUID().uuidString)"))
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        return pb
    }

    /// Plain clipboard text at a terminal site must go through the engine's
    /// protected paste (clipboard-paste-protection), never straight to
    /// `deliver` — the whole point of `PlainTextHandling.viaCore`.
    @MainActor
    func testPastePlainTextRoutesThroughCoreNotDeliver() {
        let pb = makeTextPasteboard("echo hi\nrm -rf /\n")
        defer { pb.releaseGlobally() }
        var coreCalls = 0
        var delivered: [String] = []
        let handled = KookyShellIntegration.paste(
            from: pb,
            host: nil,
            plainText: .viaCore({ coreCalls += 1; return true }),
            deliver: { delivered.append($0) }
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(coreCalls, 1)
        XCTAssertTrue(delivered.isEmpty, "plain text must not bypass the protected path")
    }

    /// The composer opts out of plain text entirely (native NSTextView paste
    /// keeps undo coalescing) — the ladder reports unhandled.
    @MainActor
    func testPastePlainTextCallerHandlesFallsThrough() {
        let pb = makeTextPasteboard("plain text")
        defer { pb.releaseGlobally() }
        var delivered: [String] = []
        let handled = KookyShellIntegration.paste(
            from: pb,
            host: nil,
            plainText: .callerHandles,
            deliver: { delivered.append($0) }
        )
        XCTAssertFalse(handled)
        XCTAssertTrue(delivered.isEmpty)
    }
}
