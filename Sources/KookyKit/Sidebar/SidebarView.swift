import SwiftUI

/// Bundles every modal sheet the sidebar can show so they share one
/// `.sheet(item:)` modifier. `.sheet(isPresented:)` per state would race
/// when switching directly between modes (create → confirm-remove).
private enum SidebarSheet: Identifiable {
    case createSSHWorkspace
    case createWorktree(Project)
    case confirmRemoveWorktree(Workspace)
    case confirmCloseOthers(WorkspaceStore.BulkRemovalRequest)
    case confirmCloseProject(WorkspaceStore.CloseProjectRequest)

    var id: String {
        switch self {
        case .createSSHWorkspace: return "create-ssh-workspace"
        case .createWorktree(let project): return "create-worktree-\(project.id.uuidString)"
        case .confirmRemoveWorktree(let ws): return "remove-\(ws.id.uuidString)"
        case .confirmCloseOthers(let req): return "close-others-\(req.keeping.id.uuidString)"
        case .confirmCloseProject(let req): return "close-project-\(req.project.id.uuidString)"
        }
    }
}

/// Places a full wordmark so the measured centre of its first glyph lands on
/// a caller-provided horizontal axis. The second subview is an invisible copy
/// of that glyph using the exact same SwiftUI font; keeping the visible word
/// intact preserves its native kerning and accessibility value.
private struct FirstGlyphCenteredLayout: Layout {
    let axisX: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let word = subviews[0].sizeThatFits(.unspecified)
        let glyph = subviews[1].sizeThatFits(.unspecified)
        return CGSize(
            width: axisX - glyph.width / 2 + word.width,
            height: max(word.height, glyph.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let word = subviews[0].sizeThatFits(.unspecified)
        let glyph = subviews[1].sizeThatFits(.unspecified)
        let origin = CGPoint(
            x: bounds.minX + axisX - glyph.width / 2,
            y: bounds.midY - word.height / 2
        )
        subviews[0].place(at: origin, anchor: .topLeading, proposal: .unspecified)
        subviews[1].place(at: origin, anchor: .topLeading, proposal: .unspecified)
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
    /// Project rows drag on their own axis, and a row is a whole header
    /// plus its children, so it keeps its own drag/target state — a
    /// workspace drag must not light up a project header.
    @State private var draggingProjectId: UUID?
    @State private var targetedProjectId: UUID?
    /// True while a Finder folder drag is hovering the sidebar — gates the
    /// drop-zone outline so the user sees that releasing here opens a new
    /// workspace.
    @State private var isFolderDropTargeted = false
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
                resizeDragStartWidth = nil
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines { engine.endSizePropagationSuspension() }
                    sidebarSuspendedEngines = []
                }
                store.endSidebarResize()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if resizeDragStartWidth == nil {
                    resizeDragStartWidth = store.sidebarWidth
                    store.beginSidebarResize()
                }
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
                store.endSidebarResize()
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
            sheetContent(for: current)
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
            if let project = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(project)
            }
        }
        // SSH-workspace create request (File menu / command palette). Same
        // parked-while-hidden contract as worktree-create above.
        .onChange(of: store.pendingCreateSSHWorkspaceRequest) { _, pending in
            if pending { sheet = .createSSHWorkspace }
        }
        // ⌘W while a sheet is key (AppDelegate can't reach the sheet's
        // `@State` directly) — cancel it exactly like its cancel button.
        .onChange(of: store.sheetDismissRequest) { _, _ in
            dismissCurrentSheet()
        }
        .onAppear {
            if let project = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(project)
            }
            if store.pendingCreateSSHWorkspaceRequest {
                sheet = .createSSHWorkspace
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
        // Remove-project-holding-worktrees request — keyed off project.id;
        // the store parks it when removing the project would strand (or, on
        // "also delete", delete) its worktree checkouts on disk.
        .onChange(of: store.pendingCloseProjectRequest?.project.id) { _, _ in
            if let request = store.pendingCloseProjectRequest {
                sheet = .confirmCloseProject(request)
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
        case .createWorktree:
            store.pendingCreateWorktreeRequest = nil
        case .confirmRemoveWorktree:
            store.pendingRemovalRequest = nil
        case .confirmCloseOthers:
            store.pendingCloseOthersRequest = nil
        case .confirmCloseProject:
            store.pendingCloseProjectRequest = nil
        case nil:
            return
        }
        sheet = nil
    }

    /// Shared subtitle string between the two bulk-close flows — folds
    /// pluralisation into one place so the count never reads as
    /// "1 workspaces" or "1 worktrees".
    private func bulkSubtitle(closingCount: Int, worktreeCount: Int) -> String {
        guard worktreeCount > 0 else {
            return String.localizedStringWithFormat(
                String(localized: "%d workspace(s) will close", bundle: .kookyResources),
                closingCount
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "%d workspace(s) will close · %d worktree(s)",
                bundle: .kookyResources
            ),
            closingCount,
            worktreeCount
        )
    }

    /// True when the project's folder is inside a git repo. Worktrees are a
    /// project capability, so the gate is the project root — a plain folder
    /// (e.g. `~/Downloads`) hides the menu item instead of offering an action
    /// that can only error.
    private func canCreateWorktree(in project: Project) -> Bool {
        // The SSH group has no local folder, so there is no repo to branch.
        !project.isSSHGroup && GitWatcher.findGitDir(near: project.rootPath) != nil
    }

    @ViewBuilder
    private func brand(isCompact: Bool) -> some View {
        Group {
            if isCompact {
                HoverableIconButton(
                    systemName: "plus",
                    fontSize: 12,
                    size: Theme.chromeToolbarButtonSize,
                    help: "New workspace"
                ) {
                    store.addWorkspace()
                }
            } else {
                HStack(spacing: 0) {
                    FirstGlyphCenteredLayout(axisX: Theme.sidebarLeadingIconCenterX) {
                        Text("Kooky")
                            .font(Theme.display(15.5, weight: .semibold))
                            .foregroundStyle(Theme.chromeForeground)
                        Text("K")
                            .font(Theme.display(15.5, weight: .semibold))
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    .fixedSize()
                    Spacer()
                    HoverableIconButton(
                        systemName: "plus",
                        fontSize: 12,
                        size: Theme.chromeToolbarButtonSize,
                        help: "New workspace"
                    ) {
                        store.addWorkspace()
                    }
                }
                // The layout owns the leading space required to centre its
                // measured first glyph; the trailing action keeps the regular
                // 16pt content gutter.
                .padding(.trailing, Theme.sidebarContentLeadingX)
            }
        }
        // A source-list title sits on the lower side of its 40pt header: the
        // first row's own vertical inset otherwise makes a geometrically
        // centred title read too high. Keep the whole title/action group on
        // the 4pt spacing grid instead of applying a text-only pixel offset.
        .padding(.bottom, Theme.space1)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.contentHeaderHeight, alignment: .bottom)
    }

    /// Pinned bottom bar, full mode only — compact hides it since a 52pt
    /// column can't host the tree the files segment switches to. Two segments
    /// toggling between the workspace list and the active workspace's file tree.
    @ViewBuilder
    private func footer() -> some View {
        Rectangle().fill(Theme.chromeSeparator).frame(height: 1)
        HStack(spacing: Theme.chromeControlSpacing) {
            segment(.workspaces, systemName: "rectangle.stack", help: "Workspaces")
            segment(.files, systemName: "folder", help: "Files")
            Spacer(minLength: 0)
        }
        // The first segment is 26pt wide; align its centre to the shared
        // sidebar axis while preserving the button's generous hit target.
        .padding(.leading, Theme.sidebarLeadingIconCenterX - Theme.chromeFooterSegmentWidth / 2)
        .padding(.trailing, Theme.chromeBarEdgeInset)
        .padding(.vertical, Theme.chromeBottomBarVerticalPadding)
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

    /// The sheet switch lives in its own `@ViewBuilder` so the body's
    /// modifier chain type-checks — inlined it exceeds the compiler's budget.
    @ViewBuilder
    private func sheetContent(for current: SidebarSheet) -> some View {
        switch current {
        case .createSSHWorkspace:
            CreateSSHWorkspaceSheet(
                create: { host in
                    store.addWorkspace(sshRemoteHost: host)
                    dismissCurrentSheet()
                },
                dismiss: dismissCurrentSheet
            )
        case .createWorktree(let project):
            CreateWorktreeSheet(
                project: project,
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
                    await store.createWorktree(project: project, request: request)
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
        case .confirmCloseProject(let request):
            ConfirmBulkCloseSheet(
                statusLabel: String(localized: "REMOVE-PROJECT", bundle: .kookyResources),
                headlineText: String.localizedStringWithFormat(
                    String(localized: "removing %@", bundle: .kookyResources),
                    request.project.title
                ),
                subtitleText: bulkSubtitle(
                    closingCount: request.workspaces.count,
                    worktreeCount: request.worktrees.count
                ),
                worktreesAmong: request.worktrees,
                confirm: { alsoDelete in
                    if let message = await store.performCloseProject(request, alsoDelete: alsoDelete) {
                        return .failure(message)
                    }
                    return .success
                },
                dismiss: dismissCurrentSheet
            )
        }
    }

    private func list(isCompact: Bool, proxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 3) {
                if isCompact {
                    // A 52pt rail can't host a project header above its rows,
                    // so it falls back to the flat workspace list — with a
                    // hairline between projects, the only way the rail can say
                    // where one folder's rows end and the next begins.
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 {
                            Rectangle()
                                .fill(Theme.chromeSeparator)
                                .frame(height: 1)
                                .padding(.horizontal, 10)
                        }
                        ForEach(store.workspaces(in: project)) { workspace in
                            DraggableWorkspaceRow(
                                workspace: workspace,
                                store: store,
                                isCompact: true,
                                draggingId: $draggingWorkspaceId
                            )
                        }
                    }
                } else {
                    ForEach(store.projects) { project in
                        draggableProjectTree(project: project)
                    }
                }
            }
            // Source-list rows use an 8pt hover-fill inset. Their own 8pt
            // content inset then places the 20pt mark at x = 16...36. The
            // 40pt header already owns the vertical separation above the
            // source list, so don't double that gap with extra top padding.
            .padding(.horizontal, Theme.space2)
            .padding(.bottom, Theme.space2)
        }
        // ⌘⇧R parks the active workspace on the store; reveal its row so the
        // row's own rename popover can open. onChange catches a request made
        // while the sidebar is up; onAppear catches one parked while the
        // sidebar was hidden (SidebarView mounts only after the reveal).
        .onChange(of: store.pendingRenameWorkspace?.id) { _, _ in
            revealWorkspaceForRename(using: proxy)
        }
        .onAppear { revealWorkspaceForRename(using: proxy) }
        // Keyboard / palette / inbox selection can land on a row that's
        // scrolled away or folded under a collapsed source — bring it on
        // screen, including when the list remounts (sidebar shown again,
        // files → workspaces).
        .background {
            ActiveWorkspaceRevealer(store: store) { reveal($0, using: proxy) }
        }
    }

    /// Project rows reorder by drag, same gesture as workspace rows: the
    /// dragged project takes the destination's slot. There is no parent to
    /// change — the order the user builds here is the order `snapshot()`
    /// writes, so it survives relaunch.
    @ViewBuilder
    private func draggableProjectTree(project: Project) -> some View {
        let order = store.projects
        let myIndex = order.firstIndex { $0.id == project.id } ?? 0
        let originIndex = draggingProjectId.flatMap { id in order.firstIndex { $0.id == id } }
        let dragsDownward = (originIndex ?? Int.max) < myIndex
        let isSelfDrag = draggingProjectId == project.id

        projectTree(project: project)
            .dropIndicator(active: targetedProjectId == project.id && !isSelfDrag,
                           on: dragsDownward ? .bottom : .top)
            .onDrag {
                draggingProjectId = project.id
                return NSItemProvider(object: "project:\(project.id.uuidString)" as NSString)
            }
            .dropDestination(for: String.self) { dropped, _ in
                defer { draggingProjectId = nil }
                guard let raw = dropped.first,
                      raw.hasPrefix("project:"),
                      let id = UUID(uuidString: String(raw.dropFirst("project:".count))),
                      let dragged = store.projects.first(where: { $0.id == id })
                else { return false }
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.moveProject(dragged, to: project)
                }
                return true
            } isTargeted: { targetedProjectId = $0 ? project.id : nil }
    }

    /// One project and the workspaces living in its folder. Two levels by
    /// construction: a worktree is not a nested workspace but one more
    /// workspace whose own root is the worktree checkout, so nothing here
    /// recurses. An empty project still shows its header — a folder added
    /// before its first tab is a legitimate state, not a row to hide.
    @ViewBuilder
    private func projectTree(project: Project) -> some View {
        let members = store.workspaces(in: project)
        let isCollapsed = store.collapsedProjectIds.contains(project.id)
        SidebarProjectRow(
            project: project,
            isCollapsed: isCollapsed,
            canCreateWorktree: canCreateWorktree(in: project),
            onToggleCollapsed: { toggleCollapsed(project.id) },
            // A new row in the SSH group is a new remote terminal, not a local
            // one — the group can only hold SSH workspaces.
            onNewWorkspace: {
                if project.isSSHGroup {
                    sheet = .createSSHWorkspace
                } else {
                    store.addWorkspace(in: project)
                }
            },
            onCreateWorktree: { presentCreateWorktree(project) },
            onRemove: { store.requestRemoveProject(project) }
        )
        if !isCollapsed {
            // Children sit one rhythm step inside their project header so the
            // hierarchy reads without decoding a badge.
            ForEach(members) { workspace in
                DraggableWorkspaceRow(
                    workspace: workspace,
                    store: store,
                    isCompact: false,
                    draggingId: $draggingWorkspaceId
                )
                .padding(.leading, Theme.space3)
            }
        }
    }

    private func toggleCollapsed(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.12)) {
            store.toggleProjectCollapsed(id)
        }
    }

    /// Bring the active workspace's row into the view hierarchy so its rename
    /// popover can anchor, then hand off to the row via `renameRequested`. The
    /// row may be unmounted — inside a collapsed project, or scrolled out of
    /// the LazyVStack's realized window. Without this the ⌘⇧R flag would sit
    /// unconsumed and then fire stale when the user later scrolled to /
    /// expanded that row.
    private func revealWorkspaceForRename(using proxy: ScrollViewProxy) {
        guard let workspace = store.pendingRenameWorkspace else { return }
        store.pendingRenameWorkspace = nil
        workspace.renameRequested = true
        reveal(workspace, anchor: .center, using: proxy)
    }

    /// Unfold the project hiding `workspace`, then scroll to its row. A nil
    /// anchor scrolls the minimum needed, so a row that's already visible
    /// doesn't move the list.
    private func reveal(_ workspace: Workspace, anchor: UnitPoint? = nil, using proxy: ScrollViewProxy) {
        if store.collapsedProjectIds.contains(workspace.projectId) {
            withAnimation(.easeOut(duration: 0.12)) {
                store.setProjectCollapsed(workspace.projectId, false)
            }
        }
        // Defer so a just-expanded section is laid out before scrolling to a
        // row that may have only now been inserted.
        DispatchQueue.main.async {
            proxy.scrollTo(workspace.id, anchor: anchor)
        }
    }

    private func presentCreateWorktree(_ project: Project) {
        // Single channel: parking on the store triggers the `.onChange`
        // observer that sets `sheet`. Row clicks and the command-palette /
        // AppDelegate routes all go through here, so this stays the one
        // mechanism that opens the create sheet.
        store.pendingCreateWorktreeRequest = project
    }
}

/// Drag source + drop target with a direction-aware edge indicator —
/// `top` when the origin is below (dragging up), `bottom` when the origin is
/// above (dragging down), so the line always shows where the dropped row will
/// land. Reordering is project-local: a project owns its folder, so dropping
/// onto a row of another project is a no-op (`WorkspaceStore.moveWorkspace`
/// refuses it).
private struct DraggableWorkspaceRow: View {
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let isCompact: Bool
    @Binding var draggingId: UUID?

    @State private var isTargeted = false

    var body: some View {
        let siblings = store.workspaces(projectId: workspace.projectId)
        let myIndex = siblings.firstIndex { $0.id == workspace.id } ?? 0
        let originIndex: Int? = {
            guard let id = draggingId, id != workspace.id else { return nil }
            return siblings.firstIndex { $0.id == id }
        }()
        let dragsDownward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsDownward ? .bottom : .top
        let isSelfDrag = draggingId == workspace.id

        SidebarWorkspaceRow(
            workspace: workspace,
            isActive: workspace.id == store.activeWorkspaceId,
            isCompact: isCompact,
            canCloseOthers: siblings.count > 1,
            onActivate: { store.activateWorkspace(workspace) },
            onClose: { store.requestCloseWorkspace(workspace) },
            onCloseOthers: { store.closeOtherWorkspaces(keeping: workspace) },
            onDuplicate: { store.duplicateWorkspace(workspace) },
            onRename: { store.renameWorkspace(workspace, to: $0) },
            onSetTag: { store.setTag($0, for: workspace) }
        )
        .dropIndicator(active: isTargeted && !isSelfDrag, on: edge)
        .onDrag {
            draggingId = workspace.id
            return NSItemProvider(object: "workspace:\(workspace.id.uuidString)" as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { draggingId = nil }
            guard let raw = dropped.first,
                  raw.hasPrefix("workspace:"),
                  let id = UUID(uuidString: String(raw.dropFirst("workspace:".count))),
                  let dragged = store.workspaces.first(where: { $0.id == id })
            else { return false }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.moveWorkspace(dragged, to: workspace)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Calls `reveal` with the active workspace on mount and whenever it changes.
/// Its own leaf so only it reads `activeWorkspaceId`: hung on the list, that
/// read would re-run every row closure (each one's `findGitDir` walk) on
/// every switch.
private struct ActiveWorkspaceRevealer: View {
    let store: WorkspaceStore
    let reveal: (Workspace) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: store.activeWorkspaceId, initial: true) { _, _ in
                if let workspace = store.active { reveal(workspace) }
            }
    }
}
