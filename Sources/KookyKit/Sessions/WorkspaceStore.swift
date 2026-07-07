import Foundation

extension Array {
    /// Step `direction` from `current`, wrapping at both ends. Used by tab
    /// and pane cycling. Direction can be any non-zero `Int`; positive walks
    /// forward, negative walks backward. Returns 0 for an empty array so
    /// callers can index without bounds checks (subscripting into an empty
    /// array would still trap, so guard `!isEmpty` before subscripting).
    func cyclicIndex(from current: Int, step direction: Int) -> Int {
        guard !isEmpty else { return 0 }
        return ((current + direction) % count + count) % count
    }
}

/// True iff `url` points at a directory that currently exists on disk.
func isDirectory(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

/// Returns `path` as a directory URL if it exists, otherwise the user's
/// home dir. The fallback prevents kooky from spawning a shell at a deleted
/// project path (deleted between sessions, externally unmounted disk),
/// which manifests as the new tab dying with a confusing one-line error.
func resolvedSpawnCwd(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    return isDirectory(url) ? url : URL(fileURLWithPath: NSHomeDirectory())
}

/// Trims a title string; blank or whitespace-only input collapses to `nil`.
/// Shared by the manual-rename paths and the OSC-title observer so "empty
/// means no title" stays one rule.
func normalizedTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Three-state sidebar visibility. `next` cycles full → compact → hidden →
/// full so each toggle hides more and eventually wraps around.
enum SidebarMode: String, Codable, Equatable, Sendable {
    case full
    case compact
    case hidden

    var next: SidebarMode {
        switch self {
        case .full: return .compact
        case .compact: return .hidden
        case .hidden: return .full
        }
    }
}

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceId: UUID?
    /// Session id currently being dragged in any pane's tab bar. Shared across
    /// all `TabBarView` instances so target panes can show drop indicators
    /// even when the source lives in a different pane.
    var draggingTabId: UUID?
    var sidebarMode: SidebarMode = .full
    /// Right-side agent-overview sidebar — per-window collapse state, sharing
    /// the left sidebar's three modes (full / compact / hidden). The content is
    /// the global `AgentMonitor`; each window toggles its own panel. Defaults
    /// to hidden since it's opt-in.
    var rightSidebarMode: SidebarMode = .hidden
    /// Fired when the last workspace closes. `KookyWindowController` wires
    /// this to close its window — a window with zero workspaces is empty.
    var onBecameEmpty: (() -> Void)?

    /// Mutate + schedule save. UI sites wrap in `withAnimation(Theme.chromeTransition)`,
    /// which animates the terminal area's width → per-frame `setFrameSize` on every
    /// surface. Suspend size propagation for the animation (same as pane zoom) so
    /// that burst doesn't SIGWINCH-wipe conda scrollback / flicker the terminal
    /// (issue #29). Gated on a real mode change above, so no-op sets don't suspend.
    func setSidebarMode(_ mode: SidebarMode) {
        guard sidebarMode != mode else { return }
        suspendSizePropagationForLayoutAnimation(active?.root.allPanes.flatMap { $0.tabs }.map(\.engine) ?? [])
        sidebarMode = mode
        scheduleSave()
    }

    func setRightSidebarMode(_ mode: SidebarMode) {
        guard rightSidebarMode != mode else { return }
        suspendSizePropagationForLayoutAnimation(active?.root.allPanes.flatMap { $0.tabs }.map(\.engine) ?? [])
        rightSidebarMode = mode
        scheduleSave()
    }

    /// Open the rename popover on the active tab (⌘R). Sets a runtime flag the
    /// active `TabBarItem` observes; the active tab is always present in its
    /// pane's tab bar, so the popover can anchor.
    func requestRenameActiveTab() {
        active?.activeSession?.renameRequested = true
    }

    /// Open the rename popover on the active workspace's sidebar row (⌘⇧R).
    /// Parks the request for `SidebarView` to handle — the active row may be
    /// unmounted (collapsed worktree parent, or scrolled out of the
    /// `LazyVStack`), so the sidebar expands/scrolls it into view before
    /// handing off to the row via `Workspace.renameRequested`. Reveal a hidden
    /// sidebar first so `SidebarView` exists to observe the parked request.
    func requestRenameActiveWorkspace() {
        if sidebarMode == .hidden { setSidebarMode(.full) }
        pendingRenameWorkspace = active
    }

    private let engineFactory: @MainActor () -> any TerminalEngine
    /// Resolves per-agent launch options at spawn time. Production wires this
    /// to `KookySettingsModel.shared.agentOptions[id]`; tests pass a closure
    /// that returns nil so unit tests stay independent of the developer's
    /// real `~/.kooky/settings.json`.
    private let optionsProvider: @MainActor (String) -> String?
    /// Reads `KookySettingsModel.shared.resumeConversations` at spawn time;
    /// tests inject a static value (typically `true`) for the same reason
    /// as `optionsProvider`.
    private let resumeProvider: @MainActor () -> Bool
    /// Every live window's store (including this one) — injected by
    /// `AppDelegate` so a tab dropped here from another window can be located
    /// in the store it came from. Tests default to `{ [] }`, keeping each
    /// store window-isolated.
    private let peerStores: @MainActor () -> [WorkspaceStore]
    /// Invoked when the user picks "Move to New Window" from a tab's
    /// right-click menu — `AppDelegate` opens a fresh window and moves the
    /// session into it. Tests default to a no-op.
    private let moveToNewWindow: @MainActor (UUID) -> Void
    /// Fired when a session enters an attention (waiting-on-you) state or a
    /// command there fails. `AppDelegate` decides whether to surface a system
    /// notification — only when the originating tab isn't currently visible.
    /// Tests default to a no-op.
    private let onSessionAlert: @MainActor (UUID, SessionAlertKind) -> Void
    private let persistence: any Persistence
    private let gitStatusFetcher = GitStatusFetcher()
    /// One watcher per session — refreshes git status when `.git/HEAD` or
    /// `.git/index` changes from any source (agent subprocess, external
    /// terminal, file-level git ops). The OSC 7 / OSC 133 paths only see
    /// the outer shell, so an agent running its own subprocess shell never
    /// trips them; the filesystem layer catches everyone.
    private var gitWatchers: [UUID: GitWatcher] = [:]
    /// Watches each Codex session's rollout file and republishes its latest
    /// rate-limit usage to `Session.codexUsage` for the status-bar gauge.
    /// Codex blocks the shell while running, so the file is the only live
    /// signal — torn down alongside `gitWatchers` at every close site.
    private let codexUsageMonitor = CodexUsageMonitor()

    /// Snapshot of a closed tab's reopenable state. Workspace + pane IDs
    /// are best-effort routing — if either is gone by the time the user
    /// hits ⌘⇧T, `reopenLastClosedTab` falls back to the active workspace
    /// / pane.
    private struct ClosedTabState {
        let agent: AgentTemplate
        let cwd: URL
        let customTitle: String?
        let workspaceId: UUID
        let paneId: UUID
        /// Captured conversation id so `⌘⇧T` resumes the Claude session
        /// the user just closed (subject to `resumeConversations` setting).
        let conversationId: String?
    }

    /// LIFO stack of recently-closed tabs for ⌘⇧T (reopen). Capped at
    /// `closedTabHistoryLimit` so a long session doesn't unbounded-grow.
    /// Runtime-only — closed tabs do not survive an app restart.
    private var recentlyClosed: [ClosedTabState] = []
    private static let closedTabHistoryLimit = 50

    private var pendingSave: Task<Void, Never>?
    private static let saveDebounce: UInt64 = 1_000_000_000

    var active: Workspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    init(
        persistence: any Persistence,
        engineFactory: @escaping @MainActor () -> any TerminalEngine = { LibghosttyEngine() },
        optionsProvider: @escaping @MainActor (String) -> String? = { KookySettingsModel.shared.agentOptions[$0] },
        resumeProvider: @escaping @MainActor () -> Bool = { KookySettingsModel.shared.resumeConversations },
        peerStores: @escaping @MainActor () -> [WorkspaceStore] = { [] },
        moveToNewWindow: @escaping @MainActor (UUID) -> Void = { _ in },
        onSessionAlert: @escaping @MainActor (UUID, SessionAlertKind) -> Void = { _, _ in }
    ) {
        self.persistence = persistence
        self.engineFactory = engineFactory
        self.optionsProvider = optionsProvider
        self.resumeProvider = resumeProvider
        self.peerStores = peerStores
        self.moveToNewWindow = moveToNewWindow
        self.onSessionAlert = onSessionAlert
        if let saved = persistence.load(), !saved.workspaces.isEmpty {
            restore(from: saved)
        } else {
            addWorkspace()
        }
    }

    // MARK: - Workspaces

    @discardableResult
    func addWorkspace(
        workingDirectory: URL? = nil,
        worktreeParent: Workspace? = nil,
        worktreeBranch: String? = nil,
        template: AgentTemplate = .terminal,
        sshRemoteHost: String? = nil
    ) -> Workspace {
        let dir = workingDirectory
            ?? active?.workingDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let remoteHost = normalizedSSHRemoteHost(sshRemoteHost)
        let pane = Pane()
        let root = PaneNode(pane: pane)
        let workspace = Workspace(workingDirectory: dir, root: root)
        workspace.worktreeParentId = worktreeParent?.id
        workspace.worktreeBranch = worktreeBranch
        workspace.sshRemoteHost = remoteHost
        // Pin worktreePath at create time so `git worktree remove` always
        // targets the disk root, no matter where the user cd's later.
        // `.standardizedFileURL` resolves `/tmp` → `/private/tmp` etc. so
        // a later reconcile comparison against `git worktree list`
        // output (which is already realpath'd) lines up.
        if worktreeParent != nil {
            workspace.worktreePath = dir.standardizedFileURL
        }
        let session = spawnSession(
            template: template,
            initialCwd: dir,
            sshRemoteHost: sshRemoteHostForNewSession(remoteHost, template: template)
        )
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
        pane.tabs.append(session)
        pane.activeTabId = session.id
        // Worktrees insert right after their source (or after the source's
        // existing worktrees) — compact-mode sidebar walks `workspaces`
        // in array order, so this visual grouping is load-bearing there.
        if let parent = worktreeParent,
           let parentIdx = workspaces.firstIndex(where: { $0 === parent }) {
            var insertAt = parentIdx + 1
            while insertAt < workspaces.count
                  && workspaces[insertAt].worktreeParentId == parent.id {
                insertAt += 1
            }
            workspaces.insert(workspace, at: insertAt)
        } else {
            workspaces.append(workspace)
        }
        activeWorkspaceId = workspace.id
        scheduleSave()
        return workspace
    }

    /// Creates a git worktree of `source` and adds the resulting directory
    /// as a child workspace under it. `git worktree add` runs on a detached
    /// task so the SwiftUI sheet stays responsive; on failure the stderr
    /// goes back via the outcome so the sheet shows it inline.
    func createWorktree(
        source: Workspace,
        request: CreateWorktreeSheet.Request
    ) async -> CreateWorktreeSheet.CreateOutcome {
        switch request.kind {
        case .create(let mode, let path, let branchForDisplay):
            guard let repoPath = WorktreeManager.repoRoot(near: source.workingDirectory) else {
                return .failure("not inside a git repository")
            }
            let result = await Task.detached(priority: .userInitiated) {
                WorktreeManager.add(repoPath: repoPath, path: path, mode: mode)
            }.value
            if case .failure(let err) = result {
                return .failure(err.description)
            }
            addWorkspace(
                workingDirectory: path,
                worktreeParent: source,
                worktreeBranch: branchForDisplay,
                template: request.template
            )
            return .success
        case .adopt(let worktrees):
            // Pure sidebar materialization — no git command, the
            // directories already exist on disk. One workspace per
            // picked worktree, inserted after the source in array
            // order so sidebar grouping stays correct.
            for info in worktrees {
                addWorkspace(
                    workingDirectory: info.path,
                    worktreeParent: source,
                    worktreeBranch: info.branch,
                    template: request.template
                )
            }
            return .success
        }
    }

    /// Worktree workspaces close through this request first so the
    /// sidebar can pop the brutalist confirm sheet before anything
    /// destructive runs. Plain workspaces skip the prompt and go
    /// straight to `closeWorkspace`. Set non-nil to mean "user asked to
    /// close this worktree, sidebar please ask them about the dir";
    /// cleared by the sheet on dismiss / confirm.
    var pendingRemovalRequest: Workspace?

    /// Cross-view create request. Sidebar rows open the sheet directly, but
    /// global entry points such as the command palette need to ask the
    /// sidebar to host the sheet, especially when the sidebar was hidden and
    /// has to be shown first.
    var pendingCreateWorktreeRequest: Workspace?

    /// ⌘⇧R rename request, parked for `SidebarView` to act on. The active
    /// workspace's row may be unmounted — nested under a collapsed worktree
    /// parent, or scrolled out of the sidebar's `LazyVStack` — so the sidebar
    /// (not the store) has to expand/scroll it into view before the row's
    /// rename popover can anchor. Identity-keyed; cleared by the sidebar once
    /// handled.
    var pendingRenameWorkspace: Workspace?

    /// Payload for the "close source workspace, take its worktrees with
    /// it" confirm sheet. A source can't simply close on its own — its
    /// worktrees would either show as orphan rows (the sidebar fallback)
    /// or vanish silently. Either way the user's mental model breaks.
    struct CloseSourceRequest {
        let source: Workspace
        let worktrees: [Workspace]
    }

    /// Set when a top-level workspace with worktrees is being closed and
    /// the sidebar should pop the bulk confirm sheet. Plain top-level
    /// workspaces (no worktrees) close inline and never park here.
    var pendingCloseSourceRequest: CloseSourceRequest?

    /// UI-level close request. Callers from the sidebar (× button, right-
    /// click menu) and the ⌘⇧W menu item both funnel here so the
    /// confirm prompt only lives in one place.
    func requestCloseWorkspace(_ workspace: Workspace) {
        if workspace.worktreeParentId != nil {
            pendingRemovalRequest = workspace
            return
        }
        let worktrees = workspaces.filter { $0.worktreeParentId == workspace.id }
        if worktrees.isEmpty {
            closeWorkspace(workspace)
            return
        }
        pendingCloseSourceRequest = CloseSourceRequest(source: workspace, worktrees: worktrees)
    }

    /// Performs the deferred source-with-worktrees close from the sheet.
    /// `alsoDelete = true` runs `git worktree remove --force` + branch-d
    /// for each child before closing the source (the v0.18.x default
    /// behaviour, now opt-in via the sheet's checkbox). First failing
    /// git remove aborts and surfaces stderr. `alsoDelete = false` just
    /// drops the workspaces from the sidebar — disk untouched.
    func performCloseSource(_ request: CloseSourceRequest, alsoDelete: Bool) async -> String? {
        if alsoDelete {
            for worktree in request.worktrees {
                if let message = await removeWorktreeDirectory(worktree) {
                    return message
                }
            }
        }
        for worktree in request.worktrees { closeWorkspace(worktree) }
        closeWorkspace(request.source)
        pendingCloseSourceRequest = nil
        return nil
    }

    /// Zombie-clean sidebar worktree workspaces against `git worktree list`.
    /// Runs once at app launch (AppDelegate calls it after every window's
    /// store is restored). Only handles the *removal* side — a sidebar
    /// entry whose worktree directory was deleted from disk (e.g. CLI
    /// `git worktree remove` while kooky was closed) gets dropped.
    ///
    /// v0.19.0 removed the disk → sidebar adopt path: kooky no longer
    /// surfaces worktrees the user created via CLI or another tool. To
    /// see them, the user explicitly goes through Create Worktree →
    /// "adopt existing worktree" mode. Reasoning: v0.18.x's auto-adopt
    /// caused noisy sidebars + scared users into not closing entries
    /// (close was destructive then). state.json + user action is now
    /// the single source of truth for what kooky displays.
    ///
    /// Subprocess fan-out runs off the main actor in a TaskGroup so a
    /// user with N source repos doesn't pay N × ~100ms blocked on launch.
    /// Results apply back on the main actor in source order.
    func reconcileWorktrees() async {
        // Snapshot inputs on the main actor before hopping off — Workspace
        // is @MainActor so the closure can't touch its properties from
        // background tasks.
        let inputs: [(index: Int, sourceId: UUID, cwd: URL)] = workspaces.enumerated().compactMap { index, source in
            guard source.worktreeParentId == nil else { return nil }
            return (index, source.id, source.workingDirectory)
        }
        guard !inputs.isEmpty else { return }

        let results: [(index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])] = await withTaskGroup(
            of: (index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])?.self
        ) { group in
            for input in inputs {
                group.addTask {
                    guard let repoRoot = WorktreeManager.repoRoot(near: input.cwd),
                          case .success(let infos) = WorktreeManager.list(repoPath: repoRoot) else {
                        return nil
                    }
                    return (input.index, input.sourceId, repoRoot, infos)
                }
            }
            var collected: [(index: Int, sourceId: UUID, repoRoot: URL, infos: [WorktreeManager.Info])] = []
            for await result in group { if let result { collected.append(result) } }
            return collected.sorted { $0.index < $1.index }
        }

        for result in results {
            guard let source = workspaces.first(where: { $0.id == result.sourceId }) else { continue }
            reconcile(source: source, sourceRoot: result.repoRoot, diskWorktrees: result.infos)
        }
    }

    /// `internal` so tests can drive it with synthetic `diskWorktrees`
    /// without spinning up a real git repo. `reconcileWorktrees` is the
    /// production entry point.
    func reconcile(source: Workspace, sourceRoot: URL? = nil, diskWorktrees: [WorktreeManager.Info]) {
        let sourceRootPath = (sourceRoot ?? WorktreeManager.repoRoot(near: source.workingDirectory) ?? source.workingDirectory)
            .standardizedFileURL
            .path
        // Drop the source workspace's own working-tree root so we're
        // comparing only sibling worktrees against the sidebar. This must
        // use a stable repo root, not `Workspace.workingDirectory`, because
        // that property follows the active shell's cwd and may be `/repo/sub`.
        let sidebar = workspaces.filter { $0.worktreeParentId == source.id }
        guard !sidebar.isEmpty else { return }

        // Precompute Set of disk satellite paths so the zombie check is
        // O(M+K) (M sidebar entries, K disk worktrees), not O(M×K) — the
        // user opens kooky a lot, every microsecond on this path adds up
        // to perceived launch latency.
        let satellitePaths: Set<String> = Set(
            diskWorktrees.lazy
                .map { $0.path.standardizedFileURL.path }
                .filter { $0 != sourceRootPath }
        )

        // Compare against the pinned worktreePath, not workingDirectory —
        // a sidebar row whose user cd'd to ~/Downloads still matches its
        // disk root via worktreePath. Adopt-on-discovery is deliberately
        // not handled — see method doc comment.
        for wt in sidebar where !satellitePaths.contains(wt.diskPath.standardizedFileURL.path) {
            closeWorkspace(wt)
        }
    }

    /// Runs `git worktree remove --force <path>` on a detached task. The
    /// caller closes the workspace separately — this method only touches
    /// disk. `--force` because the close-confirm sheet already gathered
    /// the user's intent; refusing on dirty state here would just bounce
    /// them back to terminal commands. Returns nil on success, otherwise
    /// the error message to surface inline in the sheet.
    func removeWorktreeDirectory(_ workspace: Workspace) async -> String? {
        guard workspace.worktreeParentId != nil else {
            return "workspace is not a worktree"
        }
        let path = workspace.diskPath
        let parent = workspace.worktreeParentId.flatMap { parentId in
            workspaces.first(where: { $0.id == parentId })
        }
        let repoPath = parent
            .flatMap { WorktreeManager.repoRoot(near: $0.workingDirectory) }
            ?? WorktreeManager.repoRoot(near: path)
            ?? (isDirectory(path) ? path : nil)
        guard let repoPath else {
            // Parent and worktree directory are already gone. Let the caller
            // close the stranded sidebar row; there is no disk left to delete.
            pruneRecentlyClosed(under: workspace)
            return nil
        }
        let normalizedPath = path.standardizedFileURL.path
        let result = await Task.detached(priority: .userInitiated) {
            // Resolve the worktree's real current branch from `git
            // worktree list` before removing — the user may have
            // `git switch`-ed inside the worktree since kooky last
            // recorded `worktreeBranch`. Falling back to the stored
            // value would delete an outdated branch and leave the
            // truly-checked-out one orphaned.
            let realBranch: String? = {
                guard case .success(let infos) = WorktreeManager.list(repoPath: repoPath),
                      let match = infos.first(where: {
                          $0.path.standardizedFileURL.path == normalizedPath
                      })
                else { return nil }
                return match.branch
            }()
            let removed = WorktreeManager.remove(repoPath: repoPath, path: path, force: true)
            // Safe-delete the branch (only if merged) after the worktree
            // dir is gone — `git branch -d` would otherwise refuse with
            // "currently checked out at <path>". Failure on unmerged
            // branches is expected and intentionally ignored; the next
            // Create Worktree on the same name surfaces "branch exists
            // locally" then. No data-loss risk because git refuses to
            // drop unmerged commits without the upper-case `-D`.
            if case .success = removed, let realBranch, !realBranch.isEmpty {
                _ = WorktreeManager.deleteBranchIfMerged(repoPath: repoPath, branch: realBranch)
            }
            return removed
        }.value
        if case .failure(let err) = result {
            return err.description
        }
        pruneRecentlyClosed(under: workspace)
        return nil
    }

    /// Drops `recentlyClosed` entries for a worktree workspace we just
    /// `git worktree remove`-d — without this, ⌘⇧T would respawn a tab
    /// at a deleted cwd and `resolvedSpawnCwd` would silently route it
    /// to `$HOME`, surfacing a "Terminal at ~" the user never closed.
    private func pruneRecentlyClosed(under workspace: Workspace) {
        let root = workspace.diskPath.standardizedFileURL.path
        recentlyClosed.removeAll { entry in
            let cwd = entry.cwd.standardizedFileURL.path
            return entry.workspaceId == workspace.id
                || cwd == root
                || cwd.hasPrefix(root + "/")
        }
    }

    func closeWorkspace(_ workspace: Workspace) {
        for pane in workspace.root.allPanes {
            for tab in pane.tabs {
                gitWatchers.removeValue(forKey: tab.id)?.cancel()
                codexUsageMonitor.stop(sessionId: tab.id)
                tab.engine.terminate()
            }
        }
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces.remove(at: idx)
        if workspaces.isEmpty {
            activeWorkspaceId = nil
        } else if activeWorkspaceId == workspace.id {
            let nextIdx = min(idx, workspaces.count - 1)
            activeWorkspaceId = workspaces[nextIdx].id
        }
        scheduleSave()
        if workspaces.isEmpty { onBecameEmpty?() }
    }

    func activateWorkspace(_ workspace: Workspace) {
        guard activeWorkspaceId != workspace.id else { return }
        activeWorkspaceId = workspace.id
        scheduleSave()
    }

    @discardableResult
    func duplicateWorkspace(_ workspace: Workspace) -> Workspace {
        addWorkspace(workingDirectory: workspace.workingDirectory)
    }

    /// Set or clear a user-provided workspace title. Empty / whitespace input
    /// clears the override so the sidebar label resumes tracking the cwd.
    func renameWorkspace(_ workspace: Workspace, to newTitle: String) {
        let next = normalizedTitle(newTitle)
        guard workspace.customTitle != next else { return }
        workspace.customTitle = next
        scheduleSave()
    }

    /// Reorder workspaces in the sidebar — dragged workspace takes the
    /// destination index, others shift.
    func moveWorkspace(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex != destIndex,
              (0..<workspaces.count).contains(sourceIndex),
              (0..<workspaces.count).contains(destIndex) else { return }
        let source = workspaces[sourceIndex]
        let rootId = source.worktreeParentId ?? source.id
        let movingIndices = workspaces.indices.filter { idx in
            let ws = workspaces[idx]
            return ws.id == rootId || ws.worktreeParentId == rootId
        }
        guard !movingIndices.contains(destIndex) else { return }

        let movingIds = Set(movingIndices.map { workspaces[$0].id })
        let moving = workspaces.filter { movingIds.contains($0.id) }
        var remaining = workspaces.filter { !movingIds.contains($0.id) }
        let insertAt = min(max(destIndex, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        workspaces = remaining
        scheduleSave()
    }

    /// Payload for the "Close Other Workspaces" confirm sheet — captured
    /// when at least one of the workspaces about to close is a worktree,
    /// so the sheet can show the count and make the directory deletion
    /// explicit before running it.
    struct BulkRemovalRequest {
        let keeping: Workspace
        let others: [Workspace]
        let worktreeOthers: [Workspace]

        @MainActor
        init(keeping: Workspace, others: [Workspace]) {
            self.keeping = keeping
            self.others = others
            self.worktreeOthers = others.filter { $0.worktreeParentId != nil }
        }
    }

    /// Set when `closeOtherWorkspaces` detects a worktree among the
    /// workspaces about to close; sidebar's onChange listener pops the
    /// summary sheet from here. Plain bulk closes skip this and run
    /// inline.
    var pendingCloseOthersRequest: BulkRemovalRequest?

    func closeOtherWorkspaces(keeping workspace: Workspace) {
        // Keep the workspace's worktree family intact so we never strand
        // a worktree without its source (and vice versa):
        //  - keeping a source: also keep every worktree under it
        //  - keeping a worktree: also keep its source (siblings still close)
        var keepIds: Set<UUID> = [workspace.id]
        if let parentId = workspace.worktreeParentId {
            keepIds.insert(parentId)
        } else {
            for ws in workspaces where ws.worktreeParentId == workspace.id {
                keepIds.insert(ws.id)
            }
        }
        let others = workspaces.filter { !keepIds.contains($0.id) }
        if others.contains(where: { $0.worktreeParentId != nil }) {
            pendingCloseOthersRequest = BulkRemovalRequest(keeping: workspace, others: others)
            return
        }
        for ws in others { closeWorkspace(ws) }
    }

    /// Performs the deferred bulk close from the confirm sheet.
    /// `alsoDelete = true` runs `git worktree remove --force` + branch-d
    /// on each worktree in the others list before closing; `alsoDelete
    /// = false` just drops them from the sidebar with disk untouched
    /// (v0.19.0 default — destructive removal is the checkbox path).
    /// First failing git remove aborts.
    func performCloseOthers(_ request: BulkRemovalRequest, alsoDelete: Bool) async -> String? {
        if alsoDelete {
            for worktree in request.worktreeOthers {
                if let message = await removeWorktreeDirectory(worktree) {
                    return message
                }
            }
        }
        for ws in request.others { closeWorkspace(ws) }
        pendingCloseOthersRequest = nil
        return nil
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(
        in workspace: Workspace,
        pane: Pane? = nil,
        template: AgentTemplate = .terminal,
        initialCwd: URL? = nil,
        conversationId: String? = nil,
        initialPrompt: String? = nil
    ) -> Session {
        guard let target = pane ?? workspace.activePane ?? workspace.root.firstPane else {
            preconditionFailure("workspace has no panes")
        }
        // Precedence: explicit caller cwd (`reopenLastClosedTab`,
        // right-click "Ask <agent>") > template's pinned cwd
        // (`TerminalPreset.path` via `AgentTemplate.extraCwd`) > workspace
        // cwd. `~/` is expanded; a vanished path falls back to `$HOME` via
        // `resolvedSpawnCwd`.
        let cwd = initialCwd
            ?? template.extraCwd.map { resolvedSpawnCwd(($0 as NSString).expandingTildeInPath) }
            ?? workspace.workingDirectory
        let session = spawnSession(
            template: template,
            initialCwd: cwd,
            conversationId: conversationId,
            initialPrompt: initialPrompt,
            sshRemoteHost: sshRemoteHostForNewSession(in: workspace, template: template)
        )
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
        target.tabs.append(session)
        target.activeTabId = session.id
        if workspace.activePaneId != target.id {
            workspace.activePaneId = target.id
        }
        scheduleSave()
        return session
    }

    /// Creates a terminal tab that immediately connects to `remoteHost`, and
    /// marks the workspace as remote so subsequent plain terminal tabs follow.
    @discardableResult
    func createSSHSession(
        in workspace: Workspace,
        pane: Pane? = nil,
        remoteHost: String,
        initialCwd: URL? = nil
    ) -> Session? {
        guard let host = normalizedSSHRemoteHost(remoteHost) else { return nil }
        workspace.sshRemoteHost = host
        return addTab(in: workspace, pane: pane, template: .terminal, initialCwd: initialCwd)
    }

    @discardableResult
    func duplicateTab(_ session: Session, in workspace: Workspace) -> Session? {
        guard let pane = pane(containing: session, in: workspace) else { return nil }
        return addTab(in: workspace, pane: pane, template: session.agent, initialCwd: session.currentDirectory)
    }

    /// Set or clear a user-provided tab title. Empty / whitespace input clears
    /// the override so the title resumes tracking the working directory.
    func renameTab(_ session: Session, to newTitle: String) {
        let next = normalizedTitle(newTitle)
        guard session.customTitle != next else { return }
        session.customTitle = next
        scheduleSave()
    }

    func moveTab(from sourceIndex: Int, to destIndex: Int, in pane: Pane) {
        guard sourceIndex != destIndex,
              (0..<pane.tabs.count).contains(sourceIndex),
              (0..<pane.tabs.count).contains(destIndex) else { return }
        let tab = pane.tabs.remove(at: sourceIndex)
        pane.tabs.insert(tab, at: destIndex)
        scheduleSave()
    }

    /// Move a tab from its current pane to a different pane at a specific
    /// index. If the source pane runs out of tabs as a result, it collapses
    /// (sibling pane takes its place in the split tree). The session itself
    /// is preserved — same engine, same scrollback, same agent state.
    func moveTab(_ session: Session, to destPane: Pane, at destIndex: Int, in workspace: Workspace) {
        guard let sourcePane = workspace.root.pane(containingSessionId: session.id) else { return }
        if sourcePane.id == destPane.id { return }
        guard let sourceIndex = sourcePane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        detachSession(session, from: sourcePane, at: sourceIndex, in: workspace)
        attachSession(session, to: destPane, at: destIndex, in: workspace)
    }

    /// Removes `session` from `pane`. An emptied pane collapses — cascading
    /// to closing the workspace, and the window, when it was the last one;
    /// otherwise the active-tab crown passes to the neighbour and the
    /// workspace cwd re-syncs. Structural only: the engine keeps running, so
    /// this serves both `closeTab` (which terminates first) and a tab move
    /// (which re-homes the live session elsewhere).
    private func detachSession(_ session: Session, from pane: Pane, at idx: Int, in workspace: Workspace) {
        pane.tabs.remove(at: idx)
        if pane.tabs.isEmpty {
            closePane(pane, in: workspace)
            return
        }
        if pane.activeTabId == session.id {
            let next = pane.tabs[min(idx, pane.tabs.count - 1)]
            pane.activeTabId = next.id
            if workspace.activePane?.id == pane.id, workspace.workingDirectory != next.currentDirectory {
                workspace.workingDirectory = next.currentDirectory
            }
        }
        scheduleSave()
    }

    /// Inserts an existing `session` into `destPane` at `destIndex` and
    /// promotes it to the active tab + active pane.
    private func attachSession(_ session: Session, to destPane: Pane, at destIndex: Int, in workspace: Workspace) {
        let insertIndex = min(max(destIndex, 0), destPane.tabs.count)
        destPane.tabs.insert(session, at: insertIndex)
        destPane.activeTabId = session.id
        workspace.activePaneId = destPane.id
        // Promoting to active mirrors `activateTab` so the sidebar title and
        // the next tab's spawn cwd follow the new focus without waiting for
        // the next OSC 7.
        if workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
        }
        scheduleSave()
    }

    /// One-shot drop handler for tab reorder gestures. Dispatches three ways:
    /// a same-pane index reorder when source == dest, a cross-pane session
    /// move within this window, or — when the session isn't in this window at
    /// all — a cross-window adoption from whichever peer store owns it.
    /// `destIndex` is the target item's current index in `destPane.tabs` (or
    /// `destPane.tabs.count` for "drop at end").
    @discardableResult
    func handleTabDrop(droppedId: UUID, to destPane: Pane, at destIndex: Int, in workspace: Workspace) -> Bool {
        if let sourcePane = workspace.root.pane(containingSessionId: droppedId),
           let session = sourcePane.tabs.first(where: { $0.id == droppedId }) {
            if sourcePane.id == destPane.id {
                guard let from = sourcePane.tabs.firstIndex(where: { $0.id == droppedId }) else { return false }
                let to = min(max(destIndex, 0), sourcePane.tabs.count - 1)
                guard from != to else { return false }
                moveTab(from: from, to: to, in: sourcePane)
            } else {
                moveTab(session, to: destPane, at: destIndex, in: workspace)
            }
            return true
        }
        // The drag started in another window: take the session from the peer
        // store that owns it, slot it in here, and re-point its engine
        // callbacks at this store so focus / title / activity events follow.
        for source in peerStores() where source !== self {
            if let session = source.surrenderSession(id: droppedId) {
                attachSession(session, to: destPane, at: destIndex, in: workspace)
                wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
                return true
            }
        }
        return false
    }

    /// Removes the session with `id` from this store and returns it for a
    /// peer store (another window) to adopt — its engine, libghostty surface,
    /// scrollback, PTY and agent state all stay alive. Returns nil when this
    /// store doesn't own the id. `internal`, not `private`: `handleTabDrop`
    /// calls it on each peer store.
    func surrenderSession(id: UUID) -> Session? {
        guard let (workspace, pane) = location(ofSessionId: id),
              let idx = pane.tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let session = pane.tabs[idx]
        // The drag started in this window, so `onDrag` set our `draggingTabId`
        // — and the destination store's `dropDestination` defer clears only
        // its own. Clear ours so this window's drop indicators reset.
        draggingTabId = nil
        gitWatchers.removeValue(forKey: id)?.cancel()
        codexUsageMonitor.stop(sessionId: id)
        detachSession(session, from: pane, at: idx, in: workspace)
        return session
    }

    /// Routes the right-click "Move to New Window" request to `AppDelegate`,
    /// which creates a fresh window and moves the session into it.
    func moveTabToNewWindow(_ sessionId: UUID) {
        moveToNewWindow(sessionId)
    }

    func closeOtherTabs(keeping session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace) else { return }
        let toClose = pane.tabs.filter { $0.id != session.id }
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    func closeTabsToRight(of session: Session, in workspace: Workspace) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Snapshot direct refs — `closeTab` mutates `pane.tabs` mid-iteration.
        let toClose = Array(pane.tabs[(idx + 1)...])
        for tab in toClose { closeTab(tab, in: workspace) }
    }

    func closeTab(_ session: Session, in workspace: Workspace) {
        closeTab(session, in: workspace, recordHistory: true)
    }

    /// Like `closeTab` but skips the reopen-closed-tab history — for
    /// synthetic tabs the user never knowingly opened (e.g. the placeholder
    /// the new-window orchestration spawns before adopting a moved-in tab).
    /// Without this, `⌘⇧T` after a Move to New Window resurrects a phantom
    /// "terminal at ~" the user never closed.
    func discardTab(_ session: Session, in workspace: Workspace) {
        closeTab(session, in: workspace, recordHistory: false)
    }

    private func closeTab(_ session: Session, in workspace: Workspace, recordHistory: Bool) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Closing the last tab of a worktree workspace cascades through
        // detachSession → closePane → closeWorkspace, which would bypass
        // the confirm sheet. Reroute here before any state mutates so
        // the sheet's cancel path can keep the tab open.
        let isLastTabInWorktree = workspace.worktreeParentId != nil
            && workspace.root.allPanes.count == 1
            && pane.tabs.count == 1
        if isLastTabInWorktree {
            requestCloseWorkspace(workspace)
            return
        }
        if recordHistory {
            recordClosedTab(session, pane: pane, workspace: workspace)
        }
        gitWatchers.removeValue(forKey: session.id)?.cancel()
        codexUsageMonitor.stop(sessionId: session.id)
        session.engine.terminate()
        detachSession(session, from: pane, at: idx, in: workspace)
    }

    private func recordClosedTab(_ session: Session, pane: Pane, workspace: Workspace) {
        recentlyClosed.append(ClosedTabState(
            agent: session.agent,
            cwd: session.currentDirectory,
            customTitle: session.customTitle,
            workspaceId: workspace.id,
            paneId: pane.id,
            conversationId: session.conversationId
        ))
        if recentlyClosed.count > Self.closedTabHistoryLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.closedTabHistoryLimit)
        }
    }

    /// Pops the most recently closed tab off the history stack and re-spawns
    /// it. Routes back to the original workspace + pane when both still
    /// exist, falling back to the current workspace's active pane otherwise
    /// (a tab closed under a since-deleted workspace lands wherever the user
    /// is now). Returns the new session, or nil when the stack is empty.
    @discardableResult
    func reopenLastClosedTab() -> Session? {
        guard let state = recentlyClosed.popLast() else { return nil }
        guard let workspace = workspaces.first(where: { $0.id == state.workspaceId }) ?? active else {
            return nil
        }
        let pane = workspace.root.allPanes.first { $0.id == state.paneId }
            ?? workspace.activePane
            ?? workspace.root.firstPane
        let cwd = resolvedSpawnCwd(state.cwd.path)
        let session = addTab(
            in: workspace,
            pane: pane,
            template: state.agent,
            initialCwd: cwd,
            conversationId: state.conversationId
        )
        if let custom = state.customTitle, !custom.isEmpty {
            session.customTitle = custom
        }
        activateWorkspace(workspace)
        activateTab(session, in: workspace)
        return session
    }

    /// Cycle the active pane's tab selection. `direction` of `+1` advances
    /// to the next tab, `-1` to the previous; both wrap at the end. Per-pane,
    /// not workspace-wide — focus shouldn't jump panes when the user is
    /// asking to step through tabs in the pane they're looking at.
    func cycleTab(in workspace: Workspace, direction: Int) {
        guard let pane = workspace.activePane,
              let active = pane.activeTab,
              let currentIdx = pane.tabs.firstIndex(where: { $0 === active })
        else { return }
        activateTab(pane.tabs[pane.tabs.cyclicIndex(from: currentIdx, step: direction)], in: workspace)
    }

    func activateTab(_ session: Session, in workspace: Workspace) {
        // Switching to a tab counts as reading any notification that pointed at
        // it — clears the inbox entry + the bell dot without an explicit click.
        NotificationInbox.shared.markRead(forSession: session.id)
        guard let pane = pane(containing: session, in: workspace) else { return }
        var changed = false
        if pane.activeTabId != session.id {
            pane.activeTabId = session.id
            changed = true
        }
        if workspace.activePaneId != pane.id {
            workspace.activePaneId = pane.id
            // Focusing a different pane while zoomed would route ⌘D /
            // ⌘T / cwd-sync at the now-hidden active pane. Auto-exit so
            // the visible pane = the active pane invariant holds.
            if let zoomed = workspace.zoomedPaneId, zoomed != pane.id {
                workspace.zoomedPaneId = nil
            }
            changed = true
        }
        if workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: - Panes

    /// Toggle pane zoom for the active pane (keyboard / menu entry point
    /// — `⌘⇧E` operates on whatever pane has keyboard focus).
    func toggleZoom(in workspace: Workspace) {
        guard let active = workspace.activePaneId else { return }
        toggleZoom(in: workspace, paneId: active)
    }

    /// Toggle zoom for an explicit pane — used by the per-pane button and
    /// the right-click menu, so clicking the button on a non-active pane
    /// zooms *that* pane (and activates it so subsequent ⌘D / ⌘[ / ⌘]
    /// operate on the visibly-zoomed pane).
    func toggleZoom(in workspace: Workspace, paneId: UUID) {
        guard workspace.canZoom else { return }
        // Suspend per-frame `set_size` across the workspace for the zoom animation
        // (see suspendSizePropagationForLayoutAnimation).
        suspendSizePropagationForLayoutAnimation(workspace.root.allPanes.flatMap { $0.tabs }.map(\.engine))
        workspace.activePaneId = paneId
        workspace.zoomedPaneId = workspace.isZoomed(paneId) ? nil : paneId
        scheduleSave()
    }

    /// Suspend per-frame `ghostty_surface_set_size` across `engines` for the
    /// duration of a `withAnimation(Theme.chromeTransition)` layout change (pane
    /// zoom, sidebar / agent-panel show-hide), then end + flush once it settles.
    /// Without this, SwiftUI re-frames each surface every animation frame → a
    /// SIGWINCH burst (conda scrollback wipe) AND — since the vsync render loop is
    /// driven by those per-frame `setNeedsRender`s racing the display-link tick —
    /// visible flicker (issue #29). Refcounted begin/end (self-balanced, so
    /// overlapping animations compose; flush only when an engine's count hits 0);
    /// the local capture is robust (no shared/token state to strand). ~0.25s
    /// covers `Theme.chromeTransition`.
    private func suspendSizePropagationForLayoutAnimation(_ engines: [any TerminalEngine]) {
        guard !engines.isEmpty else { return }
        for engine in engines { engine.beginSizePropagationSuspension() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            for engine in engines {
                engine.endSizePropagationSuspension()
                if !engine.suspendsSizePropagation { engine.flushSize() }
            }
        }
    }

    /// Splits `pane` in two. The existing pane stays as the first child of the
    /// new split; the second child is a fresh `Pane` with a single new tab
    /// inheriting the source pane's active-tab agent + cwd. Returns the new
    /// pane (now focused) or nil if `pane` isn't found.
    @discardableResult
    func splitPane(_ pane: Pane, orientation: SplitOrientation, in workspace: Workspace) -> Pane? {
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return nil }
        guard case .pane(let existing) = leafNode.content else { return nil }
        let template = existing.activeTab?.agent ?? .terminal
        let cwd = existing.activeTab?.currentDirectory ?? workspace.workingDirectory
        let newSession = spawnSession(
            template: template,
            initialCwd: cwd,
            sshRemoteHost: sshRemoteHostForNewSession(in: workspace, template: template)
        )
        wireSessionCallbacks(engine: newSession.engine, session: newSession, workspace: workspace)
        let newPane = Pane(tabs: [newSession], activeTabId: newSession.id)
        let firstChild = PaneNode(pane: existing)
        let secondChild = PaneNode(pane: newPane)
        leafNode.content = .split(orientation: orientation, first: firstChild, second: secondChild, fraction: 0.5)
        workspace.activePaneId = newPane.id
        // Splitting while zoomed = "I want to see what I'm creating". Drop
        // zoom so the new pane is visible. Guarded so a no-op write
        // doesn't trigger an extra Observable invalidation.
        if workspace.zoomedPaneId != nil { workspace.zoomedPaneId = nil }
        scheduleSave()
        return newPane
    }

    /// Removes `pane` and its tabs. If it's the workspace's only pane, the
    /// whole workspace closes. Otherwise the sibling pane collapses up to
    /// take the parent split's place.
    func closePane(_ pane: Pane, in workspace: Workspace) {
        guard let leafNode = workspace.root.paneNode(paneId: pane.id) else { return }
        // Worktree last-pane cascade — route through the confirm sheet
        // before any engines get terminated, so a sheet cancel leaves
        // the user's work intact.
        if leafNode === workspace.root && workspace.worktreeParentId != nil {
            requestCloseWorkspace(workspace)
            return
        }
        if workspace.zoomedPaneId == pane.id { workspace.zoomedPaneId = nil }
        // Tear down per-session watchers before terminating engines — same
        // contract as closeTab / closeWorkspace. The non-root collapse path
        // below returns without routing through those, so without this the
        // closed pane's git + Codex-usage watchers (DispatchSource fds) leak.
        // Idempotent: the root path re-stops via closeWorkspace (no-op).
        for tab in pane.tabs {
            gitWatchers.removeValue(forKey: tab.id)?.cancel()
            codexUsageMonitor.stop(sessionId: tab.id)
            tab.engine.terminate()
        }
        // Object identity, not id equality. After `splitPane`, the workspace
        // root keeps its original id but its content becomes a `.split`, while
        // a freshly-constructed child `PaneNode(pane: existing)` reuses the
        // same `pane.id`. Comparing ids would falsely match a leaf child whose
        // pane shares an id with the root and route through `closeWorkspace`.
        if leafNode === workspace.root {
            closeWorkspace(workspace)
            return
        }
        guard let info = workspace.root.parentInfo(forPane: pane.id) else { return }
        info.parent.content = info.sibling.content
        // After collapse, focus whichever pane is now nearest.
        if workspace.activePaneId == pane.id {
            workspace.activePaneId = info.sibling.firstPane?.id
            if let session = workspace.activeSession,
               workspace.workingDirectory != session.currentDirectory {
                workspace.workingDirectory = session.currentDirectory
            }
        }
        scheduleSave()
    }

    func focusPane(_ pane: Pane, in workspace: Workspace) {
        guard workspace.root.pane(id: pane.id) != nil else { return }
        var changed = false
        if workspace.activePaneId != pane.id {
            workspace.activePaneId = pane.id
            // Same "visible-pane = active-pane" invariant as activateTab —
            // cycling focus via ⌘[ / ⌘] off the zoomed pane drops zoom.
            if let zoomed = workspace.zoomedPaneId, zoomed != pane.id {
                workspace.zoomedPaneId = nil
            }
            changed = true
        }
        if let session = pane.activeTab, workspace.workingDirectory != session.currentDirectory {
            workspace.workingDirectory = session.currentDirectory
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Adjusts the divider fraction of the split node containing `pane` as a
    /// direct child (used by drag-to-resize).
    func setSplitFraction(_ fraction: Double, parentOf pane: Pane, in workspace: Workspace) {
        guard let info = workspace.root.parentInfo(forPane: pane.id) else { return }
        guard case .split(let orient, let first, let second, let current) = info.parent.content else { return }
        let clamped = min(max(fraction, 0.1), 0.9)
        guard abs(clamped - current) > .ulpOfOne else { return }
        info.parent.content = .split(orientation: orient, first: first, second: second, fraction: clamped)
        scheduleSave()
    }

    /// Routes a hook event to the named session. On `.ended`, drops the leaf
    /// back to `.terminal` only if the agent reporting end matches the
    /// session's current agent — otherwise a Codex run inside a Claude tab
    /// (or a delayed `ended`) would wipe the still-active icon.
    func applyHookEvent(agent: AgentTemplate, event: HookEvent, sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        let agentBefore = session.agent.id
        if event == .ended {
            // A custom agent based on this builtin shares its binary's
            // wrapper shim — the `ended` ping arrives with the builtin's
            // slug, not the custom's id. Match on the template's
            // baseAgentId snapshot (frozen at spawn time, see
            // `AgentTemplate.baseAgentId`) so a mid-run Settings edit
            // can't leave the tab pill stuck.
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                // Report completion to the inbox *before* reverting to
                // Terminal, so the event still knows which agent finished
                // (handleSessionAlert reads displayAgent synchronously).
                onSessionAlert(session.id, .completed)
                session.agent = .terminal
            }
        } else if session.agent.isShell {
            // Includes the default Terminal *and* any TerminalPreset — a
            // user starting Claude inside a preset terminal should get
            // the same icon-upgrade the default Terminal does.
            session.agent = agent
        }
        // SessionStart → UserPromptSubmit on Claude (and BeforeAgent on Gemini)
        // re-fires `.running` per turn; the @Observable setter notifies every
        // sidebar/tab observer even on same-value assignment, so guard.
        if session.activityState != event.activityState {
            session.activityState = event.activityState
            if event.activityState == .attention { onSessionAlert(session.id, .attention) }
        }
        if session.agent.id != agentBefore { scheduleSave() }
        // A non-`ended` event means the agent just (re)started — for Codex,
        // (re)point the usage watcher so a manually-typed `codex` lights up
        // and a relaunch follows the freshly-created rollout file.
        if event != .ended { startCodexUsageIfNeeded(for: session) }
    }

    func applyShellEnvironment(_ env: [String: String], sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        session.shellEnvironment = env
        refreshEnvironment(for: session)
    }

    /// Stores the conversation id reported by an agent's hook payload onto
    /// the originating Session and schedules a save so the value survives
    /// across kooky launches. Same-value writes are dropped so we don't
    /// churn persistence on every hook firing — Claude pings `session_id`
    /// on every SessionStart / UserPromptSubmit / Stop / SessionEnd, so the
    /// dedup keeps the debounce loop quiet.
    func applyConversationId(conversationId: String, sessionId: UUID) {
        guard let session = findSession(id: sessionId) else { return }
        guard session.conversationId != conversationId else { return }
        session.conversationId = conversationId
        scheduleSave()
    }

    /// Routes a Claude tool-call event (PreToolUse / PostToolUse) to the
    /// originating Session's rolling `toolCallEvents` buffer. Runtime-only
    /// — no `scheduleSave()` because `toolCallEvents` isn't persisted.
    /// Unknown sessionIds (race: tab closed mid-flight) drop silently;
    /// other UI keeps rendering.
    func applyToolCallEvent(
        agent: AgentTemplate,
        toolName: String,
        identifier: String,
        event: HookToolEvent,
        success: Bool?,
        toolUseId: String?,
        sessionId: UUID
    ) {
        guard let session = findSession(id: sessionId) else { return }

        switch event {
        case .pre:
            session.recordToolCallStart(
                toolName: toolName,
                identifier: identifier,
                toolUseId: toolUseId
            )
        case .post:
            // Missing success flag (parse miss / wire malformed) defaults
            // to true — better to show the call as succeeded than to
            // falsely flag failure on a Claude that ran fine.
            session.recordToolCallEnd(
                toolName: toolName,
                identifier: identifier,
                success: success ?? true,
                toolUseId: toolUseId
            )
        }
    }

    /// The workspace + pane holding the session with `id`, or nil. One DFS
    /// per workspace, stopping at the first hit.
    private func location(ofSessionId id: UUID) -> (workspace: Workspace, pane: Pane)? {
        for workspace in workspaces {
            if let pane = workspace.root.pane(containingSessionId: id) {
                return (workspace, pane)
            }
        }
        return nil
    }

    private func findSession(id: UUID) -> Session? {
        location(ofSessionId: id)?.pane.tabs.first { $0.id == id }
    }

    func flushPersistence() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence.save(snapshot())
    }

    /// Tears the store down when its window closes — releases every
    /// session's libghostty surface + PTY (AppKit closing the `NSWindow`
    /// does not, and Swift 6's nonisolated `deinit` can't reach the
    /// `@MainActor` engine state) and stops background work. Does not
    /// mutate `workspaces` or persist — the caller decides slot retention.
    func terminate() {
        pendingSave?.cancel()
        pendingSave = nil
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for tab in pane.tabs {
                    tab.engine.terminate()
                }
            }
        }
        for watcher in gitWatchers.values { watcher.cancel() }
        gitWatchers.removeAll()
        codexUsageMonitor.stopAll()
    }

    // MARK: - Internals

    private func pane(containing session: Session, in workspace: Workspace) -> Pane? {
        workspace.root.pane(containingSessionId: session.id)
    }

    private func restore(from state: PersistedState) {
        let fm = FileManager.default
        for ws in state.workspaces {
            guard let root = restorePane(ws.root, fm: fm, sshRemoteHost: ws.sshRemoteHost) else { continue }
            let workspace = Workspace(
                id: ws.id,
                workingDirectory: URL(fileURLWithPath: ws.workingDirectoryPath),
                root: root
            )
            workspace.customTitle = ws.customTitle
            workspace.worktreeParentId = ws.worktreeParentId
            workspace.worktreeBranch = ws.worktreeBranch
            workspace.worktreePath = ws.worktreePath.map { URL(fileURLWithPath: $0) }
            workspace.sshRemoteHost = ws.sshRemoteHost
            // Wire engines now that workspace is constructed (engines need
            // the workspace ref for cwd-sync callbacks).
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace)
                }
            }
            if let id = ws.activePaneId, workspace.root.allPanes.contains(where: { $0.id == id }) {
                workspace.activePaneId = id
            } else {
                workspace.activePaneId = workspace.root.firstPane?.id
            }
            workspaces.append(workspace)
        }
        activeWorkspaceId = workspaces.contains(where: { $0.id == state.activeWorkspaceId })
            ? state.activeWorkspaceId
            : workspaces.first?.id
        sidebarMode = state.sidebarMode ?? .full
        rightSidebarMode = state.rightSidebarMode ?? .hidden
    }

    private func restorePane(_ persisted: PersistedPaneNode, fm: FileManager, sshRemoteHost: String? = nil) -> PaneNode? {
        switch persisted.kind {
        case .pane(let p):
            let pane = Pane(id: p.id)
            for tab in p.tabs {
                let agent = AgentTemplate.all.first { $0.id == tab.agentId } ?? .terminal
                let session = spawnSession(
                    template: agent,
                    initialCwd: resolvedSpawnCwd(tab.currentDirectoryPath),
                    sessionId: tab.id,
                    conversationId: tab.conversationId,
                    sshRemoteHost: sshRemoteHostForNewSession(sshRemoteHost, template: agent)
                )
                session.customTitle = tab.customTitle
                pane.tabs.append(session)
            }
            pane.activeTabId = pane.tabs.contains(where: { $0.id == p.activeTabId })
                ? p.activeTabId
                : pane.tabs.first?.id
            return PaneNode(pane: pane)
        case .split(let orientation, let first, let second, let fraction):
            guard let firstChild = restorePane(first, fm: fm, sshRemoteHost: sshRemoteHost),
                  let secondChild = restorePane(second, fm: fm, sshRemoteHost: sshRemoteHost) else { return nil }
            return PaneNode(
                id: persisted.id,
                content: .split(
                    orientation: orientation,
                    first: firstChild,
                    second: secondChild,
                    fraction: fraction
                )
            )
        }
    }

    /// Spawns the engine + Session. Caller wires `onPwdChange` / `onFocus`
    /// after a workspace ref is available — `restore` builds sessions before
    /// the workspace exists, so callbacks can't capture it here.
    private func sshRemoteHostForNewSession(in workspace: Workspace, template: AgentTemplate) -> String? {
        sshRemoteHostForNewSession(workspace.sshRemoteHost, template: template)
    }

    private func sshRemoteHostForNewSession(_ host: String?, template: AgentTemplate) -> String? {
        normalizedSSHRemoteHost(host)
    }

    private func normalizedSSHRemoteHost(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func spawnSession(template: AgentTemplate, initialCwd: URL, sessionId: UUID = UUID(), conversationId: String? = nil, initialPrompt: String? = nil, sshRemoteHost: String? = nil) -> Session {
        let engine = engineFactory()
        // Resume gated by user setting — `resumeConversations` flips this off
        // when the user wants every Claude tab to start fresh without
        // losing the persisted conversation id (it stays on disk so the
        // setting can be flipped back on later). Non-resumable templates
        // ignore the value via `makeSessionConfig`'s own `supportsResume`
        // gate, so we don't have to re-check here.
        let resumeId = resumeProvider() ? conversationId : nil
        var config = template.makeSessionConfig(
            extraOptions: optionsProvider(template.id),
            resumeId: resumeId,
            initialPrompt: initialPrompt
        )
        let remoteAgentCommand = template.isShell ? nil : config.environment["KOOKY_AGENT"]
        var launchedRemoteAgent = false
        if let host = normalizedSSHRemoteHost(sshRemoteHost) {
            config = AgentTemplate.terminal.makeSessionConfig()
            let remoteAgentFragment = remoteAgentCommand.map { " -- \($0)" } ?? ""
            config.environment["KOOKY_AGENT"] = "kooky-ssh \(KookyShellIntegration.quote(host))\(remoteAgentFragment)"
            launchedRemoteAgent = remoteAgentCommand != nil
        }
        config.workingDirectory = initialCwd.path
        // A Claude-Code-based custom agent with an env block hands `claude`
        // its endpoint / key via a per-agent Claude settings file (written by
        // `refreshClaudeCustomSettings`); `kookyEnvironment` routes this
        // session's KOOKY_HOOKS_PATH there.
        let claudeCustomId = template.baseAgentId == AgentTemplate.claudeCodeID && !template.extraEnv.isEmpty
            ? template.id : nil
        config.environment.merge(
            KookyShellIntegration.kookyEnvironment(for: sessionId, claudeCustomSettingsAgentId: claudeCustomId)
        ) { _, new in new }
        engine.start(config: config)
        let session = Session(
            id: sessionId,
            engine: engine,
            currentDirectory: initialCwd,
            agent: template,
            conversationId: conversationId
        )
        if let host = normalizedSSHRemoteHost(sshRemoteHost) {
            session.remoteHost = host
        }
        if launchedRemoteAgent {
            session.activityState = .running
        }
        return session
    }

    private func wireSessionCallbacks(engine: any TerminalEngine, session: Session, workspace: Workspace) {
        // Initial refresh — without these, the status bar stays empty until
        // the user `cd`s or runs a command. Both fetchers silently hide
        // results for non-applicable cwds, so the calls are harmless.
        refreshGitStatus(for: session)
        refreshEnvironment(for: session)
        installGitWatcher(for: session)
        startCodexUsageIfNeeded(for: session)
        engine.remoteHostProvider = { [weak session, weak workspace] in
            session?.remoteHost ?? workspace?.sshRemoteHost
        }
        engine.onPwdChange = { [weak self, weak session, weak workspace] pwd in
            guard let session else { return }
            let url = URL(fileURLWithPath: pwd)
            // Compare against the URL's normalized path (what actually gets
            // stored) — not raw `pwd` — so a shell that reports a trailing-slash
            // cwd doesn't read as a change every prompt and defeat the gate below.
            let path = url.path
            let cwdChanged = session.currentDirectory.path != path
            if cwdChanged {
                session.currentDirectory = url
            }
            var workspaceCwdChanged = false
            if let workspace, workspace.activeSession?.id == session.id, workspace.workingDirectory.path != path {
                workspace.workingDirectory = url
                workspaceCwdChanged = true
            }
            // Git status AND the filesystem watcher refresh on EVERY prompt, even
            // an unchanged cwd — neither is safe to gate on cwdChanged:
            //  • refreshGitStatus: an external editor can change the working
            //    tree's uncommitted-file count without touching .git, which the
            //    watcher's fs source never sees; this per-prompt fetch (which
            //    result-dedups) is the only catch.
            //  • watch(): GitWatcher.watch self-dedups for an already-watched
            //    repo, but when the cwd had no .git at install time it re-runs
            //    findGitDir on every call — so this is what finally attaches the
            //    watcher when a repo is created in place (`git init` / `clone .`)
            //    with no cd. Gating it would strand that case (issue #29 review).
            self?.refreshGitStatus(for: session)
            self?.gitWatchers[session.id]?.watch(cwd: session.currentDirectory)
            // Environment + persistence DO only move with the cwd. venv / node
            // changes are pushed by the separate `_kooky_env_status` precmd IPC
            // (which updates shellEnvironment → refreshEnvironment), and the only
            // state this closure persists is the two cwd fields — so on an
            // unchanged cwd both refreshEnvironment and scheduleSave are redundant.
            if cwdChanged {
                self?.refreshEnvironment(for: session)
            }
            if cwdChanged || workspaceCwdChanged {
                self?.scheduleSave()
            }
        }
        engine.onTitleChange = { [weak self, weak session] title in
            guard let session else { return }
            // A `kooky-remote-login:*` title is an internal ssh marker, not a
            // visible title. SSH state belongs to explicitly created SSH
            // workspaces only; a manually typed ssh command must not promote a
            // local workspace or tab into remote mode.
            if RemoteLoginMarker.parseTitle(title) != nil {
                return
            }
            // Any `kooky-agent:*` title is a status marker, never a visible
            // title — consume it (applying the agent state when it resolves to
            // a known agent) and stop before it reaches `terminalTitle`.
            if AgentStatusMarker.isMarkerTitle(title) {
                if let marker = AgentStatusMarker.parseTitle(title) {
                    self?.applyAgentStatusMarker(
                        agent: marker.agent,
                        event: marker.event,
                        session: session
                    )
                }
                return
            }
            // A path-shaped SET_TITLE is noise: libghostty synthesises one
            // from OSC 7, and the wrapper re-emits the cwd each prompt — both
            // are things `Session.title` already renders. Keep only what the
            // cwd can't say (`ssh`'s `user@host:dir`, a TUI's filename).
            let next = normalizedTitle(title).flatMap {
                ($0.hasPrefix("/") || $0.hasPrefix("~")) ? nil : $0
            }
            if session.terminalTitle != next { session.terminalTitle = next }
        }
        engine.onFocus = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.activateTab(session, in: workspace)
        }
        engine.onCommandFinished = { [weak self, weak session] exit, duration in
            guard let session else { return }
            // A remote agent surfaced via an OSC marker (transientAgent) emits
            // no `ended` marker when the ssh drops abnormally (network loss,
            // killed connection). The local command finishing — the `ssh`
            // itself returning to the prompt — is the reliable "remote session
            // over" signal, so clear the transient promotion here too. During a
            // live ssh the local shell is blocked, so this never fires mid-
            // session and can't clear a still-running remote agent early.
            if session.transientAgent != nil {
                session.transientAgent = nil
                session.activityState = .idle
            }
            session.remoteHost = nil
            // Codex blocks the shell while it runs, so this firing means Codex
            // exited (or any other command finished) — drop the usage gauge and
            // stop watching the now-static rollout. Reliable even on an abnormal
            // codex exit where the `ended` hook never fires, since the shell
            // always returns to the prompt. stop() is unconditional (a true
            // no-op for sessions that never started a watcher) so it also frees
            // the fd when codex exited before its first `token_count` — e.g. an
            // auth failure or `codex --help`, where `codexUsage` stayed nil.
            if session.codexUsage != nil { session.codexUsage = nil }
            self?.codexUsageMonitor.stop(sessionId: session.id)
            session.lastCommandExit = exit
            session.lastCommandDuration = duration
            // A non-zero exit on a backgrounded tab is worth a nudge;
            // AppDelegate gates on visibility + the notifications setting.
            if let exit, exit != 0 { self?.onSessionAlert(session.id, .failure) }
            // A finished command may have changed the working tree (commit /
            // git add / file edits) or installed a venv / dropped an .nvmrc.
            // Refresh so the bar doesn't lie.
            self?.refreshGitStatus(for: session)
            self?.refreshEnvironment(for: session)
        }
        engine.onUserInput = { [weak session] in
            // libghostty exposes no command-START, so a keystroke (the first
            // character of the next command) is when we clear a stale
            // command-failure dot — covers any command, agent or manual.
            guard let session, session.lastCommandExit != nil else { return }
            session.lastCommandExit = nil
            session.lastCommandDuration = nil
        }
        engine.onProcessExitedCleanly = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.closeTab(session, in: workspace)
        }
        engine.onSearchStart = { [weak session] needle in
            guard let session else { return }
            session.searchActive = true
            session.searchNeedle = needle
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchEnd = { [weak session] in
            guard let session else { return }
            session.searchActive = false
            session.searchNeedle = ""
            session.searchTotal = 0
            session.searchSelected = -1
        }
        engine.onSearchTotal = { [weak session] total in
            guard let session, session.searchTotal != total else { return }
            session.searchTotal = total
        }
        engine.onSearchSelected = { [weak session] selected in
            guard let session, session.searchSelected != selected else { return }
            session.searchSelected = selected
        }
    }

    private func applyAgentStatusMarker(agent: AgentTemplate, event: HookEvent, session: Session) {
        let agentBefore = session.agent.id
        if event == .ended {
            if session.transientAgent?.id == agent.id || session.transientAgent?.baseAgentId == agent.id {
                // Remote agent done — inbox completion before clearing, so
                // displayAgent still resolves to the remote agent.
                onSessionAlert(session.id, .completed)
                session.transientAgent = nil
            }
            if session.agent.id == agent.id || session.agent.baseAgentId == agent.id {
                session.agent = .terminal
            }
        } else if session.agent.isShell {
            session.transientAgent = agent
        }

        if session.activityState != event.activityState {
            session.activityState = event.activityState
            if event.activityState == .attention { onSessionAlert(session.id, .attention) }
        }
        if session.agent.id != agentBefore { scheduleSave() }
    }

    private func refreshGitStatus(for session: Session) {
        gitStatusFetcher.fetch(sessionId: session.id, cwd: session.currentDirectory) { [weak session] status in
            guard let session, session.gitStatus != status else { return }
            session.gitStatus = status
        }
    }

    /// Starts (or re-points) the Codex usage watcher for a Codex session.
    /// No-op for every other agent. Called on session wire-up (covers a tab
    /// launched as Codex or restored as one) and on the `running` lifecycle
    /// event (covers a manually-typed `codex`, and a relaunch that opens a
    /// fresh rollout file). `start` is idempotent for an unchanged resolution.
    private func startCodexUsageIfNeeded(for session: Session) {
        let key = session.displayAgent.baseAgentId ?? session.displayAgent.id
        guard key == AgentTemplate.codex.id else { return }
        // Resolve CODEX_HOME from the session's live shell env (a Dock-launched
        // kooky doesn't inherit it; the codex child does). The monitor snapshots
        // existing rollouts on this first call to tell this session's own file
        // apart from a prior/concurrent run's.
        let root = CodexUsageMonitor.sessionsRoot(shellEnv: session.shellEnvironment)
        codexUsageMonitor.start(
            sessionId: session.id,
            cwd: session.currentDirectory,
            sessionsRoot: root
        ) { [weak session] usage in
            guard let session, session.codexUsage != usage else { return }
            session.codexUsage = usage
        }
    }

    private func installGitWatcher(for session: Session) {
        let watcher = GitWatcher { [weak self, weak session] in
            guard let self, let session else { return }
            self.refreshGitStatus(for: session)
        }
        watcher.watch(cwd: session.currentDirectory)
        gitWatchers[session.id] = watcher
    }

    private func refreshEnvironment(for session: Session) {
        let pid = session.engine.foregroundPid
        let env: ProjectEnvironment
        if session.shellEnvironment.isEmpty {
            env = EnvironmentDetector.detect(cwd: session.currentDirectory, pid: pid)
        } else {
            env = EnvironmentDetector.extract(
                shellEnv: session.shellEnvironment,
                cwd: session.currentDirectory,
                allowProjectFallback: false
            )
        }
        guard session.environment != env else { return }
        session.environment = env
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard let self, !Task.isCancelled else { return }
            self.persistence.save(self.snapshot())
        }
    }

    private func snapshot() -> PersistedState {
        PersistedState(
            workspaces: workspaces.map(PersistedWorkspace.init),
            activeWorkspaceId: activeWorkspaceId,
            sidebarMode: sidebarMode,
            rightSidebarMode: rightSidebarMode
        )
    }
}
