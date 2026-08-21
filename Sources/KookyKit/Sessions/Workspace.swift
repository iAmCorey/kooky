import Foundation

@MainActor
@Observable
final class Workspace: Identifiable {
    let id: UUID
    /// Project root. New tabs spawn here; the active pane's active tab's OSC 7
    /// reports keep this in sync — `cd` in any visible terminal updates the
    /// workspace, the next new pane / tab inherits the latest path.
    var workingDirectory: URL
    /// Single split tree per workspace. Always non-nil; a fresh workspace
    /// holds one Pane with one Session.
    var root: PaneNode
    /// Currently focused leaf-pane id. Splits/closes update this so cwd
    /// tracking and ⌘D act on what the user is looking at.
    var activePaneId: UUID?
    /// When non-nil, `PaneTreeView` renders only this pane and hides the
    /// rest of the split tree (pane zoom). Runtime-only — never persisted,
    /// so a kooky relaunch never strands the user in zoom. `closePane` /
    /// `splitPane` clear this automatically when the zoomed pane changes
    /// shape.
    var zoomedPaneId: UUID?

    /// Is `paneId` the currently zoomed pane?
    func isZoomed(_ paneId: UUID) -> Bool { zoomedPaneId == paneId }

    /// True when ⌘⇧E / the zoom button has something to do — either there
    /// are multiple panes to choose between, or the workspace is already
    /// zoomed (so toggling un-zooms).
    var canZoom: Bool { root.hasMultiplePanes || zoomedPaneId != nil }
    /// Empty / whitespace input via `renameWorkspace` clears this back to
    /// `nil` so the sidebar label resumes tracking the cwd.
    var customTitle: String? = nil

    /// Set by `SidebarView` once it has brought this workspace's row into the
    /// view hierarchy (the ⌘⇧R flow, parked on
    /// `WorkspaceStore.pendingRenameWorkspace`). The row's `SidebarWorkspaceRow`
    /// observes it — onChange while already mounted, onAppear for a row that
    /// just mounted after the sidebar expanded/scrolled to it — opens its
    /// rename popover, and resets the flag. Runtime-only.
    var renameRequested = false

    /// When non-nil, this workspace is a git worktree whose source workspace
    /// has this id. Sidebar groups worktrees under their source via a
    /// disclosure triangle. Set at creation and never changes for the
    /// workspace's lifetime — re-parenting a worktree is not a supported op.
    var worktreeParentId: UUID? = nil
    /// Branch the worktree was created on, shown next to its sidebar row.
    /// Captured at creation; the pane status bar still owns the live branch
    /// readout if the user checks out something else inside the worktree.
    var worktreeBranch: String? = nil
    /// Disk root of this worktree, captured at creation. Distinct from
    /// `workingDirectory` because the latter follows OSC 7 cwd reports —
    /// `cd ~/Downloads` inside a worktree tab drifts `workingDirectory`
    /// off the worktree, but `worktreePath` stays pinned to the directory
    /// `git worktree add` produced. The close / reconcile paths must use
    /// this, not `workingDirectory`, so `git worktree remove` doesn't
    /// target the wrong path.
    var worktreePath: URL? = nil

    /// SSH destination this workspace connects to (`user@host` or bare
    /// `host`). Non-nil marks an SSH workspace: every new plain-terminal tab
    /// auto-connects there, and agent tabs launch their agent on the remote
    /// through the kooky-ssh wrapper. Set at creation, persisted, and never
    /// mutated afterwards — a remote project stays one cohesive workspace
    /// instead of each new tab dropping back to the local machine.
    var sshRemoteHost: String? = nil

    /// User-assigned marker drawn as a stripe down the row's leading edge, in
    /// both sidebar modes. Nil for every workspace until the user sets one from
    /// the row's right-click menu — the value of a marker here comes from most
    /// rows *not* having one, so nothing assigns these automatically. A named
    /// tag also adds a `#name` line to the row's tooltip. Persisted as a hex
    /// string plus an optional name; a malformed colour falls back to gray
    /// rather than failing the restore.
    var tag: WorkspaceTag? = nil

    /// Single source of truth for "where the worktree actually lives on
    /// disk." For worktree workspaces `worktreePath` wins (pinned at
    /// create time); upgraded state.json files written before the field
    /// existed fall through to `workingDirectory` and behave as before.
    /// Use this everywhere `git worktree remove` / `reconcile` /
    /// confirm-sheet subtitle needs the disk root.
    var diskPath: URL { worktreePath ?? workingDirectory }

    /// True when closing this workspace's one remaining tab would cascade
    /// into worktree removal (`closeTab` reroutes to the workspace-removal
    /// confirm sheet instead of closing the tab). One predicate for the
    /// store's reroute AND the CLI's refusal — a drift between the two is
    /// either a refused closeable tab or a "closed" answer for a parked
    /// confirmation. (`closePane` has its own, DIFFERENT pane-level cascade
    /// condition; this models only the closeTab shape.)
    var closingLastTabCascadesIntoWorktreeRemoval: Bool {
        worktreeParentId != nil
            && root.allPanes.count == 1
            && root.allPanes.first?.tabs.count == 1
    }

    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        // Mirror the active tab's OSC title so an `ssh` session shows the
        // remote host in the sidebar, not the stale local directory.
        if let reported = activeSession?.terminalTitle, !reported.isEmpty { return reported }
        // SSH workspaces are "about" their remote, not the local cwd the
        // connection happened to spawn from. (`normalizedSSHHost` gates every
        // write, so non-nil implies non-blank.)
        if let host = sshRemoteHost { return host }
        if workingDirectory.path == homeDirectoryPath { return "Home" }
        let last = workingDirectory.lastPathComponent
        return last.isEmpty ? workingDirectory.path : last
    }

    /// Sidebar row hover text (issue #43): what this workspace is, who is
    /// running in it, and where it lives. The compact row is icon-only, so
    /// without it a hover can name a location but never an identity — the
    /// whole gap when several workspaces share one agent's icon.
    ///
    /// Mirrors `SidebarWorkspaceRow.subtitleRow`'s branch → host → cwd
    /// precedence; keep the two in step. The branch and host lines carry a
    /// word prefix because the row's glyph badge — what makes a bare `main`
    /// read as a branch — has no equivalent inside a tooltip. A worktree keeps
    /// its path too: `subtitleRow` omits the path from the visible row
    /// *because* this tooltip carries it.
    ///
    /// `agents` is the caller's `sidebarReadout` array — deliberately the same
    /// snapshot that drew the icons and the `+N` badge in this render pass, so
    /// the tooltip always explains the badge actually on screen.
    func sidebarTooltip(agents: [AgentTemplate]) -> String {
        var titleLine = singleLine(title)
        var locationLines: [String] = []
        if let branch = worktreeBranch, !branch.isEmpty {
            locationLines = ["branch \(singleLine(branch))", diskPath.path]
        } else if let host = sshRemoteHost {
            // An un-renamed SSH workspace whose remote reported no title is
            // already named after its host, so a location line would echo
            // line 1 — fold them together instead.
            if titleLine == host { titleLine = "ssh \(host)" } else { locationLines = ["ssh \(host)"] }
        } else {
            locationLines = [workingDirectory.path]
        }
        // Naming the agents only earns a line when the row shows a `+N` badge:
        // the badge says how many but never who.
        let agentLine = agents.count > 1
            ? [agents.map { singleLine($0.title) }.joined(separator: ", ")]
            : []
        // The stripe shows a tag's colour but can't show its name.
        let tagLine = tag?.hashLabel.map { [$0] } ?? []
        return ([titleLine] + tagLine + agentLine + locationLines).joined(separator: "\n")
    }

    var activePane: Pane? {
        if let id = activePaneId, let pane = root.pane(id: id) { return pane }
        return root.firstPane
    }

    var activeSession: Session? { activePane?.activeTab }

    /// Distinct non-terminal agents and aggregated activity, computed in a
    /// single tree walk. Sidebar reads all three per render. The walk runs
    /// to completion (no short-circuit) so each field reflects the whole
    /// tree — short-circuiting on attention previously left `hasFailure`
    /// false when a sibling pane held a non-zero exit.
    var sidebarReadout: (agents: [AgentTemplate], state: SessionActivityState, hasCommandFailure: Bool) {
        var seen: Set<String> = []
        var agents: [AgentTemplate] = []
        var state: SessionActivityState = .idle
        var hasFailure = false
        walk(root) { pane in
            for tab in pane.tabs {
                let agent = tab.displayAgent
                if !agent.isShell, !seen.contains(agent.id) {
                    seen.insert(agent.id)
                    agents.append(agent)
                }
                if let exit = tab.lastCommandExit, exit != 0 { hasFailure = true }
                switch tab.activityState {
                case .attention: state = .attention
                case .running where state != .attention: state = .running
                default: break
                }
            }
        } shouldStop: { false }
        return (agents, state, hasFailure)
    }

    var distinctAgents: [AgentTemplate] { sidebarReadout.agents }
    var activityState: SessionActivityState { sidebarReadout.state }
    /// True when any tab's last command exited non-zero. Sidebar uses this
    /// (with attention > failure > running > idle precedence) so a
    /// background-pane failure surfaces at the workspace level too.
    var hasCommandFailure: Bool { sidebarReadout.hasCommandFailure }

    private func walk(_ node: PaneNode, visit: (Pane) -> Void, shouldStop: () -> Bool) {
        switch node.content {
        case .pane(let p):
            visit(p)
        case .split(_, let a, let b, _):
            walk(a, visit: visit, shouldStop: shouldStop)
            if shouldStop() { return }
            walk(b, visit: visit, shouldStop: shouldStop)
        }
    }

    init(id: UUID = UUID(), workingDirectory: URL, root: PaneNode) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.root = root
        self.activePaneId = root.firstPane?.id
    }
}
