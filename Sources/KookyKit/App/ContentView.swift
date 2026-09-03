import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    /// The window's persistent AppKit pane-tree host, owned by
    /// `KookyWindowController`. Passing the instance (instead of building it
    /// here) is what guarantees SwiftUI structure changes can never tear the
    /// terminal tree down — the representable always re-mounts the same view.
    let paneHost: PaneTreeHostView
    /// Narrow AppKit seam: the store remains the source of truth for sidebar
    /// state; the owning window controller only mirrors those widths into
    /// `NSWindow.minSize`. `expandIfNeeded` asks it to grow the window frame
    /// to the new minimum when it's narrower (mode toggles, pane-tree
    /// changes); drag-driven width changes pass `false` — the window must
    /// never jump while a sidebar drag is in flight. `animate` animates that
    /// expansion (mode toggles only).
    var onWindowLayoutChange: (_ expandIfNeeded: Bool, _ animate: Bool) -> Void = { _, _ in }

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            Rectangle().fill(Theme.chromeSeparator).frame(height: 1)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if store.sidebarMode != .hidden {
                        SidebarView(store: store, mode: store.sidebarMode)
                            .frame(width: sidebarWidth)
                        Rectangle().fill(Theme.chromeSeparator)
                            .frame(width: 1)
                            .offset(x: sidebarWidth)
                    }
                    mainPane
                        .frame(width: terminalWidth(in: geo.size.width), height: geo.size.height)
                        .offset(x: terminalLeadingOffset)
                    if store.rightSidebarMode != .hidden {
                        Rectangle().fill(Theme.chromeSeparator)
                            .frame(width: 1)
                            .offset(x: geo.size.width - rightSidebarWidth - 1)
                        AgentOverviewSidebar(store: store, mode: store.rightSidebarMode)
                            .frame(width: rightSidebarWidth)
                            .offset(x: geo.size.width - rightSidebarWidth)
                    }
                }
            }
        }
        .glassWindowBackground(fallback: Theme.chromeBackground, followsOpacity: true)
        .preferredColorScheme(Theme.chromeColorScheme)
        .ignoresSafeArea(.all)
        .onChange(of: store.sidebarMode) { _, _ in
            onWindowLayoutChange(true, true)
        }
        .onChange(of: store.rightSidebarMode) { _, _ in
            onWindowLayoutChange(true, true)
        }
        .onChange(of: store.isSidebarResizing) { _, active in
            // Never expand the window during an interactive sidebar drag;
            // updating `minSize` is enough and avoids a per-frame window jump.
            if active { onWindowLayoutChange(false, false) }
        }
        .onChange(of: store.sidebarWidth) { _, _ in
            onWindowLayoutChange(false, false)
        }
        .onChange(of: store.rightSidebarWidth) { _, _ in
            onWindowLayoutChange(false, false)
        }
        .onChange(of: minimumTerminalTreeWidth) { _, _ in
            // Split/close/workspace-switch is discrete. Expand immediately:
            // unlike sidebar mode changes, split creation does not suspend
            // existing engines for an animation-wide SIGWINCH burst.
            // A smaller tree only relaxes the future resize limit.
            onWindowLayoutChange(true, false)
        }
    }
    /// Top chrome strip. `window.isMovable = false` is set globally, so the
    /// `WindowDragHandle` background is the only place AppKit allows
    /// window dragging. The responsive `SearchTriggerPill` is scoped to the
    /// drag-handle area (not the whole strip), with an explicit safety gap
    /// from the controls on either side. It condenses before disappearing,
    /// so narrow windows keep a usable quick-open target whenever possible;
    /// `⌘P` + the File menu remain available when it is fully hidden.
    private var topStrip: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Theme.topStripLeadingReservedWidth)
                .allowsHitTesting(false)
            HoverableIconButton(
                systemName: "sidebar.left",
                fontSize: 12,
                size: Theme.chromeToolbarButtonSize,
                help: sidebarTooltip
            ) {
                withAnimation(Theme.chromeTransition) {
                    store.setSidebarMode(store.sidebarMode.next)
                }
            }
            WindowDragHandle()
                .overlay {
                    GeometryReader { proxy in
                        if KookySettingsModel.shared.showSearchPill,
                           proxy.size.width >= SearchTriggerPill.minimumContainerWidth {
                            SearchTriggerPill {
                                NSApp.sendAction(#selector(AppDelegate.handleQuickOpen), to: nil, from: nil)
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                }
            HStack(spacing: Theme.chromeControlSpacing) {
                OpenInButton(store: store)
                HoverableIconButton(
                    systemName: "sidebar.right",
                    fontSize: 12,
                    size: Theme.chromeToolbarButtonSize,
                    help: "Agent Panel"
                ) {
                    withAnimation(Theme.chromeTransition) {
                        store.setRightSidebarMode(store.rightSidebarMode.next)
                    }
                }
                InboxBell()
                // Rightmost on purpose: a status light lives in the corner —
                // like a hardware power LED — not mixed into content buttons.
                KeepAwakeButton()
            }
            .padding(.trailing, Theme.chromeBarEdgeInset)
        }
        .frame(height: 32)
        .glassChromeBackground()
    }

    private var mainPane: some View {
        // No `.id`, no conditional: the host view is permanent and handles
        // "no workspace" itself. The old `.id(workspace.id)` teardown/rebuild
        // per switch was the root of the mount-churn bug class (issues #8,
        // #24, workspace-switch flicker) — the AppKit host switches by
        // visibility instead.
        PaneTreeHostRepresentable(host: paneHost)
    }

    private var minimumTerminalTreeWidth: CGFloat {
        KookyWindowLayout.minimumTerminalTreeWidth(for: store.active?.root)
    }

    /// Rendered width of the left sidebar under the current mode — compact
    /// and hidden are fixed, full follows the store's draggable width.
    /// Mirrors `SidebarView`'s own `frame(width:)` so the terminal's leading
    /// offset can never disagree with the sidebar's rendered edge.
    private var sidebarWidth: CGFloat {
        switch store.sidebarMode {
        case .full: return store.sidebarWidth
        case .compact: return SidebarView.compactWidth
        case .hidden: return 0
        }
    }

    private var rightSidebarWidth: CGFloat {
        switch store.rightSidebarMode {
        case .full: return store.rightSidebarWidth
        case .compact: return AgentOverviewSidebar.compactWidth
        case .hidden: return 0
        }
    }

    private var terminalLeadingOffset: CGFloat {
        sidebarWidth + (store.sidebarMode == .hidden ? 0 : 1)
    }

    /// Terminal width for the given content width. The drag gesture uses a
    /// global coordinate space, so the sidebar edge is stable while this
    /// value follows the live width on every frame. Engine size propagation
    /// remains suspended until drag end to avoid SIGWINCH storms.
    private func terminalWidth(in total: CGFloat) -> CGFloat {
        let separators = (store.sidebarMode == .hidden ? 0 : 1)
            + (store.rightSidebarMode == .hidden ? 0 : 1)
        return max(0, total - sidebarWidth - rightSidebarWidth - CGFloat(separators))
    }

    private var sidebarTooltip: String {
        switch store.sidebarMode {
        case .full: return String(localized: "Compact sidebar", bundle: .kookyResources)
        case .compact: return String(localized: "Hide sidebar", bundle: .kookyResources)
        case .hidden: return String(localized: "Show sidebar", bundle: .kookyResources)
        }
    }

}
