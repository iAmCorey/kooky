import Foundation

/// An SSH destination plus the port it should connect on — carried as ONE
/// value from the create sheet through persistence, spawn, and paste upload so
/// the host and its port can never drift apart. `host` stays exactly what ssh
/// itself receives (`user@host` or a `~/.ssh/config` alias); the port is never
/// folded into it, because `user@host:2222` is not a valid ssh destination and
/// `ssh://` URIs are rejected by the `scp` side of paste upload.
struct SSHRemoteTarget: Equatable {
    /// `user@host` or bare `host`.
    var host: String
    /// nil = hand the port choice to ssh: `~/.ssh/config`'s `Port`, else 22.
    var port: Int?

    /// Human-facing spelling for the sidebar row, tooltip, and Session Info:
    /// `host` stays untouched when no port was given, so surfaces that used to
    /// show a bare host keep reading the same.
    var label: String {
        guard let port else { return host }
        return "\(host):\(port)"
    }

    /// ssh's flag (`-p 2222`); empty when the port is left to ssh.
    var sshPortArguments: [String] {
        guard let port else { return [] }
        return ["-p", String(port)]
    }

    /// scp spells the same thing with a capital P — same port, different flag.
    var scpPortArguments: [String] {
        guard let port else { return [] }
        return ["-P", String(port)]
    }
}
