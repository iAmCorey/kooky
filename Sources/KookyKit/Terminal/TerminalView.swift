import AppKit
import SwiftUI

struct TerminalView: NSViewRepresentable {
    let engine: any TerminalEngine
    /// Whether this pane is the workspace's active one. Set on the engine
    /// before the view mounts (`makeNSView` runs before `viewDidMoveToWindow`)
    /// so a workspace switch only re-focuses the active pane (issue #24).
    var grabsFocusOnMount = true
    /// False for the offscreen background-spawn mounts (issue #59): the
    /// engine view is hidden via REAL `isHidden` — not opacity — because
    /// `viewDidHide` is what parks the render link, so a streaming hidden
    /// terminal draws nothing.
    var visible = true

    func makeNSView(context: Context) -> NSView {
        engine.grabsFocusOnMount = grabsFocusOnMount
        engine.view.isHidden = !visible
        return engine.view
    }

    // Also on update, not just mount: clicking a sibling pane flips `isFocused`
    // in place (no re-mount → no `makeNSView`), so this keeps the engine flag in
    // sync with the pane's active state for the next re-mount.
    func updateNSView(_ nsView: NSView, context: Context) {
        engine.grabsFocusOnMount = grabsFocusOnMount
        nsView.isHidden = !visible
    }
}
