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

    func testCommandTextWaitsForEditorAcknowledgmentAndIsConsumedOnce() {
        let (session, engine) = fixture()
        XCTAssertTrue(session.runShellCommand("nvm use v22\r"))
        XCTAssertEqual(engine.sentInputs, [ShellCommandIntegration.keySequence])

        session.consumeShellControlTitle("kooky-shell-control:available:123")
        session.consumeShellControlTitle("kooky-shell-control:ready:123")
        XCTAssertEqual(engine.sentInputs.last, "nvm use v22\0")
        session.consumeShellControlTitle("kooky-shell-control:ready:123")
        XCTAssertEqual(engine.sentInputs.count, 2)
        session.consumeShellControlTitle("kooky-shell-control:finished:123")
        session.consumeShellControlTitle("kooky-shell-control:ready:123")
        XCTAssertEqual(engine.sentInputs.last, "\0")
    }

    func testCommandCannotBeReplacedWhileWaitingOrExecuting() {
        let (session, _) = fixture()
        XCTAssertTrue(session.runShellCommand("nvm use v22"))
        XCTAssertFalse(session.runShellCommand("nvm use v20"))
        session.consumeShellControlTitle("kooky-shell-control:ready:123")
        XCTAssertFalse(session.runShellCommand("nvm use v20"))
        session.consumeShellControlTitle("kooky-shell-control:finished:123")
        XCTAssertTrue(session.runShellCommand("nvm use v20"))
    }

    func testBusyOrRemoteTerminalReceivesNoInput() {
        let (session, engine) = fixture()
        engine.foregroundPid = 456
        XCTAssertFalse(session.runShellCommand("nvm use v22\r"))
        engine.foregroundPid = 123
        session.remoteHost = "server"
        XCTAssertFalse(session.runShellCommand("nvm use v22\r"))
        XCTAssertTrue(engine.sentInputs.isEmpty)
    }

    func testUnknownShellDoesNotFallBackToTypingTheCommand() {
        let (session, engine) = fixture()
        session.shellControlPID = nil
        XCTAssertFalse(session.runShellCommand("nvm use v22\r"))
        XCTAssertTrue(engine.sentInputs.isEmpty)
    }

    func testDelayedAcknowledgmentCancelsWithoutTypingCommandText() {
        let (session, engine) = fixture()
        let now = ContinuousClock.now
        XCTAssertTrue(session.runShellCommand("nvm use v22\r", now: now))
        session.consumeShellControlTitle("kooky-shell-control:ready:123", now: now + .seconds(2))
        XCTAssertEqual(engine.sentInputs.last, "\0")
    }

    func testDifferentShellCannotClaimPendingCommand() {
        let (session, engine) = fixture()
        XCTAssertTrue(session.runShellCommand("nvm use v22\r"))
        session.consumeShellControlTitle("kooky-shell-control:ready:456")
        XCTAssertEqual(engine.sentInputs, [ShellCommandIntegration.keySequence])
        session.consumeShellControlTitle("kooky-shell-control:available:456")
        engine.foregroundPid = 456
        session.consumeShellControlTitle("kooky-shell-control:ready:456")
        XCTAssertEqual(engine.sentInputs.last, "\0")
    }

    func testPayloadRejectsEmbeddedControlCharacters() {
        XCTAssertEqual(ShellCommandIntegration.payload(for: "git switch '中文'\r"), "git switch '中文'\0")
        for command in ["", "\r", "nvm use v22\nexit", "nvm\0use", "\u{1B}evil", String(repeating: "a", count: 4097)] {
            XCTAssertNil(ShellCommandIntegration.payload(for: command))
        }
    }

    func testMarkersRequireKnownEventAndPositivePid() {
        for title in ["ordinary title", "kooky-shell-control:ready:0", "kooky-shell-control:ready:-1", "kooky-shell-control:unknown:123", "kooky-shell-control:ready:123:extra", "kooky-shell-control:ready::123"] {
            XCTAssertNil(ShellCommandIntegration.parseTitle(title))
        }
        XCTAssertEqual(ShellCommandIntegration.parseTitle("kooky-shell-control:available:123")?.pid, 123)
    }

    func testStoreRoutesControlMarkersWithoutChangingTabTitle() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let session = try XCTUnwrap(store.active?.activeSession)
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        engine.foregroundPid = 123
        engine.emitTitle("kooky-shell-control:available:123")
        XCTAssertTrue(session.runShellCommand("nvm use v22"))
        engine.emitTitle("kooky-shell-control:ready:123")
        XCTAssertEqual(engine.sentInputs.last, "nvm use v22\0")
        engine.emitTitle("kooky-shell-control:finished:123")
        XCTAssertTrue(session.canRunShellCommand)
        XCTAssertNil(session.terminalTitle)
        XCTAssertNil(session.lastCommandText)
    }
}
