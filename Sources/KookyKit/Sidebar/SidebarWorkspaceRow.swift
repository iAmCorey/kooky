import SwiftUI

struct SidebarWorkspaceRow: View {
    /// Disclosure state for a source workspace that owns worktree children.
    /// `toggle` is wired by the sidebar's parent — the row only renders the
    /// chevron and forwards the click.
    struct WorktreeDisclosure {
        let isCollapsed: Bool
        let toggle: () -> Void
    }

    let workspace: Workspace
    let isActive: Bool
    let isCompact: Bool
    let canCloseOthers: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onDuplicate: () -> Void
    let onRename: (String) -> Void
    var disclosure: WorktreeDisclosure? = nil
    /// Non-nil for source (top-level, non-worktree) workspaces — the
    /// right-click menu surfaces a "Create Worktree…" entry that the
    /// sidebar wires to a sheet. Nil on worktree rows so worktree
    /// nesting stays disabled.
    var onCreateWorktree: (() -> Void)? = nil
    /// Non-nil for worktree rows — jumps the active selection back to the
    /// source workspace this worktree was forked from. Cheap navigation
    /// shortcut when the user is deep in a worktree and wants the main
    /// repo's tab back.
    var onGoToSource: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isContextMenuOpen = false
    @State private var isRenameOpen = false
    @State private var pendingRename = ""

    var body: some View {
        let readout = workspace.sidebarReadout
        let dotColor = Self.activityDotColor(state: readout.state, hasFailure: readout.hasCommandFailure)
        Group {
            if isCompact {
                compactBody(agents: readout.agents, dotColor: dotColor)
            } else {
                fullBody(agents: readout.agents, dotColor: dotColor)
            }
        }
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .overlay(RightClickCatcher { _ in isContextMenuOpen = true })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                KookyMenuRow(
                    title: workspace.worktreeParentId == nil ? "Close Workspace" : "Close Worktree…",
                    shortcut: workspace.worktreeParentId == nil ? "⌘⇧W" : nil
                ) {
                    isContextMenuOpen = false
                    onClose()
                }
                KookyMenuRow(title: "Close Other Workspaces", isDisabled: !canCloseOthers) {
                    isContextMenuOpen = false
                    onCloseOthers()
                }
                KookyMenuDivider()
                KookyMenuRow(title: "Rename Workspace…", shortcut: "⌘⇧R") {
                    isContextMenuOpen = false
                    beginRename(deferred: true)
                }
                KookyMenuRow(title: "Duplicate Workspace") {
                    isContextMenuOpen = false
                    onDuplicate()
                }
                if let onCreateWorktree {
                    KookyMenuRow(title: "Create Worktree…") {
                        isContextMenuOpen = false
                        // Defer one runloop tick so the menu popover finishes
                        // dismissing before the sheet anchors — back-to-back
                        // popovers/sheets off the same view glitch otherwise.
                        DispatchQueue.main.async { onCreateWorktree() }
                    }
                }
                if let onGoToSource {
                    KookyMenuRow(title: "Go to Source Workspace") {
                        isContextMenuOpen = false
                        onGoToSource()
                    }
                }
                KookyMenuDivider()
                KookyMenuRow(title: "Reveal in Finder") {
                    isContextMenuOpen = false
                    NSWorkspace.shared.activateFileViewerSelecting([workspace.workingDirectory])
                }
            }
            .padding(Theme.space1)
            .frame(minWidth: 240)
            .background(Theme.chromeBackground)
        }
        .popover(isPresented: $isRenameOpen, arrowEdge: .trailing) {
            KookyRenameField(placeholder: "Workspace title", text: $pendingRename) {
                onRename(pendingRename)
                isRenameOpen = false
            }
        }
        .help(workspace.workingDirectory.path)
        .onChange(of: workspace.renameRequested) { _, requested in
            if requested { consumeRenameRequest() }
        }
        .onAppear {
            // ⌘⇧R may reveal a hidden sidebar; this row then mounts with the
            // flag already set, after onChange's window has passed — onAppear
            // catches that case.
            if workspace.renameRequested { consumeRenameRequest() }
        }
    }

    /// Consume the `Workspace.renameRequested` flag (the ⌘⇧R menu command) and
    /// open the rename popover — shared by onChange (row already mounted) and
    /// onAppear (row just mounted after a hidden sidebar was revealed).
    private func consumeRenameRequest() {
        workspace.renameRequested = false
        beginRename(deferred: false)
    }

    /// Seed the edit field from the current title and open the rename popover.
    /// `deferred` waits one runloop tick — needed from the context menu, where
    /// that popover is mid-dismiss and back-to-back popovers off the same
    /// anchor glitch; the ⌘⇧R path opens synchronously. Skips when already
    /// open so a re-trigger mid-edit can't wipe what the user is typing.
    private func beginRename(deferred: Bool) {
        guard !isRenameOpen else { return }
        pendingRename = workspace.customTitle ?? workspace.title
        if deferred {
            DispatchQueue.main.async { isRenameOpen = true }
        } else {
            isRenameOpen = true
        }
    }

    private func fullBody(agents: [AgentTemplate], dotColor: Color?) -> some View {
        HStack(spacing: Theme.space2) {
            agentIcons(agents: agents)
                .padding(.trailing, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.title)
                    .font(Theme.display(13, weight: .regular))
                    .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeForeground.opacity(0.78))
                    .lineLimit(1)
                subtitleRow
            }
            Spacer(minLength: 0)
            // Activity dot lives at the trailing edge — visible at all times
            // when not idle, eats the close-button slot only on hover.
            HStack(spacing: 2) {
                if let disclosure {
                    HoverableIconButton(
                        systemName: "chevron.right",
                        fontSize: 10,
                        size: 20,
                        help: nil,
                        action: disclosure.toggle,
                        rotation: disclosure.isCollapsed ? 0 : 90
                    )
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                if let onCreateWorktree {
                    HoverableIconButton(
                        systemName: "arrow.triangle.branch",
                        fontSize: 10,
                        size: 20,
                        help: "Create worktree",
                        action: onCreateWorktree
                    )
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                ZStack {
                    if let dotColor {
                        Circle().fill(dotColor).frame(width: 6, height: 6)
                            .opacity(isHovered ? 0 : 1)
                    }
                    HoverableIconButton(
                        systemName: "xmark",
                        fontSize: 10,
                        size: 20,
                        help: workspace.worktreeParentId == nil ? "Close workspace" : "Close worktree",
                        action: onClose
                    )
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                .frame(width: 20, alignment: .trailing)
            }
            .frame(minWidth: trailingHoverMinWidth, alignment: .trailing)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 11)
    }

    private func compactBody(agents: [AgentTemplate], dotColor: Color?) -> some View {
        // Icon-only row — activity dot floats over the icon as a small badge
        // since there's no trailing slot in the narrowed column.
        ZStack(alignment: .topTrailing) {
            agentIcons(agents: agents)
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .offset(x: 3, y: -3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
    }

    /// Subtitle below the workspace title. Source workspaces show their
    /// cwd path (tilde-abbreviated); worktree rows show the branch glyph
    /// + branch name — more informative than the path (which is usually
    /// `<repo>-<branch>` and just repeats the title) and the inline glyph
    /// makes the worktree-vs-source distinction obvious without any
    /// extra chrome. Cwd path still reaches the user via the row-level
    /// `.help(...)` tooltip.
    @ViewBuilder
    private var subtitleRow: some View {
        if let branch = workspace.worktreeBranch, !branch.isEmpty {
            // Worktree row's brand mark — a solid-filled rounded square
            // with the branch glyph reverse-cut in `chromeBackground`.
            // The solid-fill-over-tint approach reads cleanly against
            // both light and dark themes (no opacity haze on the glyph)
            // and gives the worktree row the same visual weight a tab
            // pill carries — distinct from source rows without needing
            // an extra column or stripe.
            let badgeColor = Theme.chromeForeground.opacity(0.82)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(Theme.chromeBackground)
                    .frame(width: 12, height: 12)
                    .background(badgeColor, in: RoundedRectangle(cornerRadius: 3))
                Text(branch)
                    .font(Theme.mono(10.5, weight: .medium))
                    .foregroundStyle(badgeColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            if let host = workspace.sshRemoteHost, !host.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.system(size: 9, weight: .medium))
                    Text("ssh \(host)")
                        .font(Theme.mono(10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Theme.chromeMuted)
            } else {
                Text((workspace.workingDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    /// Trailing hover icon strip min width — accommodates each optional
    /// hover button (chevron, create-worktree) plus the always-present
    /// close × slot so the trailing edge doesn't shift when a hover
    /// icon appears.
    private var trailingHoverMinWidth: CGFloat {
        var width: CGFloat = 20
        if disclosure != nil { width += 22 }
        if onCreateWorktree != nil { width += 22 }
        return width
    }

    @ViewBuilder
    private func agentIcons(agents: [AgentTemplate]) -> some View {
        if workspace.sshRemoteHost != nil {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: AgentTemplate.terminal.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeMuted)
                    .frame(width: 20, height: 20)
                Image(systemName: "network")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.chromeBackground)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(Theme.activityRunning.opacity(0.95)))
                    .overlay(Circle().stroke(Theme.chromeBackground.opacity(0.9), lineWidth: 1))
                    .offset(x: 5, y: 5)
            }
            .opacity(isActive ? 1 : 0.9)
        } else
        // Single leading mark: first non-terminal agent's brand icon, or the
        // Terminal SF Symbol when the workspace only runs plain shells.
        // Multi-agent workspaces get a `+N` badge showing the additional
        // distinct agents — first agent stays the dominant mark.
        if let agent = agents.first {
            ZStack(alignment: .bottomTrailing) {
                AgentIconView(asset: agent.iconAsset, fallbackSymbol: agent.symbol, size: 20)
                if agents.count > 1 {
                    Text("+\(agents.count - 1)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.chromeBackground)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Theme.chromeForeground.opacity(0.92)))
                        .offset(x: 6, y: 4)
                }
            }
            .opacity(isActive ? 1 : 0.85)
        } else {
            Image(systemName: AgentTemplate.terminal.symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 20, height: 20)
        }
    }

    /// Precedence: attention (agent literally waits on you) > failure
    /// (last shell command non-zero, look when free) > running (agent in
    /// flight, FYI) > idle (quiet).
    private static func activityDotColor(state: SessionActivityState, hasFailure: Bool) -> Color? {
        if state == .attention { return Theme.activityAttention }
        if hasFailure { return Theme.activityFailure }
        if state == .running { return Theme.activityRunning }
        return nil
    }

    /// Row body's background. Compact-mode worktree rows carry a 1.5pt
    /// accent stripe along the left edge — Linear / GitHub PR sidebar
    /// style — because the narrow column has no subtitle to convey
    /// branch identity. Full mode skips the stripe; the branch glyph in
    /// `subtitleRow` already carries the same signal.
    @ViewBuilder
    private var rowBackground: some View {
        ZStack(alignment: .leading) {
            rowFill
            if isCompact, workspace.worktreeParentId != nil {
                Rectangle()
                    .fill(Theme.chromeForeground.opacity(0.4))
                    .frame(width: 1.5)
            }
        }
    }

    private var rowFill: Color {
        if isActive { return Theme.chromeActive }
        if isHovered { return Theme.chromeHover }
        return .clear
    }
}
