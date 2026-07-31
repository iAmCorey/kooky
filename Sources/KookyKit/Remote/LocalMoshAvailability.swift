import Foundation

/// Fast, side-effect-free preflight for the Remote Workspace sheet.
///
/// The final authority remains `kooky-mosh`, which runs after the user's
/// interactive shell has restored its PATH. GUI applications often inherit a
/// smaller PATH, so a miss here is a warning rather than a launch prohibition.
enum LocalMoshAvailability {
    static func executablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> String? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.nix-profile/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
        ]

        var visited = Set<String>()
        for directory in pathDirectories + commonDirectories {
            guard !directory.isEmpty, visited.insert(directory).inserted else {
                continue
            }
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("mosh")
                .path
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }
}
