import Foundation

/// Layout direction of a split. `horizontal` puts the two children side-by-side
/// (divider runs vertically). `vertical` stacks them top-to-bottom (divider
/// runs horizontally).
enum SplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

/// Screen direction for keyboard pane navigation (⌥⌘ + arrow) and divider
/// moves (⌃⌘ + arrow).
enum PaneDirection: Int, CaseIterable, Sendable {
    case up, down, left, right

    /// The split whose divider runs across this direction's axis.
    var axis: SplitOrientation {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// Toward a split's first child (left / top) rather than its second.
    var towardFirst: Bool { self == .left || self == .up }
}

/// A node in a workspace's split tree. Either wraps a `Pane` (a leaf region
/// with its own tab strip) or holds two child `PaneNode`s separated by a
/// divider at `fraction` (0..1 — first child's share of the available axis).
@MainActor
@Observable
final class PaneNode: Identifiable {
    let id: UUID
    var content: PaneContent
    /// Usable length along this split's axis as last rendered by
    /// `SplitContainer`, so a keyboard divider move can step in points and
    /// clamp exactly like a drag. Runtime-only; 0 until the split lays out.
    @ObservationIgnored var renderedUsableLength: CGFloat = 0

    init(id: UUID = UUID(), content: PaneContent) {
        self.id = id
        self.content = content
    }

    convenience init(pane: Pane) {
        self.init(id: pane.id, content: .pane(pane))
    }
}

enum PaneContent {
    case pane(Pane)
    indirect case split(orientation: SplitOrientation, first: PaneNode, second: PaneNode, fraction: Double)
}

extension PaneNode {
    /// DFS list of leaf panes in display order.
    var allPanes: [Pane] {
        var out: [Pane] = []
        collectPanes(into: &out)
        return out
    }

    /// Every tab's engine under this node — the set a size-propagation
    /// suspension must cover (background tabs share the pane's NSView
    /// geometry). Single spelling for the five suspend owners.
    var allEngines: [any TerminalEngine] {
        allPanes.flatMap { $0.tabs.map(\.engine) }
    }

    private func collectPanes(into out: inout [Pane]) {
        switch content {
        case .pane(let p): out.append(p)
        case .split(_, let a, let b, _):
            a.collectPanes(into: &out)
            b.collectPanes(into: &out)
        }
    }

    var firstPane: Pane? {
        switch content {
        case .pane(let p): return p
        case .split(_, let a, _, _): return a.firstPane
        }
    }

    /// Short-circuiting lookup. Prefer this to `allPanes.first(where:)` —
    /// avoids walking the whole tree when the match is found early.
    func pane(id: UUID) -> Pane? {
        switch content {
        case .pane(let p):
            return p.id == id ? p : nil
        case .split(_, let a, let b, _):
            return a.pane(id: id) ?? b.pane(id: id)
        }
    }

    /// Subtree membership — same short-circuit walk as `pane(id:)`, just
    /// without resurfacing the leaf when callers only need the boolean.
    func contains(paneId: UUID) -> Bool { pane(id: paneId) != nil }

    /// True when this subtree contains more than one leaf pane (i.e. it
    /// has any split node). O(1) vs `allPanes.count > 1`'s O(n) array
    /// allocation — used in hot-path render code that asks "is zoom
    /// meaningful here?" on every status-bar layout.
    var hasMultiplePanes: Bool {
        switch content {
        case .pane: return false
        case .split: return true
        }
    }

    func paneNode(paneId: UUID) -> PaneNode? {
        switch content {
        case .pane(let p):
            return p.id == paneId ? self : nil
        case .split(_, let a, let b, _):
            return a.paneNode(paneId: paneId) ?? b.paneNode(paneId: paneId)
        }
    }

    /// Pane that contains the given session, or nil.
    func pane(containingSessionId sessionId: UUID) -> Pane? {
        switch content {
        case .pane(let p):
            return p.tabs.contains(where: { $0.id == sessionId }) ? p : nil
        case .split(_, let a, let b, _):
            return a.pane(containingSessionId: sessionId) ?? b.pane(containingSessionId: sessionId)
        }
    }

    /// For a leaf with the given pane id, returns the parent split node, the
    /// leaf node itself, and its sibling. nil if the leaf is the root or is
    /// not in this subtree.
    func parentInfo(forPane paneId: UUID) -> (parent: PaneNode, leaf: PaneNode, sibling: PaneNode)? {
        guard case .split(_, let first, let second, _) = content else { return nil }
        if case .pane(let p) = first.content, p.id == paneId {
            return (self, first, second)
        }
        if case .pane(let p) = second.content, p.id == paneId {
            return (self, second, first)
        }
        return first.parentInfo(forPane: paneId) ?? second.parentInfo(forPane: paneId)
    }

    /// Rewrite this split's divider. False for a leaf or an unchanged value.
    @discardableResult
    func setFraction(_ fraction: Double) -> Bool {
        guard case .split(let orientation, let first, let second, let current) = content,
              abs(current - fraction) > .ulpOfOne
        else { return false }
        content = .split(orientation: orientation, first: first, second: second, fraction: fraction)
        return true
    }

    /// The innermost split on `orientation`'s axis that contains the pane —
    /// the divider a ⌃⌘ + arrow press moves.
    func nearestSplit(containingPane paneId: UUID, orientation: SplitOrientation) -> PaneNode? {
        guard case .split(let own, let first, let second, _) = content,
              let child = [first, second].first(where: { $0.contains(paneId: paneId) })
        else { return nil }
        return child.nearestSplit(containingPane: paneId, orientation: orientation)
            ?? (own == orientation ? self : nil)
    }

    /// Each leaf's rect in a unit square (origin top-left), in tree order, laid
    /// out as on screen: a narrow window clamps a split to keep its panes
    /// usable, which can change which pane sits above which — so each split
    /// applies the renderer's clamp to its last rendered length (stored
    /// fraction before first layout).
    func paneFrames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(pane: Pane, frame: CGRect)] {
        switch content {
        case .pane(let p):
            return [(p, rect)]
        case .split(let orientation, let first, let second, let stored):
            let fraction = renderedUsableLength > 0
                ? KookyWindowLayout.clampedSplitFraction(
                    stored, orientation: orientation, first: first, second: second,
                    usableLength: renderedUsableLength
                )
                : stored
            let (a, b) = orientation == .horizontal
                ? rect.divided(atDistance: rect.width * fraction, from: .minXEdge)
                : rect.divided(atDistance: rect.height * fraction, from: .minYEdge)
            return first.paneFrames(in: a) + second.paneFrames(in: b)
        }
    }

    /// The pane ⌥⌘ + arrow moves to: among panes wholly past the current
    /// pane's edge in `direction` that share some of its span on the other
    /// axis, the nearest — then the one sharing the most, then tree order.
    /// nil at the edge; like Ghostty / Warp / cmux it doesn't wrap.
    func neighbor(of paneId: UUID, toward direction: PaneDirection) -> Pane? {
        let frames = paneFrames()
        guard let from = frames.first(where: { $0.pane.id == paneId })?.frame else { return nil }
        let epsilon: CGFloat = 1e-9
        var best: (pane: Pane, gap: CGFloat, shared: CGFloat)?
        for (pane, frame) in frames where pane.id != paneId {
            let gap: CGFloat
            let shared: CGFloat
            switch direction {
            case .left:  gap = from.minX - frame.maxX
            case .right: gap = frame.minX - from.maxX
            case .up:    gap = from.minY - frame.maxY
            case .down:  gap = frame.minY - from.maxY
            }
            switch direction.axis {
            case .horizontal: shared = min(from.maxY, frame.maxY) - max(from.minY, frame.minY)
            case .vertical:   shared = min(from.maxX, frame.maxX) - max(from.minX, frame.minX)
            }
            guard gap > -epsilon, shared > epsilon else { continue }
            if let current = best {
                let closer = gap < current.gap - epsilon
                let tiedButWider = abs(gap - current.gap) <= epsilon && shared > current.shared + epsilon
                guard closer || tiedButWider else { continue }
            }
            best = (pane, gap, shared)
        }
        return best?.pane
    }
}
