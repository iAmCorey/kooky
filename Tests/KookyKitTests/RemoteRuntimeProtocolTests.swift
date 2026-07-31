import XCTest
@testable import KookyKit

final class RemoteRuntimeProtocolTests: XCTestCase {
    private let token = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private var snapshotLine: String {
        "KRP/1\tSNAPSHOT\t42\tcodex\trunning\t/项目/a b\t0\t-1\t1234"
    }

    func testParsesEveryCollectorFrameType() throws {
        XCTAssertEqual(
            try RemoteRuntimeProtocol.parse(line: "KRP/1\tREADY\t\(token)").get(),
            .ready(token: try XCTUnwrap(UUID(uuidString: token)))
        )
        let snapshot = try RemoteRuntimeProtocol.parse(line: snapshotLine).get()
        XCTAssertEqual(snapshot, .snapshot(RemoteRuntimeSnapshot(
            sequence: 42,
            agent: "codex",
            activity: .running,
            cwd: "/项目/a b",
            cwdTruncated: false,
            exitCode: -1,
            durationMilliseconds: 1_234
        )))
        XCTAssertEqual(
            try RemoteRuntimeProtocol.parse(
                line: "KRP/1\tEVENT\t18446744073709551615\t-\tended\t\t1\t-\t-"
            ).get(),
            .event(RemoteRuntimeSnapshot(
                sequence: UInt64.max,
                agent: nil,
                activity: .ended,
                cwd: "",
                cwdTruncated: true,
                exitCode: nil,
                durationMilliseconds: nil
            ))
        )
        XCTAssertEqual(
            try RemoteRuntimeProtocol.parse(line: "KRP/1\tERROR\tcollector_failed\ttry later").get(),
            .error(code: "collector_failed", message: "try later")
        )
    }

    func testRejectsMalformedCollectorFields() {
        assertViolation("KRP/2\tREADY\t\(token)", .unsupportedVersion("KRP/2"))
        assertViolation("KRP/1\tWHAT", .unknownFrameType("WHAT"))
        assertViolation("KRP/1\tREADY\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", .invalidToken)
        assertViolation("KRP/1\tEVENT\tx\t-\tidle\t/\t0\t-\t-", .invalidSequence)
        assertViolation("KRP/1\tEVENT\t1\tbad agent\tidle\t/\t0\t-\t-", .invalidAgent)
        assertViolation("KRP/1\tEVENT\t1\t-\tbusy\t/\t0\t-\t-", .invalidActivity("busy"))
        assertViolation("KRP/1\tEVENT\t1\t-\tidle\t/\t2\t-\t-", .invalidTruncationFlag)
        assertViolation("KRP/1\tEVENT\t1\t-\tidle\t/\t0\t999999999999\t-", .invalidExitCode)
        assertViolation("KRP/1\tEVENT\t1\t-\tidle\t/\t0\t-\t-1", .invalidDuration)
    }

    func testStreamingDecoderHandlesEverySmallChunkBoundary() {
        let input = [
            "KRP/1\tREADY\t\(token)",
            snapshotLine,
            "KRP/1\tEVENT\t43\tcodex\tattention\t/项目/a b\t0\t0\t2000",
        ].joined(separator: "\n") + "\n"
        let expected: [RemoteProtocolDecodeResult] = [
            .frame(.ready(token: UUID(uuidString: token)!)),
            .frame(.snapshot(RemoteRuntimeSnapshot(
                sequence: 42,
                agent: "codex",
                activity: .running,
                cwd: "/项目/a b",
                cwdTruncated: false,
                exitCode: -1,
                durationMilliseconds: 1_234
            ))),
            .frame(.event(RemoteRuntimeSnapshot(
                sequence: 43,
                agent: "codex",
                activity: .attention,
                cwd: "/项目/a b",
                cwdTruncated: false,
                exitCode: 0,
                durationMilliseconds: 2_000
            ))),
        ]
        let bytes = Data(input.utf8)

        for chunkSize in 1...31 {
            var decoder = RemoteRuntimeStreamDecoder()
            var actual: [RemoteProtocolDecodeResult] = []
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunkSize, bytes.count)
                actual.append(contentsOf: decoder.append(bytes.subdata(in: offset..<end)))
                offset = end
            }
            actual.append(contentsOf: decoder.finish())
            XCTAssertEqual(actual, expected, "chunk size \(chunkSize)")
        }
    }

    func testStreamingDecoderBoundsBadInputAndRecoversAtNewline() {
        var decoder = RemoteRuntimeStreamDecoder()
        let oversized = Data(
            repeating: 0x78,
            count: RemoteRuntimeProtocol.maximumFrameBytes + 1
        )
        XCTAssertEqual(
            decoder.append(oversized),
            [.violation(.frameTooLarge(limit: RemoteRuntimeProtocol.maximumFrameBytes))]
        )
        XCTAssertEqual(decoder.append(Data("\n".utf8)), [])
        XCTAssertEqual(
            decoder.append(Data("KRP/1\tREADY\t\(token)\n".utf8)),
            [.frame(.ready(token: UUID(uuidString: token)!))]
        )

        var oneHugeChunk = RemoteRuntimeStreamDecoder()
        var hostile = Data(
            repeating: 0x78,
            count: RemoteRuntimeProtocol.maximumFrameBytes * 8
        )
        hostile.append(Data("\nKRP/1\tREADY\t\(token)\n".utf8))
        XCTAssertEqual(
            oneHugeChunk.append(hostile),
            [
                .violation(.frameTooLarge(
                    limit: RemoteRuntimeProtocol.maximumFrameBytes
                )),
                .frame(.ready(token: UUID(uuidString: token)!)),
            ]
        )
    }

    func testStreamingDecoderRejectsNULInvalidUTF8AndPartialEOF() {
        var nul = RemoteRuntimeStreamDecoder()
        XCTAssertEqual(
            nul.append(Data([0x4B, 0x00, 0x0A])),
            [.violation(.nulByte)]
        )
        var utf8 = RemoteRuntimeStreamDecoder()
        XCTAssertEqual(
            utf8.append(Data([0xFF, 0x0A])),
            [.violation(.invalidUTF8)]
        )
        var partial = RemoteRuntimeStreamDecoder()
        XCTAssertTrue(partial.append(Data("KRP/1\tREADY".utf8)).isEmpty)
        XCTAssertEqual(partial.finish(), [.violation(.partialFrameAtEOF)])
    }

    func testSequenceTrackerClassifiesDuplicateGapAndOutOfOrder() {
        var tracker = RemoteSequenceTracker()
        XCTAssertEqual(tracker.observe(7), .first)
        XCTAssertEqual(tracker.observe(8), .next)
        XCTAssertEqual(tracker.observe(8), .duplicate)
        XCTAssertEqual(tracker.observe(6), .outOfOrder(last: 8, received: 6))
        XCTAssertEqual(tracker.observe(11), .gap(expected: 9, received: 11))
        XCTAssertEqual(tracker.lastSequence, 11)
    }

    func testProducerProtocolIsDistinctBoundedAndHasNoSequence() throws {
        XCTAssertEqual(
            try RemoteProducerProtocol.parse(line: "P/1\tAGENT\tclaude\trunning").get(),
            .agent(agent: "claude", activity: .running)
        )
        XCTAssertEqual(
            try RemoteProducerProtocol.parse(
                line: "P/1\tPROMPT\t/srv/a b\t1\t-2\t900"
            ).get(),
            .prompt(
                cwd: "/srv/a b",
                cwdTruncated: true,
                exitCode: -2,
                durationMilliseconds: 900
            )
        )
        XCTAssertEqual(
            try RemoteProducerProtocol.parse(line: "P/1\tERROR\tfifo_full").get(),
            .error(code: "fifo_full")
        )
        let oversized = "P/1\tERROR\t" + String(
            repeating: "x",
            count: RemoteProducerProtocol.maximumFrameBytes
        )
        switch RemoteProducerProtocol.parse(line: oversized) {
        case .failure(.frameTooLarge(let limit)):
            XCTAssertEqual(limit, 480)
        default:
            XCTFail("expected producer size rejection")
        }
        assertProducerViolation(
            "P/1\tPROMPT\t99\t/srv\t0\t0\t1",
            .invalidFieldCount(type: "PROMPT", expected: 6, actual: 7)
        )
    }

    func testDirectCollectorParserEnforcesFrameLimit() {
        let oversized = "KRP/1\tERROR\tcode\t" + String(
            repeating: "x",
            count: RemoteRuntimeProtocol.maximumFrameBytes
        )
        assertViolation(
            oversized,
            .frameTooLarge(limit: RemoteRuntimeProtocol.maximumFrameBytes)
        )
    }

    private func assertViolation(
        _ line: String,
        _ expected: RemoteProtocolViolation,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        switch RemoteRuntimeProtocol.parse(line: line) {
        case .failure(let actual):
            XCTAssertEqual(actual, expected, file: file, line: lineNumber)
        case .success(let frame):
            XCTFail("unexpected frame \(frame)", file: file, line: lineNumber)
        }
    }

    private func assertProducerViolation(
        _ line: String,
        _ expected: RemoteProtocolViolation,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        switch RemoteProducerProtocol.parse(line: line) {
        case .failure(let actual):
            XCTAssertEqual(actual, expected, file: file, line: lineNumber)
        case .success(let event):
            XCTFail("unexpected event \(event)", file: file, line: lineNumber)
        }
    }
}
