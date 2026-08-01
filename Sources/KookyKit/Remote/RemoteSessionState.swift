import Foundation

enum RemoteTransportKind: String, Codable, Equatable, Sendable {
    case ssh
    case mosh
}

enum RemoteDegradationReason: String, Equatable, Sendable {
    case controlUnavailable
    case controlDisconnected
    case statusStale
    case authenticationRequired
    case protocolIncompatible
}

enum RemoteLaunchFailure: Equatable, Sendable {
    case executableMissing(String)
    case invalidConfiguration(String)
    case authenticationFailed
    case udpBlocked
    case bootstrapRejected(String)
    case processExited(code: Int32?, message: String?)
}

enum RemoteConnectionState: Equatable, Sendable {
    case launching
    case connected
    case degraded(since: Date, reason: RemoteDegradationReason)
    case authenticationRequired(since: Date)
    case disconnected(exitCode: Int32?)
    case failed(RemoteLaunchFailure)
}

struct RemoteRuntimeIdentity: Equatable, Sendable {
    let token: UUID
    let destination: String
    let transport: RemoteTransportKind
}
