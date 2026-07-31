import Foundation

enum RemoteRuntimeActivity: String, Equatable, Sendable {
    case idle
    case running
    case attention
    case ended
}

struct RemoteRuntimeSnapshot: Equatable, Sendable {
    let sequence: UInt64
    let agent: String?
    let activity: RemoteRuntimeActivity
    let cwd: String
    let cwdTruncated: Bool
    let exitCode: Int32?
    let durationMilliseconds: UInt64?
}

enum RemoteRuntimeFrame: Equatable, Sendable {
    case ready(token: UUID)
    case snapshot(RemoteRuntimeSnapshot)
    case event(RemoteRuntimeSnapshot)
    case error(code: String, message: String)
}

enum RemoteProtocolViolation: Error, Equatable, Sendable {
    case frameTooLarge(limit: Int)
    case nulByte
    case invalidUTF8
    case partialFrameAtEOF
    case unsupportedVersion(String)
    case unknownFrameType(String)
    case invalidFieldCount(type: String, expected: Int, actual: Int)
    case invalidToken
    case invalidSequence
    case invalidAgent
    case invalidActivity(String)
    case invalidTruncationFlag
    case invalidExitCode
    case invalidDuration
    case invalidErrorCode
}

enum RemoteProtocolDecodeResult: Equatable, Sendable {
    case frame(RemoteRuntimeFrame)
    case violation(RemoteProtocolViolation)
}

enum RemoteRuntimeProtocol {
    static let version = "KRP/1"
    static let maximumFrameBytes = 16 * 1_024

    static func parse(line: String) -> Result<RemoteRuntimeFrame, RemoteProtocolViolation> {
        guard line.lengthOfBytes(using: .utf8) <= maximumFrameBytes else {
            return .failure(.frameTooLarge(limit: maximumFrameBytes))
        }
        guard !line.utf8.contains(0) else { return .failure(.nulByte) }
        let fields = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let receivedVersion = fields.first else {
            return .failure(.unsupportedVersion(""))
        }
        guard receivedVersion == version else {
            return .failure(.unsupportedVersion(receivedVersion))
        }
        guard fields.count >= 2 else {
            return .failure(.invalidFieldCount(type: "", expected: 2, actual: fields.count))
        }

        switch fields[1] {
        case "READY":
            guard fields.count == 3 else {
                return .failure(.invalidFieldCount(
                    type: "READY",
                    expected: 3,
                    actual: fields.count
                ))
            }
            guard let token = UUID(uuidString: fields[2]),
                  token.uuidString.lowercased() == fields[2]
            else {
                return .failure(.invalidToken)
            }
            return .success(.ready(token: token))
        case "SNAPSHOT", "EVENT":
            guard fields.count == 9 else {
                return .failure(.invalidFieldCount(
                    type: fields[1],
                    expected: 9,
                    actual: fields.count
                ))
            }
            switch parseSnapshot(fields) {
            case .success(let snapshot):
                return .success(fields[1] == "SNAPSHOT"
                    ? .snapshot(snapshot)
                    : .event(snapshot))
            case .failure(let violation):
                return .failure(violation)
            }
        case "ERROR":
            guard fields.count == 4 else {
                return .failure(.invalidFieldCount(
                    type: "ERROR",
                    expected: 4,
                    actual: fields.count
                ))
            }
            guard isSafeIdentifier(fields[2]) else {
                return .failure(.invalidErrorCode)
            }
            return .success(.error(code: fields[2], message: fields[3]))
        default:
            return .failure(.unknownFrameType(fields[1]))
        }
    }

    private static func parseSnapshot(
        _ fields: [String]
    ) -> Result<RemoteRuntimeSnapshot, RemoteProtocolViolation> {
        guard let sequence = UInt64(fields[2]) else {
            return .failure(.invalidSequence)
        }
        let agent: String?
        if fields[3] == "-" {
            agent = nil
        } else {
            guard isSafeIdentifier(fields[3]) else {
                return .failure(.invalidAgent)
            }
            agent = fields[3]
        }
        guard let activity = RemoteRuntimeActivity(rawValue: fields[4]) else {
            return .failure(.invalidActivity(fields[4]))
        }
        let cwdTruncated: Bool
        switch fields[6] {
        case "0": cwdTruncated = false
        case "1": cwdTruncated = true
        default: return .failure(.invalidTruncationFlag)
        }
        let exitCode: Int32?
        if fields[7] == "-" {
            exitCode = nil
        } else {
            guard let parsed = Int32(fields[7]) else {
                return .failure(.invalidExitCode)
            }
            exitCode = parsed
        }
        let duration: UInt64?
        if fields[8] == "-" {
            duration = nil
        } else {
            guard let parsed = UInt64(fields[8]) else {
                return .failure(.invalidDuration)
            }
            duration = parsed
        }
        return .success(RemoteRuntimeSnapshot(
            sequence: sequence,
            agent: agent,
            activity: activity,
            cwd: fields[5],
            cwdTruncated: cwdTruncated,
            exitCode: exitCode,
            durationMilliseconds: duration
        ))
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}

/// Converts arbitrary pipe read boundaries into complete protocol frames.
/// An oversized unterminated line enters discard mode until the next newline,
/// bounding memory even when a remote peer is buggy or malicious.
struct RemoteRuntimeStreamDecoder: Sendable {
    private var buffer = Data()
    private var discardingOversizedFrame = false

    mutating func append(_ chunk: Data) -> [RemoteProtocolDecodeResult] {
        guard !chunk.isEmpty else { return [] }
        var results: [RemoteProtocolDecodeResult] = []
        for byte in chunk {
            if discardingOversizedFrame {
                if byte == 0x0A { discardingOversizedFrame = false }
                continue
            }
            if byte == 0x0A {
                results.append(decodeLine(buffer))
                buffer.removeAll(keepingCapacity: true)
            } else if buffer.count == RemoteRuntimeProtocol.maximumFrameBytes {
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedFrame = true
                results.append(.violation(.frameTooLarge(
                    limit: RemoteRuntimeProtocol.maximumFrameBytes
                )))
            } else {
                buffer.append(byte)
            }
        }
        return results
    }

    mutating func finish() -> [RemoteProtocolDecodeResult] {
        defer {
            buffer.removeAll()
            discardingOversizedFrame = false
        }
        guard !buffer.isEmpty || discardingOversizedFrame else { return [] }
        if discardingOversizedFrame { return [] }
        return [.violation(.partialFrameAtEOF)]
    }

    private func decodeLine(_ rawLine: Data) -> RemoteProtocolDecodeResult {
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        guard line.count <= RemoteRuntimeProtocol.maximumFrameBytes else {
            return .violation(.frameTooLarge(limit: RemoteRuntimeProtocol.maximumFrameBytes))
        }
        guard !line.contains(0) else { return .violation(.nulByte) }
        guard let string = String(data: line, encoding: .utf8) else {
            return .violation(.invalidUTF8)
        }
        switch RemoteRuntimeProtocol.parse(line: string) {
        case .success(let frame): return .frame(frame)
        case .failure(let violation): return .violation(violation)
        }
    }
}

enum RemoteSequenceObservation: Equatable, Sendable {
    case first
    case next
    case duplicate
    case outOfOrder(last: UInt64, received: UInt64)
    case gap(expected: UInt64, received: UInt64)
}

struct RemoteSequenceTracker: Sendable {
    private(set) var lastSequence: UInt64?

    mutating func observe(_ sequence: UInt64) -> RemoteSequenceObservation {
        guard let last = lastSequence else {
            lastSequence = sequence
            return .first
        }
        if sequence == last { return .duplicate }
        if sequence < last { return .outOfOrder(last: last, received: sequence) }
        let expected = last == UInt64.max ? UInt64.max : last + 1
        lastSequence = sequence
        return sequence == expected ? .next : .gap(expected: expected, received: sequence)
    }

    mutating func reset(to sequence: UInt64? = nil) {
        lastSequence = sequence
    }
}

// MARK: - Producer → collector protocol

enum RemoteProducerEvent: Equatable, Sendable {
    case agent(agent: String, activity: RemoteRuntimeActivity)
    case prompt(
        cwd: String,
        cwdTruncated: Bool,
        exitCode: Int32?,
        durationMilliseconds: UInt64?
    )
    case error(code: String)
}

enum RemoteProducerProtocol {
    static let version = "P/1"
    static let maximumFrameBytes = 480

    static func parse(line: String) -> Result<RemoteProducerEvent, RemoteProtocolViolation> {
        guard line.lengthOfBytes(using: .utf8) <= maximumFrameBytes else {
            return .failure(.frameTooLarge(limit: maximumFrameBytes))
        }
        guard !line.utf8.contains(0) else { return .failure(.nulByte) }
        let fields = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard fields.first == version else {
            return .failure(.unsupportedVersion(fields.first ?? ""))
        }
        guard fields.count >= 2 else {
            return .failure(.invalidFieldCount(type: "", expected: 2, actual: fields.count))
        }
        switch fields[1] {
        case "AGENT":
            guard fields.count == 4 else {
                return .failure(.invalidFieldCount(type: "AGENT", expected: 4, actual: fields.count))
            }
            guard isProducerIdentifier(fields[2]) else { return .failure(.invalidAgent) }
            guard let activity = RemoteRuntimeActivity(rawValue: fields[3]) else {
                return .failure(.invalidActivity(fields[3]))
            }
            return .success(.agent(agent: fields[2], activity: activity))
        case "PROMPT":
            guard fields.count == 6 else {
                return .failure(.invalidFieldCount(type: "PROMPT", expected: 6, actual: fields.count))
            }
            let truncated: Bool
            switch fields[3] {
            case "0": truncated = false
            case "1": truncated = true
            default: return .failure(.invalidTruncationFlag)
            }
            let exit: Int32?
            if fields[4] == "-" {
                exit = nil
            } else if let value = Int32(fields[4]) {
                exit = value
            } else {
                return .failure(.invalidExitCode)
            }
            let duration: UInt64?
            if fields[5] == "-" {
                duration = nil
            } else if let value = UInt64(fields[5]) {
                duration = value
            } else {
                return .failure(.invalidDuration)
            }
            return .success(.prompt(
                cwd: fields[2],
                cwdTruncated: truncated,
                exitCode: exit,
                durationMilliseconds: duration
            ))
        case "ERROR":
            guard fields.count == 3 else {
                return .failure(.invalidFieldCount(type: "ERROR", expected: 3, actual: fields.count))
            }
            guard isProducerIdentifier(fields[2]) else { return .failure(.invalidErrorCode) }
            return .success(.error(code: fields[2]))
        default:
            return .failure(.unknownFrameType(fields[1]))
        }
    }

    private static func isProducerIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}
