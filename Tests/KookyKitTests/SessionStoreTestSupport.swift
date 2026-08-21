import Foundation
@testable import KookyKit

/// The canonical zero-config test store: TestEngine (no libghostty/PTY),
/// in-memory persistence, no real settings reads. Third verbatim copy
/// (DeepLink / PaneTreeHost / CLIController) earned it the shared home —
/// a new WorkspaceStore injection seam lands here once, not per file.
@MainActor
func makeTestStore() -> WorkspaceStore {
    WorkspaceStore(
        persistence: InMemoryPersistence(),
        engineFactory: { TestEngine() },
        optionsProvider: { _ in nil },
        resumeProvider: { true }
    )
}

/// Shared fixture helpers for the session-store tests and benchmarks.
/// `isolatedRoots` is also the privacy guard with one home: a test scan must
/// NEVER touch the developer's real agent stores — every store gets an
/// explicit root, defaulting to a nonexistent dir that yields zero records.
/// (`PerformanceBenchmarks.testSessionScanRealStores` is the one sanctioned
/// exception, via the explicitly-named `scanDefaultRoots`.)
enum SessionStoreFixtures {
    @discardableResult
    static func writeFile(_ name: String, in dir: URL, lines: [String], mtime: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    static func isolatedRoots(base: URL, overrides: [String: URL] = [:]) -> [String: URL] {
        var roots = overrides
        for id in AgentSessionScanner.supportedAgentIds where roots[id] == nil {
            roots[id] = base.appendingPathComponent("empty-\(id)")
        }
        return roots
    }
}
