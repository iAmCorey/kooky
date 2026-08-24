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

/// kooky's one canonical form for on-disk path identity: shells report the
/// LOGICAL cwd, workspaces may hold either spelling, so equality checks must
/// resolve symlinks (`/tmp` vs `/private/tmp`) before comparing. Shared by
/// the file tree's re-rooting and the CLI's workspace matching — a drift
/// here is "opening the same project stacks new workspaces".
func canonicalDiskPath(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
}

/// Trims a title string; blank or whitespace-only input collapses to `nil`.
/// Shared by the manual-rename paths and the OSC-title observer so "empty
/// means no title" stays one rule.
func normalizedTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// `NSHomeDirectory()` re-resolves through Foundation on every call and cannot
/// change while the process lives. `Session.title` and `Workspace.title` both
/// compare against it, and those run on every sidebar / agent-panel row render,
/// so resolve it once — it was the single largest cost in either title.
let homeDirectoryPath = NSHomeDirectory()

/// Flattens a value that is about to become ONE line of a newline-joined
/// string. Titles arrive from OSC sequences and from hand-written
/// settings.json, and `normalizedTitle` only trims the ends — an interior
/// newline survives it. Every other render site is a `Text(...).lineLimit(1)`
/// that collapses newlines on its own; a tooltip whose line count carries
/// meaning is the one place that has to do it explicitly.
func singleLine(_ raw: String) -> String {
    raw.split(whereSeparator: \.isNewline)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
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

/// What the left sidebar's middle area shows — the workspace list or the
/// active workspace's file tree. The footer toggle switches between them;
/// the brand header and footer stay visible in both.
enum SidebarContent: String, Codable, Equatable, Sendable {
    case workspaces
    case files
}

/// What the right sidebar shows in full mode — live agents, on-disk history,
/// or details for the active tab. Mirrors `SidebarContent`'s footer-toggle
/// model. Compact mode always renders agents: a 44pt icon rail can't express
/// either of the detail pages usefully.
enum RightSidebarContent: String, Codable, Equatable, Sendable, CaseIterable {
    case agents
    case history
    case info
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
    /// Left sidebar's middle content — workspace list or file tree. Persisted
    /// like `sidebarMode`; the footer toggle in `SidebarView` flips it.
    var sidebarContent: SidebarContent = .workspaces
    /// Right sidebar's full-mode content — live agents, history, or active
    /// session information.
    /// Persisted like `sidebarContent`; the panel's own footer toggle flips it.
    var rightSidebarContent: RightSidebarContent = .agents
    /// History pane's agent filter + search text. Runtime-only, but owned by
    /// the STORE, not the view: collapsing the panel (or cycling its mode)
    /// unmounts `SessionHistoryView`, and `@State` there would reset both to
    /// defaults on every reopen.
    var historyFilterAgentId: String?
    var historySearchQuery = ""
    /// Session Info's collapsed sections, keyed by section title. Owned by the
    /// store for exactly the reason above — the page unmounts whenever the
    /// panel switches, so `@State` in the view would forget every collapse the
    /// moment the user glanced at the agents list. Persisted per window, so a
    /// habitual "Processes stays folded" survives a relaunch too.
    ///
    /// Empty by default: every section opens, and collapsing is the user's
    /// call to make (and keep).
    var collapsedInfoSections: Set<String> = []

    func toggleInfoSection(_ title: String) {
        if collapsedInfoSections.contains(title) {
            collapsedInfoSections.remove(title)
        } else {
            collapsedInfoSections.insert(title)
        }
        scheduleSave()
    }
    /// Full-mode sidebar width, user-draggable from the trailing edge.
    /// `SidebarView.fullWidth` is the floor (the design width — the sidebar
    /// can only grow); compact stays fixed at `compactWidth` and hidden is
    /// hidden, so this only applies while expanded. Persisted per window.
    var sidebarWidth: CGFloat = SidebarView.fullWidth
    /// File-tree state for the sidebar's files mode. Store-owned (not view
    /// `@State`) because it holds kqueue fds needing explicit teardown and
    /// the sidebar unmounts whole while hidden — `terminate()` is the
    /// window-close backstop, `FileTreeView` pauses it via on(Dis)appear.
    let fileTree = FileTreeModel()
    /// A diff-pill reveal temporarily roots the tree at that session's repo
    /// instead of its cwd, so every repo-wide diff row is representable. Tied
    /// to workspace + session identity; switching the sidebar away from files
    /// or moving focus to another workspace/tab clears it and restores the
    /// usual `Workspace.diskPath` behavior.
    private struct FileTreeRootOverride {
        let workspaceId: UUID
        let sessionId: UUID
        let root: URL
    }
    private var fileTreeRootOverride: FileTreeRootOverride?

    /// Drops a root override that no longer matches the active workspace +
    /// session, so a later re-activation of that session can't resurrect it.
    /// Call after ANY direct active-identity write that bypasses
    /// `activateTab`/`focusPane` — same scattered-sites contract as
    /// `zoomedPaneId` (CLAUDE.md): addTab, close-collapse, cross-pane move,
    /// zoom-button focus, split.
    private func invalidateStaleFileTreeRootOverride() {
        guard let override = fileTreeRootOverride else { return }
        if override.workspaceId != active?.id
            || override.sessionId != active?.activeSession?.id {
            fileTreeRootOverride = nil
        }
    }

    var fileTreeRoot: URL? {
        guard let override = fileTreeRootOverride,
              override.workspaceId == active?.id,
              override.sessionId == active?.activeSession?.id else {
            return active?.diskPath
        }
        return override.root
    }
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
        suspendSizePropagationForLayoutAnimation(active?.root.allEngines ?? [])
        sidebarMode = mode
        scheduleSave()
    }

    func setRightSidebarMode(_ mode: SidebarMode) {
        guard rightSidebarMode != mode else { return }
        suspendSizePropagationForLayoutAnimation(active?.root.allEngines ?? [])
        rightSidebarMode = mode
        scheduleSave()
    }

    /// Content-only swap like `setSidebarContent` — the panel keeps its width,
    /// so no size-propagation suspension is needed.
    func setRightSidebarContent(_ content: RightSidebarContent) {
        guard rightSidebarContent != content else { return }
        rightSidebarContent = content
        scheduleSave()
    }

    /// Content-only swap — the sidebar keeps its width, so no size-propagation
    /// suspension is needed (that dance is for width-animating mode changes).
    func setSidebarContent(_ content: SidebarContent) {
        // Gate on non-nil: `@Observable` notifies on every write, so an
        // unconditional nil-over-nil here would invalidate `fileTreeRoot`
        // observers on each no-op content set.
        if content != .files, fileTreeRootOverride != nil { fileTreeRootOverride = nil }
        guard sidebarContent != content else { return }
        sidebarContent = content
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
        // The rename popover anchors to a workspace row — flip the sidebar
        // back to the list, or the parked request sits unconsumed in files
        // mode and fires stale on the next toggle.
        if sidebarContent == .files { setSidebarContent(.workspaces) }
        pendingRenameWorkspace = active
    }

    /// Diff pill popover's "Show in File Tree": switch the sidebar to files
    /// mode, first promoting a hidden/compact sidebar to full — the tree
    /// only mounts in the full sidebar (`SidebarView.fileTreeIsMounted`).
    func revealFileTree(root: URL? = nil) {
        if let root, let workspace = active, let session = workspace.activeSession {
            fileTreeRootOverride = FileTreeRootOverride(
                workspaceId: workspace.id,
                sessionId: session.id,
                root: root
            )
        } else {
            fileTreeRootOverride = nil
        }
        setSidebarMode(.full)
        setSidebarContent(.files)
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
    /// Reports a user-chosen project folder for File → Open Recent / ⌘P.
    /// Defaults to a no-op like the other side-effecting callbacks
    /// (`onSessionAlert`, `moveToNewWindow`) — a write must never be the
    /// default a test construction silently inherits; `AppDelegate.addWindow`
    /// wires the real `RecentFolders` sink.
    private let noteRecentFolder: @MainActor (URL) -> Void
    private let persistence: any Persistence
    private let gitStatusFetcher = GitStatusFetcher()
    /// One watcher per session — refreshes git status when `.git/HEAD` or
    /// `.git/index` changes from any source (agent subprocess, external
    /// terminal, file-level git ops). The OSC 7 / OSC 133 paths only see
    /// the outer shell, so an agent running its own subprocess shell never
    /// trips them; the filesystem layer catches everyone.
    ///
    /// One watcher per RESOLVED gitdir, shared by every session whose cwd
    /// lives in that repo. `findGitDir` resolves a worktree's `.git` pointer
    /// file to its own `.git/worktrees/<name>/`, so two worktrees of one
    /// repo never share an entry — their HEAD/index events can't cross-
    /// pollinate. Replaces per-session watchers: ten same-repo tabs used to
    /// mean ten fd pairs and, on one commit, ten independent debounces each
    /// forking its own git pair (fork storm + GCD worker pileup).
    /// Reference type on purpose: subscriber mutation is in-place, and the
    /// watcher + subscriber set live and die together under one key.
    private final class GitWatch {
        let watcher: GitWatcher
        var subscribers: Set<UUID> = []
        /// Prompt/spawn bursts from same-repo tabs collapse into one shared
        /// status fetch. The watcher already debounces disk events; this task
        /// covers UI-originated triggers that otherwise arrive per session.
        var pendingStatusRefresh: Task<Void, Never>?
        init(watcher: GitWatcher) { self.watcher = watcher }
    }
    private var gitWatches: [String: GitWatch] = [:]
    /// Slightly wider than GitStatusFetcher's 50ms same-lane coalescing
    /// window: a trigger arriving just after dispatch gets a guaranteed
    /// follow-up fetch instead of being swallowed by the previous batch.
    private static let sharedGitRefreshDelay = Duration.milliseconds(60)
    /// Per-session (cwd → resolved gitdir) cache so the per-prompt hub call
    /// skips the findGitDir directory walk while the cwd is unchanged.
    private var sessionGitWatch: [UUID: (cwdPath: String, gitDir: String?)] = [:]
    /// Watches each Codex session's rollout file and republishes its latest
    /// rate-limit usage to `Session.codexUsage` for the status-bar gauge.
    /// Codex blocks the shell while running, so the file is the only live
    /// signal — torn down alongside the git-watch subscription at every
    /// close site.
    private let codexUsageMonitor = CodexUsageMonitor()
    /// Reads Kiro's per-surface ACP recording and captures the exact id
    /// returned by `session/new`, including in the current non-hookable TUI.
    private let kiroConversationMonitor = KiroConversationMonitor()

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
        /// Captured conversation id so `⌘⇧T` resumes the agent session
        /// the user just closed (subject to `resumeConversations` setting).
        let conversationId: String?
    }

    /// LIFO stack of recently-closed tabs for ⌘⇧T (reopen). Capped at
    /// `closedTabHistoryLimit` so a long session doesn't unbounded-grow.
    /// Runtime-only — closed tabs do not survive an app restart.
    private var recentlyClosed: [ClosedTabState] = []
    private static let closedTabHistoryLimit = 50

    private var pendingSave: Task<Void, Never>?

    /// Set by `terminate()`. The window layer drops its controller only on
    /// the NEXT main-queue tick (releasing an NSWindow synchronously inside
    /// windowWillClose crashes AppKit), so for one tick a dead store is
    /// still reachable through `windowControllers` — anything that acts on
    /// a store from outside the UI (the CLI) must skip it, or it lands a tab
    /// in a store that is about to be dropped and reports success.
    private(set) var isTerminated = false
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
        onSessionAlert: @escaping @MainActor (UUID, SessionAlertKind) -> Void = { _, _ in },
        noteRecentFolder: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.persistence = persistence
        self.engineFactory = engineFactory
        self.optionsProvider = optionsProvider
        self.resumeProvider = resumeProvider
        self.peerStores = peerStores
        self.moveToNewWindow = moveToNewWindow
        self.onSessionAlert = onSessionAlert
        self.noteRecentFolder = noteRecentFolder
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
        sshRemoteHost: String? = nil,
        conversationId: String? = nil,
        forceResume: Bool = false,
        rawLaunchCommand: String? = nil,
        customTitle: String? = nil,
        activate: Bool = true
    ) -> Workspace {
        // NB: the home fallback (fresh window's seed workspace) reaching
        // `noteRecentFolder` below is caught by `RecentFolders.note()`'s own
        // home exclusion — if this fallback ever becomes a configurable
        // default-projects dir, the recent list starts recording it silently.
        // `inheritedFrom` is captured HERE, before `activeWorkspaceId` moves
        // to the new workspace below — `active` later means the new one.
        let inheritedFrom = workingDirectory == nil ? active : nil
        let dir = workingDirectory
            ?? inheritedFrom?.workingDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let pane = Pane()
        let root = PaneNode(pane: pane)
        let workspace = Workspace(workingDirectory: dir, root: root)
        workspace.worktreeParentId = worktreeParent?.id
        workspace.worktreeBranch = worktreeBranch
        workspace.sshRemoteHost = Self.normalizedSSHHost(sshRemoteHost)
        // Pin worktreePath at create time so `git worktree remove` always
        // targets the disk root, no matter where the user cd's later.
        // `.standardizedFileURL` resolves `/tmp` → `/private/tmp` etc. so
        // a later reconcile comparison against `git worktree list`
        // output (which is already realpath'd) lines up.
        if worktreeParent != nil {
            workspace.worktreePath = dir.standardizedFileURL
        }
        // A new workspace always comes up with exactly one tab. The spawn
        // arguments are forwarded so that tab can BE what the caller wanted
        // (see `localSpawn`) instead of a default shell the caller then has
        // to open a second tab beside — one `open`, one PTY.
        let session = spawnSession(
            template: template,
            initialCwd: dir,
            conversationId: conversationId,
            forceResume: forceResume,
            sshRemoteHost: workspace.sshRemoteHost,
            rawLaunchCommand: rawLaunchCommand,
            customTitle: customTitle
        )
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace, codexRolloutId: session.resumedConversationId)
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
        if activate {
            activeWorkspaceId = workspace.id
        }
        // Remember the project folder for Open Recent / ⌘P (issue #28) —
        // except worktree children (their dir dies with the worktree) and
        // SSH workspaces (the local cwd is not where the project lives).
        // The exclusion follows the DIRECTORY's provenance, not just this
        // call's arguments: a dir inherited from such a workspace (⌘N with
        // one active — `inheritedFrom` — or Duplicate on one — matched by
        // path) keeps its source's exclusion.
        let origin = inheritedFrom ?? workspaces.first(where: {
            $0 !== workspace && $0.workingDirectory.standardizedFileURL.path == dir.standardizedFileURL.path
        })
        if worktreeParent == nil, workspace.sshRemoteHost == nil,
           origin?.worktreeParentId == nil, origin?.sshRemoteHost == nil {
            noteRecentFolder(dir)
        }
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
            // repoRoot runs inside the detached task too — it is a git
            // subprocess with a 2s timeout, and on the main actor it froze
            // the UI for that long on slow/network filesystems.
            let sourceDir = source.workingDirectory
            let failureMessage: String? = await Task.detached(priority: .userInitiated) {
                guard let repoPath = WorktreeManager.repoRoot(near: sourceDir) else {
                    return "not inside a git repository"
                }
                if case .failure(let err) = WorktreeManager.add(repoPath: repoPath, path: path, mode: mode) {
                    return err.description
                }
                return nil
            }.value
            if let failureMessage {
                return .failure(failureMessage)
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

    /// Cross-view SSH-workspace create request — File menu and command
    /// palette park it here for `SidebarView` to open the destination sheet
    /// (same seam as `pendingCreateWorktreeRequest`; Bool because the sheet
    /// needs no payload).
    var pendingCreateSSHWorkspaceRequest = false

    /// Park the SSH-workspace create request and reveal a hidden sidebar so
    /// `SidebarView` exists to consume it (mirrors
    /// `requestRenameActiveWorkspace`). Callers that want the reveal animated
    /// wrap the call in `withAnimation` — the store stays SwiftUI-free.
    func requestCreateSSHWorkspace() {
        pendingCreateSSHWorkspaceRequest = true
        if sidebarMode == .hidden {
            setSidebarMode(.full)
        }
    }

    /// ⌘W-on-a-sheet request, parked for `SidebarView` to cancel whichever
    /// of its sheets is up (the sheet's `@State` lives in the view, so the
    /// store can only signal). Identity-keyed so repeat requests re-fire.
    /// Runtime-only.
    var sheetDismissRequest: UUID?

    func requestDismissActiveSheet() {
        sheetDismissRequest = UUID()
    }

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
        let parentDir = workspace.worktreeParentId.flatMap { parentId in
            workspaces.first(where: { $0.id == parentId })
        }?.workingDirectory
        let normalizedPath = path.standardizedFileURL.path
        // nil = removed cleanly, or nothing on disk left to delete (repo
        // root unresolvable — parent and worktree directory already gone).
        // Same shape as createWorktree: the task hands back only the
        // failure message the sheet needs.
        let failureMessage: String? = await Task.detached(priority: .userInitiated) {
            // The repoRoot probes run in here too: each is a git subprocess
            // with a 2s timeout, and this chain can run two of them — on the
            // main actor that was a worst-case 4s UI freeze right after the
            // user confirmed the remove sheet.
            let repoPath = parentDir.flatMap { WorktreeManager.repoRoot(near: $0) }
                ?? WorktreeManager.repoRoot(near: path)
                ?? (isDirectory(path) ? path : nil)
            guard let repoPath else { return nil }
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
            if case .failure(let err) = WorktreeManager.remove(repoPath: repoPath, path: path, force: true) {
                return err.description
            }
            // Safe-delete the branch (only if merged) after the worktree
            // dir is gone — `git branch -d` would otherwise refuse with
            // "currently checked out at <path>". Failure on unmerged
            // branches is expected and intentionally ignored; the next
            // Create Worktree on the same name surfaces "branch exists
            // locally" then. No data-loss risk because git refuses to
            // drop unmerged commits without the upper-case `-D`.
            if let realBranch, !realBranch.isEmpty {
                _ = WorktreeManager.deleteBranchIfMerged(repoPath: repoPath, branch: realBranch)
            }
            return nil
        }.value
        if let failureMessage {
            return failureMessage
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
                teardownSessionMonitors(tab)
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
        fileTreeRootOverride = nil
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

    /// Set or clear a workspace's tag. `nil` clears it; picking the colour a
    /// workspace already carries is treated as a clear by the caller, so the
    /// same swatch toggles.
    func setTag(_ tag: WorkspaceTag?, for workspace: Workspace) {
        guard workspace.tag != tag else { return }
        workspace.tag = tag
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

    /// `rawLaunchCommand` (the CLI's `open -e`) rides KOOKY_AGENT verbatim —
    /// see `makeSessionConfig(rawLaunchCommand:)`. Only meaningful with the
    /// plain `.terminal` template; the CLI controller is its one caller.
    @discardableResult
    func addTab(
        in workspace: Workspace,
        pane: Pane? = nil,
        template: AgentTemplate = .terminal,
        initialCwd: URL? = nil,
        conversationId: String? = nil,
        forceResume: Bool = false,
        initialPrompt: String? = nil,
        rawLaunchCommand: String? = nil,
        customTitle: String? = nil,
        activate: Bool = true
    ) -> Session {
        // The raw channel replaces the template's own launch command inside
        // makeSessionConfig, but everything else (Session.agent identity,
        // conversation-id capture, resume persistence) would still run with
        // the template's semantics — a silent mismatch. Keep the invariant
        // executable, not a comment.
        precondition(template.isShell || rawLaunchCommand == nil,
                     "rawLaunchCommand is only valid with a shell template")
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
        let session = spawnSession(template: template, initialCwd: cwd, conversationId: conversationId, forceResume: forceResume, initialPrompt: initialPrompt, sshRemoteHost: workspace.sshRemoteHost, rawLaunchCommand: rawLaunchCommand, customTitle: customTitle)
        wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace, codexRolloutId: session.resumedConversationId)
        target.tabs.append(session)
        // `activate: false` (CLI --no-focus) appends WITHOUT touching the
        // active-tab/pane identity — the browser's background-tab shape. The
        // file-tree override invalidation is identity-coupled, so it stays
        // inside the gate too (nothing active changed).
        if activate {
            target.activeTabId = session.id
            if workspace.activePaneId != target.id {
                workspace.activePaneId = target.id
            }
            invalidateStaleFileTreeRootOverride()
        }
        scheduleSave()
        return session
    }

    @discardableResult
    func duplicateTab(_ session: Session, in workspace: Workspace) -> Session? {
        guard let pane = pane(containing: session, in: workspace) else { return nil }
        return addTab(in: workspace, pane: pane, template: session.agent, initialCwd: session.currentDirectory)
    }

    /// History-row convenience — the seam's true dependency is only the
    /// (agent, conversation, cwd) triple below, so a scanner record just
    /// forwards its three fields.
    ///
    /// Returns the Result rather than an optional on purpose: a refusal here
    /// is a CONFIGURATION problem the user has to go fix (launch options
    /// disabling persistence, an id this agent can't take), so the reason
    /// has to survive far enough to be shown. Collapsing it to nil made a
    /// history click do nothing at all, with no way to find out why.
    @discardableResult
    func resumeAgentSession(_ record: AgentSessionRecord) -> Result<Session, ResumeRefusal> {
        resumeAgentSession(
            agentId: record.agentId, conversationId: record.conversationId, cwd: record.cwd
        )
    }

    /// Resume a conversation: a new tab in the active workspace, running the
    /// agent with its resume arguments, spawned in the conversation's own
    /// directory (a different cwd would break every file reference the
    /// conversation holds — `resolvedSpawnCwd` still falls back to `$HOME`
    /// when the directory is gone, which at least opens a resumable shell).
    /// `forceResume` because both callers (History row click, deep link) are
    /// explicit asks — the `agents.resumeConversations` setting only governs
    /// automatic relaunch-time resume.
    @discardableResult
    func resumeAgentSession(agentId: String, conversationId: String, cwd: URL) -> Result<Session, ResumeRefusal> {
        if let refusal = Self.resumeRefusal(
            agentId: agentId, conversationId: conversationId, options: optionsProvider
        ) {
            return .failure(refusal)
        }
        guard let template = AgentTemplate.builtin(id: agentId) else {
            return .failure(.agentCannotResume)
        }
        let spawned = localSpawn(
            template: template,
            cwd: cwd,
            conversationId: conversationId,
            forceResume: true
        )
        activateWorkspace(spawned.workspace)
        return .success(spawned.session)
    }

    /// Why a resume was refused, decided before any session exists.
    /// Whether a resume would be refused — WITHOUT touching any store, so
    /// callers can decide before they cause side effects. The deep-link and
    /// CLI paths ask first, because reaching `resumeAgentSession` may already
    /// have built a window to land in, and a window created for a request
    /// that then fails is one the user has to close (and one the persistence
    /// layer would otherwise restore at next launch).
    ///
    /// Everything that would make `spawnSession` silently drop the resume id
    /// lives here, so a refusal never leaves a tab that quietly started a
    /// FRESH conversation. It mirrors `spawnSession`'s conditions for THIS
    /// path specifically: `forceResume` is true, no initial prompt is passed,
    /// and `localSpawn` guarantees a local (non-SSH) workspace — so these are
    /// the only ways the id can still vanish.
    @MainActor
    static func resumeRefusal(
        agentId: String,
        conversationId: String,
        options: @MainActor (String) -> String? = { KookySettingsModel.shared.agentOptions[$0] }
    ) -> ResumeRefusal? {
        guard let template = AgentTemplate.builtin(id: agentId), template.supportsResume else {
            return .agentCannotResume
        }
        guard template.persistsConversation(extraOptions: options(template.id)) else {
            return .launchOptionsDisablePersistence
        }
        guard template.normalizedConversationId(conversationId) != nil else {
            return .unusableConversationId
        }
        return nil
    }

    enum ResumeRefusal: Error, Equatable {
        case agentCannotResume
        case launchOptionsDisablePersistence
        case unusableConversationId

        func message(agentId: String, conversationId: String) -> String {
            switch self {
            case .agentCannotResume:
                return "agent '\(agentId)' does not support resuming sessions"
            case .launchOptionsDisablePersistence:
                return "the launch options for '\(agentId)' disable session persistence, so the conversation could not be resumed"
            case .unusableConversationId:
                return "'\(conversationId)' is not a conversation id \(agentId) can resume"
            }
        }
    }

    /// The workspace a LOCAL spawn may land in. An SSH workspace would wrap
    /// the launch in kooky-ssh (`makeSessionConfig(sshHost:)`) — for resume
    /// that also drops the local-only resume id — so: the active workspace
    /// if it's local, else the first local one, else a fresh workspace at
    /// `fallbackCwd` so the request can never silently no-op. One policy for
    /// both explicit-spawn front doors (History/deep-link resume, CLI open);
    /// a future exclusion (worktree children, new workspace kinds) lands in
    /// both by construction.
    /// `cwdIsConfirmed` says the caller has ALREADY established that `cwd`
    /// is a directory — off the main actor, ideally. It matters twice over:
    /// the probe it skips is a main-actor `stat` that a dead network volume
    /// freezes the whole UI on, and its `$HOME` fallback SILENTLY relocates
    /// the launch. For `kooky-cli open -e` that means running the caller's
    /// command somewhere it never asked for — in the home directory rather
    /// than the project — and still answering "ok". A caller that has
    /// verified the path wants a failure there, not a different directory.
    ///
    /// Resume deliberately leaves this false: its recorded directory may be
    /// long gone, and opening a resumable shell at `$HOME` beats refusing.
    /// A nil `cwd` means "wherever the landing workspace already is" — the
    /// caller named no directory, so `addTab`/`addWorkspace` fall back to the
    /// workspace's own working directory rather than to some guess made here.
    /// That is what `kooky-cli open` without `--cwd` asks for.
    func localSpawn(
        template: AgentTemplate,
        cwd: URL?,
        cwdIsConfirmed: Bool = false,
        conversationId: String? = nil,
        forceResume: Bool = false,
        rawLaunchCommand: String? = nil,
        customTitle: String? = nil,
        activate: Bool = true
    ) -> (workspace: Workspace, session: Session) {
        let dir = cwd.map { cwdIsConfirmed ? $0 : resolvedSpawnCwd($0.path) }
        if let existing = (active?.sshRemoteHost == nil ? active : nil)
            ?? workspaces.first(where: { $0.sshRemoteHost == nil }) {
            let session = addTab(
                in: existing,
                template: template,
                initialCwd: dir,
                conversationId: conversationId,
                forceResume: forceResume,
                rawLaunchCommand: rawLaunchCommand,
                customTitle: customTitle,
                activate: activate
            )
            return (existing, session)
        }
        // Nothing local to land in. The fresh workspace's own seed tab IS
        // the launch — adding a tab beside it would leave a blank shell and
        // a second PTY behind every such call. A background spawn keeps the
        // new workspace out of the way too: it appears in the sidebar but
        // the one the user is looking at stays active.
        let workspace = addWorkspace(
            workingDirectory: dir,
            template: template,
            conversationId: conversationId,
            forceResume: forceResume,
            rawLaunchCommand: rawLaunchCommand,
            customTitle: customTitle,
            activate: activate
        )
        // `addWorkspace` always seeds one tab; the fallback keeps the return
        // total rather than force-unwrapping an invariant held elsewhere.
        let session = workspace.activeSession ?? addTab(
            in: workspace,
            template: template,
            initialCwd: dir,
            conversationId: conversationId,
            forceResume: forceResume,
            rawLaunchCommand: rawLaunchCommand,
            customTitle: customTitle,
            activate: activate
        )
        return (workspace, session)
    }

    /// The open tab already running `conversationId`, if any — so a deep link
    /// jumps to the live tab instead of spawning a duplicate `--resume` of a
    /// conversation that's already attached. `conversationId` (the persisted
    /// id, overwritten by hook-reporting agents like Claude on every new
    /// conversation) is the authority when present; `resumedConversationId`
    /// (spawn-time, written once, never updated) only counts when no
    /// persisted id exists — else a Claude tab that `/clear`ed to a new
    /// conversation would still match its old resume id and swallow the
    /// resume. Known residue this can't see: a non-reporting agent's
    /// persisted id survives the agent exiting or the resume setting being
    /// off, so a match can reveal a tab that RAN the conversation but no
    /// longer does — the safe direction (the user lands on a related tab and
    /// can resume from History) versus duplicate-resuming a live one.
    func findOpenConversation(agentId: String, conversationId: String)
        -> (workspace: Workspace, session: Session)? {
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    guard session.agent.rosterId == agentId else { continue }
                    let matches = session.conversationId != nil
                        ? session.conversationId == conversationId
                        : session.resumedConversationId == conversationId
                    if matches { return (workspace, session) }
                }
            }
        }
        return nil
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
        invalidateStaleFileTreeRootOverride()
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
        invalidateStaleFileTreeRootOverride()
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
                wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace, codexRolloutId: session.conversationId)
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
        teardownSessionMonitors(session, keepForTransfer: true)
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

    /// Drops the tab this store was born with, once the caller that caused
    /// the WINDOW to exist has landed the tab it actually wanted. A window
    /// built to serve one request (`kooky-cli open`, a `kooky://resume`
    /// arriving with zero terminal windows open) comes up with a seed tab of
    /// its own; leaving it behind means one request produced two tabs and
    /// two PTYs, and the caller — which is told about exactly one id — can
    /// neither find nor clean up the other. `discardTab` rather than
    /// `closeTab` keeps a synthetic placeholder out of the reopen stack.
    ///
    /// Deliberately gated on this store still having a newborn's exact shape
    /// (one workspace, and now exactly that seed plus the caller's tab):
    /// callers derive "I built this window" from the window layer, which has
    /// a narrow window where it can hand back a controller whose window is
    /// already closing. Being wrong by leaving a blank tab behind is
    /// recoverable; being wrong by closing a real session is not.
    func discardSeedTab(keeping session: Session) {
        guard workspaces.count == 1, let workspace = workspaces.first else { return }
        let tabs = workspace.root.allPanes.flatMap(\.tabs)
        guard tabs.count == 2, let seed = tabs.first(where: { $0.id != session.id }) else { return }
        discardTab(seed, in: workspace)
    }

    private func closeTab(_ session: Session, in workspace: Workspace, recordHistory: Bool) {
        guard let pane = pane(containing: session, in: workspace),
              let idx = pane.tabs.firstIndex(where: { $0.id == session.id }) else { return }
        // Closing the last tab of a worktree workspace cascades through
        // detachSession → closePane → closeWorkspace, which would bypass
        // the confirm sheet. Reroute here before any state mutates so
        // the sheet's cancel path can keep the tab open.
        if workspace.closingLastTabCascadesIntoWorktreeRemoval {
            requestCloseWorkspace(workspace)
            return
        }
        if recordHistory {
            recordClosedTab(session, pane: pane, workspace: workspace)
        }
        teardownSessionMonitors(session)
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

    /// Menu validation uses this instead of exposing the history itself.
    var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

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
        invalidateStaleFileTreeRootOverride()
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
        suspendSizePropagationForLayoutAnimation(workspace.root.allEngines)
        workspace.activePaneId = paneId
        workspace.zoomedPaneId = workspace.isZoomed(paneId) ? nil : paneId
        invalidateStaleFileTreeRootOverride()
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
        let newSession = spawnSession(template: template, initialCwd: cwd, sshRemoteHost: workspace.sshRemoteHost)
        wireSessionCallbacks(engine: newSession.engine, session: newSession, workspace: workspace, codexRolloutId: newSession.resumedConversationId)
        let newPane = Pane(tabs: [newSession], activeTabId: newSession.id)
        let firstChild = PaneNode(pane: existing)
        let secondChild = PaneNode(pane: newPane)
        leafNode.content = .split(orientation: orientation, first: firstChild, second: secondChild, fraction: 0.5)
        if orientation == .horizontal {
            KookyWindowLayout.rebalanceHorizontalSplits(
                in: workspace.root,
                alongPathTo: leafNode
            )
        }
        workspace.activePaneId = newPane.id
        // Splitting while zoomed = "I want to see what I'm creating". Drop
        // zoom so the new pane is visible. Guarded so a no-op write
        // doesn't trigger an extra Observable invalidation.
        if workspace.zoomedPaneId != nil { workspace.zoomedPaneId = nil }
        invalidateStaleFileTreeRootOverride()
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
        // closed pane's git + Codex/Kiro watchers (DispatchSource fds) leak.
        // Idempotent: the root path re-stops via closeWorkspace (no-op).
        for tab in pane.tabs {
            teardownSessionMonitors(tab)
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
        invalidateStaleFileTreeRootOverride()
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
        invalidateStaleFileTreeRootOverride()
        if changed { scheduleSave() }
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
        if event != .ended {
            startCodexUsageIfNeeded(for: session)
            startKiroConversationIfNeeded(for: session)
        }
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

    /// Re-resolves every live session's `agent` against the current templates.
    ///
    /// `Session.agent` is a value snapshot taken at spawn, so a Settings edit
    /// to a custom agent — importing a logo, renaming it — reaches new tabs
    /// but never the ones already open. Matched by id, so a session keeps its
    /// identity; `.terminal` and sessions whose agent no longer exists are
    /// left alone. Assignment is gated on an actual change because
    /// `@Observable` notifies every tab/sidebar observer even on a same-value
    /// write, and this runs on every settings save.
    func refreshAgentTemplates() {
        let byId = Dictionary(
            AgentTemplate.all.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    guard let fresh = byId[session.agent.id], fresh != session.agent else { continue }
                    session.agent = fresh
                }
            }
        }
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
        isTerminated = true
        pendingSave?.cancel()
        pendingSave = nil
        for workspace in workspaces {
            for pane in workspace.root.allPanes {
                for tab in pane.tabs {
                    tab.engine.terminate()
                }
            }
        }
        for entry in gitWatches.values {
            entry.pendingStatusRefresh?.cancel()
            entry.watcher.cancel()
        }
        gitWatches.removeAll()
        sessionGitWatch.removeAll()
        codexUsageMonitor.stopAll()
        kiroConversationMonitor.stopAll(removeRecords: true)
        fileTree.cancel()
    }

    // MARK: - Internals

    private func pane(containing session: Session, in workspace: Workspace) -> Pane? {
        workspace.root.pane(containingSessionId: session.id)
    }

    private func restore(from state: PersistedState) {
        let fm = FileManager.default
        for ws in state.workspaces {
            let sshHost = Self.normalizedSSHHost(ws.sshRemoteHost)
            guard let root = restorePane(ws.root, fm: fm, sshRemoteHost: sshHost) else { continue }
            let workspace = Workspace(
                id: ws.id,
                workingDirectory: URL(fileURLWithPath: ws.workingDirectoryPath),
                root: root
            )
            workspace.customTitle = ws.customTitle
            workspace.worktreeParentId = ws.worktreeParentId
            workspace.worktreeBranch = ws.worktreeBranch
            workspace.worktreePath = ws.worktreePath.map { URL(fileURLWithPath: $0) }
            workspace.sshRemoteHost = sshHost
            // Exactly one of the two colour fields is ever written, so each
            // maps to its own case. An unknown preset (a colour a newer kooky
            // added, seen by an older build) restores untagged rather than
            // becoming a custom tag whose hex is the literal string `teal`,
            // which would render gray and read as a colour the user picked.
            // Both paths lose the value on the next save, since the encoder
            // re-derives every field from the model — preserving it would mean
            // echoing back unmapped fields, which isn't worth the machinery for
            // a downgrade-only case.
            if let preset = ws.tagPreset.flatMap(WorkspaceColorTag.init(rawValue:)) {
                workspace.tag = WorkspaceTag(color: .preset(preset), name: ws.tagName)
            } else if let hex = ws.tagCustomHex {
                workspace.tag = WorkspaceTag(color: .custom(hex: hex), name: ws.tagName)
            }
            // Wire engines now that workspace is constructed (engines need
            // the workspace ref for cwd-sync callbacks).
            for pane in workspace.root.allPanes {
                for session in pane.tabs {
                    wireSessionCallbacks(engine: session.engine, session: session, workspace: workspace, codexRolloutId: session.resumedConversationId)
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
        sidebarContent = state.sidebarContent ?? .workspaces
        rightSidebarContent = state.rightSidebarContent ?? .agents
        sidebarWidth = state.sidebarWidth
            .map { SidebarView.clampWidth(CGFloat($0)) }
            ?? SidebarView.fullWidth
        collapsedInfoSections = Set(state.collapsedInfoSections ?? [])
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
                    sshRemoteHost: sshRemoteHost
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
    private func spawnSession(template: AgentTemplate, initialCwd: URL, sessionId: UUID = UUID(), conversationId: String? = nil, forceResume: Bool = false, initialPrompt: String? = nil, sshRemoteHost: String? = nil, rawLaunchCommand: String? = nil, customTitle: String? = nil) -> Session {
        let engine = engineFactory()
        let extraOptions = optionsProvider(template.id)
        let persistsConversation = template.persistsConversation(extraOptions: extraOptions)
        // Resume gated by user setting — `resumeConversations` flips this off
        // when the user wants every agent tab to start fresh without
        // losing the persisted conversation id (it stays on disk so the
        // setting can be flipped back on later). Plain shells ignore the value
        // through `makeSessionConfig`, so we don't have to re-check here.
        // `forceResume` bypasses the gate: picking a session from the History
        // list is an explicit ask, not the automatic relaunch the setting
        // exists to switch off.
        var normalizedConversationId = persistsConversation
            ? template.normalizedConversationId(conversationId)
            : nil
        let resumeId = (forceResume || resumeProvider()) ? normalizedConversationId : nil
        // Grok accepts a caller-assigned UUID for a fresh session. Generate it
        // before launch and persist the same value immediately, eliminating
        // the hook/file-discovery race every other agent has to solve. When
        // resume is disabled, an existing saved id deliberately gets replaced
        // with a new one so this launch starts fresh.
        let newSessionId: String?
        if persistsConversation, resumeId == nil, template.preallocatesConversationId {
            let id = UUID().uuidString
            normalizedConversationId = id
            newSessionId = id
        } else {
            newSessionId = nil
        }
        // The template owns SSH composition (kooky-ssh wrapping, dropping the
        // local-only resume id, forcing a wrapped shell) — see
        // `makeSessionConfig(sshHost:)`.
        let sshHost = Self.normalizedSSHHost(sshRemoteHost)
        var config = template.makeSessionConfig(
            extraOptions: extraOptions,
            resumeId: resumeId,
            newSessionId: newSessionId,
            initialPrompt: initialPrompt,
            sshHost: sshHost,
            rawLaunchCommand: rawLaunchCommand
        )
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
            customTitle: customTitle,
            conversationId: normalizedConversationId
        )
        // Mirror the drops `makeSessionConfig` applies downstream, so the
        // field records what actually reached the command line: an SSH host
        // never carries the LOCAL resume id (M5.rrrr), a non-empty initial
        // prompt suppresses the resume fragment (M5.hh), and a template
        // without a resume strategy never emits one at all.
        let promptSuppressesResume = !(initialPrompt?.isEmpty ?? true)
        session.resumedConversationId = (sshHost == nil && !promptSuppressesResume && template.supportsResume)
            ? resumeId : nil
        if let sshHost {
            session.sshWorkspaceHost = sshHost
            // Optimistic: the remote shim's `running` marker confirms once
            // the connection + rc replay settle; until then the tab already
            // reads as "agent starting", matching the local launch feel.
            if !template.isShell { session.activityState = .running }
        }
        return session
    }

    /// Trimmed, non-empty SSH destination or nil. Single gate for every
    /// entry point (create sheet, persistence restore, spawn) so a
    /// whitespace-only host can never mark a workspace remote. Same
    /// blank-collapses-to-nil rule as titles — one rule, one place.
    static func normalizedSSHHost(_ raw: String?) -> String? {
        raw.flatMap(normalizedTitle)
    }

    /// `codexRolloutId` is the id of the rollout file this session ALREADY
    /// has on disk, nil when none exists yet — it steers the Codex usage
    /// monitor's file resolution. Spawn-path callers pass
    /// `session.resumedConversationId` (the post-gate value `spawnSession`
    /// put on the command line — re-deriving `resumeProvider() ?
    /// conversationId : nil` would miss a forced History-list resume);
    /// the cross-window attach path passes `session.conversationId` instead,
    /// because a live Codex tab's rollout predates the DESTINATION store's
    /// monitor snapshot and would otherwise be excluded as another session's
    /// file (the id is reliable there: the source window's monitor backfilled
    /// it while the tab ran).
    private func wireSessionCallbacks(engine: any TerminalEngine, session: Session, workspace: Workspace, codexRolloutId: String?) {
        // Initial refresh — without these, the status bar stays empty until
        // the user `cd`s or runs a command. Both fetchers silently hide
        // results for non-applicable cwds, so the calls are harmless.
        updateGitWatch(for: session)
        refreshGitStatus(for: session)
        refreshEnvironment(for: session)
        startCodexUsageIfNeeded(
            for: session,
            resumingConversationId: codexRolloutId
        )
        startKiroConversationIfNeeded(for: session)
        // Paste-time upload routing. Deliberately `sshWorkspaceHost` (spawn
        // pinned), NOT `remoteHost`: the latter is the status-bar display
        // signal with a marker→command-finished lifecycle that a remote
        // shell's own OSC 133;D can clear mid-connection.
        engine.pasteUploadHostProvider = { [weak session] in session?.sshWorkspaceHost }
        // File paths printed by an SSH shell live on the remote machine. Keep
        // ordinary web links openable, but prevent Cmd+Click from treating a
        // remote absolute path as a coincidentally-existing local file.
        engine.isRemoteSessionProvider = { [weak session] in
            session?.sshWorkspaceHost != nil || session?.remoteHost != nil
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
            // Git status AND the watcher hub refresh on EVERY prompt, even an
            // unchanged cwd — neither is safe to gate on cwdChanged:
            //  • refreshGitStatus: an external editor can change the working
            //    tree's uncommitted-file count without touching .git, which the
            //    watcher's fs source never sees; this per-prompt fetch (which
            //    result-dedups) is the only catch.
            //  • updateGitWatch: its per-prompt re-probe is what finally
            //    attaches a watcher when a repo is created in place
            //    (`git init` / `clone .`) with no cd. Gating it would strand
            //    that case (issue #29 review). Unchanged-cwd prompts inside a
            //    repo cost two dictionary hits, no filesystem walk.
            self?.updateGitWatch(for: session)
            self?.refreshGitStatus(for: session)
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
            // A `kooky-command:*` title is the preexec-reported command line,
            // not a visible title. Checked first: it's by far the most frequent
            // marker (one per command). Riding this stream rather than the
            // socket is what guarantees it lands before the OSC 133;D result it
            // labels — see `CommandMarker`.
            if let command = CommandMarker.parseTitle(title) {
                session.lastCommandText = command
                return
            }
            // A `kooky-remote-login:*` title is an ssh-destination marker, not
            // a visible title — record the host and stop before it reaches
            // `terminalTitle`. Cleared ONLY by the wrapper's logout marker
            // below: OSC 133;D is not "ssh exited" (a remote shell's own
            // integration emits it per remote command, through the wire).
            if let host = RemoteLoginMarker.parseTitle(title) {
                session.remoteHost = host
                // The local preexec reported `ssh host`, but OSC 133 results
                // arriving after this marker belong to commands inside the
                // remote shell. Drop the local command label rather than pair
                // it with an unrelated remote exit code.
                session.lastCommandText = nil
                return
            }
            if RemoteLoginMarker.isLogoutTitle(title) {
                session.remoteHost = nil
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
            session.applyTerminalTitle(next)
        }
        engine.onFocus = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.activateTab(session, in: workspace)
        }
        engine.onCommandFinished = { [weak self, weak session] exit, duration in
            guard let session else { return }
            // A remote agent surfaced via an OSC marker (transientAgent) emits
            // no `ended` marker when the ssh drops abnormally (network loss,
            // killed connection), so command-finished stays its safety net.
            // Safe even though a REMOTE shell integration's 133;D also lands
            // here: while a remote agent runs it owns the remote foreground,
            // so no remote prompt (hence no D) can fire mid-agent.
            // `remoteHost` is different — it must survive remote-command D's
            // for the whole connection, so it's cleared by the wrapper's
            // logout marker in onTitleChange, NOT here.
            if session.transientAgent != nil {
                session.transientAgent = nil
                session.activityState = .idle
            }
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
            // Kiro has returned control to the shell too, so its full ACP
            // trace is now static and can be removed after the id was saved.
            self?.kiroConversationMonitor.stop(sessionId: session.id, removeRecord: true)
            session.lastCommandExit = exit
            session.lastCommandDuration = duration
            // Inspector snapshot — taken here (completion), NOT cleared on
            // input like the pair above. Exit-less results (a shell that
            // omits the 133;D field) are skipped, matching the old
            // `lastCommandExit != nil` display gate.
            if let exit {
                session.lastCompletedCommand = .init(
                    text: session.lastCommandText,
                    exit: exit,
                    duration: duration
                )
            }
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
            // Do not let a failed/missing command hook pair the next OSC 133
            // result with stale text from the previous command. Its preexec
            // report will repopulate this before the new result arrives.
            session.lastCommandText = nil
        }
        engine.onProcessExitedCleanly = { [weak self, weak session, weak workspace] in
            guard let self, let session, let workspace else { return }
            self.closeTab(session, in: workspace)
        }
        engine.onDesktopNotification = { [weak self, weak session] title, body in
            guard let self, let session else { return }
            self.onSessionAlert(session.id, .programNotification(title: title, body: body))
        }
        engine.onLinkHover = { [weak session] url in
            session?.hoveredLinkURL = url
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
        if let gitDir = sessionGitWatch[session.id]?.gitDir,
           gitWatches[gitDir]?.subscribers.contains(session.id) == true {
            scheduleGitStatusRefresh(for: gitDir)
        } else {
            gitStatusFetcher.fetch(id: session.id.uuidString, cwd: session.currentDirectory) { [weak session] status in
                guard let session, session.gitStatus != status else { return }
                session.gitStatus = status
            }
        }
        // Piggyback the file tree's per-file diff on the SAME triggers that
        // refresh the status bar (spawn / every prompt / command finished /
        // GitWatcher) — single chokepoint, so the tree's +/− badges and the
        // status bar's totals can never drift.
        refreshFileTreeGitDiff(ifVisibleFor: [session.id])
    }

    /// Stable dedup key for the tree's diff fetch: the tree is a per-store
    /// singleton, so a NEWER fetch must invalidate ANY older in-flight one —
    /// keying by workspace id would let a slow pre-switch fetch land after
    /// the new workspace's fresh result and blank its badges for a beat.
    private let fileTreeDiffFetchKey = "file-tree"

    /// Piggyback gate shared by every status-refresh path: refresh the
    /// tree's diff only while it is showing AND one of the event's sessions
    /// can be on screen (in the active workspace's pane tree).
    /// `refreshFileTreeGitDiff()` stays callable directly for the tree's
    /// own mount/root-change hooks.
    private func refreshFileTreeGitDiff(ifVisibleFor ids: some Sequence<UUID>) {
        guard fileTree.isShowing, let activeRoot = active?.root,
              ids.contains(where: { activeRoot.pane(containingSessionId: $0) != nil }) else { return }
        refreshFileTreeGitDiff()
    }

    /// Fetches per-file `+/−` counts for the file tree's current root and
    /// pushes them into the model. Also called by `FileTreeView` on mount
    /// and root change (the chokepoint above can't see those). Gated on the
    /// model's own mounted predicate — zero git cost while the tree isn't
    /// on screen (workspaces mode, compact, hidden sidebar).
    func refreshFileTreeGitDiff() {
        guard fileTree.isShowing, let root = fileTree.rootURL else { return }
        gitStatusFetcher.fetchFileDiffs(id: fileTreeDiffFetchKey, cwd: root) { [weak self] diffs in
            self?.fileTree.applyGitDiff(diffs)
        }
    }

    /// Diff pill's click-time refresh: the popover's numstat snapshot carries
    /// fresher totals than the last prompt-driven fetch, so fold them in
    /// through the same seams a fetch result uses — mark any in-flight fetch
    /// stale (a slower, older one must not overwrite this newer result) and
    /// re-run the file-tree badge piggyback so tree badges and pill totals
    /// can't drift (the M5.qqqq sums-by-construction invariant).
    func applyDiffSnapshot(_ diff: GitDiffSnapshot, for session: Session, cwdPath: String) {
        // Ignore a result whose world moved while git was in flight: the cwd
        // changed, or the snapshot's repo isn't the one the pill currently
        // shows (mid-`cd` across repos — the pill's branch/root still belong
        // to the old repo; let the in-flight prompt fetch land the coherent
        // new status instead of folding foreign totals into it).
        guard session.currentDirectory.path == cwdPath,
              session.gitStatus.repoRoot == diff.repoRoot else { return }
        var refreshed = session.gitStatus
        refreshed.filesChanged = diff.filesChanged
        refreshed.insertions = diff.insertions
        refreshed.deletions = diff.deletions
        if refreshed != session.gitStatus {
            // Shared broadcasts snapshot this lane and skip only this session
            // when the token moves; the other subscribers must still receive
            // the in-flight repo result.
            gitStatusFetcher.invalidateInFlight(id: session.id.uuidString)
            session.gitStatus = refreshed
        }
        // Outside the totals gate: the file-level distribution can change
        // while totals stay equal (revert a line here, add one there) — the
        // tree's badges must follow the popover's rows regardless. The
        // invalidate lifts the tree lane's 50ms coalescing window so this
        // edge-triggered refresh can never be stood in for by an older poll.
        gitStatusFetcher.invalidateInFlight(id: fileTreeDiffFetchKey)
        refreshFileTreeGitDiff(ifVisibleFor: [session.id])
    }

    /// Starts (or re-points) the Codex usage watcher for a Codex session.
    /// No-op for every other agent. Called on session wire-up (covers a tab
    /// launched as Codex or restored as one) and on the `running` lifecycle
    /// event (covers a manually-typed `codex`, and a relaunch that opens a
    /// fresh rollout file). `start` is idempotent for an unchanged resolution.
    private func startCodexUsageIfNeeded(
        for session: Session,
        resumingConversationId: String? = nil
    ) {
        let key = session.displayAgent.rosterId
        guard key == AgentTemplate.codex.id else { return }
        // Resolve CODEX_HOME from the session's live shell env (a Dock-launched
        // kooky doesn't inherit it; the codex child does). The monitor snapshots
        // existing rollouts on this first call to tell this session's own file
        // apart from a prior/concurrent run's.
        let root = CodexUsageMonitor.sessionsRoot(shellEnv: session.shellEnvironment)
        codexUsageMonitor.start(
            sessionId: session.id,
            cwd: session.currentDirectory,
            sessionsRoot: root,
            resumingConversationId: resumingConversationId,
            conversationUpdate: { [weak self, weak session] id in
                guard let self, let session else { return }
                self.applyConversationId(conversationId: id, sessionId: session.id)
            }
        ) { [weak session] usage in
            guard let session, session.codexUsage != usage else { return }
            session.codexUsage = usage
        }
    }

    // MARK: - Git watcher hub

    /// (Re)subscribes a session to the shared watcher for its cwd's gitdir.
    /// Runs on every prompt — that per-prompt retry is what attaches a
    /// watcher once a repo appears in place — but the common unchanged-cwd
    /// prompt costs two dictionary hits and no filesystem walk.
    private func updateGitWatch(for session: Session) {
        let cwdPath = session.currentDirectory.path
        let cached = sessionGitWatch[session.id]
        if let cached, cached.cwdPath == cwdPath, let gitDir = cached.gitDir {
            // Same repo as last prompt: just confirm the shared watcher
            // still holds live kqueue fds (gitdir deleted then recreated) —
            // the per-prompt retry the old per-session watch() provided. A
            // cached "not a repo" falls through and re-probes instead: the
            // git-init-in-place attach path.
            if let watcher = gitWatches[gitDir]?.watcher, !watcher.isAttached {
                watcher.watch(cwd: session.currentDirectory)
            }
            return
        }
        let resolved = GitWatcher.findGitDir(near: session.currentDirectory)
        let gitDir = resolved?.path
        sessionGitWatch[session.id] = (cwdPath, gitDir)
        // A cd WITHIN the same repo keeps the subscription (and the fds) —
        // the old per-session watcher tore down + reopened both fds here.
        guard cached?.gitDir != gitDir else { return }
        if let previous = cached?.gitDir {
            unsubscribeGitWatch(sessionId: session.id, from: previous)
        }
        if let gitDir, let resolved {
            // A direct non-repo fetch may still be in flight from the old
            // cwd. Moving onto the shared repo lane must make that result
            // stale, otherwise a late EMPTY status can erase the repo state.
            gitStatusFetcher.invalidateInFlight(id: session.id.uuidString)
            subscribeGitWatch(session: session, to: gitDir, resolvedGitDir: resolved)
        }
    }

    private func subscribeGitWatch(session: Session, to gitDir: String, resolvedGitDir: URL) {
        let entry: GitWatch
        if let existing = gitWatches[gitDir] {
            entry = existing
        } else {
            let watcher = GitWatcher { [weak self] in
                self?.scheduleGitStatusRefresh(for: gitDir)
            }
            watcher.watch(cwd: session.currentDirectory, resolvedGitDir: resolvedGitDir)
            entry = GitWatch(watcher: watcher)
            gitWatches[gitDir] = entry
        }
        entry.subscribers.insert(session.id)
    }

    private func unsubscribeGitWatch(sessionId: UUID, from gitDir: String) {
        guard let entry = gitWatches[gitDir] else { return }
        entry.subscribers.remove(sessionId)
        if entry.subscribers.isEmpty {
            let removed = gitWatches.removeValue(forKey: gitDir)
            removed?.pendingStatusRefresh?.cancel()
            removed?.watcher.cancel()
        }
    }

    /// Test-only probe: the shared-watcher invariants (one watcher per
    /// gitdir, subscriber counting) have no UI-observable surface.
    var gitWatchHubStats: (watchers: Int, subscriptions: Int) {
        (gitWatches.count, gitWatches.values.reduce(0) { $0 + $1.subscribers.count })
    }

    /// Test-only probe for the number of actual status fetch batches (after
    /// both the shared-repo fan-in and fetcher's same-lane coalescing).
    var gitStatusDispatchCount: Int { gitStatusFetcher.statusDispatchCount }

    /// Test-only probe for the two freshness lanes touched by a click-time
    /// diff snapshot. The session lane must advance; the shared lane must not.
    func gitStatusLaneTokens(for session: Session) -> (session: Int, shared: Int?) {
        let sessionToken = gitStatusFetcher.currentToken(id: session.id.uuidString)
        let sharedToken = sessionGitWatch[session.id]?.gitDir.map {
            gitStatusFetcher.currentToken(id: $0)
        }
        return (sessionToken, sharedToken)
    }

    /// Close-site teardown: drops the session's subscription, and the shared
    /// watcher with it when this was the last subscriber.
    private func removeGitWatch(sessionId: UUID) {
        guard let gitDir = sessionGitWatch.removeValue(forKey: sessionId)?.gitDir else { return }
        unsubscribeGitWatch(sessionId: sessionId, from: gitDir)
    }

    /// Every monitor a live session holds, torn down in one place — the
    /// close paths used to hand-copy this block, and a missed line leaked
    /// kqueue fds with no UI surface. `keepForTransfer` is the cross-window
    /// surrender variant: the destination store re-wires the session, so
    /// the engine stays alive and agent records survive.
    private func teardownSessionMonitors(_ session: Session, keepForTransfer: Bool = false) {
        removeGitWatch(sessionId: session.id)
        codexUsageMonitor.stop(sessionId: session.id)
        kiroConversationMonitor.stop(sessionId: session.id, removeRecord: !keepForTransfer)
        if !keepForTransfer { session.engine.terminate() }
    }

    /// Collects prompt/spawn/watcher triggers for one gitdir. Keeping the
    /// pending task on the shared entry makes fan-in explicit: N tabs can
    /// request refresh independently while only one batch reaches git.
    private func scheduleGitStatusRefresh(for gitDir: String) {
        guard let entry = gitWatches[gitDir], entry.pendingStatusRefresh == nil else { return }
        entry.pendingStatusRefresh = Task { @MainActor [weak self, weak entry] in
            try? await Task.sleep(for: Self.sharedGitRefreshDelay)
            guard !Task.isCancelled, let self, let entry,
                  self.gitWatches[gitDir] === entry else { return }
            entry.pendingStatusRefresh = nil
            self.performSharedGitStatusRefresh(gitDir)
        }
    }

    /// Shared-watcher fan-out. ONE git run per repo event/prompt burst, its result
    /// broadcast to every subscribed session — same gitdir means same HEAD
    /// and same working tree, so their statuses are identical by
    /// construction. This is what turns "ten tabs on one repo, one commit"
    /// from ten fetches (twenty forks) into one fetch. The gitdir path
    /// doubles as the fetch lane key. Every new trigger waits 60ms after the
    /// prior dispatch, beyond the fetcher's 50ms coalescing window, so a
    /// genuinely later burst cannot be swallowed by the previous batch.
    private func performSharedGitStatusRefresh(_ gitDir: String) {
        guard let entry = gitWatches[gitDir] else { return }
        var anchor: Session?
        for id in entry.subscribers {
            guard let session = findSession(id: id) else { continue }
            // Skip sessions whose cwd was deleted under them (shell still
            // parked there): `git -C <gone>` fails and would broadcast an
            // EMPTY status over every healthy tab. Their own prompt fetch
            // reports the empty state where it belongs (Codex review P2).
            if isDirectory(session.currentDirectory) { anchor = session; break }
        }
        guard let anchor else { return }
        // Snapshot each subscriber's own lane at dispatch: a newer
        // out-of-band result (the click-time diff snapshot) advances that
        // lane, and this shared older result must not overwrite it.
        let laneStamps = Dictionary(uniqueKeysWithValues: entry.subscribers.map { id in
            (id, gitStatusFetcher.currentToken(id: id.uuidString))
        })
        gitStatusFetcher.fetch(id: gitDir, cwd: anchor.currentDirectory) { [weak self] status in
            // Re-read the subscriber set at completion (sessions that closed
            // mid-fetch drop out), then broadcast in ONE pane-tree pass
            // instead of a per-id tree search.
            guard let self, let ids = self.gitWatches[gitDir]?.subscribers else { return }
            for workspace in self.workspaces {
                for pane in workspace.root.allPanes {
                    for tab in pane.tabs where ids.contains(tab.id) && tab.gitStatus != status {
                        if let stamp = laneStamps[tab.id],
                           self.gitStatusFetcher.currentToken(id: tab.id.uuidString) != stamp {
                            continue
                        }
                        tab.gitStatus = status
                    }
                }
            }
        }
        refreshFileTreeGitDiff(ifVisibleFor: entry.subscribers)
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
            rightSidebarMode: rightSidebarMode,
            sidebarContent: sidebarContent,
            rightSidebarContent: rightSidebarContent,
            sidebarWidth: Double(sidebarWidth),
            collapsedInfoSections: collapsedInfoSections.isEmpty
                ? nil
                : collapsedInfoSections.sorted()
        )
    }

    private func startKiroConversationIfNeeded(for session: Session) {
        let key = session.displayAgent.rosterId
        guard key == AgentTemplate.kiro.id else { return }
        let path = KookyShellIntegration.kiroACPRecordPath(for: session.id)
        kiroConversationMonitor.start(sessionId: session.id, path: path) { [weak self, weak session] id in
            guard let self, let session else { return }
            self.applyConversationId(conversationId: id, sessionId: session.id)
        }
    }
}
