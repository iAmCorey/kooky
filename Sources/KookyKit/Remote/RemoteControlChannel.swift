import Darwin
import Foundation

struct RemoteControlChannelConfiguration: Equatable, Sendable {
    let destination: String
    let runtimeToken: UUID
    let sshPort: UInt16?
    let identityFile: String?
    let connectTimeoutSeconds: Int
    let executableURL: URL

    init(
        destination: String,
        runtimeToken: UUID,
        sshPort: UInt16? = nil,
        identityFile: String? = nil,
        connectTimeoutSeconds: Int = 10,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) {
        self.destination = destination
        self.runtimeToken = runtimeToken
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.executableURL = executableURL
    }
}

enum RemoteControlExitKind: Equatable, Sendable {
    case cancelled
    case authenticationRequired
    case runtimeUnavailable
    case networkUnavailable
    case launchFailed
    case exited
}

struct RemoteControlExit: Equatable, Sendable {
    let kind: RemoteControlExitKind
    let status: Int32?
    let message: String?
}

enum RemoteControlChannelEvent: Equatable, Sendable {
    case frame(RemoteRuntimeFrame)
    case protocolViolation(RemoteProtocolViolation)
    case exited(RemoteControlExit)
}

protocol RemoteControlChannelRunning: AnyObject, Sendable {
    func start()
    func stop()
}

/// One non-interactive OpenSSH subscriber for a Mosh runtime. All Process and
/// pipe state is confined to `queue`; callbacks may arrive on any queue and
/// are therefore explicitly Sendable.
final class RemoteControlChannel: RemoteControlChannelRunning, @unchecked Sendable {
    typealias EventHandler = @Sendable (RemoteControlChannelEvent) -> Void

    static let maximumStderrBytes = 32 * 1_024

    private let configuration: RemoteControlChannelConfiguration
    private let eventHandler: EventHandler
    private let queue = DispatchQueue(label: "kooky.remote-control-channel", qos: .utility)

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var decoder = RemoteRuntimeStreamDecoder()
    private var stderr = Data()
    private var stopping = false
    private var emittedExit = false

    init(
        configuration: RemoteControlChannelConfiguration,
        eventHandler: @escaping EventHandler
    ) {
        self.configuration = configuration
        self.eventHandler = eventHandler
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    static func arguments(for configuration: RemoteControlChannelConfiguration) -> [String] {
        let watch = RemoteRuntimeScripts.watchCommand(token: configuration.runtimeToken)
        return baseArguments(for: configuration, batchMode: true) + [
            "--",
            configuration.destination,
            "sh -lc \(KookyShellIntegration.quote(watch))",
        ]
    }

    /// Interactive one-shot command used inside Kooky's authentication
    /// terminal. OpenSSH owns every password/OTP/host-key prompt; Kooky only
    /// observes the clean exit and then retries the BatchMode subscriber.
    static func authenticationArguments(
        for configuration: RemoteControlChannelConfiguration
    ) -> [String] {
        baseArguments(for: configuration, batchMode: false) + [
            "--",
            configuration.destination,
            "true",
        ]
    }

    private static func baseArguments(
        for configuration: RemoteControlChannelConfiguration,
        batchMode: Bool
    ) -> [String] {
        var arguments = [
            "-o", "BatchMode=\(batchMode ? "yes" : "no")",
            "-o", "ConnectTimeout=\(configuration.connectTimeoutSeconds)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
        ]
        arguments.append(contentsOf: KookyShellIntegration.sshMultiplexOptions)
        if let port = configuration.sshPort {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        if let identityFile = WorkspaceTransport.normalizedNonEmpty(configuration.identityFile) {
            arguments.append(contentsOf: ["-i", identityFile])
        }
        return arguments
    }

    static func classifyExit(
        status: Int32?,
        stderr rawStderr: String,
        wasCancelled: Bool
    ) -> RemoteControlExit {
        if wasCancelled {
            return RemoteControlExit(kind: .cancelled, status: status, message: nil)
        }
        let sanitized = sanitizeDiagnostic(rawStderr)
        let lower = sanitized.lowercased()
        let authMarkers = [
            "permission denied",
            "authentication failed",
            "no supported authentication methods",
            "too many authentication failures",
            "host key verification failed",
            "host key has changed",
            "authenticity of host",
            "remote host identification has changed",
        ]
        if authMarkers.contains(where: lower.contains) {
            return RemoteControlExit(
                kind: .authenticationRequired,
                status: status,
                message: sanitized.nilIfEmpty
            )
        }
        let networkMarkers = [
            "connection timed out",
            "connection refused",
            "network is unreachable",
            "no route to host",
            "could not resolve hostname",
            "connection reset",
            "broken pipe",
        ]
        if networkMarkers.contains(where: lower.contains) || status == 255 {
            return RemoteControlExit(
                kind: .networkUnavailable,
                status: status,
                message: sanitized.nilIfEmpty
            )
        }
        if status == 75 || status == 76 {
            return RemoteControlExit(
                kind: .runtimeUnavailable,
                status: status,
                message: sanitized.nilIfEmpty
            )
        }
        return RemoteControlExit(
            kind: status == nil ? .launchFailed : .exited,
            status: status,
            message: sanitized.nilIfEmpty
        )
    }

    private func startOnQueue() {
        guard process == nil, !stopping else { return }
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = Self.arguments(for: configuration)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in self?.consumeStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in self?.consumeStderr(data) }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.queue.async { [weak self] in
                self?.processTerminated(status: terminated.terminationStatus)
            }
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        do {
            try process.run()
        } catch {
            consumeStderr(Data(error.localizedDescription.utf8))
            processTerminated(status: nil)
        }
    }

    private func consumeStdout(_ data: Data) {
        for result in decoder.append(data) {
            switch result {
            case .frame(let frame): eventHandler(.frame(frame))
            case .violation(let violation): eventHandler(.protocolViolation(violation))
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        guard stderr.count < Self.maximumStderrBytes else { return }
        stderr.append(data.prefix(Self.maximumStderrBytes - stderr.count))
    }

    private func stopOnQueue() {
        guard !stopping else { return }
        stopping = true
        guard let process else { return }
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak process] in
            guard let self, self.process === process, process?.isRunning == true, pid > 0 else {
                return
            }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private func processTerminated(status: Int32?) {
        guard !emittedExit else { return }
        emittedExit = true

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let tail = try? stdoutPipe?.fileHandleForReading.readToEnd(), !tail.isEmpty {
            consumeStdout(tail)
        }
        if let tail = try? stderrPipe?.fileHandleForReading.readToEnd(), !tail.isEmpty {
            consumeStderr(tail)
        }
        for result in decoder.finish() {
            if case .violation(let violation) = result {
                eventHandler(.protocolViolation(violation))
            }
        }
        let diagnostic = String(data: stderr, encoding: .utf8) ?? ""
        eventHandler(.exited(Self.classifyExit(
            status: status,
            stderr: diagnostic,
            wasCancelled: stopping
        )))
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private static func sanitizeDiagnostic(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter {
            $0.value == 0x09 || $0.value == 0x0A || $0.value == 0x0D || $0.value >= 0x20
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
