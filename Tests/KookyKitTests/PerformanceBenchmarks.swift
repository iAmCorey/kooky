import SQLite3
import XCTest
@testable import KookyKit

/// Opt-in performance benchmarks — run via `scripts/bench.sh` (or
/// `KOOKY_BENCH=1 swift test -c release --filter PerformanceBenchmarks`).
/// Skipped in a normal `swift test` so the everyday suite stays fast.
///
/// The synthetic fixture is FIXED-SIZE and deterministic, so its numbers are
/// comparable run-over-run on the same machine — that is the regression
/// signal. The real-store number tracks the developer's actual data and is
/// context only (it grows as real usage grows; never assert on it).
final class PerformanceBenchmarks: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KOOKY_BENCH"] == "1",
            "benchmarks are opt-in — run scripts/bench.sh"
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func medianSeconds(of work: () -> Void) -> Double {
        // One warmup (page cache, lazy init), then median of 3.
        var samples: [Double] = []
        for run in 0..<4 {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            if run > 0 { samples.append(elapsed / .seconds(1)) }
        }
        return samples.sorted()[1]
    }

    /// `FileTreeLister.children` on flat directories at three scales. The
    /// file tree lists on the main actor today, so these numbers ARE the UI
    /// stall for expanding a directory of that size (performance round 2's
    /// "measure before moving it off-main"). Content is irrelevant — the
    /// cost is directory enumeration + per-entry resourceValues + the
    /// localized natural sort.
    func testFileTreeListingScales() throws {
        let fm = FileManager.default
        for count in [1_000, 10_000, 50_000] {
            let dir = tempDir.appendingPathComponent("flat-\(count)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<count {
                fm.createFile(
                    atPath: dir.appendingPathComponent("file-\(String(format: "%06d", i)).txt").path,
                    contents: nil
                )
            }
            let seconds = medianSeconds {
                _ = try? FileTreeLister.children(of: dir)
            }
            print("BENCH file-tree-list-\(count): \(Int(seconds * 1000)) ms")
        }
    }

    /// The session-history scan under a fixed synthetic load shaped like the
    /// real cost drivers: Claude and pi-style files whose heads are dominated
    /// by large message lines (the byte-marker-gate paths), Codex rollouts
    /// with an oversized session_meta first line (the in-head parse +
    /// bounded-fallback path), and an OpenCode SQLite store (the query
    /// path). 600 sessions total across 4 stores.
    func testSessionScanSyntheticFixedLoad() throws {
        let claudeRoot = tempDir.appendingPathComponent("claude")
        let codexRoot = tempDir.appendingPathComponent("codex")
        let piRoot = tempDir.appendingPathComponent("pi")
        let dbURL = tempDir.appendingPathComponent("opencode.db")

        let bigAssistantLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":""# + String(repeating: "a", count: 8_000) + #""}]}}"#
        let claudeDir = claudeRoot.appendingPathComponent("-tmp-proj")
        for i in 0..<150 {
            var lines = [#"{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":"synthetic prompt \#(i)"}}"#]
            lines.append(contentsOf: Array(repeating: bigAssistantLine, count: 8))
            lines.append(#"{"type":"custom-title","customTitle":"bench session \#(i)"}"#)
            try SessionStoreFixtures.writeFile("\(UUID().uuidString).jsonl", in: claudeDir, lines: lines)
        }

        let bigInstructions = String(repeating: "b", count: 160_000)
        let codexDir = codexRoot.appendingPathComponent("2026/07/27")
        for i in 0..<150 {
            try SessionStoreFixtures.writeFile("rollout-bench-\(i).jsonl", in: codexDir, lines: [
                #"{"type":"session_meta","payload":{"id":"bench-\#(i)","cwd":"/tmp/proj","base_instructions":"\#(bigInstructions)"}}"#,
                #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
                #"{"type":"event_msg","payload":{"type":"user_message","message":"synthetic ask \#(i)"}}"#,
            ])
        }

        let bigMessageLine = #"{"type":"message","id":"m","message":{"role":"assistant","content":[{"type":"text","text":""# + String(repeating: "c", count: 8_000) + #""}]}}"#
        let piDir = piRoot.appendingPathComponent("--tmp-proj--")
        for i in 0..<150 {
            var lines = [#"{"type":"session","version":3,"id":"pi-bench-\#(i)","cwd":"/tmp/proj"}"#]
            lines.append(#"{"type":"message","id":"u","message":{"role":"user","content":[{"type":"text","text":"pi ask \#(i)"}]}}"#)
            lines.append(contentsOf: Array(repeating: bigMessageLine, count: 8))
            lines.append(#"{"type":"session_info","name":"pi bench \#(i)"}"#)
            try SessionStoreFixtures.writeFile("2026-07-27T00-00-00_\(UUID().uuidString).jsonl", in: piDir, lines: lines)
        }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE session (id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_updated INTEGER, time_archived INTEGER)", nil, nil, nil)
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for i in 0..<150 {
            sqlite3_exec(db, "INSERT INTO session VALUES ('ses_\(i)', NULL, '/tmp/proj', 'bench \(i)', \(1_000_000 + i), NULL)", nil, nil, nil)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        sqlite3_close(db)

        let roots = SessionStoreFixtures.isolatedRoots(base: tempDir, overrides: [
            AgentTemplate.claudeCodeID: claudeRoot,
            AgentTemplate.codex.id: codexRoot,
            AgentTemplate.pi.id: piRoot,
            AgentTemplate.opencode.id: dbURL,
        ])
        var count = 0
        let median = medianSeconds { count = AgentSessionScanner.scan(roots: roots).count }
        XCTAssertEqual(count, 600, "all four synthetic stores at their per-agent cap")
        print("BENCH session-scan-synthetic: \(Int(median * 1000)) ms (600 fixed sessions across 4 stores)")
        // Catastrophic-regression guard only — 10x headroom so machine noise
        // never reddens it; trends live in bench-history.jsonl.
        XCTAssertLessThan(median, 5.0)
    }

    /// Context number: the scan over THIS machine's real stores — the one
    /// sanctioned real-store scan in the test target (read-only, env-gated;
    /// everything else goes through `SessionStoreFixtures.isolatedRoots`).
    /// Grows with real usage — recorded for perspective, never asserted.
    func testSessionScanRealStores() {
        var count = 0
        let median = medianSeconds { count = AgentSessionScanner.scanDefaultRoots().count }
        print("BENCH session-scan-real: \(Int(median * 1000)) ms (\(count) records, machine-dependent)")
    }

    /// Control-plane parser throughput under a deterministic 100k-frame load.
    /// The control reader parses off-main; this still catches accidental
    /// super-linear validation or allocation growth.
    func testRemoteProtocolParses100kFrames() {
        let lines = (1...100_000).map {
            "KRP/1\tEVENT\t\($0)\tcodex\trunning\t/srv/app\t0\t-\t-"
        }
        var parsed = 0
        let median = medianSeconds {
            parsed = lines.reduce(into: 0) { count, line in
                if case .success = RemoteRuntimeProtocol.parse(line: line) {
                    count += 1
                }
            }
        }
        XCTAssertEqual(parsed, 100_000)
        print("BENCH remote-protocol-parse-100k: \(Int(median * 1000)) ms")
        XCTAssertLessThan(median, 5.0)
    }

    /// Pure argv generation, including the final quoted-byte size gate.
    func testMoshCommandBuilderThroughput() throws {
        let configuration = try XCTUnwrap(MoshWorkspaceConfiguration(
            destination: "bench@example.test",
            udpPort: .range(60_000...60_100),
            prediction: .adaptive,
            serverPath: "/opt/mosh/bin/mosh-server",
            sshPort: 2_222,
            identityFile: "/tmp/bench key",
            networkTimeoutSeconds: 604_800
        ))
        let token = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var built = 0
        let median = medianSeconds {
            built = 0
            for _ in 0..<10_000 {
                if (try? MoshCommandBuilder.build(
                    configuration: configuration,
                    runtimeToken: token,
                    remoteAgentCommand: "codex --model benchmark"
                )) != nil {
                    built += 1
                }
            }
        }
        XCTAssertEqual(built, 10_000)
        print("BENCH mosh-command-builder-10k: \(Int(median * 1000)) ms")
        XCTAssertLessThan(median, 5.0)
    }

    /// Sequence dedupe is the hot path before UI state mutation.
    func testRemoteSequenceDedupeThroughput() {
        var accepted = 0
        let median = medianSeconds {
            var tracker = RemoteSequenceTracker()
            accepted = 0
            for sequence in 1...100_000 {
                if tracker.observe(UInt64(sequence)) == .next
                    || sequence == 1 {
                    accepted += 1
                }
                _ = tracker.observe(UInt64(sequence))
            }
        }
        XCTAssertEqual(accepted, 100_000)
        print("BENCH remote-sequence-dedupe-200k: \(Int(median * 1000)) ms")
        XCTAssertLessThan(median, 2.0)
    }

    /// Pipe reads can split frames at any byte. Feed a fixed stream in tiny,
    /// uneven chunks and assert that decoder memory/throughput remains linear.
    func testRemoteChunkedPipeDecodeThroughput() {
        let frameCount = 100_000
        let stream = Data((1...frameCount).map {
            "KRP/1\tEVENT\t\($0)\tcodex\trunning\t/srv/app\t0\t-\t-\n"
        }.joined().utf8)
        var decoded = 0
        let median = medianSeconds {
            var decoder = RemoteRuntimeStreamDecoder()
            decoded = 0
            var offset = 0
            var chunkIndex = 0
            let chunkSizes = [1, 7, 31, 257, 4_096]
            while offset < stream.count {
                let size = min(chunkSizes[chunkIndex % chunkSizes.count], stream.count - offset)
                let end = offset + size
                decoded += decoder.append(stream.subdata(in: offset..<end)).reduce(into: 0) {
                    if case .frame = $1 { $0 += 1 }
                }
                offset = end
                chunkIndex += 1
            }
            decoded += decoder.finish().reduce(into: 0) {
                if case .frame = $1 { $0 += 1 }
            }
        }
        XCTAssertEqual(decoded, frameCount)
        print("BENCH remote-chunked-decode-100k: \(Int(median * 1000)) ms")
        XCTAssertLessThan(median, 8.0)
    }

    /// A full agent-panel aggregation over 100 live sessions. This is the
    /// cross-window observable walk exercised by every panel refresh.
    @MainActor
    func testAgentMonitorWalks100Sessions() {
        let store = WorkspaceStore(
            persistence: InMemoryPersistence(),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { false }
        )
        guard let workspace = store.active else {
            return XCTFail("expected seed workspace")
        }
        workspace.activeSession?.agent = .codex
        for index in 1..<100 {
            let template: AgentTemplate = index.isMultiple(of: 2) ? .claudeCode : .codex
            _ = store.addTab(in: workspace, template: template)
        }
        let monitor = AgentMonitor()
        monitor.storesProvider = { [store] }

        var count = 0
        let median = medianSeconds { count = monitor.entries.count }
        XCTAssertEqual(count, 100)
        print("BENCH agent-monitor-walk-100: \(Int(median * 1_000_000)) us")
        XCTAssertLessThan(median, 1.0)
        store.terminate()
    }
}
