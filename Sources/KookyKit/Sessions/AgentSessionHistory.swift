import Foundation
import Observation
import SwiftUI

// MARK: - Record

/// One resumable conversation found on disk — the unit the right sidebar's
/// History list renders. Built by `AgentSessionScanner` from each agent's own
/// session store, NOT from kooky's persistence: that's the point — sessions
/// started outside kooky (or in tabs long closed) are still listed, and no
/// hook-side id capture is needed because the id is already in the file.
struct AgentSessionRecord: Identifiable, Hashable, Sendable {
    /// Builtin `AgentTemplate` id ("claude-code" / "codex").
    let agentId: String
    let conversationId: String
    /// Best-effort display title; empty when nothing usable was found
    /// (the UI shows a placeholder — the record is still resumable).
    let title: String
    /// The directory the conversation ran in. Resume respawns here so the
    /// conversation's file references stay valid.
    let cwd: URL
    /// `cwd.path`, built once here: the History filters compare it per
    /// record per keystroke, and `URL.path` is a fresh String each call.
    let cwdPath: String
    /// Session file's modification date — "when this conversation last moved".
    let lastActivity: Date

    init(agentId: String, conversationId: String, title: String, cwd: URL, lastActivity: Date) {
        self.agentId = agentId
        self.conversationId = conversationId
        self.title = title
        self.cwd = cwd
        self.cwdPath = cwd.path
        self.lastActivity = lastActivity
    }

    var id: String { "\(agentId):\(conversationId)" }
}

// MARK: - Scanner

/// Reads agent session stores off the main actor. Every format here is a
/// private implementation detail of its agent with no stability promise, so
/// parsing is defensive throughout: a line that doesn't parse is skipped, a
/// file that yields no id/cwd is dropped, and only file HEADS are read — a
/// session transcript can be tens of MB, but everything the list needs
/// (title, cwd, id) lives in the first lines.
enum AgentSessionScanner {
    /// One agent's session store: where it lives by default and how to turn
    /// it into records. `scan` iterates this table and `supportedAgentIds`
    /// derives from it, so a new agent is exactly one entry — the filter
    /// chips and the README-table guard test follow automatically.
    struct Store: Sendable {
        let agentId: String
        let defaultRoot: @Sendable () -> URL
        let collect: @Sendable (URL) -> [AgentSessionRecord]
    }

    private static func home(_ path: String) -> @Sendable () -> URL {
        { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path) }
    }

    static let stores: [Store] = [
        Store(agentId: AgentTemplate.claudeCodeID, defaultRoot: home(".claude/projects"), collect: collectClaude),
        // Static default root only: the scan isn't tied to any live session,
        // so there's no shell env to consult (`CodexUsageMonitor` needs one
        // because a Dock-launched kooky lacks the user's CODEX_HOME; the
        // ProcessInfo fallback inside `defaultSessionsRoot` is the best
        // available).
        Store(agentId: AgentTemplate.codex.id, defaultRoot: { CodexUsageMonitor.defaultSessionsRoot() }, collect: collectCodex),
        Store(agentId: AgentTemplate.pi.id, defaultRoot: home(".pi/agent/sessions"),
              collect: { piStyleRecords(under: $0, agentId: AgentTemplate.pi.id) }),
        Store(agentId: AgentTemplate.ohMyPi.id, defaultRoot: home(".omp/agent/sessions"),
              collect: { piStyleRecords(under: $0, agentId: AgentTemplate.ohMyPi.id) }),
        Store(agentId: AgentTemplate.kimi.id, defaultRoot: home(".kimi-code"), collect: collectKimi),
        Store(agentId: AgentTemplate.opencode.id, defaultRoot: home(".local/share/opencode/opencode.db"), collect: collectOpencode),
        Store(agentId: AgentTemplate.grok.id, defaultRoot: home(".grok/sessions"), collect: collectGrok),
        Store(agentId: AgentTemplate.cursor.id, defaultRoot: home(".cursor/chats"), collect: collectCursor),
        Store(agentId: AgentTemplate.copilot.id, defaultRoot: home(".copilot/session-state"), collect: collectCopilot),
        Store(agentId: AgentTemplate.kiro.id, defaultRoot: home("Library/Application Support/kiro-cli/data.sqlite3"), collect: collectKiro),
        Store(agentId: AgentTemplate.gemini.id, defaultRoot: home(".gemini/tmp"), collect: collectGemini),
        Store(agentId: AgentTemplate.droid.id, defaultRoot: home(".factory/sessions"), collect: collectDroid),
        Store(agentId: AgentTemplate.reasonix.id, defaultRoot: home(".reasonix/projects"), collect: collectReasonix),
        // Absent by design: Amp keeps threads server-side (the local files
        // are create-time stubs with no cwd or content), and Antigravity's
        // CLI store layout is unverified — every local sample is the IDE's;
        // one real `agy` conversation pins it.
    ]

    /// The agents whose session stores this scanner reads — derived from the
    /// table above so the roster and the scan branches can't drift.
    static let supportedAgentIds: [String] = stores.map(\.agentId)

    /// Head bytes per file. Big enough to clear oversized leading lines
    /// (Codex `session_meta` carries the whole base_instructions blob, which
    /// alone can pass 64KB — the M5.iiii lesson) while keeping a 300-file
    /// scan cheap.
    static let headByteLimit = 262_144
    /// Per-agent record cap. Files are stat'd and mtime-sorted BEFORE any
    /// content is read, so the cap bounds parsing work, not just list length.
    /// This is the ONLY cap — a merged-list cap was tried and removed: it
    /// clipped the data the filter chips and search operate on, so an agent
    /// whose newest session was old enough could vanish entirely while
    /// "search is the deep-recall path" claimed otherwise.
    static let perAgentCap = 150

    /// Production entry — every store at its real default location. The
    /// explicit name makes "reads the user's actual agent stores" a
    /// deliberate call at each call site; everything else (tests, fixtures)
    /// must build a roots dict for `scan(roots:)`, so an accidental
    /// real-store scan is unrepresentable rather than convention-guarded.
    static func scanDefaultRoots() -> [AgentSessionRecord] {
        scan(roots: Dictionary(uniqueKeysWithValues: stores.map { ($0.agentId, $0.defaultRoot()) }))
    }

    /// Production single-conversation lookup — the deep-link path's entry.
    /// The second explicitly-named real-store reader beside
    /// `scanDefaultRoots()`, same discipline: everything else (tests,
    /// fixtures) must pass an explicit root to `findRecord(agentId:
    /// conversationId:root:)` below.
    static func findRecordInDefaultRoot(agentId: String, conversationId: String) -> AgentSessionRecord? {
        guard let store = stores.first(where: { $0.agentId == agentId }) else { return nil }
        return findRecord(agentId: agentId, conversationId: conversationId, root: store.defaultRoot())
    }

    /// Explicit-root core (fixture-testable). Reads ONE agent's store,
    /// skipping the 13-way dispatch and cross-store sort a full scan pays;
    /// `collect` sorts newest-first internally, so on duplicate ids the
    /// newest record wins — the same one a full scan would rank first.
    static func findRecord(agentId: String, conversationId: String, root: URL) -> AgentSessionRecord? {
        guard let store = stores.first(where: { $0.agentId == agentId }) else { return nil }
        return store.collect(root).first { $0.conversationId == conversationId }
    }

    /// Stores without an entry in `roots` are skipped; a missing/empty root
    /// yields an empty slice, never an error. Stores are independent, so
    /// they collect CONCURRENTLY — wall time is roughly the slowest store
    /// instead of the sum (measured ~2x on a full scan; parallelism was
    /// declined at 2 stores and revisited at 13). `concurrentPerform` keeps
    /// the call synchronous, so the detached refresh task and tests use it
    /// alike.
    static func scan(roots: [String: URL]) -> [AgentSessionRecord] {
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var slices: [(index: Int, records: [AgentSessionRecord])] = []
            func add(_ index: Int, _ records: [AgentSessionRecord]) {
                lock.lock()
                slices.append((index, records))
                lock.unlock()
            }
            /// Table order first, so equal-timestamp records tie-break
            /// deterministically and the refresh equality gate never sees
            /// ordering-only diffs across runs.
            var ordered: [AgentSessionRecord] {
                lock.lock()
                defer { lock.unlock() }
                return slices.sorted { $0.index < $1.index }.flatMap(\.records)
            }
        }
        let collector = Collector()
        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            let store = stores[index]
            guard let root = roots[store.agentId] else { return }
            collector.add(index, store.collect(root))
        }
        return collector.ordered.sorted {
            $0.lastActivity != $1.lastActivity
                ? $0.lastActivity > $1.lastActivity
                : $0.id < $1.id
        }
    }

    static func scanStore<Item>(
        files: [(item: Item, mtime: Date)],
        parse: (Item, Date) -> AgentSessionRecord?
    ) -> [AgentSessionRecord] {
        files
            .sorted { $0.mtime > $1.mtime }
            .prefix(perAgentCap)
            .compactMap { parse($0.item, $0.mtime) }
    }

    private static func collectClaude(root: URL) -> [AgentSessionRecord] {
        scanStore(files: claudeSessionFiles(under: root), parse: claudeRecord)
    }

    private static func collectCodex(root: URL) -> [AgentSessionRecord] {
        scanStore(files: codexRolloutFiles(under: root), parse: codexRecord)
    }

    // MARK: Claude Code (~/.claude/projects/<munged-cwd>/<uuid>.jsonl)

    /// The `root/<project-dir>[/subdir]/*.jsonl` walk Claude, Pi-style, and
    /// Reasonix stores share; `isSession` carries each store's filename
    /// rules. One home for the stat-then-cap enumeration invariant.
    static func projectFiles(
        under root: URL,
        subdir: String? = nil,
        isSession: (URL) -> Bool
    ) -> [(item: URL, mtime: Date)] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return projects.flatMap { project -> [(item: URL, mtime: Date)] in
            let dir = subdir.map { project.appendingPathComponent($0, isDirectory: true) } ?? project
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return [] }
            return files.compactMap { file in
                guard file.pathExtension == "jsonl",
                      isSession(file),
                      let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (file, mtime)
            }
        }
    }

    private static func claudeSessionFiles(under root: URL) -> [(item: URL, mtime: Date)] {
        // Session files sit next to same-named checkpoint DIRECTORIES;
        // the UUID gate also keeps stray non-session jsonl out.
        projectFiles(under: root) { file in
            UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
        }
    }

    private static let customTitleMarker = Data("custom-title".utf8)
    /// Also gates Gemini's `$set.summary` walk in AgentSessionStores.swift.
    static let summaryMarker = Data("\"summary\"".utf8)

    static func claudeRecord(file: URL, mtime: Date) -> AgentSessionRecord? {
        let conversationId = file.deletingPathExtension().lastPathComponent
        var customTitle: String?
        var summary: String?
        var firstUserText: String?
        var cwd: String?
        for line in headLines(of: file) {
            // Once the first-wins fields are settled, the only lines that can
            // still change the record are `custom-title` (last wins — a rename
            // appends rather than rewrites, so the whole head must be walked)
            // and a first `summary`. Gating the JSON parse on their byte
            // markers skips the multi-KB assistant/tool lines that dominate
            // the head — this is the scan's hottest loop. A marker false
            // positive just parses one extra line.
            if cwd != nil, firstUserText != nil,
               line.range(of: customTitleMarker) == nil,
               summary != nil || line.range(of: summaryMarker) == nil {
                continue
            }
            guard let object = jsonObject(line) else { continue }
            switch object["type"] as? String {
            case "custom-title":
                if let value = object["customTitle"] as? String { customTitle = value }
            case "summary":
                if summary == nil, let value = object["summary"] as? String { summary = value }
            case "user":
                // Sidechain transcripts are subagent work, not a conversation
                // the user can meaningfully resume — drop the whole file.
                // (Checked before the gate can engage: the first user line is
                // always parsed, because `firstUserText` is still nil then.)
                if object["isSidechain"] as? Bool == true { return nil }
                if cwd == nil { cwd = object["cwd"] as? String }
                if firstUserText == nil,
                   let message = object["message"] as? [String: Any],
                   let text = displayableUserText(messageContent(message["content"])) {
                    firstUserText = text
                }
            default:
                break
            }
        }
        // No cwd means no place to resume in — a wrong directory would break
        // every file reference in the conversation, so skip instead.
        guard let cwd else { return nil }
        return AgentSessionRecord(
            agentId: AgentTemplate.claudeCodeID,
            conversationId: conversationId,
            title: cleanedTitle(customTitle ?? summary ?? firstUserText ?? ""),
            cwd: URL(fileURLWithPath: cwd),
            lastActivity: mtime
        )
    }

    /// Claude `message.content` is either a plain string or an array of
    /// content blocks; the first text block carries what the user typed.
    static func messageContent(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            return block["text"] as? String
        }
        return nil
    }

    // MARK: Codex (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    private static func codexRolloutFiles(under root: URL) -> [(item: URL, mtime: Date)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [(item: URL, mtime: Date)] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("rollout-"),
                  let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            result.append((file, mtime))
        }
        return result
    }

    private static let userMessageMarker = Data("user_message".utf8)

    static func codexRecord(file: URL, mtime: Date) -> AgentSessionRecord? {
        let lines = headLines(of: file)
        // The meta usually parses straight from the in-head first line — one
        // read for the whole record. Only a session_meta line LARGER than the
        // head cap (truncated -> parse fails) falls back to the monitor's
        // newline-bounded 4MB reader; that reader also owns the legacy
        // `session_id` key fallback, which the payload accessors preserve.
        let meta: [String: Any]?
        if let first = lines.first, let object = jsonObject(first),
           object["type"] as? String == "session_meta" {
            meta = object["payload"] as? [String: Any]
        } else {
            meta = CodexUsageMonitor.sessionMetaPayload(atPath: file.path)
        }
        guard let meta,
              let conversationId = CodexUsageMonitor.conversationId(fromSessionMetaPayload: meta),
              let cwd = CodexUsageMonitor.cwd(fromSessionMetaPayload: meta)
        else { return nil }
        var title: String?
        for line in lines.dropFirst() {
            // The head is dominated by the giant session_meta and injected
            // developer/context lines; only `user_message` events can carry
            // the title, so gate the JSON parse on their byte marker.
            guard line.range(of: userMessageMarker) != nil, let object = jsonObject(line) else { continue }
            // `user_message` events carry exactly what the user typed —
            // unlike the first `response_item` user message, which is the
            // AGENTS.md / environment injection.
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message"
            else { continue }
            if let text = displayableUserText(payload["message"] as? String) {
                title = text
                break
            }
        }
        return AgentSessionRecord(
            agentId: AgentTemplate.codex.id,
            conversationId: conversationId,
            title: cleanedTitle(title ?? ""),
            cwd: URL(fileURLWithPath: cwd),
            lastActivity: mtime
        )
    }

    // MARK: Shared parsing helpers

    /// Line slices from the file's first `headByteLimit` bytes, split on raw
    /// newlines — no String decode: JSONSerialization takes UTF-8 `Data`
    /// directly, so decoding ~256KB per file to `String` would be a wasted
    /// full pass. A line truncated at the boundary simply fails JSON parsing
    /// and is skipped.
    static func headLines(of file: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headByteLimit), !data.isEmpty else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
    }

    static func jsonObject(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// First-user-message text is only a usable title when it's something the
    /// user actually typed. Injected blocks (`<command-name>`,
    /// `<system-reminder>`, Codex XML wrappers) and the Claude hook caveat all
    /// lead with a recognizable prefix — reject those and let the caller try
    /// the next candidate line.
    static func displayableUserText(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("<"),
              !trimmed.hasPrefix("Caveat:")
        else { return nil }
        return trimmed
    }

    /// Titles come from prompt text that can be arbitrarily long and can span
    /// lines; the record stores one bounded line (`singleLine` is the shared
    /// tooltip-safety rule — an interior newline must never survive into
    /// composed UI strings).
    static func cleanedTitle(_ raw: String) -> String {
        let flattened = singleLine(raw).trimmingCharacters(in: .whitespaces)
        return String(flattened.prefix(160))
    }
}

// MARK: - Model

/// App-level cache of the on-disk session list, shared by every window's
/// History pane. `@MainActor @Observable` singleton like `AgentMonitor`, but a
/// snapshot store rather than a derived view: disk state has no observation
/// to ride, so views call `refresh()` on appear and the model republishes.
@MainActor
@Observable
final class AgentSessionHistory {
    static let shared = AgentSessionHistory()
    init() {}
    /// Appear-triggered refreshes within this window reuse the last result —
    /// every panel remount (agents↔history flip, hidden↔full) fires one, and
    /// a full rescan is ~75MB of file-head I/O. The header's rescan button
    /// bypasses it with `force: true`.
    private static let minSecondsBetweenScans: TimeInterval = 30

    private(set) var records: [AgentSessionRecord] = []
    /// True only until the FIRST scan lands — refreshes after that keep the
    /// stale list on screen instead of flashing a spinner over it.
    private(set) var isInitialLoad = true
    /// True while a scan is actually running — drives the refresh button's
    /// spinner so the view doesn't have to fabricate its own "refreshing"
    /// state.
    private(set) var isScanning = false
    private var lastScanCompleted: Date?

    func refresh(force: Bool = false) {
        guard !isScanning else { return }
        if !force, let last = lastScanCompleted,
           Date().timeIntervalSince(last) < Self.minSecondsBetweenScans {
            return
        }
        isScanning = true
        Task {
            let result = await Task.detached(priority: .utility) {
                AgentSessionScanner.scanDefaultRoots()
            }.value
            // Equality gate: most rescans find nothing new, and an
            // `@Observable` write re-renders every window's History pane
            // regardless of change.
            if records != result {
                records = result
            }
            if isInitialLoad { isInitialLoad = false }
            lastScanCompleted = Date()
            isScanning = false
        }
    }
}

/// Short age tier shared by every "how long ago" label: `now`, `12m`, `3h`,
/// `5d`. The history rows and the notification inbox both build on this so
/// the app has one ago-vocabulary.
func relativeAgeTier(
    _ seconds: TimeInterval,
    bundle: Bundle = .kookyResources
) -> String {
    if seconds < 60 { return String(localized: "now", bundle: bundle) }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86_400))d"
}

/// History-row label: the shared tiers, then a bare `MMM d` date once
/// "n days" stops being how people think of it.
func relativeActivityLabel(
    _ date: Date,
    now: Date = Date(),
    bundle: Bundle = .kookyResources
) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 7 * 86_400 { return relativeAgeTier(seconds, bundle: bundle) }
    return monthDayFormatter.string(from: date)
}

private let monthDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter
}()

// MARK: - Filter

/// The History pane's three filters as one pure value, so the row list, the
/// agent chips, and the header count all derive from one pass. Location
/// scopes FIRST, and the chip set is taken from the scoped records BEFORE
/// agent + query narrow them: a chip for an agent with no sessions in this
/// workspace would click through to an empty list, while an agent hidden
/// only by the current chip/query must keep its chip so it can be picked.
struct SessionHistoryFilter {
    /// Every spelling of the workspace root a record's cwd may carry
    /// (`WorkspaceStore.historyWorkspaceRootPaths`); empty = every location.
    var workspaceRootPaths: [String]
    /// nil = every agent.
    var agentId: String?
    var query: String

    struct Result {
        var visible: [AgentSessionRecord] = []
        /// Agents with at least one session in scope.
        var presentAgentIds: Set<String> = []
    }

    func apply(_ records: [AgentSessionRecord]) -> Result {
        var result = Result()
        for record in records {
            if !workspaceRootPaths.isEmpty,
               !workspaceRootPaths.contains(where: { pathIsInside(record.cwdPath, root: $0) }) {
                continue
            }
            result.presentAgentIds.insert(record.agentId)
            if let agentId, record.agentId != agentId { continue }
            if !query.isEmpty,
               !record.title.localizedCaseInsensitiveContains(query),
               !record.cwdPath.localizedCaseInsensitiveContains(query) {
                continue
            }
            result.visible.append(record)
        }
        return result
    }
}

// MARK: - View

/// Right sidebar's History pane: workspace / agent / search filters over the
/// on-disk session list; a click resumes that conversation in a new tab of
/// the active workspace.
struct SessionHistoryView: View {
    @Bindable var store: WorkspaceStore
    var history = AgentSessionHistory.shared

    /// Keeps the spinner up for a beat after a click: the scan usually
    /// finishes faster than the eye, and a spinner that never visibly
    /// appears reads as a dead button. The real in-flight fact is the
    /// model's `isScanning`; this only stretches its tail.
    @State private var spinnerMinHold = false
    /// Cleared on the next successful resume, and by the banner's own ✕.
    /// `@State` is right despite this view being unmounted by the panel's
    /// mode cycle — a stale failure from before the user navigated away is
    /// exactly what shouldn't come back.
    @State private var resumeError: String?

    var body: some View {
        let filtered = SessionHistoryFilter(
            workspaceRootPaths: store.historyWorkspaceRootPaths,
            agentId: store.historyFilterAgentId,
            query: store.historySearchQuery
        ).apply(history.records)
        let visible = filtered.visible
        VStack(spacing: 0) {
            RightPanelHeader(title: "session history", count: visible.count) {
                refreshButton
            }
            searchField
            filterChips(present: filtered.presentAgentIds)
            workspaceFilterRow
            resumeErrorBanner
            if visible.isEmpty {
                PanelEmptyState(
                    symbol: "clock",
                    message: history.isInitialLoad ? "scanning…" : "no sessions found"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { record in
                            SessionHistoryRow(record: record) {
                                switch store.resumeAgentSession(record) {
                                case .success:
                                    resumeError = nil
                                case .failure(let refusal):
                                    resumeError = refusal.message(
                                        agentId: record.agentId,
                                        conversationId: record.conversationId
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { history.refresh() }
    }

    /// A refused resume is a configuration problem (launch options that
    /// disable persistence, an id this agent can't take), so it needs to say
    /// so — a click that silently does nothing reads as a broken panel.
    /// Lives here rather than in a sheet: the failure belongs to the row the
    /// user just clicked, and this panel is where they'll retry.
    @ViewBuilder
    private var resumeErrorBanner: some View {
        if let resumeError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.mono(10))
                Text(resumeError)
                    .font(Theme.mono(10.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { self.resumeError = nil } label: {
                    Image(systemName: "xmark")
                        .font(Theme.mono(9, weight: .medium))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.activityFailure)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.activityFailure.opacity(0.12))
        }
    }

    private var refreshButton: some View {
        HoverableIconButton(
            size: Theme.chromeCompactButtonSize,
            help: "Rescan sessions",
            action: {
                history.refresh(force: true)
                spinnerMinHold = true
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    spinnerMinHold = false
                }
            }
        ) {
            if history.isScanning || spinnerMinHold {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.65)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.chromeMuted)
            // Hand-drawn placeholder: on macOS a `prompt` Text ignores its
            // color modifiers and renders at the system placeholder
            // brightness, which reads glaring on dark chrome.
            ZStack(alignment: .leading) {
                if store.historySearchQuery.isEmpty {
                    Text(String(localized: "search sessions", bundle: .kookyResources))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.5))
                        .allowsHitTesting(false)
                }
                TextField("", text: $store.historySearchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeForeground)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.chromeHover)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// `present` is the agent set of the workspace-scoped records: with the
    /// workspace filter on, only agents that have sessions HERE get a chip.
    private func filterChips(present: Set<String>) -> some View {
        // The full scanned roster can't fit a 230pt panel — chips show only
        // the agents PRESENT in the scoped results (in roster order), which
        // on any one machine is a handful. The active filter's chip stays
        // even when its store scans empty, so a rescan can't silently
        // bounce the user back to `all`; the horizontal scroll is the
        // everything-installed fallback.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                filterChip(nil, label: String(localized: "all", bundle: .kookyResources))
                ForEach(AgentSessionScanner.supportedAgentIds.filter { present.contains($0) || $0 == store.historyFilterAgentId }, id: \.self) { agentId in
                    filterChip(agentId, label: AgentTemplate.builtin(id: agentId)?.title.lowercased() ?? agentId)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    /// Location is its own axis, so it gets its own row under the agent
    /// chips — a checkbox, not a member of the radio group. Shown exactly
    /// when the store has something local to scope to.
    @ViewBuilder
    private var workspaceFilterRow: some View {
        if store.historyScopeAnchor != nil {
            KookyCheckbox(
                title: String(localized: "only this workspace", bundle: .kookyResources),
                isOn: $store.historyFilterCurrentWorkspace,
                size: 10
            )
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    private func filterChip(_ agentId: String?, label: String) -> some View {
        let isActive = store.historyFilterAgentId == agentId
        return HistoryFilterChip(label: label, isActive: isActive) {
            store.historyFilterAgentId = agentId
        }
    }

}

/// Selected-capable chip for the History filter strip. This deliberately
/// mirrors `FooterSegment`: active is persistent, hover is transient, and
/// both lift the label to the foreground tier.
private struct HistoryFilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(10, weight: isActive ? .semibold : .regular))
                .foregroundStyle(
                    isActive || isHovered ? Theme.chromeForeground : Theme.chromeMuted
                )
                .padding(.horizontal, 8)
                .frame(height: 19)
                .hoverableRowBackground(isActive: isActive, isHovered: isHovered)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chromeButtonCornerRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(Theme.chromeTransition, value: isActive)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct SessionHistoryRow: View {
    let record: AgentSessionRecord
    let onResume: () -> Void
    private let template: AgentTemplate?

    @State private var isHovered = false

    init(record: AgentSessionRecord, onResume: @escaping () -> Void) {
        self.record = record
        self.onResume = onResume
        self.template = AgentTemplate.builtin(id: record.agentId)
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(asset: template?.iconAsset, fallbackSymbol: template?.symbol ?? "sparkles", size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title.isEmpty ? String(localized: "untitled", bundle: .kookyResources) : record.title)
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(record.title.isEmpty ? Theme.chromeMuted : Theme.chromeForeground)
                    .lineLimit(1)
                Text("\(record.cwd.lastPathComponent) · \(relativeActivityLabel(record.lastActivity))")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .hoverableRowBackground(isHovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(perform: onResume)
        .onHover { isHovered = $0 }
        .help(hoverText)
    }

    private var hoverText: String {
        let name = singleLine(template?.title ?? record.agentId)
        let title = singleLine(record.title.isEmpty ? String(localized: "untitled", bundle: .kookyResources) : record.title)
        let location = singleLine((record.cwd.path as NSString).abbreviatingWithTildeInPath)
        return "\(name) · \(relativeActivityLabel(record.lastActivity))\n\(title)\n\(location)"
    }
}
