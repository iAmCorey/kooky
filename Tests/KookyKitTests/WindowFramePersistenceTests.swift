import AppKit
import XCTest
@testable import KookyKit

/// Placement of a saved frame against the current screens, and the window
/// controller's side of frame persistence. The state.json half lives in
/// `PersistenceTests`.
@MainActor
final class WindowFramePersistenceTests: XCTestCase {
    private let main = NSRect(x: 0, y: 0, width: 1512, height: 950)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
    private let minSize = NSSize(width: 600, height: 300)

    func testFrameOnAScreenIsKeptAsIs() {
        let saved = NSRect(x: 1700, y: 200, width: 1400, height: 900)
        XCTAssertEqual(
            WindowPlacement.restoredFrame(saved, minSize: minSize, screens: [main, external]),
            saved
        )
    }

    func testFrameHangingOffAScreenIsPulledInside() {
        // Past the external screen's top-right corner: stays on that screen,
        // shifted back inside it.
        let offExternal = NSRect(x: 3500, y: 1000, width: 1000, height: 700)
        XCTAssertEqual(
            WindowPlacement.restoredFrame(offExternal, minSize: minSize, screens: [main, external]),
            NSRect(x: 3072, y: 715, width: 1000, height: 700)
        )
        // Hanging off main's bottom-right with no external screen.
        let offMain = NSRect(x: 1200, y: -100, width: 1000, height: 700)
        XCTAssertEqual(
            WindowPlacement.restoredFrame(offMain, minSize: minSize, screens: [main]),
            NSRect(x: 512, y: 0, width: 1000, height: 700)
        )
    }

    func testOversizeFrameShrinksToItsScreen() {
        let saved = NSRect(x: 100, y: 100, width: 3000, height: 2000)
        XCTAssertEqual(
            WindowPlacement.restoredFrame(saved, minSize: minSize, screens: [main]),
            main
        )
    }

    func testFrameWhoseDisplayIsGoneLandsCenteredOnMainAtItsSize() {
        let saved = NSRect(x: 4000, y: 4000, width: 1000, height: 600)
        XCTAssertEqual(
            WindowPlacement.restoredFrame(saved, minSize: minSize, screens: [main]),
            NSRect(x: 256, y: 175, width: 1000, height: 600)
        )
    }

    func testFrameWhoseDisplayIsGoneGrowsToTheMinimumAndStaysCentered() {
        let saved = NSRect(x: 4000, y: 4000, width: 400, height: 200)
        XCTAssertEqual(
            WindowPlacement.restoredFrame(saved, minSize: minSize, screens: [main]),
            NSRect(x: 456, y: 325, width: 600, height: 300)
        )
    }

    func testFrameBelowTheLayoutMinimumGrows() {
        let saved = NSRect(x: 100, y: 100, width: 300, height: 200)
        let placed = WindowPlacement.restoredFrame(saved, minSize: minSize, screens: [main])
        XCTAssertEqual(placed?.size, minSize)
    }

    func testGarbageFrameOrNoScreensGivesNoPlacement() {
        XCTAssertNil(WindowPlacement.restoredFrame(NSRect(x: 0, y: 0, width: 0, height: 700), minSize: minSize, screens: [main]))
        XCTAssertNil(WindowPlacement.restoredFrame(NSRect(x: CGFloat.nan, y: 0, width: 800, height: 700), minSize: minSize, screens: [main]))
        XCTAssertNil(WindowPlacement.restoredFrame(NSRect(x: 0, y: 0, width: 800, height: 700), minSize: minSize, screens: []))
    }

    // MARK: - The controller's persistable frame

    func testPersistableFrameFollowsTheWindowExceptWhileFullscreen() throws {
        let store = makeTestStore()
        let controller = KookyWindowController(windowId: UUID(), store: store)
        defer {
            controller.close()
            store.terminate()
        }
        let window = try XCTUnwrap(controller.window)
        let normal = NSRect(x: 50, y: 60, width: 1300, height: 800)
        window.setFrame(normal, display: false)
        XCTAssertEqual(controller.persistableFrame?.rect, normal)

        // Synthetic fullscreen transition: AppKit resizes the window to the
        // screen between willEnter and didExit; the saved frame must not move,
        // and nothing is worth saving while it's pinned.
        store.flushPersistence()
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(NSRect(x: 0, y: 0, width: 2560, height: 1440), display: false)
        XCTAssertEqual(controller.persistableFrame?.rect, normal)
        XCTAssertNil(store.pendingSave, "a resize while fullscreen must not arm a save")

        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        XCTAssertNotNil(store.pendingSave, "leaving fullscreen saves once")
        let moved = normal.offsetBy(dx: 20, dy: 0)
        window.setFrame(moved, display: false)
        XCTAssertEqual(controller.persistableFrame?.rect, moved)
    }

    /// An enter that AppKit aborts sends `didFailToEnterFullScreen`, never
    /// `didExit` — the frame must unpin there or it stays frozen.
    func testFailedFullscreenEntryUnpinsTheFrame() throws {
        let store = makeTestStore()
        let controller = KookyWindowController(windowId: UUID(), store: store)
        defer {
            controller.close()
            store.terminate()
        }
        let window = try XCTUnwrap(controller.window)
        let before = NSRect(x: 50, y: 60, width: 1300, height: 800)
        window.setFrame(before, display: false)
        store.flushPersistence()
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        controller.windowDidFailToEnterFullScreen(window)
        XCTAssertNotNil(store.pendingSave, "the failed attempt saves the frame the window still has")

        let after = before.offsetBy(dx: 0, dy: -30)
        window.setFrame(after, display: false)
        XCTAssertEqual(controller.persistableFrame?.rect, after, "moves after a failed enter must be tracked again")
    }

    /// A frame change arms the store's debounced save; a torn-down store
    /// never re-arms (a late AppKit notification after a red-button close
    /// must not resurrect the slot `removeWindow` dropped).
    func testFrameChangesArmTheDebouncedSaveUnlessTornDown() throws {
        let store = makeTestStore()
        let controller = KookyWindowController(windowId: UUID(), store: store)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        store.flushPersistence()
        XCTAssertNil(store.pendingSave)
        window.setFrame(NSRect(x: 10, y: 10, width: 1200, height: 800), display: false)
        XCTAssertNotNil(store.pendingSave, "a resize must arm the debounced state save")

        store.terminate()
        XCTAssertNil(store.pendingSave)
        store.scheduleSave()
        XCTAssertNil(store.pendingSave, "a torn-down store must never re-arm")
    }
}
