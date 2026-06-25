import AppKit
import SwiftUI

extension ToolCallEventState {
    /// Visual + accessibility tokens for a tool-call state. One switch
    /// (here) instead of four scattered across the pill and the history
    /// popover — adding a 5th state (e.g. `.cancelled`) is a single edit.
    /// `@MainActor` because the `Theme` colors are `@MainActor`-isolated
    /// (terminal theme picker is a UI-thread observable).
    struct Presentation {
        let textColor: Color
        let glyphColor: Color
        let glyph: String
        let accessibleName: String
    }

    @MainActor
    var presentation: Presentation {
        switch self {
        case .running:
            return Presentation(
                textColor: Theme.activityRunning,
                glyphColor: Theme.activityRunning,
                glyph: "⋯",  // ASCII ellipsis (no ProgressView surface)
                accessibleName: "running"
            )
        case .success:
            return Presentation(
                textColor: Theme.chromeForeground,
                glyphColor: Theme.gitInsertion,  // DRY reuse — same green as git diff
                glyph: "✓",
                accessibleName: "succeeded"
            )
        case .failed:
            return Presentation(
                textColor: Theme.activityFailure,
                glyphColor: Theme.activityFailure,
                glyph: "✗",
                accessibleName: "failed"
            )
        case .stalled:
            return Presentation(
                textColor: Theme.chromeMuted,
                glyphColor: Theme.chromeMuted,
                glyph: "⊘",
                accessibleName: "stalled"
            )
        }
    }
}

/// SwiftUI Text that refreshes once per second while `event.state == .running`
/// (so the pill's duration label actually ticks instead of freezing on first
/// render). Completed / stalled / failed events have a stable `completedAt`,
/// so no TimelineView wrap is needed — they render as plain Text.
private struct LiveDurationText: View {
    let event: ToolCallEvent

    var body: some View {
        if event.state == .running, event.completedAt == nil {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(ToolCallActivityPill.formatElapsed(context.date.timeIntervalSince(event.startedAt)))
                    .font(Theme.mono(11, weight: .regular))
                    .foregroundStyle(event.state.presentation.textColor)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            Text(ToolCallActivityPill.durationLabel(for: event))
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(event.state.presentation.textColor)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Compact tool-call pill rendered as the leftmost segment of `PaneStatusBar`
/// when a Claude / Claude-base agent is active. Shows the latest tool-call
/// event (4 visual states); click → popover with the full 200-event history
/// + counter header. Lives inside the existing status bar row rather than
/// adding its own chrome row — visual density feedback during M5.xxx
/// implementation showed two stacked bars felt cluttered, so the summary
/// moves to the popover header and only the latest call shows in the bar.
struct ToolCallActivityPill: View {
    @Bindable var session: Session
    @State private var historyOpen = false

    var body: some View {
        Button { historyOpen = true } label: {
            pillContent
        }
        .buttonStyle(.plain)
        .popover(isPresented: $historyOpen, arrowEdge: .top) {
            ToolCallHistoryPopover(session: session)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// `ViewThatFits` picks the widest variant whose ideal size fits the
    /// available width. Each variant uses `.fixedSize(horizontal: true)`
    /// on Text so the ideal size reflects the real content length —
    /// without it, `.lineLimit(1).truncationMode(.middle)` would let every
    /// variant claim it "fits" by shrinking, and VTF would always pick L0.
    @ViewBuilder
    private var pillContent: some View {
        if let last = session.toolCallEvents.last {
            ViewThatFits(in: .horizontal) {
                fullPill(for: last)
                noToolNamePill(for: last)
                iconOnlyPill(for: last)
            }
        } else {
            waitingPill
        }
    }

    // MARK: Variants (widest → narrowest)

    private func fullPill(for event: ToolCallEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon(for: event)
            Text(event.toolName)
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(event.state.presentation.textColor)
                .fixedSize(horizontal: true, vertical: false)
            separator
            Text(event.identifier.isEmpty ? "—" : event.identifier)
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(event.state.presentation.textColor)
                .fixedSize(horizontal: true, vertical: false)
            separator
            duration(for: event)
            glyph(for: event)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(border)
    }

    private func noToolNamePill(for event: ToolCallEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon(for: event)
            Text(event.identifier.isEmpty ? "—" : event.identifier)
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(event.state.presentation.textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
            separator
            duration(for: event)
            glyph(for: event)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(border)
    }

    private func iconOnlyPill(for event: ToolCallEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            icon(for: event)
            glyph(for: event)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay(border)
    }

    private var waitingPill: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "hourglass")
                .imageScale(.small)
                .foregroundStyle(Theme.chromeMuted)
            Text("waiting")
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(Theme.chromeMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(border)
    }

    // MARK: Sub-views

    private func icon(for event: ToolCallEvent) -> some View {
        Image(systemName: Self.toolIcon(event.toolName))
            .imageScale(.small)
            .foregroundStyle(Theme.chromeMuted)
    }

    private func duration(for event: ToolCallEvent) -> some View {
        LiveDurationText(event: event)
    }

    private func glyph(for event: ToolCallEvent) -> some View {
        Text(event.state.presentation.glyph)
            .font(Theme.mono(11, weight: .medium))
            .foregroundStyle(event.state.presentation.glyphColor)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 4).stroke(Theme.chromeFaint, lineWidth: 1)
    }

    private var separator: some View {
        Text("·").foregroundStyle(Theme.chromeFaint)
    }

    // MARK: Pure helpers (also used by popover row + tests)

    static func toolIcon(_ toolName: String) -> String {
        // Lowercase the match so Pi's native lowercase tool names (bash /
        // read / edit / grep / find / ls) hit the same icons as Claude's
        // capitalized ones — and add Pi's find / ls which Claude lacks.
        switch toolName.lowercased() {
        case "bash":                       return "terminal"
        case "edit", "write", "multiedit": return "pencil"
        case "read":                       return "doc.text"
        case "notebookedit":               return "book"
        case "glob", "grep", "find":       return "magnifyingglass"
        case "ls":                         return "list.bullet"
        case "webfetch", "websearch":      return "globe"
        case "task":                       return "rectangle.stack"
        default:                           return "questionmark.app"
        }
    }

    // stateGlyph moved to ToolCallEventState.presentation.glyph — call via
    // `event.state.presentation.glyph`. The static remains as a forwarder
    // for any tests still pinning the public surface.
    static func stateGlyph(for event: ToolCallEvent) -> String {
        event.state.presentation.glyph
    }

    static func durationLabel(for event: ToolCallEvent) -> String {
        let elapsed: TimeInterval = event.completedAt.map { $0.timeIntervalSince(event.startedAt) }
            ?? Date().timeIntervalSince(event.startedAt)
        return formatElapsed(elapsed)
    }

    static func formatElapsed(_ elapsed: TimeInterval) -> String {
        if elapsed < 1 {
            return String(format: "%.1fs", elapsed)
        } else if elapsed < 60 {
            return String(format: "%.0fs", elapsed)
        }
        // Roll minutes into hours and hours into days so a long-lived span
        // (the popover's total measures from the oldest retained tool call, so
        // an all-day tab can reach hours/days) reads as `1:05:09` / `2d 3:04:05`
        // instead of an ever-growing raw minute count like `3000:00`.
        let total = Int(elapsed)
        let secs = total % 60
        let mins = (total / 60) % 60
        let hours = (total / 3600) % 24
        let days = total / 86400
        if total < 3600 {
            return "\(mins):\(String(format: "%02d", secs))"
        } else if total < 86400 {
            return "\(hours):\(String(format: "%02d", mins)):\(String(format: "%02d", secs))"
        }
        return "\(days)d \(hours):\(String(format: "%02d", mins)):\(String(format: "%02d", secs))"
    }

    struct ToolCounts: Equatable {
        let bash: Int
        let edit: Int
        let read: Int
        let other: Int
    }

    static func toolCounts(in events: [ToolCallEvent]) -> ToolCounts {
        var bash = 0, edit = 0, read = 0, other = 0
        for event in events {
            // Lowercased so Pi's lowercase tool names bucket with Claude's.
            switch event.toolName.lowercased() {
            case "bash":                       bash += 1
            case "edit", "write", "multiedit": edit += 1
            case "read":                       read += 1
            default:                           other += 1
            }
        }
        return ToolCounts(bash: bash, edit: edit, read: read, other: other)
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        guard let last = session.toolCallEvents.last else {
            return "Waiting for Claude tool calls"
        }
        let identifierLabel = last.identifier.isEmpty ? "no identifier" : last.identifier
        return "\(last.toolName), \(identifierLabel), \(Self.durationLabel(for: last)), \(last.state.presentation.accessibleName)"
    }
}

/// Scrollable history popover anchored to `ToolCallActivityPill`. Top row
/// is the session summary (per-kind counters + elapsed); below is the
/// rolling 200-event list, newest first. Matches the brutalist vocabulary:
/// mono font, 1pt hairline rows, sharp corners, chrome-tinted background.
private struct ToolCallHistoryPopover: View {
    @Bindable var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if session.toolCallEvents.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.toolCallEvents.reversed()) { event in
                            row(for: event)
                            if event.id != session.toolCallEvents.first?.id {
                                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 520, height: 360)
        .glassChromeBackground()
    }

    private var header: some View {
        let counts = ToolCallActivityPill.toolCounts(in: session.toolCallEvents)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            counterSegment(icon: "terminal", count: counts.bash, label: "Bash")
            counterSegment(icon: "pencil", count: counts.edit, label: "Edit")
            counterSegment(icon: "doc.text", count: counts.read, label: "Read")
            if counts.other > 0 {
                counterSegment(icon: "ellipsis", count: counts.other, label: "Other")
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "clock")
                    .imageScale(.small)
                    .foregroundStyle(Theme.chromeMuted)
                Text(sessionElapsedLabel)
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func counterSegment(icon: String, count: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(Theme.chromeMuted)
            Text("\(count)")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
            Text(label)
                .font(Theme.mono(10, weight: .regular))
                .foregroundStyle(Theme.chromeMuted)
        }
        .accessibilityLabel("\(label) count: \(count)")
    }

    private var sessionElapsedLabel: String {
        guard let first = session.toolCallEvents.first else { return "—" }
        let end: Date
        if session.toolCallEvents.contains(where: { $0.state == .running }) {
            end = Date()
        } else {
            end = session.toolCallEvents.compactMap(\.completedAt).max() ?? Date()
        }
        return ToolCallActivityPill.formatElapsed(end.timeIntervalSince(first.startedAt))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "hourglass")
                .imageScale(.medium)
                .foregroundStyle(Theme.chromeMuted)
            Text("waiting for tool calls")
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(Theme.chromeMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private func row(for event: ToolCallEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ToolCallActivityPill.toolIcon(event.toolName))
                .imageScale(.small)
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 14)
            Text(event.toolName)
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(event.state.presentation.textColor)
                .frame(width: 64, alignment: .leading)
            Text(event.identifier.isEmpty ? "—" : event.identifier)
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(event.state.presentation.textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ToolCallActivityPill.durationLabel(for: event))
                .font(Theme.mono(11, weight: .regular))
                .foregroundStyle(event.state.presentation.textColor)
                .frame(width: 56, alignment: .trailing)
            Text(event.state.presentation.glyph)
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(event.state.presentation.glyphColor)
                .frame(width: 14)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func textColor(for event: ToolCallEvent) -> Color {
        event.state.presentation.textColor
    }

    private func glyphColor(for event: ToolCallEvent) -> Color {
        event.state.presentation.glyphColor
    }
}

/// Visibility predicate. Pill is Claude-only (per /plan-eng-review D4)
/// and shows between SessionStart and SessionEnd (per /plan-design-review
/// D2 choice C — `activityState != .idle` is the proxy since lifecycle
/// hooks already flip it both ways). Also respects Settings → Status Bar:
/// the user can hide the pill via the `toolCallActivity` kind even on a
/// Claude tab.
@MainActor
func showToolCallActivityPill(for session: Session) -> Bool {
    // Visibility is fully governed by `sessionWantsToolCallActivity` now that
    // the pill has a per-agent Settings toggle (`hiddenToolCallAgents`) rather
    // than one master `.toolCallActivity` switch — the per-agent check lives
    // there because it keys off the session's agent.
    return sessionWantsToolCallActivity(session)
}
