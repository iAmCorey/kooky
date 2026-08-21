import XCTest
@testable import KookyHookKit

/// Pins the `kooky-cli` front half: the per-verb argv grammar, the
/// command → wire-request mapping, path normalization, and the wire
/// round-trip. External tools script against this surface, so a grammar
/// change that isn't deliberate must redden here.
final class CLICommandTests: XCTestCase {
    private func parsed(_ args: [String]) -> KookyCLICommand? {
        try? KookyHookKit.parseCLICommand(args).get()
    }

    private func parseError(_ args: [String]) -> String? {
        if case .failure(let error) = KookyHookKit.parseCLICommand(args) { return error.message }
        return nil
    }

    // MARK: parse — happy paths

    func testParseOpenPlainTerminal() {
        XCTAssertEqual(parsed(["open", "--cwd", "/tmp"]), .open(cwd: "/tmp", command: nil, agent: nil))
    }

    func testParseOpenWithCommand() {
        XCTAssertEqual(
            parsed(["open", "--cwd", "/tmp", "-e", "npx @deepseek-ai/dsh web"]),
            .open(cwd: "/tmp", command: "npx @deepseek-ai/dsh web", agent: nil)
        )
    }

    func testParseOpenWithAgent() {
        XCTAssertEqual(
            parsed(["open", "--cwd", "/tmp", "--agent", "claude-code"]),
            .open(cwd: "/tmp", command: nil, agent: "claude-code")
        )
    }

    func testParseOpenCommandKeepsDashLeadingValue() {
        // A value flag takes the NEXT token verbatim — a command that
        // starts with a dash must not read as an unknown flag.
        XCTAssertEqual(
            parsed(["open", "--cwd", "/tmp", "-e", "--version"]),
            .open(cwd: "/tmp", command: "--version", agent: nil)
        )
    }

    /// A Terminal preset carries its own directory, so `--cwd` is optional
    /// once a template is named. Whether that template actually has one is
    /// the app's call — it is the side that resolves template ids.
    func testParseOpenAcceptsNoCwdWhenATemplateIsNamed() {
        XCTAssertEqual(
            parsed(["open", "--agent", "preset-1"]),
            .open(cwd: nil, command: nil, agent: "preset-1")
        )
    }

    func testParseOpenStillNeedsCwdWithNothingElseToGoOn() {
        XCTAssertNil(parsed(["open"]), "bare `open` must be refused")
        XCTAssertTrue(parseError(["open"])?.contains("--cwd") == true)
        // `-e` says WHAT to run, never WHERE — it can't stand in for --cwd.
        XCTAssertNil(parsed(["open", "-e", "ls"]), "`open -e` without --cwd must be refused")
        XCTAssertTrue(parseError(["open", "-e", "ls"])?.contains("--cwd") == true)
    }

    func testParseResume() {
        XCTAssertEqual(
            parsed(["resume", "--agent", "claude-code", "--id", "abc-123"]),
            .resume(agent: "claude-code", id: "abc-123", cwd: nil)
        )
        XCTAssertEqual(
            parsed(["resume", "--agent", "codex", "--id", "abc", "--cwd", "/x"]),
            .resume(agent: "codex", id: "abc", cwd: "/x")
        )
    }

    func testParseListFocusCloseStatus() {
        let uuid = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
        XCTAssertEqual(parsed(["list"]), .list(json: false))
        XCTAssertEqual(parsed(["list", "--json"]), .list(json: true))
        XCTAssertEqual(parsed(["focus", "--tab", uuid]), .focus(tab: uuid))
        XCTAssertEqual(parsed(["close", "--tab", uuid]), .close(tab: uuid))
        XCTAssertEqual(parsed(["status"]), .status(json: false))
        XCTAssertEqual(parsed(["status", "--json"]), .status(json: true))
    }

    func testParseTabUUIDIsCaseInsensitiveAndCanonicalized() {
        let lower = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        XCTAssertEqual(parsed(["focus", "--tab", lower]), .focus(tab: lower.uppercased()))
    }

    func testParseHelpSpellings() {
        XCTAssertEqual(parsed([]), .help)
        XCTAssertEqual(parsed(["help"]), .help)
        XCTAssertEqual(parsed(["--help"]), .help)
        XCTAssertEqual(parsed(["open", "-h"]), .help)
    }

    func testHelpInsideFlagValuesStaysAValue() {
        // The verbatim-value promise beats help detection: a caller-supplied
        // command that HAPPENS to be "--help" must still open a tab, and a
        // "help" consumed as a --tab value fails UUID validation instead of
        // silently turning into the help screen.
        XCTAssertEqual(
            parsed(["open", "--cwd", "/tmp", "-e", "--help"]),
            .open(cwd: "/tmp", command: "--help", agent: nil)
        )
        XCTAssertNotNil(parseError(["focus", "--tab", "help"]))
    }

    // MARK: parse — failures

    func testParseFailsOnUnknownVerbAndFlag() {
        XCTAssertNotNil(parseError(["teleport"]))
        XCTAssertNotNil(parseError(["open", "--cwd", "/tmp", "--wat"]))
    }

    func testParseFailsOnMissingRequiredFlags() {
        XCTAssertNotNil(parseError(["open"]))
        XCTAssertNotNil(parseError(["resume", "--agent", "claude-code"]))
        XCTAssertNotNil(parseError(["resume", "--id", "abc"]))
        XCTAssertNotNil(parseError(["focus"]))
        XCTAssertNotNil(parseError(["close"]))
    }

    func testParseFailsOnDanglingValueFlag() {
        XCTAssertNotNil(parseError(["open", "--cwd"]))
        XCTAssertNotNil(parseError(["open", "--cwd", "/tmp", "-e"]))
    }

    func testParseFailsOnDuplicateFlag() {
        XCTAssertNotNil(parseError(["open", "--cwd", "/a", "--cwd", "/b"]))
    }

    func testParseFailsWhenCommandAndAgentBothGiven() {
        let message = parseError(["open", "--cwd", "/tmp", "-e", "ls", "--agent", "codex"])
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("mutually exclusive") == true)
    }

    func testParseFailsOnNonUUIDTab() {
        XCTAssertNotNil(parseError(["focus", "--tab", "not-a-uuid"]))
        XCTAssertNotNil(parseError(["close", "--tab", "12345"]))
    }

    // MARK: command → request mapping

    func testRequestMappingCarriesEveryField() {
        let open = KookyHookKit.cliRequest(for: .open(cwd: "/x", command: "make", agent: nil))
        XCTAssertEqual(open?.verb, "open")
        XCTAssertEqual(open?.cwd, "/x")
        XCTAssertEqual(open?.command, "make")
        XCTAssertNil(open?.agent)
        XCTAssertEqual(open?.kind, KookyCLIProtocol.kind)
        XCTAssertEqual(open?.protocolVersion, KookyCLIProtocol.version)

        let resume = KookyHookKit.cliRequest(for: .resume(agent: "codex", id: "abc", cwd: "/y"))
        XCTAssertEqual(resume?.verb, "resume")
        XCTAssertEqual(resume?.agent, "codex")
        XCTAssertEqual(resume?.conversationId, "abc")
        XCTAssertEqual(resume?.cwd, "/y")

        let focus = KookyHookKit.cliRequest(for: .focus(tab: "ID"))
        XCTAssertEqual(focus?.verb, "focus")
        XCTAssertEqual(focus?.tab, "ID")

        XCTAssertEqual(KookyHookKit.cliRequest(for: .list(json: true))?.verb, "list")
        XCTAssertEqual(KookyHookKit.cliRequest(for: .close(tab: "ID"))?.verb, "close")
        XCTAssertEqual(KookyHookKit.cliRequest(for: .status(json: false))?.verb, "status")
        XCTAssertNil(KookyHookKit.cliRequest(for: .help))
    }

    // MARK: wire round-trip

    func testRequestAndResponseRoundTripAsSingleLines() throws {
        let request = KookyCLIRequest(verb: .open, cwd: "/tmp", command: "ls")
        let requestLine = try XCTUnwrap(request.encodedLine())
        XCTAssertEqual(requestLine.last, 0x0A)
        XCTAssertEqual(KookyCLIRequest.decode(from: requestLine.dropLast()), request)

        let response = KookyCLIResponse(
            ok: true,
            appVersion: "9.9.9",
            tabId: "T",
            windows: [KookyCLIWindowInfo(
                index: 1,
                isKey: true,
                workspaces: [KookyCLIWorkspaceInfo(
                    id: "W",
                    title: "kooky",
                    path: "/p",
                    isActive: true,
                    tabs: [KookyCLITabInfo(id: "S", title: "t", cwd: "/p", isActive: true, agent: "terminal", agentState: nil)]
                )]
            )]
        )
        let responseLine = try XCTUnwrap(response.encodedLine())
        XCTAssertEqual(responseLine.last, 0x0A)
        XCTAssertEqual(KookyCLIResponse.decode(from: responseLine.dropLast()), response)
    }

    // MARK: path normalization

    /// A blank value means "flag not passed", for every value flag. Scripts
    /// write `--cwd "$MAYBE_DIR"`, and an unset variable must not become the
    /// CLI's own working directory once the path is absolutized — by then it
    /// is a valid path and every downstream emptiness check is too late.
    func testBlankFlagValuesAreTreatedAsAbsent() {
        switch KookyHookKit.parseCLICommand(["open", "--cwd", ""]) {
        case .success(let command): XCTFail("expected a refusal, got \(command)")
        case .failure(let error): XCTAssertTrue(error.message.contains("--cwd"))
        }
        switch KookyHookKit.parseCLICommand(["open", "--cwd", "   "]) {
        case .success(let command): XCTFail("whitespace is blank too, got \(command)")
        case .failure: break
        }
        // resume's cwd is optional, so blank must fold to nil rather than
        // spawn the conversation in whatever directory the CLI ran from.
        switch KookyHookKit.parseCLICommand(["resume", "--agent", "claude-code", "--id", "abc", "--cwd", ""]) {
        case .success(.resume(_, _, let cwd)): XCTAssertNil(cwd)
        case .success(let other): XCTFail("unexpected \(other)")
        case .failure(let error): XCTFail("resume should still parse: \(error.message)")
        }
    }

    /// The fold must not trim a value that only LOOKS padded: a leading
    /// space in `-e` is deliberate (zsh's HIST_IGNORE_SPACE keeps such a
    /// command out of history).
    func testLeadingWhitespaceInACommandIsPreserved() {
        switch KookyHookKit.parseCLICommand(["open", "--cwd", "/tmp", "-e", " secret-cmd"]) {
        case .success(.open(_, let command, _)): XCTAssertEqual(command, " secret-cmd")
        case .success(let other): XCTFail("unexpected \(other)")
        case .failure(let error): XCTFail(error.message)
        }
    }

    func testNormalizeCLIPath() {
        XCTAssertEqual(KookyHookKit.normalizeCLIPath("/a/b", relativeTo: "/base"), "/a/b")
        XCTAssertEqual(KookyHookKit.normalizeCLIPath("sub/dir", relativeTo: "/base"), "/base/sub/dir")
        XCTAssertEqual(KookyHookKit.normalizeCLIPath(".", relativeTo: "/base"), "/base")
        XCTAssertEqual(KookyHookKit.normalizeCLIPath("../x", relativeTo: "/base/sub"), "/base/x")
        let home = NSHomeDirectory()
        XCTAssertEqual(KookyHookKit.normalizeCLIPath("~", relativeTo: "/base"), home)
        XCTAssertEqual(KookyHookKit.normalizeCLIPath("~/proj", relativeTo: "/base"), home + "/proj")
    }

    // MARK: rendering

    func testRenderListShowsTreeWithActiveMarkers() {
        let windows = [KookyCLIWindowInfo(
            index: 1,
            isKey: true,
            workspaces: [KookyCLIWorkspaceInfo(
                id: "W1",
                title: "kooky",
                path: "/Users/x/kooky",
                isActive: true,
                tabs: [
                    KookyCLITabInfo(id: "AAA", title: "fix", cwd: "/Users/x/kooky", isActive: true, agent: "claude-code", agentState: "running"),
                    KookyCLITabInfo(id: "BBB", title: "zsh", cwd: "/Users/x", isActive: false, agent: "terminal", agentState: nil),
                ]
            )]
        )]
        let text = KookyHookKit.renderCLIList(windows)
        XCTAssertTrue(text.contains("window 1 (key)"))
        XCTAssertTrue(text.contains("workspace \"kooky\" (active)"))
        XCTAssertTrue(text.contains("* AAA  claude-code (running)"))
        XCTAssertTrue(text.contains("  BBB  terminal  \"zsh\""))
        XCTAssertEqual(KookyHookKit.renderCLIList([]), "no windows")
    }

    /// Tab titles arrive from OSC 0/2 — i.e. whatever program is running,
    /// including one on the far side of an ssh — and a directory name may
    /// legally contain a newline (`mkdir $'a\nb'`). Printed raw, either can
    /// forge `list` rows (pointing a script at a tab id that isn't there)
    /// or inject escape sequences into the terminal reading the output.
    func testRenderListFlattensControlCharactersFromUntrustedValues() {
        let forgedRow = "innocent\n  * DEADBEEF  terminal  \"gotcha\" — /tmp"
        let windows = [KookyCLIWindowInfo(
            index: 1,
            isKey: false,
            workspaces: [KookyCLIWorkspaceInfo(
                id: "W1",
                title: "ws\u{1B}]52;c;aGF4\u{07}",   // an OSC 52 clipboard write
                path: "/tmp/two\nlines",
                isActive: false,
                tabs: [KookyCLITabInfo(
                    id: "AAA",
                    title: forgedRow,
                    cwd: "/tmp/also\nforged",
                    isActive: false,
                    agent: "terminal",
                    agentState: nil
                )]
            )]
        )]
        let text = KookyHookKit.renderCLIList(windows)

        // window + workspace + one tab, whatever the titles claim.
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(rows.count, 3, "untrusted values must not be able to add rows")
        for row in rows {
            XCTAssertFalse(
                row.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F },
                "no control characters may reach the caller's terminal: \(row.debugDescription)"
            )
        }
        // The text is still there, just flattened — this is sanitizing, not dropping.
        XCTAssertTrue(text.contains("DEADBEEF"))
        XCTAssertTrue(text.contains("innocent"))
    }

    /// Every dynamic value the CLI prints goes through `plain` — error
    /// lines and notes included, not just list rows. A refusal quotes the
    /// caller's own `--agent` value back at them, and that string came from
    /// whatever tool invoked kooky-cli.
    func testPlainStripsEverythingThatCouldForgeALine() {
        XCTAssertEqual(KookyHookKit.plain("a\nb"), "a b")
        // ESC and BEL become spaces; the printable `]` is not a control
        // character and stays — what matters is that no escape SEQUENCE
        // survives intact.
        XCTAssertEqual(KookyHookKit.plain("a\u{1B}]52;c;x\u{07}b"), "a ]52;c;x b")
        XCTAssertEqual(KookyHookKit.plain("tab\there"), "tab here")
        XCTAssertEqual(KookyHookKit.plain("del\u{7F}x"), "del x")
        XCTAssertEqual(KookyHookKit.plain("u\u{2028}v"), "u v")
        // Ordinary text, including non-ASCII, is untouched.
        XCTAssertEqual(KookyHookKit.plain("claude-code 中文"), "claude-code 中文")
    }

    func testRenderJSONOutputsAreParseable() throws {
        let windows = [KookyCLIWindowInfo(index: 1, isKey: false, workspaces: [])]
        let listJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(KookyHookKit.renderCLIListJSON(windows).utf8)) as? [String: Any]
        )
        XCTAssertEqual((listJSON["windows"] as? [[String: Any]])?.count, 1)

        let statusJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(
                KookyHookKit.renderCLIStatusJSON(running: true, appVersion: "1.2.3", serverProtocol: 1).utf8
            )) as? [String: Any]
        )
        XCTAssertEqual(statusJSON["running"] as? Bool, true)
        XCTAssertEqual(statusJSON["appVersion"] as? String, "1.2.3")
        XCTAssertEqual(statusJSON["cliProtocolVersion"] as? Int, KookyCLIProtocol.version)
    }
}
