import AppKit
import XCTest

@testable import KookyKit

/// Invariants of the AppKit workspace-persistence shell (`PaneTreeHostView`,
/// the C2 hybrid): one container per workspace, alive for the workspace's
/// lifetime; switching flips visibility only. These are the guarantees the
/// old `.id(workspace.id)` SwiftUI tree could not make (mount churn → issues
/// #8 / #24) — pin them at the boundary that now owns them.
///
/// CAVEAT — these tests cannot pin display-cycle layout timing (issue #52):
/// in the xctest process, mounting a container's NSHostingView marks the
/// host needsLayout, so a fresh container gets laid out even when reconcile
/// forgets to request it; in the real app `addSubview` dirties nothing and
/// the container stays at .zero (blank workspace). A run-loop-driven,
/// windowed variant of the frame assertion was written and mutation-tested:
/// it stays green with the fix removed, so it was deleted rather than kept
/// as false safety. The mechanism is pinned by a standalone AppKit repro +
/// on-device verification instead.
@MainActor
final class PaneTreeHostTests: XCTestCase {
    private func makeStore() -> WorkspaceStore { makeTestStore() }

    /// Store + host sized like a real window, reconciled and laid out.
    private func makeHost(_ store: WorkspaceStore, size: NSSize = NSSize(width: 800, height: 600)) -> PaneTreeHostView {
        let host = PaneTreeHostView(store: store)
        host.frame = NSRect(origin: .zero, size: size)
        host.renderNow()
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func sync(_ host: PaneTreeHostView) {
        host.renderNow()
        host.layoutSubtreeIfNeeded()
    }

    func testWorkspaceContainerIdentityPersistsAcrossSwitches() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.active)
        let host = makeHost(store)
        store.addWorkspace()
        let second = try XCTUnwrap(store.active)
        XCTAssertNotEqual(first.id, second.id)
        sync(host)

        let firstView = try XCTUnwrap(host.workspaceRootView(for: first.id))
        let secondView = try XCTUnwrap(host.workspaceRootView(for: second.id))
        XCTAssertTrue(firstView.isHidden)
        XCTAssertFalse(secondView.isHidden)

        store.activateWorkspace(first)
        sync(host)

        // THE invariant: switching re-uses the same container instances —
        // nothing is torn down or re-created, visibility flips.
        XCTAssertTrue(host.workspaceRootView(for: first.id) === firstView)
        XCTAssertTrue(host.workspaceRootView(for: second.id) === secondView)
        XCTAssertFalse(firstView.isHidden)
        XCTAssertTrue(secondView.isHidden)
        XCTAssertNotNil(firstView.superview)
        XCTAssertNotNil(secondView.superview)
    }

    func testActiveContainerTracksHostBoundsHiddenStaysStale() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.active)
        let host = makeHost(store)
        store.addWorkspace()
        let second = try XCTUnwrap(store.active)
        sync(host)

        let firstView = try XCTUnwrap(host.workspaceRootView(for: first.id))
        let secondView = try XCTUnwrap(host.workspaceRootView(for: second.id))
        XCTAssertEqual(secondView.frame, host.bounds)

        // Resize while `first` is hidden: only the active container follows —
        // a hidden workspace's engines must not hear about window resizes.
        let staleFrame = firstView.frame
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(secondView.frame, host.bounds)
        XCTAssertEqual(firstView.frame, staleFrame)

        // Activation re-syncs the stale frame before reveal.
        store.activateWorkspace(first)
        sync(host)
        XCTAssertEqual(firstView.frame, host.bounds)
    }

    func testClosingWorkspaceRemovesItsContainer() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.active)
        let host = makeHost(store)
        store.addWorkspace()
        let second = try XCTUnwrap(store.active)
        sync(host)
        XCTAssertNotNil(host.workspaceRootView(for: second.id))

        store.closeWorkspace(second)
        sync(host)
        XCTAssertNil(host.workspaceRootView(for: second.id))
        XCTAssertNotNil(host.workspaceRootView(for: first.id))
    }

    func testWorkspaceSwitchFocusesTerminalButYieldsToOpenComposer() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.active)
        let host = PaneTreeHostView(store: store)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        store.addWorkspace()
        let b = try XCTUnwrap(store.active)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(host)
        sync(host)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // Positive control: switching hands the keyboard to the revealed
        // workspace's terminal (syncFocus — nothing re-mounts on a switch).
        store.activateWorkspace(a)
        sync(host)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let aTerminal = try XCTUnwrap(a.activeSession?.engine.view)
        XCTAssertTrue(window.firstResponder === aTerminal)

        // Open the composer on A, leave, come back: syncFocus must YIELD —
        // the caret belongs to the still-open editor, not the shell under it
        // (Codex P1). The composer re-claims via its workspace-return token.
        a.activeSession?.composerActive = true
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        store.activateWorkspace(b)
        sync(host)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        store.activateWorkspace(a)
        sync(host)
        XCTAssertFalse(
            window.firstResponder === aTerminal,
            "syncFocus must not hand the keyboard to the terminal while its composer is open"
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertTrue(
            window.firstResponder is NSTextView,
            "the surviving composer should re-claim the caret on workspace return"
        )
    }

    func testHostedSplitTreeMountsEngineViewsInsideContainer() throws {
        let store = makeStore()
        let workspace = try XCTUnwrap(store.active)
        let host = makeHost(store)
        // Hosted SwiftUI needs a window + a run-loop turn to mount
        // representables (the terminal views).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(host)
        sync(host)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let container = try XCTUnwrap(host.workspaceRootView(for: workspace.id))
        let engineView = try XCTUnwrap(workspace.activeSession?.engine.view)
        XCTAssertTrue(
            engineView.isDescendant(of: container),
            "the SwiftUI split tree should mount the terminal view inside the workspace's persistent container"
        )
    }
}
