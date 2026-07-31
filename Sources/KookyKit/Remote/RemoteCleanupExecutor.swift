import Darwin
import Foundation

/// Best-effort explicit close for a validated runtime token. This is only
/// called from a user/app lifecycle close path; control-channel staleness
/// never reaches this type.
enum RemoteCleanupExecutor {
    static func run(
        configuration: RemoteControlChannelConfiguration,
        timeout: TimeInterval = 8,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = configuration.executableURL
            var arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(configuration.connectTimeoutSeconds)",
            ]
            arguments.append(contentsOf: KookyShellIntegration.sshMultiplexOptions)
            if let port = configuration.sshPort {
                arguments.append(contentsOf: ["-p", String(port)])
            }
            if let identity = WorkspaceTransport.normalizedNonEmpty(configuration.identityFile) {
                arguments.append(contentsOf: ["-i", identity])
            }
            let cleanup = RemoteRuntimeScripts.cleanupCommand(token: configuration.runtimeToken)
            arguments.append("--")
            arguments.append(configuration.destination)
            arguments.append("sh -lc \(KookyShellIntegration.quote(cleanup))")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let completed = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completed.signal() }
            do {
                try process.run()
            } catch {
                NSLog("kooky: could not launch remote cleanup: %@", error.localizedDescription)
                completion?(false)
                return
            }
            var timedOut = false
            if completed.wait(timeout: .now() + timeout) == .timedOut, process.isRunning {
                timedOut = true
                process.terminate()
                if completed.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            completion?(!timedOut && process.terminationStatus == 0)
        }
    }
}
