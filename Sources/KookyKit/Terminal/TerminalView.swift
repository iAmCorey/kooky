import AppKit
import SwiftUI

/// Keeps terminal NSViews mounted after their first visit. SwiftUI's `.id(tab.id)`
/// used to detach and reattach a Metal-backed view on every tab switch; the
/// AppKit reattachment is visible as a several-hundred-millisecond pause even
/// when the Ghostty surface already exists. Unvisited tabs stay lazy: their
/// view is attached only when first selected, preserving restored-tab startup
/// behaviour.
struct TerminalTabHost: NSViewRepresentable {
    let tabs: [Session]
    let activeTabId: UUID?
    let grabsFocusOnMount: Bool

    func makeNSView(context: Context) -> TerminalTabHostView {
        let host = TerminalTabHostView()
        host.update(tabs: tabs, activeTabId: activeTabId, grabsFocusOnMount: grabsFocusOnMount)
        return host
    }

    func updateNSView(_ nsView: TerminalTabHostView, context: Context) {
        nsView.update(tabs: tabs, activeTabId: activeTabId, grabsFocusOnMount: grabsFocusOnMount)
    }
}

@MainActor
final class TerminalTabHostView: NSView {
    private var mountedViews: [UUID: NSView] = [:]

    override func layout() {
        super.layout()
        for view in mountedViews.values { view.frame = bounds }
    }

    func update(tabs: [Session], activeTabId: UUID?, grabsFocusOnMount: Bool) {
        let tabIds = Set(tabs.map(\.id))
        for session in tabs where session.id == activeTabId {
            let view = session.engine.view
            if mountedViews[session.id] == nil {
                mountedViews[session.id] = view
                view.autoresizingMask = [.width, .height]
                view.frame = bounds
                addSubview(view)
            }
        }

        for session in tabs {
            guard let view = mountedViews[session.id] else { continue }
            session.engine.grabsFocusOnMount = grabsFocusOnMount && session.id == activeTabId
            view.isHidden = session.id != activeTabId
            view.frame = bounds
        }
        if let activeTabId, let active = tabs.first(where: { $0.id == activeTabId }) {
            active.engine.renderNowIfNeeded()
        }

        let removedIds = mountedViews.keys.filter { !tabIds.contains($0) }
        for id in removedIds {
            mountedViews[id]?.removeFromSuperview()
            mountedViews[id] = nil
        }
    }
}
