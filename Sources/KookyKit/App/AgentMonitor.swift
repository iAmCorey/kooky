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
        /// Control-plane freshness for Mosh. Kept separate from Agent state:
        /// stale never means idle or ended.
        let remoteConnectionLabel: String?
        /// Stable transport/cwd metadata for remote rows. Unlike `directory`,
        /// these values describe the remote machine and are safe to display.
        let remoteTransportLabel: String?
        let remoteDirectory: String?
        /// The tag of the WORKSPACE this session lives in — sessions aren't
        /// tagged individually, so every agent in a tagged project carries that
        /// project's colour. That's what turns the stripe into project grouping
        /// for a list whose order is purely by state.
        let tag: WorkspaceTag?

        init(
            id: UUID,
            agent: AgentTemplate,
            state: State,
            tabTitle: String,
            directory: URL,
            remoteHost: String?,
            remoteConnectionLabel: String? = nil,
            remoteTransportLabel: String? = nil,
            remoteDirectory: String? = nil,
            tag: WorkspaceTag?
        ) {
            self.id = id
            self.agent = agent
            self.state = state
            self.tabTitle = tabTitle
            self.directory = directory
            self.remoteHost = remoteHost
            self.remoteConnectionLabel = remoteConnectionLabel
            self.remoteTransportLabel = remoteTransportLabel
            self.remoteDirectory = remoteDirectory
            self.tag = tag
        }

        /// Stable location text used when a compact surface needs the actual
        /// project path. Remote sessions name the host because their local
        /// workspace path would be misleading.
        var locationPathLabel: String {
            if let remoteHost {
                let prefix = remoteTransportLabel ?? "ssh"
                if let remoteDirectory, !remoteDirectory.isEmpty {
                    return "\(prefix) \(remoteHost):\(remoteDirectory)"
                }
                return "\(prefix) \(remoteHost)"
            }
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
            var lines = [head]
            if let label = tag?.hashLabel { lines.append(label) }
            lines.append(locationLabel)
            if let remoteConnectionLabel { lines.append(remoteConnectionLabel) }
            return lines.joined(separator: "\n")
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
                remoteHost: item.session.workspaceTransport.remoteDestination ?? item.session.remoteHost,
                remoteConnectionLabel: Self.remoteConnectionLabel(for: item.session),
                remoteTransportLabel: item.session.workspaceTransport.isRemote
                    ? item.session.workspaceTransport.label.lowercased()
                    : nil,
                remoteDirectory: item.session.remoteWorkingDirectory,
                tag: item.workspace.tag
            )
        }
        .sorted { $0.state < $1.state }
    }

    private static func state(of session: Session) -> State {
        if session.activityState == .attention { return .attention }
        if let exit = session.lastCommandExit, exit != 0 { return .failed }
        if session.activityState == .running { return .running }
        return .idle
    }

    private static func remoteConnectionLabel(for session: Session) -> String? {
        guard case .mosh = session.workspaceTransport else { return nil }
        switch session.remoteConnectionState {
        case .launching:
            return "mosh · connecting"
        case .connected:
            return "mosh · status connected"
        case .degraded(let since, _):
            let seconds = max(0, Int(Date().timeIntervalSince(since)))
            return "mosh · status stale for \(seconds)s"
        case .authenticationRequired(let since):
            let seconds = max(0, Int(Date().timeIntervalSince(since)))
            return "mosh · ssh authentication required for \(seconds)s"
        case .disconnected:
            return "mosh · ended"
        case .failed:
            return "mosh · failed"
        case nil:
            return nil
        }
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
            let session = item.session
            if session.remoteHost != nil { return true }
            if case .mosh = session.workspaceTransport {
                switch session.remoteConnectionState {
                case .launching:
                    return true
                case .connected:
                    if !session.displayAgent.isShell && session.activityState == .running {
                        return true
                    }
                case .degraded, .authenticationRequired:
                    break
                case .disconnected, .failed, nil:
                    return false
                }
                if let renewed = session.remotePowerLeaseUpdatedAt,
                   Date().timeIntervalSince(renewed) < 15 * 60 {
                    return true
                }
            }
            return !session.displayAgent.isShell && session.activityState == .running
        }
    }
}

/// `Theme.activity*` is @MainActor; resolve the per-state accent here so both
/// the full and compact rows share one mapping.
@MainActor
private func agentAccent(_ state: AgentMonitor.State) -> Color {
    switch state {
    case .attention: return Theme.activityAttention
    case .failed: return Theme.activityFailure
    case .running: return Theme.activityRunning
    case .idle: return Theme.chromeMuted.opacity(0.6)
    }
}

// MARK: - Right sidebar

/// Shared 32pt title row + hairline for the right panel's two pages, so
/// "agents" and "session history" stay pixel-identical by construction.
/// The height matches the top strip so left/right chrome aligns.
struct RightPanelHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(LocalizedStringKey(title), bundle: .kookyResources)
                    .font(Theme.mono(13, weight: .semibold))
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
            .frame(height: 32)
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
        }
    }
}

extension RightPanelHeader where Trailing == EmptyView {
    init(title: String, count: Int) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Shared empty placeholder for the right panel's two pages.
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
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }
}

struct AgentOverviewSidebar: View {
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
    }

    // Full: content (live agents or session history) + the footer toggle.
    // Compact never shows the footer — a 44pt rail can't host the history
    // list, so it pins to the agents rail (mirrors the left sidebar's
    // full-mode-only files toggle).
    private var fullBody: some View {
        VStack(spacing: 0) {
            if store.rightSidebarContent == .history {
                SessionHistoryView(store: store)
            } else {
                agentsBody
            }
            footer
        }
        .frame(width: 230)
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
        Rectangle().fill(Theme.chromeHairline).frame(height: 1)
        HStack(spacing: 2) {
            footerSegment(.agents, systemName: "sparkles", help: "Agents")
            footerSegment(.history, systemName: "clock", help: "Session History")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, Theme.space1)
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
        .frame(width: 44)
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
                    .font(Theme.mono(12, weight: .medium))
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
                .font(Theme.mono(9.5, weight: .medium))
                .foregroundStyle(entry.state == .idle ? Theme.chromeMuted.opacity(0.7) : agentAccent(entry.state))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background((isHovered ? Theme.chromeHover : Color.clear).workspaceTagStripe(shownTag))
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
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .help(entry.hoverText(tag: shownTag))
    }

    private var shownTag: WorkspaceTag? { showTags ? entry.tag : nil }
}
