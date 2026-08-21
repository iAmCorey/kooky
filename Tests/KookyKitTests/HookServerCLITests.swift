import Darwin
import XCTest
@testable import KookyKit
import KookyHookKit

/// End-to-end socket tests for the CLI request/response branch: a real
/// `HookServer` bound to a throwaway path, driven by the real
/// `KookyCLITransport` client. The transport blocks, so it runs on a
/// detached thread while the main thread spins the run loop (the server's
/// accept source lives on the main queue) via `wait(for:)`.
@MainActor
final class HookServerCLITests: XCTestCase {
    private final class ResultBox: @unchecked Sendable {
        var value: Result<Data, KookyCLITransport.Failure>?
    }

    private var server: HookServer?
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        socketPath = NSTemporaryDirectory() + "kooky-cli-test-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    private func startServer(
        onCLIRequest: HookServer.CLIHandler?,
        handler: @escaping HookServer.Handler = { _ in }
    ) {
        let server = HookServer(socketPath: socketPath, handler: handler)
        server.onCLIRequest = onCLIRequest
        server.start()
        self.server = server
    }

    /// Runs one blocking exchange off-main while the main thread spins the
    /// run loop for the server's accept source.
    private func offMain(
        timeout: TimeInterval = 7,
        _ work: @escaping @Sendable () -> Result<Data, KookyCLITransport.Failure>
    ) -> Result<Data, KookyCLITransport.Failure>? {
        let done = expectation(description: "off-main exchange")
        let box = ResultBox()
        Thread.detachNewThread {
            box.value = work()
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        return box.value
    }

    private func roundTrip(_ line: Data, timeout: TimeInterval = 5) -> Result<Data, KookyCLITransport.Failure>? {
        let path = socketPath
        return offMain(timeout: timeout + 2) {
            KookyCLITransport.roundTrip(line: line, socketPath: path, timeout: timeout)
        }
    }

    private func decodeReply(_ reply: Result<Data, KookyCLITransport.Failure>?) throws -> KookyCLIResponse {
        try XCTUnwrap(KookyCLIResponse.decode(from: XCTUnwrap(reply).get()), "reply must decode as a response line")
    }

    func testCLIRequestGetsOneResponseLine() throws {
        startServer(onCLIRequest: { request, _, completion in
            XCTAssertEqual(request.verb, "status")
            completion(KookyCLIResponse(ok: true, appVersion: "test-1.0"))
        })
        let line = try XCTUnwrap(KookyCLIRequest(verb: .status).encodedLine())
        let response = try decodeReply(roundTrip(line))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.appVersion, "test-1.0")
    }

    func testRequestLineLargerThanOneReadBufferSurvives() throws {
        // 4 KiB is the server's per-read buffer; a long `open -e` command
        // must cross it intact via the read-to-newline loop.
        let command = String(repeating: "x", count: 8_000)
        startServer(onCLIRequest: { request, _, completion in
            completion(KookyCLIResponse(ok: true, note: "len:\(request.command?.count ?? -1)"))
        })
        let line = try XCTUnwrap(KookyCLIRequest(verb: .open, cwd: "/tmp", command: command).encodedLine())
        XCTAssertGreaterThan(line.count, 4096)
        let response = try decodeReply(roundTrip(line))
        XCTAssertEqual(response.note, "len:8000")
    }

    func testMalformedCLILineIsAnsweredNotDropped() throws {
        startServer(onCLIRequest: { _, _, completion in completion(KookyCLIResponse(ok: true)) })
        let line = Data("{\"kind\":\"cli\",\"verb\":42}\n".utf8)
        let response = try decodeReply(roundTrip(line))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("malformed") == true)
    }

    func testFutureProtocolVersionGetsVersionErrorNotMalformed() throws {
        // A breaking v2 is exactly what fails the typed decode — the
        // version peek must answer "update kooky" before decode gets a
        // chance to call it malformed.
        startServer(onCLIRequest: { _, _, completion in completion(KookyCLIResponse(ok: true)) })
        let line = Data("{\"kind\":\"cli\",\"protocolVersion\":99,\"verb\":42}\n".utf8)
        let response = try decodeReply(roundTrip(line))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("update kooky") == true)
        XCTAssertTrue(response.error?.contains("99") == true)
    }

    func testOverlongRequestLineIsAnsweredWithReadableError() throws {
        // Bypasses the CLI's own pre-check on purpose (a raw client): the
        // server truncates at the request cap and must still answer with
        // the real reason, not hang up (which the CLI would misreport as
        // "kooky may be older than this kooky-cli").
        startServer(onCLIRequest: { _, _, completion in completion(KookyCLIResponse(ok: true)) })
        var padded = Data("{\"kind\":\"cli\",\"pad\":\"".utf8)
        padded.append(Data(repeating: 0x61, count: KookyCLIProtocol.maxRequestLineBytes))
        let line = padded
        let path = socketPath
        let response = try decodeReply(offMain(timeout: 10) {
            Self.blockingExchange(line: line, socketPath: path)
        })
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("too long") == true)
    }

    func testUnwiredCLIHandlerStillAnswers() throws {
        startServer(onCLIRequest: nil)
        let line = try XCTUnwrap(KookyCLIRequest(verb: .status).encodedLine())
        let response = try decodeReply(roundTrip(line))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("not ready") == true)
    }

    func testHookLifecyclePayloadStaysFireAndForget() throws {
        // The pre-existing one-way path must be untouched: a hook line
        // reaches the handler and gets NO reply (the server closes without
        // writing, which the transport reports as closedWithoutReply).
        let received = expectation(description: "hook message delivered")
        startServer(onCLIRequest: { _, _, completion in completion(KookyCLIResponse(ok: true)) }) { message in
            if case .agent(let agent, let event, let sessionId) = message {
                XCTAssertEqual(agent.id, "claude-code")
                XCTAssertEqual(event, .running)
                XCTAssertEqual(sessionId.uuidString, "00000000-0000-0000-0000-000000000001")
                received.fulfill()
            }
        }
        let payload = KookyHookKit.buildLifecyclePayload(
            agent: "claude",
            event: "running",
            surface: "00000000-0000-0000-0000-000000000001"
        )
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        let reply = try XCTUnwrap(roundTrip(line, timeout: 3))
        XCTAssertEqual(reply, .failure(.closedWithoutReply))
        wait(for: [received], timeout: 2)
    }

    func testSocketFileIsOwnerOnly() throws {
        startServer(onCLIRequest: nil)
        var info = stat()
        XCTAssertEqual(stat(socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "the CLI control socket must be owner-only")
    }

    func testConnectToNothingFailsFast() throws {
        // No server started — the transport must fail with connectFailed
        // (this is the CLI's "kooky is not running" signal), quickly.
        let started = ContinuousClock.now
        let line = try XCTUnwrap(KookyCLIRequest(verb: .status).encodedLine())
        let reply = roundTrip(line, timeout: 5)
        XCTAssertEqual(reply, .failure(.connectFailed))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    /// Blocking write-then-read client for the overlong case — the normal
    /// transport can hit EPIPE when the server answers mid-write; a plain
    /// blocking socket rides the kernel buffer instead.
    private nonisolated static func blockingExchange(line: Data, socketPath: String) -> Result<Data, KookyCLITransport.Failure> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.connectFailed) }
        defer { close(fd) }
        // The server can answer + close while we still have bytes in
        // flight; without this the pending write turns into SIGPIPE and
        // kills the test runner.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = KookyHookKit.withUnixSocketAddress(path: socketPath) { addr, len in
            connect(fd, addr, len)
        }
        guard connected == 0 else { return .failure(.connectFailed) }
        let bytes = [UInt8](line)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n; continue }
            break  // EPIPE once the server stopped reading — fine, it answered
        }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                reply.append(contentsOf: buffer[0..<n])
                if buffer[0..<n].contains(0x0A) { break }
                continue
            }
            break
        }
        guard let newline = reply.firstIndex(of: 0x0A) else { return .failure(.closedWithoutReply) }
        return .success(reply.prefix(upTo: newline))
    }

    /// The response write must survive a client that hangs up WHILE its
    /// request is being served — a slow verb outliving the CLI's own 15s
    /// timeout. Without SIGPIPE protection that write kills the process: in
    /// the app that is every terminal and every running agent gone with no
    /// crash report, and here it takes down the test runner (so a regression
    /// shows up as the suite dying, not as this test failing).
    ///
    /// The client stays connected until the handler is in hand, because a
    /// client that left BEFORE dispatch is now dropped outright — that is
    /// the other test below.
    func testResponseToAClientThatLeftMidRequestDoesNotKillTheProcess() throws {
        let pendingBox = PendingBox()
        let received = expectation(description: "server got the request")
        startServer(onCLIRequest: { _, _, completion in
            guard !pendingBox.captured else {
                completion(KookyCLIResponse(ok: true, appVersion: "test"))
                return
            }
            pendingBox.captured = true
            pendingBox.completion = completion
            received.fulfill()
        })

        let line = try XCTUnwrap(KookyCLIRequest(verb: .status).encodedLine())
        let mayClose = DispatchSemaphore(value: 0)
        let hungUp = expectation(description: "client closed")
        let path = socketPath
        Thread.detachNewThread {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return hungUp.fulfill() }
            guard KookyHookKit.withUnixSocketAddress(path: path, { addr, len in
                connect(fd, addr, len)
            }) == 0 else {
                close(fd)
                return hungUp.fulfill()
            }
            let bytes = [UInt8](line)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, bytes.count) }
            // Stay connected until the server has taken the request.
            _ = mayClose.wait(timeout: .now() + 5)
            close(fd)
            hungUp.fulfill()
        }
        wait(for: [received], timeout: 5)
        mayClose.signal()
        wait(for: [hungUp], timeout: 5)

        // The line under test: answering a socket whose peer is now gone.
        pendingBox.completion?(.failure("late answer"))

        // Still alive — and still serving, so the fd was closed on the
        // write-error path rather than leaked.
        let after = roundTrip(try XCTUnwrap(KookyCLIRequest(verb: .status).encodedLine()))
        guard case .success = after else {
            return XCTFail("server stopped answering after writing to a departed client: \(String(describing: after))")
        }
    }

    /// A request whose caller is already gone must not be PERFORMED. The
    /// connection can sit in the listen queue for as long as the main thread
    /// is blocked, long past the CLI's timeout — and `open -e` executed then
    /// runs a command whose invoker was told it failed, and may have retried.
    func testRequestFromAClientThatLeftIsNeverDispatched() throws {
        let box = PendingBox()   // `captured` doubles as "was it dispatched"
        startServer(onCLIRequest: { _, _, completion in
            box.captured = true
            completion(KookyCLIResponse(ok: true, appVersion: "test"))
        })

        let line = try XCTUnwrap(
            KookyCLIRequest(verb: .open, cwd: NSTemporaryDirectory(), command: "touch /tmp/should-never-run").encodedLine()
        )
        let hungUp = expectation(description: "client wrote and left")
        let path = socketPath
        Thread.detachNewThread {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return hungUp.fulfill() }
            guard KookyHookKit.withUnixSocketAddress(path: path, { addr, len in
                connect(fd, addr, len)
            }) == 0 else {
                close(fd)
                return hungUp.fulfill()
            }
            let bytes = [UInt8](line)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, bytes.count) }
            close(fd)          // gone before the server ever looks
            hungUp.fulfill()
        }
        wait(for: [hungUp], timeout: 5)

        // Give the accept source its turn on the main queue.
        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertFalse(
            box.captured,
            "a request whose caller already left must be dropped, not executed"
        )
    }

    /// Both fields are touched only on the main queue (the server's accept
    /// source runs there, and so does the test body).
    private final class PendingBox: @unchecked Sendable {
        var captured = false
        var completion: (@MainActor (KookyCLIResponse) -> Void)?
    }
}
