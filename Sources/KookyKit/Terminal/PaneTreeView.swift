import AppKit
import SwiftUI

/// Recursive view for a workspace's split tree. Leaves render their own tab
/// strip + active terminal — a split slices the whole tab strip, not just
/// the content area.
struct PaneTreeView: View {
    @Bindable var node: PaneNode
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    var body: some View {
        switch node.content {
        case .pane(let pane):
            PaneView(
                pane: pane,
                workspace: workspace,
                store: store,
                isFocused: workspace.activePaneId == pane.id
            )
        case .split:
            SplitContainer(node: node, workspace: workspace, store: store)
        }
    }
}

private struct PaneView: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let isFocused: Bool

    private static let inactivePaneOpacity: Double = 0.5

    @State private var contextMenuOpen = false
    @State private var contextMenuAnchor: UnitPoint = .center

    var body: some View {
        let paneOpacity = isFocused ? 1.0 : Self.inactivePaneOpacity
        VStack(spacing: 0) {
            TabBarView(pane: pane, workspace: workspace, store: store)
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if let active = pane.activeTab {
                TerminalView(engine: active.engine)
                    .id(active.id)
                    .padding(8)
                    .overlay(RightClickCatcher { unit in
                        // Promote this pane to the workspace's active one —
                        // RightClickCatcher swallows rightMouseDown before
                        // libghostty sees it, so `engine.onFocus` never
                        // fires. Without this, the menu would dismiss but
                        // keystrokes + new-agent-tab spawns would still go
                        // to whichever pane had focus before.
                        store.activateTab(active, in: workspace)
                        contextMenuAnchor = unit
                        contextMenuOpen = true
                    })
                    .popover(
                        isPresented: $contextMenuOpen,
                        attachmentAnchor: .point(contextMenuAnchor),
                        arrowEdge: .top
                    ) {
                        PaneContextMenu(
                            session: active,
                            pane: pane,
                            workspace: workspace,
                            store: store,
                            isPresented: $contextMenuOpen
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        // Per-pane: multiple panes can search simultaneously,
                        // each with their own needle and result count.
                        if active.searchActive {
                            PaneSearchBar(
                                session: active,
                                onFocusGained: { store.activateTab(active, in: workspace) }
                            )
                            .padding(.top, Theme.space3)
                            .padding(.trailing, Theme.space3)
                        }
                    }
                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                PaneStatusBar(session: active)
            } else {
                Color.clear
            }
        }
        .opacity(paneOpacity)
        .animation(Theme.chromeTransition, value: isFocused)
    }
}

/// Chrome status bar pinned to the bottom of the active pane — Warp-style
/// approximation. libghostty owns the terminal grid, so we can't inline
/// above the prompt; pinning to chrome below the terminal is the closest
/// equivalent. Each segment is its own bordered pill with leading icon,
/// stacked right-aligned. Hidden entirely when no segment has data.
private struct PaneStatusBar: View {
    @Bindable var session: Session

    var body: some View {
        // Flow wraps overflowing segments to a new row instead of hiding
        // them — narrow panes still surface every status (branch / proxy /
        // env) at the cost of a taller chrome row. Each row is right-aligned
        // so the visual matches the single-row layout when nothing wraps.
        FlowLayout(alignment: .trailing, spacing: 8, rowSpacing: 4) {
            pythonSegment
            nodeSegment
            cwdSegment
            proxySegment
            branchSegment
            diffSegment
        }
        .frame(maxWidth: .infinity)
        .font(Theme.mono(11))
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, 5)
        .background(Theme.chromeBackground)
    }

    @ViewBuilder
    private var pythonSegment: some View {
        if let venv = session.environment.pythonVenv {
            StatusSegment(systemImage: "p.circle.fill") {
                Text(venv).foregroundStyle(Theme.chromeForeground)
            }
        }
    }

    @ViewBuilder
    private var nodeSegment: some View {
        if let version = session.environment.nodeVersion {
            let nvmDir = session.environment.nvmDirectory
            SwitchableStatusSegment<String>(
                systemImage: "n.circle.fill",
                label: version,
                helpText: "Switch Node version",
                popoverWidth: 190,
                popoverMaxHeight: 280,
                emptyMessage: "No nvm versions found",
                loadItems: { NodeVersionInventory.installedVersions(nvmDirectory: nvmDir) },
                isCurrent: { NodeVersionInventory.isSameVersion($0, version) },
                titleFor: { $0 },
                commandFor: NodeVersionInventory.shellUseCommand,
                session: session
            )
        }
    }

    @ViewBuilder
    private var proxySegment: some View {
        if let info = session.environment.proxy {
            ProxyStatusSegment(info: info, session: session)
        }
    }

    @ViewBuilder
    private var cwdSegment: some View {
        CwdStatusSegment(session: session)
    }

    @ViewBuilder
    private var branchSegment: some View {
        if let branch = session.gitStatus.branch {
            let cwd = session.currentDirectory
            SwitchableStatusSegment<String>(
                systemImage: "arrow.triangle.branch",
                label: branch,
                helpText: "Switch Git branch",
                popoverWidth: 230,
                popoverMaxHeight: 320,
                emptyMessage: "No local branches found",
                loadItems: { GitBranchInventory.localBranches(cwd: cwd) },
                isCurrent: { $0 == branch },
                titleFor: { $0 },
                commandFor: GitBranchInventory.shellSwitchCommand,
                session: session
            )
        }
    }

    @ViewBuilder
    private var diffSegment: some View {
        let s = session.gitStatus
        if s.branch != nil, s.filesChanged > 0 {
            StatusSegment(systemImage: "line.3.horizontal.button.angledtop.vertical.right") {
                // Order mirrors `git diff --shortstat` itself: files → +N → −N.
                // File count in chromeMuted (it's a count, not a delta) so the
                // saturated +/- pair pops as the actual change signal.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(s.filesChanged)")
                        .foregroundStyle(Theme.chromeMuted)
                    if s.insertions > 0 {
                        SignedNumber(sign: "+", value: s.insertions, color: Theme.gitInsertion)
                    }
                    if s.deletions > 0 {
                        // Unicode minus (U+2212), not hyphen — balanced
                        // typographic pair with `+`.
                        SignedNumber(sign: "−", value: s.deletions, color: Theme.gitDeletion)
                    }
                }
            }
        }
    }
}

/// One bordered segment of the status bar — leading SF Symbol icon at
/// `chromeMuted`, body content rendered by the caller. Wraps each
/// data-source (git, Python env, Node version, …) in a uniform pill so
/// adding new sources is just `StatusSegment(systemImage: ...) { ... }`.
private struct StatusSegment<Content: View>: View {
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(Theme.chromeMuted)
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Theme.chromeFaint, lineWidth: 1)
        )
    }
}

/// Wrap-on-overflow flow layout. Each row picks subviews greedily; when a
/// subview won't fit, it starts a new row. `alignment` shifts each row
/// within the parent's available width — `.trailing` mirrors the
/// right-aligned single-row look when nothing wraps. One pass per layout
/// invocation (no candidate-row probing like `ViewThatFits`), so this stays
/// cheap during animated parent-width changes.
private struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let plan = plan(width: width, subviews: subviews)
        return CGSize(width: proposal.width ?? plan.contentWidth, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(width: bounds.width, subviews: subviews)
        for (i, p) in plan.positions.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func plan(width: CGFloat, subviews: Subviews) -> (positions: [CGPoint], height: CGFloat, contentWidth: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let needed = rowWidth + (rowWidth > 0 ? spacing : 0) + size.width
            if rowWidth > 0, needed > width {
                rows.append([i])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(i)
                rowWidth = needed
            }
        }
        var positions = [CGPoint](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for row in rows {
            let rowContent = row.reduce(CGFloat(0)) { acc, i in
                acc + sizes[i].width + (acc > 0 ? spacing : 0)
            }
            maxRowWidth = max(maxRowWidth, rowContent)
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            let startX: CGFloat
            switch alignment {
            case .trailing: startX = max(0, width - rowContent)
            case .center:   startX = max(0, (width - rowContent) / 2)
            default:        startX = 0
            }
            var x = startX
            for i in row {
                positions[i] = CGPoint(x: x, y: y)
                x += sizes[i].width + spacing
            }
            y += rowHeight + rowSpacing
        }
        return (positions, max(0, y - rowSpacing), maxRowWidth)
    }
}

/// `+47` / `−12` as one cohesive typographic token — sign rendered at 60%
/// saturation of its digit creates a subtle hierarchical stagger that reads
/// as designed, not as a UI widget. JetBrains Mono is fixed-width, so the
/// two-Text HStack stays optically tight without manual kerning.
private struct SignedNumber: View {
    let sign: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(sign).foregroundStyle(color.opacity(0.6))
            Text("\(value)").foregroundStyle(color)
        }
    }
}

/// A `StatusSegment` you can click — opens a popover listing alternatives,
/// click one to inject a shell command. Shared shell for both the Node
/// version switcher and the git branch switcher; new switchers (Python
/// versions, mise tools, …) just instantiate with their own loader +
/// formatter.
///
/// `loadItems` is called only on click, not on `onAppear` — popover content
/// is what triggers the inventory work, so a tab the user never opens the
/// switcher on does zero filesystem / subprocess.
private struct SwitchableStatusSegment<Item: Hashable>: View {
    let systemImage: String
    let label: String
    let helpText: String
    let popoverWidth: CGFloat
    let popoverMaxHeight: CGFloat
    let emptyMessage: String
    let loadItems: () -> [Item]
    let isCurrent: (Item) -> Bool
    let titleFor: (Item) -> String
    let commandFor: (Item) -> String
    let session: Session

    @State private var isSwitcherOpen = false
    @State private var isHovered = false
    @State private var items: [Item] = []

    var body: some View {
        Button {
            items = loadItems()
            isSwitcherOpen.toggle()
        } label: {
            StatusSegment(systemImage: systemImage) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.chromeForeground)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered || isSwitcherOpen ? Theme.chromeHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .help(helpText)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isSwitcherOpen, arrowEdge: .bottom) {
            KookyMenuList(width: popoverWidth, maxHeight: popoverMaxHeight) {
                if items.isEmpty {
                    KookyMenuRow(title: emptyMessage, isDisabled: true) {}
                } else {
                    ForEach(items, id: \.self) { item in
                        let current = isCurrent(item)
                        KookyMenuRow(
                            title: titleFor(item),
                            isDisabled: current,
                            leading: { menuRowCheckmark(visible: current) }
                        ) {
                            isSwitcherOpen = false
                            session.engine.sendInput(commandFor(item))
                        }
                    }
                }
            }
        }
    }
}

/// Each row click-copies the `name=value` to the pasteboard. No PTY
/// injection: `unset` semantics differ per shell and across already-launched
/// child processes, so kooky doesn't pretend to switch proxies for you.
private struct ProxyStatusSegment: View {
    let info: ProxyInfo
    let session: Session

    @State private var isPopoverOpen = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPopoverOpen.toggle()
        } label: {
            StatusSegment(systemImage: "network") {
                Text(info.summary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.chromeForeground)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered || isPopoverOpen ? Theme.chromeHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .help("Show proxy env (click text to copy)")
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPopoverOpen, arrowEdge: .bottom) {
            KookyMenuList(width: 380, maxHeight: 240) {
                ForEach(info.entries, id: \.self) { entry in
                    ProxyEntryRow(entry: entry) {
                        // Click entry text → copy raw `name=value` to clipboard.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry, forType: .string)
                        isPopoverOpen = false
                    } onUnset: { name in
                        // `unset` lowercase + uppercase together — corporate
                        // shells often export both forms; clearing just one
                        // leaves the other in effect.
                        let upper = name.uppercased()
                        session.engine.sendInput("unset \(name) \(upper)\r")
                        isPopoverOpen = false
                    }
                }
            }
        }
    }
}

private struct ProxyEntryRow: View {
    let entry: String
    let onCopy: () -> Void
    let onUnset: (String) -> Void

    @State private var isHovered = false

    private var name: String {
        // `name=value` — split once on first `=`. Names are well-known
        // (https_proxy / http_proxy / all_proxy) so no escaping concern.
        String(entry.prefix { $0 != "=" })
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onCopy) {
                Text(entry)
                    .font(Theme.display(12.5, weight: .regular))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            Button("Unset") { onUnset(name) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.chromeFaint.opacity(0.6))
                )
                .help("unset \(name)")
        }
        .padding(.horizontal, Theme.space2 + 2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Theme.chromeHover : .clear)
        )
        .onHover { isHovered = $0 }
    }
}

/// Current-directory pill: shows the cwd abbreviated to its last three path
/// components (e.g. `…/personal/projects/kooky`), or `~` when the cwd is
/// $HOME. Click copies the full absolute path to the pasteboard — the
/// shortened display is for fitting in the chrome row, but the user almost
/// always wants the full path when they reach for it (paste into Finder,
/// `cd` in another terminal, scripts, etc.).
private struct CwdStatusSegment: View {
    @Bindable var session: Session

    @State private var isHovered = false
    @State private var didCopy = false

    private var fullPath: String {
        session.currentDirectory.standardizedFileURL.path
    }

    private var displayPath: String {
        let standardized = session.currentDirectory.standardizedFileURL
        let path = standardized.path
        if path == NSHomeDirectory() { return "~" }
        // `pathComponents` includes a leading "/" for absolute URLs — drop it
        // so the last-3 slice doesn't pull in the root separator as a
        // component.
        let parts = standardized.pathComponents.filter { $0 != "/" }
        if parts.count <= 3 { return path }
        return "…/" + parts.suffix(3).joined(separator: "/")
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fullPath, forType: .string)
            withAnimation(.easeInOut(duration: 0.12)) { didCopy = true }
            // Revert the checkmark after a beat so repeated copies still
            // animate. Lives on the MainActor — Session + this view are both
            // `@MainActor`-isolated.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                withAnimation(.easeInOut(duration: 0.2)) { didCopy = false }
            }
        } label: {
            StatusSegment(systemImage: didCopy ? "checkmark" : "folder") {
                Text(didCopy ? "Copied" : displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.chromeForeground)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Theme.chromeHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .help("\(fullPath) — click to copy")
        .onHover { isHovered = $0 }
    }
}

/// Right-click context menu for a terminal pane. Top section is the
/// "Ask <agent>" rows (visible only when there's a selection); below
/// the divider are the standard Copy / Paste / Select All / Clear
/// actions rendered in the same brutalist style as the rest of kooky's
/// popover menus instead of the system NSMenu. Anchored at the click
/// site via `attachmentAnchor: .point(...)` so it reads as a contextual
/// menu, not a static popover on the pane edge.
private struct PaneContextMenu: View {
    let session: Session
    /// Pane the right-click landed on. Explicitly passed (rather than
    /// inferred from `workspace.activePane`) so Ask <agent> spawns the
    /// new tab inside the visually-right-clicked split, even when the
    /// outer activate-on-right-click call hasn't yet rippled through
    /// SwiftUI state.
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    @Binding var isPresented: Bool

    private let model = KookySettingsModel.shared

    var body: some View {
        let selection = session.engine.readSelection() ?? ""
        let hasSelection = !selection.isEmpty
        let pasteAvailable = !(NSPasteboard.general.string(forType: .string) ?? "").isEmpty
        let askRows = hasSelection ? buildAskRows() : []
        KookyMenuList(width: 240, maxHeight: 480) {
            if !askRows.isEmpty {
                ForEach(askRows, id: \.template.id) { row in
                    KookyMenuRow(
                        title: row.isDefault ? "▸ Ask \(row.template.title)" : "Ask \(row.template.title)",
                        leading: {
                            AgentIconView(asset: row.template.iconAsset, fallbackSymbol: row.template.symbol, size: 16)
                        }
                    ) {
                        ask(agent: row.template, selection: selection)
                    }
                }
                Divider()
            }
            KookyMenuRow(title: "Copy", shortcut: "⌘C", isDisabled: !hasSelection) {
                isPresented = false
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection, forType: .string)
            }
            KookyMenuRow(title: "Paste", shortcut: "⌘V", isDisabled: !pasteAvailable) {
                isPresented = false
                if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    session.engine.paste(text)
                }
            }
            Divider()
            KookyMenuRow(title: "Select All", shortcut: "⌘A") {
                isPresented = false
                session.engine.performAction("select_all")
            }
            KookyMenuRow(title: "Clear", shortcut: "⌘K") {
                isPresented = false
                session.engine.performAction("clear_screen")
            }
        }
    }

    private func buildAskRows() -> [(template: AgentTemplate, isDefault: Bool)] {
        let defaultId = AgentTemplate.defaultLaunchTemplate(model: model)
            .flatMap { $0.id == "terminal" ? nil : $0.id }
        let visible = AgentTemplate.visibleOrdered(model: model).filter { $0.id != "terminal" }
        var rows: [(AgentTemplate, Bool)] = []
        if let defaultId, let def = visible.first(where: { $0.id == defaultId }) {
            rows.append((def, true))
        }
        for t in visible where t.id != defaultId {
            rows.append((t, false))
        }
        return rows
    }

    private func ask(agent: AgentTemplate, selection: String) {
        isPresented = false
        let tab = store.addTab(
            in: workspace,
            pane: pane,
            template: agent,
            initialCwd: session.currentDirectory,
            initialPrompt: selection
        )
        store.activateTab(tab, in: workspace)
    }
}

/// Scrollable menu shell shared by every popover in the status bar (and
/// future ones). Width varies per call site; vertical chrome and bg are
/// constant. Keeps `KookyMenuRow`'s sibling layout consistent across the
/// app.
private struct KookyMenuList<Content: View>: View {
    let width: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 2, content: content).padding(6)
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background(Theme.chromeBackground)
    }
}

@ViewBuilder
private func menuRowCheckmark(visible: Bool) -> some View {
    if visible {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.chromeForeground)
            .frame(width: 14)
    } else {
        Color.clear.frame(width: 14, height: 11)
    }
}

/// Editable search field overlaying the active pane's terminal area.
/// Each keystroke pushes `search:<text>` to libghostty (the named action
/// that updates the needle and re-runs the search). Auto-focuses when
/// search activates so Esc / Enter route here instead of to the terminal
/// NSView. Lives in `PaneTreeView` because search state belongs visually
/// next to the content it filters — not in the global window chrome.
private struct PaneSearchBar: View {
    @Bindable var session: Session
    /// Called when the TextField gains focus so the parent can promote this
    /// pane to active. Without this, clicking a non-active pane's search bar
    /// leaves `WorkspaceStore.activePaneId` unchanged, and ⌘G / ⌘⇧G route
    /// `navigate_search` to the wrong session.
    let onFocusGained: () -> Void
    @State private var needle = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.chromeMuted)
            TextField("Search…", text: $needle)
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeForeground)
                .focused($focused)
                .onChange(of: needle) { _, new in
                    // Persist the needle on the session so it survives a tab
                    // switch (which destroys this view; `onAppear` re-seeds
                    // from `session.searchNeedle`). libghostty's `START_SEARCH`
                    // action_cb writes the same field but only fires on initial
                    // start_search, not on per-keystroke updates.
                    session.searchNeedle = new
                    // `search:<text>` is libghostty's "update the search needle"
                    // action. Empty cancels matches but keeps the GUI open per
                    // libghostty's docs — we end_search explicitly on Esc / X.
                    session.engine.performAction("search:\(new)")
                }
                .onSubmit {
                    session.engine.performAction("navigate_search:next")
                }
                .onKeyPress(.escape) {
                    end()
                    return .handled
                }
            if session.searchTotal > 0 {
                Text(counterText)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .frame(minWidth: 50, alignment: .trailing)
            }
            HoverableIconButton(systemName: "chevron.up", fontSize: 10, size: 20, help: "Previous match (⌘⇧G)") {
                session.engine.performAction("navigate_search:previous")
            }
            HoverableIconButton(systemName: "chevron.down", fontSize: 10, size: 20, help: "Next match (⌘G)") {
                session.engine.performAction("navigate_search:next")
            }
            HoverableIconButton(systemName: "xmark", fontSize: 10, size: 20, help: "End search (Esc)") {
                end()
            }
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 5)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.chromeBackground.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.chromeHairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .onAppear {
            // Seed from libghostty's start-search needle so a future
            // `start_search:<text>` keybind (or selected-text seeding) carries
            // through to the visible TextField. Empty in the common case.
            needle = session.searchNeedle
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { onFocusGained() }
        }
    }

    private func end() {
        focused = false
        session.engine.performAction("end_search")
    }

    /// "i / total" once the user has navigated to a specific match;
    /// the bare match count while libghostty's `selected = -1` (no current
    /// match highlighted yet).
    private var counterText: String {
        guard session.searchSelected >= 0 else { return "\(session.searchTotal)" }
        return "\(session.searchSelected + 1) / \(session.searchTotal)"
    }
}

private struct SplitContainer: View {
    @Bindable var node: PaneNode
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    @State private var dragStartFraction: Double?

    private static let dividerThickness: CGFloat = 1
    private static let handleHitSize: CGFloat = 6
    private static let minFraction: Double = 0.1
    private static let maxFraction: Double = 0.9

    var body: some View {
        guard case .split(let orientation, let first, let second, let fraction) = node.content else {
            return AnyView(EmptyView())
        }
        return AnyView(
            GeometryReader { geo in
                let total: CGFloat = orientation == .horizontal ? geo.size.width : geo.size.height
                let usable = max(total - Self.dividerThickness, 0)
                let firstSize = max(0, usable * fraction)
                let secondSize = max(0, usable - firstSize)
                let handleOffset = firstSize - Self.handleHitSize / 2 + Self.dividerThickness / 2

                ZStack(alignment: orientation == .horizontal ? .leading : .top) {
                    if orientation == .horizontal {
                        HStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store).frame(width: firstSize)
                            Rectangle().fill(Theme.chromeHairline).frame(width: Self.dividerThickness)
                            PaneTreeView(node: second, workspace: workspace, store: store).frame(width: secondSize)
                        }
                        DividerHandle(orientation: .horizontal)
                            .frame(width: Self.handleHitSize, height: geo.size.height)
                            .offset(x: handleOffset, y: 0)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    } else {
                        VStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store).frame(height: firstSize)
                            Rectangle().fill(Theme.chromeHairline).frame(height: Self.dividerThickness)
                            PaneTreeView(node: second, workspace: workspace, store: store).frame(height: secondSize)
                        }
                        DividerHandle(orientation: .vertical)
                            .frame(width: geo.size.width, height: Self.handleHitSize)
                            .offset(x: 0, y: handleOffset)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    }
                }
            }
        )
    }

    private func dragGesture(orientation: SplitOrientation, total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard case .split(let orient, let f, let s, let current) = node.content else { return }
                if dragStartFraction == nil { dragStartFraction = current }
                let translation = orientation == .horizontal ? value.translation.width : value.translation.height
                let delta = total > 0 ? Double(translation) / Double(total) : 0
                let proposed = (dragStartFraction ?? current) + delta
                let clamped = min(max(proposed, Self.minFraction), Self.maxFraction)
                guard abs(clamped - current) > .ulpOfOne else { return }
                node.content = .split(orientation: orient, first: f, second: s, fraction: clamped)
            }
            .onEnded { _ in
                dragStartFraction = nil
                store.flushPersistence()
            }
    }
}

private struct DividerHandle: View {
    let orientation: SplitOrientation

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    if orientation == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}
