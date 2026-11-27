import AppKit
import SwiftUI

/// Keeps terminal NSViews mounted after their first visit. SwiftUI's `.id(tab.id)`
/// used to detach and reattach a Metal-backed view on every tab switch; the
/// AppKit reattachment is visible as a several-hundred-millisecond pause even
/// when the Ghostty surface already exists. Unvisited tabs stay lazy: their
/// view is attached only when first selected, preserving restored-tab startup
/// behaviour. CLI `open --no-focus` tabs are the exception: they mount hidden
/// immediately so their shell can start without becoming the active tab.
struct TerminalTabHost: NSViewRepresentable {
    let pane: Pane
    /// The host reads `pane` itself and never these. They are here so this
    /// value changes when the pane's tabs do — that is what makes SwiftUI
    /// call `updateNSView`.
    let tabs: [Session]
    let activeTabId: UUID?
    let grabsFocusOnMount: Bool

    func makeNSView(context: Context) -> TerminalTabHostView {
        let host = TerminalTabHostView()
        host.update(pane: pane, grabsFocusOnMount: grabsFocusOnMount)
        return host
    }

    func updateNSView(_ nsView: TerminalTabHostView, context: Context) {
        nsView.update(pane: pane, grabsFocusOnMount: grabsFocusOnMount)
    }
}

@MainActor
final class TerminalTabHostView: NSView {
    /// Which host renders each pane right now. Restructuring the split tree
    /// (⌘D, a split collapsing) makes SwiftUI build a new host for a pane
    /// that lives on and, in the same commit, call `updateNSView` once more
    /// on the host it is about to remove — after the new one has taken the
    /// terminal. With "last update owns the view" the dying host pulled the
    /// terminal back and took it out of the window with it (#89).
    private static let currentHosts = NSMapTable<Pane, TerminalTabHostView>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .weakMemory
    )

    private weak var pane: Pane?
    private var mountedViews: [UUID: NSView] = [:]

    override func layout() {
        super.layout()
        // A cross-pane/window move reparents the engine view before the old
        // host necessarily receives its model update. Only the current AppKit
        // owner may size it during that handoff.
        for view in mountedViews.values where view.superview === self {
            view.frame = bounds
        }
    }

    func update(pane: Pane, grabsFocusOnMount: Bool) {
        // Taking on a pane makes this host its current one. Per binding, not
        // per host: when a nested split collapses SwiftUI keeps a host and
        // hands it a different pane.
        if self.pane !== pane {
            self.pane = pane
            Self.currentHosts.setObject(self, forKey: pane)
        }
        guard Self.currentHosts.object(forKey: pane) === self else { return }
        // The pane, not a snapshot of it: that last call to a host on its way
        // out can replay the value it held before the model changed, listing
        // a tab that has since moved to another pane.
        let tabs = pane.tabs
        let activeTabId = pane.activeTabId

        let tabIds = Set(tabs.map(\.id))
        for session in tabs where session.id == activeTabId || session.spawnsInBackground {
            let view = session.engine.view
            let isActive = session.id == activeTabId
            // Set mount-time gates before addSubview triggers
            // viewDidMoveToWindow on an already-windowed host.
            session.engine.grabsFocusOnMount = grabsFocusOnMount && isActive
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            view.isHidden = !isActive
            mountedViews[session.id] = view
            if view.superview !== self {
                addSubview(view)
            }
        }

        for session in tabs {
            guard let view = mountedViews[session.id], view.superview === self else { continue }
            session.engine.grabsFocusOnMount = grabsFocusOnMount && session.id == activeTabId
            view.isHidden = session.id != activeTabId
            view.frame = bounds
        }
        if let activeTabId,
           let active = tabs.first(where: { $0.id == activeTabId }),
           active.engine.view.superview === self {
            active.engine.renderNowIfNeeded()
        }

        let removedIds = mountedViews.keys.filter { !tabIds.contains($0) }
        for id in removedIds {
            // addSubview reparents automatically. If a destination host has
            // already adopted this view, the stale source entry must only be
            // forgotten — removing it would detach the destination's terminal.
            if let view = mountedViews[id], view.superview === self {
                view.removeFromSuperview()
            }
            mountedViews[id] = nil
        }
    }
}
