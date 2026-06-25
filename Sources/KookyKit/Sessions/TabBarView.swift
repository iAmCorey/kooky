import AppKit
import SwiftUI

/// Per-pane tab strip — each split region renders its own. The "+" button
/// targets the pane it sits in.
struct TabBarView: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    @State private var isAddMenuOpen = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        DraggableTabRow(
                            tab: tab,
                            pane: pane,
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            canCloseToRight: index < pane.tabs.count - 1
                        )
                    }
                    addButton
                }
                .padding(.horizontal, Theme.space2)
            }
            // Double-click on tab bar empty area triggers macOS Zoom (filled
            // screen, dock/menu kept) — same gesture as the system title-bar
            // double-click. SwiftUI arbitrates count: 2 alongside children's
            // count: 1 taps so tab activation still fires on single click.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                NSApplication.shared.keyWindow?.performZoom(nil)
            }

            // Split controls pinned to the trailing edge — outside the
            // ScrollView so they stay put while the tabs scroll.
            splitButtons
        }
        .frame(height: 40)
    }

    /// Split-right / split-down buttons. Mirror ⌘D / ⌘⇧D exactly: Split
    /// Right is the `.horizontal` orientation (panes side by side), Split
    /// Down is `.vertical` (panes stacked) — same mapping as
    /// `AppDelegate.handleSplitRight` / `handleSplitDown`.
    private var splitButtons: some View {
        HStack(spacing: 2) {
            HoverableIconButton(
                systemName: "square.split.2x1",
                fontSize: 12,
                size: 28,
                help: "Split Right (⌘D)"
            ) {
                store.splitPane(pane, orientation: .horizontal, in: workspace)
            }
            HoverableIconButton(
                systemName: "square.split.1x2",
                fontSize: 12,
                size: 28,
                help: "Split Down (⌘⇧D)"
            ) {
                store.splitPane(pane, orientation: .vertical, in: workspace)
            }
        }
        .padding(.trailing, Theme.space2)
    }

    private var addButton: some View {
        AddTabButton(
            pane: pane,
            workspace: workspace,
            store: store,
            isMenuOpen: $isAddMenuOpen
        )
    }
}

/// `+` button doubling as the "drop at end" target — dragging a tab here
/// (from this pane or another) appends it after the last tab, which is
/// otherwise unreachable inside a horizontal `ScrollView` where there's no
/// flex space for a trailing drop zone.
private struct AddTabButton: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    @Binding var isMenuOpen: Bool

    @State private var isTargeted = false

    var body: some View {
        HoverableIconButton(
            systemName: "plus",
            fontSize: 12,
            size: 28,
            help: "New tab"
        ) {
            // Two short-circuit paths that skip the popover entirely:
            //   1. user picked a default agent in Settings — open it
            //   2. every coding agent is hidden so the popover would show
            //      just Terminal anyway — open Terminal
            let model = KookySettingsModel.shared
            if let defaultTemplate = AgentTemplate.defaultLaunchTemplate(model: model) {
                store.addTab(in: workspace, pane: pane, template: defaultTemplate)
            } else if AgentTemplate.visibleOrdered(model: model).count <= 1 {
                store.addTab(in: workspace, pane: pane, template: .terminal)
            } else {
                isMenuOpen.toggle()
            }
        }
        // Indicator sits in the gap just left of the `+` (offset by half its
        // hit-area), not on the button itself, so it reads as "tab will land
        // here, after the last one" rather than "drop on +".
        .dropIndicator(active: isTargeted, on: .leading, offset: -3)
        .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentTemplate.visibleOrdered(model: KookySettingsModel.shared)) { template in
                    KookyMenuRow(title: template.title) {
                        AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 16)
                    } action: {
                        store.addTab(in: workspace, pane: pane, template: template)
                        isMenuOpen = false
                    }
                }
            }
            .padding(Theme.space1)
            .frame(minWidth: 220)
            .glassChromeBackground()
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil }
            guard let id = dropped.first.flatMap(UUID.init) else { return false }
            return withAnimation(.easeInOut(duration: 0.18)) {
                store.handleTabDrop(droppedId: id, to: pane, at: pane.tabs.count, in: workspace)
            }
        } isTargeted: { isTargeted = $0 }
    }
}

/// Wraps `TabBarItem` with drag source + drop target. Same-pane drops
/// reorder; cross-pane drops move the session into this pane (source pane
/// collapses if it runs out of tabs). The 2pt indicator follows drag
/// direction — `leading` for left-of-target sources, `trailing` for
/// right-of-target — so the line always shows where the dropped tab lands.
private struct DraggableTabRow: View {
    @Bindable var tab: Session
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let canCloseToRight: Bool

    @State private var isTargeted = false

    var body: some View {
        let originIndex: Int? = {
            guard let id = store.draggingTabId, id != tab.id else { return nil }
            return pane.tabs.firstIndex(where: { $0.id == id })
        }()
        let dragsRightward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsRightward ? .trailing : .leading
        let isSelfDrag = store.draggingTabId == tab.id

        TabBarItem(
            tab: tab,
            isActive: pane.activeTabId == tab.id,
            canCloseToRight: canCloseToRight,
            onActivate: { store.activateTab(tab, in: workspace) },
            onClose: { store.closeTab(tab, in: workspace) },
            onCloseOthers: { store.closeOtherTabs(keeping: tab, in: workspace) },
            onCloseToRight: { store.closeTabsToRight(of: tab, in: workspace) },
            onDuplicate: { store.duplicateTab(tab, in: workspace) },
            onRename: { store.renameTab(tab, to: $0) },
            onSplit: { store.splitPane(pane, orientation: $0, in: workspace) },
            onMoveToNewWindow: { store.moveTabToNewWindow(tab.id) }
        )
        .dropIndicator(active: isTargeted && !isSelfDrag, on: edge)
        .onDrag {
            store.draggingTabId = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil }
            guard let id = dropped.first.flatMap(UUID.init) else { return false }
            return withAnimation(.easeInOut(duration: 0.18)) {
                store.handleTabDrop(droppedId: id, to: pane, at: myIndex, in: workspace)
            }
        } isTargeted: { isTargeted = $0 }
    }
}
