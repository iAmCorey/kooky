import SwiftUI
import XCTest
@testable import KookyKit

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/tmp/projectA")
    private let projectB = URL(fileURLWithPath: "/tmp/projectB")
    private let projectC = URL(fileURLWithPath: "/tmp/projectC")

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        for path in ["/tmp/projectA", "/tmp/projectA/sub", "/tmp/projectA/deep", "/tmp/projectB", "/tmp/projectC"] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private func makeStore(
        initial: PersistedState? = nil,
        persistence: InMemoryPersistence? = nil,
        noteRecentFolder: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> WorkspaceStore {
        WorkspaceStore(
            persistence: persistence ?? InMemoryPersistence(initial: initial),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true },
            noteRecentFolder: noteRecentFolder
        )
    }

    /// Two independent stores wired as each other's peers — models two kooky
    /// windows for cross-window tab-drag tests.
    private func makeWindowPair() -> (WorkspaceStore, WorkspaceStore) {
        // `peers` reads `stores` lazily — both inits run (neither invokes
        // `peerStores`) before the array is backfilled on the line below.
        var stores: [WorkspaceStore] = []
        let peers: @MainActor () -> [WorkspaceStore] = { stores }
        let a = WorkspaceStore(
            persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { true }, peerStores: peers
        )
        let b = WorkspaceStore(
            persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { true }, peerStores: peers
        )
        stores = [a, b]
        return (a, b)
    }

    private func engine(_ session: Session) -> TestEngine {
        guard let e = session.engine as? TestEngine else { preconditionFailure("expected TestEngine") }
        return e
    }

    private func firstPane(_ ws: Workspace) -> Pane {
        guard let pane = ws.root.firstPane else { preconditionFailure("expected at least one pane") }
        return pane
    }

    func testRequestRenameActiveTabSetsFlag() {
        let store = makeStore()
        XCTAssertEqual(store.active?.activeSession?.renameRequested, false)
        store.requestRenameActiveTab()
        XCTAssertEqual(store.active?.activeSession?.renameRequested, true)
    }

    func testRequestRenameActiveWorkspaceParksRequest() {
        let store = makeStore()
        XCTAssertNil(store.pendingRenameWorkspace)
        store.requestRenameActiveWorkspace()
        XCTAssertEqual(store.pendingRenameWorkspace?.id, store.active?.id)
    }

    func testRequestRenameActiveWorkspaceRevealsHiddenSidebar() {
        let store = makeStore()
        store.setSidebarMode(.hidden)
        store.requestRenameActiveWorkspace()
        XCTAssertEqual(store.sidebarMode, .full)
        XCTAssertEqual(store.pendingRenameWorkspace?.id, store.active?.id)
    }

    func testInitialStateHasOneWorkspaceWithOnePaneAndOneTab() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.count, 1)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(firstPane(ws).tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, ws.id)
    }

    func testFirstWorkspaceUsesHomeDirectory() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.first?.workingDirectory.path, NSHomeDirectory())
        XCTAssertEqual(store.workspaces.first?.title, "Home")
    }

    func testAddWorkspaceCreatesNewWorkspaceAndActivatesIt() {
        let store = makeStore()
        let first = store.workspaces[0]
        let second = store.addWorkspace(workingDirectory: projectA)
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(second.root.allPanes.count, 1)
        XCTAssertEqual(firstPane(second).tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, second.id)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testAddWorkspaceTitleDefaultsToLastPathComponent() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/sample-project"))
        XCTAssertEqual(ws.title, "sample-project")
    }

    func testAddWorkspaceWithWorktreeParentSetsRelationship() {
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-feat-x"),
            worktreeParent: source,
            worktreeBranch: "feat-x"
        )
        XCTAssertEqual(wt.worktreeParentId, source.id)
        XCTAssertEqual(wt.worktreeBranch, "feat-x")
    }

    func testWorktreeWorkspaceTitleUsesCwdBasename() {
        // Title falls through to the cwd basename like any other workspace
        // — branch identity now lives in the sidebar row's subtitle
        // (`⎇ <branch>`), so the title doesn't need to carry it too.
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-feat-y"),
            worktreeParent: source,
            worktreeBranch: "feat-y"
        )
        XCTAssertEqual(wt.title, "projectA-feat-y")
    }

    func testAddWorkspaceWithCustomTemplateSpawnsThatAgent() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA, template: .claudeCode)
        XCTAssertEqual(firstPane(ws).tabs.first?.agent.id, AgentTemplate.claudeCode.id)
    }

    func testRequestCloseWorkspaceClosesPlainWorkspaceImmediately() {
        let store = makeStore()
        let plain = store.addWorkspace(workingDirectory: projectA)
        XCTAssertTrue(store.workspaces.contains { $0.id == plain.id })
        store.requestCloseWorkspace(plain)
        XCTAssertFalse(store.workspaces.contains { $0.id == plain.id })
        XCTAssertNil(store.pendingRemovalRequest)
    }

    func testRequestCloseWorkspaceParksWorktreeForConfirmation() {
        // worktree workspaces must surface in `pendingRemovalRequest` so
        // the sidebar's confirm sheet can intercept — the close itself
        // does NOT happen until the sheet's `confirm` action runs.
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-feat-x"),
            worktreeParent: source,
            worktreeBranch: "feat-x"
        )
        store.requestCloseWorkspace(wt)
        XCTAssertTrue(store.workspaces.contains { $0.id == wt.id },
                      "worktree workspace must remain until the sheet confirms")
        XCTAssertEqual(store.pendingRemovalRequest?.id, wt.id)
    }

    func testCloseOtherWorkspacesKeepsWorktreeFamilyIntact() {
        // Repro of the "close-other on a worktree row strands the family"
        // bug: closing siblings while keeping a worktree must also retain
        // its source workspace — otherwise the sidebar's parent-id lookup
        // can't render the orphaned worktree.
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-wt"),
            worktreeParent: source, worktreeBranch: "feat"
        )
        let unrelated = store.addWorkspace(workingDirectory: projectB)

        store.closeOtherWorkspaces(keeping: wt)
        let ids = store.workspaces.map(\.id)
        XCTAssertTrue(ids.contains(wt.id))
        XCTAssertTrue(ids.contains(source.id), "source must stay so the worktree has a parent to nest under")
        XCTAssertFalse(ids.contains(unrelated.id))
    }

    func testCreateWorktreeAdoptKindAddsOneWorkspacePerPickedPath() async {
        // v0.19.0 "Create Worktree → adopt existing worktree" path —
        // sheet emits Request(.adopt(...)), store materializes one
        // workspace per picked Info without running git.
        let store = makeStore()
        let source = store.workspaces[0]
        let before = store.workspaces.count
        let picked: [WorktreeManager.Info] = [
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/adopt-a"), branch: "feat-a"),
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/adopt-b"), branch: "feat-b"),
        ]
        let request = CreateWorktreeSheet.Request(
            kind: .adopt(worktrees: picked),
            template: .terminal
        )
        let outcome = await store.createWorktree(source: source, request: request)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(store.workspaces.count, before + 2)
        let adopted = store.workspaces.filter { $0.worktreeParentId == source.id }
        XCTAssertEqual(adopted.count, 2)
        XCTAssertEqual(adopted.map(\.worktreeBranch).compactMap { $0 }.sorted(), ["feat-a", "feat-b"])
    }

    func testReconcileDoesNotAdoptDiskOnlyOrphans() {
        // v0.19.0 reverses v0.18.x: a worktree the user `git worktree add`-ed
        // in a shell stays out of the sidebar until they explicitly adopt it
        // via Create Worktree → adopt existing. The motivating user feedback:
        // "auto-adopted entries are noise I can't easily dismiss."
        let store = makeStore()
        let source = store.workspaces[0]
        XCTAssertTrue(store.workspaces.filter { $0.worktreeParentId == source.id }.isEmpty)
        store.reconcile(source: source, diskWorktrees: [
            WorktreeManager.Info(path: source.workingDirectory, branch: "main"),
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/source-feat-x"), branch: "feat-x")
        ])
        XCTAssertTrue(
            store.workspaces.filter { $0.worktreeParentId == source.id }.isEmpty,
            "reconcile must not auto-adopt disk-only worktrees in v0.19.0"
        )
    }

    func testReconcileClosesSidebarOnlyZombies() {
        // The user `git worktree remove`-d it in a shell — kooky's row
        // is now a zombie. Disk is truth, drop the row.
        let store = makeStore()
        let source = store.workspaces[0]
        _ = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/source-stale"),
            worktreeParent: source, worktreeBranch: "stale"
        )
        XCTAssertEqual(store.workspaces.filter { $0.worktreeParentId == source.id }.count, 1)
        store.reconcile(source: source, diskWorktrees: [
            WorktreeManager.Info(path: source.workingDirectory, branch: "main")
        ])
        XCTAssertTrue(store.workspaces.filter { $0.worktreeParentId == source.id }.isEmpty)
    }

    func testWorktreePathIsPinnedAndIndependentOfWorkingDirectoryDrift() {
        // Repro of the "not a working tree" bug: tab cd's off the worktree,
        // workingDirectory drifts via OSC 7, but worktreePath stays pinned
        // to the disk root that `git worktree add` produced.
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-feat"),
            worktreeParent: source, worktreeBranch: "feat"
        )
        XCTAssertEqual(wt.worktreePath?.path, "/tmp/projectA-feat")
        // Simulate OSC 7 cd to a sibling.
        wt.workingDirectory = URL(fileURLWithPath: "/tmp/elsewhere")
        XCTAssertEqual(wt.worktreePath?.path, "/tmp/projectA-feat",
                       "worktreePath must not drift with workingDirectory")
    }

    func testReconcileMatchesByWorktreePathNotWorkingDirectory() {
        // A worktree whose cwd drifted off the disk root should still
        // match its disk satellite — reconcile must key on worktreePath,
        // not the drifted workingDirectory, otherwise the user's tab
        // gets killed every relaunch.
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-feat"),
            worktreeParent: source, worktreeBranch: "feat"
        )
        wt.workingDirectory = URL(fileURLWithPath: "/tmp/elsewhere")  // cd drift
        store.reconcile(source: source, diskWorktrees: [
            WorktreeManager.Info(path: source.workingDirectory, branch: "main"),
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/projectA-feat"), branch: "feat")
        ])
        XCTAssertTrue(store.workspaces.contains { $0.id == wt.id },
                      "drifted-cwd worktree must not be treated as a zombie")
    }

    func testReconcileUsesStableSourceRootForExistingWorktreeZombieCheck() {
        // v0.19.0 no longer adopts disk-only entries, but zombie cleanup
        // still needs the stable source root: a worktree workspace whose
        // disk dir is gone (`/tmp/projectA-feat` removed) gets dropped,
        // while one whose disk dir is still present (matching by
        // worktreePath, not the drifted source cwd) survives.
        let store = makeStore()
        let source = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/projectA/sub"))
        let stillThere = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-feat"),
            worktreeParent: source, worktreeBranch: "feat"
        )
        _ = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-zombie"),
            worktreeParent: source, worktreeBranch: "zombie"
        )

        store.reconcile(source: source, sourceRoot: projectA, diskWorktrees: [
            WorktreeManager.Info(path: projectA, branch: "main"),
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/projectA-feat"), branch: "feat")
        ])

        let surviving = store.workspaces.filter { $0.worktreeParentId == source.id }
        XCTAssertEqual(surviving.count, 1)
        XCTAssertEqual(surviving.first?.id, stillThere.id,
                       "matched-disk worktree survives; missing-from-disk one drops")
    }

    func testReconcileLeavesMatchedPairsUntouched() {
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/source-feat"),
            worktreeParent: source, worktreeBranch: "feat"
        )
        store.reconcile(source: source, diskWorktrees: [
            WorktreeManager.Info(path: source.workingDirectory, branch: "main"),
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/source-feat"), branch: "feat")
        ])
        let after = store.workspaces.filter { $0.worktreeParentId == source.id }
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, wt.id, "matched pair must keep its original id")
    }

    func testRequestCloseSourceWithWorktreesParksForConfirm() {
        // Closing a top-level workspace that owns worktrees would either
        // strand them as orphan rows or vanish them silently. Either way
        // is wrong — the request parks in `pendingCloseSourceRequest` so
        // the sheet can ask about deleting all of them in one shot.
        let store = makeStore()
        let source = store.addWorkspace(workingDirectory: projectA)
        let wtA = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-a"),
            worktreeParent: source, worktreeBranch: "a"
        )
        let wtB = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-b"),
            worktreeParent: source, worktreeBranch: "b"
        )
        store.requestCloseWorkspace(source)
        XCTAssertTrue(store.workspaces.contains { $0.id == source.id },
                      "source must stay until the sheet confirms")
        let req = store.pendingCloseSourceRequest
        XCTAssertEqual(req?.source.id, source.id)
        XCTAssertEqual(Set(req?.worktrees.map(\.id) ?? []), Set([wtA.id, wtB.id]))
    }

    func testRequestCloseSourceWithoutWorktreesClosesInline() {
        // A top-level workspace with no worktree children still closes
        // immediately — only the worktree-owning case needs the sheet.
        let store = makeStore()
        let solo = store.addWorkspace(workingDirectory: projectB)
        store.requestCloseWorkspace(solo)
        XCTAssertFalse(store.workspaces.contains { $0.id == solo.id })
        XCTAssertNil(store.pendingCloseSourceRequest)
    }

    func testPerformCloseSourceAlsoDeleteFalseSkipsGitRemoveEntirely() async {
        // v0.19.0 default — close drops sidebar entries only, never
        // touches disk. The fake worktree path used in the failure test
        // would normally bomb on `git worktree remove`; with alsoDelete
        // false, we skip the subprocess entirely so the close succeeds.
        let store = makeStore()
        let source = store.addWorkspace(workingDirectory: projectA)
        let fakePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-fake-wt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakePath) }
        let wt = store.addWorkspace(
            workingDirectory: fakePath,
            worktreeParent: source, worktreeBranch: "feat"
        )
        let request = WorkspaceStore.CloseSourceRequest(source: source, worktrees: [wt])
        let message = await store.performCloseSource(request, alsoDelete: false)
        XCTAssertNil(message, "no git invocation means no error to surface")
        XCTAssertFalse(store.workspaces.contains { $0.id == source.id })
        XCTAssertFalse(store.workspaces.contains { $0.id == wt.id })
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fakePath.path),
            "disk dir must survive alsoDelete=false close"
        )
        XCTAssertNil(store.pendingCloseSourceRequest)
    }

    func testPerformCloseSourceAbortsWhenGitRemoveFails() async {
        // A fake existing directory that is not a git worktree causes
        // `git worktree remove` to fail; abort means source + worktrees
        // stay (sidebar = disk preserved).
        let store = makeStore()
        let source = store.addWorkspace(workingDirectory: projectA)
        let fakePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-fake-wt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakePath) }
        let wt = store.addWorkspace(
            workingDirectory: fakePath,
            worktreeParent: source, worktreeBranch: "feat"
        )
        let request = WorkspaceStore.CloseSourceRequest(source: source, worktrees: [wt])
        let message = await store.performCloseSource(request, alsoDelete: true)
        XCTAssertNotNil(message, "git remove must fail on fake worktree path")
        XCTAssertTrue(store.workspaces.contains { $0.id == source.id })
        XCTAssertTrue(store.workspaces.contains { $0.id == wt.id })
    }

    func testCloseLastTabOfWorktreeRoutesThroughConfirmInsteadOfCascading() {
        // The default cascade is closeTab → detachSession → closePane →
        // closeWorkspace, which skips the worktree confirm sheet. The
        // intercept should park the workspace in `pendingRemovalRequest`
        // and leave the tab in place so the sheet's cancel can roll back.
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-feat-x"),
            worktreeParent: source, worktreeBranch: "feat-x"
        )
        let onlyTab = firstPane(wt).tabs[0]
        store.closeTab(onlyTab, in: wt)
        XCTAssertTrue(store.workspaces.contains { $0.id == wt.id },
                      "worktree workspace must survive until the sheet confirms")
        XCTAssertEqual(firstPane(wt).tabs.count, 1, "tab must stay in place")
        XCTAssertEqual(store.pendingRemovalRequest?.id, wt.id)
    }

    func testCloseOtherWithoutWorktreesRunsInline() {
        // No worktrees in `others` → close runs immediately, no sheet.
        let store = makeStore()
        let kept = store.workspaces[0]
        _ = store.addWorkspace(workingDirectory: projectA)
        _ = store.addWorkspace(workingDirectory: projectB)
        store.closeOtherWorkspaces(keeping: kept)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces.first?.id, kept.id)
        XCTAssertNil(store.pendingCloseOthersRequest)
    }

    func testCloseOtherWithWorktreesParksForConfirmSheet() {
        // Any worktree in `others` → park the request and let the sheet
        // ask about the directories. No workspace closes until the sheet
        // calls performCloseOthers.
        let store = makeStore()
        let kept = store.workspaces[0]
        let other = store.addWorkspace(workingDirectory: projectA)
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-wt"),
            worktreeParent: other, worktreeBranch: "feat"
        )
        store.closeOtherWorkspaces(keeping: kept)
        XCTAssertEqual(store.workspaces.count, 3, "nothing closed yet, awaiting sheet")
        let req = store.pendingCloseOthersRequest
        XCTAssertEqual(req?.keeping.id, kept.id)
        XCTAssertEqual(req?.worktreeOthers.count, 1)
        XCTAssertEqual(req?.worktreeOthers.first?.id, wt.id)
    }

    func testPerformCloseOthersClosesPlainWorkspacesWhenNoWorktrees() async {
        // sidebar = disk: bulk close always tries `git worktree remove`
        // for every worktree in the request. If there are no worktrees in
        // `others`, no git is invoked — pure close path.
        let store = makeStore()
        let kept = store.workspaces[0]
        let p1 = store.addWorkspace(workingDirectory: projectA)
        let p2 = store.addWorkspace(workingDirectory: projectB)
        let request = WorkspaceStore.BulkRemovalRequest(keeping: kept, others: [p1, p2])
        let message = await store.performCloseOthers(request, alsoDelete: false)
        XCTAssertNil(message)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces.first?.id, kept.id)
        XCTAssertNil(store.pendingCloseOthersRequest)
    }

    func testPerformCloseOthersAbortsWhenGitRemoveFails() async {
        // An existing plain directory is not a git worktree, so `git
        // worktree remove` bombs. Abort means no workspace closes —
        // sidebar = disk holds.
        let store = makeStore()
        let kept = store.workspaces[0]
        let other = store.addWorkspace(workingDirectory: projectA)
        let fakePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-fake-wt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakePath) }
        let wt = store.addWorkspace(
            workingDirectory: fakePath,
            worktreeParent: other, worktreeBranch: "feat"
        )
        let request = WorkspaceStore.BulkRemovalRequest(keeping: kept, others: [other, wt])
        let message = await store.performCloseOthers(request, alsoDelete: true)
        XCTAssertNotNil(message, "git remove must fail on fake worktree path")
        XCTAssertTrue(store.workspaces.contains { $0.id == other.id })
        XCTAssertTrue(store.workspaces.contains { $0.id == wt.id })
    }

    func testCloseOtherWorkspacesKeepsAllWorktreesUnderKeptSource() {
        // Symmetric case: closing others while keeping a source workspace
        // should also keep every worktree hanging off it — otherwise the
        // sidebar tree degenerates into a bunch of useless empty parents.
        let store = makeStore()
        let source = store.workspaces[0]
        let wtA = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-a"),
            worktreeParent: source, worktreeBranch: "a"
        )
        let wtB = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-b"),
            worktreeParent: source, worktreeBranch: "b"
        )
        let unrelated = store.addWorkspace(workingDirectory: projectB)

        store.closeOtherWorkspaces(keeping: source)
        let ids = store.workspaces.map(\.id)
        XCTAssertTrue(ids.contains(source.id))
        XCTAssertTrue(ids.contains(wtA.id))
        XCTAssertTrue(ids.contains(wtB.id))
        XCTAssertFalse(ids.contains(unrelated.id))
    }

    func testMoveWorkspaceMovesWorktreeFamilyTogether() {
        // Compact mode renders store.workspaces directly, so source + child
        // worktrees must remain contiguous after a drag reorder.
        let store = makeStore()
        let home = store.workspaces[0]
        let source = store.addWorkspace(workingDirectory: projectA)
        let wtA = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-a"),
            worktreeParent: source, worktreeBranch: "a"
        )
        let wtB = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/projectA-b"),
            worktreeParent: source, worktreeBranch: "b"
        )
        let unrelated = store.addWorkspace(workingDirectory: projectB)

        let from = store.workspaces.firstIndex { $0.id == source.id }!
        let to = store.workspaces.firstIndex { $0.id == unrelated.id }!
        store.moveWorkspace(from: from, to: to)

        XCTAssertEqual(store.workspaces.map(\.id), [
            home.id, unrelated.id, source.id, wtA.id, wtB.id
        ])
    }

    func testRemoveWorktreeDirectoryAllowsAlreadyGoneOrphanToClose() async {
        // Defensive sidebar fallback can surface a worktree whose parent no
        // longer exists. If its directory is also gone, there is nothing left
        // to delete; the confirm path should let the row close.
        let store = makeStore()
        let source = store.workspaces[0]
        let wt = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/kooky-missing-worktree-\(UUID().uuidString)"),
            worktreeParent: source,
            worktreeBranch: "gone"
        )
        wt.worktreeParentId = UUID()

        let message = await store.removeWorktreeDirectory(wt)

        XCTAssertNil(message)
    }

    func testAddTabAppendsToActivePaneAndStartsEngine() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let session = store.addTab(in: ws, template: .terminal)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTabId, session.id)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, projectA.path)
    }

    func testActiveTabPwdReportSyncsToWorkspace() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let session = pane.tabs[0]
        engine(session).emitPwd("/tmp/projectA/sub")
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA/sub")
    }

    func testCommandFinishedUpdatesSessionStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]
        XCTAssertNil(session.lastCommandExit)
        XCTAssertNil(session.lastCommandDuration)
        engine(session).emitCommandFinished(exit: 1, duration: 0.42)
        XCTAssertEqual(session.lastCommandExit, 1)
        XCTAssertEqual(session.lastCommandDuration, 0.42)
        // Subsequent zero-exit overwrites the failure (so the dot disappears
        // when the next command succeeds, instead of sticking forever).
        engine(session).emitCommandFinished(exit: 0, duration: 0.05)
        XCTAssertEqual(session.lastCommandExit, 0)
    }

    func testTerminalTitleReportUpdatesTabAndWorkspaceName() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        // An `ssh` remote shell emits its own OSC 0/2 title.
        engine(session).emitTitle("corey@web-prod: ~/srv")

        XCTAssertEqual(session.title, "corey@web-prod: ~/srv")
        XCTAssertEqual(ws.title, "corey@web-prod: ~/srv")
    }

    func testAgentStatusTitleMarkerSurfacesRemoteAgentWithoutChangingLaunchTemplate() {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(
            persistence: persistence,
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
        )
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle(AgentStatusMarker.title(slug: "claude", event: .running))

        XCTAssertEqual(session.agent.id, AgentTemplate.terminal.id)
        XCTAssertEqual(session.displayAgent.id, AgentTemplate.claudeCode.id)
        XCTAssertEqual(session.activityState, .running)
        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(ws.distinctAgents.map(\.id), [AgentTemplate.claudeCode.id])

        store.flushPersistence()
        guard case .pane(let persistedPane)? = persistence.saved?.workspaces.last?.root.kind else {
            return XCTFail("expected single-pane persisted workspace")
        }
        XCTAssertEqual(persistedPane.tabs.first?.agentId, AgentTemplate.terminal.id)

        engine(session).emitTitle(AgentStatusMarker.title(slug: "claude", event: .ended))

        XCTAssertNil(session.transientAgent)
        XCTAssertEqual(session.displayAgent.id, AgentTemplate.terminal.id)
        XCTAssertEqual(session.activityState, .idle)
        XCTAssertTrue(ws.distinctAgents.isEmpty)
    }

    func testAgentStatusTitleMarkerDoesNotReplaceRemoteShellTitle() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("corey@web-prod: ~/srv")
        engine(session).emitTitle(AgentStatusMarker.title(slug: "codex", event: .running))

        XCTAssertEqual(session.terminalTitle, "corey@web-prod: ~/srv")
        XCTAssertEqual(session.title, "corey@web-prod: ~/srv")
        XCTAssertEqual(session.displayAgent.id, AgentTemplate.codex.id)
        XCTAssertEqual(ws.distinctAgents.map(\.id), [AgentTemplate.codex.id])
    }

    func testUnknownAgentStatusMarkerIsIgnoredInsteadOfBecomingTitle() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("kooky-agent:not-real:running")

        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.displayAgent.id, AgentTemplate.terminal.id)
        XCTAssertTrue(ws.distinctAgents.isEmpty)
    }

    func testAgentStatusEndedRevertsPromotedAgentEvenWhenTransientMarkerExists() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle(AgentStatusMarker.title(slug: "claude", event: .running))
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        engine(session).emitTitle(AgentStatusMarker.title(slug: "claude", event: .ended))

        XCTAssertNil(session.transientAgent)
        XCTAssertEqual(session.agent.id, AgentTemplate.terminal.id)
        XCTAssertEqual(session.displayAgent.id, AgentTemplate.terminal.id)
    }

    func testTransientAgentClearedWhenLocalCommandFinishes() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        // A remote agent surfaces via an OSC marker (ssh session running codex).
        engine(session).emitTitle(AgentStatusMarker.title(slug: "codex", event: .running))
        XCTAssertEqual(session.displayAgent.id, AgentTemplate.codex.id)
        XCTAssertEqual(session.activityState, .running)

        // The ssh drops with no `ended` marker — the local command (the ssh
        // itself) returning to the prompt is the fallback "remote session over"
        // signal, and must clear the stale transient promotion + activity dot.
        engine(session).emitCommandFinished(exit: 0, duration: 1)

        XCTAssertNil(session.transientAgent)
        XCTAssertEqual(session.displayAgent.id, AgentTemplate.terminal.id)
        XCTAssertEqual(session.activityState, .idle)
        XCTAssertTrue(ws.distinctAgents.isEmpty)
    }

    func testTerminalTitleBurstCoalescesToTrailingValue() async throws {
        // #51: a TUI re-emitting OSC 2 at output speed must not land one
        // SwiftUI invalidation per chunk. Leading edge is synchronous; the
        // burst parks and ONLY the final value lands at the window's tail.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("pi — 37 tokens")
        XCTAssertEqual(session.terminalTitle, "pi — 37 tokens")

        engine(session).emitTitle("pi — 74 tokens")
        engine(session).emitTitle("pi — 111 tokens")
        XCTAssertEqual(
            session.terminalTitle, "pi — 37 tokens",
            "burst writes inside the throttle window must park, not apply"
        )

        try await Task.sleep(for: Session.terminalTitleThrottle * 2)
        XCTAssertEqual(
            session.terminalTitle, "pi — 111 tokens",
            "the trailing flush must land the LAST parked value"
        )
    }

    func testTerminalTitleAppliesImmediatelyAfterQuietGap() async throws {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("first")
        XCTAssertEqual(session.terminalTitle, "first")

        try await Task.sleep(for: Session.terminalTitleThrottle * 2)
        engine(session).emitTitle("second")
        XCTAssertEqual(
            session.terminalTitle, "second",
            "a write after a quiet gap is a fresh leading edge — no deferral"
        )
    }

    func testCustomTitleWinsOverTerminalTitle() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("corey@web-prod")
        store.renameTab(session, to: "deploy")

        XCTAssertEqual(session.title, "deploy")
    }

    func testCommandFinishedKeepsTerminalTitle() {
        // P2 regression: a shell theme's `precmd` title hook sets the title
        // just before kooky's OSC 133;D fires (kooky's 133 hook runs last in
        // `precmd_functions`). Clearing on command-finished would wipe that
        // fresh title — so `onCommandFinished` must leave `terminalTitle`
        // alone. Stale titles are reset by the wrapper's per-prompt
        // `_kooky_title_pwd`, not here.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("corey@web-prod")
        engine(session).emitCommandFinished(exit: 0, duration: 0.1)

        XCTAssertEqual(session.terminalTitle, "corey@web-prod")
        XCTAssertEqual(session.title, "corey@web-prod")
    }

    func testEmptyTerminalTitleReportFallsBackToCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        engine(session).emitTitle("   ")

        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.title, "projectA")
    }

    func testBareCwdPathTitleIsIgnoredSoTabKeepsBasename() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        // libghostty derives a SET_TITLE that's just the absolute cwd path.
        // The tab must keep showing the basename, not `/tmp/projectA`.
        engine(session).emitTitle("/tmp/projectA")
        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.title, "projectA")

        // A `~`-abbreviated path is the same noise.
        engine(session).emitTitle("~/tmp/projectA")
        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.title, "projectA")
    }

    func testShellEnvironmentReportUpdatesSessionEnvironment() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]

        store.applyShellEnvironment([
            "VIRTUAL_ENV": "/tmp/projectA/.venv",
            "CONDA_DEFAULT_ENV": "",
            "NVM_BIN": "/Users/corey/.nvm/versions/node/v22.3.0/bin",
            "NVM_DIR": "/Users/corey/.nvm",
            "KOOKY_NODE_VERSION": "v22.3.0",
        ], sessionId: session.id)

        XCTAssertEqual(session.environment.pythonVenv, ".venv")
        XCTAssertEqual(session.environment.nodeVersion, "v22.3.0")
        XCTAssertEqual(session.environment.nvmDirectory, "/Users/corey/.nvm")
    }

    func testWorkspaceFailureAggregatesAcrossPanes() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        // Failure-bearing tab must live in a different pane from the active
        // one to verify the DFS picks it up regardless of focus.
        store.splitPane(pane, orientation: .horizontal, in: ws)
        let firstTab = pane.tabs[0]
        let secondPaneTab = ws.root.allPanes.last!.tabs[0]
        XCTAssertFalse(ws.hasCommandFailure)
        engine(secondPaneTab).emitCommandFinished(exit: 1, duration: 0.1)
        XCTAssertTrue(ws.hasCommandFailure)
        engine(secondPaneTab).emitCommandFinished(exit: 0, duration: 0.1)
        XCTAssertFalse(ws.hasCommandFailure)
        engine(firstTab).emitCommandFinished(exit: 2, duration: 0.1)
        XCTAssertTrue(ws.hasCommandFailure)
    }

    func testSwitchingWorkspacesPreservesActivePane() {
        // Issue #24: switching away from a split workspace and back must keep
        // the pane you left focused, not jump to the last one. The store is the
        // foundation — `activateWorkspace` must never reset `activePaneId`;
        // `PaneTreeHostView.syncFocus` then hands the keyboard to exactly that
        // pane's terminal (a switch re-mounts nothing in the C2 hybrid, so no
        // mount-time grab can race it).
        let store = makeStore()
        let a = store.addWorkspace(workingDirectory: projectA)
        let pane1 = firstPane(a)
        store.splitPane(pane1, orientation: .horizontal, in: a)
        // splitPane activates the new (second) pane; focus the first one instead.
        store.focusPane(pane1, in: a)
        XCTAssertEqual(a.activePaneId, pane1.id)

        let b = store.addWorkspace(workingDirectory: projectB)  // activates B
        XCTAssertEqual(store.activeWorkspaceId, b.id)
        store.activateWorkspace(a)                              // switch back to A

        XCTAssertEqual(store.activeWorkspaceId, a.id)
        XCTAssertEqual(a.activePaneId, pane1.id, "active pane must survive a workspace round-trip")
    }

    func testFailureSurfacesEvenWhenAttentionFiresFirstInDFS() {
        // Regression: `sidebarReadout`'s walk used to short-circuit on attention,
        // leaving `hasCommandFailure` false when a sibling pane held a non-zero
        // exit. The walk now runs to completion so each field is independent.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        store.splitPane(pane, orientation: .horizontal, in: ws)
        let firstPaneTab = pane.tabs[0]
        let secondPaneTab = ws.root.allPanes.last!.tabs[0]
        firstPaneTab.activityState = .attention
        engine(secondPaneTab).emitCommandFinished(exit: 1, duration: 0.1)
        XCTAssertEqual(ws.activityState, .attention)
        XCTAssertTrue(ws.hasCommandFailure)
    }

    func testPresetTabsAreTreatedAsShellsInSidebarReadout() {
        // Regression: when `Workspace.sidebarReadout` filtered with
        // `id != AgentTemplate.terminal.id`, preset tabs (id `preset-N`)
        // counted as "agents" — the sidebar would show a pip per preset
        // and a `+N` indicator for a workspace that just held a few
        // pinned-cwd terminals. `isShell` covers Terminal + all presets.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pinned = AgentTemplate.fromTerminalPreset(
            TerminalPreset(id: "preset-b", title: "B", path: projectB.path)
        )
        store.addTab(in: ws, template: pinned)
        XCTAssertTrue(ws.distinctAgents.isEmpty,
                      "preset tabs are shells, not agents — sidebar must not list them")
    }

    func testAddTabUsesTemplateExtraCwdOverWorkspaceCwd() {
        // Terminal preset pinned to /tmp/projectB spawns there even when
        // the active workspace lives in /tmp/projectA. Models issue #12 —
        // `+` menu entries that always open at a fixed path.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pinned = AgentTemplate.fromTerminalPreset(
            TerminalPreset(id: "preset-b", title: "B", path: projectB.path)
        )
        let session = store.addTab(in: ws, template: pinned)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, projectB.path)
    }

    func testAddTabInitialCwdOverridesTemplateExtraCwd() {
        // Explicit `initialCwd` (right-click "Ask <agent>" path,
        // `reopenLastClosedTab`) wins over the template's pinned cwd —
        // the caller is asking for that exact path, not the template's
        // default.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pinned = AgentTemplate.fromTerminalPreset(
            TerminalPreset(id: "preset-b", title: "B", path: projectB.path)
        )
        let session = store.addTab(in: ws, template: pinned, initialCwd: projectC)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, projectC.path)
    }

    func testNewTabInheritsLatestPwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        engine(pane.tabs[0]).emitPwd("/tmp/projectA/sub")
        let session = store.addTab(in: ws)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, "/tmp/projectA/sub")
    }

    func testAddTabRespectsTemplate() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode)
        XCTAssertEqual(session.agent.id, "claude-code")
        XCTAssertEqual(engine(session).startedConfigs.first?.environment["KOOKY_AGENT"], "claude")
    }

    func testReopenLastClosedTabRestoresAgentAndCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = store.addTab(in: ws, template: .claudeCode, initialCwd: projectB)
        session.customTitle = "release prep"
        XCTAssertEqual(firstPane(ws).tabs.count, 2)

        store.closeTab(session, in: ws)
        XCTAssertEqual(firstPane(ws).tabs.count, 1)
        XCTAssertTrue(store.canReopenClosedTab)

        let reopened = store.reopenLastClosedTab()
        let pane = firstPane(ws)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(reopened?.agent.id, "claude-code")
        XCTAssertEqual(reopened?.currentDirectory.path, projectB.path)
        XCTAssertEqual(reopened?.customTitle, "release prep")
        XCTAssertEqual(pane.activeTabId, reopened?.id)
        XCTAssertFalse(store.canReopenClosedTab)
    }

    func testReopenIsLifoStack() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let a = store.addTab(in: ws)
        let b = store.addTab(in: ws)
        store.closeTab(a, in: ws)
        store.closeTab(b, in: ws)

        let firstReopen = store.reopenLastClosedTab()
        let secondReopen = store.reopenLastClosedTab()

        // LIFO: most-recently-closed (`b`) comes back first.
        XCTAssertEqual(firstReopen?.currentDirectory.path, b.currentDirectory.path)
        XCTAssertEqual(secondReopen?.currentDirectory.path, a.currentDirectory.path)
        XCTAssertEqual(pane.tabs.count, 3)
    }

    func testReopenWithEmptyStackReturnsNil() {
        let store = makeStore()
        XCTAssertFalse(store.canReopenClosedTab)
        XCTAssertNil(store.reopenLastClosedTab())
    }

    func testCycleTabAdvancesAndWrapsAroundEnd() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let a = pane.tabs[0]
        let b = store.addTab(in: ws)
        let c = store.addTab(in: ws)
        XCTAssertEqual(pane.activeTabId, c.id)

        store.cycleTab(in: ws, direction: 1)  // c → a (wrap)
        XCTAssertEqual(pane.activeTabId, a.id)

        store.cycleTab(in: ws, direction: 1)  // a → b
        XCTAssertEqual(pane.activeTabId, b.id)
    }

    func testCycleTabBackwardsWrapsAtStart() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let a = pane.tabs[0]
        let b = store.addTab(in: ws)
        store.activateTab(a, in: ws)

        store.cycleTab(in: ws, direction: -1)  // a → b (wrap backward)
        XCTAssertEqual(pane.activeTabId, b.id)
    }

    func testClosingActiveTabActivatesNeighbor() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let first = pane.tabs[0]
        let second = store.addTab(in: ws)
        XCTAssertEqual(pane.activeTabId, second.id)
        store.closeTab(second, in: ws)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.activeTabId, first.id)
        XCTAssertEqual(engine(second).terminateCount, 1)
    }

    func testClosingLastTabClosesPaneAndWorkspaceWhenSinglePane() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        store.closeTab(pane.tabs[0], in: ws)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    func testClosingMiddleWorkspaceActivatesNextNeighbor() {
        let store = makeStore()
        let a = store.workspaces[0]
        let b = store.addWorkspace(workingDirectory: projectB)
        let c = store.addWorkspace(workingDirectory: projectC)
        store.activateWorkspace(b)
        store.closeWorkspace(b)
        XCTAssertEqual(store.workspaces.map(\.id), [a.id, c.id])
        XCTAssertEqual(store.activeWorkspaceId, c.id)
    }

    func testClosingLastWorkspaceClearsActiveId() {
        let store = makeStore()
        store.closeWorkspace(store.workspaces[0])
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    // MARK: Splits

    func testSplitPaneCreatesSiblingPaneAndFocusesIt() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)
        XCTAssertNotNil(new)
        XCTAssertEqual(ws.root.allPanes.count, 2)
        XCTAssertEqual(ws.activePaneId, new?.id)
        XCTAssertEqual(new?.tabs.count, 1)
    }

    func testRepeatedRightSplitsRebalanceTheAncestorPath() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let first = firstPane(ws)
        let second = store.splitPane(first, orientation: .horizontal, in: ws)!
        let third = store.splitPane(second, orientation: .horizontal, in: ws)!
        _ = store.splitPane(third, orientation: .horizontal, in: ws)

        guard case .split(.horizontal, _, let right, let rootFraction) = ws.root.content else {
            return XCTFail("root should remain horizontal")
        }
        XCTAssertEqual(rootFraction, 0.25, accuracy: 0.001)
        guard case .split(.horizontal, _, let deepRight, let rightFraction) = right.content else {
            return XCTFail("right subtree should remain horizontal")
        }
        XCTAssertEqual(rightFraction, 1.0 / 3.0, accuracy: 0.001)
        guard case .split(.horizontal, _, _, let deepFraction) = deepRight.content else {
            return XCTFail("deep right subtree should remain horizontal")
        }
        XCTAssertEqual(deepFraction, 0.5, accuracy: 0.001)
    }

    func testSplitPaneInheritsActiveTabAgentAndCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        store.addTab(in: ws, template: .claudeCode)
        engine(pane.tabs.last!).emitPwd("/tmp/projectA/sub")
        let new = store.splitPane(pane, orientation: .vertical, in: ws)
        let newSession = new?.tabs.first
        XCTAssertEqual(newSession?.agent.id, "claude-code")
        XCTAssertEqual((newSession?.engine as? TestEngine)?.startedConfigs.last?.workingDirectory, "/tmp/projectA/sub")
    }

    func testClosePaneCollapsesSiblingUp() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        XCTAssertEqual(ws.root.allPanes.count, 2)
        store.closePane(new, in: ws)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(ws.root.allPanes.first?.id, pane.id)
    }

    func testClosingLastTabInSecondPaneCollapsesSplit() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        // Close the lone tab in `new`. Should collapse the split, leaving `pane` alone.
        store.closeTab(new.tabs[0], in: ws)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(ws.root.allPanes.first?.id, pane.id)
    }

    func testFocusPaneSwitchesActivePane() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        store.focusPane(pane, in: ws)
        XCTAssertEqual(ws.activePaneId, pane.id)
        store.focusPane(new, in: ws)
        XCTAssertEqual(ws.activePaneId, new.id)
    }

    func testCrossPaneMoveOfRootSoleTabKeepsWorkspaceAlive() {
        // Regression: after splitPane, the root PaneNode kept the original
        // pane's id; the wrapper for that pane (now `firstChild`) reused the
        // same id. Closing the now-empty source pane via id-equality would
        // route to closeWorkspace and terminate the freshly-moved session.
        let store = makeStore()
        let ws = store.workspaces[0]
        let original = firstPane(ws)
        let originalSession = original.tabs[0]
        let new = store.splitPane(original, orientation: .horizontal, in: ws)!
        XCTAssertEqual(ws.root.allPanes.count, 2)
        store.moveTab(originalSession, to: new, at: new.tabs.count, in: ws)
        XCTAssertFalse(store.workspaces.isEmpty)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertTrue(new.tabs.contains { $0.id == originalSession.id })
        XCTAssertEqual(engine(originalSession).terminateCount, 0)
    }

    func testCrossPaneMoveSyncsWorkspaceWorkingDirectory() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let source = firstPane(ws)
        let session = source.tabs[0]
        engine(session).emitPwd("/tmp/projectA/sub")
        let dest = store.splitPane(source, orientation: .horizontal, in: ws)!
        // splitPane spawns a new session in dest; switch active away first so
        // the move into dest is the thing that has to sync the cwd.
        store.focusPane(source, in: ws)
        store.moveTab(session, to: dest, at: dest.tabs.count, in: ws)
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA/sub")
    }

    // MARK: Persistence

    func testRestoreSinglePaneWorkspace() {
        let wsId = UUID()
        let paneId = UUID()
        let leafA = UUID()
        let leafB = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: paneId,
                        kind: .pane(PersistedPane(
                            id: paneId,
                            tabs: [
                                PersistedTab(id: leafA, agentId: "terminal", currentDirectoryPath: "/tmp/projectA"),
                                PersistedTab(id: leafB, agentId: "claude-code", currentDirectoryPath: "/tmp/projectA/sub"),
                            ],
                            activeTabId: leafB
                        ))
                    ),
                    activePaneId: paneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        XCTAssertEqual(store.workspaces.count, 1)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.id, wsId)
        XCTAssertEqual(ws.title, "projectA")
        let pane = firstPane(ws)
        XCTAssertEqual(pane.tabs.map(\.id), [leafA, leafB])
        XCTAssertEqual(pane.tabs[1].agent.id, "claude-code")
        XCTAssertEqual(pane.activeTabId, leafB)
        XCTAssertEqual(ws.activePaneId, paneId)
    }

    func testRestoreSpawnsEngineWithSavedWorkingDirectory() {
        let wsId = UUID()
        let paneId = UUID()
        let leafId = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: paneId,
                        kind: .pane(PersistedPane(
                            id: paneId,
                            tabs: [PersistedTab(id: leafId, agentId: "terminal", currentDirectoryPath: "/tmp/projectA/deep")],
                            activeTabId: leafId
                        ))
                    ),
                    activePaneId: paneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        let pane = firstPane(store.workspaces[0])
        XCTAssertEqual(engine(pane.tabs[0]).startedConfigs.last?.workingDirectory, "/tmp/projectA/deep")
    }

    func testRestoreSplitTreeReconstructsBothPanes() {
        let wsId = UUID()
        let rootId = UUID()
        let firstPaneId = UUID()
        let secondPaneId = UUID()
        let leafA = UUID()
        let leafB = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: rootId,
                        kind: .split(
                            orientation: .horizontal,
                            first: PersistedPaneNode(id: firstPaneId, kind: .pane(PersistedPane(id: firstPaneId, tabs: [PersistedTab(id: leafA, agentId: "terminal", currentDirectoryPath: "/tmp/projectA")], activeTabId: leafA))),
                            second: PersistedPaneNode(id: secondPaneId, kind: .pane(PersistedPane(id: secondPaneId, tabs: [PersistedTab(id: leafB, agentId: "terminal", currentDirectoryPath: "/tmp/projectA")], activeTabId: leafB))),
                            fraction: 0.6
                        )
                    ),
                    activePaneId: secondPaneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.root.allPanes.count, 2)
        XCTAssertEqual(ws.activePaneId, secondPaneId)
        if case .split(_, _, _, let fraction) = ws.root.content {
            XCTAssertEqual(fraction, 0.6, accuracy: 0.0001)
        } else {
            XCTFail("expected split content at root")
        }
    }

    func testFlushPersistenceWritesCurrentSnapshot() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/projectB"))
        store.flushPersistence()
        let saved = try XCTUnwrap(persistence.saved)
        XCTAssertEqual(saved.workspaces.count, 2)
        XCTAssertEqual(saved.workspaces.last?.workingDirectoryPath, "/tmp/projectB")
        XCTAssertEqual(saved.activeWorkspaceId, store.activeWorkspaceId)
    }

    func testSidebarContentPersistsAndRestores() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        store.addWorkspace(workingDirectory: projectA)
        store.setSidebarContent(.files)
        store.flushPersistence()
        XCTAssertEqual(persistence.saved?.sidebarContent, .files)

        let restored = makeStore(initial: persistence.saved)
        XCTAssertEqual(restored.sidebarContent, .files)
    }

    func testCollapsedInfoSectionsPersistAndRestore() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        store.addWorkspace(workingDirectory: projectA)
        store.toggleInfoSection("Processes")
        store.toggleInfoSection("Runtime")
        store.flushPersistence()
        // Sorted on save so the file is byte-stable across saves (Set order
        // isn't), absent when nothing is collapsed.
        XCTAssertEqual(persistence.saved?.collapsedInfoSections, ["Processes", "Runtime"])

        let restored = makeStore(initial: persistence.saved)
        XCTAssertEqual(restored.collapsedInfoSections, ["Processes", "Runtime"])

        store.toggleInfoSection("Processes")
        store.toggleInfoSection("Runtime")
        store.flushPersistence()
        XCTAssertNil(persistence.saved?.collapsedInfoSections)
    }

    func testRightSidebarWidthPersistsAndRestoresClamped() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        store.addWorkspace(workingDirectory: projectA)
        store.rightSidebarWidth = 320
        store.flushPersistence()
        XCTAssertEqual(persistence.saved?.rightSidebarWidth, 320)

        let restored = makeStore(initial: persistence.saved)
        XCTAssertEqual(restored.rightSidebarWidth, 320)

        // A hand-edited / stale width restores clamped to the floor — the
        // design width is the minimum, the panel only grows.
        var narrow = persistence.saved!
        narrow.rightSidebarWidth = 80
        XCTAssertEqual(makeStore(initial: narrow).rightSidebarWidth, AgentOverviewSidebar.fullWidth)

        // Pre-resizable-panel state files (no key) restore the default.
        var legacy = persistence.saved!
        legacy.rightSidebarWidth = nil
        XCTAssertEqual(makeStore(initial: legacy).rightSidebarWidth, AgentOverviewSidebar.fullWidth)
    }

    func testRequestRenameActiveWorkspaceLeavesFilesMode() {
        // The rename popover anchors to a workspace row — ⌘⇧R from files
        // mode must flip the sidebar back so the parked request is consumed.
        let store = makeStore()
        store.addWorkspace(workingDirectory: projectA)
        store.setSidebarContent(.files)
        store.requestRenameActiveWorkspace()
        XCTAssertEqual(store.sidebarContent, .workspaces)
        XCTAssertNotNil(store.pendingRenameWorkspace)
    }

    func testRevealFileTreePromotesSidebarToFullFilesMode() {
        // Diff pill popover's "Show in File Tree": whatever state the sidebar
        // is in, it must land visible + full (the tree only mounts in the
        // full sidebar) with files content.
        let store = makeStore()
        store.addWorkspace(workingDirectory: projectA)

        store.setSidebarMode(.hidden)
        store.revealFileTree(root: projectA)
        XCTAssertEqual(store.sidebarMode, .full)
        XCTAssertEqual(store.sidebarContent, .files)
        XCTAssertEqual(store.fileTreeRoot?.path, projectA.path)

        store.setSidebarMode(.compact)
        store.setSidebarContent(.workspaces)
        store.revealFileTree()
        XCTAssertEqual(store.sidebarMode, .full)
        XCTAssertEqual(store.sidebarContent, .files)

        // Already full + files: a no-op, not a mode bounce.
        store.revealFileTree()
        XCTAssertEqual(store.sidebarMode, .full)
        XCTAssertEqual(store.sidebarContent, .files)
        XCTAssertEqual(store.fileTreeRoot?.path, store.active?.diskPath.path)
    }

    func testFileTreeRepoRootOverrideClearsWhenAnotherTabActivates() throws {
        let store = makeStore()
        let workspace = try XCTUnwrap(store.active)
        let first = try XCTUnwrap(workspace.activeSession)
        let second = store.addTab(
            in: workspace,
            template: .terminal,
            initialCwd: projectB
        )

        store.activateTab(first, in: workspace)
        store.revealFileTree(root: projectA)
        XCTAssertEqual(store.fileTreeRoot?.path, projectA.path)

        store.activateTab(second, in: workspace)
        XCTAssertEqual(store.fileTreeRoot?.path, projectB.path)
    }

    func testApplyDiffSnapshotFoldsTotalsBehindCwdAndRepoGuards() throws {
        // Diff pill click refresh: totals fold into the pill only when the
        // session is still at the cwd the snapshot was fetched for AND the
        // snapshot describes the repo the pill currently shows; branch /
        // repoRoot are untouched (numstat carries no branch info).
        let store = makeStore()
        store.addWorkspace(workingDirectory: projectA)
        let session = try XCTUnwrap(store.active?.activeSession)
        session.gitStatus = GitStatus(
            branch: "main", repoRoot: projectA.path,
            filesChanged: 1, insertions: 2, deletions: 3
        )
        let entries = [
            GitDiffFileEntry(path: "a.swift", insertions: 10, deletions: 4),
            GitDiffFileEntry(path: "b.swift", insertions: 5, deletions: 1),
        ]
        let snapshot = GitDiffSnapshot(repoRoot: projectA.path, entries: entries)

        // Stale click result (cwd moved while git was in flight) → ignored.
        store.applyDiffSnapshot(snapshot, for: session, cwdPath: "/tmp/elsewhere")
        XCTAssertEqual(session.gitStatus.filesChanged, 1)

        // Mid-`cd` across repos: snapshot from a repo the pill isn't showing
        // (its branch/root still belong to the old one) → ignored.
        let foreign = GitDiffSnapshot(repoRoot: projectB.path, entries: entries)
        store.applyDiffSnapshot(foreign, for: session, cwdPath: session.currentDirectory.path)
        XCTAssertEqual(session.gitStatus.filesChanged, 1)

        store.applyDiffSnapshot(snapshot, for: session, cwdPath: session.currentDirectory.path)
        XCTAssertEqual(session.gitStatus.filesChanged, 2)
        XCTAssertEqual(session.gitStatus.insertions, 15)
        XCTAssertEqual(session.gitStatus.deletions, 5)
        XCTAssertEqual(session.gitStatus.branch, "main")
        XCTAssertEqual(session.gitStatus.repoRoot, projectA.path)
    }

    func testFileTreeRootOverrideCannotResurrectAfterDirectActiveWrite() throws {
        // `addTab` promotes the new session by writing active ids directly
        // (bypassing `activateTab`) — the override must die there, not lie
        // dormant and resurrect when the original session reactivates.
        let store = makeStore()
        let workspace = try XCTUnwrap(store.active)
        let revealed = try XCTUnwrap(workspace.activeSession)
        store.revealFileTree(root: projectB)
        XCTAssertEqual(store.fileTreeRoot?.path, projectB.path)

        _ = store.addTab(in: workspace, template: .terminal)
        store.activateTab(revealed, in: workspace)
        XCTAssertEqual(store.fileTreeRoot?.path, workspace.diskPath.path)
    }

    func testTerminateCancelsFileTreeWatchers() {
        let store = makeStore()
        store.addWorkspace(workingDirectory: projectA)
        store.fileTree.activate(root: projectA)
        XCTAssertEqual(store.fileTree.watchedDirectoryCount, 1)
        store.terminate()
        XCTAssertEqual(store.fileTree.watchedDirectoryCount, 0)
    }

    func testApplyConversationIdWritesToCorrectSessionOnly() {
        // Two Claude tabs running in parallel — each gets its own conversation
        // id via separate `applyConversationId` calls, neither stomps the
        // other. Same isolation we get in prod via KOOKY_SURFACE_ID routing.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let tabA = store.addTab(in: ws, template: .claudeCode)
        let tabB = store.addTab(in: ws, template: .claudeCode)
        _ = pane

        store.applyConversationId(conversationId: "convo-a", sessionId: tabA.id)
        store.applyConversationId(conversationId: "convo-b", sessionId: tabB.id)

        XCTAssertEqual(tabA.conversationId, "convo-a")
        XCTAssertEqual(tabB.conversationId, "convo-b")
    }

    /// Collapse lives on the store because the page unmounts on every panel
    /// switch — the same reason the history filter does.
    func testInfoSectionCollapseTogglesAndStartsFullyExpanded() {
        let store = makeStore()

        XCTAssertTrue(
            store.collapsedInfoSections.isEmpty,
            "every section opens by default — collapsing is the user's call"
        )

        store.toggleInfoSection("Context")
        XCTAssertEqual(store.collapsedInfoSections, ["Context"])

        store.toggleInfoSection("Runtime")
        XCTAssertEqual(store.collapsedInfoSections, ["Context", "Runtime"])

        store.toggleInfoSection("Context")
        XCTAssertEqual(store.collapsedInfoSections, ["Runtime"])
    }

    func testCommandMarkerRecordsTextWithoutBecomingAVisibleTitle() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tabA = store.addTab(in: ws, template: .terminal)
        let tabB = store.addTab(in: ws, template: .terminal)

        engine(tabA).emitTitle(CommandMarker.titlePrefix + "  git status --short  ")
        engine(tabA).emitCommandFinished(exit: 0, duration: 0.25)

        XCTAssertEqual(tabA.lastCommandText, "git status --short")
        XCTAssertNil(
            tabA.terminalTitle,
            "a command marker is consumed, never shown as the tab title"
        )
        XCTAssertNil(tabB.lastCommandText, "the marker rides one session's own stream")
    }

    /// The pairing of text with exit code depends on this: the keystroke that
    /// starts the next command clears the previous pair, and the marker for the
    /// new command arrives afterwards on the same stream.
    func testUserInputClearsThePreviousCommandPair() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .terminal)

        engine(tab).emitTitle(CommandMarker.titlePrefix + "ls")
        engine(tab).emitCommandFinished(exit: 0, duration: 0.25)
        XCTAssertEqual(tab.lastCommandText, "ls")

        engine(tab).emitUserInput()
        XCTAssertNil(tab.lastCommandText, "typing the next command must clear stale command text")
        XCTAssertNil(tab.lastCommandExit)
        XCTAssertNil(tab.lastCommandDuration)
    }

    /// The inspector's snapshot lives on the other side of that clear: it
    /// survives input and is only replaced when the NEXT command completes.
    func testCompletedCommandSnapshotSurvivesInputUntilReplaced() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .terminal)

        engine(tab).emitTitle(CommandMarker.titlePrefix + "make build")
        engine(tab).emitCommandFinished(exit: 2, duration: 3.5)
        engine(tab).emitUserInput()

        XCTAssertNil(tab.lastCommandExit, "precondition: the red-dot pair cleared")
        XCTAssertEqual(tab.lastCompletedCommand?.text, "make build")
        XCTAssertEqual(tab.lastCompletedCommand?.exit, 2)
        XCTAssertEqual(tab.lastCompletedCommand?.duration, 3.5)

        engine(tab).emitTitle(CommandMarker.titlePrefix + "make test")
        engine(tab).emitCommandFinished(exit: 0, duration: 1.0)
        XCTAssertEqual(tab.lastCompletedCommand?.text, "make test")
        XCTAssertEqual(tab.lastCompletedCommand?.exit, 0)
    }

    /// A shell that omits the 133;D exit field never showed a Last-command
    /// row before the snapshot existed; keep that gate.
    func testExitlessCommandResultDoesNotSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .terminal)

        engine(tab).emitTitle(CommandMarker.titlePrefix + "ls")
        engine(tab).emitCommandFinished(exit: nil, duration: 0.2)
        XCTAssertNil(tab.lastCompletedCommand)
    }

    func testRemoteLoginMarkerDropsTheLocalSshCommandLabel() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .terminal)

        engine(tab).emitTitle(CommandMarker.titlePrefix + "ssh build-box")
        engine(tab).emitTitle(RemoteLoginMarker.titlePrefix + "build-box")

        XCTAssertEqual(tab.remoteHost, "build-box")
        XCTAssertNil(
            tab.lastCommandText,
            "OSC 133 results after this marker belong to remote commands, not `ssh build-box`"
        )
    }

    func testConversationIdSurvivesPersistenceRoundTrip() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .claudeCode)
        store.applyConversationId(conversationId: "convo-roundtrip", sessionId: tab.id)
        store.flushPersistence()

        let saved = try XCTUnwrap(persistence.saved)
        let persistedTab = saved.workspaces
            .flatMap(\.root.allTabs)
            .first { $0.id == tab.id }
        XCTAssertEqual(persistedTab?.conversationId, "convo-roundtrip")
    }

    func testClaudeNoSessionPersistenceDropsResumeIdWithoutDisablingFutureCapture() {
        let store = WorkspaceStore(
            persistence: InMemoryPersistence(),
            engineFactory: { TestEngine() },
            optionsProvider: { id in
                id == AgentTemplate.claudeCodeID
                    ? "--print --no-session-persistence"
                    : nil
            },
            resumeProvider: { true }
        )
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(
            in: ws,
            template: .claudeCode,
            conversationId: "old-persisted-id"
        )

        XCTAssertEqual(
            engine(tab).startedConfigs.last?.environment["KOOKY_AGENT"],
            "claude --print --no-session-persistence"
        )
        XCTAssertNil(tab.conversationId)

        // KookyHook suppresses the ephemeral run's id using the wrapper-scoped
        // environment marker. The tab itself must remain capture-capable so a
        // later normal, manually typed Claude run can persist its valid id.
        store.applyConversationId(conversationId: "later-persistent-id", sessionId: tab.id)
        XCTAssertEqual(tab.conversationId, "later-persistent-id")
    }

    func testPiLegacyConversationIdIsNormalizedBeforeSpawn() {
        let legacy = "2026-07-14T19-24-02-459Z_019f6216-161b-737e-ba6b-0f974a7b7b8c"
        let canonical = "019f6216-161b-737e-ba6b-0f974a7b7b8c"
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .pi, conversationId: legacy)

        XCTAssertEqual(tab.conversationId, canonical)
        XCTAssertEqual(
            engine(tab).startedConfigs.last?.environment["KOOKY_AGENT"],
            "pi --session \(canonical)"
        )
    }

    func testFreshGrokSessionPreallocatesAndPersistsExactId() throws {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .grok)

        let id = try XCTUnwrap(tab.conversationId)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(
            engine(tab).startedConfigs.last?.environment["KOOKY_AGENT"],
            "grok --session-id \(id)"
        )
    }

    func testGrokRestoresExistingConversationWithResume() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .grok, conversationId: "grok-existing")

        XCTAssertEqual(tab.conversationId, "grok-existing")
        XCTAssertEqual(
            engine(tab).startedConfigs.last?.environment["KOOKY_AGENT"],
            "grok --resume grok-existing"
        )
    }

    func testGrokResumeDisabledStartsAndStoresNewConversation() throws {
        let store = WorkspaceStore(
            persistence: InMemoryPersistence(),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { false }
        )
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .grok, conversationId: "old-id")
        let id = try XCTUnwrap(tab.conversationId)

        XCTAssertNotEqual(id, "old-id")
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(
            engine(tab).startedConfigs.last?.environment["KOOKY_AGENT"],
            "grok --session-id \(id)"
        )
    }

    func testReopenLastClosedTabRestoresConversationId() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .claudeCode)
        store.applyConversationId(conversationId: "convo-reopen", sessionId: tab.id)
        store.closeTab(tab, in: ws)

        let reopened = store.reopenLastClosedTab()
        XCTAssertEqual(reopened?.conversationId, "convo-reopen")
    }

    func testAddTabPropagatesInitialPromptToSpawnedEngine() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let tab = store.addTab(in: ws, template: .claudeCode, initialPrompt: "explain this")
        let cfg = engine(tab).startedConfigs.last
        XCTAssertEqual(cfg?.environment["KOOKY_AGENT"], "claude -- 'explain this'")
    }

    // MARK: - Multi-window teardown

    func testTerminateReleasesEverySessionEngine() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        store.addTab(in: ws, template: .terminal)
        store.splitPane(firstPane(ws), orientation: .horizontal, in: ws)
        let engines = store.workspaces
            .flatMap { $0.root.allPanes.flatMap(\.tabs) }
            .map { engine($0) }
        XCTAssertTrue(engines.allSatisfy { $0.terminateCount == 0 })
        store.terminate()
        XCTAssertTrue(engines.allSatisfy { $0.terminateCount == 1 },
                      "terminate() must release every session's engine")
    }

    func testOnBecameEmptyFiresWhenLastWorkspaceCloses() {
        let store = makeStore()   // starts with one workspace
        var fired = 0
        store.onBecameEmpty = { fired += 1 }
        let extra = store.addWorkspace(workingDirectory: projectA)
        store.closeWorkspace(extra)
        XCTAssertEqual(fired, 0, "one workspace still open — store is not empty")
        store.closeWorkspace(store.workspaces[0])
        XCTAssertEqual(fired, 1, "closing the last workspace empties the store")
    }

    // MARK: - Cross-window tab drag

    func testHandleTabDropMovesTabBetweenPanesInSameWindow() {
        // The same-window path through `handleTabDrop` still works after the
        // cross-window branch was added.
        let store = makeStore()
        let ws = store.workspaces[0]
        let source = firstPane(ws)
        let session = source.tabs[0]
        let dest = store.splitPane(source, orientation: .horizontal, in: ws)!
        let ok = store.handleTabDrop(droppedId: session.id, to: dest, at: dest.tabs.count, in: ws)
        XCTAssertTrue(ok)
        XCTAssertTrue(dest.tabs.contains { $0 === session })
    }

    func testCrossWindowDropMovesSessionToOtherWindow() {
        let (a, b) = makeWindowPair()
        let wsA = a.workspaces[0]
        let moved = a.addTab(in: wsA, template: .claudeCode)
        let wsB = b.workspaces[0]
        let destPane = firstPane(wsB)

        let ok = b.handleTabDrop(droppedId: moved.id, to: destPane, at: destPane.tabs.count, in: wsB)

        XCTAssertTrue(ok)
        XCTAssertTrue(destPane.tabs.contains { $0 === moved }, "session now lives in window B")
        XCTAssertFalse(firstPane(wsA).tabs.contains { $0 === moved }, "session left window A")
        XCTAssertEqual(firstPane(wsA).tabs.count, 1, "window A keeps its remaining tab")
        XCTAssertEqual(engine(moved).terminateCount, 0, "the move must not terminate the engine")
    }

    func testCrossWindowDropRewiresEngineCallbacksToDestination() {
        let (a, b) = makeWindowPair()
        let wsA = a.workspaces[0]
        let moved = a.addTab(in: wsA, template: .terminal)
        let wsB = b.workspaces[0]
        b.handleTabDrop(droppedId: moved.id, to: firstPane(wsB), at: 0, in: wsB)

        // The engine's callbacks must now drive window B, not the window the
        // tab was dragged out of.
        engine(moved).emitPwd("/tmp/projectC")
        XCTAssertEqual(wsB.workingDirectory.path, "/tmp/projectC", "pwd change reaches window B")
        XCTAssertNotEqual(wsA.workingDirectory.path, "/tmp/projectC", "window A is untouched")
    }

    func testCrossWindowDropOfLastTabEmptiesSourceWindow() {
        let (a, b) = makeWindowPair()
        var aBecameEmpty = 0
        a.onBecameEmpty = { aBecameEmpty += 1 }
        let onlyTab = firstPane(a.workspaces[0]).tabs[0]
        let wsB = b.workspaces[0]

        b.handleTabDrop(droppedId: onlyTab.id, to: firstPane(wsB), at: firstPane(wsB).tabs.count, in: wsB)

        XCTAssertTrue(a.workspaces.isEmpty, "window A's last tab left — its workspace collapsed away")
        XCTAssertEqual(aBecameEmpty, 1, "store A signalled empty so its window can close")
        XCTAssertTrue(firstPane(wsB).tabs.contains { $0 === onlyTab })
        XCTAssertEqual(engine(onlyTab).terminateCount, 0, "engine survives the source window emptying")
    }

    func testHandleTabDropReturnsFalseWhenSessionExistsNowhere() {
        let (_, b) = makeWindowPair()
        let wsB = b.workspaces[0]
        XCTAssertFalse(b.handleTabDrop(droppedId: UUID(), to: firstPane(wsB), at: 0, in: wsB))
    }

    func testMoveTabToNewWindowForwardsRequestToInjectedClosure() {
        var captured: UUID?
        let store = WorkspaceStore(
            persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { true },
            moveToNewWindow: { captured = $0 }
        )
        let id = UUID()
        store.moveTabToNewWindow(id)
        XCTAssertEqual(captured, id)
    }

    func testDiscardTabDoesNotRecordToReopenHistory() {
        // `discardTab` is for synthetic tabs the user never knowingly opened
        // (e.g. the placeholder in a freshly-spawned Move-to-New-Window
        // window). It must not pollute the `⌘⇧T` reopen stack.
        let store = makeStore()
        let ws = store.workspaces[0]
        let tab = store.addTab(in: ws)
        store.discardTab(tab, in: ws)
        XCTAssertNil(store.reopenLastClosedTab(), "discardTab must not feed the reopen stack")
    }

    // MARK: - Pane zoom

    func testToggleZoomNoOpOnSinglePane() {
        // Single pane → nothing to zoom into, guard rejects.
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        store.toggleZoom(in: ws, paneId: pane.id)
        XCTAssertNil(ws.zoomedPaneId)
    }

    func testToggleZoomOnMultiPaneSetsZoomAndActivates() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let firstPane = self.firstPane(ws)
        guard let newPane = store.splitPane(firstPane, orientation: .horizontal, in: ws) else {
            return XCTFail("split failed")
        }
        // Force active to first so toggleZoom on second has to also
        // activate (regression: clicking a non-active pane's button must
        // zoom THAT pane, not the active one).
        store.activateTab(firstPane.tabs[0], in: ws)
        XCTAssertEqual(ws.activePaneId, firstPane.id)

        store.toggleZoom(in: ws, paneId: newPane.id)
        XCTAssertEqual(ws.zoomedPaneId, newPane.id)
        XCTAssertEqual(ws.activePaneId, newPane.id, "zoom must activate the targeted pane")
    }

    func testToggleZoomTwiceClears() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        store.splitPane(pane, orientation: .horizontal, in: ws)
        store.toggleZoom(in: ws, paneId: pane.id)
        store.toggleZoom(in: ws, paneId: pane.id)
        XCTAssertNil(ws.zoomedPaneId)
    }

    func testToggleZoomOnDifferentPaneSwitchesTarget() {
        // While pane A is zoomed, clicking zoom on pane B should switch
        // the zoom target to B (not unzoom). Matches the "make THIS pane
        // fullscreen" muscle memory the docstring promises.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let paneA = firstPane(ws)
        guard let paneB = store.splitPane(paneA, orientation: .horizontal, in: ws) else {
            return XCTFail("split failed")
        }
        store.toggleZoom(in: ws, paneId: paneA.id)
        XCTAssertEqual(ws.zoomedPaneId, paneA.id)
        store.toggleZoom(in: ws, paneId: paneB.id)
        XCTAssertEqual(ws.zoomedPaneId, paneB.id)
    }

    func testSplitWhileZoomedClearsZoom() {
        // splitPane → user wants to see the new pane, drop zoom.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let paneA = firstPane(ws)
        store.splitPane(paneA, orientation: .horizontal, in: ws)
        store.toggleZoom(in: ws, paneId: paneA.id)
        XCTAssertEqual(ws.zoomedPaneId, paneA.id)
        store.splitPane(paneA, orientation: .vertical, in: ws)
        XCTAssertNil(ws.zoomedPaneId)
    }

    func testClosingZoomedPaneClearsZoom() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let paneA = firstPane(ws)
        guard let paneB = store.splitPane(paneA, orientation: .horizontal, in: ws) else {
            return XCTFail("split failed")
        }
        store.toggleZoom(in: ws, paneId: paneB.id)
        XCTAssertEqual(ws.zoomedPaneId, paneB.id)
        store.closePane(paneB, in: ws)
        XCTAssertNil(ws.zoomedPaneId)
    }

    func testCanZoomReflectsTreeShape() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        XCTAssertFalse(ws.canZoom, "single-pane workspace can't zoom")
        let pane = firstPane(ws)
        store.splitPane(pane, orientation: .horizontal, in: ws)
        XCTAssertTrue(ws.canZoom, "multi-pane workspace can zoom")
    }

    func testFocusPaneWhileZoomedClearsZoom() {
        // Regression (Codex P2 — `WorkspaceStore.swift:528-529`): cycling
        // focus via ⌘[ / ⌘] off the zoomed pane previously left
        // `zoomedPaneId` pointing at the old pane while `activePaneId`
        // moved on, routing subsequent ⌘D / ⌘T at the hidden active
        // pane. Focus change to a different pane must drop zoom.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let paneA = firstPane(ws)
        guard let paneB = store.splitPane(paneA, orientation: .horizontal, in: ws) else {
            return XCTFail("split failed")
        }
        store.toggleZoom(in: ws, paneId: paneA.id)
        XCTAssertEqual(ws.zoomedPaneId, paneA.id)
        store.focusPane(paneB, in: ws)
        XCTAssertNil(ws.zoomedPaneId, "focusing a different pane while zoomed must exit zoom")
        XCTAssertEqual(ws.activePaneId, paneB.id)
    }

    func testActivateTabOnDifferentPaneWhileZoomedClearsZoom() {
        // Same regression on the activateTab path — clicking a tab in a
        // different (hidden) pane while zoomed must auto-exit so the
        // newly-focused pane becomes visible.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let paneA = firstPane(ws)
        guard let paneB = store.splitPane(paneA, orientation: .horizontal, in: ws) else {
            return XCTFail("split failed")
        }
        store.toggleZoom(in: ws, paneId: paneA.id)
        XCTAssertEqual(ws.zoomedPaneId, paneA.id)
        store.activateTab(paneB.tabs[0], in: ws)
        XCTAssertNil(ws.zoomedPaneId)
        XCTAssertEqual(ws.activePaneId, paneB.id)
    }

    func testActivateTabOnZoomedPaneKeepsZoom() {
        // Switching tabs WITHIN the zoomed pane (or just re-activating)
        // doesn't change pane focus → zoom stays. Guards against an
        // over-eager "any activateTab clears zoom" interpretation of the
        // fix above.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let paneA = firstPane(ws)
        store.splitPane(paneA, orientation: .horizontal, in: ws)
        let secondTab = store.addTab(in: ws, pane: paneA)
        store.toggleZoom(in: ws, paneId: paneA.id)
        store.activateTab(paneA.tabs[0], in: ws)
        XCTAssertEqual(ws.zoomedPaneId, paneA.id, "switching tabs in the zoomed pane keeps zoom")
        store.activateTab(secondTab, in: ws)
        XCTAssertEqual(ws.zoomedPaneId, paneA.id)
    }

    // Zoom's SIGWINCH suspension moved out of `toggleZoom` into the AppKit
    // host's animation pass (begin before the frame animation, end + flush in
    // its completion) — pinned by
    // `PaneTreeHostTests.testZoomSuspendsSizePropagationForTheAnimation`.

    func testSizePropagationSuspensionIsRefcounted() {
        // Zoom / status-bar / divider-drag can overlap on the same engine, so
        // suspension must be a refcount: it holds until the LAST owner ends, and a
        // stray extra end can't drive it negative (issue #29 review — the fix for
        // the shared-Bool clobber race).
        let store = makeStore()
        guard let session = store.active?.activeSession else {
            return XCTFail("expected an active session")
        }
        let e = engine(session)
        XCTAssertFalse(e.suspendsSizePropagation)
        e.beginSizePropagationSuspension()   // owner A
        e.beginSizePropagationSuspension()   // owner B
        XCTAssertTrue(e.suspendsSizePropagation)
        e.endSizePropagationSuspension()     // A ends
        XCTAssertTrue(e.suspendsSizePropagation, "still suspended while owner B holds it")
        e.endSizePropagationSuspension()     // B ends
        XCTAssertFalse(e.suspendsSizePropagation, "un-suspended only after the last owner ends")
        e.endSizePropagationSuspension()     // underflow guard
        XCTAssertFalse(e.suspendsSizePropagation)
    }

    // MARK: - onPwdChange refresh gating (issue #29 follow-up: env/save run only
    // on a real cwd change; git status still refreshes every prompt)

    func testPwdChangeUpdatesSessionAndWorkspaceDirectories() {
        let store = makeStore()
        guard let ws = store.active, let session = ws.activeSession else {
            return XCTFail("expected an active session")
        }
        engine(session).emitPwd("/tmp/projectB")
        XCTAssertEqual(session.currentDirectory.path, "/tmp/projectB")
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectB",
                       "active session's cwd drives the workspace working directory")
    }

    func testSamePwdLeavesDirectoriesUnchanged() {
        let store = makeStore()
        guard let ws = store.active, let session = ws.activeSession else {
            return XCTFail("expected an active session")
        }
        let e = engine(session)
        e.emitPwd("/tmp/projectA")
        // Re-emitting the same cwd (every prompt re-fires OSC 7) must be a no-op
        // on the directories — the gate keys off this exact comparison.
        e.emitPwd("/tmp/projectA")
        XCTAssertEqual(session.currentDirectory.path, "/tmp/projectA")
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA")
    }

    func testPwdChangeIsStillPersisted() {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(
            persistence: persistence,
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
        )
        guard let session = store.active?.activeSession else {
            return XCTFail("expected an active session")
        }
        engine(session).emitPwd("/tmp/projectB")
        store.flushPersistence()
        // Gating scheduleSave on cwd-change must NOT drop the new directory from
        // persistence, otherwise a restored tab would reopen in the wrong place.
        XCTAssertEqual(persistence.saved?.workspaces.first?.workingDirectoryPath, "/tmp/projectB")
        XCTAssertEqual(persistence.saved?.workspaces.first?.root.allTabs.first?.currentDirectoryPath,
                       "/tmp/projectB")
    }

    /// Directly exercises the scheduleSave gating: a real cwd change persists,
    /// re-emitting the SAME cwd (every prompt re-fires OSC 7) must NOT schedule
    /// a redundant save. Timing-based because scheduleSave debounces ~1s.
    func testSamePwdDoesNotScheduleRedundantSave() async {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(
            persistence: persistence,
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
        )
        guard let session = store.active?.activeSession else {
            return XCTFail("expected an active session")
        }
        let e = engine(session)
        // A real change schedules a save; let it (and the bootstrap save) settle.
        e.emitPwd("/tmp/projectB")
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        let baseline = persistence.saveCount
        XCTAssertGreaterThan(baseline, 0, "a real cwd change must persist")
        // Same cwd — the gate must skip scheduleSave entirely, so no new save.
        e.emitPwd("/tmp/projectB")
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(persistence.saveCount, baseline,
                       "re-emitting an unchanged cwd must not re-persist")
    }

    // MARK: - SSH workspaces

    func testAddWorkspaceWithSSHHostSpawnsFirstTabOverSSH() {
        let store = makeStore()

        let ws = store.addWorkspace(workingDirectory: projectA, sshRemoteHost: "deploy@example.com")

        guard let session = ws.activeSession else { return XCTFail("expected initial session") }
        XCTAssertEqual(ws.sshRemoteHost, "deploy@example.com")
        XCTAssertEqual(session.sshWorkspaceHost, "deploy@example.com")
        XCTAssertEqual(engine(session).isRemoteSessionProvider?(), true)
        XCTAssertEqual(
            engine(session).startedConfigs.last?.environment["KOOKY_AGENT"],
            "kooky-ssh 'deploy@example.com'"
        )
        XCTAssertEqual(session.activityState, .idle, "a plain shell over ssh is not agent activity")
    }

    func testAddWorkspaceTreatsWhitespaceHostAsLocal() {
        let store = makeStore()

        let ws = store.addWorkspace(workingDirectory: projectA, sshRemoteHost: "   ")

        XCTAssertNil(ws.sshRemoteHost)
        guard let session = ws.activeSession else { return XCTFail("expected initial session") }
        XCTAssertNil(session.sshWorkspaceHost)
        XCTAssertNil(engine(session).startedConfigs.last?.environment["KOOKY_AGENT"])
    }

    func testSSHWorkspaceAgentTabLaunchesAgentBehindDoubleDash() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA, sshRemoteHost: "deploy@example.com")

        let session = store.addTab(in: ws, template: .claudeCode)

        XCTAssertEqual(
            engine(session).startedConfigs.last?.environment["KOOKY_AGENT"],
            "kooky-ssh 'deploy@example.com' -- claude"
        )
        XCTAssertEqual(session.sshWorkspaceHost, "deploy@example.com")
        XCTAssertEqual(session.agent.id, AgentTemplate.claudeCodeID)
        XCTAssertEqual(session.activityState, .running, "remote agent tab promotes optimistically")
    }

    func testSSHWorkspaceAgentTabDropsLocalResumeId() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA, sshRemoteHost: "deploy@example.com")

        // resumeProvider is `true` in makeStore — locally this conversation
        // id would become `--resume <id>`. The remote has no such session.
        let session = store.addTab(in: ws, template: .claudeCode, conversationId: "abc-123")

        let launch = engine(session).startedConfigs.last?.environment["KOOKY_AGENT"] ?? ""
        XCTAssertFalse(launch.contains("--resume"), "local conversation ids must not ride to the remote: \(launch)")
        XCTAssertFalse(launch.contains("abc-123"))
    }

    func testSSHWorkspaceSplitInheritsHost() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA, sshRemoteHost: "deploy@example.com")
        let pane = firstPane(ws)

        guard let newPane = store.splitPane(pane, orientation: .horizontal, in: ws),
              let session = newPane.activeTab
        else { return XCTFail("expected split pane") }

        XCTAssertEqual(
            engine(session).startedConfigs.last?.environment["KOOKY_AGENT"],
            "kooky-ssh 'deploy@example.com'"
        )
        XCTAssertEqual(session.sshWorkspaceHost, "deploy@example.com")
    }

    func testRestoreSSHWorkspaceReconnectsTabs() {
        let wsId = UUID()
        let paneId = UUID()
        let leafId = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: paneId,
                        kind: .pane(PersistedPane(
                            id: paneId,
                            tabs: [PersistedTab(id: leafId, agentId: "terminal", currentDirectoryPath: "/tmp/projectA")],
                            activeTabId: leafId
                        ))
                    ),
                    activePaneId: paneId,
                    sshRemoteHost: "deploy@example.com"
                )
            ],
            activeWorkspaceId: wsId
        )

        let store = makeStore(initial: initial)

        guard let ws = store.workspaces.first, let session = ws.activeSession else {
            return XCTFail("expected restored workspace")
        }
        XCTAssertEqual(ws.sshRemoteHost, "deploy@example.com")
        XCTAssertEqual(session.sshWorkspaceHost, "deploy@example.com")
        XCTAssertEqual(
            engine(session).startedConfigs.last?.environment["KOOKY_AGENT"],
            "kooky-ssh 'deploy@example.com'"
        )
    }

    // MARK: - Recent folders

    func testAddWorkspaceRecordsRecentFolderExceptWorktreesAndSSH() {
        var noted: [String] = []
        let store = makeStore(noteRecentFolder: { noted.append($0.path) })
        // The seed workspace (home cwd) reports too — home filtering is
        // RecentFolders.note()'s own rule, covered by its tests. This test
        // pins the STORE-level exclusions, so start counting from here.
        noted.removeAll()

        store.addWorkspace(workingDirectory: projectA)
        XCTAssertEqual(noted, ["/tmp/projectA"], "a plain workspace records its folder")

        let source = store.workspaces[0]
        store.addWorkspace(workingDirectory: projectB, worktreeParent: source, worktreeBranch: "feat")
        XCTAssertEqual(noted, ["/tmp/projectA"], "worktree children must not be recorded — their dir dies with the worktree")

        store.addWorkspace(workingDirectory: projectC, sshRemoteHost: "deploy@example.com")
        XCTAssertEqual(noted, ["/tmp/projectA"], "SSH workspaces must not be recorded — the local cwd is not the project")
    }

    func testRecentFolderExclusionFollowsDirProvenance() {
        var noted: [String] = []
        let store = makeStore(noteRecentFolder: { noted.append($0.path) })
        noted.removeAll()

        // Duplicate on a worktree: the dir is path-matched to the worktree
        // workspace, so its exclusion rides along.
        let source = store.addWorkspace(workingDirectory: projectA)
        let worktree = store.addWorkspace(workingDirectory: projectB, worktreeParent: source, worktreeBranch: "feat")
        noted.removeAll()
        store.duplicateWorkspace(worktree)
        XCTAssertTrue(noted.isEmpty, "duplicating a worktree must not record its dying dir")

        // ⌘N (no explicit dir) while an SSH workspace is active inherits its
        // cwd — and must inherit its exclusion too.
        let ssh = store.addWorkspace(workingDirectory: projectC, sshRemoteHost: "deploy@example.com")
        store.activateWorkspace(ssh)
        noted.removeAll()
        store.addWorkspace()
        XCTAssertTrue(noted.isEmpty, "a dir inherited from an SSH workspace is not a local project")
    }

    func testManualSshMarkerKeepsStatusBarButNotPasteRouting() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        guard let session = ws.activeSession else { return XCTFail("expected session") }
        XCTAssertEqual(engine(session).isRemoteSessionProvider?(), false)

        // A manually typed `ssh` (public shim) emits the remote-login marker.
        engine(session).emitTitle("\(RemoteLoginMarker.titlePrefix)deploy@example.com")

        // v0.26.5 behaviour intact: the status-bar slot still gets the host…
        XCTAssertEqual(session.remoteHost, "deploy@example.com")
        // …but paste routing stays local, and the workspace is not promoted.
        XCTAssertNil(session.sshWorkspaceHost)
        XCTAssertNil(ws.sshRemoteHost)
        XCTAssertEqual(engine(session).isRemoteSessionProvider?(), true,
                       "manual SSH still owns remote file paths even though paste routing stays local")
        let next = store.addTab(in: ws, template: .terminal)
        XCTAssertNil(engine(next).startedConfigs.last?.environment["KOOKY_AGENT"])
    }

    func testRemoteHostSurvivesRemoteCommandsAndClearsOnLogoutMarker() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        guard let session = ws.activeSession else { return XCTFail("expected session") }

        engine(session).emitTitle("\(RemoteLoginMarker.titlePrefix)deploy@example.com")
        XCTAssertEqual(session.remoteHost, "deploy@example.com")

        // A REMOTE shell with its own integration emits OSC 133;D through
        // the connection on every remote command. That must NOT read as
        // "ssh exited" — the SSH conversation (and its keep-awake claim)
        // spans the whole connection.
        engine(session).emitCommandFinished(exit: 0, duration: 1)
        XCTAssertEqual(session.remoteHost, "deploy@example.com",
                       "a remote command finishing must not clear the live SSH host")

        // The wrapper's logout marker — emitted after ssh actually returns —
        // is the one true clear signal.
        engine(session).emitTitle(RemoteLoginMarker.logoutTitle)
        XCTAssertNil(session.remoteHost)
        XCTAssertEqual(engine(session).isRemoteSessionProvider?(), false)
    }

    // MARK: - Agent template refresh

    /// `Session.agent` is a value snapshot taken at spawn, so a Settings edit
    /// to a custom agent (importing a logo, renaming it) reaches new tabs but
    /// not already-open ones without this push.
    func testRefreshAgentTemplatesPushesEditsIntoOpenTabs() {
        let model = KookySettingsModel.shared
        let snapshot = model.customAgents
        defer { model.customAgents = snapshot }
        model.customAgents = [
            CustomAgentData(id: "custom-1", title: "Mine", command: "mine", iconAsset: "old-abc.png")
        ]
        let store = makeStore()
        let workspace = store.active!
        let session = store.addTab(in: workspace, template: .fromCustom(model.customAgents[0]))
        XCTAssertEqual(session.agent.iconAsset, "old-abc.png")

        model.customAgents[0].iconAsset = "new-def.png"
        store.refreshAgentTemplates()
        XCTAssertEqual(session.agent.iconAsset, "new-def.png")
        XCTAssertEqual(session.agent.id, "custom-1", "identity must survive the refresh")
    }

    /// A session whose agent no longer exists (the user deleted that custom
    /// agent mid-run) keeps what it has rather than being reset underneath.
    func testRefreshAgentTemplatesLeavesUnknownAndShellAgentsAlone() {
        let model = KookySettingsModel.shared
        let snapshot = model.customAgents
        defer { model.customAgents = snapshot }
        model.customAgents = [
            CustomAgentData(id: "custom-1", title: "Mine", command: "mine", iconAsset: "old-abc.png")
        ]
        let store = makeStore()
        let workspace = store.active!
        let custom = store.addTab(in: workspace, template: .fromCustom(model.customAgents[0]))
        let shell = store.addTab(in: workspace, template: .terminal)

        model.customAgents = []
        store.refreshAgentTemplates()
        XCTAssertEqual(custom.agent.iconAsset, "old-abc.png", "a deleted agent must not reset a live tab")
        XCTAssertTrue(shell.agent.isShell)
    }

    // MARK: - Sidebar row tooltip (issue #43)

    /// The compact sidebar row is icon-only, so its hover text is the only
    /// thing that can tell two workspaces running the same agent apart. The
    /// terminal-reported title is what carries that — the exact case the
    /// issue was filed about, where every row showed the same logo and the
    /// hover only offered a path.
    func testSidebarTooltipLeadsWithTheReportedTitle() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        ws.workingDirectory = projectA
        firstPane(ws).activeTab?.terminalTitle = "System Testing"

        XCTAssertEqual(ws.sidebarTooltip(agents: []), "System Testing\n/tmp/projectA")
    }

    /// A single agent is already named by the icon the row draws, so listing it
    /// would only repeat what's on screen. Two or more put a `+N` badge there
    /// instead — which says how many but never who — so that's where the names
    /// earn their line.
    func testSidebarTooltipNamesTheAgentsOnlyWhenTheBadgeIsAmbiguous() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        ws.workingDirectory = projectA

        XCTAssertEqual(ws.sidebarTooltip(agents: [.claudeCode]), "projectA\n/tmp/projectA",
                       "one agent is what the icon already shows")
        XCTAssertEqual(ws.sidebarTooltip(agents: [.claudeCode, .codex]),
                       "projectA\nClaude Code, Codex\n/tmp/projectA")
    }

    /// A custom title wins the first line, and the path still rides below it
    /// — renaming a workspace must not hide where it lives.
    func testSidebarTooltipHonoursACustomTitleWithoutDroppingThePath() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        ws.workingDirectory = projectA
        ws.customTitle = "Scroll fix"

        XCTAssertEqual(ws.sidebarTooltip(agents: []), "Scroll fix\n/tmp/projectA")
    }

    /// The location line mirrors what the expanded row shows underneath the
    /// title — branch for a worktree, host for an SSH workspace — so hovering
    /// a collapsed sidebar and expanding it never disagree. A worktree keeps
    /// its path as well: the expanded row drops the path *because* this
    /// tooltip is documented as carrying it.
    func testSidebarTooltipLocationTracksWorktreeAndSSH() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        ws.workingDirectory = projectA

        ws.worktreeBranch = "fix-scroll"
        XCTAssertEqual(ws.sidebarTooltip(agents: []), "projectA\nbranch fix-scroll\n/tmp/projectA")

        // An un-renamed SSH workspace whose remote hasn't reported a title is
        // named after its host, so a separate location line would say the same
        // thing twice — the two collapse into one.
        ws.worktreeBranch = nil
        ws.sshRemoteHost = "corey@prod"
        XCTAssertEqual(ws.sidebarTooltip(agents: []), "ssh corey@prod")

        // Once the title diverges there are two things to say, so both lines
        // come back — and the collapse must not have eaten the title.
        firstPane(ws).activeTab?.terminalTitle = "deploy"
        XCTAssertEqual(ws.sidebarTooltip(agents: []), "deploy\nssh corey@prod")
    }

    /// The collapsed SSH form used to be built by overwriting `lines[0]`, which
    /// silently assumed no other line had been inserted ahead of the title.
    /// Multi-agent × SSH is the combination where that assumption discriminates
    /// — the agent names must survive the collapse, in both orderings.
    func testSidebarTooltipKeepsAgentNamesWhenTheSSHTitleCollapses() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        ws.workingDirectory = projectA
        ws.sshRemoteHost = "corey@prod"

        XCTAssertEqual(ws.sidebarTooltip(agents: [.claudeCode, .codex]),
                       "ssh corey@prod\nClaude Code, Codex")

        firstPane(ws).activeTab?.terminalTitle = "deploy"
        XCTAssertEqual(ws.sidebarTooltip(agents: [.claudeCode, .codex]),
                       "deploy\nClaude Code, Codex\nssh corey@prod")
    }

    /// Titles reach the tooltip from OSC sequences and from hand-written
    /// settings.json, neither of which strips an interior newline. Every other
    /// render site is a one-line `Text` that collapses them; here a stray
    /// newline would add a line to a string whose line count is the structure.
    func testSidebarTooltipFlattensNewlinesInsideATitle() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        ws.workingDirectory = projectA
        ws.customTitle = "Scroll\nfix"
        ws.worktreeBranch = "topic\nbranch"

        XCTAssertEqual(ws.sidebarTooltip(agents: []),
                       "Scroll fix\nbranch topic branch\n/tmp/projectA",
                       "a newline inside a value must not become a tooltip line")
    }

    // MARK: - Workspace tag (issue #43)

    /// The tag is the only mark on the row the user placed themselves, so it
    /// has to outlive a relaunch — a marker you have to reapply every launch
    /// is worse than none.
    /// Serializes for real on the way through. `InMemoryPersistence` hands the
    /// struct straight back, and `PersistedWorkspace` hand-rolls its Codable
    /// conformance across three places (CodingKeys, encode, init(from:)) — so a
    /// field can live on the struct, pass an in-memory round trip, and still
    /// never reach disk.
    private func tagAfterRelaunch(setting tag: WorkspaceTag) throws -> WorkspaceTag? {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence: persistence)
        store.setTag(tag, for: try XCTUnwrap(store.active))
        store.flushPersistence()

        let data = try JSONEncoder().encode(try XCTUnwrap(persistence.saved))
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        return makeStore(initial: decoded).active?.tag
    }

    func testColorTagSurvivesAPersistenceRoundTrip() throws {
        XCTAssertEqual(try tagAfterRelaunch(setting: WorkspaceTag(preset: .purple)),
                       WorkspaceTag(preset: .purple))
    }

    /// Setting and clearing a tag both take effect. (The swatch strip's
    /// "clicking the lit swatch clears it" gesture is a private View and isn't
    /// covered here — this pins the store side only, which is what the name
    /// used to overclaim.)
    func testSetTagSetsAndClears() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }

        store.setTag(WorkspaceTag(preset: .red), for: ws)
        XCTAssertEqual(ws.tag?.colorHex, WorkspaceColorTag.red.hex)
        store.setTag(nil, for: ws)
        XCTAssertNil(ws.tag)
    }

    /// Opening the editor on a preset tag and saving without touching the
    /// colour well must keep it a preset. Seeding the picker from the existing
    /// tag round-trips the preset's own hex back out, so a name-only edit would
    /// otherwise convert it — and the strip would then show that preset's
    /// swatch unselected next to an identical-looking custom one.
    func testNamingAPresetTagKeepsItAPreset() {
        // Editor opened on the red preset, colour well untouched, name added.
        let named = WorkspaceTag.edited(seededPreset: .red,
                                        pickedHex: WorkspaceColorTag.red.hex,
                                        name: "urgent")
        XCTAssertEqual(named.color, .preset(.red),
                       "the strip must still light the preset swatch, not add a custom one")
        XCTAssertEqual(named.name, "urgent")

        // Actually moving the well away makes it the user's own colour…
        let picked = WorkspaceTag.edited(seededPreset: .red, pickedHex: "123456", name: nil)
        XCTAssertEqual(picked.color, .custom(hex: "123456"))

        // …and so does picking a preset's exact colour with no preset seeded,
        // which is the identity rule the whole model exists to protect.
        let deliberate = WorkspaceTag.edited(seededPreset: nil,
                                             pickedHex: WorkspaceColorTag.red.hex,
                                             name: nil)
        XCTAssertNil(deliberate.color.preset)
    }

    /// A named tag adds a `#name` line to the row's hover text — the stripe can
    /// show the colour but never what the user meant by it.
    func testNamedTagAddsAHashLineToTheTooltip() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        ws.workingDirectory = projectA
        store.setTag(WorkspaceTag(color: .custom(hex: "FF8800"), name: "urgent"), for: ws)

        XCTAssertEqual(ws.sidebarTooltip(agents: []), "projectA\n#urgent\n/tmp/projectA")

        // An unnamed tag is colour only — nothing to say, so no line.
        store.setTag(WorkspaceTag(preset: .red), for: ws)
        XCTAssertEqual(ws.sidebarTooltip(agents: []), "projectA\n/tmp/projectA")
    }

    /// The tooltip renders the `#` itself, so a name the user typed with one
    /// must not come back as `##urgent`. Blank-after-trimming clears the name
    /// rather than storing an empty string.
    func testTagNameIsNormalizedOnTheWayIn() {
        XCTAssertEqual(WorkspaceTag(color: .custom(hex: "FF8800"), name: "#urgent").name, "urgent")
        XCTAssertEqual(WorkspaceTag(color: .custom(hex: "FF8800"), name: "  ## release  ").name, "release")
        XCTAssertNil(WorkspaceTag(color: .custom(hex: "FF8800"), name: "   ").name)
        XCTAssertNil(WorkspaceTag(color: .custom(hex: "FF8800"), name: "#").name)
        // Interior newlines would otherwise add a tooltip line of their own.
        XCTAssertEqual(WorkspaceTag(color: .custom(hex: "FF8800"), name: "two\nlines").name, "two lines")
    }

    /// A custom colour has to survive as its own hex, and still be clearable —
    /// the strip lights an extra swatch for it precisely because it matches no
    /// preset.
    /// A colour the user picked stays theirs even when it exactly equals a
    /// preset — otherwise their named tag silently turns into a swatch
    /// selection they never made, and the strip stops offering it as custom.
    func testAPickedColorStaysCustomEvenWhenItEqualsAPreset() throws {
        let picked = WorkspaceTag(color: .custom(hex: WorkspaceColorTag.red.hex), name: "urgent")
        XCTAssertNil(picked.color.preset, "a picked colour is never a preset selection")
        XCTAssertEqual(picked.colorHex, WorkspaceColorTag.red.hex, "but it still renders that colour")
        XCTAssertEqual(WorkspaceTag(preset: .green).color.preset, .green)

        // And it has to survive the wire as custom. Storing only the colour and
        // re-deriving the origin on load is the bug this whole shape exists to
        // prevent, and that regression can only be seen through persistence.
        let restored = try tagAfterRelaunch(setting: picked)
        XCTAssertEqual(restored, picked)
        XCTAssertNil(restored?.color.preset,
                     "restoring must not turn the user's own colour into a preset")
    }

    /// A tag written by a future kooky must degrade to "untagged" rather than
    /// failing the decode — one unknown string should never cost the user every
    /// window, workspace, and tab in `state.json`.
    func testMalformedTagColorStillRestoresTheWorkspace() throws {
        let tab = PersistedTab(id: UUID(), agentId: "terminal", currentDirectoryPath: projectA.path)
        let pane = PersistedPane(id: UUID(), tabs: [tab], activeTabId: tab.id)
        let workspace = PersistedWorkspace(
            id: UUID(),
            workingDirectoryPath: projectA.path,
            root: PersistedPaneNode(id: pane.id, kind: .pane(pane)),
            tagCustomHex: "not-a-color"
        )
        let persisted = PersistedState(workspaces: [workspace], activeWorkspaceId: workspace.id)
        // Round-trip through JSON so the decoder actually sees the raw value.
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        let store = WorkspaceStore(persistence: InMemoryPersistence(initial: decoded),
                                   engineFactory: { TestEngine() },
                                   optionsProvider: { _ in nil }, resumeProvider: { true })

        XCTAssertEqual(store.workspaces.count, 1, "the workspace must still restore")
        // The tag survives as data; only its unusable colour degrades — the
        // stripe falls back to gray rather than the restore failing.
        XCTAssertEqual(store.workspaces.first?.tag?.colorHex, "not-a-color")
        XCTAssertEqual(store.workspaces.first?.tag?.swatchColor, Color(hex: WorkspaceColorTag.gray.hex))
    }

    /// LOCKED WIRE FORMAT. These three key names and the preset raw values live
    /// in every user's `state.json`. Rename one and their tags vanish silently:
    /// the field stops decoding, the workspace restores untagged, and the next
    /// save overwrites the old value — no error, nothing to recover from. This
    /// happened twice during development, which is why it is pinned here.
    /// Adding keys or preset cases is safe; renaming needs a migration.
    func testPersistedTagKeysAreALockedWireFormat() throws {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence: persistence)
        let ws = try XCTUnwrap(store.active)
        store.setTag(WorkspaceTag(color: .custom(hex: "123456"), name: "urgent"), for: ws)
        store.flushPersistence()

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(try XCTUnwrap(persistence.saved))
            ) as? [String: Any]
        )
        let workspaces = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        let encoded = try XCTUnwrap(workspaces.first)

        XCTAssertEqual(encoded["tagCustomHex"] as? String, "123456")
        XCTAssertEqual(encoded["tagName"] as? String, "urgent")
        XCTAssertNil(encoded["tagPreset"], "a picked colour must not also write a preset")

        store.setTag(WorkspaceTag(preset: .purple), for: ws)
        store.flushPersistence()
        let presetJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(try XCTUnwrap(persistence.saved))
            ) as? [String: Any]
        )
        let presetWs = try XCTUnwrap((presetJSON["workspaces"] as? [[String: Any]])?.first)
        XCTAssertEqual(presetWs["tagPreset"] as? String, "purple")
        XCTAssertNil(presetWs["tagCustomHex"], "a preset must not also write a hex")

        // The preset raw values themselves are wire format.
        XCTAssertEqual(WorkspaceColorTag.allCases.map(\.rawValue),
                       ["red", "orange", "yellow", "green", "blue", "purple", "gray"])
    }

    /// A hand-edited `#ff8800` and a picked `FF8800` are the same tag, so the
    /// swatch toggle (which compares whole tags) has to agree.
    func testCustomHexIsNormalizedSoEqualTagsCompareEqual() {
        XCTAssertEqual(WorkspaceTag(color: .custom(hex: "#ff8800")),
                       WorkspaceTag(color: .custom(hex: "FF8800")))
        XCTAssertEqual(WorkspaceTag(color: .custom(hex: " #ff8800 ")).colorHex, "FF8800")
        // Not a colour: kept as-is so the tag stays visible and clearable.
        XCTAssertEqual(WorkspaceTag(color: .custom(hex: "nope")).colorHex, "nope")
    }

    // MARK: - Agent panel row (issue #43)

    private func agentEntry(
        tabTitle: String,
        directory: URL,
        remoteHost: String? = nil,
        agent: AgentTemplate = .claudeCode,
        tag: WorkspaceTag? = nil
    ) -> AgentMonitor.Entry {
        AgentMonitor.Entry(id: UUID(), agent: agent, state: .running,
                           tabTitle: tabTitle, directory: directory, remoteHost: remoteHost, tag: tag)
    }

    /// The panel repeats the workspace's tag so one marker means one thing in
    /// both sidebars — and the toggle has to silence the name as well as the
    /// stripe, or turning tags off leaves half of one in the hover.
    func testAgentPanelHoverCarriesTheWorkspaceTagOnlyWhenTagsAreShown() {
        let entry = agentEntry(tabTitle: "Fixing scroll", directory: projectA,
                               tag: WorkspaceTag(color: .custom(hex: "123456"), name: "urgent"))

        XCTAssertEqual(entry.hoverText(tag: entry.tag),
                       "Claude Code · Fixing scroll · running\n#urgent\n/tmp/projectA")
        XCTAssertEqual(entry.hoverText(tag: nil),
                       "Claude Code · Fixing scroll · running\n/tmp/projectA")
    }

    /// Every agent in one workspace inherits that workspace's tag — the stripe
    /// groups the panel by project, which is the only project signal a list
    /// sorted purely by state has.
    func testEveryAgentInAWorkspaceCarriesItsTag() {
        let store = makeStore()
        guard let ws = store.active else { return XCTFail("expected a seed workspace") }
        store.setTag(WorkspaceTag(preset: .purple), for: ws)
        _ = store.addTab(in: ws, template: .claudeCode)
        _ = store.addTab(in: ws, template: .codex)

        let monitor = AgentMonitor()
        monitor.storesProvider = { [store] }
        let tags = monitor.entries.map(\.tag)

        XCTAssertEqual(tags.count, 2)
        XCTAssertTrue(tags.allSatisfy { $0 == WorkspaceTag(preset: .purple) })
    }

    /// An agent reached over SSH runs somewhere this machine can't name:
    /// libghostty drops OSC 7 from a non-local host, so the session's cwd is
    /// still the LOCAL directory the connection was opened from. Naming that
    /// directory would point at the wrong machine.
    func testAgentEntryNamesTheRemoteHostInsteadOfTheLocalPath() {
        let entry = agentEntry(tabTitle: "deploy", directory: projectA, remoteHost: "corey@prod")

        XCTAssertEqual(entry.locationPathLabel, "ssh corey@prod")
        XCTAssertEqual(entry.locationLabel, "ssh corey@prod")
        XCTAssertFalse(entry.hoverText(tag: entry.tag).contains("/tmp/projectA"),
                       "a local path must not appear anywhere on a remote row")
    }

    /// A session with no reported title is named after its own directory, so
    /// the location line would repeat line 1 — in `$HOME` both sides even
    /// render as the same single `~`. Naming the agent is the one fact the row
    /// is otherwise missing, since it carries the agent only as an icon.
    func testAgentEntryFallsBackToTheAgentNameWhenTheLocationWouldRepeat() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let homeEntry = agentEntry(tabTitle: "~", directory: home)
        XCTAssertEqual(homeEntry.locationPathLabel, "~")
        XCTAssertEqual(homeEntry.locationLabel, "Claude Code")

        // The ordinary case is untouched: a real title over a real path.
        XCTAssertEqual(agentEntry(tabTitle: "Fixing scroll", directory: projectA).locationLabel,
                       "/tmp/projectA")
    }

    /// Both row shapes share this string, and the compact rail has nothing
    /// else — so it has to carry the agent, the tab, the state, and where it
    /// is running, on a stable two-line shape.
    func testAgentEntryHoverTextCarriesEveryFieldTheRowCannot() {
        let entry = agentEntry(tabTitle: "Fixing scroll", directory: projectA)

        XCTAssertEqual(entry.hoverText(tag: entry.tag), "Claude Code · Fixing scroll · running\n/tmp/projectA")
    }

}

private extension PersistedPaneNode {
    /// Recursive flatten used by tests to assert per-tab persisted fields
    /// without re-implementing the pane-tree walker.
    var allTabs: [PersistedTab] {
        switch kind {
        case .pane(let p): return p.tabs
        case .split(_, let a, let b, _): return a.allTabs + b.allTabs
        }
    }
}

// MARK: - Git watcher hub

extension WorkspaceStoreTests {
    /// Real `git init` fixture — the hub keys on the RESOLVED gitdir, so a
    /// plain directory can't exercise subscribe/unsubscribe at all.
    private func makeGitRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-hub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try XCTSkipUnless(
            GitStatusFetcher.runGit(["-C", repo.path, "init", "-q"], timeout: 10) != nil,
            "git unavailable"
        )
        return repo
    }

    /// Baselines are relative: the seed workspace (home cwd) may or may not
    /// resolve to a repo on the machine running the tests.
    func testSameRepoTabsShareOneGitWatcher() throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = makeStore()
        let base = store.gitWatchHubStats

        let ws = store.addWorkspace(workingDirectory: repo)
        store.addTab(in: ws)
        store.addTab(in: ws)
        XCTAssertEqual(store.gitWatchHubStats.watchers, base.watchers + 1,
                       "three same-repo tabs must share ONE kqueue watcher")
        XCTAssertEqual(store.gitWatchHubStats.subscriptions, base.subscriptions + 3)

        let pane = firstPane(ws)
        store.closeTab(pane.tabs[0], in: ws)
        XCTAssertEqual(store.gitWatchHubStats.watchers, base.watchers + 1,
                       "the shared watcher survives while any subscriber remains")
        XCTAssertEqual(store.gitWatchHubStats.subscriptions, base.subscriptions + 2)
    }

    func testSameRepoTabSpawnMergesGitStatusFetches() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = makeStore()
        let baseline = store.gitStatusDispatchCount

        let ws = store.addWorkspace(workingDirectory: repo)
        store.addTab(in: ws)
        store.addTab(in: ws)

        XCTAssertEqual(store.gitStatusDispatchCount, baseline,
                       "the shared repo refresh should remain queued while tabs join")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(store.gitStatusDispatchCount, baseline + 1,
                       "three same-repo tabs must dispatch one shared git status batch")
    }

    func testDiffSnapshotInvalidatesOnlyTheClickedSessionLane() throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = makeStore()
        let workspace = store.addWorkspace(workingDirectory: repo)
        let session = try XCTUnwrap(workspace.activeSession)
        session.gitStatus = GitStatus(
            branch: "main",
            repoRoot: repo.path,
            filesChanged: 1,
            insertions: 1,
            deletions: 0
        )
        let before = store.gitStatusLaneTokens(for: session)

        store.applyDiffSnapshot(
            GitDiffSnapshot(
                repoRoot: repo.path,
                entries: [GitDiffFileEntry(path: "changed.swift", insertions: 2, deletions: 1)]
            ),
            for: session,
            cwdPath: repo.path
        )

        let after = store.gitStatusLaneTokens(for: session)
        XCTAssertEqual(after.session, before.session + 1)
        XCTAssertEqual(after.shared, before.shared,
                       "a local snapshot must not cancel the repo-wide broadcast")
    }

    func testCdAcrossRepoBoundaryMovesTheSubscription() throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = makeStore()
        let base = store.gitWatchHubStats

        let ws = store.addWorkspace(workingDirectory: repo)
        guard let session = ws.activeSession else { return XCTFail("no session") }
        XCTAssertEqual(store.gitWatchHubStats.watchers, base.watchers + 1)

        engine(session).emitPwd(projectB.path)
        XCTAssertEqual(store.gitWatchHubStats.watchers, base.watchers,
                       "last subscriber cd'd out of the repo — the shared watcher must tear down")

        engine(session).emitPwd(repo.path)
        XCTAssertEqual(store.gitWatchHubStats.watchers, base.watchers + 1,
                       "cd back in re-subscribes and re-creates the watcher")
    }

    func testDistinctReposGetDistinctWatchers() throws {
        let repoA = try makeGitRepo()
        let repoB = try makeGitRepo()
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }
        let store = makeStore()
        let base = store.gitWatchHubStats

        store.addWorkspace(workingDirectory: repoA)
        store.addWorkspace(workingDirectory: repoB)
        XCTAssertEqual(store.gitWatchHubStats.watchers, base.watchers + 2,
                       "different gitdirs never share a watcher")
        XCTAssertEqual(store.gitWatchHubStats.subscriptions, base.subscriptions + 2)
    }

    // MARK: seed tab of a window built to serve one request

    /// A window created for a single `kooky-cli open` / `kooky://resume` is
    /// born with a tab; the request then lands its own beside it. The seed
    /// is a byproduct the caller never hears about, so it goes.
    func testDiscardSeedTabDropsTheBornWithTabAndKeepsTheRequestedOne() throws {
        let store = makeStore()
        let workspace = store.workspaces[0]
        let seed = try XCTUnwrap(workspace.activeSession)
        let wanted = store.addTab(in: workspace)

        store.discardSeedTab(keeping: wanted)

        let tabs = workspace.root.allPanes.flatMap(\.tabs)
        XCTAssertEqual(tabs.map(\.id), [wanted.id])
        XCTAssertFalse(tabs.contains { $0.id == seed.id })
    }

    /// The half that matters more: the shape gate. Callers learn "I built
    /// this window" from the window layer, which has a narrow window where
    /// it can hand back a controller whose window is already closing — so
    /// anything that is not a newborn's exact shape must be left alone
    /// rather than have a real session closed out from under the user.
    func testDiscardSeedTabLeavesAnythingThatIsNotANewbornAlone() throws {
        let store = makeStore()
        let workspace = store.workspaces[0]
        let wanted = store.addTab(in: workspace)
        store.addTab(in: workspace)   // a third tab — not a newborn any more
        XCTAssertEqual(workspace.root.allPanes.flatMap(\.tabs).count, 3)

        store.discardSeedTab(keeping: wanted)
        XCTAssertEqual(workspace.root.allPanes.flatMap(\.tabs).count, 3, "too many tabs to be a window we just built")

        // Two tabs but a second workspace: still not a newborn.
        let second = makeStore()
        let secondWorkspace = second.workspaces[0]
        let secondWanted = second.addTab(in: secondWorkspace)
        second.addWorkspace(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        second.discardSeedTab(keeping: secondWanted)
        XCTAssertEqual(
            secondWorkspace.root.allPanes.flatMap(\.tabs).count, 2,
            "more than one workspace means this store was not born for this request"
        )
    }

    /// A refused resume must leave NOTHING behind. Before this, the tab was
    /// spawned first and the missing resume id noticed after — so a caller
    /// got a failure AND a tab quietly running a fresh conversation, and a
    /// retrying script stacked one more every time.
    func testRefusedResumeSpawnsNoTab() {
        let store = WorkspaceStore(
            persistence: InMemoryPersistence(),
            engineFactory: { TestEngine() },
            // Claude with session persistence switched off in launch options:
            // the resume id would be dropped downstream.
            optionsProvider: { _ in "--no-session-persistence" },
            resumeProvider: { true }
        )
        let before = store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count

        let outcome = store.resumeAgentSession(
            agentId: AgentTemplate.claudeCode.id,
            conversationId: UUID().uuidString,
            cwd: URL(fileURLWithPath: NSTemporaryDirectory())
        )

        guard case .failure(let refusal) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(refusal, .launchOptionsDisablePersistence)
        XCTAssertEqual(
            store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count, before,
            "a refusal must not leave a session behind"
        )
    }

    /// A caller that already verified the directory must get THAT directory
    /// — never a silent substitution. `kooky-cli open -e "make"` relocated
    /// to $HOME would run the build in the wrong place and still report
    /// success, which is worse than any failure.
    func testConfirmedCwdIsNotSecondGuessedIntoHome() {
        let store = makeStore()
        // A path that no longer exists: the unconfirmed path would swap in
        // $HOME here, which is exactly what a verified caller must not get.
        let vanished = URL(fileURLWithPath: "/tmp/kooky-vanished-\(UUID().uuidString)")

        let confirmed = store.localSpawn(template: .terminal, cwd: vanished, cwdIsConfirmed: true)
        XCTAssertEqual(
            confirmed.session.currentDirectory.path, vanished.path,
            "a confirmed cwd must reach the spawn untouched"
        )

        let probed = store.localSpawn(template: .terminal, cwd: vanished)
        XCTAssertEqual(
            probed.session.currentDirectory.path, NSHomeDirectory(),
            "without confirmation the $HOME fallback still applies (resume relies on it)"
        )
    }

    /// The deep-link / CLI paths ask this BEFORE building a window, so it
    /// has to answer without a store.
    func testResumeRefusalDecidesWithoutAStore() {
        let id = UUID().uuidString
        XCTAssertEqual(
            WorkspaceStore.resumeRefusal(agentId: "no-such-agent", conversationId: id, options: { _ in nil }),
            .agentCannotResume
        )
        XCTAssertEqual(
            WorkspaceStore.resumeRefusal(
                agentId: AgentTemplate.claudeCode.id, conversationId: id,
                options: { _ in "--no-session-persistence" }
            ),
            .launchOptionsDisablePersistence
        )
        XCTAssertNil(
            WorkspaceStore.resumeRefusal(
                agentId: AgentTemplate.claudeCode.id, conversationId: id, options: { _ in nil }
            )
        )
    }

    func testResumeSucceedsWhenPersistenceIsOn() throws {
        let store = makeStore()
        let outcome = store.resumeAgentSession(
            agentId: AgentTemplate.claudeCode.id,
            conversationId: UUID().uuidString,
            cwd: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let session = try XCTUnwrap(try? outcome.get())
        XCTAssertNotNil(session.resumedConversationId, "the id must survive to the command line")
    }

    /// The flag the CLI and deep-link entry points filter on. A window's
    /// controller is dropped only on the NEXT main-queue tick (releasing an
    /// NSWindow inside windowWillClose crashes AppKit), so for one tick a
    /// terminated store is still reachable from `windowControllers` — and
    /// spawning into it would report success for a tab about to vanish.
    func testTerminateMarksTheStoreSoOutsideCallersCanSkipIt() {
        let store = makeStore()
        XCTAssertFalse(store.isTerminated)
        store.terminate()
        XCTAssertTrue(store.isTerminated)
    }

    /// `discardTab`, not `closeTab` — the seed is synthetic, so ⌘⇧T must not
    /// offer to reopen a tab the user never opened or closed.
    func testDiscardedSeedTabDoesNotEnterTheReopenStack() throws {
        let store = makeStore()
        let workspace = store.workspaces[0]
        let wanted = store.addTab(in: workspace)
        let reopenableBefore = store.canReopenClosedTab

        store.discardSeedTab(keeping: wanted)
        XCTAssertEqual(store.canReopenClosedTab, reopenableBefore)
    }
}
