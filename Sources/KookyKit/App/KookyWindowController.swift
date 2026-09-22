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
    /// Set by `AppDelegate`. Fires from `windowShouldClose` — a user-initiated
    /// close (traffic light) — and returning `false` keeps the window alive;
    /// the delegate hides the last window instead of tearing its sessions
    /// down. Programmatic `close()` (the emptied-window path) bypasses it.
    var onShouldClose: ((KookyWindowController) -> Bool)?
    /// Ordered out by a user close, sessions still running. Explicit rather
    /// than derived from `NSWindow.isVisible`, which ⌘H (Hide kooky) and a
    /// just-closed window awaiting its next-tick drop also make false.
    private(set) var hiddenOnClose = false
    /// Fires when this window becomes key — lets `AppDelegate` remember the
    /// most-recently-active kooky window, so menu actions route there when a
    /// Settings / Update panel is the key window instead.
    var onDidBecomeKey: ((KookyWindowController) -> Void)?

    /// The frame kooky persists for this window: the live frame, or — while
    /// in native fullscreen, transitions included — the frame it had before
    /// entering, so a ⌘Q from fullscreen doesn't restore a screen-sized
    /// normal window. Read through `WindowPersistence.frameProvider` on every
    /// state save; nil once the window is gone (the saved value is kept).
    var persistableFrame: PersistedFrame? {
        guard let window else { return nil }
        return PersistedFrame(preFullScreenFrame ?? window.frame)
    }
    private var preFullScreenFrame: NSRect?

    init(windowId: UUID, store: WorkspaceStore) {
        self.windowId = windowId
        self.store = store
        self.paneHost = PaneTreeHostView(store: store)
        super.init(window: Self.makeWindow())
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
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
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

    /// The close-instead-of-hide half of `shouldCloseWindow`.
    func hideInsteadOfClose() {
        hiddenOnClose = true
        store.setOnScreen(false)
        window?.orderOut(nil)
    }

    /// Any path that puts the window back in front (Dock reopen, deep link,
    /// menu action) lands here — from `front(_:)` explicitly and again from
    /// `windowDidBecomeKey`, whichever comes first.
    func markPresented() {
        hiddenOnClose = false
        store.setOnScreen(true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onShouldClose?(self) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        markPresented()
        alignTrafficLights()
        onDidBecomeKey?(self)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        alignTrafficLights()
        updateMinimumWindowSize(expandIfNeeded: true, animate: false)
    }

    func windowDidResize(_ notification: Notification) {
        alignTrafficLights()
        noteFrameChanged()
    }

    func windowDidMove(_ notification: Notification) {
        noteFrameChanged()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        preFullScreenFrame = window?.frame
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        preFullScreenFrame = nil
        alignTrafficLights()
        // The exit transition's own resize / move notifications arrived while
        // the frame was pinned and were skipped — save once now.
        noteFrameChanged()
    }

    /// An interrupted enter (animation cancelled, gesture conflict) leaves a
    /// normal window with no `didExit` coming — unpin here or every later
    /// move / resize would be ignored and the stale frame saved forever.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        preFullScreenFrame = nil
        noteFrameChanged()
    }

    /// Per-frame during drags and live resizes; the store's 1s debounce
    /// coalesces those into one write. While fullscreen the persisted frame
    /// is pinned to `preFullScreenFrame`, so a save would only rewrite
    /// state.json with what's already on disk.
    private func noteFrameChanged() {
        guard preFullScreenFrame == nil else { return }
        store.scheduleSave()
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

extension PersistedFrame {
    init(_ rect: NSRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

/// Where a window with a saved frame goes on the CURRENT screen layout.
/// Pure so the display-gone / half-offscreen / oversize cases are unit-tested.
enum WindowPlacement {
    /// `screens` are visible frames (menu bar and Dock excluded), main screen
    /// first. The saved frame is kept where it overlaps a screen the most,
    /// pulled fully inside it and clamped to its size (a monitor that shrank)
    /// and to `minSize` (the window's layout minimum grew since). A frame
    /// that overlaps no screen — the display it lived on is gone — keeps its
    /// size and lands centered on the main screen. nil only for garbage
    /// (non-finite / non-positive) or no screens at all.
    static func restoredFrame(_ saved: NSRect, minSize: NSSize, screens: [NSRect]) -> NSRect? {
        guard saved.origin.x.isFinite, saved.origin.y.isFinite,
              saved.width.isFinite, saved.height.isFinite,
              saved.width > 0, saved.height > 0,
              let main = screens.first
        else { return nil }
        let overlap = { (screen: NSRect) -> CGFloat in
            let i = screen.intersection(saved)
            return i.isNull ? 0 : i.width * i.height
        }
        if let screen = screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 {
            return fit(saved, in: screen, minSize: minSize)
        }
        // Display gone: settle the size first (same clamps as above), then
        // center THAT — centering the saved size and growing afterwards
        // would push the window off-center by half the growth.
        let sized = fit(saved, in: main, minSize: minSize).size
        return NSRect(
            x: main.midX - sized.width / 2, y: main.midY - sized.height / 2,
            width: sized.width, height: sized.height
        )
    }

    private static func fit(_ frame: NSRect, in screen: NSRect, minSize: NSSize) -> NSRect {
        var f = frame
        f.size.width = min(max(f.width, minSize.width), screen.width)
        f.size.height = min(max(f.height, minSize.height), screen.height)
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        f.origin.y = min(max(f.minY, screen.minY), screen.maxY - f.height)
        return f
    }
}
