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
                TerminalView(engine: active.engine, grabsFocusOnMount: isFocused)
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
                    .overlay(alignment: .bottom) {
                        // ⌘L composer rises from the bottom like a chat box.
                        // Per-pane / per-session, same as search.
                        if active.composerActive {
                            PaneComposerBar(
                                session: active,
                                onFocusGained: { store.activateTab(active, in: workspace) }
                            )
                            .padding(.horizontal, Theme.space3)
                            .padding(.bottom, Theme.space3)
                        }
                    }
                // Always present now that it hosts the compose button — a
                // stable bottom affordance, not gated on git / env / zoom data.
                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                PaneStatusBar(session: active, paneId: pane.id, workspace: workspace, store: store)
            } else {
                Color.clear
            }
        }
        .opacity(paneOpacity)
        .animation(Theme.chromeTransition, value: isFocused)
        .onChange(of: pane.activeTab.map { paneStatusBarHasData(session: $0) } ?? false) { _, _ in
            // Status-bar height transition. The bar is always present now (it
            // hosts the compose button), so this fires when its CONTENT height
            // changes — a pill/segment appears or clears, or FlowLayout wraps
            // to another row — not when the whole bar shows/hides. That still
            // moves chrome height → libghostty re-frames the surface →
            // SIGWINCH burst → conda init's precmd hook would wipe scrollback
            // (CLAUDE.md Known issues). Reuse the pane-zoom pattern: suspend
            // SIGWINCH on EVERY tab's engine in the pane (background tabs share
            // the parent NSView geometry, not just the active one), then flush
            // after the transition settles. Refcounted (issue #29 review): begin
            // now, end after 250ms, on a LOCAL engine capture — each height change
            // is a self-balanced begin/end pair, so overlapping changes / a zoom /
            // a divider drag on the same engines compose, and the old generation
            // token is unnecessary. Flush only when the engine's count hits 0 (its
            // last owner released) so a concurrent suspender isn't defeated.
            let engines = pane.tabs.map(\.engine)
            for engine in engines { engine.beginSizePropagationSuspension() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)  // covers Theme.chromeTransition
                for engine in engines {
                    engine.endSizePropagationSuspension()
                    if !engine.suspendsSizePropagation { engine.flushSize() }
                }
            }
        }
    }
}

/// One configurable slot of the pane status bar. Order + visibility are
/// controlled by Settings → Status Bar (`KookySettingsModel.statusBarItems`
/// + `.hiddenStatusBarItems`). Adding a new kind: append a case here,
/// add the rendering branch in `PaneStatusBar.segment(for:)`, and add the
/// data-presence branch in `paneStatusBarHasData`.
enum StatusBarItemKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// Tool-call activity pill, shown for agents that feed kooky their
    /// tool calls (`AgentTemplate.reportsToolCalls` — Claude + Pi).
    /// Special-positioned on the left of the bar (not inside the
    /// right-aligned `FlowLayout`) so the rotating-content piece doesn't
    /// compete with the static signals. Settings entry here only controls
    /// visibility; reordering this kind has no visible effect because
    /// rendering bypasses `visibleItems`.
    case toolCallActivity = "tool-call-activity"
    /// Codex account rate-limit gauge (5-hour + weekly windows). Like
    /// `.toolCallActivity` it's agent-specific (Codex only) and rendered in a
    /// hardcoded slot rather than the right-aligned `FlowLayout`; its Settings
    /// row lives under a per-agent "Codex" section (`hiddenUsageAgents`).
    case codexUsage = "codex-usage"
    case pythonVenv = "python-venv"
    case nodeVersion = "node-version"
    case proxy
    case remoteLogin = "remote-login"
    case gitBranch = "git-branch"
    case gitDiff = "git-diff"

    var displayName: String {
        switch self {
        case .toolCallActivity: return "Tool calls"
        case .codexUsage: return "Usage remaining"
        case .pythonVenv: return "Python venv"
        case .nodeVersion: return "Node version"
        case .proxy: return "Proxy"
        case .remoteLogin: return "Remote Login"
        case .gitBranch: return "Git branch"
        case .gitDiff: return "Git diff"
        }
    }

    /// SF Symbol used by Settings → Status Bar to label each row. nil for
    /// `.toolCallActivity`: its row lives under a per-agent section whose
    /// header already carries that agent's mark (Settings renders one
    /// section per tool-reporting agent — Claude / Pi), so no per-row glyph.
    var symbol: String? {
        switch self {
        case .toolCallActivity: return nil
        case .codexUsage: return nil
        case .pythonVenv: return "p.circle.fill"
        case .nodeVersion: return "hexagon"
        case .proxy: return "network"
        case .remoteLogin: return "person.fill"
        case .gitBranch: return "arrow.triangle.branch"
        case .gitDiff: return "plusminus"
        }
    }

    /// Kinds rendered in a hardcoded left slot (an agent's live signal —
    /// tool-call pill, Codex usage gauge) rather than the right-aligned,
    /// reorderable `FlowLayout`. Their Settings rows live under a per-agent
    /// section, so they're excluded from `visibleItems` / `reorderableItems`.
    var isHardcodedSlot: Bool { self == .toolCallActivity || self == .codexUsage }

    /// Default order shipped with kooky — used when the user hasn't
    /// touched Settings → Status Bar. Tool-call activity goes first so a
    /// fresh Settings → Status Bar list renders it at the top.
    static let defaultOrder: [StatusBarItemKind] = [
        .toolCallActivity, .codexUsage, .remoteLogin, .pythonVenv, .nodeVersion, .proxy, .gitBranch, .gitDiff,
    ]
}

/// Decides whether to draw the status-bar hairline + row. Returns false
/// when every enabled kind has no data, so a bottom chrome divider
/// doesn't draw over an empty row. Includes the activity pill — when a
/// Claude session is alive but no other slot has data (no git repo, no
/// venv), the bar appears just to host the pill.
@MainActor
func paneStatusBarHasData(session: Session) -> Bool {
    let model = KookySettingsModel.shared
    for item in model.statusBarItems where !model.hiddenStatusBarItems.contains(item) {
        // The outer `where` clause already filters hidden kinds, so each
        // case body only needs the pure data-presence check — no kind-
        // enabled re-check. Activity pill: ask only the session-level
        // question (is Claude active in this tab?) since the kind-enabled
        // gate already lives in the loop predicate.
        switch item {
        case .toolCallActivity: if sessionWantsToolCallActivity(session) { return true }
        case .codexUsage: if sessionWantsCodexUsage(session) { return true }
        case .pythonVenv: if session.environment.pythonVenv != nil { return true }
        case .nodeVersion: if session.environment.nodeVersion != nil { return true }
        case .proxy: if session.environment.proxy != nil { return true }
        case .remoteLogin: if session.remoteHost != nil { return true }
        case .gitBranch: if session.gitStatus.branch != nil { return true }
        case .gitDiff: if session.gitStatus.branch != nil && session.gitStatus.filesChanged > 0 { return true }
        }
    }
    return false
}

/// Tool-call activity-pill visibility predicate — `true` when the tab's
/// agent feeds tool-call activity (`reportsToolCalls` — Claude + Pi, plus
/// any custom built on them, since `fromCustom` inherits the flag), a
/// session is currently alive (activityState != .idle), AND the user hasn't
/// hidden that agent's pill in Settings → Status Bar (per-agent toggle,
/// `hiddenToolCallAgents`, keyed by base id so a custom follows its base).
/// `showToolCallActivityPill` is the call-site alias; `paneStatusBarHasData`
/// calls this directly.
@MainActor
func sessionWantsToolCallActivity(_ session: Session) -> Bool {
    guard session.agent.reportsToolCalls, session.activityState != .idle else { return false }
    let agentKey = session.agent.baseAgentId ?? session.agent.id
    return !KookySettingsModel.shared.hiddenToolCallAgents.contains(agentKey)
}

/// Codex usage-gauge visibility predicate — `true` when the Codex usage
/// monitor has parsed at least one quota window for this tab AND the user
/// hasn't hidden it in Settings → Status Bar (per-agent toggle,
/// `hiddenUsageAgents`, keyed by base id so a custom follows its base). The
/// monitor only populates `codexUsage` for Codex sessions, so no agent
/// re-check is needed here.
@MainActor
func sessionWantsCodexUsage(_ session: Session) -> Bool {
    guard let usage = session.codexUsage, usage.hasQuota else { return false }
    // Only on an actual Codex tab — once Codex exits the agent reverts to
    // `.terminal`, so this also hides a stale gauge the moment the session
    // is no longer Codex (belt-and-suspenders with the onCommandFinished clear).
    let agentKey = session.displayAgent.baseAgentId ?? session.displayAgent.id
    guard agentKey == AgentTemplate.codex.id else { return false }
    return !KookySettingsModel.shared.hiddenUsageAgents.contains(agentKey)
}

/// A status-bar icon button: bracket-bordered pill with hover + engaged
/// (active) fill, matching `BracketButton` / Settings rows. Both the compose
/// and zoom buttons are this — factored out the moment there were two.
private struct StatusBarIconButton: View {
    let systemName: String
    let isActive: Bool
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeMuted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Theme.chromeHairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(Theme.chromeTransition, value: hovered)
        .animation(Theme.chromeTransition, value: isActive)
    }

    private var fill: Color {
        if isActive { return Theme.chromeActive }
        if hovered { return Theme.chromeHover }
        return Color.clear
    }
}

/// Chrome status bar pinned to the bottom of the active pane — Warp-style
/// approximation. libghostty owns the terminal grid, so we can't inline
/// above the prompt; pinning to chrome below the terminal is the closest
/// equivalent. Each segment is its own bordered pill with leading icon,
/// stacked right-aligned. Hidden entirely when no segment has data.
private struct PaneStatusBar: View {
    @Bindable var session: Session
    /// Which pane this status bar belongs to. The zoom button uses this so
    /// clicking a non-active pane's button still zooms *that* pane (not
    /// whatever has keyboard focus).
    let paneId: UUID
    @Bindable var workspace: Workspace
    let store: WorkspaceStore
    /// `.shared` is the only producer — `@Observable` tracks per-property
    /// reads, so observation is per-`statusBarItems` / per-`hiddenStatusBarItems`
    /// access without needing `@Bindable`.
    private let model = KookySettingsModel.shared

    var body: some View {
        HStack(spacing: 8) {
            // Zoom + compose: bracket-pill icon buttons. Zoom shows only when
            // meaningful; compose is always present — the reason the bar's
            // visibility gate is gone (the bar is the stable host for it).
            if workspace.canZoom {
                let isZoomed = workspace.isZoomed(paneId)
                StatusBarIconButton(
                    systemName: isZoomed
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    isActive: isZoomed,
                    help: isZoomed ? "Exit zoom (⌘⇧E)" : "Zoom pane (⌘⇧E)"
                ) {
                    withAnimation(Theme.chromeTransition) {
                        store.toggleZoom(in: workspace, paneId: paneId)
                    }
                }
            }
            StatusBarIconButton(
                systemName: "long.text.page.and.pencil",
                isActive: session.composerActive,
                help: "Compose (⌘L)"
            ) {
                session.composerActive.toggle()
            }
            // Tool-call activity pill — Claude-only, shows the latest
            // tool call + click-to-popover for history. Sits on the left
            // (after zoom) so the rotating-content piece doesn't compete
            // with the trailing-aligned static signals (git / env / etc.).
            if showToolCallActivityPill(for: session) {
                ToolCallActivityPill(session: session)
            }
            // Codex account quota gauge — Codex-only, sits on the left next to
            // the activity-pill slot (Codex feeds no tool calls, so the slot is
            // free) since it's this agent's live signal, not a static env one.
            if sessionWantsCodexUsage(session), let usage = session.codexUsage {
                CodexUsagePill(usage: usage)
            }
            // Flow wraps overflowing segments to a new row instead of hiding
            // them — narrow panes still surface every status at the cost of
            // a taller chrome row. Each row is right-aligned so the visual
            // matches the single-row layout when nothing wraps.
            FlowLayout(alignment: .trailing, spacing: 8, rowSpacing: 4) {
                ForEach(visibleItems, id: \.self) { item in
                    segment(for: item)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .font(Theme.mono(11))
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, 5)
        .glassChromeBackground()
    }

    /// Items that render inside the right-aligned `FlowLayout`. Activity
    /// pill is excluded — it has its own hardcoded slot on the left of
    /// the bar (driven by `showToolCallActivityPill`, which already
    /// honors the kind's hidden/visible state).
    private var visibleItems: [StatusBarItemKind] {
        model.statusBarItems.filter {
            !$0.isHardcodedSlot && !model.hiddenStatusBarItems.contains($0)
        }
    }

    @ViewBuilder
    private func segment(for item: StatusBarItemKind) -> some View {
        switch item {
        case .toolCallActivity: EmptyView()  // rendered separately on the left
        case .codexUsage: EmptyView()  // rendered separately on the left
        case .pythonVenv: pythonSegment
        case .nodeVersion: nodeSegment
        case .proxy: proxySegment
        case .remoteLogin: remoteLoginSegment
        case .gitBranch: branchSegment
        case .gitDiff: diffSegment
        }
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
                systemImage: "hexagon",
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
    private var remoteLoginSegment: some View {
        if let host = session.remoteHost {
            StatusSegment(systemImage: "person.fill") {
                Text(host)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.chromeForeground)
            }
        }
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
            StatusSegment(systemImage: "plusminus") {
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
        let pasteAvailable = KookyShellIntegration.pasteboardHasTerminalPasteContent(.general)
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
                if let text = KookyShellIntegration.readTerminalPasteText(
                    from: .general,
                    remoteHost: session.remoteHost ?? workspace.sshRemoteHost
                ),
                   !text.isEmpty
                {
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
            if workspace.canZoom {
                Divider()
                let isZoomed = workspace.isZoomed(pane.id)
                KookyMenuRow(title: isZoomed ? "Exit Zoom" : "Zoom Pane", shortcut: "⌘⇧E") {
                    isPresented = false
                    withAnimation(Theme.chromeTransition) {
                        store.toggleZoom(in: workspace, paneId: pane.id)
                    }
                }
            }
        }
    }

    private func buildAskRows() -> [(template: AgentTemplate, isDefault: Bool)] {
        // Shells (default Terminal + presets) have nothing to "Ask".
        let defaultId = AgentTemplate.defaultLaunchTemplate(model: model)
            .flatMap { $0.isShell ? nil : $0.id }
        let visible = AgentTemplate.visibleOrdered(model: model).filter { !$0.isShell }
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
@MainActor
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

/// Multiline prompt composer (⌘L) — a chat-style box that rises from the
/// bottom of the pane for writing prompts. Return sends the draft to the agent
/// (pasted whole, newlines intact, then a carriage return to submit);
/// Shift+Return inserts a newline; Esc cancels but keeps the draft on the
/// session. The body is an `NSTextView` (`ComposerTextView`) rather than a
/// SwiftUI `TextEditor`: only `doCommandBy` can intercept Return *before* a
/// newline is inserted, which is what the chat convention needs (Return =
/// send, Shift+Return = newline — same as ChatGPT / Claude.ai / Slack).
private struct PaneComposerBar: View {
    @Bindable var session: Session
    let onFocusGained: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComposerTextView(
                text: $session.composerDraft,
                remoteHostProvider: { session.remoteHost },
                onSend: send,
                onCancel: close
            )
            // Identity by session. SwiftUI otherwise reuses one
            // NSViewRepresentable coordinator across tabs, so switching between
            // two tabs that both have the composer open would route this tab's
            // edits / Return to the previous session, and the reused view
            // wouldn't re-grab focus (Codex P2). `.id` forces a fresh view +
            // coordinator + makeFirstResponder per session.
            .id(session.id)
            .frame(minHeight: 46, maxHeight: 168)
            .overlay(alignment: .topLeading) {
                if session.composerDraft.isEmpty {
                    Text("type prompt or command here")
                        .font(Theme.mono(12.5))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.55))
                        .padding(.leading, 7)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                hint("⏎", "send")
                hint("⇧⏎", "newline")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.chromeBackground.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.chromeHairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, y: 3)
        )
        .frame(maxWidth: .infinity)
        .onAppear { onFocusGained() }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Theme.mono(9.5, weight: .medium))
                .foregroundStyle(Theme.chromeForeground.opacity(0.7))
            Text(label)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.chromeMuted)
        }
    }

    private func send() {
        let trimmed = session.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { close(); return }
        // Paste the raw draft (newlines intact, bracketed-paste wrapped) then a
        // carriage return to submit — the same two-step the shell / agent
        // readline expects from a real ⌘V followed by Enter.
        session.engine.paste(session.composerDraft)
        session.engine.sendInput("\r")
        session.composerDraft = ""
        close()
    }

    private func close() {
        session.composerActive = false
        // Hand first responder back to the terminal surface. The composer's
        // NSTextView held it, so without this the surface stays unfocused once
        // the overlay is torn down and the user must click the pane before
        // typing again (Codex P2). Deferred so the overlay is gone first.
        let view = session.engine.view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

/// NSTextView that resolves a pasted file or image into the terminal's full
/// backslash-escaped path — matching ⌘V in the surface — instead of the system
/// default, where a fileURL's `.string` is just the basename (why pasting a
/// file showed only the filename in the composer). Routes through the shared
/// `readTerminalPasteText` seam (file → escaped path, image → cached-PNG path)
/// that both terminal paste entry points use, so the composer can't drift from
/// them. Plain text falls through to NSTextView's native paste, keeping undo
/// coalescing + smart behaviors.
private final class ComposerNSTextView: NSTextView {
    var remoteHostProvider: (() -> String?)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.availableType(from: [.fileURL, .png, .tiff]) != nil,
           let text = KookyShellIntegration.readTerminalPasteText(
               from: pb,
               remoteHost: remoteHostProvider?()
           ),
           !text.isEmpty {
            insertText(text, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }
}

/// AppKit-backed multiline editor for the composer. A SwiftUI `TextEditor`
/// inserts a newline on Return before `onKeyPress` can see it, so it can't do
/// "Return sends, Shift+Return newlines." An `NSTextView` via `doCommandBy`
/// intercepts the Return command itself, before any newline is inserted.
private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var remoteHostProvider: (() -> String?)?
    var onSend: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerNSTextView(frame: .zero)
        tv.remoteHostProvider = remoteHostProvider
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.textColor = NSColor(Theme.chromeForeground)
        tv.insertionPointColor = NSColor(Theme.chromeForeground)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 3, height: 5)
        // This text feeds a terminal / agent verbatim — kill every auto-rewrite
        // so smart quotes / dashes, text replacement, and autocorrect can't
        // mangle command args, JSON, or `--flags` before paste (Codex P2).
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        // Grab focus once the view lands in a window so Return / Esc route here.
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ComposerNSTextView else { return }
        tv.remoteHostProvider = remoteHostProvider
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return → newline (let the text view handle it);
                // plain Return → send.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                parent.onSend()
                return true
            case #selector(NSResponder.cancelOperation(_:)):  // Esc
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private struct SplitContainer: View {
    @Bindable var node: PaneNode
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    @State private var dragStartFraction: Double?
    /// True while a divider drag is actively resizing (a real fraction change has
    /// occurred). Gates the SIGWINCH-suspend so a bare click on the handle — which
    /// still fires `onChanged` under `minimumDistance: 0` but changes nothing —
    /// doesn't suspend the subtree for no reason. Also gates begin/end so the
    /// refcount stays balanced (one begin per drag, one end).
    @State private var dividerResizeSuspended = false
    /// The exact engines this drag incremented, captured at drag start so onEnded /
    /// onDisappear `end` the SAME set — a re-walk could diverge on a mid-drag
    /// teardown and leave the refcount stuck > 0 (issue #29 review).
    @State private var dividerSuspendedEngines: [any TerminalEngine] = []

    private static let dividerThickness: CGFloat = 1
    private static let handleHitSize: CGFloat = 6
    private static let minFraction: Double = 0.1
    private static let maxFraction: Double = 0.9

    var body: some View {
        guard case .split(let orientation, let first, let second, let storedFraction) = node.content else {
            return AnyView(EmptyView())
        }
        // Pane zoom = "push the fraction on every split along the path to
        // the zoomed pane all the way to one side, smoothly animated."
        // Non-zoomed panes get squeezed to width 0 by SwiftUI's frame
        // animation. NSViews follow the CALayer frame change, so the
        // libghostty surface visibly scales (same mechanism as the
        // sidebar's `.frame(width:)` morph) instead of cross-fading.
        let firstContainsZoom = workspace.zoomedPaneId.map { first.contains(paneId: $0) } ?? false
        let secondContainsZoom = !firstContainsZoom
            && (workspace.zoomedPaneId.map { second.contains(paneId: $0) } ?? false)
        let fraction: Double = {
            if firstContainsZoom { return 1.0 }
            if secondContainsZoom { return 0.0 }
            return storedFraction
        }()
        let isZoomedAcrossThisSplit = firstContainsZoom || secondContainsZoom
        return AnyView(
            GeometryReader { geo in
                let total: CGFloat = orientation == .horizontal ? geo.size.width : geo.size.height
                let usable = max(total - Self.dividerThickness, 0)
                let firstSize = max(0, usable * fraction)
                let secondSize = max(0, usable - firstSize)
                let handleOffset = firstSize - Self.handleHitSize / 2 + Self.dividerThickness / 2
                // Divider + handle hide during zoom-collapse so the
                // collapsed side doesn't leave a 1pt hairline at the edge
                // and the user can't accidentally drag an invisible handle.
                let chromeVisible: Double = isZoomedAcrossThisSplit ? 0 : 1

                // "Push" the non-zoomed side off the workspace edge while
                // the zoomed side grows to fill — visually reads as
                // "shoving the other pane out" instead of "collapsing in
                // place". Offset magnitude = full split dimension so the
                // pane is fully off-edge by animation end; `.clipped()`
                // hides anything that sticks out during the transition.
                let firstPushX: CGFloat = orientation == .horizontal && secondContainsZoom ? -geo.size.width : 0
                let secondPushX: CGFloat = orientation == .horizontal && firstContainsZoom ? geo.size.width : 0
                let firstPushY: CGFloat = orientation == .vertical && secondContainsZoom ? -geo.size.height : 0
                let secondPushY: CGFloat = orientation == .vertical && firstContainsZoom ? geo.size.height : 0

                ZStack(alignment: orientation == .horizontal ? .leading : .top) {
                    if orientation == .horizontal {
                        HStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store)
                                .frame(width: firstSize)
                                .offset(x: firstPushX, y: firstPushY)
                                .clipped()
                            Rectangle().fill(Theme.chromeHairline)
                                .frame(width: Self.dividerThickness)
                                .opacity(chromeVisible)
                            PaneTreeView(node: second, workspace: workspace, store: store)
                                .frame(width: secondSize)
                                .offset(x: secondPushX, y: secondPushY)
                                .clipped()
                        }
                        DividerHandle(orientation: .horizontal)
                            .frame(width: Self.handleHitSize, height: geo.size.height)
                            .offset(x: handleOffset, y: 0)
                            .opacity(chromeVisible)
                            .allowsHitTesting(!isZoomedAcrossThisSplit)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    } else {
                        VStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store)
                                .frame(height: firstSize)
                                .offset(x: firstPushX, y: firstPushY)
                                .clipped()
                            Rectangle().fill(Theme.chromeHairline)
                                .frame(height: Self.dividerThickness)
                                .opacity(chromeVisible)
                            PaneTreeView(node: second, workspace: workspace, store: store)
                                .frame(height: secondSize)
                                .offset(x: secondPushX, y: secondPushY)
                                .clipped()
                        }
                        DividerHandle(orientation: .vertical)
                            .frame(width: geo.size.width, height: Self.handleHitSize)
                            .offset(x: 0, y: handleOffset)
                            .opacity(chromeVisible)
                            .allowsHitTesting(!isZoomedAcrossThisSplit)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    }
                }
                .clipped()
                .onDisappear {
                    // Teardown backstop for the divider-drag suspend. `onEnded` is
                    // the normal un-suspend, but if this split is torn down MID-drag
                    // (workspace switch's `.id` rebuild, or a pane close collapsing
                    // the split) onEnded never fires and the subtree's engines would
                    // stay `suspendsSizePropagation == true` — silently degrading
                    // their per-frame resize propagation until some later force-push
                    // push, so no flush needed). A normal fraction change keeps this
                    // view's identity, so this only fires on a real removal. `end` the
                    // captured engines (not a re-walk) so the refcount stays balanced.
                    if dividerResizeSuspended {
                        dividerResizeSuspended = false
                        for engine in dividerSuspendedEngines { engine.endSizePropagationSuspension() }
                        dividerSuspendedEngines = []
                    }
                }
                // Animation now driven by `withAnimation(Theme.chromeTransition)`
                // at the toggle call sites — that propagates to the outer
                // PaneStatusBar visibility too, so the chrome row that
                // hosts the zoom button can animate in/out together with
                // the split-tree morph.
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
                // A real fraction change re-lays out every pane under this split on
                // each frame → a SIGWINCH-per-frame burst (conda scrollback-wipe /
                // prompt flicker, issue #29). This is a SwiftUI drag, not a window
                // live-resize, so setFrameSize's inLiveResize defer doesn't cover
                // it — suspend size propagation on the subtree's engines for the
                // drag, then flush once on release (mirrors pane zoom / status-bar
                // height). Background tabs share the pane's NSView geometry, so
                // suspend every tab's engine. begin once per drag (gated), capturing
                // the engines so onEnded/onDisappear end the SAME set (balanced).
                if !dividerResizeSuspended {
                    dividerResizeSuspended = true
                    dividerSuspendedEngines = node.allPanes.flatMap { $0.tabs.map(\.engine) }
                    for engine in dividerSuspendedEngines { engine.beginSizePropagationSuspension() }
                }
                node.content = .split(orientation: orient, first: f, second: s, fraction: clamped)
            }
            .onEnded { _ in
                dragStartFraction = nil
                // End the suspension + push each engine's final size once. Flush only
                // when the engine's count hits 0 (a concurrent zoom / status-bar
                // suspension on the same engine will flush when ITS end releases it).
                if dividerResizeSuspended {
                    dividerResizeSuspended = false
                    for engine in dividerSuspendedEngines {
                        engine.endSizePropagationSuspension()
                        if !engine.suspendsSizePropagation { engine.flushSize() }
                    }
                    dividerSuspendedEngines = []
                }
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
