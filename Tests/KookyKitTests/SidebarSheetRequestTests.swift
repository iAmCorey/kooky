import AppKit
import SwiftUI
import XCTest

@testable import KookyKit

/// The sidebar hosts every modal in one `.sheet(item:)`, opened from requests
/// the store parks. These put the real `SidebarView` in a real window: the
/// bug they pin lives in SwiftUI's presentation path (Esc dismisses a sheet
/// without running any kooky code), which store-only tests cannot reach.
@MainActor
final class SidebarSheetRequestTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        if let window {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        window = nil
        super.tearDown()
    }

    /// Sheet presentation and dismissal finish within a few run-loop turns,
    /// so poll instead of sleeping a fixed interval.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Mounts the real `SidebarView` and returns after its first frame has
    /// rendered, so a later request reaches it through `onChange` as it does
    /// in the app, not through `onAppear`.
    private func mountSidebar(_ store: WorkspaceStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SidebarView(store: store, mode: .full))
        window.orderFrontRegardless()
        self.window = window
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return window
    }

    /// A real Esc keystroke, delivered to the sheet's first responder the
    /// way AppKit delivers it (the SSH sheet's focused text field).
    private func pressEscape(in sheet: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            ))
            sheet.sendEvent(event)
        }
    }

    private func addWorktree(to store: WorkspaceStore, of source: Workspace, branch: String) -> Workspace {
        store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp/kooky-sheet-test-\(branch)"),
            worktreeParent: source,
            worktreeBranch: branch
        )
    }

    func testSSHSheetReopensAfterEscape() throws {
        let store = makeTestStore()
        let window = mountSidebar(store)

        store.requestCreateSSHWorkspace()
        XCTAssertTrue(waitUntil { window.attachedSheet != nil }, "the request presents the sheet")
        try pressEscape(in: XCTUnwrap(window.attachedSheet))
        XCTAssertTrue(waitUntil { window.attachedSheet == nil }, "Esc dismisses the sheet")
        // A request left parked here also popped the sheet back up by itself
        // the next time the sidebar was shown (its onAppear presents it).
        XCTAssertFalse(store.pendingCreateSSHWorkspaceRequest, "nothing stays parked after Esc")

        store.requestCreateSSHWorkspace()
        XCTAssertTrue(waitUntil { window.attachedSheet != nil }, "the next request presents the sheet again")
    }

    func testClosingTheSameWorktreeAsksAgainAfterEscape() throws {
        let store = makeTestStore()
        let worktree = addWorktree(to: store, of: store.workspaces[0], branch: "feat")
        let window = mountSidebar(store)

        store.requestCloseWorkspace(worktree)
        XCTAssertTrue(waitUntil { window.attachedSheet != nil }, "closing a worktree asks first")
        try pressEscape(in: XCTUnwrap(window.attachedSheet))
        XCTAssertTrue(waitUntil { window.attachedSheet == nil }, "Esc dismisses the confirm sheet")

        store.requestCloseWorkspace(worktree)
        XCTAssertTrue(waitUntil { window.attachedSheet != nil }, "closing the same worktree again asks again")
        store.requestDismissActiveSheet()
        XCTAssertTrue(waitUntil { window.attachedSheet == nil }, "⌘W cancels the confirm sheet")
        XCTAssertTrue(store.workspaces.contains { $0.id == worktree.id }, "nothing closes until the sheet confirms")
    }

    func testCloseConfirmationRequestedBehindAHiddenSidebarPresents() throws {
        let store = makeTestStore()
        let worktree = addWorktree(to: store, of: store.workspaces[0], branch: "hidden")
        store.setSidebarMode(.hidden)
        // The app's own window, so ContentView's rule (mount SidebarView only
        // while the sidebar is shown) decides whether anything hosts the sheet.
        let controller = KookyWindowController(windowId: UUID(), store: store)
        let window = try XCTUnwrap(controller.window)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            controller.close()
            store.terminate()
        }
        window.orderFrontRegardless()

        store.requestCloseWorkspace(worktree)
        XCTAssertTrue(
            waitUntil { window.attachedSheet != nil },
            "the sidebar comes back and presents the confirm sheet"
        )
    }
}
