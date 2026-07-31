import Foundation

enum RemoteLaunchFailureMarker {
    private static let prefix = "kooky-remote-failure:"

    static func title(for failure: RemoteLaunchFailure) -> String {
        switch failure {
        case .executableMissing(let executable):
            return "\(prefix)missing:\(safe(executable))"
        case .processExited(let code, _):
            return "\(prefix)exit:\(code.map(String.init) ?? "unknown")"
        case .udpBlocked:
            return "\(prefix)udp-blocked"
        case .authenticationFailed:
            return "\(prefix)authentication"
        case .invalidConfiguration, .bootstrapRejected:
            return "\(prefix)configuration"
        }
    }

    static func parse(_ title: String) -> RemoteLaunchFailure? {
        guard title.hasPrefix(prefix) else { return nil }
        let payload = String(title.dropFirst(prefix.count))
        if payload.hasPrefix("missing:") {
            let executable = String(payload.dropFirst("missing:".count))
            return .executableMissing(executable.isEmpty ? "mosh" : executable)
        }
        if payload.hasPrefix("exit:") {
            let raw = String(payload.dropFirst("exit:".count))
            return .processExited(code: Int32(raw), message: nil)
        }
        switch payload {
        case "udp-blocked": return .udpBlocked
        case "authentication": return .authenticationFailed
        case "configuration": return .invalidConfiguration("remote launch rejected")
        default: return nil
        }
    }

    static func isMarker(_ title: String) -> Bool {
        title.hasPrefix(prefix)
    }

    private static func safe(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber || "._-".contains($0) }.prefix(64))
    }
}

/// A neutral, post-establishment mosh-client exit. Unlike a launch failure it
/// offers no SSH fallback: the interactive session ran and then its remote
/// command exited non-zero, exactly like a local shell that exits non-zero and
/// keeps its buffer on screen. The wrapper only emits this once mosh has run
/// long enough to have established, so a fast connect/launch error still routes
/// to `RemoteLaunchFailureMarker` and its actionable fallback.
enum RemoteSessionExitMarker {
    private static let prefix = "kooky-remote-exit:"

    static func title(exitCode: Int32) -> String { "\(prefix)\(exitCode)" }

    static func isMarker(_ title: String) -> Bool { title.hasPrefix(prefix) }

    static func parse(_ title: String) -> Int32? {
        guard title.hasPrefix(prefix) else { return nil }
        return Int32(title.dropFirst(prefix.count))
    }
}
