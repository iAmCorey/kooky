import Foundation

/// A project is a folder. It is the immutable anchor a group of workspaces
/// shares: the workspace list nests under it, every new tab spawned from one
/// of its workspaces starts at `rootPath`, and `git worktree` operations are
/// project-level decisions rather than per-workspace ones.
///
/// `rootPath` is `let` on purpose — a project IS its folder, so nothing may
/// re-point it. A worktree created from a project is not a second project; it
/// is one more `Workspace` under this project whose own root is the worktree
/// directory (`Workspace.worktreePath`).
///
/// The single exception is the SSH group (`isSSHGroup`): a remote host has no
/// local folder to be a project, yet its workspaces still need a row to nest
/// under, so one project collects all of them. Its `rootPath` is
/// `sshGroupRoot`, a sentinel no filesystem path can compare equal to, which
/// keeps it out of `project(forRoot:)`, git probing and worktree machinery.
@MainActor
@Observable
final class Project: Identifiable {
    /// Sentinel root for the SSH group. Scheme-bearing on purpose: every real
    /// project root goes through `URL(fileURLWithPath:)`, so this can never
    /// collide with a folder.
    static let sshGroupRoot = URL(string: "kooky-ssh://remote")!

    let id: UUID
    /// Absolute, standardized folder root. Never mutated. `sshGroupRoot` for
    /// the SSH group.
    let rootPath: URL
    /// True for the one project that owns every SSH workspace.
    let isSSHGroup: Bool
    /// Sidebar label: "SSH" for the SSH group > folder name > "Home" for `~`.
    /// There is no rename: a project *is* its folder, so a name that no longer
    /// matches the folder would let two identical-looking projects point at
    /// two different folders.
    var title: String {
        if isSSHGroup { return "SSH" }
        if rootPath.path == homeDirectoryPath { return "Home" }
        let last = rootPath.lastPathComponent
        return last.isEmpty ? rootPath.path : last
    }

    init(id: UUID = UUID(), rootPath: URL, isSSHGroup: Bool = false) {
        self.id = id
        self.rootPath = rootPath
        self.isSSHGroup = isSSHGroup
    }
}
