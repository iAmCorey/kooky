import Foundation

enum MoshCommandBuildError: Error, Equatable {
    case invalidConfiguration
    case remoteCommandTooLarge(actualBytes: Int, maximumBytes: Int)
}

struct MoshInvocation: Equatable, CustomDebugStringConvertible {
    let executable: String
    let arguments: [String]
    let remoteCommandBytes: Int

    /// The local shell wrapper consumes `KOOKY_AGENT` as a command string.
    /// Every token is quoted here; no user value is allowed to become an
    /// option fragment.
    var shellCommand: String {
        ([executable] + arguments)
            .map(KookyShellIntegration.quote)
            .joined(separator: " ")
    }

    /// `arguments` contains the complete remote Agent command and may include
    /// an initial prompt or provider option. Diagnostics expose only shape and
    /// size so a crash report cannot accidentally retain that content.
    var debugDescription: String {
        "MoshInvocation(executable: \(executable), argumentCount: \(arguments.count), remoteCommandBytes: \(remoteCommandBytes))"
    }
}

enum MoshCommandBuilder {
    static let maximumRemoteCommandBytes = 64 * 1_024

    static func build(
        configuration rawConfiguration: MoshWorkspaceConfiguration,
        runtimeToken: UUID,
        remoteAgentCommand: String?,
        bootstrapScript: String = RemoteRuntimeScripts.bootstrapScript
    ) throws -> MoshInvocation {
        guard case .mosh(let configuration) = WorkspaceTransport
            .mosh(rawConfiguration)
            .normalized()
        else {
            throw MoshCommandBuildError.invalidConfiguration
        }

        let sshCommand = buildSSHCommand(configuration: configuration)
        let serverCommand = buildServerCommand(configuration: configuration)
        var arguments = [
            "--ssh=\(sshCommand)",
            "--server=\(serverCommand)",
            "--predict=\(configuration.prediction.rawValue)",
        ]
        if let port = udpPortArgument(configuration.udpPort) {
            arguments.append(contentsOf: ["-p", port])
        }
        arguments.append("--")
        arguments.append(configuration.destination)

        var remoteArguments = [
            "env",
            "KOOKY_RUNTIME_TOKEN=\(runtimeToken.uuidString.lowercased())",
        ]
        if let remoteAgentCommand = WorkspaceTransport.normalizedNonEmpty(remoteAgentCommand) {
            remoteArguments.append("KOOKY_REMOTE_AGENT=\(remoteAgentCommand)")
        }
        remoteArguments.append(contentsOf: [
            "sh",
            "-lc",
            bootstrapScript,
        ])

        // This mirrors mosh.pl's `shell_quote(@command)` before the command is
        // handed to OpenSSH. Gate the actual quoted byte count, not Swift
        // character count or the unquoted source size.
        let quotedRemoteCommand = remoteArguments
            .map(KookyShellIntegration.quote)
            .joined(separator: " ")
        let byteCount = quotedRemoteCommand.lengthOfBytes(using: .utf8)
        guard byteCount <= maximumRemoteCommandBytes else {
            throw MoshCommandBuildError.remoteCommandTooLarge(
                actualBytes: byteCount,
                maximumBytes: maximumRemoteCommandBytes
            )
        }
        arguments.append(contentsOf: remoteArguments)
        return MoshInvocation(
            executable: "kooky-mosh",
            arguments: arguments,
            remoteCommandBytes: byteCount
        )
    }

    private static func buildSSHCommand(
        configuration: MoshWorkspaceConfiguration
    ) -> String {
        var tokens = ["/usr/bin/ssh"]
        tokens.append(contentsOf: KookyShellIntegration.sshMultiplexOptions)
        if let port = configuration.sshPort {
            tokens.append(contentsOf: ["-p", String(port)])
        }
        if let identity = configuration.identityFile {
            tokens.append(contentsOf: ["-i", identity])
        }
        return tokens.map(KookyShellIntegration.quote).joined(separator: " ")
    }

    private static func buildServerCommand(
        configuration: MoshWorkspaceConfiguration
    ) -> String {
        let server = configuration.serverPath ?? "mosh-server"
        return [
            "env",
            "MOSH_SERVER_NETWORK_TMOUT=\(configuration.networkTimeoutSeconds)",
            server,
        ]
        .map(KookyShellIntegration.quote)
        .joined(separator: " ")
    }

    private static func udpPortArgument(
        _ selection: MoshUDPPortSelection
    ) -> String? {
        switch selection {
        case .automatic:
            nil
        case .port(let port):
            String(port)
        case .range(let range):
            "\(range.lowerBound):\(range.upperBound)"
        }
    }
}
