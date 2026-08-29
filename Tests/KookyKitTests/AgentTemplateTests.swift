import XCTest
@testable import KookyKit

@MainActor
final class AgentTemplateTests: XCTestCase {
    func testTerminalTemplateHasNoAgentEnv() {
        XCTAssertNil(AgentTemplate.terminal.makeSessionConfig().environment["KOOKY_AGENT"])
    }

    /// Plain shell tabs (no launch command) and Claude Code keep the `\`+CR
    /// newline trick (kittyProtocol=false); every agent that actually
    /// launches a non-Claude TUI speaks CSI-u (kittyProtocol=true).
    func testKittyProtocolFlagPerSessionKind() {
        XCTAssertFalse(
            AgentTemplate.terminal.makeSessionConfig().kittyProtocol,
            "plain shell tab must keep the backslash-CR newline trick"
        )
        XCTAssertFalse(
            AgentTemplate.claudeCode.makeSessionConfig().kittyProtocol,
            "Claude Code must keep the backslash-CR trick"
        )
        for template in AgentTemplate.all where template.id != "terminal" && template.id != AgentTemplate.claudeCodeID {
            XCTAssertTrue(
                template.makeSessionConfig().kittyProtocol,
                "agent template \(template.id) must speak CSI-u"
            )
        }
    }

    func testAgentTemplatesPublishKookyAgentEnv() {
        for template in AgentTemplate.all where template.id != "terminal" {
            XCTAssertEqual(
                template.makeSessionConfig().environment["KOOKY_AGENT"],
                template.initialCommand,
                "agent template \(template.id) must publish KOOKY_AGENT matching its initialCommand"
            )
        }
    }

    func testAllTemplatesAreUniqueAndIncludeTerminal() {
        let ids = AgentTemplate.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
        XCTAssertTrue(ids.contains("terminal"))
    }

    func testTerminalTemplateUsesUserDefaultShell() {
        let expected = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        XCTAssertEqual(AgentTemplate.terminal.makeSessionConfig().command, expected)
    }

    func testAgentTemplatesPickAShellWithIntegrationWrapper() {
        // Agent must run under one of our wrappers (zsh ZDOTDIR or bash
        // --rcfile) — anything else means KOOKY_AGENT never fires.
        for template in AgentTemplate.all where template.id != "terminal" {
            let cmd = template.makeSessionConfig().command
            XCTAssertTrue(
                cmd == "/bin/zsh" || cmd.contains("kooky-bash-launch-"),
                "agent template \(template.id) launched without a kooky shell wrapper: \(cmd)"
            )
        }
    }

    func testBuiltinTemplatesHaveNoBaseAgentId() {
        for template in AgentTemplate.builtin {
            XCTAssertNil(template.baseAgentId, "builtin \(template.id) must not declare a base")
        }
    }

    func testFromCustomSnapshotsBaseAgentId() {
        let data = CustomAgentData(id: "claude-opus", baseAgentId: "claude-code")
        XCTAssertEqual(AgentTemplate.fromCustom(data).baseAgentId, "claude-code")
    }

    func testFromCustomTreatsEmptyBaseAsNil() {
        let data = CustomAgentData(id: "loose-custom", command: "aichat")
        XCTAssertNil(AgentTemplate.fromCustom(data).baseAgentId)
    }

    @MainActor
    func testOrderedKeepsHalfConfiguredCustoms() {
        // Regression: when `ordered(model:)` filtered with `!isShell`, a
        // freshly-added custom agent (initialCommand still nil until the
        // user fills `command` or picks a `baseAgentId`) vanished from
        // Settings → Agents — the user couldn't continue editing the row
        // they just created. `ordered` must keep these visible; the
        // `+` menu's own `initialCommand != nil` gate (in `visibleOrdered`)
        // is what hides them from the launch surface.
        //
        // `ordered` reads `customAgents` off `KookySettingsModel.shared`
        // (via `all`), so the test snapshots + restores the singleton
        // rather than constructing a fresh model.
        let model = KookySettingsModel.shared
        let snapshot = model.customAgents
        defer { model.customAgents = snapshot }
        model.customAgents = [CustomAgentData(id: "draft-custom")]
        let ordered = AgentTemplate.ordered(model: model)
        XCTAssertTrue(ordered.contains(where: { $0.id == "draft-custom" }),
                      "half-configured custom must stay in Settings list")
    }

    // MARK: - Terminal presets

    func testFromTerminalPresetSnapshotsPathAsExtraCwd() {
        let preset = TerminalPreset(id: "preset-1", title: "Work", path: "~/projects/foo")
        let template = AgentTemplate.fromTerminalPreset(preset)
        XCTAssertEqual(template.id, "preset-1")
        XCTAssertEqual(template.title, "Work")
        XCTAssertEqual(template.extraCwd, "~/projects/foo")
        XCTAssertNil(template.initialCommand, "presets are terminals — must not carry a binary")
        XCTAssertEqual(template.iconAsset, AgentTemplate.terminal.iconAsset)
    }

    func testFromTerminalPresetTitleFallsBackToBasename() {
        // Blank title is fine — many users will rename later. Until they
        // do, the path basename reads better than `preset-1`.
        let preset = TerminalPreset(id: "preset-1", title: "", path: "~/projects/foo")
        XCTAssertEqual(AgentTemplate.fromTerminalPreset(preset).title, "foo")
    }

    func testFromTerminalPresetTitleFallsBackToIdWhenAllBlank() {
        let preset = TerminalPreset(id: "preset-1", title: "", path: "")
        XCTAssertEqual(AgentTemplate.fromTerminalPreset(preset).title, "preset-1")
    }

    func testFromTerminalPresetTreatsEmptyPathAsNilExtraCwd() {
        // Empty path = no override → addTab falls through to the workspace
        // cwd instead of trying to expand "" via NSString.
        let preset = TerminalPreset(id: "preset-1", title: "Untouched", path: "")
        XCTAssertNil(AgentTemplate.fromTerminalPreset(preset).extraCwd)
    }

    func testVisibleOrderedDropsHiddenPresets() {
        // Toggling a preset off in Settings → Terminals should remove it
        // from the `+` menu but keep its config alive — symmetric with
        // hiding an agent via the Agents toggle.
        let model = KookySettingsModel()
        model.terminalPresets = [
            TerminalPreset(id: "preset-shown", title: "Shown", path: "/tmp"),
            TerminalPreset(id: "preset-hidden", title: "Hidden", path: "/var"),
        ]
        model.hiddenPresets = ["preset-hidden"]
        model.hiddenAgents = []
        model.agentOrder = []
        let ids = AgentTemplate.visibleOrdered(model: model).map(\.id)
        XCTAssertTrue(ids.contains("preset-shown"))
        XCTAssertFalse(ids.contains("preset-hidden"), "hidden preset must not appear in + menu")
    }

    func testVisibleOrderedDropsPresetsWithBlankPath() {
        // A just-added preset with no path entered yet must not pollute
        // the `+` menu — it would render as a no-op duplicate of the
        // default Terminal under a misleading "preset-N" label.
        let model = KookySettingsModel()
        model.terminalPresets = [
            TerminalPreset(id: "preset-blank", title: "Blank", path: ""),
            TerminalPreset(id: "preset-whitespace", title: "Whitespace", path: "   "),
            TerminalPreset(id: "preset-real", title: "Real", path: "/tmp"),
        ]
        model.hiddenAgents = []
        model.agentOrder = []
        let ids = AgentTemplate.visibleOrdered(model: model).map(\.id)
        XCTAssertFalse(ids.contains("preset-blank"), "blank-path preset must not appear in + menu")
        XCTAssertFalse(ids.contains("preset-whitespace"), "whitespace-only path counts as blank")
        XCTAssertTrue(ids.contains("preset-real"), "path-bearing preset still surfaces")
    }

    func testVisibleOrderedInsertsPresetsBetweenTerminalAndAgents() {
        // A fresh model reads the user's actual settings.json — overwrite
        // the slots we care about so the test stays deterministic across
        // machines and across whatever the developer has saved locally.
        let model = KookySettingsModel()
        model.terminalPresets = [
            TerminalPreset(id: "preset-a", title: "A", path: "/tmp"),
            TerminalPreset(id: "preset-b", title: "B", path: "/var"),
        ]
        model.hiddenAgents = []
        model.agentOrder = []
        let list = AgentTemplate.visibleOrdered(model: model)
        XCTAssertEqual(list.first?.id, "terminal")
        XCTAssertEqual(list[1].id, "preset-a")
        XCTAssertEqual(list[2].id, "preset-b")
        XCTAssertEqual(list[3].id, AgentTemplate.claudeCodeID,
                       "agents must follow the preset block; Claude is the first builtin agent after Terminal")
    }

    func testAskAgentPrefersLastPickThenDefaultThenFirst() {
        let model = KookySettingsModel()
        model.terminalPresets = []
        model.hiddenAgents = []
        model.agentOrder = []
        // Roster is recomputed per assertion — hiddenAgents changes mid-test.
        func resolved() -> String? {
            let agents = AgentTemplate.askAgents(model: model)
            return AgentTemplate.askAgent(in: agents, model: model)?.id
        }

        // The user's default IS an agent (and not the first one) → it wins.
        model.defaultAgentId = AgentTemplate.codex.id
        model.lastAskAgentId = nil
        XCTAssertEqual(resolved(), AgentTemplate.codex.id)

        // A remembered last pick beats the default.
        model.lastAskAgentId = AgentTemplate.claudeCodeID
        XCTAssertEqual(resolved(), AgentTemplate.claudeCodeID)

        // A last pick the user has since hidden must be ignored, not honored.
        model.hiddenAgents = [AgentTemplate.claudeCodeID]
        XCTAssertEqual(resolved(), AgentTemplate.codex.id)

        // Default is a shell and nothing remembered → first enabled agent.
        // (askDefault resolves the id against the non-shell roster, so a
        // shell default simply isn't found.)
        model.hiddenAgents = []
        model.lastAskAgentId = nil
        model.defaultAgentId = "terminal"
        XCTAssertEqual(resolved(), AgentTemplate.claudeCodeID)
    }

    func testAskAgentsAreEnabledAgentsInUserOrder() {
        let model = KookySettingsModel()
        model.terminalPresets = [TerminalPreset(id: "preset-a", title: "A", path: "/tmp")]
        model.hiddenAgents = [AgentTemplate.claudeCodeID]
        model.agentOrder = [AgentTemplate.gemini.id, AgentTemplate.codex.id]

        let ids = AgentTemplate.askAgents(model: model).map(\.id)
        XCTAssertEqual(Array(ids.prefix(2)), [AgentTemplate.gemini.id, AgentTemplate.codex.id],
                       "the picker must follow the user's Settings → Agents order")
        XCTAssertFalse(ids.contains(AgentTemplate.claudeCodeID), "hidden agents stay out of the picker")
        XCTAssertFalse(ids.contains("terminal"), "shells have nothing to Ask")
        XCTAssertFalse(ids.contains("preset-a"), "terminal presets are shells too")
    }

    func testMakeSessionConfigInjectsResumeFlagForClaude() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "abc-123")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude --resume abc-123")
    }

    func testMakeSessionConfigCombinesResumeAndExtras() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: "--model opus", resumeId: "abc-123")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude --resume abc-123 --model opus")
    }

    func testClaudeNoSessionPersistenceDisablesConversationPersistence() {
        XCTAssertFalse(
            AgentTemplate.claudeCode.persistsConversation(
                extraOptions: "--print --no-session-persistence"
            )
        )
        XCTAssertEqual(
            AgentTemplate.claudeCode.makeSessionConfig(
                extraOptions: "--print --no-session-persistence",
                resumeId: "ephemeral-id"
            ).environment["KOOKY_AGENT"],
            "claude --print --no-session-persistence"
        )
    }

    func testClaudeNoSessionPersistenceDetectionRespectsShellWords() {
        XCTAssertFalse(
            AgentTemplate.claudeCode.persistsConversation(
                extraOptions: #""--no-session-persistence" --model opus"#
            )
        )
        XCTAssertTrue(
            AgentTemplate.claudeCode.persistsConversation(
                extraOptions: #"--system-prompt "mention --no-session-persistence here""#
            )
        )
        XCTAssertTrue(
            AgentTemplate.claudeCode.persistsConversation(
                extraOptions: "# --no-session-persistence"
            )
        )
    }

    func testClaudeBasedCustomCommandCanDisableConversationPersistence() {
        let template = AgentTemplate.fromCustom(
            CustomAgentData(
                id: "claude-print",
                command: "claude --print --no-session-persistence",
                baseAgentId: AgentTemplate.claudeCodeID
            )
        )
        XCTAssertFalse(template.persistsConversation(extraOptions: nil))
    }

    func testNoSessionPersistenceOptionDoesNotAffectOtherAgents() {
        XCTAssertTrue(
            AgentTemplate.pi.persistsConversation(
                extraOptions: "--no-session-persistence"
            )
        )
    }

    func testMakeSessionConfigSkipsResumeWhenIdEmpty() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude")
    }

    func testMakeSessionConfigInjectsAgentSpecificResumeArguments() {
        let expected: [(AgentTemplate, String)] = [
            (.codex, "codex resume abc-123"),
            (.gemini, "gemini --resume abc-123"),
            (.opencode, "opencode --session abc-123"),
            (.amp, "amp threads continue abc-123"),
            (.cursor, "cursor-agent --resume=abc-123"),
            (.copilot, "copilot --resume=abc-123"),
            (.grok, "grok --resume abc-123"),
            (.antigravity, "agy --conversation=abc-123"),
            (.kimi, "kimi --session abc-123"),
            (.ohMyPi, "omp --resume abc-123"),
            (.reasonix, "reasonix --resume abc-123"),
            (.kiro, "kiro-cli --resume-id abc-123"),
            (.droid, "droid --resume abc-123"),
        ]
        for (template, command) in expected {
            XCTAssertEqual(
                template.makeSessionConfig(resumeId: "abc-123").environment["KOOKY_AGENT"],
                command,
                "wrong resume command for \(template.id)"
            )
        }
    }

    func testEveryBuiltinAgentSupportsResume() {
        XCTAssertFalse(AgentTemplate.terminal.supportsResume)
        for template in AgentTemplate.builtin where !template.isShell {
            XCTAssertTrue(template.supportsResume, "\(template.id) must declare a resume strategy")
        }
    }

    func testResumeIdIsShellQuotedWhenUnexpectedCharactersAppear() {
        let config = AgentTemplate.codex.makeSessionConfig(resumeId: "id; echo injected")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "codex resume 'id; echo injected'")
    }

    func testMakeSessionConfigInjectsResumeForClaudeBasedCustom() {
        let custom = CustomAgentData(id: "claude-opus", baseAgentId: "claude-code")
        let template = AgentTemplate.fromCustom(custom)
        let config = template.makeSessionConfig(resumeId: "xyz")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude --resume xyz")
    }

    func testMakeSessionConfigInjectsResumeForPi() {
        // Pi takes a launch-time `--session <id>`; the extension captures the
        // session id and reports it via `kooky-hook pi conversation <id>`.
        let config = AgentTemplate.pi.makeSessionConfig(resumeId: "abc-123")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "pi --session abc-123")
    }

    func testMakeSessionConfigNormalizesLegacyPiFilenameStem() {
        let legacy = "2026-07-14T19-24-02-459Z_019f6216-161b-737e-ba6b-0f974a7b7b8c"
        let config = AgentTemplate.pi.makeSessionConfig(resumeId: legacy)
        XCTAssertEqual(
            config.environment["KOOKY_AGENT"],
            "pi --session 019f6216-161b-737e-ba6b-0f974a7b7b8c"
        )
    }

    func testMakeSessionConfigNormalizesLegacyPiFilenameStemForCustomAgent() {
        let custom = AgentTemplate.fromCustom(
            CustomAgentData(id: "pi-custom", command: "pi", baseAgentId: "pi")
        )
        let legacy = "2026-07-14T19-24-02-459Z_019f6216-161b-737e-ba6b-0f974a7b7b8c"
        let config = custom.makeSessionConfig(resumeId: legacy)
        XCTAssertEqual(
            config.environment["KOOKY_AGENT"],
            "pi --session 019f6216-161b-737e-ba6b-0f974a7b7b8c"
        )
    }

    func testMakeSessionConfigPreservesPiCustomIdEndingInUUID() {
        let id = "team_019f6216-161b-737e-ba6b-0f974a7b7b8c"
        let config = AgentTemplate.pi.makeSessionConfig(resumeId: id)
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "pi --session \(id)")
    }

    func testMakeSessionConfigPreservesPiConversationIdCase() {
        let id = "019F6216-161B-737E-BA6B-0F974A7B7B8C"
        let config = AgentTemplate.pi.makeSessionConfig(resumeId: id)
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "pi --session \(id)")
    }

    func testMakeSessionConfigPreservesLegacyPiUUIDCaseWhenNormalizing() {
        let legacy = "2026-07-14T19-24-02-459Z_019F6216-161B-737E-BA6B-0F974A7B7B8C"
        let config = AgentTemplate.pi.makeSessionConfig(resumeId: legacy)
        XCTAssertEqual(
            config.environment["KOOKY_AGENT"],
            "pi --session 019F6216-161B-737E-BA6B-0F974A7B7B8C"
        )
    }

    func testMakeSessionConfigDoesNotNormalizeClaudeConversationId() {
        let id = "2026-07-14T19-24-02-459Z_019f6216-161b-737e-ba6b-0f974a7b7b8c"
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: id)
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude --resume \(id)")
    }

    func testReportsToolCallsOnlyForToolFeedingAgents() {
        // Claude (hooks) + Pi and its fork Oh My Pi (extension
        // tool_execution_* events) feed kooky per-tool-call activity; every
        // other builtin (incl. shells) does not.
        XCTAssertTrue(AgentTemplate.claudeCode.reportsToolCalls)
        XCTAssertTrue(AgentTemplate.pi.reportsToolCalls)
        XCTAssertTrue(AgentTemplate.ohMyPi.reportsToolCalls)
        // Reasonix feeds them through its Claude-shaped PreToolUse/PostToolUse
        // hooks rather than an extension.
        XCTAssertTrue(AgentTemplate.reasonix.reportsToolCalls)
        XCTAssertFalse(AgentTemplate.terminal.reportsToolCalls)
        XCTAssertFalse(AgentTemplate.codex.reportsToolCalls)
        XCTAssertFalse(AgentTemplate.gemini.reportsToolCalls)
        XCTAssertFalse(AgentTemplate.kimi.reportsToolCalls)
        XCTAssertFalse(AgentTemplate.copilot.reportsToolCalls)
        XCTAssertFalse(AgentTemplate.kiro.reportsToolCalls)
        XCTAssertFalse(AgentTemplate.droid.reportsToolCalls)
    }

    func testFromCustomInheritsReportsToolCallsFromBase() {
        // A custom built on Claude / Pi inherits the tool-call pill; one built
        // on a non-reporting base (or none) does not — mirrors resumeStrategy.
        XCTAssertTrue(AgentTemplate.fromCustom(CustomAgentData(id: "c1", baseAgentId: "claude-code")).reportsToolCalls)
        XCTAssertTrue(AgentTemplate.fromCustom(CustomAgentData(id: "c2", baseAgentId: "pi")).reportsToolCalls)
        XCTAssertFalse(AgentTemplate.fromCustom(CustomAgentData(id: "c3", baseAgentId: "codex")).reportsToolCalls)
        XCTAssertFalse(AgentTemplate.fromCustom(CustomAgentData(id: "c4", baseAgentId: "")).reportsToolCalls)
    }

    // MARK: - initialPrompt (Ask <agent> right-click path)

    func testMakeSessionConfigPositionalPromptForClaude() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForCopilot() {
        let config = AgentTemplate.copilot.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "copilot -p 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForAmp() {
        let config = AgentTemplate.amp.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "amp -x 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForAntigravity() {
        let config = AgentTemplate.antigravity.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "agy -i 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForKimi() {
        let config = AgentTemplate.kimi.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "kimi -p 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForPi() {
        let config = AgentTemplate.pi.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "pi -p 'fix this error'")
    }

    func testMakeSessionConfigFlagPromptForReasonix() {
        // Reasonix's parser rejects positional arguments for interactive
        // sessions outright, so Ask has to go through `-p` (a single-shot,
        // like Kimi and Pi) rather than seeding a live REPL the way Droid
        // and Kiro do.
        let config = AgentTemplate.reasonix.makeSessionConfig(initialPrompt: "fix this error")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "reasonix -p 'fix this error'")
    }

    // MARK: - Monochrome icon theming

    func testMonochromeIconSetReferencesRealBuiltinAssets() {
        // A typo in `monochromeAssets` would silently skip theme-adaptive
        // tinting for that agent, so pin every entry to a real builtin iconAsset.
        let builtinAssets = Set(AgentTemplate.builtin.compactMap(\.iconAsset))
        for name in AgentIcon.monochromeAssets {
            XCTAssertTrue(builtinAssets.contains(name),
                          "monochrome asset \(name) matches no builtin iconAsset")
        }
    }

    func testBundledAgentIconsHaveTransparentCorners() throws {
        // Every agent mark is a shape on transparency — the chrome behind it
        // shows through, and a rounded tile without alpha renders as a light
        // square glued onto a dark sidebar. Nothing about a PNG forces this:
        // rendering an SVG through a thumbnailer (qlmanage) silently flattens
        // transparency onto white, which is exactly how the first cut of the
        // reasonix icon shipped a white box. Cheap to assert, invisible to
        // miss by eye on a light theme.
        // Read the checked-in source assets, not the runtime bundle:
        // `bundleResourceURL` resolves against `Bundle.main`, which under
        // xctest is the test runner, and the files in the repo are what a
        // future icon lands as anyway.
        let iconsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KookyKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/KookyKit/Resources/Icons")

        let assets = Set(AgentTemplate.builtin.compactMap(\.iconAsset))
        XCTAssertFalse(assets.isEmpty, "no builtin declares an icon — the loop below would vacuously pass")

        for asset in assets {
            let url = iconsDir.appendingPathComponent("\(asset).png")
            let data = try Data(contentsOf: url)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data), "\(asset).png is not decodable")
            let maxX = rep.pixelsWide - 1
            let maxY = rep.pixelsHigh - 1

            for (x, y) in [(0, 0), (maxX, 0), (0, maxY), (maxX, maxY)] {
                let alpha = try XCTUnwrap(rep.colorAt(x: x, y: y)).alphaComponent
                // Tolerate antialiasing residue (droid's corners sit at 2/255)
                // while still catching a fully-flattened background.
                XCTAssertLessThanOrEqual(
                    alpha, 8.0 / 255.0,
                    "\(asset).png corner (\(x),\(y)) is opaque — the icon has a baked-in background"
                )
            }
        }
    }

    func testReadmeAgentTableMatchesBuiltins() throws {
        // The READMEs list every shipped agent and which signals it supports.
        // That list drifted silently for two releases (it still said 13 agents
        // after 15 shipped) because nothing tied it to the code — and it is
        // the first thing a new user reads. Pin all three translations: the
        // command column against `builtin`, and the tool-pill column against
        // `reportsToolCalls`.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let agents = AgentTemplate.builtin.filter { !$0.isShell }
        let expectedCommands = Set(agents.compactMap(\.initialCommand))
        let expectedPill = Set(agents.filter(\.reportsToolCalls).compactMap(\.initialCommand))
        let historyIds = Set(AgentSessionScanner.supportedAgentIds)
        let expectedHistory = Set(agents.filter { historyIds.contains($0.id) }.compactMap(\.initialCommand))
        XCTAssertFalse(expectedCommands.isEmpty)
        XCTAssertFalse(expectedHistory.isEmpty)

        // `| Name | `cmd` | <dot> | <pill> | <history> |`.
        let row = try NSRegularExpression(
            pattern: #"^\|[^|]+\|\s*`([^`]+)`\s*\|\s*(.)\s*\|\s*(.)\s*\|\s*(.)\s*\|$"#,
            options: [.anchorsMatchLines]
        )

        for name in ["README.md", "README_CN.md", "README_JA.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)

            var commands: Set<String> = []
            var pill: Set<String> = []
            var history: Set<String> = []
            for match in row.matches(in: text, range: range) {
                guard let cmdRange = Range(match.range(at: 1), in: text),
                      let pillRange = Range(match.range(at: 3), in: text),
                      let historyRange = Range(match.range(at: 4), in: text) else { continue }
                let command = String(text[cmdRange])
                commands.insert(command)
                if text[pillRange] == "✓" { pill.insert(command) }
                if text[historyRange] == "✓" { history.insert(command) }
            }

            XCTAssertEqual(commands, expectedCommands, "\(name): agent table is out of sync with AgentTemplate.builtin")
            XCTAssertEqual(pill, expectedPill, "\(name): tool-pill column disagrees with reportsToolCalls")
            XCTAssertEqual(history, expectedHistory, "\(name): session-history column disagrees with AgentSessionScanner.supportedAgentIds")
        }
    }

    func testMonochromeBrandsTintedAndColorBrandsRenderedAsIs() {
        // The white-mark brands get template-tinted so they survive a light
        // theme; the color brands keep their own pixels on every theme.
        for mono in ["opencode", "cursor", "githubcopilot", "grok", "kimi", "pi", "droid"] {
            XCTAssertTrue(AgentIcon.isMonochrome(mono), "\(mono) should be template-tinted")
        }
        for color in ["claudecode", "codex", "gemini", "amp", "antigravity", "kiro", "omp", "reasonix"] {
            XCTAssertFalse(AgentIcon.isMonochrome(color), "\(color) is a color brand, render as-is")
        }
    }

    func testMakeSessionConfigPositionalPromptForFlaglessAgents() {
        let pairs: [(AgentTemplate, String)] = [
            (.codex, "codex"),
            (.cursor, "cursor-agent"),
            (.gemini, "gemini"),
            (.opencode, "opencode"),
            (.grok, "grok"),
            (.kiro, "kiro-cli"),
            (.droid, "droid"),
            // omp's `-p` is the non-interactive single-shot, so Ask stays
            // positional and rides omp's POSIX `--` support.
            (.ohMyPi, "omp"),
        ]
        for (template, bin) in pairs {
            let config = template.makeSessionConfig(initialPrompt: "hello")
            XCTAssertEqual(config.environment["KOOKY_AGENT"], "\(bin) -- 'hello'", "agent \(template.id)")
        }
    }

    func testMakeSessionConfigQuotesSingleQuotesInPrompt() {
        // POSIX wrap: `'` inside single quotes becomes `'\''`
        let config = AgentTemplate.claudeCode.makeSessionConfig(initialPrompt: "don't fix it")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'don'\\''t fix it'")
    }

    func testMakeSessionConfigCombinesPromptAndExtras() {
        let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: "--model opus", initialPrompt: "review this")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'review this' --model opus")
    }

    func testInitialPromptSuppressesResume() {
        // Ask <agent> is a fresh question — don't graft onto a stale
        // conversation. Both supplied → prompt wins, resume dropped.
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "old-convo", initialPrompt: "new question")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "claude -- 'new question'")
    }

    func testEmptyInitialPromptIgnored() {
        let blankConfig = AgentTemplate.claudeCode.makeSessionConfig(initialPrompt: "   ")
        XCTAssertEqual(blankConfig.environment["KOOKY_AGENT"], "claude")
        let resumeConfig = AgentTemplate.claudeCode.makeSessionConfig(resumeId: "abc", initialPrompt: "")
        XCTAssertEqual(resumeConfig.environment["KOOKY_AGENT"], "claude --resume abc")
    }

    func testFromCustomInheritsPromptLaunchFlagFromCopilotBase() {
        // Codex P2 (v0.10.9): a Copilot-based custom must inherit Copilot's
        // `-p` flag — otherwise right-click Ask sends the prompt as a
        // positional argv that Copilot ignores.
        let custom = CustomAgentData(id: "copilot-beta", baseAgentId: "copilot")
        let template = AgentTemplate.fromCustom(custom)
        let config = template.makeSessionConfig(initialPrompt: "hello")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "copilot -p 'hello'")
    }

    func testFromCustomInheritsPromptLaunchFlagFromAmpBase() {
        let custom = CustomAgentData(id: "amp-beta", baseAgentId: "amp")
        let template = AgentTemplate.fromCustom(custom)
        let config = template.makeSessionConfig(initialPrompt: "hello")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "amp -x 'hello'")
    }

    func testPositionalPromptWithDashPrefixRoutedThroughSeparator() {
        // Real-world bug: user right-clicks `ls -la` output, the first
        // line begins `-rw-r--r--@`. Without the `--` separator the
        // agent's argparse would reject it as an unknown flag. The
        // POSIX separator + POSIX-quoted prompt together neutralise it.
        let config = AgentTemplate.codex.makeSessionConfig(initialPrompt: "-rw-r--r--@  1 corey staff  44")
        XCTAssertEqual(config.environment["KOOKY_AGENT"], "codex -- '-rw-r--r--@  1 corey staff  44'")
    }

    // MARK: - parseEnv (custom-agent environment block)

    func testParseEnvBasicPair() {
        XCTAssertEqual(
            AgentTemplate.parseEnv("ANTHROPIC_BASE_URL=https://api.example.com"),
            ["ANTHROPIC_BASE_URL": "https://api.example.com"]
        )
    }

    func testParseEnvMultipleLines() {
        XCTAssertEqual(
            AgentTemplate.parseEnv("ANTHROPIC_BASE_URL=https://api.example.com\nANTHROPIC_AUTH_TOKEN=sk-abc123"),
            ["ANTHROPIC_BASE_URL": "https://api.example.com", "ANTHROPIC_AUTH_TOKEN": "sk-abc123"]
        )
    }

    func testParseEnvSkipsBlankAndCommentLines() {
        XCTAssertEqual(
            AgentTemplate.parseEnv("# a comment\nFOO=bar\n\n   # indented comment\nBAZ=qux"),
            ["FOO": "bar", "BAZ": "qux"]
        )
    }

    func testParseEnvStripsExportPrefix() {
        XCTAssertEqual(AgentTemplate.parseEnv("export FOO=bar"), ["FOO": "bar"])
    }

    func testParseEnvStripsExportWithTab() {
        XCTAssertEqual(AgentTemplate.parseEnv("export\tFOO=bar"), ["FOO": "bar"])
    }

    func testParseEnvHandlesCRLFLineEndings() {
        // A block pasted from a Windows editor / web copy uses \r\n — the
        // parser must split it into separate pairs, not collapse the whole
        // block into the first key's value.
        XCTAssertEqual(
            AgentTemplate.parseEnv("FOO=bar\r\nBAZ=qux\rZIP=zap"),
            ["FOO": "bar", "BAZ": "qux", "ZIP": "zap"]
        )
    }

    func testParseEnvSplitsOnFirstEquals() {
        // A value containing `=` (URL query string) must survive intact.
        XCTAssertEqual(
            AgentTemplate.parseEnv("URL=https://x.com/path?a=1&b=2"),
            ["URL": "https://x.com/path?a=1&b=2"]
        )
    }

    func testParseEnvUnwrapsSurroundingQuotes() {
        XCTAssertEqual(AgentTemplate.parseEnv(#"FOO="hello world""#), ["FOO": "hello world"])
        XCTAssertEqual(AgentTemplate.parseEnv("FOO='single'"), ["FOO": "single"])
    }

    func testParseEnvTrimsWhitespace() {
        XCTAssertEqual(AgentTemplate.parseEnv("  FOO = bar  "), ["FOO": "bar"])
    }

    func testParseEnvDropsInvalidKeys() {
        // Leading digit, space in key, empty key, and a line with no `=`
        // are all dropped — only `GOOD` survives.
        XCTAssertEqual(
            AgentTemplate.parseEnv("1FOO=bad\nMY VAR=bad\n=bad\ngarbage line\nGOOD=ok"),
            ["GOOD": "ok"]
        )
    }

    func testParseEnvDropsKookyPrefixedKeys() {
        // A custom agent must not shadow kooky's own env — KOOKY_SURFACE_ID
        // in particular routes hook pings to the right tab.
        XCTAssertEqual(AgentTemplate.parseEnv("KOOKY_SURFACE_ID=evil\nFOO=ok"), ["FOO": "ok"])
    }

    func testParseEnvLaterLineWinsOnDuplicateKey() {
        XCTAssertEqual(AgentTemplate.parseEnv("FOO=first\nFOO=second"), ["FOO": "second"])
    }

    func testParseEnvEmptyBlockYieldsEmptyDict() {
        XCTAssertTrue(AgentTemplate.parseEnv("").isEmpty)
        XCTAssertTrue(AgentTemplate.parseEnv("\n\n   \n").isEmpty)
    }

    // MARK: - extraEnv snapshot

    func testFromCustomParsesEnvIntoExtraEnv() {
        let custom = CustomAgentData(
            id: "claude-mirror",
            baseAgentId: "claude-code",
            env: "ANTHROPIC_BASE_URL=https://mirror.example.com\nANTHROPIC_AUTH_TOKEN=sk-xyz"
        )
        let template = AgentTemplate.fromCustom(custom)
        XCTAssertEqual(template.extraEnv, [
            "ANTHROPIC_BASE_URL": "https://mirror.example.com",
            "ANTHROPIC_AUTH_TOKEN": "sk-xyz",
        ])
    }

    func testBuiltinTemplatesHaveEmptyExtraEnv() {
        for template in AgentTemplate.builtin {
            XCTAssertTrue(template.extraEnv.isEmpty, "builtin \(template.id) must not carry extraEnv")
        }
    }
}
