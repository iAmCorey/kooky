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
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' gemini \(state)")
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
            XCTAssertEqual(inner["command"] as? String, "'\(Self.stubHook)' claude \(state)")
        }
    }

    func testBracketWrapperPassesThroughWhenSurfaceIdMissing() {
        let script = KookyShellIntegration.bracketWrapperScript(slug: "amp")

        XCTAssertTrue(script.contains("self_dir"), "must skip own dir on PATH walk")
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp running"))
        XCTAssertTrue(script.contains("\"$KOOKY_HOOK_BIN\" amp ended"))
        XCTAssertTrue(script.contains("exec \"$real\" \"$@\""), "must passthrough when KOOKY_SURFACE_ID is unset")
    }

    func testOpencodePluginShellsOutToHookBinForBothEvents() {
        let body = KookyShellIntegration.opencodePluginScript

        XCTAssertTrue(body.contains("chat.message"), "plugin must subscribe to per-prompt event")
        XCTAssertTrue(body.contains("session.idle"), "plugin must subscribe to turn-end event")
        XCTAssertTrue(body.contains(#"ping("running")"#))
        XCTAssertTrue(body.contains(#"ping("attention")"#))
        XCTAssertTrue(body.contains("opencode"), "plugin must pass agent slug to KookyHook")
        XCTAssertTrue(body.contains("KOOKY_SURFACE_ID"))
        XCTAssertTrue(body.contains("kooky-managed-do-not-edit"), "plugin must carry the upgrade-safety marker")
    }

    func testAgentLaunchBlockDefinesFunctionAndDoesNotInlineEval() {
        // Inline `eval "$KOOKY_AGENT"` during zshrc parsing inherits
        // Powerlevel10k's redirected stdio (p10k captures stdout/stderr
        // until first prompt renders), so agents launched there see a
        // non-TTY stdin/stdout and silently switch into non-interactive
        // mode — Claude Code 2.x then errors with "Input must be provided
        // ... when using --print". The launch path must define a function
        // we can hook into precmd / PROMPT_COMMAND instead.
        let body = KookyShellIntegration.agentLaunchBlock

        XCTAssertTrue(body.contains("__kooky_agent_launch()"),
                      "agentLaunchBlock must declare __kooky_agent_launch as a function")
        XCTAssertTrue(body.contains("KOOKY_AGENT_LAUNCHED"),
                      "must guard against re-entry from agent-spawned subshells")
        XCTAssertTrue(body.contains(#"eval "$_kooky_cmd""#),
                      "must still eval the launch command after guards pass")
        XCTAssertFalse(body.contains(#"if [[ -n "$KOOKY_AGENT" && -z "$KOOKY_AGENT_LAUNCHED" ]]; then"#),
                      "must NOT inline-eval during zshrc parsing — defer to precmd")
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

    func testBackslashEscapeFallsBackToQuoteOnNewlineToAvoidLineContinuation() {
        // POSIX: `\<newline>` is line continuation and gets dropped — so a
        // legitimate macOS filename containing `\n` would be silently
        // corrupted by the plain backslash-escape path. Codex P3 fix
        // (v0.11.3): fall back to single-quote wrap, which preserves the
        // literal newline.
        let escaped = KookyShellIntegration.backslashEscape("/tmp/multi\nline/file.txt")
        XCTAssertEqual(escaped, "'/tmp/multi\nline/file.txt'")
    }
}
