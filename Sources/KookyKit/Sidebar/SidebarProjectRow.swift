import SwiftUI

/// Sidebar header for one project — the folder its workspaces live in. The
/// row is the only place project-level actions live (new workspace, create
/// worktree, remove): a workspace row can't reach beyond its own folder, and
/// every one of these changes the project. There is no rename — the folder's
/// name is the project's name.
///
/// Styled as a source-list group header (small, muted, chevron-led) so the
/// workspace rows beneath it read as children without a second indent rule
/// fighting the row's own leading gutter.
struct SidebarProjectRow: View {
    let project: Project
    let isCollapsed: Bool
    /// Gates the worktree entry: a non-git folder has no repo to branch.
    let canCreateWorktree: Bool
    let onToggleCollapsed: () -> Void
    let onNewWorkspace: () -> Void
    let onCreateWorktree: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var isContextMenuOpen = false

    var body: some View {
        HStack(spacing: Theme.space2) {
            HoverableIconButton(
                systemName: "chevron.right",
                fontSize: 9,
                size: Theme.chromeContextButtonSize,
                help: isCollapsed ? "Show workspaces" : "Hide workspaces",
                action: onToggleCollapsed,
                rotation: isCollapsed ? 0 : 90
            )
            // Hierarchy is a primary interaction: the chevron stays visible
            // off-hover, unlike the row's own actions.
            .opacity(0.48)
            Text(project.title)
                .font(Theme.display(11.5, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            HStack(spacing: Theme.chromeControlSpacing) {
                if canCreateWorktree {
                    HoverableIconButton(
                        systemName: "arrow.triangle.branch",
                        fontSize: 10,
                        size: Theme.chromeContextButtonSize,
                        help: "Create worktree",
                        action: onCreateWorktree
                    )
                }
                HoverableIconButton(
                    systemName: "plus",
                    fontSize: 10,
                    size: Theme.chromeContextButtonSize,
                    help: "New workspace",
                    action: onNewWorkspace
                )
                HoverableIconButton(
                    systemName: "xmark",
                    fontSize: 10,
                    size: Theme.chromeContextButtonSize,
                    help: "Remove project",
                    action: onRemove
                )
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.leading, Theme.sidebarContentLeadingX - Theme.space2)
        .padding(.trailing, Theme.space3)
        .padding(.vertical, Theme.space1)
        .background(isHovered ? Theme.chromeHover : .clear)
        .clipShape(
            RoundedRectangle(
                cornerRadius: Theme.chromeSelectionCornerRadius,
                style: .continuous
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapsed)
        .onHover { isHovered = $0 }
        .overlay(RightClickCatcher { _ in isContextMenuOpen = true })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                KookyMenuRow(title: "New Workspace") {
                    isContextMenuOpen = false
                    onNewWorkspace()
                }
                if canCreateWorktree {
                    KookyMenuRow(title: "Create Worktree…") {
                        isContextMenuOpen = false
                        // One tick so the menu popover finishes dismissing
                        // before the sheet anchors on the same view.
                        DispatchQueue.main.async { onCreateWorktree() }
                    }
                }
                KookyMenuDivider()
                if !project.isSSHGroup {
                    // A remote group has no folder on this machine to reveal.
                    RevealInFinderMenuRow(url: project.rootPath) { isContextMenuOpen = false }
                }
                KookyMenuRow(title: "Remove Project…") {
                    isContextMenuOpen = false
                    onRemove()
                }
            }
            .padding(Theme.space1)
            .frame(minWidth: 240)
            .background(Theme.chromeBackground)
        }
        .help(project.isSSHGroup ? String(localized: "SSH workspaces") : project.rootPath.path)
    }
}
