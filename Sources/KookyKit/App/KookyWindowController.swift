import AppKit
import SwiftUI

/// One kooky window: an `NSWindow` paired with its own `WorkspaceStore`.
/// `AppDelegate` keeps an array of these — every window is fully
/// independent (own sidebar, own workspaces, own persisted slice keyed by
/// `windowId`).
@MainActor
final class KookyWindowController: NSWindowController, NSWindowDelegate {
    let windowId: UUID
    let store: WorkspaceStore
    /// Set by `AppDelegate`. Fires from `windowWillClose` so the delegate
    /// can drop this window from its list and decide whether the window's
    /// persisted slot survives (one of several closed) or is discarded.
    var onWillClose: ((KookyWindowController) -> Void)?
    /// Fires when this window becomes key — lets `AppDelegate` remember the
    /// most-recently-active kooky window, so menu actions route there when a
    /// Settings / Update panel is the key window instead.
    var onDidBecomeKey: ((KookyWindowController) -> Void)?

    init(windowId: UUID, store: WorkspaceStore) {
        self.windowId = windowId
        self.store = store
        super.init(window: Self.makeWindow())
        window?.delegate = self
        window?.contentView = NSHostingView(rootView: ContentView(store: store))
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
        if Theme.glassEnabled {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onDidBecomeKey?(self)
    }
}
