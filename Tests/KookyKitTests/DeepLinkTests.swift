import XCTest
@testable import KookyKit

/// `kooky://` deep-link grammar + the already-open-conversation lookup and
/// store lookup the handler consults before spawning a duplicate resume. The
/// AppKit half (`application(_:open:)`, window fronting, the failure sheet)
/// stays manual — these pin the pure decisions underneath it.
@MainActor
final class DeepLinkTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deeplink-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeStore() -> WorkspaceStore { makeTestStore() }

    // MARK: - Parse

    func testParsesResumeLink() {
        XCTAssertEqual(
            KookyDeepLink.parse(URL(string: "kooky://resume?agent=claude-code&id=1234-abcd")!),
            .resumeSession(agentId: "claude-code", conversationId: "1234-abcd", cwd: nil)
        )
        XCTAssertEqual(
            KookyDeepLink.parse(URL(string: "kooky://resume?agent=codex&id=abc&cwd=/Users/x/proj%20dir")!),
            .resumeSession(agentId: "codex", conversationId: "abc", cwd: "/Users/x/proj dir")
        )
    }

    func testSchemeHostAndAgentAreCaseNormalized() {
        XCTAssertEqual(
            KookyDeepLink.parse(URL(string: "KOOKY://Resume?agent=Codex&id=aBc")!),
            .resumeSession(agentId: "codex", conversationId: "aBc", cwd: nil)
        )
    }

    /// `kooky:///resume` — the natural file:///-habit typo — parses with an
    /// empty host and the action in the path; it must be accepted, not
    /// silently dropped.
    func testTripleSlashSpellingIsAccepted() {
        XCTAssertEqual(
            KookyDeepLink.parse(URL(string: "kooky:///resume?agent=codex&id=abc")!),
            .resumeSession(agentId: "codex", conversationId: "abc", cwd: nil)
        )
    }

    /// The constructor is the canonical spelling; parse must invert it even
    /// for values that need percent-encoding.
    func testResumeURLRoundTripsThroughParse() {
        let url = KookyDeepLink.resumeURL(
            agentId: "claude-code",
            conversationId: "0199a834-3d22-7bd0-8c85-9d701b6c76f5",
            cwd: "/Users/corey/My Projects/kooky code"
        )
        XCTAssertNotNil(url)
        XCTAssertEqual(
            KookyDeepLink.parse(url!),
            .resumeSession(
                agentId: "claude-code",
                conversationId: "0199a834-3d22-7bd0-8c85-9d701b6c76f5",
                cwd: "/Users/corey/My Projects/kooky code"
            )
        )
    }

    /// Not ours at all → nil, dropped silently (public surface must not pop
    /// UI for arbitrary URLs).
    func testForeignLinksParseToNil() {
        for raw in ["https://resume?agent=claude-code&id=x", "kooky://open?agent=claude-code&id=x"] {
            XCTAssertNil(KookyDeepLink.parse(URL(string: raw)!), "should silently drop \(raw)")
        }
    }

    /// Recognized resume links with refused parameters → `.invalid`, so the
    /// handler can show the caller WHY (the requirement's visible-feedback
    /// clause), never a silent nil.
    func testBadParametersParseToInvalid() {
        let bad = [
            "kooky://resume",                          // no query at all
            "kooky://resume?agent=claude-code",        // missing id
            "kooky://resume?id=x",                     // missing agent
            "kooky://resume?agent=&id=x",              // empty agent
            "kooky://resume?agent=%20&id=x",           // whitespace-only agent
            "kooky://resume?agent=codex&id=x&cwd=rel/path",   // non-absolute cwd
            "kooky://resume?agent=codex&id=a%3Brm%20-rf%20~", // `a;rm -rf ~` id
            "kooky://resume?agent=\(String(repeating: "a", count: 65))&id=x",       // agent over cap
            "kooky://resume?agent=codex&id=x&cwd=/\(String(repeating: "p", count: 1024))", // cwd over cap
        ]
        for raw in bad {
            if case .invalid = KookyDeepLink.parse(URL(string: raw)!) {
                continue
            }
            XCTFail("should parse to .invalid: \(raw)")
        }
    }

    /// `validateResume` is the field-level door the CLI's `resume` verb
    /// enters through; it must be the SAME grammar `parse` applies to URLs —
    /// for every good and bad shape above, both doors agree. A drift here
    /// means the CLI accepts an id the deep link would refuse (or vice
    /// versa), and both end up inside KOOKY_AGENT.
    func testValidateResumeMatchesParseForEveryShape() throws {
        let queries: [(agent: String?, id: String?, cwd: String?)] = [
            ("claude-code", "abc-123", nil),
            ("Codex", "aBc", "/tmp/x y"),          // case-normalization + spacey cwd
            (nil, "x", nil),                       // missing agent
            ("claude-code", nil, nil),             // missing id
            ("  ", "x", nil),                      // blank agent
            ("codex", "a;rm -rf ~", nil),          // hostile id
            ("codex", "x", "rel/path"),            // relative cwd
            (String(repeating: "a", count: 65), "x", nil),
            ("codex", "x", "/" + String(repeating: "p", count: 1024)),
        ]
        for query in queries {
            var components = URLComponents()
            components.scheme = "kooky"
            components.host = "resume"
            var items: [URLQueryItem] = []
            if let agent = query.agent { items.append(URLQueryItem(name: "agent", value: agent)) }
            if let id = query.id { items.append(URLQueryItem(name: "id", value: id)) }
            if let cwd = query.cwd { items.append(URLQueryItem(name: "cwd", value: cwd)) }
            components.queryItems = items.isEmpty ? nil : items
            let url = try XCTUnwrap(components.url)
            XCTAssertEqual(
                KookyDeepLink.parse(url),
                KookyDeepLink.validateResume(agentId: query.agent, conversationId: query.id, cwd: query.cwd),
                "parse and validateResume disagree for \(query)"
            )
        }
    }

    /// The id whitelist IS the shell parameterization for the beyond-cap
    /// resume path, so it must admit every real store's id shape and refuse
    /// anything a shell or an argv parser could interpret.
    func testConversationIdValidation() {
        let realShapes = [
            "07675f68-0884-4430-ab83-69b36f6cb8ee",       // claude/copilot/cursor/kiro uuid
            "0199A834-3D22-7BD0-8C85-9D701B6C76F5",       // uppercase uuid
            "ses_1da2a47feffeNHvayIG8y6MYOX",             // opencode
            "session-2026-07-27T14-11-fdd64c67",          // gemini
            "rollout-2026.08.17",                         // dots
        ]
        for id in realShapes {
            XCTAssertTrue(KookyDeepLink.isValidConversationId(id), "should accept \(id)")
        }
        let hostile = [
            ";rm -rf ~",             // shell separator + spaces
            "a;rm",                  // separator mid-id
            "$(open -a Calc)",       // command substitution
            "`id`",                  // backticks
            "a b",                   // whitespace
            "a\nb",                  // newline
            "--resume",              // leading dash would parse as a flag
            "-rf",
            "_leading-underscore",   // non-alphanumeric head
            "",                      // empty
            String(repeating: "a", count: 201),  // over length cap
            "café-señal",            // non-ASCII
        ]
        for id in hostile {
            XCTAssertFalse(KookyDeepLink.isValidConversationId(id), "should refuse \(id)")
        }
    }

    // MARK: - Open-conversation lookup

    func testFindOpenConversationMatchesPersistedAndResumedIds() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let hooked = store.addTab(in: ws, template: .claudeCode)
        hooked.conversationId = "convo-hooked"
        // gemini stands in for "agent with no id-reporting hook" — it leaves
        // conversationId nil so only resumedConversationId can match. (NOT
        // codex: addTab(.codex) starts the real ~/.codex usage monitor.)
        let resumed = store.addTab(in: ws, template: .gemini)
        resumed.resumedConversationId = "convo-resumed"

        let hitA = store.findOpenConversation(agentId: "claude-code", conversationId: "convo-hooked")
        XCTAssertEqual(hitA?.session.id, hooked.id)
        XCTAssertEqual(hitA?.workspace.id, ws.id)
        let hitB = store.findOpenConversation(agentId: AgentTemplate.gemini.id, conversationId: "convo-resumed")
        XCTAssertEqual(hitB?.session.id, resumed.id)
        XCTAssertNil(store.findOpenConversation(agentId: "claude-code", conversationId: "missing"))
    }

    /// A hook-reporting agent overwrites `conversationId` when the user
    /// starts a new conversation in the same tab (claude `/clear`); the
    /// stale spawn-time `resumedConversationId` must then STOP matching, or
    /// the deep link reveals a tab attached to a different conversation and
    /// the resume silently never happens.
    func testFindOpenConversationPrefersLiveConversationIdOverStaleResumeId() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let tab = store.addTab(in: ws, template: .claudeCode)
        tab.resumedConversationId = "convo-old"
        tab.conversationId = "convo-new"   // hook reported a fresh conversation

        XCTAssertNil(
            store.findOpenConversation(agentId: "claude-code", conversationId: "convo-old"),
            "stale resume id must not match once the hook reported a different live conversation"
        )
        XCTAssertEqual(
            store.findOpenConversation(agentId: "claude-code", conversationId: "convo-new")?.session.id,
            tab.id
        )
    }

    /// Same conversation id under a different agent must not match (id
    /// namespaces are per-agent; a cross-agent collision would reveal the
    /// wrong tab), while a custom agent's tab matches under its BASE id —
    /// deep links speak the scanner's roster, which only knows builtins.
    /// Built via `fromCustom`, the path production custom agents take.
    func testFindOpenConversationMatchesAgentByBaseId() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let custom = AgentTemplate.fromCustom(CustomAgentData(
            id: "my-claude", title: "My Claude", command: "claude", baseAgentId: "claude-code"
        ))
        let tab = store.addTab(in: ws, template: custom)
        tab.conversationId = "convo-x"

        XCTAssertNil(store.findOpenConversation(agentId: "codex", conversationId: "convo-x"))
        XCTAssertEqual(
            store.findOpenConversation(agentId: "claude-code", conversationId: "convo-x")?.session.id,
            tab.id
        )
    }

    // MARK: - Store lookup

    /// `findRecord(root:)` is the deep-link fallback's store dispatch + id
    /// filter; pinned against a claude-shaped fixture via the explicit-roots
    /// seam so no test can touch the developer's real stores.
    func testFindRecordMatchesConversationInExplicitRoot() throws {
        let root = tempDir.appendingPathComponent("projects")
        let dir = root.appendingPathComponent("-tmp-proj")
        let conversationId = UUID().uuidString.lowercased()
        try SessionStoreFixtures.writeFile("\(conversationId).jsonl", in: dir, lines: [
            #"{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-01T00:00:00Z","message":{"role":"user","content":"hi"}}"#,
        ])

        let hit = AgentSessionScanner.findRecord(
            agentId: AgentTemplate.claudeCodeID, conversationId: conversationId, root: root
        )
        XCTAssertEqual(hit?.conversationId, conversationId)
        XCTAssertEqual(hit?.cwd.path, "/tmp/proj")
        XCTAssertNil(
            AgentSessionScanner.findRecord(
                agentId: AgentTemplate.claudeCodeID, conversationId: "absent", root: root
            )
        )
        XCTAssertNil(
            AgentSessionScanner.findRecord(agentId: "not-an-agent", conversationId: conversationId, root: root)
        )
    }

    /// The documented caller agents must all stay on the scanner roster (the
    /// deep-link whitelist). The resume half of the contract is pinned for
    /// the whole roster by `testEveryStoreAgentIdIsARealBuiltinWithResume`.
    func testDocumentedCallerAgentsAreOnScannerRoster() {
        for agentId in ["claude-code", "codex", "copilot", "cursor", "opencode", "kiro", "gemini"] {
            XCTAssertTrue(
                AgentSessionScanner.supportedAgentIds.contains(agentId),
                "\(agentId) missing from scanner roster"
            )
        }
    }
}
