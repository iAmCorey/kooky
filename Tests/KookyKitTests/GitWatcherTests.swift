import XCTest
@testable import KookyKit

final class GitWatcherTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kooky-gitwatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testFindGitDirReturnsNilOutsideRepo() {
        XCTAssertNil(GitWatcher.findGitDir(near: tempRoot))
    }

    func testFindGitDirReturnsDirectoryWhenGitIsADir() throws {
        let gitDir = tempRoot.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let result = GitWatcher.findGitDir(near: tempRoot)
        XCTAssertEqual(result?.standardizedFileURL, gitDir.standardizedFileURL)
    }

    func testFindGitDirWalksUpFromSubdirectory() throws {
        let gitDir = tempRoot.appendingPathComponent(".git", isDirectory: true)
        let nested = tempRoot.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let result = GitWatcher.findGitDir(near: nested)
        XCTAssertEqual(result?.standardizedFileURL, gitDir.standardizedFileURL)
    }

    func testFindGitDirResolvesWorktreeGitfile() throws {
        // Worktrees: `.git` is a file containing `gitdir: <abs-path>`.
        let realGit = tempRoot.appendingPathComponent("real-git", isDirectory: true)
        try FileManager.default.createDirectory(at: realGit, withIntermediateDirectories: true)
        let worktreeRoot = tempRoot.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let gitFile = worktreeRoot.appendingPathComponent(".git")
        try "gitdir: \(realGit.path)\n".write(to: gitFile, atomically: true, encoding: .utf8)

        let result = GitWatcher.findGitDir(near: worktreeRoot)
        XCTAssertEqual(result?.standardizedFileURL, realGit.standardizedFileURL)
    }

    func testFindGitDirResolvesRelativeGitfileAgainstCandidateParent() throws {
        // Submodule layout: `project/.git/modules/foo/` is the real gitdir,
        // and `project/foo/.git` is a file containing
        //   gitdir: ../.git/modules/foo
        // The relative path must resolve against the `.git` file's parent
        // (`project/foo/`), not the process working directory.
        let project = tempRoot.appendingPathComponent("project", isDirectory: true)
        let modulesFoo = project.appendingPathComponent(".git/modules/foo", isDirectory: true)
        try FileManager.default.createDirectory(at: modulesFoo, withIntermediateDirectories: true)
        let submoduleRoot = project.appendingPathComponent("foo", isDirectory: true)
        try FileManager.default.createDirectory(at: submoduleRoot, withIntermediateDirectories: true)
        let gitFile = submoduleRoot.appendingPathComponent(".git")
        try "gitdir: ../.git/modules/foo\n".write(to: gitFile, atomically: true, encoding: .utf8)

        let result = GitWatcher.findGitDir(near: submoduleRoot)
        XCTAssertEqual(result?.standardizedFileURL, modulesFoo.standardizedFileURL)
    }

    func testFindGitDirGivesUpOnUnparseableGitfile() throws {
        let worktreeRoot = tempRoot.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let gitFile = worktreeRoot.appendingPathComponent(".git")
        try "not a gitfile\n".write(to: gitFile, atomically: true, encoding: .utf8)

        XCTAssertNil(GitWatcher.findGitDir(near: worktreeRoot))
    }

    func testWorktreeRootReturnsNilForNonFileURL() {
        // The SSH group's sentinel is kooky-ssh://remote. Walking it never
        // reaches "/", so this must return without spinning.
        let sentinel = URL(string: "kooky-ssh://remote")!
        XCTAssertFalse(sentinel.isFileURL)
        XCTAssertNil(GitWatcher.worktreeRoot(near: sentinel))
        XCTAssertNil(GitWatcher.findGitDir(near: sentinel))
    }
}
