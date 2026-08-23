import AppKit
import SwiftUI

/// Middle-button (button 2) click detector designed to sit in `.overlay()`
/// above SwiftUI content. Its `hitTest` returns `self` only for middle-mouse
/// events, so left clicks/hovers pass through to the SwiftUI gestures behind
/// it. Other "other" mouse events (side buttons 3/4) also pass through.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickView, context: Context) {
        nsView.action = action
    }

    final class MiddleClickView: NSView {
        var action: (() -> Void)?

        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            action?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard
                let current = NSApp.currentEvent,
                current.type == .otherMouseDown || current.type == .otherMouseUp || current.type == .otherMouseDragged,
                current.buttonNumber == 2
            else { return nil }
            return bounds.contains(point) ? self : nil
        }
    }
}
