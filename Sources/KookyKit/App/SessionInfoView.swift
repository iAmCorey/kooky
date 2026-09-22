import AppKit
import SwiftUI

/// Active-tab details for the right sidebar. The view reads the store's
/// active workspace, pane, and session directly so switching any of them
/// replaces the page immediately without a second selection model.
struct SessionInfoView: View {
    let store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            RightPanelHeader(title: "session info", count: 0)
            if let workspace = store.active,
               let session = workspace.activeSession {
                // The identity row is pinned above the scroll area, not inside
                // it: an inspector must keep saying whose data this is while
                // the fields scroll.
                identityRow(session)
                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                fields(session: session, workspace: workspace)
            } else {
                PanelEmptyState(symbol: "info.circle", message: "no active session")
                Spacer(minLength: 0)
            }
        }
    }

    /// Deliberately the same shape as an `AgentOverviewRow`: icon, title, then
    /// one muted line carrying the agent and its state. Landing here from the
    /// agents list should read as that row expanded, not as another component.
    private func identityRow(_ session: Session) -> some View {
        let state = AgentMonitor.state(of: session)
        // The agents row's shared word color, so an idle tab reads the same
        // weight here as it does there; the dot takes the word's color so the
        // pair reads as one mark.
        let accent = agentStateWordColor(state)
        return HStack(spacing: 10) {
            AgentIconView(
                asset: session.displayAgent.iconAsset,
                fallbackSymbol: session.displayAgent.symbol,
                size: 16
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: session.title)
                    .font(SessionInfo.titleFont)
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(verbatim: session.displayAgent.title)
                        .font(SessionInfo.labelFont)
                        .foregroundStyle(SessionInfo.labelText)
                        .lineLimit(1)
                    Circle()
                        .fill(accent)
                        .frame(width: 4, height: 4)
                    Text(state.label)
                        .font(SessionInfo.stateFont)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SessionInfo.gutter)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .help(session.title)
    }

    private func fields(session: Session, workspace: Workspace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SessionInfoSection(title: SessionInfoRules.contextTitle, store: store) {
                    InlineField(label: "Workspace", value: workspace.title)
                    BlockField(label: "Directory", value: abbreviatedPath(session.currentDirectory.path))
                    if let remote = session.effectiveRemoteHost {
                        InlineField(label: "Remote", value: remote)
                    }
                }

                if hasSourceInfo(session: session, workspace: workspace) {
                    SessionInfoSection(title: SessionInfoRules.sourceTitle, store: store) {
                        if let branch = session.gitStatus.branch {
                            InlineField(label: "Git branch", value: branch)
                        }
                        if let repoRoot = visibleRepoRoot(session) {
                            BlockField(label: "Git repo", value: abbreviatedPath(repoRoot))
                        }
                        if session.gitStatus.filesChanged > 0 {
                            GitDiffField(status: session.gitStatus)
                        }
                        // A worktree's branch and path already show above; what
                        // nothing else on this page says is that it IS one, and
                        // which workspace it was cut from.
                        if let parent = worktreeParent(of: workspace) {
                            InlineField(label: "Worktree of", value: parent.title)
                        }
                    }
                }

                if !session.environment.isEmpty {
                    SessionInfoSection(title: SessionInfoRules.environmentTitle, store: store) {
                        if let python = session.environment.pythonVenv {
                            InlineField(label: "Python venv", value: python)
                        }
                        if let node = session.environment.nodeVersion {
                            InlineField(label: "Node version", value: node)
                        }
                        if let proxy = session.environment.proxy {
                            InlineField(label: "Proxy", value: proxy.summary)
                        }
                    }
                }

                SessionProcessesSection(store: store, session: session)

                if hasRuntimeInfo(session) {
                    SessionInfoSection(title: SessionInfoRules.runtimeTitle, store: store) {
                        if let completed = session.lastCompletedCommand {
                            LastCommandField(
                                completed: completed,
                                askFix: askFix(session: session, workspace: workspace, completed: completed)
                            )
                        }
                        if let title = visibleTerminalTitle(session) {
                            BlockField(label: "Terminal title", value: title)
                        }
                    }
                }

                // No Identifiers section: `session.id` is only ever
                // `KOOKY_SURFACE_ID` for hook routing — nothing in kooky
                // accepts one, nothing logs one, and the shell already exposes
                // it. `conversationId`'s one real use (reaching the transcript
                // file, or resuming outside kooky) wants an action, not a UUID
                // to hand-select.
            }
            .padding(.bottom, Theme.space5)
        }
    }

    private func hasSourceInfo(session: Session, workspace: Workspace) -> Bool {
        SessionInfoRules.hasSourceInfo(session: session, worktreeParent: worktreeParent(of: workspace))
    }

    private func hasRuntimeInfo(_ session: Session) -> Bool {
        SessionInfoRules.hasRuntimeInfo(session)
    }

    private func visibleRepoRoot(_ session: Session) -> String? {
        SessionInfoRules.visibleRepoRoot(session)
    }

    private func visibleTerminalTitle(_ session: Session) -> String? {
        SessionInfoRules.visibleTerminalTitle(session)
    }

    private func worktreeParent(of workspace: Workspace) -> Workspace? {
        guard let parentId = workspace.worktreeParentId else { return nil }
        return store.workspaces.first { $0.id == parentId }
    }

    /// The one-click "hand this failure to an agent" affordance, or nil when
    /// it can't do its job (gates in `SessionInfoRules.askFixCommand`, plus
    /// "no agent installed/visible"). The prompt is built here, from the same
    /// snapshot the field renders, so what the agent receives is exactly what
    /// the row showed. Running remembers the pick (`lastAskAgentId`) so the
    /// plain click tracks the user's last choice, the Open-in model.
    private func askFix(
        session: Session,
        workspace: Workspace,
        completed: Session.CompletedCommand
    ) -> LastCommandField.AskFix? {
        guard let command = SessionInfoRules.askFixCommand(
            completed: completed,
            sshWorkspaceHost: session.sshWorkspaceHost
        ) else { return nil }
        let model = KookySettingsModel.shared
        let agents = AgentTemplate.askAgents(model: model)
        guard let current = AgentTemplate.askAgent(in: agents, model: model) else { return nil }
        let prompt = SessionInfoRules.askFixPrompt(
            command: command,
            exit: completed.exit,
            cwd: session.currentDirectory.path
        )
        let cwd = session.currentDirectory
        return LastCommandField.AskFix(current: current, agents: agents) { agent in
            model.noteAskAgentPicked(agent.id)
            let tab = store.addTab(
                in: workspace,
                template: agent,
                initialCwd: cwd,
                initialPrompt: prompt
            )
            store.activateTab(tab, in: workspace)
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        SessionInfoRules.abbreviatedPath(path)
    }
}

/// The only periodically-changing part of Session Info. Keeping the process
/// snapshot and polling task in this dedicated view means each 2-second sample
/// invalidates only the Processes section, not the identity/context/source/
/// environment/runtime inspector around it.
private struct SessionProcessesSection: View {
    let store: WorkspaceStore
    let session: Session

    @State private var processes: [SessionProcess] = []

    /// Slow enough to be free, fast enough that a command you just started
    /// shows up before you go looking for it.
    private static let pollInterval = Duration.seconds(2)

    var body: some View {
        SessionInfoSection(title: SessionInfoRules.processesTitle, store: store) {
            if processes.isEmpty {
                Text(verbatim: "—")
                    .font(SessionInfo.valueFont)
                    .foregroundStyle(Theme.chromeMuted)
            } else {
                ForEach(processes) { ProcessRow(process: $0) }
            }
            // The scan is honest but incomplete over SSH: the local tty only
            // carries the ssh process itself, so say so rather than letting
            // one bare `ssh` row read as "this tab is running nothing".
            if session.effectiveRemoteHost != nil {
                Text("remote processes not visible", bundle: .kookyResources)
                    .font(SessionInfo.labelFont)
                    .foregroundStyle(SessionInfo.labelText)
            }
        }
        // Always mounted because the placeholder above gives the section a
        // first frame. `id:` restarts on a tab switch; unmounting Session Info
        // cancels the loop, so other right-panel pages never pay for polling.
        .task(id: session.id) {
            processes = []
            // Loop-carried, deliberately not @State: nothing renders this
            // sample window, so changing it must not invalidate the section.
            var previousCPU: SessionProcessScanner.CPUSamples?
            while !Task.isCancelled {
                // Off screen (window closed-but-alive) the sysctl/fd walk paints nothing.
                if store.isOnScreen,
                   !store.collapsedInfoSections.contains(SessionInfoRules.processesTitle) {
                    // The port walk can cost milliseconds on a connection-
                    // heavy child; keep every kernel query off the main actor.
                    let pid = session.engine.foregroundPid ?? 0
                    let window = previousCPU
                    let scanned = await Task.detached {
                        SessionProcessScanner.scan(foregroundPid: pid, previousCPU: window)
                    }.value
                    previousCPU = scanned.cpu
                    // Detached work does not inherit cancellation. Never let
                    // an old tab's late scan overwrite the new tab's section.
                    if !Task.isCancelled, scanned.processes != processes {
                        processes = scanned.processes
                    }
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }
}

// MARK: - Row visibility

/// Which rows a session actually has something to say in.
///
/// A section's gate MUST be the OR of exactly the predicates its rows use.
/// They were written twice once, drifted, and shipped a `Runtime` heading with
/// nothing under it: the row hid a terminal title identical to the one the
/// identity row already showed, while the gate only checked that a title
/// existed. Deriving each row's visibility once, here, is what makes the two
/// impossible to disagree — and puts them somewhere a test can reach.
@MainActor
enum SessionInfoRules {
    /// Section display titles doubling as the persisted collapse keys
    /// (state.json `collapsedInfoSections`) — a LOCKED wire format, the
    /// M5.bbbbb tag-keys lesson: renaming one silently orphans every user's
    /// saved collapse state. Reword a heading only with a migration;
    /// `testInfoSectionTitlesAreALockedWireFormat` pins the strings.
    static let contextTitle = "Context"
    static let sourceTitle = "Source"
    static let environmentTitle = "Environment"
    static let processesTitle = "Processes"
    static let runtimeTitle = "Runtime"

    static func hasSourceInfo(session: Session, worktreeParent: Workspace?) -> Bool {
        session.gitStatus.branch != nil
            || visibleRepoRoot(session) != nil
            || session.gitStatus.filesChanged > 0
            || worktreeParent != nil
    }

    static func hasRuntimeInfo(_ session: Session) -> Bool {
        session.lastCompletedCommand != nil || visibleTerminalTitle(session) != nil
    }

    /// Suppressed when it's the directory shown above — a tab sitting at the
    /// repo root would otherwise print the same path twice.
    static func visibleRepoRoot(_ session: Session) -> String? {
        guard let repoRoot = session.gitStatus.repoRoot,
              !isSameDirectory(repoRoot, session.currentDirectory.path)
        else { return nil }
        return repoRoot
    }

    /// Suppressed when it's what the identity row already shows: `Session.title`
    /// falls through to `terminalTitle`, so without a rename this would repeat
    /// the top of the page word for word.
    static func visibleTerminalTitle(_ session: Session) -> String? {
        guard let title = nonEmpty(session.terminalTitle), title != session.title else { return nil }
        return title
    }

    static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// The usage column: whatever was measured, always — a first cut hid
    /// values below a threshold, and CPU hovering around the bar popped in
    /// and out every poll, which reads as glitch, not quiet. Quiet is the
    /// COLOR's job now (`processUsageIsProminent`): idle rows keep their
    /// numbers but sink to the faint tier. nil only when nothing was
    /// readable at all (other-uid pid).
    static func processUsageLabel(cpuPercent: Int?, residentMB: Int?) -> String? {
        var parts: [String] = []
        if let cpu = cpuPercent { parts.append("\(cpu)%") }
        if let mb = residentMB {
            // C-locale format on purpose: "1.2G" is a unit readout, not prose.
            parts.append(mb >= 1024 ? String(format: "%.1fG", Double(mb) / 1024) : "\(mb)M")
        }
        // The interpunct is the page's one meta-separator (the command status
        // row uses it too) — without it "47% 1.2G" reads as one blob.
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether a row's usage deserves the readable tier: it's DOING
    /// something. Everything else stays legible but faint, so a scan of the
    /// list lands on the busy row without anything blinking in and out.
    static func processUsageIsProminent(cpuPercent: Int?) -> Bool {
        (cpuPercent ?? 0) >= 1
    }

    /// The command an "ask agent to fix" button would quote, or nil when the
    /// button must hide: the command succeeded, there's no text to quote
    /// (remote command, bash, pre-marker), or this is an SSH workspace.
    /// The SSH gate is NOT about delivery — the spawn path carries an
    /// initial prompt to the remote fine (only the resume id is dropped,
    /// see `makeSessionConfig`) — it's about truth: the prompt embeds the
    /// LOCAL `currentDirectory` (a remote's OSC 7 never arrives) and quotes
    /// a failure from a mixed local/remote context, which would send a
    /// fresh remote agent chasing a local path.
    static func askFixCommand(
        completed: Session.CompletedCommand,
        sshWorkspaceHost: String?
    ) -> String? {
        guard sshWorkspaceHost == nil,
              completed.exit != 0,
              let text = completed.text
        else { return nil }
        return text
    }

    /// English on purpose — it's addressed to the agent, not the user.
    static func askFixPrompt(command: String, exit: Int, cwd: String) -> String {
        """
        This command failed with exit code \(exit) (ran in \(cwd)):

        \(command)

        Diagnose why it failed and fix it.
        """
    }

    /// "Blank means absent" is `normalizedTitle`'s one rule — this is just
    /// its optional-taking spelling, not a second implementation.
    static func nonEmpty(_ value: String?) -> String? {
        value.flatMap(normalizedTitle)
    }

    private static func isSameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }
}

// MARK: - Section

/// Disclosure header + rows. The header is the app's existing category-label
/// treatment (uppercase mono, tracked, muted — the same one the sheets' status
/// labels and the Codex plan badge use), which separates it from a field label
/// by LETTERFORM, not just by weight. `.textCase` rather than uppercase keys so
/// the Chinese strings pass through untouched.
///
/// Collapse state lives on the store, not in `@State`: the page unmounts every
/// time the panel switches, and this view would otherwise forget it instantly.
private struct SessionInfoSection<Content: View>: View {
    let title: String
    let store: WorkspaceStore
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    private var isExpanded: Bool { !store.collapsedInfoSections.contains(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: SessionInfo.rowSpacing) {
            Button {
                withAnimation(Theme.chromeTransition) { store.toggleInfoSection(title) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 8)
                    Text(LocalizedStringKey(title), bundle: .kookyResources)
                        .font(SessionInfo.sectionFont)
                        .textCase(.uppercase)
                        .tracking(SessionInfo.sectionTracking)
                        .fixedSize()
                    Rectangle()
                        .fill(Theme.chromeHairline)
                        .frame(height: 1)
                }
                .foregroundStyle(isHovered ? Theme.chromeForeground : SessionInfo.sectionText)
                .frame(height: SessionInfo.sectionHeaderHeight)
                .hoverableRowBackground(isHovered: isHovered)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chromeButtonCornerRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(SectionDisclosureStyle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)

            if isExpanded {
                VStack(alignment: .leading, spacing: SessionInfo.rowSpacing) {
                    content()
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, SessionInfo.gutter)
        .padding(.top, SessionInfo.sectionGap)
    }
}

/// Plain button with a pressed state — `.plain` alone gives a disclosure
/// header no press feedback at all.
private struct SectionDisclosureStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// MARK: - Processes

/// One process on the session's terminal, shell at depth 0.
private struct ProcessRow: View {
    let process: SessionProcess

    @State private var contextMenu: PopoverPresentation<SessionProcess>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Fixed marker column outside the indent, so nesting reads off
                // one straight edge instead of stepping with the dot.
                Circle()
                    .fill(process.isForeground ? Theme.activityRunning : .clear)
                    .frame(width: 4, height: 4)
                Text(verbatim: process.name)
                    .font(SessionInfo.valueFont)
                    .foregroundStyle(
                        process.isForeground
                            ? Theme.chromeForeground
                            : Theme.chromeForeground.opacity(0.7)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, CGFloat(process.depth) * 6)
                Spacer(minLength: 8)
                // Busy rows read, idle rows sink to the faint tier — same
                // numbers, different weight, nothing blinking in and out.
                if let usage = SessionInfoRules.processUsageLabel(
                    cpuPercent: process.cpuPercent,
                    residentMB: process.residentMB
                ) {
                    Text(verbatim: usage)
                        .font(SessionInfo.labelFont)
                        .foregroundStyle(
                            SessionInfoRules.processUsageIsProminent(cpuPercent: process.cpuPercent)
                                ? SessionInfo.labelText
                                : Theme.chromeFaint
                        )
                        .lineLimit(1)
                }
                // Faintest thing on the row, held off the usage column by an
                // extra step of space: usage is live state worth reading, the
                // pid is an identifier you only need when you go for it (the
                // row's right-click copies it).
                Text(verbatim: "\(process.pid)")
                    .font(SessionInfo.labelFont)
                    .foregroundStyle(Theme.chromeFaint)
                    .padding(.leading, 6)
            }
            // Ports get their own line under the name: they're what the
            // process OFFERS, not what it costs, and a multi-listener dev
            // server was crowding the name off the row. Indented to the
            // name's own left edge (marker column + gutter + depth).
            if !process.ports.isEmpty {
                HStack(spacing: 4) {
                    ForEach(process.ports, id: \.self) { PortLink(port: $0) }
                }
                .padding(.leading, 10 + CGFloat(process.depth) * 6)
            }
        }
        .contentShape(Rectangle())
        // The row's own immutable snapshot rides the presentation as the item
        // (the popover rule); a `.contextMenu` would fight the page's popover
        // menu language, and the catcher lets left clicks fall through to the
        // port links.
        .overlay(RightClickCatcher { _ in
            contextMenu = PopoverPresentation(value: process)
        })
        .popover(item: $contextMenu, arrowEdge: .trailing) { presented in
            ProcessContextMenu(process: presented.value) { contextMenu = nil }
        }
    }
}

/// A listening port as a clickable chip: the click opens the local URL, which
/// is what "my dev server took :3000" wants next. A chip, not bare text — the
/// row's numbers are all readout, and the one clickable thing must not dress
/// like them (the Ask-AI pill's rule, one size down).
private struct PortLink: View {
    let port: UInt16

    @State private var isHovered = false

    private var urlString: String { "http://localhost:\(port)" }

    var body: some View {
        Button {
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        } label: {
            Text(verbatim: ":\(port)")
                .font(SessionInfo.stateFont)
                .foregroundStyle(Theme.chromeForeground.opacity(isHovered ? 1 : 0.8))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isHovered ? Theme.chromeActive : Theme.chromeHover)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .hoverCursor(.pointingHand)
        .help(urlString)
    }
}

/// Copy PID / copy port URLs / two-step kill. The kill row arms on the first
/// click and only sends SIGTERM on the second, recolored as a warning while
/// armed; `.popover(item:)`'s fresh identity per open means an armed-but-
/// abandoned kill resets the moment the menu closes.
private struct ProcessContextMenu: View {
    let process: SessionProcess
    let dismiss: () -> Void

    @State private var killArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KookyMenuRow(title: "Copy PID") {
                dismiss()
                writeToGeneralPasteboard("\(process.pid)")
            }
            ForEach(process.ports, id: \.self) { port in
                KookyMenuRow(
                    title: String.localizedStringWithFormat(
                        String(localized: "Copy localhost:%d", bundle: .kookyResources),
                        Int(port)
                    ),
                    localizesTitle: false
                ) {
                    dismiss()
                    writeToGeneralPasteboard("http://localhost:\(port)")
                }
            }
            KookyMenuDivider()
            KookyMenuRow(
                title: killArmed ? "Confirm Kill" : "Kill Process",
                titleColor: killArmed ? Theme.activityFailure : nil
            ) {
                guard killArmed else {
                    killArmed = true
                    return
                }
                dismiss()
                // SIGTERM, not SIGKILL — the polite ask. Identity is
                // re-verified first: this menu can sit open long after the
                // target exited, and a recycled pid must never take the hit
                // (Codex review). A refusal — gone, recycled, or not ours to
                // signal — beeps instead of failing silently.
                if !SessionProcessScanner.identityMatches(pid: process.pid, startedAtUs: process.startedAtUs)
                    || kill(process.pid, SIGTERM) != 0 {
                    NSSound.beep()
                }
            }
        }
        .padding(Theme.space1)
        .frame(minWidth: 200)
        .background(Theme.chromeBackground)
    }
}

// MARK: - Fields

/// Hover-revealed copy affordance shared by every field. Copies the FULL
/// value — the rendered text is truncated, and dragging a selection across a
/// middle-truncated path is exactly the fiddliness this exists to remove.
/// Space is reserved even while hidden so hovering never reflows the row;
/// `Text(Image(...))` rather than a bare `Image` so the glyph carries a real
/// text baseline in the baseline-aligned rows.
private struct FieldCopyButton: View {
    let value: String
    let isVisible: Bool

    @State private var copied = false
    @State private var isHovered = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            writeToGeneralPasteboard(value)
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Text("\(Image(systemName: copied ? "checkmark" : "doc.on.doc"))")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(
                    copied
                        ? Theme.activitySuccess
                        : (isHovered ? Theme.chromeForeground : Theme.chromeMuted)
                )
                .frame(
                    width: Theme.chromeContextButtonSize,
                    height: Theme.chromeContextButtonSize
                )
                .background(isHovered ? Theme.chromeHover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chromeButtonCornerRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        // `copied` keeps the checkmark up if the pointer leaves right after
        // the click — the feedback must outlive the hover that revealed it.
        .opacity(isVisible || copied ? 1 : 0)
        .allowsHitTesting(isVisible)
        .help(String(localized: "Copy", bundle: .kookyResources))
    }
}

/// Label left, value right. For values short enough to sit beside their label —
/// everything except paths and identifiers, which get `BlockField`.
private struct InlineField: View {
    let label: String
    let value: String

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            FieldLabel(label)
            FieldCopyButton(value: value, isVisible: isHovered)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(SessionInfo.valueFont)
                .foregroundStyle(Theme.chromeForeground)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .help(value)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Label above a full-width value. For paths and identifiers: they need the
/// width, and they're what a user selects to copy.
private struct BlockField: View {
    let label: String
    let value: String

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: SessionInfo.labelGap) {
            HStack(spacing: 10) {
                FieldLabel(label)
                FieldCopyButton(value: value, isVisible: isHovered)
                Spacer(minLength: 0)
            }
            Text(verbatim: value)
                .font(SessionInfo.valueFont)
                .foregroundStyle(Theme.chromeForeground)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(value)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Reads exactly like the status bar's diff pill — file count first and muted
/// (it's a count, not a delta), then the shared `+X −Y` badge, the same
/// primitive the pill and the file-tree rows use. One diff vocabulary app-wide,
/// including the binary/mode-only `±` fallback.
private struct GitDiffField: View {
    let status: GitStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            FieldLabel("Git diff")
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(status.filesChanged)")
                    .font(SessionInfo.valueFont)
                    .foregroundStyle(Theme.chromeMuted)
                DiffCountBadge(
                    insertions: status.insertions,
                    deletions: status.deletions,
                    fontSize: SessionInfo.valueSize
                )
            }
        }
    }
}

/// The page's one raised surface, and it reuses the history search field's
/// treatment (`chromeHover`, radius 6) rather than inventing a card: this is
/// literal terminal content quoted back, so it earns a surface of its own.
private struct LastCommandField: View {
    /// Everything the "Ask AI" split button needs, prebuilt by the page —
    /// the field stays a display component that fires a closure. `current`
    /// is the plain click's target (its brand mark fronts the button; the
    /// wordmark stays a constant "Ask AI"); `agents` backs the chevron's
    /// picker; `run` executes with whichever agent was chosen.
    struct AskFix {
        let current: AgentTemplate
        let agents: [AgentTemplate]
        let run: (AgentTemplate) -> Void
    }

    let completed: Session.CompletedCommand
    let askFix: AskFix?

    @State private var isHovered = false

    private var command: String? { completed.text }
    private var statusColor: Color {
        completed.exit != 0 ? Theme.activityFailure : Theme.activitySuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SessionInfo.labelGap) {
            HStack(spacing: 10) {
                FieldLabel("Last command")
                if let command {
                    FieldCopyButton(value: command, isVisible: isHovered)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                // One line while it fits — `$ cmd` left, meta right. A command
                // too wide for that falls back to the stacked form instead of
                // being truncated just to keep the meta beside it.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        promptRow(wrapped: false)
                        Spacer(minLength: 12)
                        metaRow
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        promptRow(wrapped: true)
                        metaRow
                    }
                }

                // The action gets its own row, not a seat on the meta row —
                // squeezed beside "exit 1 · 3s" the button read as more meta,
                // and the two collided long before the panel got narrow. A
                // failure is the one state that warrants the extra line.
                if let askFix {
                    HStack {
                        Spacer(minLength: 0)
                        AskFixButton(askFix: askFix)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chromeHover)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func promptRow(wrapped: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "$")
                .foregroundStyle(Theme.chromeMuted)
            commandText(wrapped: wrapped)
        }
        .font(SessionInfo.valueFont)
    }

    /// No status word and no dot: the red/green tint on `exit N` carries the
    /// pass/fail semantics AND the number in one element (the agent panel made
    /// the same call — colored word over a redundant accent bar).
    private var metaRow: some View {
        HStack(spacing: 5) {
            Text(verbatim: TabBarItem.formatDuration(completed.duration))
            Text(verbatim: "·")
            Text(
                String.localizedStringWithFormat(
                    String(localized: "exit %d", bundle: .kookyResources),
                    completed.exit
                )
            )
            .foregroundStyle(statusColor)
        }
        .font(SessionInfo.stateFont)
        .foregroundStyle(SessionInfo.labelText)
        .fixedSize()
    }

    /// `—` when the shell never reported the text: a remote command, or a
    /// result that arrived before the session's first `CommandMarker`.
    /// `wrapped: false` is the one-line candidate: fixedSize so a long
    /// command genuinely overflows — making ViewThatFits pick the stacked
    /// form — instead of silently truncating to stay on one line. No `.help`
    /// there: an untruncated line has nothing extra to reveal.
    @ViewBuilder
    private func commandText(wrapped: Bool) -> some View {
        let base = Text(verbatim: command ?? "—")
            .foregroundStyle(command == nil ? Theme.chromeMuted : Theme.chromeForeground)
        if wrapped {
            let text = base
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let command {
                text.help(command)
            } else {
                text
            }
        } else {
            base.fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// The failed-command row's escape hatch: hands command + exit + cwd to an
/// agent in a new tab. A pill, not bare text — everything else on the card is
/// passive readout, and the one thing you can CLICK must not dress like the
/// metadata around it. Split like the Open-in control: the main zone runs the
/// last-picked agent (its brand mark fronts the button; the wordmark stays a
/// constant "Ask AI", hover names it in full), the chevron opens the picker
/// of enabled agents in the user's Settings order.
private struct AskFixButton: View {
    let askFix: LastCommandField.AskFix

    @State private var mainHovered = false
    @State private var chevronHovered = false
    @State private var picker: PopoverPresentation<[AgentTemplate]>?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                askFix.run(askFix.current)
            } label: {
                HStack(spacing: 6) {
                    AgentIconView(
                        asset: askFix.current.iconAsset,
                        fallbackSymbol: askFix.current.symbol,
                        size: 11
                    )
                    Text("Ask AI", bundle: .kookyResources)
                }
                .font(SessionInfo.stateFont)
                .foregroundStyle(Theme.chromeForeground.opacity(mainHovered ? 1 : 0.85))
                .padding(.leading, 7)
                .padding(.trailing, 6)
                .padding(.vertical, 3.5)
                .background(mainHovered ? Theme.chromeHover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { mainHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: mainHovered)
            .help(
                String.localizedStringWithFormat(
                    String(localized: "ask %@", bundle: .kookyResources),
                    askFix.current.title
                )
            )

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 1, height: 11)

            Button {
                picker = PopoverPresentation(value: askFix.agents)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.chromeForeground.opacity(chevronHovered ? 1 : 0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .background(
                        chevronHovered || picker != nil ? Theme.chromeHover : .clear
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { chevronHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: chevronHovered)
            .popover(item: $picker, arrowEdge: .bottom) { presented in
                AskAgentPicker(agents: presented.value) { agent in
                    picker = nil
                    askFix.run(agent)
                }
            }
        }
        // chromeActive over the card's chromeHover — one step brighter than
        // its surface, the same relationship every active row has to its
        // hovered neighbors.
        .background(Theme.chromeActive)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .hoverCursor(.pointingHand)
    }
}

/// The chevron's agent list — the same rows as the right-click "Ask" menu
/// (brand mark + name), fed by `AgentTemplate.askAgents`: enabled agents
/// only, in the user's Settings → Agents order.
private struct AskAgentPicker: View {
    let agents: [AgentTemplate]
    let choose: (AgentTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(agents, id: \.id) { agent in
                KookyMenuRow(title: agent.title, localizesTitle: false) {
                    AgentIconView(asset: agent.iconAsset, fallbackSymbol: agent.symbol, size: 16)
                } action: {
                    choose(agent)
                }
            }
        }
        .padding(Theme.space1)
        .frame(minWidth: 190)
        .background(Theme.chromeBackground)
    }
}

private struct FieldLabel: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(LocalizedStringKey(key), bundle: .kookyResources)
            .font(SessionInfo.labelFont)
            .foregroundStyle(SessionInfo.labelText)
    }
}

// MARK: - Design contract

/// Typography and spacing for the 230pt Session Info inspector.
///
/// Three text classes, and they must never be confusable:
///
/// | class   | size      | case      | color        |
/// |---------|-----------|-----------|--------------|
/// | SECTION | 9 medium  | UPPER +tr | muted 0.7    |
/// | label   | 10        | Sentence  | muted 0.8    |
/// | value   | 11        | —         | foreground   |
///
/// Every size is one the app already uses: 12 medium and 10 are the agent /
/// history row's two lines, 11 is the search field, 9.5 medium is the agents
/// list's state word, and 9 medium + tracking is the sheets' status label. An
/// inspector with its own scale would read as a different app one footer click
/// away, so additions take one of these roles instead of a new size at the
/// call site.
///
/// Spacing is a 3 : 11 : 24 rhythm — inside a field, between fields, between
/// sections. The jumps are what keep five groups of dense mono from reading as
/// one block; shrink the outer one and the page closes up again.
@MainActor
private enum SessionInfo {
    /// Matches `RightPanelHeader` and every right-panel row, so the whole
    /// column shares one left edge.
    static let gutter: CGFloat = 14

    static let valueSize: CGFloat = 11

    static var titleFont: Font { Theme.mono(12, weight: .medium) }
    static var sectionFont: Font { Theme.mono(9, weight: .medium) }
    static var valueFont: Font { Theme.mono(valueSize) }
    static var labelFont: Font { Theme.mono(10) }
    static var stateFont: Font { Theme.mono(9.5, weight: .medium) }

    static let sectionTracking: CGFloat = 1.2
    static var sectionText: Color { Theme.chromeMuted.opacity(0.7) }
    static var labelText: Color { Theme.chromeMuted.opacity(0.8) }

    static let sectionHeaderHeight: CGFloat = 16
    static let sectionGap = Theme.space5
    static let rowSpacing: CGFloat = 11
    static let labelGap: CGFloat = 3
}
