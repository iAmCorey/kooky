import XCTest
@testable import KookyKit

/// The invariant these all serve: a section's gate is true only when at least
/// one of its rows is. A gate that outlives its rows renders a heading with
/// nothing under it, which shipped once.
@MainActor
final class SessionInfoRulesTests: XCTestCase {
    private var store: WorkspaceStore!
    private var workspace: Workspace!
    private var session: Session!

    override func setUp() async throws {
        try await super.setUp()
        store = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() })
        workspace = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        session = store.addTab(in: workspace, template: .terminal)
    }

    // MARK: Terminal title

    /// Without a rename `Session.title` IS `terminalTitle`, so the row would
    /// repeat the identity line at the top of the page.
    func testTerminalTitleHiddenWhenItIsAlreadyTheSessionTitle() {
        session.terminalTitle = "vim README.md"
        XCTAssertEqual(session.title, "vim README.md", "precondition: title falls through")

        XCTAssertNil(SessionInfoRules.visibleTerminalTitle(session))
        XCTAssertFalse(
            SessionInfoRules.hasRuntimeInfo(session),
            "the gate must fall with its only row — this is the empty-heading bug"
        )
    }

    func testTerminalTitleShownOnceARenameHidesIt() {
        session.terminalTitle = "vim README.md"
        session.customTitle = "notes"

        XCTAssertEqual(SessionInfoRules.visibleTerminalTitle(session), "vim README.md")
        XCTAssertTrue(SessionInfoRules.hasRuntimeInfo(session))
    }

    func testBlankTerminalTitleIsNotARow() {
        session.terminalTitle = "   "
        session.customTitle = "notes"
        XCTAssertNil(SessionInfoRules.visibleTerminalTitle(session))
        XCTAssertFalse(SessionInfoRules.hasRuntimeInfo(session))
    }

    func testRuntimeSurvivesOnACompletedCommandAlone() {
        session.lastCompletedCommand = .init(text: "ls", exit: 0, duration: 0.1)
        XCTAssertTrue(SessionInfoRules.hasRuntimeInfo(session))
    }

    /// The red-dot pair is cleared on input; the inspector's gate must NOT
    /// read it, or the Runtime section vanishes on the first keystroke.
    func testRuntimeIgnoresTheClearedRedDotPair() {
        session.lastCompletedCommand = .init(text: "ls", exit: 0, duration: 0.1)
        session.lastCommandExit = nil
        session.lastCommandText = nil
        XCTAssertTrue(SessionInfoRules.hasRuntimeInfo(session))
    }

    // MARK: Repo root

    func testRepoRootHiddenWhenItIsTheCurrentDirectory() {
        session.currentDirectory = URL(fileURLWithPath: "/tmp/project")
        session.gitStatus = GitStatus(
            branch: nil, repoRoot: "/tmp/project", filesChanged: 0, insertions: 0, deletions: 0
        )

        XCTAssertNil(SessionInfoRules.visibleRepoRoot(session))
        XCTAssertFalse(
            SessionInfoRules.hasSourceInfo(session: session, isWorktree: false),
            "repo root alone, and it's the directory above — nothing left to show"
        )
    }

    /// Trailing slashes and `..` must not read as a different directory.
    func testRepoRootComparisonIsPathNormalised() {
        session.currentDirectory = URL(fileURLWithPath: "/tmp/project")
        session.gitStatus = GitStatus(
            branch: nil, repoRoot: "/tmp/sub/../project/", filesChanged: 0, insertions: 0, deletions: 0
        )
        XCTAssertNil(SessionInfoRules.visibleRepoRoot(session))
    }

    func testRepoRootShownFromASubdirectory() {
        session.currentDirectory = URL(fileURLWithPath: "/tmp/project/Sources")
        session.gitStatus = GitStatus(
            branch: "main", repoRoot: "/tmp/project", filesChanged: 0, insertions: 0, deletions: 0
        )

        XCTAssertEqual(SessionInfoRules.visibleRepoRoot(session), "/tmp/project")
        XCTAssertTrue(SessionInfoRules.hasSourceInfo(session: session, isWorktree: false))
    }

    func testSourceSurvivesOnBranchOrDiffOrWorktreeAlone() {
        session.gitStatus = GitStatus(
            branch: "main", repoRoot: nil, filesChanged: 0, insertions: 0, deletions: 0
        )
        XCTAssertTrue(SessionInfoRules.hasSourceInfo(session: session, isWorktree: false))

        session.gitStatus = GitStatus(
            branch: nil, repoRoot: nil, filesChanged: 2, insertions: 5, deletions: 1
        )
        XCTAssertTrue(SessionInfoRules.hasSourceInfo(session: session, isWorktree: false))

        session.gitStatus = .empty
        XCTAssertFalse(SessionInfoRules.hasSourceInfo(session: session, isWorktree: false))
        XCTAssertTrue(SessionInfoRules.hasSourceInfo(session: session, isWorktree: true))
    }

    // MARK: Helpers

    func testNonEmptyTrimsAndRejectsWhitespace() {
        XCTAssertEqual(SessionInfoRules.nonEmpty("  main  "), "main")
        XCTAssertNil(SessionInfoRules.nonEmpty("  \n "))
        XCTAssertNil(SessionInfoRules.nonEmpty(nil))
    }

    func testAbbreviatedPathUsesTilde() {
        let home = NSHomeDirectory()
        XCTAssertEqual(SessionInfoRules.abbreviatedPath("\(home)/Github"), "~/Github")
        XCTAssertEqual(SessionInfoRules.abbreviatedPath("/tmp/project"), "/tmp/project")
    }

    // MARK: Section titles

    /// The collapse keys ARE these strings on disk (state.json
    /// `collapsedInfoSections`) — locked wire format, the M5.bbbbb tag-keys
    /// lesson: reword a heading and every user's saved collapse state
    /// silently orphans. Rename only with a migration.
    func testInfoSectionTitlesAreALockedWireFormat() {
        XCTAssertEqual(SessionInfoRules.contextTitle, "Context")
        XCTAssertEqual(SessionInfoRules.sourceTitle, "Source")
        XCTAssertEqual(SessionInfoRules.environmentTitle, "Environment")
        XCTAssertEqual(SessionInfoRules.processesTitle, "Processes")
        XCTAssertEqual(SessionInfoRules.runtimeTitle, "Runtime")
    }

    // MARK: Process usage label

    /// Always show what was measured — a visibility threshold here made CPU
    /// pop in and out every poll for a process hovering around the bar.
    /// Quieting idle rows is the prominence tier's job, not visibility's.
    func testProcessUsageLabelShowsWhatWasMeasured() {
        XCTAssertNil(
            SessionInfoRules.processUsageLabel(cpuPercent: nil, residentMB: nil),
            "nothing readable (other-uid pid) is the only empty case"
        )
        XCTAssertEqual(SessionInfoRules.processUsageLabel(cpuPercent: 0, residentMB: 12), "0% · 12M")
        XCTAssertEqual(SessionInfoRules.processUsageLabel(cpuPercent: 3, residentMB: 30), "3% · 30M")
        XCTAssertEqual(
            SessionInfoRules.processUsageLabel(cpuPercent: nil, residentMB: 313), "313M",
            "first tick has no CPU window yet — memory alone, no placeholder percent"
        )
        XCTAssertEqual(SessionInfoRules.processUsageLabel(cpuPercent: 240, residentMB: 313), "240% · 313M")
    }

    /// The quiet mechanism: same numbers on every row, but only busy rows get
    /// the readable tier — this replaced a visibility threshold that made CPU
    /// blink in and out every poll for a process hovering around the bar.
    func testProcessUsageProminenceLandsOnBusyRows() {
        XCTAssertFalse(SessionInfoRules.processUsageIsProminent(cpuPercent: nil))
        XCTAssertFalse(SessionInfoRules.processUsageIsProminent(cpuPercent: 0))
        XCTAssertTrue(SessionInfoRules.processUsageIsProminent(cpuPercent: 1))
    }

    func testProcessUsageLabelFormatsGigabytes() {
        XCTAssertEqual(SessionInfoRules.processUsageLabel(cpuPercent: nil, residentMB: 1229), "1.2G")
        XCTAssertEqual(SessionInfoRules.processUsageLabel(cpuPercent: nil, residentMB: 1024), "1.0G")
        XCTAssertEqual(SessionInfoRules.processUsageLabel(cpuPercent: nil, residentMB: 1023), "1023M")
    }

    // MARK: Ask-fix

    func testAskFixOnlyOffersAFailedCommandWithText() {
        XCTAssertEqual(
            SessionInfoRules.askFixCommand(
                completed: .init(text: "npm test", exit: 1, duration: 2),
                sshWorkspaceHost: nil
            ),
            "npm test"
        )
        XCTAssertNil(
            SessionInfoRules.askFixCommand(
                completed: .init(text: "npm test", exit: 0, duration: 2),
                sshWorkspaceHost: nil
            ),
            "a succeeded command has nothing to fix"
        )
        XCTAssertNil(
            SessionInfoRules.askFixCommand(
                completed: .init(text: nil, exit: 1, duration: 2),
                sshWorkspaceHost: nil
            ),
            "no command text (bash / pre-marker) → the prompt can't say what failed"
        )
    }

    /// Not a delivery problem (the spawn path carries prompts to the remote
    /// fine) — a trust one: the prompt embeds the LOCAL cwd, which is
    /// meaningless to a fresh remote agent.
    func testAskFixHidesOnSSHWorkspaces() {
        XCTAssertNil(
            SessionInfoRules.askFixCommand(
                completed: .init(text: "npm test", exit: 1, duration: 2),
                sshWorkspaceHost: "devbox"
            )
        )
    }

    func testAskFixPromptCarriesCommandExitAndCwd() {
        let prompt = SessionInfoRules.askFixPrompt(
            command: "npm test", exit: 127, cwd: "/tmp/project"
        )
        XCTAssertTrue(prompt.contains("npm test"))
        XCTAssertTrue(prompt.contains("127"))
        XCTAssertTrue(prompt.contains("/tmp/project"))
    }
}
