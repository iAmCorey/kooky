import Darwin
import Foundation

/// Per-session kqueue watcher on `.git/HEAD` and `.git/index`. Fires
/// `onChange` (debounced ~200ms) when either file is written or atomically
/// replaced — covers branch switches, commits, and staging from any caller:
/// Claude / Codex / Gemini's Bash tools, an external terminal, etc. The OSC 7
/// (cwd) and OSC 133 (command finished) refresh paths only see the *outer*
/// shell, so an agent that runs its own subprocess shell never trips them;
/// the filesystem layer does.
@MainActor
final class GitWatcher {
    private struct WatchedFile {
        let path: String
        let source: DispatchSourceFileSystemObject
    }

    private var watches: [WatchedFile] = []
    private var watchedCwd: URL?
    private let onChange: () -> Void
    private var pendingRefresh: DispatchWorkItem?

    /// False when the watcher holds no live kqueue fds (never attached, or
    /// the gitdir vanished and the rebuild failed). The store's per-prompt
    /// hub check uses this to re-arm a shared watcher with a fresh cwd.
    var isAttached: Bool { !watches.isEmpty }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }
    // No deinit cleanup — `@MainActor` deinits run nonisolated in Swift 6, and
    // the project convention (see CLAUDE.md "Don't try to deinit-free…") is
    // to require explicit teardown. Callers MUST invoke `cancel()` before
    // dropping the watcher, or kqueue fds leak.

    /// Idempotent for live, same-cwd watchers — the same cwd with non-empty
    /// `watches` returns early. The rebuild path (tearDown then re-watch)
    /// intentionally falls through because `watches` is empty there.
    func watch(cwd: URL) {
        if watchedCwd == cwd && !watches.isEmpty { return }
        watch(cwd: cwd, resolvedGitDir: Self.findGitDir(near: cwd))
    }

    /// Hub entry: the caller already resolved the gitdir (it IS the hub's
    /// key), so don't walk the directory tree a second time. `watch(cwd:)`
    /// stays for the internal delete/rename rebuild, which must re-resolve.
    func watch(cwd: URL, resolvedGitDir: URL?) {
        if watchedCwd == cwd && !watches.isEmpty { return }
        tearDownSources()
        watchedCwd = cwd
        guard let gitDir = resolvedGitDir else { return }
        attach(path: gitDir.appendingPathComponent("HEAD").path)
        attach(path: gitDir.appendingPathComponent("index").path)
    }

    func cancel() {
        tearDownSources()
        watchedCwd = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// Stops kqueue sources without disturbing `pendingRefresh` — used by the
    /// rebuild path so a NOTE_DELETE event can both swap fds AND let the
    /// debounced refresh it just scheduled fire.
    private func tearDownSources() {
        for w in watches { w.source.cancel() }
        watches.removeAll()
    }

    private func attach(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = src.data
            self.scheduleRefresh()
            // git rewrites HEAD atomically: write `.git/HEAD.lock`, rename
            // to `.git/HEAD`. The rename unlinks our fd's old inode, so
            // future writes won't fire. Tear down + reattach to the fresh
            // file — but keep `pendingRefresh` alive (full `cancel()` here
            // would defeat the refresh we just scheduled).
            if data.contains(.delete) || data.contains(.rename), let cwd = self.watchedCwd {
                self.tearDownSources()
                // Re-check watchedCwd before rebuilding — an `onPwdChange`
                // between teardown and this fire would have set up the
                // correct new watchers already, and a stale rebuild here
                // would tear them down and re-attach to the old gitdir.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.watchedCwd == cwd else { return }
                    self.watch(cwd: cwd)
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watches.append(WatchedFile(path: path, source: src))
    }

    private func scheduleRefresh() {
        // `git checkout` touches HEAD then index in quick succession; coalesce
        // both events into one git-status refresh.
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Nearest ancestor of `cwd` (inclusive) holding a `.git` entry — the
    /// working-tree root, for a plain repo, a linked worktree, or a
    /// submodule alike (each keeps its own `.git` file or directory at its
    /// top level). Nil when `cwd` isn't inside any repo. Looser than
    /// `findGitDir != nil` on purpose: an unparseable `.git` file still
    /// marks the project boundary, it just isn't watchable.
    nonisolated static func worktreeRoot(near cwd: URL) -> URL? {
        var dir = cwd.standardizedFileURL
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Walks up from `cwd` looking for `.git`. Returns the gitdir URL when
    /// found — either the `.git/` directory itself, or the path resolved
    /// from a `.git` worktree pointer file (`gitdir: <path>`). Returns nil
    /// when not inside any repo.
    nonisolated static func findGitDir(near cwd: URL) -> URL? {
        guard let root = worktreeRoot(near: cwd) else { return nil }
        let candidate = root.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        if let contents = try? String(contentsOf: candidate, encoding: .utf8),
           let line = contents.split(whereSeparator: \.isNewline)
               .first(where: { $0.hasPrefix("gitdir: ") }) {
            let raw = String(line.dropFirst("gitdir: ".count))
                .trimmingCharacters(in: .whitespaces)
            // Submodule `.git` files commonly carry a relative path
            // (e.g. `gitdir: ../.git/modules/foo`). Resolve against
            // the `.git` file's directory, not the process cwd —
            // otherwise the watcher opens a nonexistent path and
            // silently never fires.
            return URL(fileURLWithPath: raw, relativeTo: root).standardizedFileURL
        }
        return nil
    }
}
