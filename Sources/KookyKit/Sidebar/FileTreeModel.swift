import Foundation
import os

// MARK: - Values + listing (nonisolated so tests reach them without the main actor)

/// One filesystem entry in the sidebar file tree.
struct FileNode: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    /// False for symlinks even when they point at a directory — the tree
    /// never expands through links, which is what keeps symlink cycles from
    /// being representable at all.
    let isDirectory: Bool
    let isSymlink: Bool

    /// Path-stable identity: a refresh keeps rows for surviving entries,
    /// while a rename is a new node (old row out, new row in).
    var id: String { url.path }
}

/// One visible row after flattening the expanded tree for the `LazyVStack`.
struct FileTreeRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case entry(FileNode)
        /// Non-interactive "no access" note under an expanded-but-unlistable
        /// directory. The message lives at the render site — the model only
        /// carries the state.
        case placeholder
    }

    let kind: Kind
    /// 0 = direct child of the root; drives the row's leading indent.
    let depth: Int
    /// Whether this row's directory is showing its children — baked into the
    /// row (rather than queried off the model) so expanding an *empty*
    /// directory still produces a row diff and the chevron animates.
    let isExpanded: Bool
    let id: String
}

enum FileTreeLister {
    /// Entries never shown. Other dotfiles stay visible — developers live in
    /// `.env` / `.gitignore` — but `.git` is plumbing and `.DS_Store` is
    /// Finder noise.
    static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    /// Shallow listing of one directory: `hiddenNames` filtered, directories
    /// first, Finder-style natural sort within each group. Throws on a
    /// missing/unreadable directory so callers can tell "empty" from
    /// "gone" — the model routes root failures to `rootError` and child
    /// failures to a placeholder row.
    static func children(of directory: URL) throws -> [FileNode] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        return urls.compactMap { url -> FileNode? in
            let name = url.lastPathComponent
            guard !hiddenNames.contains(name) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = values?.isSymbolicLink == true
            return FileNode(
                // `contentsOfDirectory` returns realpath'd URLs (a `/var/…` or
                // `/tmp/…` root comes back under `/private/…`); standardize the
                // `/private` back off so child ids share the root's prefix and
                // path comparisons hold — the same normalization worktree paths use.
                url: url.standardizedFileURL,
                name: name,
                isDirectory: values?.isDirectory == true && !isSymlink,
                isSymlink: isSymlink
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Result of an off-main expand cascade, merged back on the main actor.
    struct SubtreeListing: Sendable {
        var listed: [String: [FileNode]] = [:]
        var failed: Set<String> = []
    }

    /// Off-main cascade for a newly expanded directory: lists `start`, then
    /// every previously-expanded directory that just became visible beneath
    /// it (outermost first — each level's listing feeds the walk). Pure; the
    /// model merges the result on the main actor and drops it if superseded.
    static func listSubtree(start: URL, expanded: Set<String>) -> SubtreeListing {
        var result = SubtreeListing()
        var stack: [URL] = [start]
        while let dir = stack.popLast() {
            do {
                let children = try children(of: dir)
                result.listed[dir.path] = children
                for child in children where child.isDirectory && expanded.contains(child.url.path) {
                    stack.append(child.url)
                }
            } catch {
                result.failed.insert(dir.path)
            }
        }
        return result
    }

    /// Flattens the expanded tree into the visible-row array. Recursing views
    /// inside a `LazyVStack` would defeat its laziness, so the tree shape is
    /// resolved here and the view renders a flat list.
    static func flatten(
        root: URL,
        childrenByDir: [String: [FileNode]],
        expandedDirs: Set<String>,
        failedDirs: Set<String>
    ) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        // Children pushed in reverse so pop order matches display order.
        var stack: [(FileNode, Int)] =
            (childrenByDir[root.path] ?? []).reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            let path = node.url.path
            let isExpanded = node.isDirectory && expandedDirs.contains(path)
            rows.append(FileTreeRow(kind: .entry(node), depth: depth, isExpanded: isExpanded, id: path))
            guard isExpanded else { continue }
            if failedDirs.contains(path) {
                rows.append(FileTreeRow(
                    kind: .placeholder,
                    depth: depth + 1,
                    isExpanded: false,
                    id: path + "/__placeholder__"
                ))
                continue
            }
            for child in (childrenByDir[path] ?? []).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return rows
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "ico", "bmp", "tiff",
    ]

    static func symbolName(for node: FileNode) -> String {
        if node.isDirectory { return "folder.fill" }
        if imageExtensions.contains(node.url.pathExtension.lowercased()) { return "photo" }
        return "doc.text"
    }
}

// MARK: - Model

/// Sidebar file-tree state for one window: lazy per-directory listings,
/// ephemeral expansion, and kqueue watchers on the visible directories.
/// Owned by `WorkspaceStore` (not view `@State`) because the watchers hold
/// fds that need explicit teardown and the sidebar unmounts whole while
/// hidden — `FileTreeView` pauses via `activate`/`deactivate`, and
/// `WorkspaceStore.terminate()` calls `cancel()` as the window-close
/// backstop.
@MainActor
@Observable
final class FileTreeModel {
    private(set) var rootURL: URL?
    private(set) var rows: [FileTreeRow] = []
    /// Per-file `+/−` counts from the same `git diff … HEAD` the status bar
    /// aggregates, keyed by the row id (absolute standardized path). Pushed
    /// by `WorkspaceStore` on the status bar's own refresh triggers so the
    /// two can't drift.
    private(set) var gitDiff: [String: GitFileDiff] = [:]
    /// Subtree totals for every ancestor directory of a changed file —
    /// rendered only on COLLAPSED directory rows, so each change surfaces
    /// exactly once along the visible frontier (expanded dirs let their
    /// children carry the numbers).
    private(set) var gitDiffDirTotals: [String: GitFileDiff] = [:]
    /// True when the root itself can't be listed (deleted / unreadable).
    /// Recovers on the next `activate`/`setRoot`, or via the root watcher
    /// if the directory reappears at the same path.
    private(set) var rootError = false
    /// The first root listing is in flight. Cached trees stay visible during
    /// later refreshes, so this is only user-visible when a new root has no
    /// rows yet.
    private(set) var isLoading = false
    var selectedId: String?

    /// Listing cache, keyed by directory path. Retained across collapse so
    /// `flatten` has data, but every directory is re-listed at the moment it
    /// becomes visible again — kqueue only reports future changes, so a
    /// cache that sat hidden may be stale.
    private var childrenByDir: [String: [FileNode]] = [:]
    private var expandedDirs: Set<String> = []
    /// Expansion recency — newest last. Decides which directories keep their
    /// watcher when the `maxWatchedDirectories` cap bites.
    private var expansionOrder: [String] = []
    /// Expanded directories whose last listing threw; rendered as one
    /// placeholder row. Re-listing is retried whenever the dir is expanded
    /// again or its parent refreshes.
    private var failedDirs: Set<String> = []
    private var watchers: [String: DirectoryWatcher] = [:]
    /// False while the tree isn't showing (workspaces mode / sidebar hidden)
    /// — no watchers run and refreshes are skipped; caches survive.
    private var isActive = false
    /// Bumped by every `activate`; lets a stale `deactivate` be ignored.
    private var activationToken = 0
    /// Cross-thread active mount identity. A queued listing must not touch
    /// disk after the Files page has unmounted, even when its root/version
    /// are otherwise still current.
    private let liveActivationToken = OSAllocatedUnfairLock(initialState: 0)
    /// Root identity epoch — bumped by `resetState`, snapshotted by every
    /// listing, so work launched under the previous root can
    /// never merge into the new root's caches.
    private var rootEpoch = 0
    /// Cross-thread mirror of `rootEpoch` (Codex review): the MainActor
    /// epoch guard alone only stops the MERGE — a queued listing would
    /// still walk the old root's 10k/50k directories to completion on the
    /// shared serial queue, delaying every newer request behind dead
    /// work. The runner's work closure reads this before walking and bails
    /// when the root already moved.
    private let liveRootEpoch = OSAllocatedUnfairLock(initialState: 0)
    /// Latest scheduled listing version per directory. Results merge only
    /// where their version is still current. PER-DIRECTORY on purpose: a
    /// global token would let expanding B drop A's still-flying listing (A
    /// stuck "expanded but empty").
    private var dirListVersions: [String: Int] = [:]
    private var nextDirListVersion = 0
    /// Cross-thread mirror used before queued work starts. Repeated watcher
    /// refreshes for the same subtree coalesce here instead of making the
    /// serial queue walk obsolete 10k/50k-entry directories first.
    private let liveDirListVersions = OSAllocatedUnfairLock(initialState: [String: Int]())

    /// Serial background lane for every filesystem listing. Serial keeps a
    /// burst of watcher events / expands from stacking N concurrent large-
    /// directory walks on the cooperative pool; the version mirror above
    /// drops superseded queued work before it starts.
    private static let listingQueue = DispatchQueue(label: "kooky.file-tree-listing", qos: .userInitiated)

    /// How listings execute. Production uses `listingQueue`; tests inject a
    /// synchronous runner so model assertions stay deterministic.
    var listingRunner: (
        _ work: @escaping @Sendable () -> FileTreeLister.SubtreeListing,
        _ apply: @escaping @MainActor (FileTreeLister.SubtreeListing) -> Void
    ) -> Void = { work, apply in
        listingQueue.async {
            let result = work()
            DispatchQueue.main.async { apply(result) }
        }
    }

    /// Roots must resolve symlinks: shells report the *logical* cwd over
    /// OSC 7, but `contentsOfDirectory(at:)` refuses to traverse a URL whose
    /// last component is a symlink (ENOTDIR) — verified on macOS 15/26; an
    /// `isDirectory: true` hint does NOT help — which would strand the tree
    /// on "Folder unavailable" for any symlinked project dir. Resolving also
    /// realpaths the prefix, and the trailing `.standardizedFileURL` strips
    /// `/private` the same way child listings do, so root and child keys
    /// converge on one canonical form (`canonicalDiskPath`, shared with the
    /// CLI's workspace matching).
    private static func canonicalRoot(_ url: URL) -> URL {
        canonicalDiskPath(url)
    }

    /// Root + 63 most recently expanded directories. Keeps the fd budget
    /// trivial next to the default 256 soft limit; over-cap directories
    /// still refresh whenever they're re-listed on expansion.
    static let maxWatchedDirectories = 64

    /// Number of live kqueue watchers — exposed for tests.
    var watchedDirectoryCount: Int { watchers.count }

    /// Whether the tree is the mounted, visible surface right now — the
    /// authoritative "is it showing" predicate, maintained by the mount
    /// lifecycle itself (activate/deactivate). Callers gating side work
    /// (the git-diff fetch) read this instead of re-deriving sidebar
    /// content+mode+visibility shallowly.
    var isShowing: Bool { isActive }

    /// Entering files mode (or the sidebar remounting). Shows any cached rows
    /// immediately, schedules an off-main refresh of the visible subtree,
    /// and arms watchers.
    /// Returns an activation token; `deactivate(token:)` ignores stale tokens
    /// so an animated unmount's late `onDisappear` can't kill the watchers a
    /// newer mount just armed (the shared-state clobber M5.mmmm refcounted).
    @discardableResult
    func activate(root: URL?) -> Int {
        activationToken += 1
        let token = activationToken
        liveActivationToken.withLock { $0 = token }
        isActive = true
        let root = root.map(Self.canonicalRoot)
        if rootURL?.path != root?.path {
            resetState(to: root)
        }
        scheduleListing(start: rootURL)
        rebuildRows()
        return token
    }

    /// Leaving files mode (toggle back / sidebar hidden). Drops every
    /// watcher; caches and expansion survive so re-entry is instant.
    /// Pass the token `activate` returned to make the call a no-op when a
    /// newer activation superseded it; nil deactivates unconditionally.
    func deactivate(token: Int? = nil) {
        if let token, token != activationToken { return }
        isActive = false
        liveActivationToken.withLock { $0 = 0 }
        isLoading = false
        cancelAllWatchers()
    }

    /// Full teardown for `WorkspaceStore.terminate()`.
    func cancel() {
        deactivate()
        resetState(to: nil)
        rows = []
    }

    /// Active-workspace switch or cwd drift. Same path is a no-op; a new
    /// path clears expansion/caches/selection and re-lists.
    func setRoot(_ url: URL?) {
        let url = url.map(Self.canonicalRoot)
        guard rootURL?.path != url?.path else { return }
        resetState(to: url)
        guard isActive else {
            // Keep the model self-consistent while paused — the old root's
            // rows must not survive under the new `rootURL`.
            if !rows.isEmpty { rows = [] }
            return
        }
        scheduleListing(start: rootURL)
        rebuildRows()
    }

    func toggleExpanded(_ node: FileNode) {
        guard node.isDirectory else { return }
        let path = node.url.path
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
            expansionOrder.removeAll { $0 == path }
            rebuildRows()
            return
        }
        // Not in `expandedDirs` ⟹ not in `expansionOrder` — the two are
        // kept in lockstep — so a plain append suffices.
        expandedDirs.insert(path)
        expansionOrder.append(path)
        // The row expands immediately; children appear when the background
        // listing lands.
        scheduleListing(start: node.url)
        rebuildRows()
    }

    private func applyListing(
        _ listing: FileTreeLister.SubtreeListing,
        epoch: Int,
        version: Int
    ) {
        guard epoch == rootEpoch, isActive else { return }
        var changed = false
        var needsPrune = false
        let rootPath = rootURL?.path
        for (path, children) in listing.listed {
            guard dirListVersions[path] == version else { continue }
            let previous = childrenByDir[path]
            if previous != children {
                childrenByDir[path] = children
                changed = true
                if let previous {
                    let kept = Set(children.map(\.id))
                    if previous.contains(where: { !kept.contains($0.id) }) {
                        needsPrune = true
                    }
                }
            }
            if failedDirs.remove(path) != nil { changed = true }
            if path == rootPath {
                if rootError { rootError = false; changed = true }
                isLoading = false
            }
        }
        for path in listing.failed {
            guard dirListVersions[path] == version else { continue }
            if childrenByDir.removeValue(forKey: path) != nil { changed = true }
            needsPrune = true
            if path == rootPath {
                if !rootError { rootError = true; changed = true }
                isLoading = false
                failedDirs.remove(path)
            } else if failedDirs.insert(path).inserted {
                changed = true
            }
        }
        // Re-expanding or refreshing a cached directory usually lands an
        // identical listing — skip the prune walk, row rebuild, and watcher
        // re-sync entirely then.
        guard changed else { return }
        if needsPrune { pruneUnreachable() }
        rebuildRows()
    }

    /// Latest per-file diff for the current root. Filters to paths under the
    /// root and pre-computes ancestor-directory totals; no-ops when nothing
    /// changed so the per-prompt refresh doesn't re-render the tree.
    func applyGitDiff(_ diffs: [String: GitFileDiff]) {
        // No root ⟹ the diff dicts are already empty: `resetState` (the only
        // rootURL writer) clears them in the same synchronous call.
        guard let rootPath = rootURL?.path else { return }
        let prefix = rootPath + "/"
        var files: [String: GitFileDiff] = [:]
        var totals: [String: GitFileDiff] = [:]
        for (path, counts) in diffs where path.hasPrefix(prefix) {
            files[path] = counts
            var dir = (path as NSString).deletingLastPathComponent
            while dir != rootPath, dir.hasPrefix(prefix) {
                var t = totals[dir] ?? GitFileDiff(insertions: 0, deletions: 0)
                t.insertions += counts.insertions
                t.deletions += counts.deletions
                totals[dir] = t
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        if files != gitDiff { gitDiff = files }
        if totals != gitDiffDirTotals { gitDiffDirTotals = totals }
    }

    /// Watcher callback (also driven directly by tests): re-list this visible
    /// directory and its expanded descendants on the background lane.
    func refresh(dirPath: String) {
        guard isActive, let rootPath = rootURL?.path else { return }
        guard dirPath == rootPath || childrenByDir[dirPath] != nil || expandedDirs.contains(dirPath)
        else { return }
        scheduleListing(start: URL(fileURLWithPath: dirPath))
    }

    // MARK: Internals

    private func resetState(to url: URL?) {
        rootEpoch += 1
        let epoch = rootEpoch
        liveRootEpoch.withLock { $0 = epoch }
        dirListVersions.removeAll()
        liveDirListVersions.withLock { $0.removeAll() }
        nextDirListVersion = 0
        rootURL = url
        rootError = false
        isLoading = false
        selectedId = nil
        childrenByDir.removeAll()
        expandedDirs.removeAll()
        expansionOrder.removeAll()
        failedDirs.removeAll()
        gitDiff.removeAll()
        gitDiffDirTotals.removeAll()
    }

    /// Schedule one directory plus every expanded descendant beneath it.
    /// All filesystem calls stay on `listingQueue`; only version-checked
    /// cache/state merging returns to the main actor.
    private func scheduleListing(start: URL?) {
        guard let start, let rootPath = rootURL?.path else { return }
        let startPath = start.path
        let prefix = startPath.hasSuffix("/") ? startPath : startPath + "/"
        let expandedSnapshot = expandedDirs
        var affectedPaths = Set(expandedSnapshot.filter { $0.hasPrefix(prefix) })
        affectedPaths.insert(startPath)
        let affectedSnapshot = affectedPaths

        nextDirListVersion += 1
        let version = nextDirListVersion
        for path in affectedSnapshot { dirListVersions[path] = version }
        liveDirListVersions.withLock { versions in
            for path in affectedSnapshot { versions[path] = version }
        }
        if startPath == rootPath, childrenByDir[rootPath] == nil {
            isLoading = true
        }

        let epoch = rootEpoch
        let activeToken = activationToken
        let liveActivation = liveActivationToken
        let liveEpoch = liveRootEpoch
        let liveVersions = liveDirListVersions
        listingRunner({
            guard liveActivation.withLock({ $0 }) == activeToken,
                  liveEpoch.withLock({ $0 }) == epoch,
                  liveVersions.withLock({ $0[startPath] }) == version
            else { return FileTreeLister.SubtreeListing() }
            return FileTreeLister.listSubtree(start: start, expanded: expandedSnapshot)
        }, { [weak self] listing in
            self?.applyListing(listing, epoch: epoch, version: version)
        })
    }

    /// Drops cache/expansion/failure state for directories no longer
    /// reachable from the root through the current cache — a deleted
    /// subtree must not keep stale rows (or, via `syncWatchers`, fds) alive.
    private func pruneUnreachable() {
        // No root ⟹ every cache is already empty (only `resetState` clears
        // them, and it nils the root in the same call; nothing populates a
        // cache without a root). So there's nothing to prune here.
        guard let rootPath = rootURL?.path else { return }
        var reachable: Set<String> = [rootPath]
        var stack: [String] = [rootPath]
        while let dir = stack.popLast() {
            for child in childrenByDir[dir] ?? [] where child.isDirectory {
                let path = child.url.path
                if reachable.insert(path).inserted {
                    stack.append(path)
                }
            }
        }
        childrenByDir = childrenByDir.filter { reachable.contains($0.key) }
        expandedDirs = expandedDirs.filter { reachable.contains($0) }
        expansionOrder = expansionOrder.filter { expandedDirs.contains($0) }
        failedDirs = failedDirs.filter { reachable.contains($0) }
        dirListVersions = dirListVersions.filter { reachable.contains($0.key) }
        let reachableSnapshot = reachable
        liveDirListVersions.withLock { versions in
            versions = versions.filter { reachableSnapshot.contains($0.key) }
        }
    }

    /// Aligns live watchers with what's on screen: the root, plus the most
    /// recently expanded visible directories under the cap. `start()` is
    /// idempotent and retries a failed attach, so re-syncing also heals a
    /// watcher whose directory briefly disappeared.
    private func syncWatchers() {
        guard isActive, let rootPath = rootURL?.path else {
            cancelAllWatchers()
            return
        }
        var desired: Set<String> = [rootPath]
        if !rootError {
            // The visible expanded dirs are exactly the expanded directory
            // rows just emitted — `rebuildRows` tail-calls syncWatchers, so
            // `rows` is always fresh here and no separate tree walk is
            // needed.
            let visible = Set(rows.compactMap { row -> String? in
                guard case .entry(let node) = row.kind, node.isDirectory, row.isExpanded
                else { return nil }
                return node.url.path
            })
            desired.formUnion(
                expansionOrder.reversed()
                    .filter { visible.contains($0) }
                    .prefix(Self.maxWatchedDirectories - 1)
            )
        }
        for (path, watcher) in watchers where !desired.contains(path) {
            watcher.cancel()
            watchers.removeValue(forKey: path)
        }
        for path in desired {
            if let existing = watchers[path] {
                existing.start()
            } else {
                let watcher = DirectoryWatcher(directory: URL(fileURLWithPath: path)) { [weak self] in
                    self?.refresh(dirPath: path)
                }
                watcher.start()
                watchers[path] = watcher
            }
        }
    }

    /// Drop every live watcher (each owns a kqueue fd) — shared by
    /// `deactivate()` and the no-root guard in `syncWatchers()`.
    private func cancelAllWatchers() {
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
    }

    private func rebuildRows() {
        // Tail-calling syncWatchers here is the single ordering-enforcement
        // point: the watcher set is derived from `rows`, so the wrong order
        // (sync against stale rows) is unrepresentable at call sites.
        defer { syncWatchers() }
        guard let root = rootURL, !rootError else {
            if !rows.isEmpty { rows = [] }
            if selectedId != nil { selectedId = nil }
            return
        }
        let newRows = FileTreeLister.flatten(
            root: root,
            childrenByDir: childrenByDir,
            expandedDirs: expandedDirs,
            failedDirs: failedDirs
        )
        // Skip the assign when nothing changed — `.DS_Store` churn fires the
        // watcher even though the entry is filtered, and an equal-array set
        // would re-render every visible row.
        if newRows != rows { rows = newRows }
        if let selected = selectedId, !newRows.contains(where: { $0.id == selected }) {
            selectedId = nil
        }
    }
}
