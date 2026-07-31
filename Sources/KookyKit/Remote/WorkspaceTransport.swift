import Foundation

enum MoshPredictionMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case adaptive
    case always
    case never
}

enum MoshUDPPortSelection: Equatable, Sendable {
    case automatic
    case port(UInt16)
    case range(ClosedRange<UInt16>)

    var isValid: Bool {
        switch self {
        case .automatic:
            true
        case .port(let port):
            port > 0
        case .range(let range):
            range.lowerBound > 0 && range.lowerBound <= range.upperBound
        }
    }
}

extension MoshUDPPortSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case port
        case lower
        case upper
    }

    private enum Kind: String, Codable {
        case automatic
        case port
        case range
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .automatic:
            self = .automatic
        case .port:
            let port = try container.decode(UInt16.self, forKey: .port)
            guard port > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .port,
                    in: container,
                    debugDescription: "Mosh UDP port must be between 1 and 65535"
                )
            }
            self = .port(port)
        case .range:
            let lower = try container.decode(UInt16.self, forKey: .lower)
            let upper = try container.decode(UInt16.self, forKey: .upper)
            guard lower > 0, lower <= upper else {
                throw DecodingError.dataCorruptedError(
                    forKey: .upper,
                    in: container,
                    debugDescription: "Mosh UDP range lower bound exceeds upper bound"
                )
            }
            self = .range(lower...upper)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Kind.automatic, forKey: .kind)
        case .port(let port):
            try container.encode(Kind.port, forKey: .kind)
            try container.encode(port, forKey: .port)
        case .range(let range):
            try container.encode(Kind.range, forKey: .kind)
            try container.encode(range.lowerBound, forKey: .lower)
            try container.encode(range.upperBound, forKey: .upper)
        }
    }
}

struct SSHWorkspaceConfiguration: Codable, Equatable, Sendable {
    var destination: String

    init?(destination rawDestination: String) {
        guard let destination = WorkspaceTransport.normalizedNonEmpty(rawDestination) else {
            return nil
        }
        self.destination = destination
    }
}

struct MoshWorkspaceConfiguration: Codable, Equatable, Sendable {
    static let defaultNetworkTimeoutSeconds = 7 * 24 * 60 * 60
    static let networkTimeoutRange = 3_600...2_592_000

    var destination: String
    var udpPort: MoshUDPPortSelection
    var prediction: MoshPredictionMode
    var serverPath: String?
    var sshPort: Int?
    var identityFile: String?
    var networkTimeoutSeconds: Int

    init?(
        destination rawDestination: String,
        udpPort: MoshUDPPortSelection = .automatic,
        prediction: MoshPredictionMode = .adaptive,
        serverPath: String? = nil,
        sshPort: Int? = nil,
        identityFile: String? = nil,
        networkTimeoutSeconds: Int = Self.defaultNetworkTimeoutSeconds
    ) {
        guard let destination = WorkspaceTransport.normalizedNonEmpty(rawDestination),
              Self.networkTimeoutRange.contains(networkTimeoutSeconds),
              sshPort.map({ (1...65_535).contains($0) }) ?? true,
              udpPort.isValid
        else {
            return nil
        }
        self.destination = destination
        self.udpPort = udpPort
        self.prediction = prediction
        self.serverPath = WorkspaceTransport.normalizedNonEmpty(serverPath)
        self.sshPort = sshPort
        self.identityFile = WorkspaceTransport.normalizedNonEmpty(identityFile)
        self.networkTimeoutSeconds = networkTimeoutSeconds
    }
}

/// The stable, persisted location/transport identity for a workspace.
///
/// `unsupported` is deliberately retained instead of degrading an unknown
/// future transport to a local shell. It gives old builds a safe, visible
/// placeholder that can be removed without accidentally launching locally.
enum WorkspaceTransport: Equatable, Sendable {
    case local
    case ssh(SSHWorkspaceConfiguration)
    case mosh(MoshWorkspaceConfiguration)
    case unsupported(kind: String, destination: String?)

    var isRemote: Bool {
        switch self {
        case .local:
            false
        case .ssh, .mosh, .unsupported:
            true
        }
    }

    var remoteDestination: String? {
        switch self {
        case .local:
            nil
        case .ssh(let configuration):
            configuration.destination
        case .mosh(let configuration):
            configuration.destination
        case .unsupported(_, let destination):
            destination
        }
    }

    var supportsRemoteUpload: Bool {
        switch self {
        case .ssh, .mosh:
            true
        case .local, .unsupported:
            false
        }
    }

    var label: String {
        switch self {
        case .local:
            "Local"
        case .ssh:
            "SSH"
        case .mosh:
            "Mosh"
        case .unsupported(let kind, _):
            kind.isEmpty ? "Unsupported Remote" : "Unsupported \(kind)"
        }
    }

    var remoteKind: RemoteTransportKind? {
        switch self {
        case .ssh:
            .ssh
        case .mosh:
            .mosh
        case .local, .unsupported:
            nil
        }
    }

    static func ssh(destination: String?) -> WorkspaceTransport {
        guard let destination,
              let configuration = SSHWorkspaceConfiguration(destination: destination)
        else {
            return .local
        }
        return .ssh(configuration)
    }

    static func normalizedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func normalized() -> WorkspaceTransport {
        switch self {
        case .local:
            return .local
        case .ssh(let configuration):
            return .ssh(destination: configuration.destination)
        case .mosh(let configuration):
            guard let normalized = MoshWorkspaceConfiguration(
                destination: configuration.destination,
                udpPort: configuration.udpPort,
                prediction: configuration.prediction,
                serverPath: configuration.serverPath,
                sshPort: configuration.sshPort,
                identityFile: configuration.identityFile,
                networkTimeoutSeconds: configuration.networkTimeoutSeconds
            ) else {
                return .unsupported(
                    kind: "mosh",
                    destination: Self.normalizedNonEmpty(configuration.destination)
                )
            }
            return .mosh(normalized)
        case .unsupported(let kind, let destination):
            return .unsupported(
                kind: Self.normalizedNonEmpty(kind) ?? "unknown",
                destination: Self.normalizedNonEmpty(destination)
            )
        }
    }
}

extension WorkspaceTransport: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case destination
        case udpPort
        case prediction
        case serverPath
        case sshPort
        case identityFile
        case networkTimeoutSeconds
    }

    private enum KnownKind: String {
        case local
        case ssh
        case mosh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        let destination = try? container.decodeIfPresent(String.self, forKey: .destination)

        switch KnownKind(rawValue: rawKind) {
        case .local:
            self = .local
        case .ssh:
            if let destination,
               let configuration = SSHWorkspaceConfiguration(destination: destination) {
                self = .ssh(configuration)
            } else {
                self = .unsupported(
                    kind: rawKind,
                    destination: WorkspaceTransport.normalizedNonEmpty(destination)
                )
            }
        case .mosh:
            let fallback = WorkspaceTransport.unsupported(
                kind: rawKind,
                destination: WorkspaceTransport.normalizedNonEmpty(destination)
            )
            let udpPort: MoshUDPPortSelection
            if container.contains(.udpPort) {
                guard let decoded = try? container.decode(
                    MoshUDPPortSelection.self,
                    forKey: .udpPort
                ) else {
                    self = fallback
                    return
                }
                udpPort = decoded
            } else {
                udpPort = .automatic
            }
            let prediction: MoshPredictionMode
            if container.contains(.prediction) {
                guard let decoded = try? container.decode(
                    MoshPredictionMode.self,
                    forKey: .prediction
                ) else {
                    self = fallback
                    return
                }
                prediction = decoded
            } else {
                prediction = .adaptive
            }
            let serverPath: String?
            if container.contains(.serverPath) {
                guard let decoded = try? container.decodeIfPresent(
                    String.self,
                    forKey: .serverPath
                ) else {
                    self = fallback
                    return
                }
                serverPath = decoded
            } else {
                serverPath = nil
            }
            let sshPort: Int?
            if container.contains(.sshPort) {
                guard let decoded = try? container.decodeIfPresent(
                    Int.self,
                    forKey: .sshPort
                ) else {
                    self = fallback
                    return
                }
                sshPort = decoded
            } else {
                sshPort = nil
            }
            let identityFile: String?
            if container.contains(.identityFile) {
                guard let decoded = try? container.decodeIfPresent(
                    String.self,
                    forKey: .identityFile
                ) else {
                    self = fallback
                    return
                }
                identityFile = decoded
            } else {
                identityFile = nil
            }
            let timeout: Int
            if container.contains(.networkTimeoutSeconds) {
                guard let decoded = try? container.decode(
                    Int.self,
                    forKey: .networkTimeoutSeconds
                ) else {
                    self = fallback
                    return
                }
                timeout = decoded
            } else {
                timeout = MoshWorkspaceConfiguration.defaultNetworkTimeoutSeconds
            }
            if let destination,
               let configuration = MoshWorkspaceConfiguration(
                   destination: destination,
                   udpPort: udpPort,
                   prediction: prediction,
                   serverPath: serverPath,
                   sshPort: sshPort,
                   identityFile: identityFile,
                   networkTimeoutSeconds: timeout
               ) {
                self = .mosh(configuration)
            } else {
                self = fallback
            }
        case nil:
            self = .unsupported(
                kind: rawKind,
                destination: WorkspaceTransport.normalizedNonEmpty(destination)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(KnownKind.local.rawValue, forKey: .kind)
        case .ssh(let configuration):
            try container.encode(KnownKind.ssh.rawValue, forKey: .kind)
            try container.encode(configuration.destination, forKey: .destination)
        case .mosh(let configuration):
            try container.encode(KnownKind.mosh.rawValue, forKey: .kind)
            try container.encode(configuration.destination, forKey: .destination)
            try container.encode(configuration.udpPort, forKey: .udpPort)
            try container.encode(configuration.prediction, forKey: .prediction)
            try container.encodeIfPresent(configuration.serverPath, forKey: .serverPath)
            try container.encodeIfPresent(configuration.sshPort, forKey: .sshPort)
            try container.encodeIfPresent(configuration.identityFile, forKey: .identityFile)
            try container.encode(
                configuration.networkTimeoutSeconds,
                forKey: .networkTimeoutSeconds
            )
        case .unsupported(let kind, let destination):
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(destination, forKey: .destination)
        }
    }
}
