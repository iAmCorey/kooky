import XCTest
@testable import KookyKit

@MainActor
final class ShellCommandIntegrationTests: XCTestCase {
    private func fixture() -> (Session, TestEngine) {
        let engine = TestEngine()
        engine.foregroundPid = 123
        let session = Session(engine: engine, currentDirectory: URL(fileURLWithPath: "/tmp"), agent: .terminal)
        session.consumeShellControlTitle("kooky-shell-control:available:123")
        return (session, engine)
    }

    func testCommandIsFetchedOnceWithoutSendingItsTextToTheTerminal() {
        let (session, engine) = fixture()
        XCTAssertTrue(session.runShellCommand("nvm use v22\r"))
        session.consumeShellControlTitle("kooky-shell-control:available:123")
        XCTAssertEqual(session.takeShellCommand(shellPID: 123), "nvm use v22")
        XCTAssertNil(session.takeShellCommand(shellPID: 123))
        session.consumeShellControlTitle("kooky-shell-control:finished:123")
        XCTAssertNil(session.takeShellCommand(shellPID: 123))
        XCTAssertEqual(engine.sentInputs, [ShellCommandIntegration.keySequence])
    }

    func testCommandCannotBeReplacedWhileWaitingOrExecuting() {
        let (session, _) = fixture()
        XCTAssertTrue(session.runShellCommand("nvm use v22"))
        XCTAssertFalse(session.runShellCommand("nvm use v20"))
        XCTAssertEqual(session.takeShellCommand(shellPID: 123), "nvm use v22")
        XCTAssertFalse(session.runShellCommand("nvm use v20"))
        session.consumeShellControlTitle("kooky-shell-control:finished:123")
        XCTAssertTrue(session.runShellCommand("nvm use v20"))
    }

    func testBusyOrRemoteTerminalCannotRunOrFetchACommand() {
        let (session, engine) = fixture()
        engine.foregroundPid = 456
        XCTAssertFalse(session.runShellCommand("nvm use v22"))
        engine.foregroundPid = 123
        XCTAssertTrue(session.runShellCommand("nvm use v22"))
        engine.foregroundPid = 456
        XCTAssertNil(session.takeShellCommand(shellPID: 123))
        engine.foregroundPid = 123
        session.remoteHost = "server"
        XCTAssertNil(session.takeShellCommand(shellPID: 123))
        XCTAssertFalse(session.runShellCommand("nvm use v20"))
        XCTAssertEqual(engine.sentInputs, [ShellCommandIntegration.keySequence])
    }

    func testProxyUnsetDoesNotSendCommandTextOrConsumeSubsequentUserInput() throws {
        let (session, engine) = fixture()
        let command = try XCTUnwrap(ProxyInfo.unsetCommand(for: "https_proxy"))
        XCTAssertTrue(session.runShellCommand(command))
        engine.sendInput("X")
        XCTAssertEqual(session.takeShellCommand(shellPID: 123), "_kooky_unset_proxy https_proxy HTTPS_PROXY")
        XCTAssertEqual(engine.sentInputs, [ShellCommandIntegration.keySequence, "X"])
    }

    func testUnknownShellDoesNotFallBackToTypingTheCommand() {
        let (session, engine) = fixture()
        session.shellControlPID = nil
        XCTAssertFalse(session.runShellCommand("nvm use v22"))
        XCTAssertTrue(engine.sentInputs.isEmpty)
    }

    func testDelayedFetchCancelsWithoutTypingCommandText() {
        let (session, engine) = fixture()
        let now = ContinuousClock.now
        XCTAssertTrue(session.runShellCommand("nvm use v22", now: now))
        XCTAssertNil(session.takeShellCommand(shellPID: 123, now: now + .seconds(2)))
        XCTAssertNil(session.takeShellCommand(shellPID: 123, now: now))
        XCTAssertEqual(engine.sentInputs, [ShellCommandIntegration.keySequence])
    }

    func testDifferentShellCannotClaimPendingCommand() {
        let (session, engine) = fixture()
        XCTAssertTrue(session.runShellCommand("nvm use v22"))
        XCTAssertNil(session.takeShellCommand(shellPID: 456))
        session.consumeShellControlTitle("kooky-shell-control:available:456")
        engine.foregroundPid = 456
        XCTAssertNil(session.takeShellCommand(shellPID: 456))
    }

    func testFailedFetchCompletionDiscardsThePendingCommand() {
        let (session, _) = fixture()
        XCTAssertTrue(session.runShellCommand("nvm use v22"))
        session.consumeShellControlTitle("kooky-shell-control:finished:123")
        XCTAssertNil(session.takeShellCommand(shellPID: 123))
        XCTAssertTrue(session.runShellCommand("nvm use v20"))
    }

    func testMarkersRequireKnownEventAndPositivePid() {
        for title in ["ordinary title", "kooky-shell-control:finished:0", "kooky-shell-control:finished:-1", "kooky-shell-control:ready:123", "kooky-shell-control:available:123:extra", "kooky-shell-control:available::123"] {
            XCTAssertNil(ShellCommandIntegration.parseTitle(title))
        }
        XCTAssertEqual(ShellCommandIntegration.parseTitle("kooky-shell-control:available:123")?.pid, 123)
    }

    func testStoreRoutesFetchAndControlMarkersWithoutChangingTabTitle() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let session = try XCTUnwrap(store.active?.activeSession)
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        engine.foregroundPid = 123
        engine.emitTitle("kooky-shell-control:available:123")
        XCTAssertTrue(session.runShellCommand("nvm use v22"))
        XCTAssertNil(store.takeShellCommand(sessionId: UUID(), shellPID: 123))
        XCTAssertEqual(store.takeShellCommand(sessionId: session.id, shellPID: 123), "nvm use v22")
        engine.emitTitle("kooky-shell-control:finished:123")
        XCTAssertEqual(engine.sentInputs, [ShellCommandIntegration.keySequence])
        XCTAssertTrue(session.canRunShellCommand)
        XCTAssertNil(session.terminalTitle)
        XCTAssertNil(session.lastCommandText)
    }
}
