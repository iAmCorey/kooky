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

    func testTerminalTabHostRetainsVisitedViews() throws {
        let store = makeStore()
        let workspace = try XCTUnwrap(store.active)
        let pane = try XCTUnwrap(workspace.activePane)
        let first = try XCTUnwrap(pane.activeTab)
        let second = store.addTab(in: workspace)
        let host = TerminalTabHostView()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        host.update(pane: pane, grabsFocusOnMount: true)
        XCTAssertTrue(second.engine.view.superview === host)
        XCTAssertNil(first.engine.view.superview, "unvisited tabs stay lazy")

        store.activateTab(first, in: workspace)
        host.update(pane: pane, grabsFocusOnMount: true)
        XCTAssertTrue(first.engine.view.superview === host)
        XCTAssertFalse(first.engine.view.isHidden)
        XCTAssertTrue(second.engine.view.superview === host, "a visited tab stays mounted when it is switched away from")
        XCTAssertTrue(second.engine.view.isHidden)

        store.activateTab(second, in: workspace)
        host.update(pane: pane, grabsFocusOnMount: true)
        XCTAssertTrue(first.engine.view.superview === host)
        XCTAssertTrue(first.engine.view.isHidden)
        XCTAssertFalse(second.engine.view.isHidden)
    }

    func testTerminalTabHostMountsBackgroundSpawningTabs() throws {
        let store = makeStore()
        let workspace = try XCTUnwrap(store.active)
        let pane = try XCTUnwrap(workspace.activePane)
        let visible = try XCTUnwrap(pane.activeTab)
        let background = store.addTab(
            in: workspace,
            activate: false,
            spawnInBackground: true
        )
        let host = TerminalTabHostView()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        host.update(pane: pane, grabsFocusOnMount: true)

        XCTAssertTrue(visible.engine.view.superview === host)
        XCTAssertTrue(
            background.engine.view.superview === host,
            "CLI --no-focus tabs need a hidden mount so their real shell starts"
        )
        XCTAssertTrue(background.engine.view.isHidden)
    }

    /// A tab dragged to another pane: the destination host can hear about it
    /// before the source does, and the source must then leave it alone.
    func testSourcePaneCannotDisturbATabThatMovedToAnotherPane() throws {
        let store = makeStore()
        let workspace = try XCTUnwrap(store.active)
        let a = try XCTUnwrap(workspace.activePane)
        let moving = store.addTab(in: workspace)
        let b = try XCTUnwrap(store.splitPane(a, orientation: .horizontal, in: workspace))
        let hostA = TerminalTabHostView()
        hostA.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let hostB = TerminalTabHostView()
        hostB.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hostA.update(pane: a, grabsFocusOnMount: false)
        hostB.update(pane: b, grabsFocusOnMount: true)
        XCTAssertTrue(moving.engine.view.superview === hostA)

        store.moveTab(moving, to: b, at: b.tabs.count, in: workspace)
        hostB.update(pane: b, grabsFocusOnMount: true)
        XCTAssertTrue(moving.engine.view.superview === hostB)

        hostA.layout()
        XCTAssertEqual(moving.engine.view.frame, hostB.bounds, "the old pane must not size a terminal it no longer owns")
        hostA.update(pane: a, grabsFocusOnMount: false)
        XCTAssertTrue(
            moving.engine.view.superview === hostB,
            "the old pane must not detach a terminal after the new pane adopted it"
        )

        store.moveTab(moving, to: a, at: a.tabs.count, in: workspace)
        hostA.update(pane: a, grabsFocusOnMount: true)
        XCTAssertTrue(moving.engine.view.superview === hostA, "a tab must be able to move back to a pane that held it before")
        XCTAssertEqual(moving.engine.view.frame, hostA.bounds)
    }

    /// Issue #89 at the host level. Restructuring the split tree makes
    /// SwiftUI build a new host for a pane and then call the old one once
    /// more before removing it.
    func testReplacedHostCannotReclaimItsPanesTerminals() throws {
        let store = makeStore()
        let workspace = try XCTUnwrap(store.active)
        let pane = try XCTUnwrap(workspace.activePane)
        let session = try XCTUnwrap(pane.activeTab)
        let old = TerminalTabHostView()
        old.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let new = TerminalTabHostView()
        new.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        old.update(pane: pane, grabsFocusOnMount: false)
        new.update(pane: pane, grabsFocusOnMount: true)
        XCTAssertTrue(session.engine.view.superview === new)

        old.update(pane: pane, grabsFocusOnMount: false)
        XCTAssertTrue(session.engine.view.superview === new, "the host being removed must not take the terminal back")
        XCTAssertEqual(session.engine.view.frame, new.bounds)
        XCTAssertTrue(session.engine.grabsFocusOnMount, "nor rewrite the focus gate the new host set")

        // A tab the old host never mounted — one dragged in by the same
        // change that replaced it. "I held this before" cannot cover it.
        let arrived = store.addTab(in: workspace)
        new.update(pane: pane, grabsFocusOnMount: true)
        old.update(pane: pane, grabsFocusOnMount: false)
        XCTAssertTrue(arrived.engine.view.superview === new)
    }

    // MARK: - Split restructuring (issue #89)

    private func makeWindowedHost(_ store: WorkspaceStore) -> (host: PaneTreeHostView, window: NSWindow) {
        let host = makeHost(store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        return (host, window)
    }

    /// Hosted SwiftUI applies a model change on its own commit; give it one.
    private func settle(_ host: PaneTreeHostView) {
        sync(host)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func assertOnScreen(
        _ session: Session,
        in host: PaneTreeHostView,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let view = session.engine.view
        XCTAssertTrue(view.isDescendant(of: host), message, file: file, line: line)
        XCTAssertTrue(view.window != nil && view.window === host.window, message, file: file, line: line)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, message, file: file, line: line)
        XCTAssertGreaterThan(view.bounds.width, 0, message, file: file, line: line)
        XCTAssertGreaterThan(view.bounds.height, 0, message, file: file, line: line)
    }

    func testClosingOnePaneOfASplitKeepsTheOtherOnScreen() throws {
        for orientation in [SplitOrientation.horizontal, .vertical] {
            for closeOriginal in [false, true] {
                let store = makeStore()
                defer { store.terminate() }
                let workspace = try XCTUnwrap(store.active)
                let original = try XCTUnwrap(workspace.activePane)
                let (host, window) = makeWindowedHost(store)
                defer { window.close() }
                let added = try XCTUnwrap(store.splitPane(original, orientation: orientation, in: workspace))
                settle(host)
                let surviving = try XCTUnwrap((closeOriginal ? added : original).activeTab)
                let closing = try XCTUnwrap((closeOriginal ? original : added).activeTab)
                assertOnScreen(surviving, in: host, "both panes of a fresh split are on screen")

                store.closeTab(closing, in: workspace)
                settle(host)

                assertOnScreen(
                    surviving, in: host,
                    "\(orientation) split, closed the \(closeOriginal ? "original" : "new") pane"
                )
                XCTAssertEqual((surviving.engine as? TestEngine)?.terminateCount, 0)
            }
        }
    }

    /// Three panes, close the first: the inner split is promoted. With both
    /// splits on one axis SwiftUI keeps the first slot's host and hands it
    /// the next pane; across axes everything is rebuilt.
    func testClosingAPaneBesideANestedSplitKeepsBothSurvivorsOnScreen() throws {
        for inner in [SplitOrientation.horizontal, .vertical] {
            let store = makeStore()
            defer { store.terminate() }
            let workspace = try XCTUnwrap(store.active)
            let a = try XCTUnwrap(workspace.activePane)
            let (host, window) = makeWindowedHost(store)
            defer { window.close() }
            let b = try XCTUnwrap(store.splitPane(a, orientation: .horizontal, in: workspace))
            settle(host)
            let c = try XCTUnwrap(store.splitPane(b, orientation: inner, in: workspace))
            settle(host)
            let inB = try XCTUnwrap(b.activeTab)
            let inC = try XCTUnwrap(c.activeTab)

            store.closeTab(try XCTUnwrap(a.activeTab), in: workspace)
            settle(host)

            assertOnScreen(inB, in: host, "inner \(inner) split: first survivor")
            assertOnScreen(inC, in: host, "inner \(inner) split: second survivor")
        }
    }

    /// Dragging a pane's only tab into its neighbour collapses the split and
    /// hands the neighbour a terminal its old host never mounted.
    func testMovingAPanesOnlyTabIntoItsNeighbourKeepsItOnScreen() throws {
        let store = makeStore()
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active)
        let a = try XCTUnwrap(workspace.activePane)
        let (host, window) = makeWindowedHost(store)
        defer { window.close() }
        let b = try XCTUnwrap(store.splitPane(a, orientation: .horizontal, in: workspace))
        settle(host)
        let resident = try XCTUnwrap(a.activeTab)
        let moved = try XCTUnwrap(b.activeTab)

        store.moveTab(moved, to: a, at: a.tabs.count, in: workspace)
        settle(host)
        assertOnScreen(moved, in: host, "the moved tab is now the neighbour's active tab")

        store.activateTab(resident, in: workspace)
        settle(host)
        assertOnScreen(resident, in: host, "the neighbour's own tab still shows when selected")
        store.activateTab(moved, in: workspace)
        settle(host)
        assertOnScreen(moved, in: host, "and the moved tab comes back when reselected")
    }

}
