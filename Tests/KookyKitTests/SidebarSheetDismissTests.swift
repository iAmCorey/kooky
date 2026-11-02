import AppKit
import SwiftUI
import XCTest

@testable import KookyKit

/// The sidebar hosts every modal in ONE `.sheet(item:)` and the store parks a
/// request that opens it. A system-initiated dismissal (Esc / ⌘.) nils the
/// item without calling the sidebar's own cancel path, so the parked flag has
/// to be cleared by `onDismiss` too — otherwise the next File › New SSH
/// Workspace sets an already-true flag, `onChange` never fires, and the sheet
/// silently stops appearing for the rest of the session.
///
/// These mount the real `SidebarView` in a real window: the failure mode lives
/// in SwiftUI's presentation plumbing, so store-only assertions cannot see it.
@MainActor
final class SidebarSheetDismissTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        // `orderOut` rather than `close`: closing a window whose content is an
        // NSHostingView whose sheet just went away segfaults (signal 11) in the
        // xctest process after the window is released.
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func mount(_ store: WorkspaceStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: SidebarView(store: store, mode: .full))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        pump()
        return window
    }

    /// Esc reaches the sheet as `cancelOperation`; nothing in kooky handles it,
    /// so the dismissal is entirely SwiftUI's.
    func testEscapeDismissalLetsTheSheetComeBack() throws {
        let store = makeTestStore()
        let window = mount(store)

        store.requestCreateSSHWorkspace()
        pump()
        let sheet = try XCTUnwrap(window.attachedSheet, "first request must present the sheet")

        sheet.cancelOperation(nil)
        pump()
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(
            store.pendingCreateSSHWorkspaceRequest,
            "a system dismissal must not leave the parked request true"
        )

        store.requestCreateSSHWorkspace()
        pump()
        XCTAssertNotNil(window.attachedSheet, "the next request must present the sheet again")
    }

    /// The explicit cancel path (button / ⌘W) clears the flag and the sheet.
    func testExplicitCancelKeepsPresentingOnEveryRequest() throws {
        let store = makeTestStore()
        let window = mount(store)

        for _ in 0..<3 {
            store.requestCreateSSHWorkspace()
            pump()
            XCTAssertNotNil(window.attachedSheet)
            store.requestDismissActiveSheet()
            pump()
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(store.pendingCreateSSHWorkspaceRequest)
        }
    }

    /// A request parked while a sheet is already up swaps the presented sheet
    /// in place. SwiftUI does not run the outgoing sheet's `onDismiss` for a
    /// swap, so one dismissal can never wipe the request that just arrived —
    /// and `clearParkedSheetRequest` sweeping every field stays safe.
    func testRequestParkedWhileSheetIsUpSurvivesTheSwap() throws {
        let store = makeTestStore()
        let window = mount(store)
        let workspace = store.addWorkspace(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            activate: false
        )

        store.requestCreateSSHWorkspace()
        pump()
        XCTAssertNotNil(window.attachedSheet, "the first request presents its sheet")

        store.pendingCreateWorktreeRequest = workspace
        pump()
        XCTAssertNotNil(window.attachedSheet, "the sidebar keeps presenting a sheet across the swap")
        XCTAssertNotNil(
            store.pendingCreateWorktreeRequest,
            "the outgoing sheet's dismissal must not clear the newcomer's request"
        )
    }
}
