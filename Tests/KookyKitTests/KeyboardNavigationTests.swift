import XCTest
@testable import KookyKit

/// ⌃⌘[ / ⌃⌘] workspace cycling, ⌥⌘ + arrow pane focus, ⌃⌘ + arrow divider moves.
@MainActor
final class KeyboardNavigationTests: XCTestCase {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())

    // MARK: - Workspaces

    func testCycleWorkspaceWrapsForward() {
        let store = makeTestStore()
        let first = store.workspaces[0]
        let second = store.addWorkspace(workingDirectory: dir)
        let third = store.addWorkspace(workingDirectory: dir)
        XCTAssertEqual(store.activeWorkspaceId, third.id)

        store.cycleWorkspace(direction: 1)
        XCTAssertEqual(store.activeWorkspaceId, first.id, "next from the last wraps to the first")
        store.cycleWorkspace(direction: 1)
        XCTAssertEqual(store.activeWorkspaceId, second.id)
    }

    func testCycleWorkspaceWrapsBackward() {
        let store = makeTestStore()
        let first = store.workspaces[0]
        let second = store.addWorkspace(workingDirectory: dir)
        store.activateWorkspace(first)

        store.cycleWorkspace(direction: -1)
        XCTAssertEqual(store.activeWorkspaceId, second.id, "previous from the first wraps to the last")
    }

    func testCycleWorkspaceWithOneWorkspaceIsNoOp() {
        let store = makeTestStore()
        let only = store.workspaces[0]
        store.cycleWorkspace(direction: 1)
        XCTAssertEqual(store.activeWorkspaceId, only.id)
    }

    // MARK: - Layout fixtures

    /// `A | (B over C)`.
    private func sideBySideWithStackedRight(_ store: WorkspaceStore) -> (Workspace, Pane, Pane, Pane) {
        let ws = store.workspaces[0]
        let a = ws.root.firstPane!
        let b = store.splitPane(a, orientation: .horizontal, in: ws)!
        let c = store.splitPane(b, orientation: .vertical, in: ws)!
        return (ws, a, b, c)
    }

    /// `(A | B) over C`, top divider at `topFraction`.
    private func splitTopOverWide(_ store: WorkspaceStore, topFraction: Double) -> (Workspace, Pane, Pane, Pane) {
        let ws = store.workspaces[0]
        let a = ws.root.firstPane!
        let c = store.splitPane(a, orientation: .vertical, in: ws)!
        let b = store.splitPane(a, orientation: .horizontal, in: ws)!
        ws.root.parentInfo(forPane: a.id)!.parent.setFraction(topFraction)
        return (ws, a, b, c)
    }

    /// Split `a | b` with both rendered `usable` points wide.
    private func sideBySide(_ store: WorkspaceStore, usable: CGFloat = 1000) -> (Workspace, Pane, Pane) {
        let ws = store.workspaces[0]
        let a = ws.root.firstPane!
        let b = store.splitPane(a, orientation: .horizontal, in: ws)!
        ws.root.renderedUsableLength = usable
        return (ws, a, b)
    }

    private var oneStep: Double { Double(WorkspaceStore.dividerKeyboardStep / 1000) }

    private func fraction(_ node: PaneNode) -> Double? {
        guard case .split(_, _, _, let f) = node.content else { return nil }
        return f
    }

    // MARK: - Pane frames

    func testPaneFramesFollowStoredFractions() {
        let store = makeTestStore()
        let (ws, a, b, c) = splitTopOverWide(store, topFraction: 0.3)
        let frames = Dictionary(uniqueKeysWithValues: ws.root.paneFrames().map { ($0.pane.id, $0.frame) })
        assertFrame(frames[a.id], CGRect(x: 0, y: 0, width: 0.3, height: 0.5))
        assertFrame(frames[b.id], CGRect(x: 0.3, y: 0, width: 0.7, height: 0.5))
        assertFrame(frames[c.id], CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    private func assertFrame(_ actual: CGRect?, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("missing frame", file: file, line: line) }
        for (got, want) in [(actual.minX, expected.minX), (actual.minY, expected.minY),
                            (actual.width, expected.width), (actual.height, expected.height)] {
            XCTAssertEqual(got, want, accuracy: 1e-9, file: file, line: line)
        }
    }

    // MARK: - Directional focus

    func testFocusMovesToAdjacentPane() {
        let store = makeTestStore()
        let (ws, a, b, c) = sideBySideWithStackedRight(store)

        store.focusPane(toward: .left, in: ws)  // from C (just created)
        XCTAssertEqual(ws.activePaneId, a.id)
        store.focusPane(toward: .right, in: ws)
        XCTAssertEqual(ws.activePaneId, b.id, "two equal candidates: tree order wins")
        store.focusPane(toward: .down, in: ws)
        XCTAssertEqual(ws.activePaneId, c.id)
        store.focusPane(toward: .up, in: ws)
        XCTAssertEqual(ws.activePaneId, b.id)
    }

    func testFocusAtEdgeDoesNotWrap() {
        let store = makeTestStore()
        let (ws, a, _, _) = sideBySideWithStackedRight(store)
        store.focusPane(a, in: ws)

        store.focusPane(toward: .left, in: ws)
        store.focusPane(toward: .up, in: ws)
        store.focusPane(toward: .down, in: ws)
        XCTAssertEqual(ws.activePaneId, a.id)
    }

    func testFocusPrefersThePaneSharingMoreOfTheEdge() {
        let store = makeTestStore()
        let (ws, a, b, c) = splitTopOverWide(store, topFraction: 0.3)
        store.focusPane(c, in: ws)

        store.focusPane(toward: .up, in: ws)
        XCTAssertEqual(ws.activePaneId, b.id, "B spans 70% of C's top edge, A only 30%")
        store.focusPane(toward: .left, in: ws)
        XCTAssertEqual(ws.activePaneId, a.id)
        store.focusPane(toward: .down, in: ws)
        XCTAssertEqual(ws.activePaneId, c.id)
    }

    func testFocusFollowsTheClampedLayoutOnScreen() {
        // (A | B) over (C | D), dividers stored at 0.2 and 0.45. At 400pt
        // both rows must give each pane 200pt, so on screen A sits squarely
        // above C — the stored fractions alone would pick B.
        let store = makeTestStore()
        let ws = store.workspaces[0]
        let a = ws.root.firstPane!
        let c = store.splitPane(a, orientation: .vertical, in: ws)!
        store.splitPane(a, orientation: .horizontal, in: ws)
        store.splitPane(c, orientation: .horizontal, in: ws)
        for (pane, stored) in [(a, 0.2), (c, 0.45)] {
            let row = ws.root.parentInfo(forPane: pane.id)!.parent
            row.setFraction(stored)
            row.renderedUsableLength = 2 * KookyWindowLayout.minimumTerminalWidth
        }
        store.focusPane(c, in: ws)

        store.focusPane(toward: .up, in: ws)
        XCTAssertEqual(ws.activePaneId, a.id)
    }

    // MARK: - Divider moves

    func testDividerMovesInPointSteps() {
        let store = makeTestStore()
        let (ws, a, _) = sideBySide(store)
        store.focusPane(a, in: ws)

        store.moveDivider(toward: .right, in: ws)
        XCTAssertEqual(fraction(ws.root) ?? 0, 0.5 + oneStep, accuracy: 1e-9)
        store.moveDivider(toward: .left, in: ws)
        store.moveDivider(toward: .left, in: ws)
        XCTAssertEqual(fraction(ws.root) ?? 0, 0.5 - oneStep, accuracy: 1e-9)
    }

    func testDividerStopsAtTheMinimumPaneWidth() {
        let store = makeTestStore()
        let (ws, _, b) = sideBySide(store)
        let limit = 1 - Double(KookyWindowLayout.minimumTerminalWidth / 1000)
        ws.root.setFraction(limit)
        store.focusPane(b, in: ws)

        store.moveDivider(toward: .right, in: ws)
        XCTAssertEqual(fraction(ws.root), limit)
        XCTAssertFalse(
            ws.root.allEngines.contains { $0.suspendsSizePropagation },
            "a press that moves nothing must not suspend resizing"
        )
    }

    func testDividerMoveTargetsTheSplitOnThatAxis() {
        let store = makeTestStore()
        let (ws, _, _, c) = sideBySideWithStackedRight(store)
        store.focusPane(c, in: ws)
        let stack = ws.root.parentInfo(forPane: c.id)!.parent
        stack.renderedUsableLength = 1000
        ws.root.renderedUsableLength = 1000
        let rootBefore = fraction(ws.root)

        store.moveDivider(toward: .up, in: ws)
        XCTAssertEqual(fraction(stack) ?? 0, 0.5 - oneStep, accuracy: 1e-9)
        XCTAssertEqual(fraction(ws.root), rootBefore, "the side-by-side root is a different axis")

        store.moveDivider(toward: .left, in: ws)
        XCTAssertNotEqual(fraction(ws.root), rootBefore)
    }

    func testDividerMoveTargetsInnermostOfNestedSameAxisSplits() {
        // A | (B | C): from C, ← moves the B|C divider, not A's.
        let store = makeTestStore()
        let ws = store.workspaces[0]
        let a = ws.root.firstPane!
        let b = store.splitPane(a, orientation: .horizontal, in: ws)!
        let c = store.splitPane(b, orientation: .horizontal, in: ws)!
        store.focusPane(c, in: ws)
        let inner = ws.root.parentInfo(forPane: c.id)!.parent
        XCTAssertFalse(inner === ws.root)
        inner.renderedUsableLength = 1000
        ws.root.renderedUsableLength = 1000
        let rootBefore = fraction(ws.root)
        let innerBefore = fraction(inner)

        store.moveDivider(toward: .left, in: ws)
        XCTAssertEqual(fraction(ws.root), rootBefore)
        XCTAssertNotEqual(fraction(inner), innerBefore)
    }

    func testDividerMoveWithNoSplitOnThatAxisIsNoOp() {
        let store = makeTestStore()
        let (ws, _, _) = sideBySide(store)
        let before = fraction(ws.root)

        store.moveDivider(toward: .up, in: ws)
        store.moveDivider(toward: .down, in: ws)
        XCTAssertEqual(fraction(ws.root), before)
    }

    func testDividerMoveBeforeLayoutIsNoOp() {
        let store = makeTestStore()
        let (ws, _, _) = sideBySide(store, usable: 0)
        let before = fraction(ws.root)

        store.moveDivider(toward: .right, in: ws)
        XCTAssertEqual(fraction(ws.root), before)
    }

    func testDividerMoveSuspendsResizingForHeldKeys() {
        let store = makeTestStore()
        let (ws, _, _) = sideBySide(store)

        store.moveDivider(toward: .right, in: ws)
        XCTAssertTrue(
            ws.root.allEngines.allSatisfy { $0.suspendsSizePropagation },
            "auto-repeat must not SIGWINCH per press"
        )
    }

    func testDividerMoveWhileZoomedIsNoOp() {
        let store = makeTestStore()
        let (ws, a, _) = sideBySide(store)
        store.toggleZoom(in: ws, paneId: a.id)
        let before = fraction(ws.root)

        store.moveDivider(toward: .right, in: ws)
        XCTAssertEqual(fraction(ws.root), before)
    }
}
