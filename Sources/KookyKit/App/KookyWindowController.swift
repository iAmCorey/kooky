import AppKit
import SwiftUI

/// Width contract shared by SwiftUI content and the AppKit window boundary.
/// Sidebar views own their concrete full/compact widths; this policy adds the
/// visible pieces and reserves a genuinely usable terminal column between them.
@MainActor
enum KookyWindowLayout {
    /// Smallest width that keeps the fixed top-chrome controls plus the 28pt
    /// search trigger and its 15pt safety gap on both sides.
    static let minimumChromeWidth: CGFloat = 301
    /// Keeps one terminal useful at the narrowest supported window size while
    /// still leaving the status bar enough room to wrap inside its own pane.
    static let minimumTerminalWidth: CGFloat = 200
    static let separatorWidth: CGFloat = 1

    /// Width required by the current pane tree. Side-by-side children both
    /// need a full pane and a divider, while stacked children reuse the same
    /// horizontal span. This mirrors `SplitContainer`'s rendering recursion.
    static func minimumTerminalTreeWidth(for node: PaneNode?) -> CGFloat {
        guard let node else { return minimumTerminalWidth }
        switch node.content {
        case .pane:
            return minimumTerminalWidth
        case .split(let orientation, let first, let second, _):
            let firstWidth = minimumTerminalTreeWidth(for: first)
            let secondWidth = minimumTerminalTreeWidth(for: second)
            switch orientation {
            case .horizontal:
                return firstWidth + separatorWidth + secondWidth
            case .vertical:
                return max(firstWidth, secondWidth)
            }
        }
    }

    /// Rebalances only horizontal splits on the root→target path after a
    /// leaf is split. Without this, repeatedly splitting the rightmost pane
    /// leaves every ancestor at 50/50, producing 1/2, 1/4, 1/8… widths even
    /// when sibling panes have abundant space. Unrelated branches — including
    /// user-adjusted dividers elsewhere — are untouched.
    @discardableResult
    static func rebalanceHorizontalSplits(in node: PaneNode, alongPathTo target: PaneNode) -> Bool {
        if node === target {
            rebalanceHorizontalSplit(node)
            return true
        }
        guard case .split(let orientation, let first, let second, let fraction) = node.content else {
            return false
        }
        let targetIsBelow = rebalanceHorizontalSplits(in: first, alongPathTo: target)
            || rebalanceHorizontalSplits(in: second, alongPathTo: target)
        guard targetIsBelow else { return false }
        if orientation == .horizontal {
            let balanced = balancedFraction(first: first, second: second)
            if abs(balanced - fraction) > .ulpOfOne {
                node.content = .split(
                    orientation: orientation,
                    first: first,
                    second: second,
                    fraction: balanced
                )
            }
        }
        return true
    }

    private static func rebalanceHorizontalSplit(_ node: PaneNode) {
        guard case .split(.horizontal, let first, let second, let fraction) = node.content else { return }
        let balanced = balancedFraction(first: first, second: second)
        guard abs(balanced - fraction) > .ulpOfOne else { return }
        node.content = .split(
            orientation: .horizontal,
            first: first,
            second: second,
            fraction: balanced
        )
    }

    private static func balancedFraction(first: PaneNode, second: PaneNode) -> Double {
        let firstWidth = minimumTerminalTreeWidth(for: first)
        let secondWidth = minimumTerminalTreeWidth(for: second)
        return Double(firstWidth / (firstWidth + secondWidth))
    }

    static func minimumWindowWidth(
        leftMode: SidebarMode,
        expandedLeftWidth: CGFloat,
        rightMode: SidebarMode,
        expandedRightWidth: CGFloat,
        terminalWidth: CGFloat = minimumTerminalWidth
    ) -> CGFloat {
        let leftWidth: CGFloat
        switch leftMode {
        case .full: leftWidth = SidebarView.clampWidth(expandedLeftWidth)
        case .compact: leftWidth = SidebarView.compactWidth
        case .hidden: leftWidth = 0
        }

        let rightWidth: CGFloat
        switch rightMode {
        case .full: rightWidth = AgentOverviewSidebar.clampWidth(expandedRightWidth)
        case .compact: rightWidth = AgentOverviewSidebar.compactWidth
        case .hidden: rightWidth = 0
        }

        let separators = (leftMode == .hidden ? 0 : separatorWidth)
            + (rightMode == .hidden ? 0 : separatorWidth)
        return max(
            minimumChromeWidth,
            leftWidth + separators + terminalWidth + rightWidth
        )
    }

    static func screenBoundMinimumWindowWidth(
        desiredWidth: CGFloat,
        visibleScreenWidth: CGFloat?
    ) -> CGFloat {
        guard let visibleScreenWidth, visibleScreenWidth > 0 else { return desiredWidth }
        return min(desiredWidth, visibleScreenWidth)
    }

    /// Clamps a divider to the usable size required by both child trees.
    /// A side-by-side subtree may itself contain several terminal columns,
    /// so a fixed 10% bound is not enough to keep every leaf usable. When the
    /// current screen is physically too narrow for all requested minima, pin
    /// the divider to the proportional split instead of allowing one branch
    /// to absorb all of the compression.
    static func clampedSplitFraction(
        _ proposed: Double,
        orientation: SplitOrientation,
        first: PaneNode,
        second: PaneNode,
        usableLength: CGFloat
    ) -> Double {
        guard usableLength > 0 else { return 0.5 }
        guard orientation == .horizontal else {
            return min(max(proposed, 0.1), 0.9)
        }

        let firstMinimum = minimumTerminalTreeWidth(for: first)
        let secondMinimum = minimumTerminalTreeWidth(for: second)
        let required = firstMinimum + secondMinimum
        guard usableLength >= required else {
            return Double(firstMinimum / required)
        }

        let minimumFraction = Double(firstMinimum / usableLength)
        let maximumFraction = 1 - Double(secondMinimum / usableLength)
        return min(max(proposed, minimumFraction), maximumFraction)
    }
}

/// One kooky window: an `NSWindow` paired with its own `WorkspaceStore`.
/// `AppDelegate` keeps an array of these — every window is fully
/// independent (own sidebar, own workspaces, own persisted slice keyed by
/// `windowId`).
@MainActor
final class KookyWindowController: NSWindowController, NSWindowDelegate {
    let windowId: UUID
    let store: WorkspaceStore
    /// The window's persistent AppKit pane-tree host. Owned here — not by
    /// SwiftUI — so every terminal NSView's lifetime is bound to the window,
    /// never to SwiftUI view identity.
    let paneHost: PaneTreeHostView
    /// Set by `AppDelegate`. Fires from `windowWillClose` so the delegate
    /// can drop this window from its list and decide whether the window's
    /// persisted slot survives (one of several closed) or is discarded.
    var onWillClose: ((KookyWindowController) -> Void)?
    /// Fires when this window becomes key — lets `AppDelegate` remember the
    /// most-recently-active kooky window, so menu actions route there when a
    /// Settings / Update panel is the key window instead.
    var onDidBecomeKey: ((KookyWindowController) -> Void)?

    init(windowId: UUID, store: WorkspaceStore, frameSize: PersistedWindowSize? = nil) {
        self.windowId = windowId
        self.store = store
        self.paneHost = PaneTreeHostView(store: store)
        super.init(window: Self.makeWindow(frameSize: frameSize))
        window?.delegate = self
        window?.contentView = NSHostingView(
            rootView: ContentView(store: store, paneHost: paneHost) { [weak self] expandIfNeeded, animate in
                self?.updateMinimumWindowSize(expandIfNeeded: expandIfNeeded, animate: animate)
            }
        )
        alignTrafficLights()
        // AppKit may perform one final titlebar layout after the hosting view
        // is attached. Reapply once on the next run-loop turn; the operation
        // is absolute and idempotent, so this can never accumulate an offset.
        DispatchQueue.main.async { [weak self] in self?.alignTrafficLights() }
        updateMinimumWindowSize(expandIfNeeded: true, animate: false)
        // The last workspace closing leaves an empty window — close it.
        store.onBecameEmpty = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError("not a storyboard window") }

    /// Builds a kooky main window with the standard chrome. Mirrors the
    /// config that used to live inline in `applicationDidFinishLaunching`.
    private static func makeWindow(frameSize: PersistedWindowSize?) -> NSWindow {
        let size = if let frameSize,
                      frameSize.width.isFinite,
                      frameSize.width > 0,
                      frameSize.height.isFinite,
                      frameSize.height > 0 {
            NSSize(width: CGFloat(frameSize.width), height: CGFloat(frameSize.height))
        } else {
            NSSize(width: 1100, height: 720)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = KookyApp.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Tab strips sit under the transparent titlebar; only our explicit
        // sidebar handle moves the window so tab DnD never races AppKit.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.appearance = Theme.windowAppearance
        // The controller governs the window's lifetime; without this,
        // `close()` would also `release` it out from under the controller.
        window.isReleasedWhenClosed = false
        // Every window's NSWindow title is the app name, so the system
        // Windows-menu / Dock-tile auto window list stacks a useless
        // "kooky × N" above our own workspace/tab list. Drop them — the Dock
        // menu's workspace list and ⌘P are the real navigation.
        window.isExcludedFromWindowsMenu = true
        // Liquid Glass needs a non-opaque window so the glass layer can sample
        // the desktop behind it and the terminal's `background-opacity` reads
        // through. `refreshThemeAppearances` keeps this in sync on live edits.
        window.applyGlassBacking()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        alignTrafficLights()
        onDidBecomeKey?(self)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        alignTrafficLights()
        updateMinimumWindowSize(expandIfNeeded: true, animate: false)
    }

    func windowDidResize(_ notification: Notification) {
        alignTrafficLights()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        alignTrafficLights()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, minimumWindowWidth(on: sender.screen)),
            height: frameSize.height
        )
    }

    private var desiredMinimumWindowWidth: CGFloat {
        KookyWindowLayout.minimumWindowWidth(
            leftMode: store.sidebarMode,
            expandedLeftWidth: store.sidebarWidth,
            rightMode: store.rightSidebarMode,
            expandedRightWidth: store.rightSidebarWidth,
            terminalWidth: KookyWindowLayout.minimumTerminalTreeWidth(for: store.active?.root)
        )
    }

    private func minimumWindowWidth(on screen: NSScreen?) -> CGFloat {
        KookyWindowLayout.screenBoundMinimumWindowWidth(
            desiredWidth: desiredMinimumWindowWidth,
            visibleScreenWidth: (screen ?? NSScreen.main)?.visibleFrame.width
        )
    }

    /// SwiftUI cannot reposition AppKit's native titlebar controls. Keep that
    /// imperative edge here: move the standard three-button group as a unit,
    /// preserving native sizes, spacing, hit testing, accessibility, and
    /// fullscreen behaviour. Computing the delta from the close button's
    /// current centre makes repeated lifecycle calls idempotent and also
    /// repairs AppKit relayouts after leaving fullscreen.
    private func alignTrafficLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton)
        else { return }
        let delta = Theme.sidebarLeadingIconCenterX - close.frame.midX
        guard abs(delta) > .ulpOfOne else { return }
        for type in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x + delta, y: button.frame.origin.y))
        }
    }

    /// `NSWindow.minSize` does not follow observable sidebar/pane-tree state,
    /// so mirror the current layout policy here. If the required width grows,
    /// expand up to the current screen's visible width; beyond that physical
    /// limit, the balanced split fractions let every pane shrink together.
    func updateMinimumWindowSize(expandIfNeeded: Bool, animate: Bool) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        let width = minimumWindowWidth(on: screen)
        window.minSize = NSSize(width: width, height: window.minSize.height)
        guard expandIfNeeded, window.frame.width < width else { return }

        var target = window.frame
        target.size.width = width
        if let screen {
            target = window.constrainFrameRect(target, to: screen)
        }
        window.setFrame(target, display: true, animate: animate)
    }

}
