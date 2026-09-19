import SQLite3
import XCTest
@testable import KookyKit


private final class SessionScanGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let result: [AgentSessionRecord]

    init(result: [AgentSessionRecord]) {
        self.result = result
    }

    func scan() -> [AgentSessionRecord] {
        started.signal()
        release.wait()
        return result
    }
}
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

    // MARK: On-demand first message (history hover)

    private func record(
        agentId: String,
        id: String = UUID().uuidString,
        cwd: String = "/tmp/proj",
        sourceURL: URL
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            agentId: agentId,
            conversationId: id,
            title: "",
            cwd: URL(fileURLWithPath: cwd),
            lastActivity: Date(),
            sourceURL: sourceURL
        )
    }

    func testFirstMessageClaudeKeepsFullMultilineText() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        let file = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            #"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":"line one\nline two\nline three"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"reply"}}"#,
        ])
        let rec = record(agentId: AgentTemplate.claudeCodeID, sourceURL: file)
        XCTAssertEqual(
            AgentSessionScanner.firstMessageText(for: rec),
            "line one\nline two\nline three"
        )
    }

    func testFirstMessageClaudeSkipsSidechainAndInjection() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        let file = try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [
            #"{"type":"user","isSidechain":true,"cwd":"/tmp/proj","message":{"role":"user","content":"sub work"}}"#,
            #"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":"<system-reminder>inject"}}"#,
            #"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":"real ask"}}"#,
        ])
        let rec = record(agentId: AgentTemplate.claudeCodeID, sourceURL: file)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "real ask")
    }

    func testFirstMessageCodexReadsUserMessageEvent() throws {
        let dir = codexRoot.appendingPathComponent("2026/07/01")
        let file = try writeFile("rollout-x.jsonl", in: dir, lines: [
            #"{"type":"session_meta","payload":{"id":"thread-9","cwd":"/tmp/proj"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"first ask"}}"#,
        ])
        let rec = record(agentId: AgentTemplate.codex.id, sourceURL: file)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "first ask")
    }

    func testFirstMessagePiKeepsFullMultiline() throws {
        let dir = tempDir.appendingPathComponent("pi/--tmp-proj--")
        let file = try writeFile("s.jsonl", in: dir, lines: [
            #"{"type":"session","id":"pi-1","cwd":"/tmp/proj"}"#,
            #"{"type":"message","message":{"role":"user","content":"multi\nline ask"}}"#,
        ])
        let rec = record(agentId: AgentTemplate.pi.id, sourceURL: file)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "multi\nline ask")
    }

    func testFirstMessageGeminiReadsSetMessages() throws {
        let root = tempDir.appendingPathComponent("gemini")
        let file = try writeFile("session-x.jsonl", in: root, lines: [
            #"{"sessionId":"g-1","kind":"main"}"#,
            #"{"$set":{"messages":[{"type":"user","content":[{"text":"gemini ask"}]}]}}"#,
        ])
        let rec = record(agentId: AgentTemplate.gemini.id, sourceURL: file)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "gemini ask")
    }

    func testFirstMessageGrokUnwrapsUserQuery() throws {
        let root = tempDir.appendingPathComponent("grok")
        let session = root.appendingPathComponent("p/sess")
        try writeFile("chat_history.jsonl", in: session, lines: [
            #"{"type":"user","content":[{"type":"text","text":"<user_info>ctx</user_info><user_query>grok ask</user_query>"}]}"#,
        ])
        let rec = record(agentId: AgentTemplate.grok.id, sourceURL: session)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "grok ask")
    }

    func testFirstMessageReasonixReadsPreview() throws {
        let root = tempDir.appendingPathComponent("reasonix")
        let sessions = root.appendingPathComponent("-p/sessions")
        let file = try writeFile("a-gpt.jsonl", in: sessions, lines: ["{}"])
        try writeFile("a-gpt.jsonl.meta", in: sessions, lines: [
            #"{"schema_version":1,"workspace_root":"/tmp/proj","preview":"reasonix\nask","turns":2}"#,
        ])
        let rec = record(agentId: AgentTemplate.reasonix.id, sourceURL: file)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "reasonix\nask")
    }

    func testFirstMessageCopilotReadsWholeNameBlock() throws {
        let root = tempDir.appendingPathComponent("copilot")
        let session = root.appendingPathComponent("cop-1")
        try writeFile("workspace.yaml", in: session, lines: [
            "id: cop-1",
            "name: |-",
            "  first line",
            "  second line",
            "cwd: /tmp/proj",
        ])
        let rec = record(agentId: AgentTemplate.copilot.id, sourceURL: session)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "first line\nsecond line")
    }

    func testFirstMessageKiroReadsPromptWhole() throws {
        let dbURL = tempDir.appendingPathComponent("kiro.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let setup = """
        CREATE TABLE conversations_v2 (key TEXT, conversation_id TEXT, value TEXT, created_at INTEGER, updated_at INTEGER, PRIMARY KEY (key, conversation_id));
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        let blob = #"{"history":[{"user":{"content":{"Prompt":{"prompt":"kiro\nask"}}}}]}"#
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "INSERT INTO conversations_v2 (key, conversation_id, value, updated_at) VALUES (?, ?, ?, ?)", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "/tmp/proj", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, "kiro-1", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, blob, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 4, 1_000)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        let rec = record(agentId: AgentTemplate.kiro.id, id: "kiro-1", cwd: "/tmp/proj", sourceURL: dbURL)
        XCTAssertEqual(AgentSessionScanner.firstMessageText(for: rec), "kiro\nask")
    }

    func testFirstMessageFallsBackToNilForUnmappedAgents() throws {
        let rec = record(agentId: AgentTemplate.opencode.id, sourceURL: tempDir)
        XCTAssertNil(AgentSessionScanner.firstMessageText(for: rec))
    }

    func testFileBackedRecordCapturesCreationDate() throws {
        let dir = claudeRoot.appendingPathComponent("-tmp-proj")
        try writeFile("\(UUID().uuidString).jsonl", in: dir, lines: [claudeUserLine(text: "hello")])
        let record = try XCTUnwrap(
            scanIsolated([AgentTemplate.claudeCodeID: claudeRoot])
                .first { $0.agentId == AgentTemplate.claudeCodeID }
        )
        let createdAt = try XCTUnwrap(record.createdAt)
        XCTAssertLessThanOrEqual(createdAt, Date())
    }

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

    func testChineseSessionDeletionStringsRemainLocalized() {
        let bundle = KookyAppLanguage.simplifiedChinese.previewBundle
        XCTAssertEqual(String(localized: "Rescan sessions", bundle: bundle), "重新扫描会话")
        XCTAssertEqual(String(localized: "DELETE-SESSION", bundle: bundle), "删除会话")
        XCTAssertEqual(String(localized: "deleting…", bundle: bundle), "正在删除…")
        XCTAssertEqual(String(localized: "couldn't delete session", bundle: bundle), "无法删除会话")
    }

    // MARK: Deletion

    func testDeleteRemovesFileBackedSession() throws {
        let root = tempDir.appendingPathComponent("delete-claude")
        let project = root.appendingPathComponent("proj-hash")
        let target = try writeFile("11111111-1111-1111-1111-111111111111.jsonl", in: project, lines: [
            claudeUserLine(text: "delete me", cwd: "/tmp/proj"),
        ])
        let sibling = try writeFile("22222222-2222-2222-2222-222222222222.jsonl", in: project, lines: [
            claudeUserLine(text: "keep me", cwd: "/tmp/proj"),
        ])
        let record = try XCTUnwrap(AgentSessionScanner.claudeRecord(file: target, mtime: Date()))

        XCTAssertTrue(AgentSessionScanner.delete(record))

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "the deleted session's transcript must be gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path),
                      "unrelated sessions must survive")
        let remaining = scanIsolated([AgentTemplate.claudeCodeID: root])
        XCTAssertEqual(remaining.map(\.conversationId), ["22222222-2222-2222-2222-222222222222"])
    }

    func testDeleteRemovesClaudeIndexAndBackups() throws {
        let root = tempDir.appendingPathComponent("delete-claude-companions")
        let project = root.appendingPathComponent("proj-hash")
        let id = "11111111-1111-1111-1111-111111111111"
        let target = try writeFile("\(id).jsonl", in: project, lines: [
            claudeUserLine(text: "delete me", cwd: "/tmp/proj")
        ])
        let backup = try writeFile("\(id).jsonl.bak.1", in: project, lines: ["backup"])
        let index = try writeFile("sessions-index.json", in: project, lines: [
            #"[{"sessionId":"11111111-1111-1111-1111-111111111111","fullPath":"/tmp/target"},{"sessionId":"22222222-2222-2222-2222-222222222222","fullPath":"/tmp/keep"}]"#
        ])
        let record = try XCTUnwrap(AgentSessionScanner.claudeRecord(file: target, mtime: Date()))

        XCTAssertTrue(AgentSessionScanner.delete(record))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]]
        XCTAssertEqual(remaining?.compactMap { $0["sessionId"] as? String }, ["22222222-2222-2222-2222-222222222222"])
    }

    func testDeleteRemovesCodexHistoryEntry() throws {
        let root = tempDir.appendingPathComponent("delete-codex-companions")
        let rollout = try writeFile("rollout-2026-07-01T00-00-00-thread-123.jsonl", in: root.appendingPathComponent("sessions/2026/07/01"), lines: [
            #"{"type":"session_meta","payload":{"id":"thread-123","cwd":"/tmp/proj"}}"#
        ])
        let history = try writeFile("history.jsonl", in: root, lines: [
            #"{"session_id":"thread-123","text":"delete me"}"#,
            #"{"session_id":"thread-keep","text":"keep me"}"#
        ])
        let record = try XCTUnwrap(AgentSessionScanner.codexRecord(file: rollout, mtime: Date()))

        XCTAssertTrue(AgentSessionScanner.delete(record))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollout.path))
        let remaining = String(decoding: try Data(contentsOf: history), as: UTF8.self)
        XCTAssertFalse(remaining.contains("thread-123"))
        XCTAssertTrue(remaining.contains("thread-keep"))
    }

    func testDeleteRemovesKimiDirectoryAndIndexEntry() throws {
        let root = tempDir.appendingPathComponent("delete-kimi-companions")
        let sessionDir = root.appendingPathComponent("sessions/wd_proj/session_1111")
        try writeFile("state.json", in: sessionDir, lines: [
            #"{"title":"delete me","isCustomTitle":true}"#
        ])
        try writeFile("transcript.jsonl", in: sessionDir, lines: ["private transcript"])
        try writeFile("session_index.jsonl", in: root, lines: [
            #"{"sessionId":"session_1111","sessionDir":"sessions/wd_proj/session_1111","workDir":"/tmp/proj"}"#,
            #"{"sessionId":"session_2222","sessionDir":"sessions/wd_proj/session_2222","workDir":"/tmp/proj"}"#
        ])
        try writeFile("state.json", in: root.appendingPathComponent("sessions/wd_proj/session_2222"), lines: [
            #"{"title":"keep","isCustomTitle":true}"#
        ])
        let record = try XCTUnwrap(AgentSessionScanner.collectKimi(root: root).first { $0.conversationId == "session_1111" })

        XCTAssertTrue(AgentSessionScanner.delete(record))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path))
        let remaining = String(decoding: try Data(contentsOf: root.appendingPathComponent("session_index.jsonl")), as: UTF8.self)
        XCTAssertFalse(remaining.contains("session_1111"))
        XCTAssertTrue(remaining.contains("session_2222"))
    }

    func testDeleteRemovesOpenCodeDependentRows() throws {
        let dbURL = tempDir.appendingPathComponent("delete-opencode-cascade.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let setup = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, time_updated INTEGER, time_archived INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT REFERENCES session(id) ON DELETE CASCADE, data TEXT);
        INSERT INTO session VALUES ('ses_a', NULL, '/tmp/proj', 'a', 2000000, NULL);
        INSERT INTO message VALUES ('msg_a', 'ses_a', 'private message');
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let record = try XCTUnwrap(AgentSessionScanner.collectOpencode(root: dbURL).first)
        XCTAssertTrue(AgentSessionScanner.delete(record))

        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
    }

    func testDeleteRemovesDroidAndReasonixSidecars() throws {
        let droid = tempDir.appendingPathComponent("delete-droid")
        let droidFile = try writeFile("session.jsonl", in: droid, lines: [
            #"{"type":"session_start","id":"droid-1","cwd":"/tmp/proj"}"#,
            #"{"type":"message","message":{"role":"user","content":"hi"}}"#
        ])
        let droidSidecar = try writeFile("session.settings.json", in: droid, lines: ["{}"])
        let droidRecord = try XCTUnwrap(AgentSessionScanner.droidRecord(file: droidFile, mtime: Date()))
        XCTAssertTrue(AgentSessionScanner.delete(droidRecord))
        XCTAssertFalse(FileManager.default.fileExists(atPath: droidFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: droidSidecar.path))

        let reasonix = tempDir.appendingPathComponent("delete-reasonix")
        let reasonixFile = try writeFile("session-1.jsonl", in: reasonix, lines: ["{}"])
        try writeFile("session-1.jsonl.meta", in: reasonix, lines: [
            #"{"schema_version":1,"workspace_root":"/tmp/proj","turns":1}"#
        ])
        let events = try writeFile("session-1.events.jsonl", in: reasonix, lines: ["private event"])
        let reasonixRecord = try XCTUnwrap(AgentSessionScanner.reasonixRecord(file: reasonixFile, mtime: Date()))
        XCTAssertTrue(AgentSessionScanner.delete(reasonixRecord))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reasonixFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reasonixFile.appendingPathExtension("meta").path))
    }

    func testDeleteRemovesDirectoryBackedSession() throws {
        // Cursor keeps one dir per chat; deleting must remove the whole
        // session dir while leaving sibling sessions under the same group.
        let root = tempDir.appendingPathComponent("delete-cursor")
        let group = root.appendingPathComponent("md5hash")
        let doomed = group.appendingPathComponent("33333333-3333-3333-3333-333333333333")
        let kept = group.appendingPathComponent("44444444-4444-4444-4444-444444444444")
        try writeFile("meta.json", in: doomed, lines: [
            #"{"cwd":"/tmp/proj","title":"doomed","hasConversation":true}"#,
        ])
        try writeFile("meta.json", in: kept, lines: [
            #"{"cwd":"/tmp/proj","title":"kept","hasConversation":true}"#,
        ])
        let record = try XCTUnwrap(AgentSessionScanner.collectCursor(root: root)
            .first { $0.conversationId == "33333333-3333-3333-3333-333333333333" })

        XCTAssertTrue(AgentSessionScanner.delete(record))

        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path),
                       "the deleted session's whole directory must be gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path),
                      "sibling sessions must survive")
        XCTAssertEqual(AgentSessionScanner.collectCursor(root: root).map(\.conversationId),
                       ["44444444-4444-4444-4444-444444444444"])
    }

    func testDeleteRemovesOnlyTheTargetSQLiteRow() throws {
        // OpenCode's store is one shared DB — deletion must remove exactly
        // the target session row and leave the database + other rows intact.
        let dbURL = tempDir.appendingPathComponent("delete-opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let setup = """
        CREATE TABLE session (id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_updated INTEGER, time_archived INTEGER);
        INSERT INTO session VALUES ('ses_a', NULL, '/tmp/proj', 'a', 2000000, NULL);
        INSERT INTO session VALUES ('ses_b', NULL, '/tmp/proj', 'b', 1000000, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let records = AgentSessionScanner.collectOpencode(root: dbURL)
        let doomed = try XCTUnwrap(records.first { $0.conversationId == "ses_a" })
        XCTAssertTrue(AgentSessionScanner.delete(doomed))

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                      "the database itself must survive")
        let remaining = AgentSessionScanner.collectOpencode(root: dbURL)
        XCTAssertEqual(remaining.map(\.conversationId), ["ses_b"],
                       "only the target row is deleted")
    }

    func testDeleteIsNoopForDefaultSentinelSource() throws {
        // Records built without a backing source (tests, or a store the
        // scanner doesn't yet map) default to the /dev/null sentinel —
        // delete must refuse to touch anything, not throw or wipe a path.
        let root = tempDir.appendingPathComponent("delete-sentinel")
        let keep = try writeFile("55555555-5555-5555-5555-555555555555.jsonl", in: root, lines: [
            claudeUserLine(text: "keep", cwd: "/tmp/proj"),
        ])
        let record = AgentSessionRecord(
            agentId: AgentTemplate.claudeCodeID,
            conversationId: "55555555-5555-5555-5555-555555555555",
            title: "keep",
            cwd: URL(fileURLWithPath: "/tmp/proj"),
            lastActivity: Date()
        )
        XCTAssertEqual(record.sourceURL.path, "/dev/null")

        XCTAssertFalse(AgentSessionScanner.delete(record),
                       "a sentinel record reports failure — nothing was deleted")

        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path),
                      "a sentinel record must never delete anything")
    }

    func testDeleteKiroRowByConversationID() throws {
        // Kiro keys rows by (cwd, conversation_id); deletion targets the
        // conversation id column so the right conversation goes even when
        // multiple rows share a cwd.
        let dbURL = tempDir.appendingPathComponent("delete-kiro.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let setup = """
        CREATE TABLE conversations_v2 (key TEXT, conversation_id TEXT, value TEXT, created_at INTEGER, updated_at INTEGER, PRIMARY KEY (key, conversation_id));
        INSERT INTO conversations_v2 VALUES ('/tmp/proj', 'kiro-1', '{}', 1000, 2000000);
        INSERT INTO conversations_v2 VALUES ('/tmp/proj', 'kiro-2', '{}', 1000, 1000000);
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let doomed = try XCTUnwrap(AgentSessionScanner.collectKiro(root: dbURL)
            .first { $0.conversationId == "kiro-1" })
        XCTAssertTrue(AgentSessionScanner.delete(doomed))

        let remaining = AgentSessionScanner.collectKiro(root: dbURL)
        XCTAssertEqual(remaining.map(\.conversationId), ["kiro-2"])
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
    }

    // MARK: Model-layer delete cache sync

    func testFirstMessageIsCachedAndClearedOnDelete() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-hover-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("proj")
        func makeRecord(_ id: String) throws -> AgentSessionRecord {
            let file = try SessionStoreFixtures.writeFile("\(UUID().uuidString).jsonl", in: project, lines: [
                #"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":"cached ask"}}"#,
            ])
            return AgentSessionRecord(
                agentId: AgentTemplate.claudeCodeID,
                conversationId: id,
                title: "cached ask",
                cwd: URL(fileURLWithPath: "/tmp/proj"),
                lastActivity: Date(),
                sourceURL: file
            )
        }
        let history = AgentSessionHistory(records: [])
        // Read 1 goes to disk; deleting the file proves read 2 is cached.
        let cachedRecord = try makeRecord("cached-1")
        let first = await history.firstMessage(for: cachedRecord)
        XCTAssertEqual(first, "cached ask")
        try FileManager.default.removeItem(at: cachedRecord.sourceURL)
        let cached = await history.firstMessage(for: cachedRecord)
        XCTAssertEqual(cached, "cached ask", "second read must hit the cache, not disk")
        // A record whose file still exists: delete clears its cached preview.
        let doomed = try makeRecord("cached-2")
        _ = await history.firstMessage(for: doomed)
        let deleted = await history.delete(doomed)
        XCTAssertTrue(deleted)
        XCTAssertNil(history.firstMessageCache[doomed.id], "delete must drop the cached preview")
        XCTAssertEqual(history.firstMessageCache[cachedRecord.id], "cached ask",
                       "other records' previews survive a sibling delete")
    }

    func testModelDeleteRemovesRecordFromCacheOnlyOnSuccess() async throws {
        // Disk delete succeeded → the record leaves the cache immediately.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-model-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try SessionStoreFixtures.writeFile("11111111-1111-1111-1111-111111111111.jsonl", in: dir, lines: [
            #"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":"hi"}}"#,
        ])
        let doomed = AgentSessionRecord(
            agentId: AgentTemplate.claudeCodeID,
            conversationId: "11111111-1111-1111-1111-111111111111",
            title: "doomed",
            cwd: URL(fileURLWithPath: "/tmp/proj"),
            lastActivity: Date(),
            sourceURL: file
        )
        let kept = AgentSessionRecord(
            agentId: AgentTemplate.codex.id,
            conversationId: "22222222-2222-2222-2222-222222222222",
            title: "kept",
            cwd: URL(fileURLWithPath: "/tmp/proj"),
            lastActivity: Date(),
            sourceURL: URL(fileURLWithPath: "/dev/null")
        )
        let history = AgentSessionHistory(records: [doomed, kept])

        let succeeded = await history.delete(doomed)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(history.records.map(\.id), [kept.id],
                       "the deleted record leaves the cache, the sibling stays")
        XCTAssertEqual(history.presentAgentIds, [kept.agentId])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testModelDeleteKeepsCacheWhenDiskDeleteFails() async {
        // A record whose backing file is already gone (or unwritable) must
        // NOT leave the cache — otherwise the row vanishes then reappears on
        // the next scan, and the sheet would claim success.
        let missing = AgentSessionRecord(
            agentId: AgentTemplate.claudeCodeID,
            conversationId: "33333333-3333-3333-3333-333333333333",
            title: "missing",
            cwd: URL(fileURLWithPath: "/tmp/proj"),
            lastActivity: Date(),
            sourceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("definitely-missing-\(UUID().uuidString).jsonl")
        )
        let history = AgentSessionHistory(records: [missing])

        let succeeded = await history.delete(missing)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(history.records.map(\.id), [missing.id],
                       "a failed disk delete must keep the cached record")
        XCTAssertEqual(history.presentAgentIds, [missing.agentId])
    }

    func testDeleteInvalidatesInFlightRefreshSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-refresh-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try SessionStoreFixtures.writeFile("44444444-4444-4444-4444-444444444444.jsonl", in: dir, lines: [
            #"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":"hi"}}"#
        ])
        let record = AgentSessionRecord(
            agentId: AgentTemplate.claudeCodeID,
            conversationId: "44444444-4444-4444-4444-444444444444",
            title: "stale",
            cwd: URL(fileURLWithPath: "/tmp/proj"),
            lastActivity: Date(),
            sourceURL: file
        )
        let gate = SessionScanGate(result: [record])
        let history = AgentSessionHistory(records: [record], scanProvider: gate.scan)
        history.refresh(force: true)
        await Task.yield()
        XCTAssertEqual(gate.started.wait(timeout: .now() + 1), .success)

        let deletion = Task { await history.delete(record) }
        gate.release.signal()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(history.records.contains { $0.id == record.id })
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
