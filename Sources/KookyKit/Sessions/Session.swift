import Foundation

/// Coarse "what's the agent doing" status, surfaced as a sidebar dot. Stage 1
/// is UI-only; Stage 2 will drive these from real agent hooks (Claude Code's
/// `--settings` hooks, Codex equivalents) over a unix socket.
enum SessionActivityState: Equatable {
    case idle
    case running
    case attention
}

/// State of one Claude tool-call event captured by the activity strip.
/// `running` is the in-flight default after PreToolUse; `success` / `failed`
/// transition on PostToolUse with the hook's heuristic success flag;
/// `stalled` is the orphan terminal — set 60s after PreToolUse if no
/// matching PostToolUse arrived (Claude crashed / network dropped / etc.).
enum ToolCallEventState: Equatable {
    case running, success, failed, stalled
}

/// One PreToolUse / PostToolUse pair represented as a single record in
/// `Session.toolCallEvents`. Runtime only — never persisted (`Persistence`
/// drops the field by Codable design: the field doesn't appear in
/// `PersistedTab` so the encoder simply skips it).
///
/// Matched on the post side by `toolUseId` when Claude provided one (the
/// only correct identity for concurrent same-tool calls — two parallel
/// `Grep "TODO"` calls share `toolName` + `identifier`); falls back to
/// (`toolName`, `identifier`) for older Claude versions that omit the id.
/// `toolUseId` nil → fallback path; non-nil → primary key.
struct ToolCallEvent: Identifiable, Equatable {
    let id: UUID
    let toolUseId: String?
    let toolName: String
    let identifier: String
    let startedAt: Date
    var completedAt: Date?
    var state: ToolCallEventState
}

@MainActor
@Observable
final class Session: Identifiable {
    let id: UUID
    let engine: any TerminalEngine
    /// Initial template the tab was opened with. Promoted at runtime when an
    /// agent's hooks fire from a plain `terminal` session — e.g. user types
    /// `claude` inside a Terminal tab → upgraded to `.claudeCode` so the
    /// sidebar / tab icon and agent state-tracking start working.
    var agent: AgentTemplate
    /// Runtime-only agent reported through the terminal byte stream rather
    /// than the local hook socket. This is primarily for ssh remotes: the
    /// remote side can emit an OSC title marker that kooky sees locally,
    /// while the persisted launch template remains `terminal`.
    var transientAgent: AgentTemplate?
    var displayAgent: AgentTemplate { transientAgent ?? agent }
    /// Runtime-only SSH destination (`user@host` or bare `host`) reported by
    /// the ssh wrapper via an OSC title marker, shown in the pane status bar.
    /// Not persisted (like `transientAgent`); cleared on command-finished.
    var remoteHost: String?
    /// SSH destination this tab was *spawned against* — set only when kooky
    /// itself opened the connection (SSH workspace tabs), never by a manually
    /// typed `ssh`. Stable for the tab's lifetime, which makes it the paste
    /// routing signal: "upload pasted files to this host" must not flicker
    /// with `remoteHost`'s marker/command-finished lifecycle. Not persisted —
    /// restore re-derives it from `Workspace.sshRemoteHost` at spawn.
    var sshWorkspaceHost: String?
    /// Latest Codex account rate-limit usage (5-hour + weekly windows), parsed
    /// from the active session's rollout file by `CodexUsageMonitor` and shown
    /// as a status-bar gauge. Only populated for Codex sessions; `nil` until
    /// the first `token_count` lands. Runtime-only — not persisted (each launch
    /// re-derives it from disk once Codex starts writing again).
    var codexUsage: CodexUsage?
    /// Per-tab cwd. Initialized from the workspace's cwd at spawn, then kept in
    /// sync via OSC 7 (`engine.onPwdChange`). Drives the tab title so users see
    /// where they are, not which agent template the tab was launched from.
    var currentDirectory: URL
    /// Runtime state; not persisted. Resets to `.idle` after relaunch.
    var activityState: SessionActivityState = .idle
    /// Empty / whitespace input via `renameTab` clears this back to `nil` so
    /// the tab title resumes tracking the cwd.
    var customTitle: String?
    /// Title the running program set via `OSC 0` / `OSC 2` (libghostty's
    /// `GHOSTTY_ACTION_SET_TITLE`) — e.g. the `user@host:dir` an `ssh` remote
    /// shell emits. Runtime-only, never persisted. The shell wrapper re-emits
    /// the cwd as the title each prompt (`_kooky_title_pwd`), which the path
    /// filter in `onTitleChange` maps back to `nil` — so a leftover `ssh` /
    /// TUI title can't outlive the program once control returns to the prompt.
    /// Mutate via `applyTerminalTitle` — every raw write invalidates the tab
    /// bar + sidebar row + agent panel, so the write path must stay throttled.
    var terminalTitle: String?

    /// Throttle window for `applyTerminalTitle` (#51). A program can re-emit
    /// OSC 0/2 at output speed (a TUI ticking a token counter into the title
    /// every chunk); unthrottled, each write re-lays-out every observing
    /// surface and sustained streaming pegs a core on SwiftUI layout.
    static let terminalTitleThrottle: Duration = .milliseconds(250)
    @ObservationIgnored private var terminalTitleFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTerminalTitle: String?
    @ObservationIgnored private var lastTerminalTitleApply: ContinuousClock.Instant?

    /// Leading + trailing throttle around `terminalTitle`. The first write
    /// after a quiet gap lands synchronously (one-shot titles — an ssh
    /// banner, a TUI's startup title — keep the old immediate behavior, and
    /// the existing synchronous tests stay honest); writes inside the window
    /// park and the LAST parked value lands at the window's tail, so a burst
    /// can never drop its final title.
    func applyTerminalTitle(_ next: String?) {
        if terminalTitleFlushTask != nil {
            pendingTerminalTitle = next
            return
        }
        let now = ContinuousClock.now
        if let last = lastTerminalTitleApply, now - last < Self.terminalTitleThrottle {
            pendingTerminalTitle = next
            terminalTitleFlushTask = Task { @MainActor [weak self] in
                // Tolerance: the throttle is jitter-insensitive, so let the
                // kernel coalesce the wakeup instead of firing a tight timer.
                try? await Task.sleep(
                    until: last + Self.terminalTitleThrottle,
                    tolerance: .milliseconds(50),
                    clock: .continuous
                )
                guard let self else { return }
                self.terminalTitleFlushTask = nil
                let value = self.pendingTerminalTitle
                self.pendingTerminalTitle = nil
                self.commitTerminalTitle(value)
            }
            return
        }
        commitTerminalTitle(next)
    }

    /// Same-value applies must not advance `lastTerminalTitleApply`: no write
    /// happened, so no throttle window opens and the next real change stays
    /// synchronous (the wrapper's per-prompt cwd re-emit maps to an unchanged
    /// nil every prompt). Both the leading write and the trailing flush share
    /// this gate — the invariant must not fork between them.
    private func commitTerminalTitle(_ value: String?) {
        guard terminalTitle != value else { return }
        terminalTitle = value
        lastTerminalTitleApply = ContinuousClock.now
    }
    /// Agent id to persist for the next automatic restore. Kept after an
    /// agent's `.ended` event even though `agent` returns to `.terminal` for
    /// the live tab UI.
    var restoreAgentId: String?
    /// Last resumable conversation id this tab's agent reported. Persisted
    /// via `PersistedTab.conversationId` so the next kooky launch can resume
    /// where the user left off. Per-Session because each tab owns its own
    /// conversation and `KOOKY_SURFACE_ID` routes hook payloads precisely.
    var conversationId: String?
    /// The conversation id this spawn ACTUALLY resumed with, nil for a fresh
    /// launch. Distinct from `conversationId` (which persists even while the
    /// resume *setting* is off) — `spawnSession` records the value that
    /// reached the command line, mirroring `makeSessionConfig`'s ssh/prompt
    /// drops, so `wireSessionCallbacks` consumers (Codex usage monitor)
    /// don't have to re-derive any gate. Runtime-only.
    var resumedConversationId: String?
    /// Exit status of the most recent command — populated from libghostty's
    /// `OSC 133;D` event. `nil` until the shell reports its first finish (or
    /// when it omits the exit field). Not persisted: each launch starts fresh.
    var lastCommandExit: Int?
    /// Wall-clock duration of the most recent command in seconds. Same source
    /// as `lastCommandExit`; `nil` until first OSC 133;D arrives.
    var lastCommandDuration: TimeInterval?
    /// Shell-reported command line paired with `lastCommandExit`. The zsh/fish
    /// preexec hooks emit it as a `CommandMarker` on the same byte stream as
    /// the OSC 133 result, so the text is captured at the shell boundary
    /// (history expansion and edits included) and can never arrive after the
    /// result it labels. Runtime only — commands may carry credentials or
    /// other sensitive arguments and are never persisted.
    var lastCommandText: String?

    /// The host this session's shell is on, when remote: the spawn-pinned
    /// SSH-workspace host, else the ssh wrapper's login-marker host. The one
    /// derivation for every surface that names a session's location (agent
    /// panel, Session Info) — two spellings had already diverged once.
    var effectiveRemoteHost: String? { sshWorkspaceHost ?? remoteHost }

    /// The most recently COMPLETED command, for the Session Info inspector.
    /// `lastCommandExit`/`lastCommandText` above are the red-dot pairing
    /// buffer — cleared the moment the user types, so a stale failure dot
    /// can't linger. An inspector that read them directly vanished its
    /// "Last command" row on the first keystroke; this snapshot survives
    /// input and is only ever REPLACED by the next completed command.
    /// Runtime only for the same credential reason as the text above.
    struct CompletedCommand {
        let text: String?
        let exit: Int
        let duration: TimeInterval
    }
    var lastCompletedCommand: CompletedCommand?

    /// Per-session search state mirrored from libghostty's `start_search` /
    /// `search:<text>` / `navigate_search` / `end_search` action_cbs. Each
    /// surface owns its own search internally, so kooky tracks the state per
    /// session — multiple panes can be in search mode at the same time, each
    /// with its own needle and result count. `searchSelected = -1` is
    /// libghostty's "no current match" sentinel.
    var searchActive = false
    var searchNeedle = ""
    var searchTotal = 0
    var searchSelected = -1

    /// Multiline prompt composer state (⌘L). Per-session like search — the
    /// draft survives a tab switch (switching destroys the view; `composerDraft`
    /// re-seeds the `TextEditor` on re-appear). Runtime-only, not persisted.
    var composerActive = false
    var composerDraft = ""

    /// URL under a ⌘-hover (`link-previews`) — drives the preview badge in
    /// the pane's bottom-left corner. Runtime-only, not persisted.
    var hoveredLinkURL: String?

    /// Set true to open the rename popover on this tab from outside the view
    /// (the ⌘R menu command). The active tab's `TabBarItem` observes this,
    /// opens its rename popover, and resets the flag. Runtime-only.
    var renameRequested = false

    /// CLI `open --no-focus` (issue #59): this tab's shell must spawn while
    /// hidden — "background" means the command runs. Two topologies consume
    /// it: PaneView's offscreen engine mount (a non-active tab in an
    /// existing pane), and the engine's `spawnsWhileHidden` exemption alone
    /// (the seed tab of a fresh hidden workspace — it IS its pane's active
    /// tab, so no offscreen mount exists). LIFELONG — never cleared:
    /// clearing on activation raced the next-frame mount (an
    /// activate-then-switch-away inside one render commit stranded a
    /// never-spawned tab), so the one consumer gate is PaneView's
    /// active-tab exclusion, and the flag's meaning is "this tab was born
    /// in the background", not "hasn't been seen yet". The residual cost is
    /// one hidden, render-parked mount while such a tab is inactive.
    /// Runtime-only, deliberately NOT persisted: after a restart the tab is
    /// an ordinary restored background tab, back on the lazy
    /// spawn-on-reveal path (the `-e` command isn't persisted either — an
    /// eager respawn couldn't run it anyway).
    var spawnsInBackground = false

    /// Latest git status for the session's cwd. `branch == nil` when the cwd
    /// isn't inside a git repo (or git isn't installed). Refreshed by
    /// `WorkspaceStore` on cwd-change + command-finished hooks. Runtime-only;
    /// not persisted.
    var gitStatus: GitStatus = .empty

    /// Project-environment indicators (Python venv name, Node version)
    /// reported by the live shell prompt hook, with project-file fallback.
    var environment: ProjectEnvironment = .empty

    /// Latest live shell env reported by the prompt hook. Kernel proc env
    /// snapshots are not reliable after `nvm use` / `activate` mutate the
    /// running shell, so this takes priority when present.
    var shellEnvironment: [String: String] = [:]

    /// Rolling buffer of recent Claude tool-call events (PreToolUse +
    /// PostToolUse pairs collapsed into one record each), rendered as
    /// pills in the activity strip. Capped at 200 (oldest evicted on
    /// overflow). Runtime only — `Persistence` does not encode this field,
    /// so app restart / `--resume` starts the strip empty.
    var toolCallEvents: [ToolCallEvent] = []
    static let toolCallEventsCap = 200
    /// 60s without a matching PostToolUse → `.running` flips to `.stalled`.
    /// Matches the "Claude crashed mid-tool" case the activity strip's
    /// design doc calls out.
    static let toolCallOrphanThreshold: TimeInterval = 60

    /// Background timer that periodically sweeps `.running` events for
    /// orphan status. Started lazily on first `recordToolCallStart`; ends
    /// itself when the sweep finds no `.running` events left. `[weak self]`
    /// means Session deinit naturally tears it down without explicit
    /// cleanup. Single timer per session (5s tick) regardless of how many
    /// concurrent tool calls are running.
    private var orphanCheckTimer: Task<Void, Never>?

    /// Appends a PreToolUse record (state = .running) and enforces the
    /// rolling cap. Caller (`WorkspaceStore.applyToolCallEvent`) is
    /// `@MainActor`-isolated so direct array mutation is safe.
    func recordToolCallStart(
        toolName: String,
        identifier: String,
        toolUseId: String? = nil,
        startedAt: Date = Date()
    ) {
        appendToolCallEvent(ToolCallEvent(
            id: UUID(),
            toolUseId: toolUseId,
            toolName: toolName,
            identifier: identifier,
            startedAt: startedAt,
            completedAt: nil,
            state: .running
        ))
        scheduleOrphanCheckIfNeeded()
    }

    /// Resolves a PostToolUse: looks up the matching pre record (prefer
    /// `toolUseId` when both sides have one; fall back to oldest
    /// `.running`-or-`.stalled` matching `toolName` + `identifier`) and
    /// flips it to `.success` / `.failed`. The `.stalled` fallback is
    /// deliberate: a Claude tool that ran >60s is marked stalled by the
    /// orphan sweep, but if the Post eventually arrives we'd rather revive
    /// the original record (with accurate completedAt) than synthesise a
    /// 0s ghost record alongside the now-misleading stalled one.
    func recordToolCallEnd(
        toolName: String,
        identifier: String,
        success: Bool,
        toolUseId: String? = nil,
        completedAt: Date = Date()
    ) {
        // Match priority:
        //   1. tool_use_id exact match (any non-terminal state) — Claude's
        //      stable per-call id; only correct option for concurrent
        //      same-tool calls with truncated identifiers
        //   2. oldest (toolName + identifier) running OR stalled — legacy
        //      payloads without tool_use_id, or stalled record revival
        let matchIndex: Int? = {
            if let toolUseId, !toolUseId.isEmpty {
                if let i = toolCallEvents.firstIndex(where: { $0.toolUseId == toolUseId }) {
                    return i
                }
            }
            return toolCallEvents.firstIndex {
                $0.toolName == toolName
                    && $0.identifier == identifier
                    && ($0.state == .running || $0.state == .stalled)
            }
        }()

        if let i = matchIndex {
            toolCallEvents[i].completedAt = completedAt
            toolCallEvents[i].state = success ? .success : .failed
        } else {
            // Orphan post — synthesise a record so the call still appears
            // in the strip. startedAt = completedAt (no duration possible
            // without the pre). Rare; usually means a hook race or kooky
            // restart between Pre and Post.
            appendToolCallEvent(ToolCallEvent(
                id: UUID(),
                toolUseId: toolUseId,
                toolName: toolName,
                identifier: identifier,
                startedAt: completedAt,
                completedAt: completedAt,
                state: success ? .success : .failed
            ))
        }
    }

    /// Append + enforce the 200-event rolling cap. Single source of truth
    /// for the cap policy — `recordToolCallStart` and the orphan-post
    /// branch of `recordToolCallEnd` both route through here so a future
    /// change to the eviction rule (ring buffer, eviction-by-state, etc.)
    /// only touches one site.
    private func appendToolCallEvent(_ event: ToolCallEvent) {
        toolCallEvents.append(event)
        if toolCallEvents.count > Self.toolCallEventsCap {
            toolCallEvents.removeFirst(toolCallEvents.count - Self.toolCallEventsCap)
        }
    }

    /// Marks `.running` events older than 60s (`toolCallOrphanThreshold`)
    /// as `.stalled` and stamps `completedAt` with the sweep time so the
    /// duration label freezes at the stall threshold (not the pill's
    /// fallback `Date()` clock that grows forever). Returns true if any
    /// `.running` events survived the sweep — the orphan timer uses this
    /// to decide whether to keep ticking.
    @discardableResult
    func checkStalledToolCallEvents(now: Date = Date()) -> Bool {
        var anyStillRunning = false
        for i in toolCallEvents.indices where toolCallEvents[i].state == .running {
            if now.timeIntervalSince(toolCallEvents[i].startedAt) > Self.toolCallOrphanThreshold {
                toolCallEvents[i].state = .stalled
                toolCallEvents[i].completedAt = now
            } else {
                anyStillRunning = true
            }
        }
        return anyStillRunning
    }

    private func scheduleOrphanCheckIfNeeded() {
        guard orphanCheckTimer == nil else { return }
        orphanCheckTimer = Task { @MainActor [weak self] in
            // 5s tick — coarse enough that 200 events × N sessions stays
            // cheap (single array scan per session) but fine enough that
            // a 60s orphan transitions within ~1 tick of the threshold.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                let stillRunning = self.checkStalledToolCallEvents()
                if !stillRunning {
                    self.orphanCheckTimer = nil
                    break
                }
            }
        }
    }

    /// Tab-pill name. Precedence: `customTitle` (manual rename) wins, then
    /// `terminalTitle` (OSC title from the running program, e.g. an `ssh`
    /// remote), then `lastPathComponent` of the cwd (`~` for $HOME). An empty
    /// cwd path falls back to the agent name so a degenerate URL doesn't
    /// render as blank.
    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if let reported = terminalTitle, !reported.isEmpty { return reported }
        if currentDirectory.standardizedFileURL.path == homeDirectoryPath { return "~" }
        let last = currentDirectory.lastPathComponent
        return last.isEmpty ? displayAgent.title : last
    }

    init(
        id: UUID = UUID(),
        engine: any TerminalEngine,
        currentDirectory: URL,
        agent: AgentTemplate,
        customTitle: String? = nil,
        conversationId: String? = nil
    ) {
        self.id = id
        self.engine = engine
        self.currentDirectory = currentDirectory
        self.agent = agent
        self.restoreAgentId = agent.supportsResume ? agent.id : nil
        self.customTitle = customTitle
        self.conversationId = conversationId
    }
}
