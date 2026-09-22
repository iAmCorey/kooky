import Darwin
import Foundation

/// Project-context environment indicators surfaced in the pane status bar.
struct ProjectEnvironment: Equatable {
    var pythonVenv: String?
    var nodeVersion: String?
    var nvmDirectory: String?
    var proxy: ProxyInfo?

    init(
        pythonVenv: String? = nil,
        nodeVersion: String? = nil,
        nvmDirectory: String? = nil,
        proxy: ProxyInfo? = nil
    ) {
        self.pythonVenv = pythonVenv
        self.nodeVersion = nodeVersion
        self.nvmDirectory = nvmDirectory
        self.proxy = proxy
    }

    static let empty = ProjectEnvironment()
    var isEmpty: Bool { pythonVenv == nil && nodeVersion == nil && proxy == nil }
}

/// Shell-level proxy configuration. `summary` is the compact `host:port` for
/// the status-bar pill (taken from the highest-priority non-empty proxy var,
/// in the order `https_proxy` → `http_proxy` → `all_proxy`). `entries`
/// preserves the full original `name=value` strings — surfaced in the
/// click-to-open popover so users can see which scheme/credentials each tool
/// would actually pick up.
struct ProxyInfo: Equatable {
    let summary: String
    let entries: [String]

    static let variableNames = ["https_proxy", "http_proxy", "all_proxy"]

    /// The shell integration supplies the shell-specific implementation.
    static func unsetCommand(for name: String) -> String? {
        let name = name.lowercased()
        guard variableNames.contains(name) else { return nil }
        return "_kooky_unset_proxy \(name) \(name.uppercased())"
    }
}

/// Extracts status-bar env from a shell env snapshot, then falls back to
/// project files (`.nvmrc`, `.node-version`, `pyvenv.cfg`) when the live
/// shell hasn't reported anything yet. `WorkspaceStore` supplies prompt-hook
/// env when available; `detect(cwd:pid:)` is only the initial/fallback path.
enum EnvironmentDetector {
    static func detect(cwd: URL, pid: pid_t?) -> ProjectEnvironment {
        let shellEnv = pid.flatMap { ProcessEnvReader.readEnv(pid: $0) } ?? [:]
        return extract(shellEnv: shellEnv, cwd: cwd)
    }

    /// Pure function — synthetic shell env for unit tests.
    static func extract(shellEnv: [String: String], cwd: URL, allowProjectFallback: Bool = true) -> ProjectEnvironment {
        ProjectEnvironment(
            pythonVenv: detectPythonVenv(shellEnv: shellEnv, cwd: cwd, allowProjectFallback: allowProjectFallback),
            nodeVersion: detectNodeVersion(shellEnv: shellEnv, cwd: cwd, allowProjectFallback: allowProjectFallback),
            nvmDirectory: normalizedNonEmpty(shellEnv["NVM_DIR"]),
            proxy: detectProxy(shellEnv: shellEnv)
        )
    }

    /// Inspects the three common shell-proxy vars. Order is `https_proxy`
    /// first (the var most tools actually consult — HTTPS dominates modern
    /// traffic), then `http_proxy`, then `all_proxy` (covers socks5 setups).
    /// `summary` parses `host:port` out of whichever wins; `entries` keeps
    /// the raw `name=value` for every non-empty var so the popover can show
    /// the full picture.
    private static func detectProxy(shellEnv: [String: String]) -> ProxyInfo? {
        let pairs = ProxyInfo.variableNames.compactMap { name -> (name: String, value: String)? in
            guard let value = normalizedNonEmpty(shellEnv[name]) else { return nil }
            return (name, value)
        }
        guard !pairs.isEmpty else { return nil }
        let summary = pairs.lazy.compactMap { parseHostPort($0.value) }.first ?? pairs[0].value
        return ProxyInfo(summary: summary, entries: pairs.map { "\($0.name)=\($0.value)" })
    }

    /// Strips scheme + credentials from a proxy URL, returning `host:port`.
    /// Wraps IPv6 hosts in brackets — macOS URLComponents keeps the brackets
    /// for v6 hosts already; normalize first to avoid `[[::1]]`.
    fileprivate static func parseHostPort(_ raw: String) -> String? {
        let normalized = raw.contains("://") ? raw : "http://" + raw
        guard let components = URLComponents(string: normalized),
              let host = components.host, !host.isEmpty else {
            return nil
        }
        let unwrapped = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        let displayHost = unwrapped.contains(":") ? "[\(unwrapped)]" : unwrapped
        if let port = components.port {
            return "\(displayHost):\(port)"
        }
        return displayHost
    }

    /// `VIRTUAL_ENV` is the standard env var venv / virtualenv writes when
    /// activated. `CONDA_DEFAULT_ENV` is conda's. Project-file fallback
    /// catches the case of cd-ing into a project whose user hasn't sourced
    /// activate yet — we surface the venv directory name so the slot lights
    /// up before activation.
    private static func detectPythonVenv(shellEnv: [String: String], cwd: URL, allowProjectFallback: Bool) -> String? {
        if let venv = shellEnv["VIRTUAL_ENV"], !venv.isEmpty {
            return (venv as NSString).lastPathComponent
        }
        if let conda = shellEnv["CONDA_DEFAULT_ENV"], !conda.isEmpty {
            return conda
        }
        guard allowProjectFallback else { return nil }
        return walkUpVenv(cwd: cwd.path)
    }

    /// `NVM_BIN` is set by `nvm use` and points to the active version's bin
    /// directory: `~/.nvm/versions/node/v25.1.0/bin`. The grand-parent
    /// directory's name is the version. mise / asdf don't surface a
    /// per-version env var — fall through to dotfile content.
    private static func detectNodeVersion(shellEnv: [String: String], cwd: URL, allowProjectFallback: Bool) -> String? {
        if let live = normalizedVersion(shellEnv["KOOKY_NODE_VERSION"]) {
            return live
        }
        if let bin = shellEnv["NVM_BIN"], !bin.isEmpty,
           let version = nvmVersion(fromBinPath: bin) {
            return version
        }
        guard allowProjectFallback else { return nil }
        if let v = readVersionFile(cwd: cwd.path, names: [".nvmrc", ".node-version"]) {
            return nodeVersionWithVPrefix(v)
        }
        return nil
    }

    private static func walkUpVenv(cwd: String) -> String? {
        var path = cwd
        while !path.isEmpty {
            for name in [".venv", "venv", "env"] {
                let venv = (path as NSString).appendingPathComponent(name)
                let cfg = (venv as NSString).appendingPathComponent("pyvenv.cfg")
                if FileManager.default.fileExists(atPath: cfg) {
                    return name
                }
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { return nil }
            path = parent
        }
        return nil
    }

    private static func readVersionFile(cwd: String, names: [String]) -> String? {
        var path = cwd
        while !path.isEmpty {
            for name in names {
                let candidate = (path as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate),
                   let content = try? String(contentsOfFile: candidate, encoding: .utf8) {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { return nil }
            path = parent
        }
        return nil
    }

    private static func nvmVersion(fromBinPath bin: String) -> String? {
        let parts = bin.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4,
              parts.last == "bin",
              parts[parts.count - 3] == "node",
              parts[parts.count - 4] == "versions"
        else { return nil }
        let version = parts[parts.count - 2]
        return version.isEmpty ? nil : version
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedVersion(_ value: String?) -> String? {
        guard let trimmed = normalizedNonEmpty(value) else { return nil }
        return nodeVersionWithVPrefix(trimmed)
    }
}

/// `v` is the canonical Node version prefix (`v25.1.0`, not `25.1.0`),
/// but `.nvmrc` and `.node-version` also accept aliases like `lts/*`,
/// `lts/iron`, `node`, `system` — those must pass through verbatim, or
/// the sidebar will display gibberish (`vlts/*`) and the switch popover
/// won't match anything in the installed-versions list.
fileprivate func nodeVersionWithVPrefix(_ version: String) -> String {
    if version.hasPrefix("v") { return version }
    if let first = version.first, first.isNumber { return "v\(version)" }
    return version
}

enum NodeVersionInventory {
    static func installedVersions(nvmDirectory: String?) -> [String] {
        let nvmDir = normalizedNvmDirectory(nvmDirectory)
        let nodeDir = URL(fileURLWithPath: nvmDir, isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: nodeDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let versions = urls.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            return name.isEmpty ? nil : nodeVersionWithVPrefix(name)
        }
        return sortVersions(Array(Set(versions)))
    }

    static func isSameVersion(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return nodeVersionWithVPrefix(lhs) == nodeVersionWithVPrefix(rhs)
    }

    static func sortVersions(_ versions: [String]) -> [String] {
        versions.sorted { lhs, rhs in
            Version.compare(lhs, rhs) == .orderedDescending
        }
    }

    /// Executed through the shell editor bridge, with the version kept as one
    /// literal argument even when an installed directory contains shell syntax.
    static func shellUseCommand(version: String) -> String {
        "nvm use \(KookyShellIntegration.quote(version))\r"
    }

    private static func normalizedNvmDirectory(_ nvmDirectory: String?) -> String {
        guard let nvmDirectory, !nvmDirectory.isEmpty else {
            return (NSHomeDirectory() as NSString).appendingPathComponent(".nvm")
        }
        if nvmDirectory.hasPrefix("~") {
            let suffix = String(nvmDirectory.dropFirst())
            return NSHomeDirectory() + suffix
        }
        return nvmDirectory
    }

}

/// Dotted-version compare shared by the nvm version sorter and the GitHub
/// update checker. Each segment is parsed up to its first non-digit
/// (`"0-rc"` → `0`); `localizedStandardCompare` breaks ties on equal
/// numeric prefixes. Sufficient for release tags like `v0.12.0`; pre-release
/// suffixes are not semver-aware, so don't rely on `0.12.0-rc.1 < 0.12.0`.
enum Version {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericParts(lhs)
        let right = numericParts(rhs)
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }
        return lhs.localizedStandardCompare(rhs)
    }

    static func numericParts(_ version: String) -> [Int] {
        stripLeadingV(version).split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }

    static func stripLeadingV(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}
