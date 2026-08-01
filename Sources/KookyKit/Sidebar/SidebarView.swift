import SwiftUI

/// Bundles every modal sheet the sidebar can show so they share one
/// `.sheet(item:)` modifier. `.sheet(isPresented:)` per state would race
/// when switching directly between modes (create → confirm-remove).
private enum SidebarSheet: Identifiable {
    case createSSHWorkspace
    case authenticateRemote(Session)
    case createWorktree(Workspace)
    case confirmRemoveWorktree(Workspace)
    case confirmCloseOthers(WorkspaceStore.BulkRemovalRequest)
    case confirmCloseSource(WorkspaceStore.CloseSourceRequest)

    var id: String {
        switch self {
        case .createSSHWorkspace: return "create-ssh-workspace"
        case .authenticateRemote(let session): return "authenticate-\(session.id.uuidString)"
        case .createWorktree(let ws): return "create-\(ws.id.uuidString)"
        case .confirmRemoveWorktree(let ws): return "remove-\(ws.id.uuidString)"
        case .confirmCloseOthers(let req): return "close-others-\(req.keeping.id.uuidString)"
        case .confirmCloseSource(let req): return "close-source-\(req.source.id.uuidString)"
        }
    }
}

struct SidebarView: View {
    static let fullWidth: CGFloat = 220
    static let compactWidth: CGFloat = 52
    /// Ceiling for the user-draggable full-mode width (`fullWidth` is the
    /// floor — the sidebar only grows from its design width).
    static let maxWidth: CGFloat = 480

    /// Single source for the width policy — floor `fullWidth`, ceiling
    /// `maxWidth`, and whole points (fractional widths land row text on
    /// per-frame-shifting sub-pixel boundaries → the mono diff badges
    /// visibly shimmer during a drag). Shared by the drag gesture and the
    /// state.json restore path so the two can't diverge.
    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, fullWidth), maxWidth).rounded()
    }

    // Trailing-edge resize drag (full mode only). Mirrors the split
    // divider's suspend pattern: begin once per drag (gated), capture the
    // engines so onEnded / the handle's onDisappear end the SAME set.
    @State private var resizeDragStartWidth: CGFloat?
    @State private var sidebarResizeSuspended = false
    @State private var sidebarSuspendedEngines: [any TerminalEngine] = []
    @Bindable var store: WorkspaceStore
    /// Passed as a parameter (not read live off the store) so the exiting
    /// view keeps its LAST VISIBLE mode during the hide transition: a
    /// compact→hidden switch otherwise re-evaluates `isCompact` against the
    /// already-`.hidden` store value → false → the sidebar snaps to full
    /// width while fading out (the "flash of full mode"). Mirrors
    /// `AgentOverviewSidebar(mode:)`, which never had this flash.
    let mode: SidebarMode
    /// Id of the workspace currently being dragged. Set by `.onDrag`, cleared
    /// on drop. Lets each row compute whether the drag origin is above or
    /// below it so the drop indicator can flip edges.
    @State private var draggingWorkspaceId: UUID?
    /// True while a Finder folder drag is hovering the sidebar — gates the
    /// drop-zone outline so the user sees that releasing here opens a new
    /// workspace.
    @State private var isFolderDropTargeted = false
    /// Source workspace ids whose worktree subtree the user collapsed.
    /// Default behaviour is expanded — only ids the user explicitly closed
    /// land here. Ephemeral by design: a kooky relaunch always shows every
    /// worktree on first paint so nothing is hidden by stale state.
    @State private var collapsedParents: Set<UUID> = []
    /// Active modal sheet (create worktree / confirm-delete worktree).
    /// Nil = no sheet. Set by row callbacks and an onChange observer that
    /// watches `store.pendingRemovalRequest` for ⌘⇧W routed via AppDelegate.
    @State private var sheet: SidebarSheet?

    /// Invisible trailing-edge strip that widens the sidebar by drag —
    /// full mode only (compact is fixed, hidden is hidden). A width drag
    /// re-frames every libghostty NSView per frame → SIGWINCH storm (conda
    /// scrollback-wipe, issue #29) without the divider-style suspension.
    private var resizeHandle: some View {
        DividerHandle(orientation: .horizontal)
            .frame(width: 7)
            .gesture(resizeGesture)
            .onDisappear {
                // Backstop: ⌘⌃S mid-drag unmounts the handle before onEnded
                // can fire — end the captured engines so the suspension
                // refcount stays balanced (mirrors the split divider).
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines { engine.endSizePropagationSuspension() }
                    sidebarSuspendedEngines = []
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeDragStartWidth == nil { resizeDragStartWidth = store.sidebarWidth }
                let proposed = (resizeDragStartWidth ?? store.sidebarWidth) + value.translation.width
                let clamped = Self.clampWidth(proposed)
                guard abs(clamped - store.sidebarWidth) > .ulpOfOne else { return }
                if !sidebarResizeSuspended {
                    sidebarResizeSuspended = true
                    sidebarSuspendedEngines = store.active?.root.allEngines ?? []
                    for engine in sidebarSuspendedEngines { engine.beginSizePropagationSuspension() }
                }
                store.sidebarWidth = clamped
            }
            .onEnded { _ in
                resizeDragStartWidth = nil
                // End + flush once — only when the engine's refcount hits 0
                // (a concurrent zoom / status-bar suspension flushes on ITS
                // own release).
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines {
                        engine.endSizePropagationSuspension()
                        if !engine.suspendsSizePropagation { engine.flushSize() }
                    }
                    sidebarSuspendedEngines = []
                }
                store.flushPersistence()
            }
    }

    /// Whether the file tree is the mounted middle surface (files mode, full
    /// width — compact can't fit a tree and falls back to the icon list).
    /// Single source for the body's content switch and the folder-drop
    /// rejection below: the drop zone must reject exactly while the tree —
    /// whose rows vend `public.file-url` drags — is what's on screen.
    private var fileTreeIsMounted: Bool {
        store.sidebarContent == .files && mode != .compact
    }

    var body: some View {
        let isCompact = mode == .compact
        VStack(spacing: 0) {
            brand(isCompact: isCompact)
            // Compact can't fit a tree in 52pt, so it always shows the icon
            // list; the file tree (and its footer toggle) are full-mode only.
            if fileTreeIsMounted {
                FileTreeView(store: store, model: store.fileTree)
            } else {
                ScrollViewReader { proxy in
                    list(isCompact: isCompact, proxy: proxy)
                }
            }
            Spacer(minLength: 0)
            if !isCompact { footer() }
        }
        .frame(width: isCompact ? Self.compactWidth : store.sidebarWidth)
        .glassChromeBackground()
        .overlay(alignment: .trailing) {
            if !isCompact { resizeHandle }
        }
        .overlay {
            // Drop affordance: tinted fill + hairline stroke, inset from the
            // sidebar edges so the splitter / titlebar don't clip it. Always
            // in the view tree (alpha-driven) so `easeOut(0.12)` can animate.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.chromeActive)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.chromeForeground.opacity(0.55), lineWidth: 1)
            }
            .padding(Theme.space2)
            .opacity(isFolderDropTargeted ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isFolderDropTargeted)
            .allowsHitTesting(false)
        }
        // Files are silently ignored — `GhosttySurfaceView` already handles
        // "drop a file path at the cursor" inside a pane (M5.kk). The outline
        // lights up for any URL drag (SwiftUI's `.dropDestination` can't
        // pre-filter file-vs-folder); file drags release as no-ops.
        .dropDestination(for: URL.self) { urls, _ in
            // The file tree's rows vend public.file-url drags (a folder row
            // looks exactly like a Finder drag) and the tree renders inside
            // this very drop zone — reject drops while it's mounted so a
            // tree drag released over the sidebar bounces back instead of
            // minting a workspace. Everywhere the workspace LIST shows —
            // workspaces mode, compact (the tree never mounts there), any
            // window — Finder folders still land.
            guard !fileTreeIsMounted else { return false }
            let folders = urls.filter(isDirectory)
            guard !folders.isEmpty else { return false }
            for folder in folders {
                store.addWorkspace(workingDirectory: folder)
            }
            return true
        } isTargeted: { isFolderDropTargeted = $0 && !fileTreeIsMounted }
        .sheet(item: $sheet) { current in
            switch current {
            case .createSSHWorkspace:
                CreateRemoteWorkspaceSheet(
                    create: { transport in
                        store.addWorkspace(transport: transport)
                        dismissCurrentSheet()
                    },
                    dismiss: dismissCurrentSheet,
                    moshEnabled: KookySettingsModel.shared.showMoshTransport
                )
            case .authenticateRemote(let session):
                RemoteAuthenticationSheet(
                    session: session,
                    authenticated: {
                        store.remoteAuthenticationSucceeded(for: session)
                        dismissCurrentSheet()
                    },
                    dismiss: dismissCurrentSheet
                )
            case .createWorktree(let source):
                CreateWorktreeSheet(
                    source: source,
                    launchTemplates: AgentTemplate.visibleOrdered(model: KookySettingsModel.shared),
                    defaultLaunchTemplate: AgentTemplate.defaultLaunchTemplate(model: KookySettingsModel.shared)
                        ?? .terminal,
                    // Include every workspace's diskPath, not just worktree
                    // children — if the user opened a worktree directory as
                    // a top-level workspace (Finder drop / ⌘O), adopting it
                    // again would spawn a duplicate row pointing at the same
                    // dir. Source workspaces (the repo root) also belong in
                    // the exclusion set because the adopt picker already
                    // drops them via `sourceRootKey`; including them here is
                    // belt-and-suspenders against multi-source ⌘O scenarios.
                    alreadyAdoptedPaths: Set(
                        store.workspaces.map { $0.diskPath.standardizedFileURL.path }
                    ),
                    create: { request in
                        await store.createWorktree(source: source, request: request)
                    },
                    dismiss: dismissCurrentSheet
                )
            case .confirmRemoveWorktree(let workspace):
                ConfirmRemoveWorktreeSheet(
                    workspace: workspace,
                    confirm: { alsoDelete in
                        if alsoDelete {
                            if let message = await store.removeWorktreeDirectory(workspace) {
                                return .failure(message)
                            }
                        }
                        store.closeWorkspace(workspace)
                        return .success
                    },
                    dismiss: dismissCurrentSheet
                )
            case .confirmCloseOthers(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: String(localized: "CLOSE-OTHERS", bundle: .kookyResources),
                    headlineText: String.localizedStringWithFormat(
                        String(localized: "keeping %@", bundle: .kookyResources),
                        request.keeping.title
                    ),
                    subtitleText: bulkSubtitle(
                        closingCount: request.others.count,
                        worktreeCount: request.worktreeOthers.count
                    ),
                    worktreesAmong: request.worktreeOthers,
                    confirm: { alsoDelete in
                        if let message = await store.performCloseOthers(request, alsoDelete: alsoDelete) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: dismissCurrentSheet
                )
            case .confirmCloseSource(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: String(localized: "CLOSE-WORKSPACE", bundle: .kookyResources),
                    headlineText: String.localizedStringWithFormat(
                        String(localized: "closing %@", bundle: .kookyResources),
                        request.source.title
                    ),
                    subtitleText: bulkSubtitle(
                        closingCount: request.worktrees.count + 1,
                        worktreeCount: request.worktrees.count
                    ),
                    worktreesAmong: request.worktrees,
                    confirm: { alsoDelete in
                        if let message = await store.performCloseSource(request, alsoDelete: alsoDelete) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: dismissCurrentSheet
                )
            }
        }
        // ⌘⇧W routes through AppDelegate → store.requestCloseWorkspace,
        // which parks worktree workspaces in `pendingRemovalRequest` for
        // the sidebar to pop the confirm sheet on. Identity-keyed so the
        // observer only fires on a fresh request, not internal renames.
        .onChange(of: store.pendingRemovalRequest?.id) { _, _ in
            if let workspace = store.pendingRemovalRequest {
                sheet = .confirmRemoveWorktree(workspace)
            }
        }
        // Global create requests (currently the command palette). When the
        // sidebar was hidden, `onAppear` below catches the already-parked
        // request after AppDelegate makes the sidebar visible.
        .onChange(of: store.pendingCreateWorktreeRequest?.id) { _, _ in
            if let workspace = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(workspace)
            }
        }
        // SSH-workspace create request (File menu / command palette). Same
        // parked-while-hidden contract as worktree-create above.
        .onChange(of: store.pendingCreateSSHWorkspaceRequest) { _, pending in
            if pending { sheet = .createSSHWorkspace }
        }
        .onChange(of: store.pendingRemoteAuthenticationSession?.id) { _, _ in
            if let session = store.pendingRemoteAuthenticationSession {
                sheet = .authenticateRemote(session)
            }
        }
        // ⌘W while a sheet is key (AppDelegate can't reach the sheet's
        // `@State` directly) — cancel it exactly like its cancel button.
        .onChange(of: store.sheetDismissRequest) { _, _ in
            dismissCurrentSheet()
        }
        .onAppear {
            if let workspace = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(workspace)
            }
            if store.pendingCreateSSHWorkspaceRequest {
                sheet = .createSSHWorkspace
            }
            if let session = store.pendingRemoteAuthenticationSession {
                sheet = .authenticateRemote(session)
            }
        }
        // Bulk close-others request — keyed off keeping.id since the
        // others list can vary in length but each request is anchored
        // on its keeping workspace.
        .onChange(of: store.pendingCloseOthersRequest?.keeping.id) { _, _ in
            if let request = store.pendingCloseOthersRequest {
                sheet = .confirmCloseOthers(request)
            }
        }
        // Close-source-with-worktrees request — keyed off source.id; the
        // store parks it when ⌘⇧W / × on a top-level workspace would
        // strand its worktrees.
        .onChange(of: store.pendingCloseSourceRequest?.source.id) { _, _ in
            if let request = store.pendingCloseSourceRequest {
                sheet = .confirmCloseSource(request)
            }
        }
    }

    /// Cancel whichever sheet is up, clearing its parked store request —
    /// the single dismissal path shared by every sheet's cancel button and
    /// the ⌘W `sheetDismissRequest` signal, so the two can't drift.
    private func dismissCurrentSheet() {
        switch sheet {
        case .createSSHWorkspace:
            store.pendingCreateSSHWorkspaceRequest = false
        case .authenticateRemote:
            store.pendingRemoteAuthenticationSession = nil
        case .createWorktree:
            store.pendingCreateWorktreeRequest = nil
        case .confirmRemoveWorktree:
            store.pendingRemovalRequest = nil
        case .confirmCloseOthers:
            store.pendingCloseOthersRequest = nil
        case .confirmCloseSource:
            store.pendingCloseSourceRequest = nil
        case nil:
            return
        }
        sheet = nil
    }

    /// Shared subtitle string between the two bulk-close flows — folds
    /// pluralisation into one place so the count never reads as
    /// "1 workspaces" or "1 worktrees".
    private func bulkSubtitle(closingCount: Int, worktreeCount: Int) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "%d workspace(s) will close · %d worktree(s)",
                bundle: .kookyResources
            ),
            closingCount,
            worktreeCount
        )
    }

    /// True when `workspace` is a top-level source workspace *and* its
    /// cwd is inside a git repo. Worktree rows are excluded (worktree
    /// nesting isn't supported); non-git workspaces (e.g. `~/Downloads`
    /// opened as a workspace) hide the menu item so users never see an
    /// option that can only error.
    private func canCreateWorktree(from workspace: Workspace) -> Bool {
        guard workspace.worktreeParentId == nil else { return false }
        return GitWatcher.findGitDir(near: workspace.workingDirectory) != nil
    }

    @ViewBuilder
    private func brand(isCompact: Bool) -> some View {
        if isCompact {
            HoverableIconButton(
                systemName: "plus",
                fontSize: 12,
                size: 28,
                help: "New workspace"
            ) {
                store.addWorkspace()
            }
            .padding(.top, Theme.space3)
            .padding(.bottom, Theme.space2)
        } else {
            HStack(spacing: 0) {
                Text("kooky")
                    .font(Theme.display(15, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                Spacer()
                HoverableIconButton(
                    systemName: "plus",
                    fontSize: 12,
                    size: 28,
                    help: "New workspace"
                ) {
                    store.addWorkspace()
                }
            }
            .padding(.horizontal, Theme.space4)
            .padding(.top, Theme.space3)
            .padding(.bottom, Theme.space2)
        }
    }

    /// Pinned bottom bar, full mode only — compact hides it since a 52pt
    /// column can't host the tree the files segment switches to. Two segments
    /// toggling between the workspace list and the active workspace's file tree.
    @ViewBuilder
    private func footer() -> some View {
        Rectangle().fill(Theme.chromeHairline).frame(height: 1)
        HStack(spacing: 2) {
            segment(.workspaces, systemName: "rectangle.stack", help: "Workspaces")
            segment(.files, systemName: "folder", help: "Files")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, Theme.space1)
    }

    private func segment(_ content: SidebarContent, systemName: String, help: String) -> some View {
        FooterSegment(
            systemName: systemName,
            isActive: store.sidebarContent == content,
            help: help
        ) {
            withAnimation(Theme.chromeTransition) {
                store.setSidebarContent(content)
            }
        }
    }

    private func list(isCompact: Bool, proxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                if isCompact {
                    // 52pt-wide sidebar can't fit a disclosure triangle next
                    // to a 28pt icon — fall back to a flat list. The order
                    // is stable: store.workspaces already places worktrees
                    // after their source by virtue of being appended at
                    // creation time.
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        // canCreateWorktree walks the fs (`findGitDir`) —
                        // hoist once per workspace so the two row callbacks
                        // don't each stat the same ancestor chain.
                        let canCreate = canCreateWorktree(from: workspace)
                        let goToSource: (() -> Void)? = workspace.worktreeParentId
                            .flatMap { id in store.workspaces.first { $0.id == id } }
                            .map { parent in { store.activateWorkspace(parent) } }
                        DraggableWorkspaceRow(
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            isCompact: isCompact,
                            draggingId: $draggingWorkspaceId,
                            onCreateWorktree: canCreate ? { presentCreateWorktree(workspace) } : nil,
                            onGoToSource: goToSource
                        )
                    }
                } else {
                    // A workspace is "top-level" either because it has no
                    // parent, or because its parent is gone — defensive
                    // fallback so a bug that strands a worktree (parent
                    // closed while child kept) still surfaces the row in
                    // the sidebar instead of vanishing it entirely.
                    let parentIds = Set(store.workspaces.map(\.id))
                    let topLevel = store.workspaces.enumerated().filter { _, ws in
                        guard let parentId = ws.worktreeParentId else { return true }
                        return !parentIds.contains(parentId)
                    }
                    ForEach(Array(topLevel), id: \.element.id) { index, workspace in
                        workspaceTree(parent: workspace, parentIndex: index)
                    }
                }
            }
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, Theme.space2)
        }
        // ⌘⇧R parks the active workspace on the store; reveal its row so the
        // row's own rename popover can open. onChange catches a request made
        // while the sidebar is up; onAppear catches one parked while the
        // sidebar was hidden (SidebarView mounts only after the reveal).
        .onChange(of: store.pendingRenameWorkspace?.id) { _, _ in
            revealWorkspaceForRename(using: proxy)
        }
        .onAppear { revealWorkspaceForRename(using: proxy) }
    }

    @ViewBuilder
    private func workspaceTree(parent: Workspace, parentIndex: Int) -> some View {
        let worktrees = store.workspaces.filter { $0.worktreeParentId == parent.id }
        let hasWorktrees = !worktrees.isEmpty
        let isCollapsed = collapsedParents.contains(parent.id)

        // canCreateWorktree walks the fs (`findGitDir`) — hoist once so
        // the two callbacks don't each stat the same ancestor chain.
        let canCreate = canCreateWorktree(from: parent)
        DraggableWorkspaceRow(
            workspace: parent,
            store: store,
            myIndex: parentIndex,
            isCompact: false,
            draggingId: $draggingWorkspaceId,
            disclosure: hasWorktrees
                ? SidebarWorkspaceRow.WorktreeDisclosure(
                    isCollapsed: isCollapsed,
                    toggle: { toggleCollapsed(parent.id) }
                )
                : nil,
            onCreateWorktree: canCreate ? { presentCreateWorktree(parent) } : nil
        )

        if hasWorktrees && !isCollapsed {
            ForEach(worktrees) { worktree in
                SidebarWorkspaceRow(
                    workspace: worktree,
                    isActive: worktree.id == store.activeWorkspaceId,
                    isCompact: false,
                    canCloseOthers: store.workspaces.count > 1,
                    onActivate: { store.activateWorkspace(worktree) },
                    onClose: { store.requestCloseWorkspace(worktree) },
                    onCloseOthers: { store.closeOtherWorkspaces(keeping: worktree) },
                    onDuplicate: { store.duplicateWorkspace(worktree) },
                    onRename: { store.renameWorkspace(worktree, to: $0) },
                    onSetTag: { store.setTag($0, for: worktree) },
                    onGoToSource: { store.activateWorkspace(parent) }
                )
            }
        }
    }

    private func toggleCollapsed(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.12)) {
            if collapsedParents.contains(id) {
                collapsedParents.remove(id)
            } else {
                collapsedParents.insert(id)
            }
        }
    }

    /// Bring the active workspace's row into the view hierarchy so its rename
    /// popover can anchor, then hand off to the row via `renameRequested`. The
    /// row may be unmounted — nested under a collapsed worktree parent, or
    /// scrolled out of the LazyVStack's realized window. Without this the ⌘⇧R
    /// flag would sit unconsumed and then fire stale when the user later
    /// scrolled to / expanded that row.
    private func revealWorkspaceForRename(using proxy: ScrollViewProxy) {
        guard let workspace = store.pendingRenameWorkspace else { return }
        store.pendingRenameWorkspace = nil
        if let parentId = workspace.worktreeParentId, collapsedParents.contains(parentId) {
            collapsedParents.remove(parentId)
        }
        workspace.renameRequested = true
        // Defer so a just-expanded subtree is laid out before scrolling to a
        // row that may have only now been inserted.
        DispatchQueue.main.async {
            proxy.scrollTo(workspace.id, anchor: .center)
        }
    }

    private func presentCreateWorktree(_ workspace: Workspace) {
        // Single channel: parking on the store triggers the `.onChange`
        // observer that sets `sheet`. Direct row clicks and command-palette
        // / AppDelegate routes all go through here, so this stays the one
        // mechanism that opens the create sheet.
        store.pendingCreateWorktreeRequest = workspace
    }
}

/// Drag source + drop target with a direction-aware edge indicator —
/// `top` when origin is below (dragging up), `bottom` when origin is above
/// (dragging down), so the line always shows where the dropped row will land.
private struct DraggableWorkspaceRow: View {
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let isCompact: Bool
    @Binding var draggingId: UUID?
    /// Non-nil only for source workspaces that own at least one worktree.
    /// Worktree rows themselves render via `SidebarWorkspaceRow` directly,
    /// without this wrapper, so they don't pick up drag/drop handlers.
    var disclosure: SidebarWorkspaceRow.WorktreeDisclosure? = nil
    var onCreateWorktree: (() -> Void)? = nil
    var onGoToSource: (() -> Void)? = nil

    @State private var isTargeted = false

    var body: some View {
        let originIndex: Int? = {
            guard let id = draggingId, id != workspace.id else { return nil }
            return store.workspaces.firstIndex(where: { $0.id == id })
        }()
        let dragsDownward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsDownward ? .bottom : .top
        let isSelfDrag = draggingId == workspace.id

        SidebarWorkspaceRow(
            workspace: workspace,
            isActive: workspace.id == store.activeWorkspaceId,
            isCompact: isCompact,
            canCloseOthers: store.workspaces.count > 1,
            onActivate: { store.activateWorkspace(workspace) },
            onClose: { store.requestCloseWorkspace(workspace) },
            onCloseOthers: { store.closeOtherWorkspaces(keeping: workspace) },
            onDuplicate: { store.duplicateWorkspace(workspace) },
            onRename: { store.renameWorkspace(workspace, to: $0) },
            onSetTag: { store.setTag($0, for: workspace) },
            disclosure: disclosure,
            onCreateWorktree: onCreateWorktree,
            onGoToSource: onGoToSource
        )
        .dropIndicator(active: isTargeted && !isSelfDrag, on: edge)
        .onDrag {
            draggingId = workspace.id
            return NSItemProvider(object: workspace.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { draggingId = nil }
            guard let id = dropped.first.flatMap(UUID.init),
                  let from = store.workspaces.firstIndex(where: { $0.id == id })
            else { return false }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.moveWorkspace(from: from, to: myIndex)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
