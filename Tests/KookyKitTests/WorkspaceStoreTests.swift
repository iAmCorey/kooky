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

    private func makeStore(initial: PersistedState? = nil) -> WorkspaceStore {
        WorkspaceStore(
            persistence: InMemoryPersistence(initial: initial),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
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
        // foundation — `activateWorkspace` must never reset `activePaneId`; the
        // view layer's per-pane `grabsFocusOnMount` gate then makes the on-screen
        // keyboard focus follow it instead of racing to the last-mounted surface.
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

    func testCreateSSHSessionStartsSSHAndMarksWorkspaceRemote() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)

        guard let session = store.createSSHSession(in: ws, remoteHost: "deploy@example.com") else {
            return XCTFail("expected ssh session")
        }

        XCTAssertEqual(ws.sshRemoteHost, "deploy@example.com")
        XCTAssertEqual(engine(session).startedConfigs.last?.environment["KOOKY_AGENT"], "kooky-ssh 'deploy@example.com'")
    }

    func testAddWorkspaceWithSSHRemoteHostStartsFirstTabOverSSH() {
        let store = makeStore()

        let ws = store.addWorkspace(workingDirectory: projectA, sshRemoteHost: "deploy@example.com")

        guard let session = ws.activeSession else { return XCTFail("expected initial session") }
        XCTAssertEqual(ws.sshRemoteHost, "deploy@example.com")
        XCTAssertEqual(engine(session).startedConfigs.last?.environment["KOOKY_AGENT"], "kooky-ssh 'deploy@example.com'")
    }

    func testRemoteLoginMarkerDoesNotPromoteWorkspaceToSSH() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let first = firstPane(ws).tabs[0]

        engine(first).emitTitle("\(RemoteLoginMarker.titlePrefix)deploy@example.com")
        let second = store.addTab(in: ws, template: .terminal)

        XCTAssertNil(first.remoteHost)
        XCTAssertNil(ws.sshRemoteHost)
        XCTAssertNil(engine(second).startedConfigs.last?.environment["KOOKY_AGENT"])
    }

    func testRemoteWorkspaceLaunchesAgentsThroughSSHBootstrap() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        ws.sshRemoteHost = "deploy@example.com"

        let session = store.addTab(in: ws, template: .claudeCode)

        XCTAssertEqual(engine(session).startedConfigs.last?.environment["KOOKY_AGENT"], "kooky-ssh 'deploy@example.com' -- claude")
        XCTAssertNil(engine(session).startedConfigs.last?.environment["KOOKY_SSH_REMOTE_AGENT"])
    }

    func testRemoteWorkspaceSplitStartsSSHForShellTabs() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        ws.sshRemoteHost = "deploy@example.com"
        let pane = firstPane(ws)

        guard let newPane = store.splitPane(pane, orientation: .horizontal, in: ws),
              let session = newPane.activeTab
        else { return XCTFail("expected split pane") }

        XCTAssertEqual(engine(session).startedConfigs.last?.environment["KOOKY_AGENT"], "kooky-ssh 'deploy@example.com'")
    }

    func testRestoreRemoteWorkspaceStartsShellTabsOverSSH() {
        let tab = PersistedTab(
            id: UUID(),
            agentId: AgentTemplate.terminal.id,
            currentDirectoryPath: projectA.path
        )
        let pane = PersistedPane(id: UUID(), tabs: [tab], activeTabId: tab.id)
        let root = PersistedPaneNode(id: pane.id, kind: .pane(pane))
        let workspace = PersistedWorkspace(
            id: UUID(),
            workingDirectoryPath: projectA.path,
            root: root,
            activePaneId: pane.id,
            sshRemoteHost: "deploy@example.com"
        )
        let store = makeStore(initial: PersistedState(workspaces: [workspace], activeWorkspaceId: workspace.id))

        guard let session = store.workspaces.first?.activeSession else {
            return XCTFail("expected restored session")
        }

        XCTAssertEqual(store.workspaces.first?.sshRemoteHost, "deploy@example.com")
        XCTAssertEqual(engine(session).startedConfigs.last?.environment["KOOKY_AGENT"], "kooky-ssh 'deploy@example.com'")
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

        let reopened = store.reopenLastClosedTab()
        let pane = firstPane(ws)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(reopened?.agent.id, "claude-code")
        XCTAssertEqual(reopened?.currentDirectory.path, projectB.path)
        XCTAssertEqual(reopened?.customTitle, "release prep")
        XCTAssertEqual(pane.activeTabId, reopened?.id)
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

    func testToggleZoomSuspendsSizePropagationDuringAnimation() {
        // The animation window must skip per-frame `set_size` propagation
        // — otherwise each animation frame fires its own SIGWINCH burst
        // (the documented conda-init scrollback-wipe path). Verifies the
        // flag is set immediately after toggle; the async restore lives
        // on a 0.25s delay we don't wait for here.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let paneA = firstPane(ws)
        guard let paneB = store.splitPane(paneA, orientation: .horizontal, in: ws) else {
            return XCTFail("split failed")
        }
        let engineA = engine(paneA.tabs[0])
        let engineB = engine(paneB.tabs[0])
        XCTAssertFalse(engineA.suspendsSizePropagation)
        XCTAssertFalse(engineB.suspendsSizePropagation)
        store.toggleZoom(in: ws, paneId: paneA.id)
        XCTAssertTrue(engineA.suspendsSizePropagation, "every engine in the workspace gets suspended")
        XCTAssertTrue(engineB.suspendsSizePropagation)
    }

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
