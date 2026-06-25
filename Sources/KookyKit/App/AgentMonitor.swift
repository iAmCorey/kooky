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

        var label: String {
            switch self {
            case .attention: return "waiting"
            case .failed: return "failed"
            case .running: return "running"
            case .idle: return "idle"
            }
        }
        var help: String {
            switch self {
            case .attention: return "waiting on you"
            case .failed: return "command failed"
            case .running: return "running"
            case .idle: return "idle"
            }
        }
    }

    struct Entry: Identifiable {
        let id: UUID            // sessionId
        let agent: AgentTemplate
        let state: State
        let tabTitle: String
    }

    /// Every non-shell agent session across all windows, neediest first. A
    /// `Session` reverts to `.terminal` (a shell) when its agent ends, so an
    /// ended agent naturally drops off — this is "agents alive right now".
    var entries: [Entry] {
        _ = windowGeneration   // re-aggregate when the window set changes
        return storesProvider().flatMap { store in
            store.workspaces.flatMap { workspace in
                workspace.root.allPanes.flatMap { pane in
                    pane.tabs.compactMap { session -> Entry? in
                        let agent = session.displayAgent
                        guard !agent.isShell else { return nil }
                        return Entry(
                            id: session.id,
                            agent: agent,
                            state: Self.state(of: session),
                            tabTitle: session.title
                        )
                    }
                }
            }
        }
        .sorted { $0.state < $1.state }
    }

    private static func state(of session: Session) -> State {
        if session.activityState == .attention { return .attention }
        if let exit = session.lastCommandExit, exit != 0 { return .failed }
        if session.activityState == .running { return .running }
        return .idle
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

struct AgentOverviewSidebar: View {
    var monitor = AgentMonitor.shared
    /// `.full` or `.compact` — `.hidden` never renders (`ContentView` gates it),
    /// mirroring the left sidebar's three collapse modes.
    let mode: SidebarMode

    var body: some View {
        Group {
            if mode == .compact { compactBody } else { fullBody }
        }
        .glassChromeBackground()
    }

    // Full: header + labelled rows.
    private var fullBody: some View {
        let entries = monitor.entries   // aggregate once per render, not per read
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("agents")
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.chromeForeground)
                if !entries.isEmpty {
                    Text("\(entries.count)")
                        .font(Theme.mono(10, weight: .medium))
                        .foregroundStyle(Theme.chromeMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)   // matches the top strip so left/right align
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if entries.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            AgentOverviewRow(entry: entry)
                                .onTapGesture { monitor.onActivate(entry.id) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 230)
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.chromeMuted.opacity(0.4))
            Text("no agents running")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }

    // Compact: a narrow rail of status-tinted agent icons; hover for detail.
    private var compactBody: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(monitor.entries) { entry in
                    AgentOverviewCompactRow(entry: entry)
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
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(asset: entry.agent.iconAsset, fallbackSymbol: entry.agent.symbol, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.agent.title)
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                Text(entry.tabTitle)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            // The colored state word does the work the left accent bar used to.
            Text(entry.state.label)
                .font(Theme.mono(9.5, weight: .medium))
                .foregroundStyle(entry.state == .idle ? Theme.chromeMuted.opacity(0.7) : agentAccent(entry.state))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(isHovered ? Theme.chromeHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct AgentOverviewCompactRow: View {
    let entry: AgentMonitor.Entry
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
            .background(isHovered ? Theme.chromeHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .help("\(entry.agent.title) · \(entry.tabTitle) · \(entry.state.help)")
    }
}
