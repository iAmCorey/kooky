import Foundation

struct RemoteTransferItem: Equatable, Sendable {
    let localURL: URL
    let remotePath: String
    let isDirectory: Bool
}

struct RemoteTransferPayload: Equatable, Sendable {
    let remoteDirectory: String
    let items: [RemoteTransferItem]
}

enum RemoteTransferFailure: Error, Equatable, Sendable {
    case createDirectoryFailed
    case uploadFailed(localPath: String)
}

protocol RemoteTransferService: Sendable {
    func upload(
        payload: RemoteTransferPayload,
        to target: RemoteUploadTarget
    ) async -> Result<[String], RemoteTransferFailure>
}

/// SSH and Mosh workspaces share this exact SCP implementation and
/// ControlPath. It runs blocking Process work on a dedicated GCD worker,
/// never on the cooperative executor or main actor.
struct OpenSSHRemoteTransferService: RemoteTransferService, Sendable {
    typealias ProcessRunner = @Sendable (String, [String], TimeInterval) -> Bool
    let processRunner: ProcessRunner

    func upload(
        payload: RemoteTransferPayload,
        to target: RemoteUploadTarget
    ) async -> Result<[String], RemoteTransferFailure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: uploadSynchronously(
                    payload: payload,
                    to: target
                ))
            }
        }
    }

    private func uploadSynchronously(
        payload: RemoteTransferPayload,
        to target: RemoteUploadTarget
    ) -> Result<[String], RemoteTransferFailure> {
        let options = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
        ] + KookyShellIntegration.sshMultiplexOptions + target.sshOptions
        let mkdir = """
        find /tmp -maxdepth 1 -name 'kooky-pastes-*' -type d -mmin +60 -exec rm -rf {} + 2>/dev/null; \
        mkdir -p -- \(KookyShellIntegration.quote(payload.remoteDirectory))
        """
        guard processRunner(
            "/usr/bin/ssh",
            options + ["--", target.destination, mkdir],
            20
        ) else {
            return .failure(.createDirectoryFailed)
        }

        for item in payload.items {
            var arguments = options
            if item.isDirectory { arguments.append("-r") }
            arguments.append(contentsOf: [
                "--",
                item.localURL.path,
                "\(target.destination):\(item.remotePath)",
            ])
            guard processRunner("/usr/bin/scp", arguments, 60) else {
                return .failure(.uploadFailed(localPath: item.localURL.path))
            }
        }
        return .success(payload.items.map(\.remotePath))
    }
}
