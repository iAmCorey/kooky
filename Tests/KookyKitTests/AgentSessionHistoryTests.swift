import SQLite3
import XCTest
@testable import KookyKit

final class AgentSessionScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-session-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Fixture helpers

    @discardableResult
    private func writeFile(_ name: String, in dir: URL, lines: [String], mtime: Date? = nil) throws -> URL {
        try SessionStoreFixtures.writeFile(name, in: dir, lines: lines, mtime: mtime)
    }

    private var claudeRoot: URL { tempDir.appendingPathComponent("projects") }
    private var codexRoot: URL { tempDir.appendingPathComponent("sessions") }

    private func scanIsolated(_ overrides: [String: URL] = [:]) -> [AgentSessionRecord] {
        AgentSessionScanner.scan(roots: SessionStoreFixtures.isolatedRoots(base: tempDir, overrides: overrides))
    }

    private func claudeUserLine(text: String, cwd: String = "/tmp/proj") -> String {
        #"{"type":"user","cwd":"\#(cwd)","timestamp":"2026-07-01T00:00:00Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    // MARK: Claude parsing

    func testClaudeRecordPrefersLatestCustomTitle() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        let file = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            #"{"type":"custom-title","customTitle":"old name","sessionId":"x"}"#,
            claudeUserLine(text: "the first prompt"),
            #"{"type":"custom-title","customTitle":"new name","sessionId":"x"}"#,
        ])
        let record = try XCTUnwrap(AgentSessionScanner.claudeRecord(file: file, mtime: Date()))
        XCTAssertEqual(record.title, "new name")
        XCTAssertEqual(record.cwd.path, "/tmp/proj")
        XCTAssertEqual(record.agentId, AgentTemplate.claudeCodeID)
        XCTAssertEqual(record.conversationId, file.deletingPathExtension().lastPathComponent)
    }

    func testClaudeRecordFallsBackToSummaryThenUserText() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        let withSummary = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            #"{"type":"summary","summary":"compact summary"}"#,
            claudeUserLine(text: "raw prompt"),
        ])
        XCTAssertEqual(AgentSessionScanner.claudeRecord(file: withSummary, mtime: Date())?.title, "compact summary")

        let userOnly = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            claudeUserLine(text: "raw prompt"),
        ])
        XCTAssertEqual(AgentSessionScanner.claudeRecord(file: userOnly, mtime: Date())?.title, "raw prompt")
    }

    func testClaudeRecordSkipsInjectedBlocksForTitle() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        // Slash-command expansion, hook caveat, and a content-blocks message —
        // the first REAL prompt (block form) must win.
        let file = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            claudeUserLine(text: "<command-name>/clear</command-name>"),
            claudeUserLine(text: "Caveat: the messages below were generated"),
            #"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":[{"type":"text","text":"real question"}]}}"#,
        ])
        XCTAssertEqual(AgentSessionScanner.claudeRecord(file: file, mtime: Date())?.title, "real question")
    }

    func testClaudeRecordDropsSidechainAndCwdlessFiles() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        let sidechain = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            #"{"type":"user","isSidechain":true,"cwd":"/tmp/proj","message":{"role":"user","content":"sub work"}}"#,
        ])
        XCTAssertNil(AgentSessionScanner.claudeRecord(file: sidechain, mtime: Date()))

        let cwdless = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            #"{"type":"summary","summary":"no user line at all"}"#,
        ])
        XCTAssertNil(AgentSessionScanner.claudeRecord(file: cwdless, mtime: Date()))
    }

    func testClaudeTitleIsFlattenedAndBounded() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        let long = String(repeating: "x", count: 500)
        let file = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            claudeUserLine(text: "line one\\nline two \(long)"),
        ])
        let title = try XCTUnwrap(AgentSessionScanner.claudeRecord(file: file, mtime: Date())?.title)
        XCTAssertFalse(title.contains("\n"), "interior newlines must not survive into composed UI strings")
        XCTAssertLessThanOrEqual(title.count, 160)
    }

    // MARK: Codex parsing

    func testCodexRecordParsesMetaAndUserMessage() throws {
        let dir = codexRoot.appendingPathComponent("2026/07/01")
        let file = try writeFile("rollout-2026-07-01T00-00-00-abc.jsonl", in: dir, lines: [
            #"{"timestamp":"2026-07-01T00:00:00Z","type":"session_meta","payload":{"id":"thread-123","cwd":"/tmp/proj"}}"#,
            #"{"timestamp":"2026-07-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>injected</environment_context>"}]}}"#,
            #"{"timestamp":"2026-07-01T00:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"fix the flaky test"}}"#,
        ])
        let record = try XCTUnwrap(AgentSessionScanner.codexRecord(file: file, mtime: Date()))
        XCTAssertEqual(record.agentId, AgentTemplate.codex.id)
        XCTAssertEqual(record.conversationId, "thread-123")
        XCTAssertEqual(record.cwd.path, "/tmp/proj")
        XCTAssertEqual(record.title, "fix the flaky test")
    }

    func testCodexRecordWithoutUserMessageIsUntitledButResumable() throws {
        let dir = codexRoot.appendingPathComponent("2026/07/01")
        let file = try writeFile("rollout-x.jsonl", in: dir, lines: [
            #"{"type":"session_meta","payload":{"id":"thread-9","cwd":"/tmp/proj"}}"#,
        ])
        let record = try XCTUnwrap(AgentSessionScanner.codexRecord(file: file, mtime: Date()))
        XCTAssertEqual(record.title, "")
        XCTAssertEqual(record.conversationId, "thread-9")
    }

    func testCodexRecordWithoutMetaIsDropped() throws {
        let dir = codexRoot.appendingPathComponent("2026/07/01")
        let corrupt = try writeFile("rollout-bad.jsonl", in: dir, lines: [
            "not json at all {{{",
        ])
        XCTAssertNil(AgentSessionScanner.codexRecord(file: corrupt, mtime: Date()))
    }

    // MARK: Directory walking, sorting, capping

    func testScanMergesSortedByActivityAndIgnoresForeignFiles() throws {
        let projDir = claudeRoot.appendingPathComponent("-tmp-proj")
        try writeFile("\(UUID().uuidString).jsonl", in: projDir,
                      lines: [claudeUserLine(text: "older claude")],
                      mtime: Date(timeIntervalSinceNow: -300))
        // Non-UUID filename (a stray jsonl) must not become a record.
        try writeFile("notes.jsonl", in: projDir,
                      lines: [claudeUserLine(text: "not a session")])
        try writeFile("rollout-a.jsonl", in: codexRoot.appendingPathComponent("2026/07/01"), lines: [
            #"{"type":"session_meta","payload":{"id":"t1","cwd":"/tmp/proj"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"newer codex"}}"#,
        ], mtime: Date(timeIntervalSinceNow: -60))

        let records = scanIsolated([
            AgentTemplate.claudeCodeID: claudeRoot,
            AgentTemplate.codex.id: codexRoot,
        ])
        XCTAssertEqual(records.map(\.title), ["newer codex", "older claude"])
    }

    func testScanCapsPerAgentByRecency() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        let base = Date(timeIntervalSinceNow: -100_000)
        for i in 0..<(AgentSessionScanner.perAgentCap + 5) {
            try writeFile("\(UUID().uuidString).jsonl", in: dir,
                          lines: [claudeUserLine(text: "session \(i)")],
                          mtime: base.addingTimeInterval(Double(i)))
        }
        let records = scanIsolated([AgentTemplate.claudeCodeID: claudeRoot])
        XCTAssertEqual(records.count, AgentSessionScanner.perAgentCap)
        // The cap keeps the NEWEST files — the oldest five fall off.
        XCTAssertEqual(records.first?.title, "session \(AgentSessionScanner.perAgentCap + 4)")
        XCTAssertFalse(records.contains { $0.title == "session 0" })
    }

    func testScanSurvivesMissingRoots() {
        XCTAssertEqual(scanIsolated(), [])
    }

    // MARK: Pi / Oh My Pi

    func testPiStyleRecordReadsHeaderAndLatestRename() throws {
        let dir = tempDir.appendingPathComponent("pi/--tmp-proj--")
        let file = try writeFile("2026-07-01T00-00-00_\(UUID().uuidString).jsonl", in: dir, lines: [
            #"{"type":"session","version":3,"id":"pi-11","timestamp":"t","cwd":"/tmp/proj"}"#,
            #"{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"first ask"}]}}"#,
            #"{"type":"session_info","name":"old name"}"#,
            #"{"type":"session_info","name":"final name"}"#,
        ])
        let record = try XCTUnwrap(AgentSessionScanner.piStyleRecord(file: file, mtime: Date(), agentId: AgentTemplate.pi.id))
        XCTAssertEqual(record.agentId, AgentTemplate.pi.id)
        XCTAssertEqual(record.conversationId, "pi-11")
        XCTAssertEqual(record.cwd.path, "/tmp/proj")
        XCTAssertEqual(record.title, "final name")
    }

    func testPiStyleRecordFallsBackToFirstUserMessage() throws {
        let dir = tempDir.appendingPathComponent("pi/--tmp-proj--")
        let file = try writeFile("s.jsonl", in: dir, lines: [
            #"{"type":"session","id":"pi-12","cwd":"/tmp/proj"}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"agent reply"}]}}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"real ask"}]}}"#,
        ])
        XCTAssertEqual(AgentSessionScanner.piStyleRecord(file: file, mtime: Date(), agentId: AgentTemplate.pi.id)?.title, "real ask")
    }

    func testPiStyleRecordDropsForksAndOmpUsesHeaderTitle() throws {
        let dir = tempDir.appendingPathComponent("omp/-proj")
        let fork = try writeFile("fork.jsonl", in: dir, lines: [
            #"{"type":"session","id":"omp-2","cwd":"/tmp/proj","parentSession":"omp-1"}"#,
        ])
        XCTAssertNil(AgentSessionScanner.piStyleRecord(file: fork, mtime: Date(), agentId: AgentTemplate.ohMyPi.id))

        let titled = try writeFile("titled.jsonl", in: dir, lines: [
            #"{"type":"session","id":"omp-3","cwd":"/tmp/proj","title":"auto title","titleSource":"generated"}"#,
        ])
        let record = try XCTUnwrap(AgentSessionScanner.piStyleRecord(file: titled, mtime: Date(), agentId: AgentTemplate.ohMyPi.id))
        XCTAssertEqual(record.agentId, AgentTemplate.ohMyPi.id)
        XCTAssertEqual(record.title, "auto title")
    }

    func testPiStyleScanSkipsAdvisorTranscripts() throws {
        let root = tempDir.appendingPathComponent("omp-root")
        let dir = root.appendingPathComponent("-proj")
        try writeFile("__advisor-x.jsonl", in: dir, lines: [
            #"{"type":"session","id":"adv-1","cwd":"/tmp/proj"}"#,
        ])
        try writeFile("real.jsonl", in: dir, lines: [
            #"{"type":"session","id":"omp-9","cwd":"/tmp/proj"}"#,
        ])
        let records = AgentSessionScanner.piStyleRecords(under: root, agentId: AgentTemplate.ohMyPi.id)
        XCTAssertEqual(records.map(\.conversationId), ["omp-9"])
    }

    // MARK: Kimi Code

    func testKimiRecordsReadIndexAndBlankDefaultTitles() throws {
        let root = tempDir.appendingPathComponent("kimi")
        let sessionDir = "sessions/wd_proj_abc/session_1111"
        try writeFile("state.json", in: root.appendingPathComponent(sessionDir), lines: [
            #"{"title":"New Session","isCustomTitle":false,"workDir":"/tmp/proj"}"#,
        ])
        let named = "sessions/wd_proj_abc/session_2222"
        try writeFile("state.json", in: root.appendingPathComponent(named), lines: [
            #"{"title":"my task","isCustomTitle":true}"#,
        ])
        try writeFile("session_index.jsonl", in: root, lines: [
            #"{"sessionId":"session_1111","sessionDir":"\#(sessionDir)","workDir":"/tmp/proj"}"#,
            #"{"sessionId":"session_2222","sessionDir":"\#(named)","workDir":"/tmp/proj"}"#,
            #"{"sessionId":"session_3333","sessionDir":"missing/dir","workDir":"/tmp/proj"}"#,
        ])
        let records = AgentSessionScanner.collectKimi(root: root)
        XCTAssertEqual(Set(records.map(\.conversationId)), ["session_1111", "session_2222"],
                       "index rows without a state.json are dropped")
        XCTAssertEqual(records.first { $0.conversationId == "session_1111" }?.title, "",
                       "the untouched default 'New Session' blanks to the untitled placeholder")
        XCTAssertEqual(records.first { $0.conversationId == "session_2222" }?.title, "my task")
    }

    // MARK: OpenCode

    func testOpencodeRecordsQueryTopLevelUnarchivedSessions() throws {
        let dbURL = tempDir.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let setup = """
        CREATE TABLE session (id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_updated INTEGER, time_archived INTEGER);
        INSERT INTO session VALUES ('ses_new', NULL, '/tmp/proj', 'newer', 2000000, NULL);
        INSERT INTO session VALUES ('ses_old', NULL, '/tmp/proj', 'older', 1000000, NULL);
        INSERT INTO session VALUES ('ses_child', 'ses_new', '/tmp/proj', 'subagent', 3000000, NULL);
        INSERT INTO session VALUES ('ses_gone', NULL, '/tmp/proj', 'archived', 4000000, 4000000);
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)

        let records = AgentSessionScanner.collectOpencode(root: dbURL)
        XCTAssertEqual(records.map(\.conversationId), ["ses_new", "ses_old"],
                       "children and archived sessions stay out; newest first")
        XCTAssertEqual(records.first?.title, "newer")
        XCTAssertEqual(records.first?.lastActivity, Date(timeIntervalSince1970: 2000))
    }

    func testOpencodeRecordsSurviveMissingOrForeignDatabase() throws {
        XCTAssertEqual(AgentSessionScanner.collectOpencode(root: tempDir.appendingPathComponent("nope.db")), [])
        let junk = try writeFile("junk.db", in: tempDir, lines: ["not a database"])
        XCTAssertEqual(AgentSessionScanner.collectOpencode(root: junk), [])
    }

    // MARK: Grok Build

    func testGrokRecordUsesSummaryThenChatHistoryFallback() throws {
        let root = tempDir.appendingPathComponent("grok")
        let summarized = root.appendingPathComponent("%2Ftmp%2Fproj/11111111-aaaa-bbbb-cccc-000000000001")
        try writeFile("summary.json", in: summarized, lines: [
            #"{"info":{"id":"11111111-aaaa-bbbb-cccc-000000000001","cwd":"/tmp/proj"},"session_summary":"did the thing"}"#,
        ])
        let fresh = root.appendingPathComponent("%2Ftmp%2Fproj/11111111-aaaa-bbbb-cccc-000000000002")
        try writeFile("summary.json", in: fresh, lines: [
            #"{"info":{"id":"11111111-aaaa-bbbb-cccc-000000000002","cwd":"/tmp/proj"},"session_summary":""}"#,
        ])
        try writeFile("chat_history.jsonl", in: fresh, lines: [
            #"{"type":"system","content":"boot"}"#,
            #"{"type":"user","content":"early ask"}"#,
        ])
        let records = AgentSessionScanner.collectGrok(root: root)
        XCTAssertEqual(Set(records.map(\.title)), ["did the thing", "early ask"])
        XCTAssertTrue(records.allSatisfy { $0.cwd.path == "/tmp/proj" })
    }

    func testGrokFallbackUnwrapsUserQueryFromBlockContent() throws {
        // Current grok writes user content as [{type,text}] blocks with the
        // real ask wrapped in <user_query> among injected blocks — the plain
        // `<`-prefix filter alone would reject every real prompt.
        let root = tempDir.appendingPathComponent("grok-blocks")
        let dir = root.appendingPathComponent("%2Ftmp%2Fproj/11111111-aaaa-bbbb-cccc-000000000003")
        try writeFile("summary.json", in: dir, lines: [
            #"{"info":{"id":"11111111-aaaa-bbbb-cccc-000000000003","cwd":"/tmp/proj"},"session_summary":""}"#,
        ])
        try writeFile("chat_history.jsonl", in: dir, lines: [
            #"{"type":"system","content":"boot"}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_info>\nOS: macos\n</user_info>"}]}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_query>\nwhy is the build slow\n</user_query>"}]}"#,
        ])
        XCTAssertEqual(AgentSessionScanner.collectGrok(root: root).first?.title, "why is the build slow")
    }

    // MARK: Cursor CLI

    func testCursorRecordGatesOnConversationAndReadsMeta() throws {
        let root = tempDir.appendingPathComponent("cursor")
        let real = root.appendingPathComponent("md5hash/22222222-aaaa-bbbb-cccc-000000000001")
        try writeFile("meta.json", in: real, lines: [
            #"{"cwd":"/tmp/proj","title":"fix the bug","updatedAtMs":1750000000000,"hasConversation":true}"#,
        ])
        let shell = root.appendingPathComponent("md5hash/22222222-aaaa-bbbb-cccc-000000000002")
        try writeFile("meta.json", in: shell, lines: [
            #"{"cwd":"/tmp/proj","hasConversation":false}"#,
        ])
        let records = AgentSessionScanner.collectCursor(root: root)
        XCTAssertEqual(records.map(\.conversationId), ["22222222-aaaa-bbbb-cccc-000000000001"],
                       "conversation-less shells are skipped")
        XCTAssertEqual(records.first?.title, "fix the bug")
        XCTAssertEqual(records.first?.lastActivity, Date(timeIntervalSince1970: 1_750_000_000))
    }

    // MARK: Copilot CLI

    func testCopilotRecordParsesWorkspaceYaml() throws {
        let root = tempDir.appendingPathComponent("copilot")
        try writeFile("workspace.yaml", in: root.appendingPathComponent("33333333-aaaa-bbbb-cccc-000000000001"), lines: [
            "id: 33333333-aaaa-bbbb-cccc-000000000001",
            "cwd: /tmp/proj",
            "name: \"rename: the config loader\"",
            "updated_at: 2026-07-01T00:00:00Z",
        ])
        try writeFile("workspace.yaml", in: root.appendingPathComponent("cwdless"), lines: [
            "id: cwdless",
        ])
        let records = AgentSessionScanner.collectCopilot(root: root)
        XCTAssertEqual(records.map(\.conversationId), ["33333333-aaaa-bbbb-cccc-000000000001"])
        XCTAssertEqual(records.first?.title, "rename: the config loader",
                       "value splits on the FIRST colon-space; quotes are trimmed")
        XCTAssertEqual(records.first?.cwd.path, "/tmp/proj")
    }

    // MARK: Kiro CLI

    func testKiroRecordsExtractTitleInSQL() throws {
        let dbURL = tempDir.appendingPathComponent("kiro.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let summarized = #"{"latest_summary":"long chat summary","history":[{"user":{"content":{"Prompt":{"prompt":"first ask"}}}}]}"#
        let fresh = #"{"latest_summary":null,"history":[{"user":{"content":{"Prompt":{"prompt":"early ask"}}}}]}"#
        let setup = """
        CREATE TABLE conversations_v2 (key TEXT, conversation_id TEXT, value TEXT, created_at INTEGER, updated_at INTEGER, PRIMARY KEY (key, conversation_id));
        INSERT INTO conversations_v2 VALUES ('/tmp/proj', 'kiro-1', '\(summarized)', 1000, 2000000);
        INSERT INTO conversations_v2 VALUES ('/tmp/proj', 'kiro-2', '\(fresh)', 1000, 1000000);
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)

        let records = AgentSessionScanner.collectKiro(root: dbURL)
        XCTAssertEqual(records.map(\.conversationId), ["kiro-1", "kiro-2"])
        XCTAssertEqual(records.first?.title, "long chat summary",
                       "the running summary outranks the first prompt")
        XCTAssertEqual(records.last?.title, "early ask")
        XCTAssertEqual(records.first?.cwd.path, "/tmp/proj")
    }

    // MARK: Gemini CLI

    func testGeminiRecordsRequireProjectRootAndParseSetRecords() throws {
        let root = tempDir.appendingPathComponent("gemini-tmp")
        // Modern layout: readable dir + .project_root sidecar.
        let project = root.appendingPathComponent("myproj")
        try writeFile(".project_root", in: project, lines: ["/tmp/proj"])
        try writeFile("session-2026-07-27T14-11-abc.jsonl", in: project.appendingPathComponent("chats"), lines: [
            #"{"sessionId":"gem-1","projectHash":"h","kind":"main","startTime":"t","lastUpdated":"t"}"#,
            #"{"$set":{"messages":[{"type":"user","content":[{"text":"<session_context>injected</session_context>"}]},{"type":"user","content":[{"text":"real gemini ask"}]}]}}"#,
        ])
        // Subagent transcript: dropped by the kind gate.
        try writeFile("session-sub.jsonl", in: project.appendingPathComponent("chats"), lines: [
            #"{"sessionId":"gem-2","kind":"subagent"}"#,
        ])
        // Legacy sha256 dir without the sidecar: no recoverable cwd, skipped.
        try writeFile("session-old.jsonl", in: root.appendingPathComponent("abc123hash/chats"), lines: [
            #"{"sessionId":"gem-3","kind":"main"}"#,
        ])
        let records = AgentSessionScanner.collectGemini(root: root)
        XCTAssertEqual(records.map(\.conversationId), ["gem-1"])
        XCTAssertEqual(records.first?.title, "real gemini ask",
                       "the session_context injection is filtered; summary would win if present")
        XCTAssertEqual(records.first?.cwd.path, "/tmp/proj")
    }

    func testGeminiRecordPrefersSummaryOverUserText() throws {
        let root = tempDir.appendingPathComponent("gemini-tmp2")
        let project = root.appendingPathComponent("p")
        try writeFile(".project_root", in: project, lines: ["/tmp/proj"])
        try writeFile("session-a.jsonl", in: project.appendingPathComponent("chats"), lines: [
            #"{"sessionId":"gem-9","kind":"main"}"#,
            #"{"$set":{"messages":[{"type":"user","content":[{"text":"the ask"}]}]}}"#,
            #"{"$set":{"summary":"a tidy summary"}}"#,
        ])
        XCTAssertEqual(AgentSessionScanner.collectGemini(root: root).first?.title, "a tidy summary")
    }

    // MARK: Droid

    func testDroidRecordReadsRewrittenHeaderAndFiltersLineage() throws {
        let root = tempDir.appendingPathComponent("factory")
        let dir = root.appendingPathComponent("-tmp-proj")
        try writeFile("11111111-2222-4333-8444-000000000001.jsonl", in: dir, lines: [
            #"{"type":"session_start","id":"11111111-2222-4333-8444-000000000001","title":"auto title","sessionTitle":"renamed title","cwd":"/tmp/old","lastCwd":"/tmp/proj"}"#,
            #"{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#,
        ])
        // Subagent (lineage field) and message-less sessions never list.
        try writeFile("sub.jsonl", in: dir, lines: [
            #"{"type":"session_start","id":"sub","cwd":"/tmp/proj","callingSessionId":"parent-1"}"#,
            #"{"type":"message","id":"m1"}"#,
        ])
        try writeFile("empty.jsonl", in: dir, lines: [
            #"{"type":"session_start","id":"empty","cwd":"/tmp/proj"}"#,
        ])
        // Legacy flat file at the top level still counts.
        try writeFile("22222222-2222-4333-8444-000000000002.jsonl", in: root, lines: [
            #"{"type":"session_start","id":"22222222-2222-4333-8444-000000000002","title":"legacy","cwd":"/tmp/proj"}"#,
            #"{"type":"message","id":"m1"}"#,
        ])
        let records = AgentSessionScanner.collectDroid(root: root)
        XCTAssertEqual(Set(records.map(\.conversationId)),
                       ["11111111-2222-4333-8444-000000000001", "22222222-2222-4333-8444-000000000002"])
        let renamed = records.first { $0.conversationId.hasSuffix("001") }
        XCTAssertEqual(renamed?.title, "renamed title", "sessionTitle outranks the auto title")
        XCTAssertEqual(renamed?.cwd.path, "/tmp/proj", "lastCwd outranks the spawn cwd")
    }

    func testDroidRecordHonorsArchivedSidecar() throws {
        let root = tempDir.appendingPathComponent("factory2")
        let dir = root.appendingPathComponent("-tmp-proj")
        try writeFile("aaaa.jsonl", in: dir, lines: [
            #"{"type":"session_start","id":"aaaa","cwd":"/tmp/proj"}"#,
            #"{"type":"message","id":"m1"}"#,
        ])
        try writeFile("aaaa.settings.json", in: dir, lines: [
            #"{"archivedAt":"2026-07-01T00:00:00Z"}"#,
        ])
        XCTAssertEqual(AgentSessionScanner.collectDroid(root: root), [],
                       "archived sessions are hidden, matching droid's own picker")
    }

    // MARK: Reasonix

    func testReasonixRecordReadsMetaSidecar() throws {
        let root = tempDir.appendingPathComponent("reasonix")
        let sessions = root.appendingPathComponent("-tmp-proj/sessions")
        try writeFile("20260727-120000.000000000-gpt.jsonl", in: sessions, lines: [
            #"{"role":"user","content":"the actual ask"}"#,
        ])
        try writeFile("20260727-120000.000000000-gpt.jsonl.meta", in: sessions, lines: [
            #"{"id":"20260727-120000.000000000-gpt","custom_title":"","topic_title":"","preview":"the actual ask","turns":2,"workspace_root":"/tmp/proj","schema_version":1}"#,
        ])
        // Event sidecar named *.jsonl must not become a phantom session.
        try writeFile("20260727-120000.000000000-gpt.events.jsonl", in: sessions, lines: ["{}"])
        // Zero-turn sessions are invisible to Reasonix's own picker.
        try writeFile("20260727-130000.000000000-gpt.jsonl", in: sessions, lines: ["{}"])
        try writeFile("20260727-130000.000000000-gpt.jsonl.meta", in: sessions, lines: [
            #"{"turns":0,"workspace_root":"/tmp/proj","schema_version":1}"#,
        ])
        let records = AgentSessionScanner.collectReasonix(root: root)
        XCTAssertEqual(records.map(\.conversationId), ["20260727-120000.000000000-gpt"])
        XCTAssertEqual(records.first?.title, "the actual ask")
        XCTAssertEqual(records.first?.cwd.path, "/tmp/proj")
    }

    func testReasonixRecordPrefersCustomTitleAndRequiresMeta() throws {
        let root = tempDir.appendingPathComponent("reasonix2")
        let sessions = root.appendingPathComponent("-p/sessions")
        try writeFile("a-gpt.jsonl", in: sessions, lines: ["{}"])
        try writeFile("a-gpt.jsonl.meta", in: sessions, lines: [
            #"{"custom_title":"my rename","topic_title":"topic","preview":"ask","turns":1,"workspace_root":"/tmp/proj","schema_version":1}"#,
        ])
        // No sidecar → no id/cwd source → skipped, never guessed.
        try writeFile("b-gpt.jsonl", in: sessions, lines: ["{}"])
        let records = AgentSessionScanner.collectReasonix(root: root)
        XCTAssertEqual(records.map(\.title), ["my rename"])
    }

    func testCopilotBlockScalarNameCannotOverwriteTopLevelFields() throws {
        // A multi-line first prompt is a YAML block scalar; its indented
        // lines must neither become the literal title ("|-") nor be read as
        // top-level fields (a prompt containing "cwd: /evil" once could
        // redirect the resume directory).
        let root = tempDir.appendingPathComponent("copilot-block")
        try writeFile("workspace.yaml", in: root.appendingPathComponent("44444444-aaaa-bbbb-cccc-000000000001"), lines: [
            "id: 44444444-aaaa-bbbb-cccc-000000000001",
            "cwd: /tmp/proj",
            "name: |-",
            "  first line of a long prompt",
            "  cwd: /evil/path",
            "updated_at: 2026-07-01T00:00:00Z",
        ])
        let record = try XCTUnwrap(AgentSessionScanner.collectCopilot(root: root).first)
        XCTAssertEqual(record.title, "first line of a long prompt")
        XCTAssertEqual(record.cwd.path, "/tmp/proj", "indented block lines must never override top-level fields")
    }

    // MARK: Cross-store roster

    func testEveryStoreAgentIdIsARealBuiltinWithResume() {
        for agentId in AgentSessionScanner.supportedAgentIds {
            let template = AgentTemplate.builtin(id: agentId)
            XCTAssertNotNil(template, "\(agentId) is not a builtin template id")
            XCTAssertTrue(template?.supportsResume == true,
                          "\(agentId) has no resumeStrategy — its history rows could never resume")
        }
    }

    // MARK: Relative time label

    func testRelativeActivityLabelTiers() {
        let now = Date()
        let bundle = KookyAppLanguage.english.previewBundle
        XCTAssertEqual(relativeActivityLabel(now.addingTimeInterval(-5), now: now, bundle: bundle), "now")
        XCTAssertEqual(relativeActivityLabel(now.addingTimeInterval(-120), now: now, bundle: bundle), "2m")
        XCTAssertEqual(relativeActivityLabel(now.addingTimeInterval(-7200), now: now, bundle: bundle), "2h")
        XCTAssertEqual(
            relativeActivityLabel(
                now.addingTimeInterval(-3 * 86_400),
                now: now,
                bundle: bundle
            ),
            "3d"
        )
        // Past a week it's a date, not a count.
        let old = relativeActivityLabel(
            now.addingTimeInterval(-30 * 86_400),
            now: now,
            bundle: bundle
        )
        XCTAssertFalse(old.hasSuffix("d"))
        XCTAssertFalse(old.isEmpty)
    }
}

@MainActor
final class AgentSessionResumeTests: XCTestCase {
    private func makeStore(resumeSetting: Bool) -> WorkspaceStore {
        WorkspaceStore(
            persistence: InMemoryPersistence(),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { resumeSetting }
        )
    }

    private func makeRecord(agentId: String, cwd: URL) -> AgentSessionRecord {
        SessionStoreFixtures.record(agentId: agentId, cwd: cwd)
    }

    func testResumeAgentSessionForcesResumePastDisabledSetting() throws {
        // The `agents.resumeConversations` setting only governs automatic
        // relaunch-time resume — a History click is explicit and must work
        // with the setting OFF.
        let store = makeStore(resumeSetting: false)
        store.addWorkspace(workingDirectory: FileManager.default.temporaryDirectory)
        let cwd = FileManager.default.temporaryDirectory
        let record = makeRecord(agentId: AgentTemplate.claudeCodeID, cwd: cwd)

        let session = try store.resumeAgentSession(record).get()
        XCTAssertEqual(session.agent.id, AgentTemplate.claudeCodeID)
        XCTAssertEqual(session.conversationId, record.conversationId)
        XCTAssertEqual(session.resumedConversationId, record.conversationId,
                       "forceResume must bypass the resumeProvider gate")
        XCTAssertEqual(session.currentDirectory.standardizedFileURL, cwd.standardizedFileURL)
        XCTAssertEqual(store.active?.activeSession?.id, session.id, "resumed tab becomes active")
    }

    func testResumeAgentSessionAvoidsSSHWorkspaces() throws {
        // An SSH workspace would wrap the launch in kooky-ssh and drop the
        // resume id — the tab must land in a local workspace instead.
        let store = makeStore(resumeSetting: true)
        store.addWorkspace(workingDirectory: FileManager.default.temporaryDirectory, sshRemoteHost: "user@box")
        XCTAssertNotNil(store.active?.sshRemoteHost)

        let record = makeRecord(agentId: AgentTemplate.claudeCodeID, cwd: FileManager.default.temporaryDirectory)
        let session = try store.resumeAgentSession(record).get()
        XCTAssertNil(store.active?.sshRemoteHost, "resumed tab must land in a local workspace")
        XCTAssertEqual(store.active?.activeSession?.id, session.id)
        XCTAssertEqual(session.resumedConversationId, record.conversationId)
    }

    func testResumeAgentSessionCreatesLocalWorkspaceWhenAllAreSSH() throws {
        // Codex review P2: with every workspace SSH, the old guard made a
        // history click a silent no-op. It must open a local workspace at
        // the conversation's directory instead.
        let store = makeStore(resumeSetting: true)
        let seed = store.active!
        store.addWorkspace(workingDirectory: FileManager.default.temporaryDirectory, sshRemoteHost: "user@box")
        store.closeWorkspace(seed)
        XCTAssertTrue(store.workspaces.allSatisfy { $0.sshRemoteHost != nil })

        let cwd = FileManager.default.temporaryDirectory
        let record = makeRecord(agentId: AgentTemplate.claudeCodeID, cwd: cwd)
        let session = try store.resumeAgentSession(record).get()
        let landed = try XCTUnwrap(store.active)
        XCTAssertNil(landed.sshRemoteHost)
        XCTAssertEqual(landed.workingDirectory.standardizedFileURL, cwd.standardizedFileURL)
        XCTAssertEqual(session.resumedConversationId, record.conversationId)
    }

    func testResumeAgentSessionRejectsUnknownAgent() {
        let store = makeStore(resumeSetting: true)
        store.addWorkspace(workingDirectory: FileManager.default.temporaryDirectory)
        let record = makeRecord(agentId: "no-such-agent", cwd: FileManager.default.temporaryDirectory)
        // The refusal now carries its reason (the history panel shows it)
        // instead of collapsing to nil.
        guard case .failure(let refusal) = store.resumeAgentSession(record) else {
            return XCTFail("an unknown agent must be refused")
        }
        XCTAssertEqual(refusal, .agentCannotResume)
    }

    func testResumedConversationIdMirrorsTheSSHDrop() {
        // makeSessionConfig drops the LOCAL resume id for an SSH spawn —
        // the recorded field must say nil too, or downstream consumers
        // (Codex usage monitor) would hunt for a rollout that was never
        // resumed locally.
        let store = makeStore(resumeSetting: true)
        store.addWorkspace(workingDirectory: FileManager.default.temporaryDirectory, sshRemoteHost: "user@box")
        let session = store.addTab(
            in: store.active!,
            template: .claudeCode,
            conversationId: "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertNil(session.resumedConversationId)
        XCTAssertEqual(session.conversationId, "11111111-2222-3333-4444-555555555555",
                       "the persisted id survives — only the spawn-time resume is dropped")
    }

    func testAutomaticResumeStaysGatedBySetting() {
        // Pin the pre-existing contract: WITHOUT forceResume, a disabled
        // setting still suppresses the resume argument (the id persists).
        let store = makeStore(resumeSetting: false)
        store.addWorkspace(workingDirectory: FileManager.default.temporaryDirectory)
        let workspace = store.active!
        let session = store.addTab(
            in: workspace,
            template: .claudeCode,
            conversationId: "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(session.conversationId, "11111111-2222-3333-4444-555555555555")
        XCTAssertNil(session.resumedConversationId)
    }

    func testRightSidebarContentPersistsAndRestores() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        store.addWorkspace(workingDirectory: FileManager.default.temporaryDirectory)
        store.setRightSidebarContent(.info)
        store.flushPersistence()
        XCTAssertEqual(persistence.saved?.rightSidebarContent, .info)

        let restored = WorkspaceStore(
            persistence: InMemoryPersistence(initial: persistence.saved),
            engineFactory: { TestEngine() }
        )
        XCTAssertEqual(restored.rightSidebarContent, .info)
    }
}

/// The History pane's workspace filter, end to end: the store picks the
/// root and its spellings, the pure filter applies them. One class because
/// the store half needs the main actor and the filter half doesn't care.
@MainActor
final class SessionHistoryFilterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-history-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func record(_ agentId: String = AgentTemplate.claudeCodeID, cwd: String, title: String = "t") -> AgentSessionRecord {
        SessionStoreFixtures.record(agentId: agentId, cwd: URL(fileURLWithPath: cwd), title: title, conversationId: UUID().uuidString)
    }

    private func filter(roots: [String] = [], agentId: String? = nil, query: String = "") -> SessionHistoryFilter {
        SessionHistoryFilter(workspaceRootPaths: roots, agentId: agentId, query: query)
    }

    // MARK: Pure filter

    func testWorkspaceScopeKeepsTheRootAndItsDescendantsOnly() {
        let inside = [record(cwd: "/a/b"), record(cwd: "/a/b/c/d")]
        // `/a/bc` shares the string prefix but is a sibling, and `/a` is
        // the parent — neither is "inside this workspace".
        let outside = [record(cwd: "/a/bc"), record(cwd: "/a"), record(cwd: "/x")]
        XCTAssertEqual(filter(roots: ["/a/b"]).apply(inside + outside).visible.map(\.id), inside.map(\.id))
    }

    func testEmptyScopeKeepsEveryRecord() {
        XCTAssertEqual(filter().apply([record(cwd: "/a"), record(cwd: "/b")]).visible.count, 2)
    }

    func testAnyRootSpellingAdmitsARecord() {
        let records = [record(cwd: "/logical/proj/sub"), record(cwd: "/physical/proj"), record(cwd: "/elsewhere")]
        XCTAssertEqual(
            filter(roots: ["/logical/proj", "/physical/proj"]).apply(records).visible.map(\.id),
            Array(records.prefix(2)).map(\.id)
        )
    }

    func testRootOfTheDiskScopesEveryAbsolutePath() {
        // Codex P2: the prefix form spelled root-of-disk as `//` and hid
        // everything but a session at `/` itself.
        XCTAssertTrue(pathIsInside("/Users/a/proj", root: "/"))
        XCTAssertTrue(pathIsInside("/", root: "/"))
        XCTAssertEqual(filter(roots: ["/"]).apply([record(cwd: "/Users/a"), record(cwd: "/x")]).visible.count, 2)
    }

    func testPrivateSpellingCoversOnlyTheThreeSymlinkedSystemDirs() {
        XCTAssertEqual(privateSpelling(of: "/var/folders/x/proj"), "/private/var/folders/x/proj")
        XCTAssertEqual(privateSpelling(of: "/tmp"), "/private/tmp")
        XCTAssertNil(privateSpelling(of: "/Users/a/proj"))
        XCTAssertNil(privateSpelling(of: "/variety"), "sibling trap")
    }

    func testAgentChipsDrawFromTheScopeNotTheNarrowedList() {
        // Chips come from the scoped records BEFORE the agent/query narrow:
        // an agent hidden only by the current chip must keep its chip, an
        // agent with no sessions in this workspace must lose it.
        let records = [
            record(AgentTemplate.claudeCodeID, cwd: "/a/b"),
            record("codex", cwd: "/a/b"),
            record("pi", cwd: "/x"),
        ]
        let result = filter(roots: ["/a/b"], agentId: "codex").apply(records)
        XCTAssertEqual(result.presentAgentIds, [AgentTemplate.claudeCodeID, "codex"])
        XCTAssertEqual(result.visible.map(\.id), [records[1].id])
    }

    func testNarrowComposesAgentAndQuery() {
        let records = [
            record(AgentTemplate.claudeCodeID, cwd: "/p", title: "Fix parser"),
            record(AgentTemplate.claudeCodeID, cwd: "/p", title: "Write docs"),
            record("codex", cwd: "/p", title: "Fix parser"),
        ]
        XCTAssertEqual(filter(agentId: AgentTemplate.claudeCodeID, query: "PARSER").apply(records).visible.map(\.id), [records[0].id])
    }

    // MARK: Store-side root

    func testWorkspaceRootIsTheRepoRootNotTheTabCwd() throws {
        // `workingDirectory` follows the active tab's cd — anchoring the
        // filter there would hide a root-launched session after `cd src`.
        let repo = tempDir.appendingPathComponent("repo")
        let src = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        let store = makeTestStore()
        store.addWorkspace(workingDirectory: src)
        XCTAssertFalse(store.historyFilterCurrentWorkspace, "off by default, like the agent chip")
        XCTAssertNotNil(store.historyScopeAnchor, "the checkbox row shows for a local workspace")
        XCTAssertNil(store.historyWorkspaceRoot, "no root while the checkbox is off")

        store.historyFilterCurrentWorkspace = true
        XCTAssertEqual(store.historyWorkspaceRoot?.standardizedFileURL.path, repo.standardizedFileURL.path)
    }

    func testWorkspaceRootFallsBackToTheWorkspaceDirOutsideGit() throws {
        let plain = tempDir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let store = makeTestStore()
        store.addWorkspace(workingDirectory: plain)
        store.historyFilterCurrentWorkspace = true
        XCTAssertEqual(store.historyWorkspaceRoot?.standardizedFileURL.path, plain.standardizedFileURL.path)
    }

    func testWorkspaceRootPathsCarryBothSpellingsOfASymlinkedRoot() throws {
        // OSC 7 reports the logical path the user typed (through the link);
        // an agent's own record carries getcwd()'s physical path. The store
        // hands the filter both, so either spelling lands in the workspace.
        let real = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let physical = real.resolvingSymlinksInPath()
        XCTAssertNotEqual(physical.path, link.path)

        let store = makeTestStore()
        store.addWorkspace(workingDirectory: link)
        store.historyFilterCurrentWorkspace = true
        let paths = store.historyWorkspaceRootPaths
        XCTAssertTrue(paths.contains(link.standardizedFileURL.path), "\(paths)")
        XCTAssertTrue(paths.contains(physical.path), "\(paths)")

        let records = [
            record(cwd: physical.appendingPathComponent("sub").path),
            record(cwd: link.path),
            record(cwd: tempDir.appendingPathComponent("elsewhere").path),
        ]
        XCTAssertEqual(
            filter(roots: paths).apply(records).visible.map(\.id),
            Array(records.prefix(2)).map(\.id)
        )
    }

    func testSymlinkIntoARepoAnchorsOnThePhysicalRepoRoot() throws {
        // Codex P2: `~/alias -> ~/repo/src` has no `.git` above its logical
        // path; git itself works from the physical cwd and answers `~/repo`.
        // Sessions at the repo root AND sessions recorded through the alias
        // (a logical-$PWD agent) both belong to this workspace.
        let repo = tempDir.appendingPathComponent("repo")
        let src = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let alias = tempDir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: src)

        let store = makeTestStore()
        store.addWorkspace(workingDirectory: alias)
        store.historyFilterCurrentWorkspace = true
        let physicalRepo = canonicalDiskPath(repo)
        XCTAssertEqual(store.historyWorkspaceRoot?.path, physicalRepo.path)

        let paths = store.historyWorkspaceRootPaths
        let records = [
            record(cwd: physicalRepo.path),
            record(cwd: alias.appendingPathComponent("deep").path),
            record(cwd: tempDir.appendingPathComponent("elsewhere").path),
        ]
        XCTAssertEqual(filter(roots: paths).apply(records).visible.map(\.id), Array(records.prefix(2)).map(\.id), "\(paths)")
    }

    func testRootPathsCarryTheKernelSpellingOfATempDirRoot() throws {
        // An agent launched under `/var/…` records `/private/var/…`
        // (getcwd); Foundation's resolved root says `/var/…`.
        let plain = tempDir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let store = makeTestStore()
        store.addWorkspace(workingDirectory: plain)
        store.historyFilterCurrentWorkspace = true
        let root = try XCTUnwrap(store.historyWorkspaceRoot)
        try XCTSkipUnless(privateSpelling(of: root.path) != nil, "temp dir not under a /private-backed dir: \(root.path)")
        let kernel = record(cwd: "/private" + root.path + "/sub")
        XCTAssertEqual(filter(roots: store.historyWorkspaceRootPaths).apply([kernel]).visible.count, 1, "\(store.historyWorkspaceRootPaths)")
    }

    func testScopeAnchorIsNilForSSHWorkspaces() {
        // The local spawn dir says nothing about a remote project's
        // sessions — the checkbox row hides and the filter no-ops there.
        let store = makeTestStore()
        store.addWorkspace(workingDirectory: tempDir, sshRemoteHost: "user@box")
        store.historyFilterCurrentWorkspace = true
        XCTAssertNil(store.historyScopeAnchor)
        XCTAssertNil(store.historyWorkspaceRoot)
        XCTAssertEqual(store.historyWorkspaceRootPaths, [])
    }
}
