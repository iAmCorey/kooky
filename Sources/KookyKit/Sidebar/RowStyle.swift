import AppKit
import SwiftUI

/// Shared row background palette for sidebar / tab / popover-menu rows.
/// Reads the theme-derived tokens so light themes get a visible (ink-based)
/// fill — the old hardcoded `Color.white` alphas were invisible on light
/// chrome and matched nothing else after v0.26.2 moved every active/hover
/// surface onto `Theme.chromeActive`/`chromeHover`.
extension View {
    func hoverableRowBackground(isActive: Bool = false, isHovered: Bool) -> some View {
        let color: Color
        if isActive {
            color = Theme.chromeActive
        } else if isHovered {
            color = Theme.chromeHover
        } else {
            color = .clear
        }
        return background(color)
    }

    /// Menu rows are single-state: hover === selected, so they use the active
    /// theme token instead of the quieter row-hover token.
    func menuRowHover(_ isHovered: Bool) -> some View {
        background(isHovered ? Theme.chromeActive : Color.clear)
    }

    /// Balanced AppKit cursor ownership for SwiftUI hover regions. A view can
    /// disappear while still hovered (closing a popover, deleting a row), in
    /// which case `onHover(false)` is not guaranteed; `onDisappear` releases
    /// the matching push so the process-wide NSCursor stack cannot leak.
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
}

private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isPushed else { return }
                if hovering {
                    cursor.push()
                    isPushed = true
                } else {
                    popIfNeeded()
                }
            }
            .onDisappear(perform: popIfNeeded)
    }

    private func popIfNeeded() {
        guard isPushed else { return }
        NSCursor.pop()
        isPushed = false
    }
}

/// One row in a kooky popover menu — tab right-click, "+" agent menu, etc.
/// Shares hover treatment + typography with the rest of the chrome.
/// Optional `shortcut` renders right-aligned in the same monospace style
/// AppKit uses for native NSMenuItem key equivalents (e.g. "⌘W", "⌘⇧D").
struct KookyMenuRow<Leading: View>: View {
    let title: String
    let localizesTitle: Bool
    let shortcut: String?
    let isDisabled: Bool
    /// nil = the standard foreground. Set for rows whose next click is
    /// destructive (an armed "Confirm Kill") so the state change is visible
    /// before the damage, not after.
    let titleColor: Color?
    let leading: Leading
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        localizesTitle: Bool = true,
        shortcut: String? = nil,
        isDisabled: Bool = false,
        titleColor: Color? = nil,
        @ViewBuilder leading: () -> Leading,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.localizesTitle = localizesTitle
        self.shortcut = shortcut
        self.isDisabled = isDisabled
        self.titleColor = titleColor
        self.leading = leading()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.space2) {
                leading
                Group {
                    if localizesTitle {
                        Text(LocalizedStringKey(title), bundle: .kookyResources)
                    } else {
                        Text(verbatim: title)
                    }
                }
                    .font(Theme.display(12.5, weight: .regular))
                    .foregroundStyle(isDisabled ? Theme.chromeMuted : (titleColor ?? Theme.chromeForeground))
                Spacer(minLength: 0)
                if let shortcut {
                    // System font (SF Pro) — the ⌘⇧⌥⌃ glyphs are designed for
                    // it; in JetBrains Mono they render heavier and off-baseline,
                    // which looks alien next to the row title.
                    Text(shortcut)
                        .font(.system(size: 11.5, weight: .regular))
                        .tracking(0.5)
                        .foregroundStyle(isDisabled ? Theme.chromeMuted.opacity(0.6) : Theme.chromeMuted)
                        .padding(.leading, Theme.space2)
                }
            }
            .padding(.horizontal, Theme.space2 + 2)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuRowHover(isHovered && !isDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 && !isDisabled }
    }
}

extension KookyMenuRow where Leading == EmptyView {
    init(
        title: String,
        localizesTitle: Bool = true,
        shortcut: String? = nil,
        isDisabled: Bool = false,
        titleColor: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            localizesTitle: localizesTitle,
            shortcut: shortcut,
            isDisabled: isDisabled,
            titleColor: titleColor,
            leading: { EmptyView() },
            action: action
        )
    }
}

/// One immutable data snapshot tied to one popover presentation — the
/// canonical way to hand click-time data to `.popover` content: present via
/// `.popover(item:)` with the loaded snapshot as the item, and the content
/// closure receives it as a parameter. On macOS 26.5 this is the ONLY
/// reliable path (see the CLAUDE.md popover rule); the fresh id also gives
/// every reopen a new content identity.
struct PopoverPresentation<Value>: Identifiable {
    let id = UUID()
    let value: Value
}

/// The shared "Reveal in Finder" popover row — tab menu, workspace menu,
/// file tree, and the status bar's repo pill all offer it; the 4th call
/// site made it a primitive.
struct RevealInFinderMenuRow: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        KookyMenuRow(title: "Reveal in Finder") {
            dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

extension View {
    /// 2pt drop-target indicator anchored to one edge of the view, animated on
    /// the `active` toggle. Used by reorder gestures (sidebar workspaces, tab
    /// pills, the trailing `+` button) to show "drop will land here".
    /// `offset` nudges the line into a visual gap between sibling views.
    /// `length` only applies to horizontal-axis (leading/trailing) edges.
    func dropIndicator(active: Bool, on edge: Alignment, offset: CGFloat = 0, length: CGFloat = 22) -> some View {
        let isVertical = edge == .top || edge == .bottom
        return overlay(alignment: edge) {
            let color = Theme.chromeForeground.opacity(active ? 0.55 : 0)
            if isVertical {
                Rectangle()
                    .fill(color)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: offset)
                    .animation(.easeOut(duration: 0.12), value: active)
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 2, height: length)
                    .offset(x: offset)
                    .animation(.easeOut(duration: 0.12), value: active)
            }
        }
    }
}

struct KookyMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chromeHairline)
            .frame(height: 1)
            .padding(.vertical, 3)
            .padding(.horizontal, Theme.space2)
    }
}

/// `≡` drag-source glyph used by every reorderable list (Settings →
/// Agents, Terminals, Status Bar). Scoping `.onDrag` to the handle — not
/// the whole row — keeps Toggle / TextField hit-testing independent and
/// makes openHand the only cursor inside the row.
struct ReorderHandle: View {
    let payload: String
    let onBeginDrag: () -> Void

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.chromeMuted.opacity(0.7))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .hoverCursor(.openHand)
            .onDrag {
                onBeginDrag()
                return NSItemProvider(object: payload as NSString)
            }
    }
}

/// Row-level drop catcher used by every reorderable list. The `Color.clear`
/// surface is load-bearing: putting `.dropDestination` on the row HStack
/// with `.contentShape(Rectangle())` routes Toggle / TextField clicks
/// through the row-wide content shape and registers them against the wrong
/// row. `decode` converts the dragged `NSItemProvider` payload (always a
/// `String`) into the caller's typed item; return `nil` to reject the drop.
struct ReorderDropZone<Item: Equatable>: View {
    let row: Item
    let isDragging: Bool
    let decode: (String) -> Item?
    let onDrop: (Item) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .dropIndicator(active: isTargeted && !isDragging, on: .top)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let dropped = decode(raw),
                      dropped != row else { return false }
                return onDrop(dropped)
            } isTargeted: { isTargeted = $0 }
            .allowsHitTesting(true)
    }
}

/// One segment of a sidebar footer toggle (left sidebar's workspaces/files,
/// right panel's agents/history). `HoverableIconButton` has no active-fill
/// state, so this is its selected-capable sibling: active segments read
/// the shared selection surface, hover reads
/// `chromeHover`.
struct FooterSegment: View {
    let systemName: String
    let isActive: Bool
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(
                    width: Theme.chromeFooterSegmentWidth,
                    height: Theme.chromeCompactButtonSize
                )
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chromeButtonCornerRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(Theme.chromeTransition, value: isActive)
        .accessibilityLabel(localizedHelp)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(localizedHelp)
    }

    private var localizedHelp: String {
        String(
            localized: String.LocalizationValue(help),
            bundle: .kookyResources
        )
    }

    private var iconColor: Color {
        isActive || isHovered ? Theme.chromeForeground : Theme.chromeMuted
    }

    private var fill: Color {
        if isActive { return Theme.chromeSelection }
        if isHovered { return Theme.chromeHover }
        return .clear
    }
}

/// Shared rename-popover body used by tab + workspace rename. Both render
/// inside `.popover` modifiers anchored to their own row; the caller picks
/// the arrowEdge so the popover points the right way.
/// kooky's checkbox: a native `.checkbox` Toggle whose mono label lifts to
/// the foreground tier when on. Third verbatim copy (the two worktree
/// close sheets, History's workspace filter) earned it a home; control size
/// and layout stay at the call site.
struct KookyCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var size: CGFloat = 11.5

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(Theme.mono(size))
                .foregroundStyle(isOn ? Theme.chromeForeground : Theme.chromeMuted)
        }
        .toggleStyle(.checkbox)
    }
}

struct KookyRenameField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(
            String(
                localized: String.LocalizationValue(placeholder),
                bundle: .kookyResources
            ),
            text: $text
        )
            .textFieldStyle(.plain)
            .font(Theme.display(13))
            .foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2 + 2)
            .frame(minWidth: 220)
            .background(Theme.chromeBackground)
            .onSubmit(onSubmit)
    }
}

extension View {
    /// Draws a workspace's colour tag as a stripe down the leading edge. Used
    /// by the sidebar row and both agent-panel row shapes, so the width,
    /// alignment, and "sits over the row fill, under its content" contract has
    /// one owner rather than three copies that can drift.
    ///
    /// Pass `nil` for an untagged row (or when the agent panel's tag display is
    /// switched off) and the view is returned untouched.
    @ViewBuilder
    func workspaceTagStripe(_ tag: WorkspaceTag?) -> some View {
        if let tag {
            overlay(alignment: .leading) {
                Rectangle()
                    .fill(tag.swatchColor)
                    .frame(width: Theme.colorTagStripeWidth)
            }
        } else {
            self
        }
    }
}
