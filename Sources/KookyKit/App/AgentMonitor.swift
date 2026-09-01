import AppKit
import SwiftUI

// MARK: - Model

/// App-level (cross-window) live view of every running agent — the data behind
/// the right-side agent overview sidebar. Mirrors `NotificationInbox`: a
/// `@MainActor @Observable` singleton. But it's a *derived* view, not a store —
/// `entries` aggregates the agent sessions across every window's
/// `WorkspaceStore` on read, so SwiftUI's observation of each `Session`'s
/// `activityState` / `lastCommandExit` drives the re-render with no manual push.
@MainActor
@Observable
final class AgentMonitor {
    static let shared = AgentMonitor()
    /// `internal` (not `private`) so tests can build an isolated instance.
    init() {}

    /// Every live window's store. Injected by `AppDelegate` (it owns the set).
    var storesProvider: @MainActor () -> [WorkspaceStore] = { [] }
    /// Jump to a session's tab (cross-window). Injected by `AppDelegate` —
    /// reuses the notification center's reveal seam.
    var onActivate: @MainActor (UUID) -> Void = { _ in }

    /// Bumped by `AppDelegate` when a window is added or removed. `entries`
    /// reads it so the sidebar re-aggregates over the new window set. Same-window
    /// agent changes already drive re-render via each `Session`'s observation,
    /// but a brand-new window's sessions aren't in the tracked set until we
    /// re-walk — this forces that walk.
    var windowGeneration = 0

    /// Sort priority — declaration order is "neediest first". `Comparable` is
    /// synthesized from that order, so no raw values / manual `<` are needed.
    enum State: Comparable {
        case attention   // waiting on you
        case failed      // last command exited non-zero
        case running     // working
        case idle        // alive but quiet

        @MainActor
        var label: String {
            let key: String
            switch self {
            case .attention: key = "waiting"
            case .failed: key = "failed"
            case .running: key = "running"
            case .idle: key = "idle"
            }
            return String(
                localized: String.LocalizationValue(key),
                bundle: .kookyResources
            )
        }
        @MainActor
        var help: String {
            let key: String
            switch self {
            case .attention: key = "waiting on you"
            case .failed: key = "command failed"
            case .running: key = "running"
            case .idle: key = "idle"
            }
            return String(
                localized: String.LocalizationValue(key),
                bundle: .kookyResources
            )
        }
    }

    struct Entry: Identifiable {
        let id: UUID            // sessionId
        let agent: AgentTemplate
        let state: State
        let tabTitle: String
        /// The WORKSPACE's directory, not the session's live cwd. This line
        /// answers "which project", and a `cd` into a subdirectory would
        /// otherwise rename the row — head truncation keeps the deepest
        /// components, so the project name is the first thing it drops.
        let directory: URL
        /// Non-nil when the agent runs on a remote host. `directory` is then
        /// the LOCAL directory the connection was opened from: libghostty
        /// discards OSC 7 from a non-local host ("OSC 7 host must be local"),
        /// so a remote shell's cwd never reaches us and naming it would point
        /// at the wrong machine entirely.
        let remoteHost: String?
        /// The tag of the WORKSPACE this session lives in — sessions aren't
        /// tagged individually, so every agent in a tagged project carries that
        /// project's colour. That's what turns the stripe into project grouping
        /// for a list whose order is purely by state.
        let tag: WorkspaceTag?

        /// Stable location text used when a compact surface needs the actual
        /// project path. Remote sessions name the host because their local
        /// workspace path would be misleading.
        var locationPathLabel: String {
            if let remoteHost { return "ssh \(remoteHost)" }
            return (directory.path as NSString).abbreviatingWithTildeInPath
        }

        /// Second line of the full row. Nothing else on the row says where a
        /// session lives, and this list is flat across every window — a row's
        /// position tells you nothing about its project. Falls back to naming
        /// the agent when the location would only repeat line 1: a session
        /// with no reported title is named after its own directory, and in
        /// `$HOME` both sides render as `~`.
        var locationLabel: String {
            let label = locationPathLabel
            return label == tabTitle ? agent.title : label
        }

        /// Hover text, shared by both row shapes. The compact rail is
        /// icon-only, so there it *is* the row's content; the full row's 230pt
        /// column is fixed and can't be dragged wider, so a truncated title or
        /// location has nowhere else to be read, and the agent's name is on
        /// the row only as an icon.
        /// Takes the tag the row is actually showing rather than reading
        /// `self.tag`, so the setting that hides the stripe hides the `#name`
        /// with it — the caller resolves that once and both follow.
        @MainActor
        func hoverText(tag: WorkspaceTag?) -> String {
            let head = "\(singleLine(agent.title)) · \(singleLine(tabTitle)) · \(state.help)"
            guard let label = tag?.hashLabel else { return "\(head)\n\(locationLabel)" }
            return "\(head)\n\(label)\n\(locationLabel)"
        }
    }

    /// Every non-shell agent session across all windows, neediest first. A
    /// `Session` reverts to `.terminal` (a shell) when its agent ends, so an
    /// ended agent naturally drops off — this is "agents alive right now".
    var entries: [Entry] {
        sessionsWithWorkspace.compactMap { item -> Entry? in
            let agent = item.session.displayAgent
            guard !agent.isShell else { return nil }
            return Entry(
                id: item.session.id,
                agent: agent,
                state: Self.state(of: item.session),
                tabTitle: item.session.title,
                directory: item.workspace.diskPath,
                remoteHost: item.session.effectiveRemoteHost,
                tag: item.workspace.tag
            )
        }
        .sorted { $0.state < $1.state }
    }

    /// `internal` so the Session Info inspector reports a tab's state with the
    /// same words and colors the agents list gives it — two derivations would
    /// drift the moment a state is added.
    static func state(of session: Session) -> State {
        if session.activityState == .attention { return .attention }
        if let exit = session.lastCommandExit, exit != 0 { return .failed }
        if session.activityState == .running { return .running }
        return .idle
    }

    /// True when any session is actively working — an agent running, or a
    /// live SSH conversation (`remoteHost`: set by the login marker, cleared
    /// by the wrapper's logout marker, so it spans the whole connection).
    /// SleepGuard's busy input. A short-circuiting walk on purpose, NOT
    /// `entries`: entries allocates, sorts, and reads every session's
    /// `title` (cwd-derived), which would both waste work and re-fire
    /// observers on every cd / OSC title update.
    /// The one four-level walk under `entries` / `activeAgentCount` /
    /// `hasActiveWork`. Lazy, so `contains` still short-circuits and each
    /// consumer's closure alone decides which session fields enter its
    /// observation set; the `windowGeneration` dependency registers here
    /// once for all three.
    private var sessionsWithWorkspace: some Sequence<(session: Session, workspace: Workspace)> {
        _ = windowGeneration   // re-walk when the window set changes
        return storesProvider().lazy.flatMap { store in
            store.workspaces.lazy.flatMap { workspace in
                workspace.root.allPanes.lazy.flatMap { pane in
                    pane.tabs.lazy.map { (session: $0, workspace: workspace) }
                }
            }
        }
    }

    /// Count-only companion to `entries` for the menu bar. Reads ONLY the
    /// membership field (`displayAgent`), so a title / cwd / state change on
    /// a session doesn't re-fire the menu bar's observation the way the full
    /// `entries` read would (same reasoning as `hasActiveWork`).
    var activeAgentCount: Int {
        sessionsWithWorkspace.count { !$0.session.displayAgent.isShell }
    }

    /// True when any session is actively working — an agent running, or a
    /// live SSH conversation (`remoteHost`: set by the login marker, cleared
    /// by the wrapper's logout marker, so it spans the whole connection).
    /// SleepGuard's busy input. A short-circuiting walk on purpose, NOT
    /// `entries`: entries allocates, sorts, and reads every session's
    /// `title` (cwd-derived), which would both waste work and re-fire
    /// observers on every cd / OSC title update.
    var hasActiveWork: Bool {
        return sessionsWithWorkspace.contains { item in
            item.session.remoteHost != nil
                || (!item.session.displayAgent.isShell && item.session.activityState == .running)
        }
    }
}

/// `Theme.activity*` is @MainActor; resolve the per-state accent here so the
/// full row, the compact rail, and the Session Info inspector share one mapping.
@MainActor
func agentAccent(_ state: AgentMonitor.State) -> Color {
    switch state {
    case .attention: return Theme.activityAttention
    case .failed: return Theme.activityFailure
    case .running: return Theme.activityRunning
    case .idle: return Theme.chromeMuted.opacity(0.6)
    }
}

/// The state WORD's color — `agentAccent` with idle lifted to the slightly
/// brighter muted that text needs. The agents row and the Session Info
/// identity row both render this word; the exception lives here so it can't
/// fork between them (the compact rail's dot keeps raw `agentAccent`).
@MainActor
func agentStateWordColor(_ state: AgentMonitor.State) -> Color {
    state == .idle ? Theme.chromeMuted.opacity(0.7) : agentAccent(state)
}

// MARK: - Right sidebar

/// Shared title row + quiet divider for every right-panel page, so their headers
/// stay pixel-identical by construction. Its height
/// matches the pane tab strip and left sidebar header, forming one continuous
/// content baseline below the window drag strip.
struct RightPanelHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(LocalizedStringKey(title), bundle: .kookyResources)
                    .font(Theme.display(13.5, weight: .semibold))
                    .foregroundStyle(Theme.chromeForeground)
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.mono(10, weight: .medium))
                        .foregroundStyle(Theme.chromeMuted)
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.contentHeaderHeight)
            Rectangle().fill(Theme.chromeSeparator).frame(height: 1)
        }
    }
}

extension RightPanelHeader where Trailing == EmptyView {
    init(title: String, count: Int) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Shared empty placeholder for the right panel's pages.
struct PanelEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.chromeMuted.opacity(0.4))
            Text(LocalizedStringKey(message), bundle: .kookyResources)
                .font(Theme.display(11.5))
                .foregroundStyle(Theme.chromeMuted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }
}

struct AgentOverviewSidebar: View {
    static let fullWidth: CGFloat = 230
    static let compactWidth: CGFloat = 44

    /// Ceiling for the user-draggable full-mode width (`fullWidth` is the
    /// floor — the panel only grows from its design width). Mirrors
    /// `SidebarView.maxWidth`.
    static let maxWidth: CGFloat = 480

    /// Single source for the width policy — floor `fullWidth`, ceiling
    /// `maxWidth`, and whole points (mirrors `SidebarView.clampWidth`).
    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, fullWidth), maxWidth).rounded()
    }

    // Leading-edge resize drag (full mode only). Mirrors SidebarView's
    // trailing-edge gesture, mirrored horizontally: the handle sits on the
    // panel's LEFT edge, so dragging left (negative translation) widens it.
    // Same suspend pattern — a width drag re-frames every libghostty NSView
    // per frame → SIGWINCH storm without divider-style suspension.
    @State private var resizeDragStartWidth: CGFloat?
    @State private var sidebarResizeSuspended = false
    @State private var sidebarSuspendedEngines: [any TerminalEngine] = []

    let store: WorkspaceStore
    var monitor = AgentMonitor.shared
    /// Reading the model here registers the observation, so flipping the
    /// setting re-renders the panel live.
    private var showTags: Bool { KookySettingsModel.shared.showAgentPanelTag }
    /// `.full` or `.compact` — `.hidden` never renders (`ContentView` gates it),
    /// mirroring the left sidebar's three collapse modes.
    let mode: SidebarMode

    var body: some View {
        Group {
            if mode == .compact { compactBody } else { fullBody }
        }
        .glassChromeBackground()
        .overlay(alignment: .leading) {
            if mode != .compact { resizeHandle }
        }
    }

    private var resizeHandle: some View {
        DividerHandle(orientation: .horizontal)
            .frame(width: 7)
            .gesture(resizeGesture)
            .onDisappear {
                // Backstop: ⌘⌃S mid-drag unmounts the handle before onEnded
                // can fire — end the captured engines so the suspension
                // refcount stays balanced (mirrors the sidebar).
                resizeDragStartWidth = nil
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines { engine.endSizePropagationSuspension() }
                    sidebarSuspendedEngines = []
                }
                store.endSidebarResize()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if resizeDragStartWidth == nil {
                    resizeDragStartWidth = store.rightSidebarWidth
                    store.beginSidebarResize()
                }
                let proposed = (resizeDragStartWidth ?? store.rightSidebarWidth) - value.translation.width
                let clamped = Self.clampWidth(proposed)
                guard abs(clamped - store.rightSidebarWidth) > .ulpOfOne else { return }
                if !sidebarResizeSuspended {
                    sidebarResizeSuspended = true
                    sidebarSuspendedEngines = store.active?.root.allEngines ?? []
                    for engine in sidebarSuspendedEngines { engine.beginSizePropagationSuspension() }
                }
                store.rightSidebarWidth = clamped
            }
            .onEnded { _ in
                resizeDragStartWidth = nil
                // End + flush once — only when the engine's refcount hits 0
                // (a concurrent zoom / status-bar suspension flushes on ITS
                // own release).
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines {
                        engine.endSizePropagationSuspension()
                        if !engine.suspendsSizePropagation { engine.flushSize() }
                    }
                    sidebarSuspendedEngines = []
                }
                store.endSidebarResize()
                store.flushPersistence()
            }
    }

    // Full: selected page + the footer toggle.
    // Compact never shows the footer — a 44pt rail can't host the history
    // list, so it pins to the agents rail (mirrors the left sidebar's
    // full-mode-only files toggle).
    private var fullBody: some View {
        VStack(spacing: 0) {
            switch store.rightSidebarContent {
            case .agents:
                agentsBody
            case .history:
                SessionHistoryView(store: store)
            case .info:
                SessionInfoView(store: store)
            }
            footer
        }
        .frame(width: store.rightSidebarWidth)
    }

    private var agentsBody: some View {
        let entries = monitor.entries   // aggregate once per render, not per read
        return VStack(spacing: 0) {
            RightPanelHeader(title: "agents", count: entries.count)
            if entries.isEmpty {
                PanelEmptyState(symbol: "sparkles", message: "no agents running")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            AgentOverviewRow(entry: entry, showTags: showTags)
                                .onTapGesture { monitor.onActivate(entry.id) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var footer: some View {
        Rectangle().fill(Theme.chromeSeparator).frame(height: 1)
        HStack(spacing: Theme.chromeControlSpacing) {
            footerSegment(.agents, systemName: "sparkles", help: "Agents")
            footerSegment(.history, systemName: "clock", help: "Session History")
            footerSegment(.info, systemName: "info.circle", help: "Session Info")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.chromeBarEdgeInset)
        .padding(.vertical, Theme.chromeBottomBarVerticalPadding)
    }

    private func footerSegment(_ content: RightSidebarContent, systemName: String, help: String) -> some View {
        FooterSegment(
            systemName: systemName,
            isActive: store.rightSidebarContent == content,
            help: help
        ) {
            withAnimation(Theme.chromeTransition) {
                store.setRightSidebarContent(content)
            }
        }
    }

    // Compact: a narrow rail of status-tinted agent icons; hover for detail.
    private var compactBody: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(monitor.entries) { entry in
                    AgentOverviewCompactRow(entry: entry, showTags: showTags)
                        .onTapGesture { monitor.onActivate(entry.id) }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: Self.compactWidth)
    }
}

private struct AgentOverviewRow: View {
    let entry: AgentMonitor.Entry
    let showTags: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(asset: entry.agent.iconAsset, fallbackSymbol: entry.agent.symbol, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                // What this agent is working on leads: with several sessions of
                // the same agent running, it's the only line that differs.
                Text(entry.tabTitle)
                    .font(Theme.display(12.5, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                // Head truncation, matching the sidebar's own path subtitle:
                // the tail holds the project name.
                Text(entry.locationLabel)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            // The colored state word does the work the left accent bar used to.
            Text(entry.state.label)
                .font(Theme.display(10, weight: .medium))
                .foregroundStyle(agentStateWordColor(entry.state))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .background((isHovered ? Theme.chromeHover : Color.clear).workspaceTagStripe(shownTag))
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
        .padding(.horizontal, Theme.space2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(entry.hoverText(tag: shownTag))
    }

    /// The tag this row actually displays — nil once the panel's tag display is
    /// switched off, so the stripe and the tooltip can't disagree about it.
    private var shownTag: WorkspaceTag? { showTags ? entry.tag : nil }
}

private struct AgentOverviewCompactRow: View {
    let entry: AgentMonitor.Entry
    let showTags: Bool
    @State private var isHovered = false

    var body: some View {
        AgentIconView(asset: entry.agent.iconAsset, fallbackSymbol: entry.agent.symbol, size: 17)
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(agentAccent(entry.state))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Theme.chromeBackground, lineWidth: 1.5))
            }
            .background((isHovered ? Theme.chromeHover : Color.clear).workspaceTagStripe(shownTag))
            .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .help(entry.hoverText(tag: shownTag))
    }

    private var shownTag: WorkspaceTag? { showTags ? entry.tag : nil }
}
