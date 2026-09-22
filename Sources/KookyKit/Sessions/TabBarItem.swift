import SwiftUI

struct TabBarItem: View {
    @Bindable var tab: Session
    let isActive: Bool
    let canCloseToRight: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let onDuplicate: () -> Void
    let onRename: (String) -> Void
    let onSplit: (SplitOrientation) -> Void
    let onMoveToNewWindow: () -> Void

    @State private var isHovered = false
    @State private var isContextMenuOpen = false
    @State private var isRenameOpen = false
    @State private var pendingRename = ""

    var body: some View {
        HStack(spacing: 7) {
            commandStatusDot
            AgentIconView(asset: tab.displayAgent.iconAsset, fallbackSymbol: tab.displayAgent.symbol, size: 15)
            Text(tab.title)
                .font(Theme.display(12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
            HoverableIconButton(
                systemName: "xmark",
                fontSize: 9,
                size: 16,
                help: "Close tab",
                action: onClose
            )
            .opacity(isHovered || isActive ? 1 : 0)
            .allowsHitTesting(isHovered || isActive)
        }
        .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeForeground.opacity(0.62))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: CGFloat(KookySettingsModel.shared.tabMaxWidth), alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        // Selection is a discrete navigation state, not a layout transition.
        // Animating it delays the visual handoff while the terminal surface is
        // already being switched underneath.
        .transaction { transaction in
            if isActive { transaction.animation = nil }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .overlay(RightClickCatcher { _ in isContextMenuOpen = true })
        .overlay(MiddleClickCatcher { onClose() })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                KookyMenuRow(title: "Close Tab", shortcut: "⌘W") {
                    isContextMenuOpen = false
                    onClose()
                }
                KookyMenuRow(title: "Close Other Tabs") {
                    isContextMenuOpen = false
                    onCloseOthers()
                }
                KookyMenuRow(title: "Close Tabs to the Right", isDisabled: !canCloseToRight) {
                    isContextMenuOpen = false
                    onCloseToRight()
                }
                KookyMenuDivider()
                KookyMenuRow(title: "Split Right", shortcut: "⌘D") {
                    isContextMenuOpen = false
                    onSplit(.horizontal)
                }
                KookyMenuRow(title: "Split Down", shortcut: "⌘⇧D") {
                    isContextMenuOpen = false
                    onSplit(.vertical)
                }
                KookyMenuRow(title: "Move to New Window") {
                    isContextMenuOpen = false
                    onMoveToNewWindow()
                }
                KookyMenuDivider()
                KookyMenuRow(title: "Rename Tab…", shortcut: "⌘R") {
                    isContextMenuOpen = false
                    beginRename(deferred: true)
                }
                KookyMenuRow(title: "Duplicate Tab") {
                    isContextMenuOpen = false
                    onDuplicate()
                }
                KookyMenuDivider()
                RevealInFinderMenuRow(url: tab.currentDirectory) { isContextMenuOpen = false }
            }
            .padding(Theme.space1)
            .frame(minWidth: 240)
            .background(Theme.chromeBackground)
        }
        .popover(isPresented: $isRenameOpen, arrowEdge: .bottom) {
            KookyRenameField(placeholder: "Tab title", text: $pendingRename) {
                onRename(pendingRename)
                isRenameOpen = false
            }
        }
        .onChange(of: tab.renameRequested) { _, requested in
            // ⌘R routes here via `Session.renameRequested`. Consume the flag
            // so the next ⌘R re-fires.
            guard requested else { return }
            tab.renameRequested = false
            beginRename(deferred: false)
        }
    }

    /// Seed the edit field from the current title and open the rename popover.
    /// `deferred` waits one runloop tick — needed from the context menu, where
    /// that popover is mid-dismiss and back-to-back popovers off the same
    /// anchor glitch; the ⌘R path opens synchronously. Skips when already open
    /// so a re-trigger mid-edit can't wipe what the user is typing.
    private func beginRename(deferred: Bool) {
        guard !isRenameOpen else { return }
        pendingRename = tab.customTitle ?? tab.title
        if deferred {
            DispatchQueue.main.async { isRenameOpen = true }
        } else {
            isRenameOpen = true
        }
    }

    private var rowBackground: Color {
        if isActive { return Theme.chromeSelection }
        if isHovered { return Theme.chromeHover }
        return .clear
    }

    /// Shows only on non-zero exit. Successful runs intentionally leave the
    /// row clean — a green dot on every command would dominate the chrome.
    @ViewBuilder
    private var commandStatusDot: some View {
        if let exit = tab.lastCommandExit, exit != 0 {
            Circle()
                .fill(Theme.activityFailure)
                .frame(width: 5, height: 5)
                .help(Self.statusTooltip(exit: exit, duration: tab.lastCommandDuration))
        }
    }

    private static func statusTooltip(exit: Int, duration: TimeInterval?) -> String {
        guard let duration else {
            return String.localizedStringWithFormat(
                String(localized: "exit %d", bundle: .kookyResources),
                exit
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "exit %d · %@", bundle: .kookyResources),
            exit,
            formatDuration(duration)
        )
    }

    /// Internal: the Session Info inspector renders the same OSC 133;D
    /// duration — one formatter, or the tab tooltip and the inspector drift
    /// on the next tier tweak. (`ToolCallActivityPill.formatElapsed` stays a
    /// deliberately distinct style — see M5.bbbb.)
    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds / 60)
        let rem = Int(seconds.truncatingRemainder(dividingBy: 60).rounded())
        return "\(minutes)m \(rem)s"
    }
}
