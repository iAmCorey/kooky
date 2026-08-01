import Foundation

/// On-disk shape of `WorkspaceStore`. Just the metadata — engine state
/// (scrollback, in-flight processes) can't survive PTY exit, so a restored
/// workspace re-spawns a fresh `LibghosttyEngine` per leaf and lands it in
/// the saved cwd via `TerminalSessionConfig.workingDirectory`.
struct PersistedState: Codable, Equatable {
    var workspaces: [PersistedWorkspace]
    var activeWorkspaceId: UUID?
    var sidebarMode: SidebarMode?
    var rightSidebarMode: SidebarMode?
    /// Optional so state.json files written before the file-tree toggle
    /// existed still decode (nil → `.workspaces`).
    var sidebarContent: SidebarContent?
    /// Optional so state.json files written before the History pane existed
    /// still decode (nil → `.agents`).
    var rightSidebarContent: RightSidebarContent?
    /// Optional so pre-resizable-sidebar state files decode (nil → the
    /// design width). Clamped on restore, not trusted from disk.
    var sidebarWidth: Double?
}

/// Root of the multi-window `state.json`. Each `PersistedWindow` is one
/// kooky window's `WorkspaceStore`; array order is window restore order.
struct PersistedApp: Codable, Equatable {
    var windows: [PersistedWindow]
    var pendingRemoteReaps: [PersistedRemoteReap]

    init(
        windows: [PersistedWindow],
        pendingRemoteReaps: [PersistedRemoteReap] = []
    ) {
        self.windows = windows
        self.pendingRemoteReaps = pendingRemoteReaps
    }

    private enum CodingKeys: String, CodingKey {
        case windows
        case pendingRemoteReaps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decode([PersistedWindow].self, forKey: .windows)
        pendingRemoteReaps = try container.decodeIfPresent(
            [PersistedRemoteReap].self,
            forKey: .pendingRemoteReaps
        ) ?? []
    }
}

struct PersistedRemoteReap: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { runtimeToken }
    let runtimeToken: UUID
    let destination: String
    let sshPort: UInt16?
    let identityFile: String?
    let createdAt: Date

    init(
        runtimeToken: UUID,
        destination: String,
        sshPort: UInt16?,
        identityFile: String?,
        createdAt: Date = Date()
    ) {
        self.runtimeToken = runtimeToken
        self.destination = destination
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.createdAt = createdAt
    }

    var controlConfiguration: RemoteControlChannelConfiguration {
        RemoteControlChannelConfiguration(
            destination: destination,
            runtimeToken: runtimeToken,
            sshPort: sshPort,
            identityFile: identityFile
        )
    }
}

/// Window frame (size / position) is intentionally not persisted — kooky
/// has never restored window geometry; restored windows just cascade.
struct PersistedWindow: Codable, Equatable {
    var id: UUID
    var state: PersistedState
}

struct PersistedWorkspace: Codable, Equatable {
    var id: UUID
    var workingDirectoryPath: String
    var root: PersistedPaneNode
    var activePaneId: UUID?
    var customTitle: String?
    /// nil = top-level workspace; non-nil = this is a git worktree whose
    /// source workspace persisted with this id. Decoded with
    /// `decodeIfPresent` so pre-worktree `state.json` files still load.
    var worktreeParentId: UUID?
    var worktreeBranch: String?
    /// Disk root captured at worktree-create time. Separate from
    /// `workingDirectoryPath` so the latter can drift with OSC 7 cwd
    /// reports without breaking close/reconcile path lookups.
    var worktreePath: String?
    /// SSH destination of an SSH workspace. Decoded as optional so state
    /// files written before the field restore as plain local workspaces.
    var sshRemoteHost: String?
    /// Authoritative workspace transport. Optional in the persisted model so
    /// state written before Mosh support can migrate from `sshRemoteHost`.
    var transport: WorkspaceTransport?
    /// The workspace's tag. Exactly one of `tagPreset` (a `WorkspaceColorTag`
    /// raw value) and `tagCustomHex` is set, which keeps "the user picked this
    /// themselves" in the file rather than re-deriving it by comparing colours.
    /// Flat optionals rather than a nested object so a hand-edited or truncated
    /// `state.json` degrades one field at a time instead of failing the restore.
    var tagPreset: String?
    var tagCustomHex: String?
    var tagName: String?

    @MainActor
    init(_ ws: Workspace) {
        self.id = ws.id
        self.workingDirectoryPath = ws.workingDirectory.path
        self.root = PersistedPaneNode(ws.root)
        self.activePaneId = ws.activePaneId
        self.customTitle = ws.customTitle
        self.worktreeParentId = ws.worktreeParentId
        self.worktreeBranch = ws.worktreeBranch
        self.worktreePath = ws.worktreePath?.path
        self.transport = ws.transport.normalized()
        // Dual-write the real destination. Older Kooky releases therefore
        // degrade a Mosh workspace to a usable SSH workspace, never local.
        self.sshRemoteHost = ws.remoteDestination
        self.tagPreset = ws.tag?.color.preset?.rawValue
        self.tagCustomHex = ws.tag?.color.customHex
        self.tagName = ws.tag?.name
    }

    init(id: UUID, workingDirectoryPath: String, root: PersistedPaneNode, activePaneId: UUID? = nil, customTitle: String? = nil, worktreeParentId: UUID? = nil, worktreeBranch: String? = nil, worktreePath: String? = nil, sshRemoteHost: String? = nil, transport: WorkspaceTransport? = nil, tagPreset: String? = nil, tagCustomHex: String? = nil, tagName: String? = nil) {
        self.id = id
        self.workingDirectoryPath = workingDirectoryPath
        self.root = root
        self.activePaneId = activePaneId
        self.customTitle = customTitle
        self.worktreeParentId = worktreeParentId
        self.worktreeBranch = worktreeBranch
        self.worktreePath = worktreePath
        let resolved = (transport ?? .ssh(destination: sshRemoteHost)).normalized()
        self.transport = resolved
        self.sshRemoteHost = resolved.remoteDestination
        self.tagPreset = tagPreset
        self.tagCustomHex = tagCustomHex
        self.tagName = tagName
    }

    private enum CodingKeys: String, CodingKey {
        case id, workingDirectoryPath, root, activePaneId, customTitle
        case worktreeParentId, worktreeBranch, worktreePath, sshRemoteHost, transport, tagPreset, tagCustomHex, tagName
        // Legacy keys
        case tabs, activeTabId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workingDirectoryPath, forKey: .workingDirectoryPath)
        try c.encode(root, forKey: .root)
        try c.encodeIfPresent(activePaneId, forKey: .activePaneId)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        try c.encodeIfPresent(worktreeParentId, forKey: .worktreeParentId)
        try c.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
        try c.encodeIfPresent(worktreePath, forKey: .worktreePath)
        let resolved = resolvedTransport
        try c.encode(resolved, forKey: .transport)
        try c.encodeIfPresent(resolved.remoteDestination, forKey: .sshRemoteHost)
        try c.encodeIfPresent(tagPreset, forKey: .tagPreset)
        try c.encodeIfPresent(tagCustomHex, forKey: .tagCustomHex)
        try c.encodeIfPresent(tagName, forKey: .tagName)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workingDirectoryPath = try c.decode(String.self, forKey: .workingDirectoryPath)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        worktreeParentId = try c.decodeIfPresent(UUID.self, forKey: .worktreeParentId)
        worktreeBranch = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        sshRemoteHost = try c.decodeIfPresent(String.self, forKey: .sshRemoteHost)
        if c.contains(.transport) {
            transport = (try? c.decode(WorkspaceTransport.self, forKey: .transport))
                ?? .unsupported(
                    kind: "unknown",
                    destination: WorkspaceTransport.normalizedNonEmpty(sshRemoteHost)
                )
        } else if let destination = WorkspaceTransport.normalizedNonEmpty(sshRemoteHost) {
            transport = .ssh(destination: destination)
        } else {
            transport = .local
        }
        tagPreset = try c.decodeIfPresent(String.self, forKey: .tagPreset)
        tagCustomHex = try c.decodeIfPresent(String.self, forKey: .tagCustomHex)
        tagName = try c.decodeIfPresent(String.self, forKey: .tagName)
        if let root = try c.decodeIfPresent(PersistedPaneNode.self, forKey: .root) {
            self.root = root
            self.activePaneId = try c.decodeIfPresent(UUID.self, forKey: .activePaneId)
        } else {
            // Legacy schema: flat `tabs: [PersistedTab]`. Wrap into a single Pane.
            let legacy = try c.decode([PersistedTab].self, forKey: .tabs)
            let activeTabId = try c.decodeIfPresent(UUID.self, forKey: .activeTabId)
            let pane = PersistedPane(
                id: UUID(),
                tabs: legacy,
                activeTabId: activeTabId
            )
            self.root = PersistedPaneNode(id: pane.id, kind: .pane(pane))
            self.activePaneId = pane.id
        }
    }

    var resolvedTransport: WorkspaceTransport {
        if let transport {
            return transport.normalized()
        }
        if let destination = WorkspaceTransport.normalizedNonEmpty(sshRemoteHost) {
            return .ssh(destination: destination)
        }
        return .local
    }
}

struct PersistedPaneNode: Codable, Equatable {
    var id: UUID
    var kind: PersistedPaneKind
}

indirect enum PersistedPaneKind: Equatable {
    case pane(PersistedPane)
    case split(orientation: SplitOrientation, first: PersistedPaneNode, second: PersistedPaneNode, fraction: Double)
}

extension PersistedPaneNode {
    @MainActor
    init(_ node: PaneNode) {
        self.id = node.id
        switch node.content {
        case .pane(let pane):
            self.kind = .pane(PersistedPane(pane))
        case .split(let orientation, let first, let second, let fraction):
            self.kind = .split(
                orientation: orientation,
                first: PersistedPaneNode(first),
                second: PersistedPaneNode(second),
                fraction: fraction
            )
        }
    }
}

extension PersistedPaneKind: Codable {
    private enum CodingKeys: String, CodingKey { case pane, split }

    private struct SplitPayload: Codable, Equatable {
        var orientation: SplitOrientation
        var first: PersistedPaneNode
        var second: PersistedPaneNode
        var fraction: Double
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let p):
            try c.encode(p, forKey: .pane)
        case .split(let orient, let first, let second, let fraction):
            try c.encode(
                SplitPayload(orientation: orient, first: first, second: second, fraction: fraction),
                forKey: .split
            )
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try c.decodeIfPresent(PersistedPane.self, forKey: .pane) {
            self = .pane(pane)
        } else if let payload = try c.decodeIfPresent(SplitPayload.self, forKey: .split) {
            self = .split(
                orientation: payload.orientation,
                first: payload.first,
                second: payload.second,
                fraction: payload.fraction
            )
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .pane, in: c,
                debugDescription: "PersistedPaneKind requires either pane or split"
            )
        }
    }
}

struct PersistedPane: Codable, Equatable {
    var id: UUID
    var tabs: [PersistedTab]
    var activeTabId: UUID?

    @MainActor
    init(_ pane: Pane) {
        self.id = pane.id
        self.tabs = pane.tabs.map(PersistedTab.init)
        self.activeTabId = pane.activeTabId
    }

    init(id: UUID, tabs: [PersistedTab], activeTabId: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

struct PersistedTab: Codable, Equatable {
    var id: UUID
    var agentId: String
    var currentDirectoryPath: String
    var customTitle: String?
    /// Optional — only Claude reports it today. Decoded with
    /// `decodeIfPresent` so state.json files written by pre-resume kooky
    /// versions still load.
    var conversationId: String?

    @MainActor
    init(_ session: Session) {
        self.id = session.id
        self.agentId = session.agent.id
        self.currentDirectoryPath = session.currentDirectory.path
        self.customTitle = session.customTitle
        self.conversationId = session.conversationId
    }

    init(id: UUID, agentId: String, currentDirectoryPath: String, customTitle: String? = nil, conversationId: String? = nil) {
        self.id = id
        self.agentId = agentId
        self.currentDirectoryPath = currentDirectoryPath
        self.customTitle = customTitle
        self.conversationId = conversationId
    }
}

@MainActor
protocol Persistence {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
    func recordPendingRemoteReap(_ reap: PersistedRemoteReap)
    func clearPendingRemoteReap(runtimeToken: UUID)
}

extension Persistence {
    func recordPendingRemoteReap(_ reap: PersistedRemoteReap) {}
    func clearPendingRemoteReap(runtimeToken: UUID) {}
}

/// Owns the single `state.json` for the whole app. Holds every window's
/// `PersistedState` in memory (ordered) and writes the file synchronously
/// on each change. `WorkspaceStore`s never touch this directly — each gets
/// a `WindowPersistence` scoped to its own `windowId`.
@MainActor
final class AppPersistence {
    /// The real `state.json`. Tests inject a temp path via `init(fileURL:)`.
    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("kooky", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private let fileURL: URL
    private var windows: [PersistedWindow]
    private var pendingRemoteReaps: [PersistedRemoteReap]
    private var didSchedulePendingRemoteReaps = false

    init(fileURL: URL = AppPersistence.defaultFileURL) {
        self.fileURL = fileURL
        let app = Self.loadAppFromDisk(from: fileURL)
        windows = app.windows
        pendingRemoteReaps = app.pendingRemoteReaps
    }

    /// Window ids in restore order — `AppDelegate` rebuilds one window each.
    var windowIds: [UUID] { windows.map(\.id) }

    func state(for id: UUID) -> PersistedState? {
        windows.first { $0.id == id }?.state
    }

    /// Upserts a window's state — a new id appends (so a `⌘⇧N` window
    /// restores last) — and writes the file. The write is synchronous:
    /// `WorkspaceStore.scheduleSave` already debounces upstream, and a
    /// closing window must reach disk before the process can exit.
    func setWindow(_ id: UUID, state: PersistedState) {
        if let idx = windows.firstIndex(where: { $0.id == id }) {
            windows[idx].state = state
        } else {
            windows.append(PersistedWindow(id: id, state: state))
        }
        writeToDisk()
    }

    func removeWindow(_ id: UUID) {
        windows.removeAll { $0.id == id }
        writeToDisk()
    }

    func recordPendingRemoteReap(_ reap: PersistedRemoteReap) {
        pendingRemoteReaps.removeAll { $0.runtimeToken == reap.runtimeToken }
        pendingRemoteReaps.append(reap)
        writeToDisk()
    }

    func clearPendingRemoteReap(runtimeToken: UUID) {
        let previousCount = pendingRemoteReaps.count
        pendingRemoteReaps.removeAll { $0.runtimeToken == runtimeToken }
        if pendingRemoteReaps.count != previousCount { writeToDisk() }
    }

    /// Startup cleanup is deliberately non-interactive and non-blocking.
    /// Failed/unauthenticated hosts retain their lease for a later launch;
    /// the remote Mosh timeout remains the final orphan backstop.
    func schedulePendingRemoteReaps() {
        guard !didSchedulePendingRemoteReaps else { return }
        didSchedulePendingRemoteReaps = true
        for reap in pendingRemoteReaps {
            RemoteCleanupExecutor.run(configuration: reap.controlConfiguration) {
                [weak self] succeeded in
                guard succeeded else { return }
                Task { @MainActor [weak self] in
                    self?.clearPendingRemoteReap(runtimeToken: reap.runtimeToken)
                }
            }
        }
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(PersistedApp(
            windows: windows,
            pendingRemoteReaps: pendingRemoteReaps
        )) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Reads `state.json`, accepting both the current `{windows:[…]}` shape
    /// and the legacy bare `PersistedState` (pre-multi-window) — a legacy
    /// file migrates to one window. Returns `[]` for a missing / corrupt file.
    static func loadFromDisk(from url: URL) -> [PersistedWindow] {
        loadAppFromDisk(from: url).windows
    }

    static func loadAppFromDisk(from url: URL) -> PersistedApp {
        guard let data = try? Data(contentsOf: url) else {
            return PersistedApp(windows: [])
        }
        let decoder = JSONDecoder()
        if let app = try? decoder.decode(PersistedApp.self, from: data) {
            return app
        }
        if let legacy = try? decoder.decode(PersistedState.self, from: data) {
            return PersistedApp(windows: [
                PersistedWindow(id: UUID(), state: legacy),
            ])
        }
        return PersistedApp(windows: [])
    }
}

/// A `Persistence` scoped to one window's slice of the shared `state.json`.
/// `WorkspaceStore` uses it like any `Persistence` and never knows it's one
/// window among several.
@MainActor
struct WindowPersistence: Persistence {
    let windowId: UUID
    let app: AppPersistence

    func load() -> PersistedState? {
        app.schedulePendingRemoteReaps()
        return app.state(for: windowId)
    }
    func save(_ state: PersistedState) { app.setWindow(windowId, state: state) }
    func recordPendingRemoteReap(_ reap: PersistedRemoteReap) {
        app.recordPendingRemoteReap(reap)
    }
    func clearPendingRemoteReap(runtimeToken: UUID) {
        app.clearPendingRemoteReap(runtimeToken: runtimeToken)
    }
}
