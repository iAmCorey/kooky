import Darwin
import Foundation
import XCTest
@testable import KookyKit

/// Functional coverage for `RemoteRuntimeScripts.reaperScript`, the detached
/// single cleanup executor. On macOS the reaper cannot be spawned detached
/// (no `setsid`), so these tests drive the script directly in the foreground
/// via `/bin/sh -c`, register agents through its control FIFO, and assert the
/// TERM→KILL reap semantics, identity guards, and sole-runtime-deletion
/// contract.
final class RemoteReaperTests: XCTestCase {
    private var spawned: [Process] = []
    private var spawnedGroups: [pid_t] = []
    private var openFDs: [Int32] = []
    private var tempDirs: [URL] = []

    override func tearDown() {
        for pgid in spawnedGroups { kill(-pgid, SIGKILL) }
        spawnedGroups.removeAll()
        for fd in openFDs { close(fd) }
        openFDs.removeAll()
        for process in spawned where process.isRunning {
            process.terminate()
        }
        for process in spawned {
            kill(process.processIdentifier, SIGKILL)
        }
        spawned.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    func testReaperScriptIsPOSIXShellSyntax() throws {        let process = Process()
        let input = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(RemoteRuntimeScripts.reaperScript.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let diagnostic = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }

    func testBootstrapSpawnsCapabilityGatedReaperAsSoleDeleter() {
        let script = RemoteRuntimeScripts.bootstrapScript
        // Detached via setsid, params by env, script fed on stdin heredoc.
        XCTAssertTrue(script.contains("setsid sh -s"))
        XCTAssertTrue(script.contains("KOOKY_REAPER_LEADER_PID=\"$$\""))
        XCTAssertTrue(script.contains("reaper.control"))
        // Inherited already-open control fd (constraint 2).
        XCTAssertTrue(script.contains("exec 6<> \"$_kooky_reaper_ctrl\""))
        // Capability gate (constraint 3): different pgid AND session than leader.
        XCTAssertTrue(script.contains("!= \"$_kooky_leader_pgid\""))
        XCTAssertTrue(script.contains("!= \"$_kooky_leader_sid\""))
        XCTAssertTrue(script.contains("export KOOKY_REAPER_ENABLED=1"))
        // Reaper is the SOLE deleter when enabled; leader hands off via SHUTDOWN.
        XCTAssertTrue(script.contains("printf 'SHUTDOWN\\n' >&6"))
        XCTAssertTrue(
            script.contains("if [ -n \"${KOOKY_REAPER_ENABLED:-}\" ]; then"),
            "leader trap must gate its own rm -rf on the reaper being disabled"
        )
    }

    func testAgentWrapperRegistersAndDeregistersOnInheritedFdOnly() {
        let script = KookyShellIntegration.remoteAgentBootstrapScript
        XCTAssertTrue(script.contains("trap '' PIPE"))
        XCTAssertTrue(script.contains("[ \"${KOOKY_REAPER_ENABLED:-}\" = 1 ]"))
        XCTAssertTrue(script.contains("printf 'REG\\t%s\\t%s\\t%s\\t%s\\n'"))
        XCTAssertTrue(script.contains("printf 'UNREG\\t%s\\n' \"$$\""))
        // Constraint 2: write to the inherited fd, never open the FIFO here.
        XCTAssertTrue(script.contains(">&6 2>/dev/null"))
        XCTAssertFalse(
            script.contains("reaper.control"),
            "the wrapper must not know or open the control FIFO path"
        )
    }

    func testReaperShutdownTerminatesRegisteredGroupAndRemovesRuntime() throws {
        let fixture = try makeReaperFixture()
        let leader = try spawnLeader()
        let reaper = try startReaper(fixture, leaderPID: leader.processIdentifier)
        let ctrl = try openControlWriter(fixture.ctrl)

        let target = try spawnGroupTarget()
        try register(target, into: ctrl)

        try writeFrame("SHUTDOWN\n", to: ctrl)
        waitForExit(reaper, timeout: 15)

        XCTAssertFalse(reaper.isRunning)
        XCTAssertFalse(isAlive(target.processIdentifier), "TERM should reap the group")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.runtime.path),
            "reaper is the sole deleter of the runtime directory"
        )
    }

    func testReaperEscalatesToKillWhenAgentIgnoresTerm() throws {
        let fixture = try makeReaperFixture()
        let leader = try spawnLeader()
        let reaper = try startReaper(fixture, leaderPID: leader.processIdentifier)
        let ctrl = try openControlWriter(fixture.ctrl)

        // Own process group, TERM ignored, only KILL can stop it.
        let target = try spawnProcess([
            "/usr/bin/perl", "-e",
            "setpgrp(0,0); $SIG{TERM}='IGNORE'; sleep 600",
        ])
        try waitUntilGroupLeader(target.processIdentifier)
        try register(target, into: ctrl)

        try writeFrame("SHUTDOWN\n", to: ctrl)
        waitForExit(reaper, timeout: 15)

        XCTAssertFalse(reaper.isRunning)
        XCTAssertFalse(
            isAlive(target.processIdentifier),
            "grace expiry must escalate TERM to KILL"
        )
    }

    func testReaperSkipsIdentityMismatchedEntry() throws {
        let fixture = try makeReaperFixture()
        let leader = try spawnLeader()
        let reaper = try startReaper(fixture, leaderPID: leader.processIdentifier)
        let ctrl = try openControlWriter(fixture.ctrl)

        let target = try spawnGroupTarget()
        let pid = String(target.processIdentifier)
        // Deliberately wrong recorded start-time → PID-reuse guard must skip it.
        try writeFrame("REG\t\(pid)\t\(pid)\tWed Jan  1 00:00:00 2000\t-\n", to: ctrl)

        try writeFrame("SHUTDOWN\n", to: ctrl)
        waitForExit(reaper, timeout: 15)

        XCTAssertTrue(
            isAlive(target.processIdentifier),
            "start-time mismatch must fail closed and never signal the group"
        )
    }

    func testReaperDoesNotKillUnregisteredResidue() throws {
        let fixture = try makeReaperFixture()
        let leader = try spawnLeader()
        let reaper = try startReaper(fixture, leaderPID: leader.processIdentifier)
        let ctrl = try openControlWriter(fixture.ctrl)

        let target = try spawnGroupTarget()
        try register(target, into: ctrl)
        try writeFrame("UNREG\t\(target.processIdentifier)\n", to: ctrl)

        try writeFrame("SHUTDOWN\n", to: ctrl)
        waitForExit(reaper, timeout: 15)

        XCTAssertTrue(
            isAlive(target.processIdentifier),
            "an UNREG'd agent's background residue must be left running"
        )
    }

    func testReaperPollerReapsOnLeaderDeath() throws {
        let fixture = try makeReaperFixture()
        let leader = try spawnLeader()
        let reaper = try startReaper(
            fixture,
            leaderPID: leader.processIdentifier,
            poll: 1
        )
        let ctrl = try openControlWriter(fixture.ctrl)

        let target = try spawnGroupTarget()
        try register(target, into: ctrl)

        // No manual SHUTDOWN: killing the leader must make the poller emit one.
        kill(leader.processIdentifier, SIGKILL)
        waitForExit(reaper, timeout: 15)

        XCTAssertFalse(reaper.isRunning, "poller must convert leader death to SHUTDOWN")
        XCTAssertFalse(isAlive(target.processIdentifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtime.path))
    }

    func testReaperReapsRecordedGroupAfterWrapperAnchorDies() throws {
        let fixture = try makeReaperFixture()
        let leader = try spawnLeader()
        let reaper = try startReaper(fixture, leaderPID: leader.processIdentifier)
        let ctrl = try openControlWriter(fixture.ctrl)

        // Model the incident race: a foreground wrapper is the group leader,
        // forks a HUP/TERM-ignoring agent in the same group, then dies before
        // the reaper observes PTY death. The recorded SID+PGID must still
        // identify and reclaim the surviving agent without trusting a reused
        // wrapper PID.
        let wrapper = try spawnProcess([
            "/usr/bin/perl", "-e",
            "setpgrp(0,0); if (fork() == 0) { $SIG{TERM}='IGNORE'; sleep 600; exit 0 } sleep 600",
        ])
        try waitUntilGroupLeader(wrapper.processIdentifier)
        spawnedGroups.append(wrapper.processIdentifier)
        try register(wrapper, into: ctrl)
        // Let the child complete fork() before removing the wrapper anchor.
        usleep(300_000)
        kill(wrapper.processIdentifier, SIGKILL)

        let groupDeadline = Date().addingTimeInterval(5)
        while !groupHasNonZombieMember(wrapper.processIdentifier), Date() < groupDeadline {
            usleep(50_000)
        }
        XCTAssertTrue(
            groupHasNonZombieMember(wrapper.processIdentifier),
            "child group member must survive"
        )

        try writeFrame("SHUTDOWN\n", to: ctrl)
        waitForExit(reaper, timeout: 15)

        XCTAssertFalse(reaper.isRunning)
        let reapDeadline = Date().addingTimeInterval(5)
        while groupHasNonZombieMember(wrapper.processIdentifier), Date() < reapDeadline {
            usleep(50_000)
        }
        XCTAssertFalse(
            groupHasNonZombieMember(wrapper.processIdentifier),
            "reaper must reclaim the group after its wrapper anchor dies"
        )
    }

    func testCleanupCommandRoutesShutdownToLiveReaperAndReclaims() throws {
        // End-to-end: the ssh-side cleanupCommand must NOT signal processes
        // itself when a reaper owns the session (constraint 1). It asks the
        // reaper to shut down; the reaper reaps the registered group and is the
        // sole deleter of the runtime.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-cleanup-reaper-\(UUID().uuidString)")
        let token = UUID()
        let base = root.appendingPathComponent("kooky-\(getuid())")
        let runtime = base.appendingPathComponent(token.uuidString.lowercased())
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: runtime.path
        )
        tempDirs.append(root)
        let ctrl = runtime.appendingPathComponent("reaper.control").path
        XCTAssertEqual(mkfifo(ctrl, 0o600), 0)

        let leader = try spawnLeader()
        let reaper = try startReaper(
            ReaperFixture(runtime: runtime, ctrl: ctrl),
            leaderPID: leader.processIdentifier
        )
        try writeFile(String(leader.processIdentifier), "leader.pid", in: runtime)
        try writeFile(String(reaper.processIdentifier), "reaper.pid", in: runtime)
        try writeFile(token.uuidString.lowercased(), "token", in: runtime)

        let ctrlWriter = try openControlWriter(ctrl)
        let target = try spawnGroupTarget()
        try register(target, into: ctrlWriter)

        let status = try runCleanup(token: token, runtimeRoot: root)

        XCTAssertEqual(status, 0)
        XCTAssertFalse(isAlive(target.processIdentifier), "reaper must reap the group")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
    }

    func testCleanupDirectPathEscalatesTermToKill() {
        // The legacy/no-reaper path must escalate rather than send a lone TERM.
        let cleanup = RemoteRuntimeScripts.cleanupCommand(token: UUID())
        XCTAssertTrue(cleanup.contains("kill -KILL"))
        XCTAssertTrue(cleanup.contains("printf 'SHUTDOWN\\n' >&3"))
        XCTAssertTrue(cleanup.contains("reaper.pid"))
        XCTAssertTrue(cleanup.contains("reaper.control"))
    }

    private func runCleanup(token: UUID, runtimeRoot: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteRuntimeScripts.cleanupCommand(token: token)]
        var env = ProcessInfo.processInfo.environment
        env["XDG_RUNTIME_DIR"] = runtimeRoot.path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func writeFile(_ value: String, _ name: String, in dir: URL) throws {
        try Data((value + "\n").utf8).write(to: dir.appendingPathComponent(name))
    }

    // MARK: - Fixture & helpers

    private struct ReaperFixture {
        let runtime: URL
        let ctrl: String
    }

    private func makeReaperFixture() throws -> ReaperFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-reaper-\(UUID().uuidString)")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        tempDirs.append(root)
        let ctrl = runtime.appendingPathComponent("reaper.control").path
        let status = mkfifo(ctrl, 0o600)
        XCTAssertEqual(status, 0, "mkfifo failed: \(String(cString: strerror(errno)))")
        return ReaperFixture(runtime: runtime, ctrl: ctrl)
    }

    private func startReaper(
        _ fixture: ReaperFixture,
        leaderPID: pid_t,
        poll: Int = 5,
        grace: Int = 1
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteRuntimeScripts.reaperScript]
        var env = ProcessInfo.processInfo.environment
        env["KOOKY_REAPER_RUNTIME"] = fixture.runtime.path
        env["KOOKY_REAPER_CTRL"] = fixture.ctrl
        env["KOOKY_REAPER_LEADER_PID"] = String(leaderPID)
        env["KOOKY_REAPER_POLL"] = String(poll)
        env["KOOKY_REAPER_GRACE"] = String(grace)
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)
        return process
    }

    /// A long-lived stand-in for the interactive login leader. Kept alive so the
    /// poller does not fire until a test intentionally triggers shutdown.
    private func spawnLeader() throws -> Process {
        try spawnProcess(["/bin/sleep", "600"])
    }

    /// A `sleep` in its OWN process group so `kill -<pgid>` cannot reach the
    /// test runner. `setpgrp(0,0)` makes the group id equal the pid.
    private func spawnGroupTarget() throws -> Process {
        let process = try spawnProcess([
            "/usr/bin/perl", "-e", "setpgrp(0,0); exec 'sleep', '600'",
        ])
        try waitUntilGroupLeader(process.processIdentifier)
        return process
    }

    @discardableResult
    private func spawnProcess(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)
        return process
    }

    private func openControlWriter(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(
            fd, 0, "open control fifo: \(String(cString: strerror(errno)))"
        )
        openFDs.append(fd)
        return fd
    }

    private func register(_ process: Process, into fd: Int32) throws {
        let pid = String(process.processIdentifier)
        let start = try psValue(["-o", "lstart=", "-p", pid])
        let sid = try psValue(["-o", "sess=", "-p", pid])
        try writeFrame("REG\t\(pid)\t\(pid)\t\(start)\t\(sid)\n", to: fd)
    }

    private func writeFrame(_ frame: String, to fd: Int32) throws {
        let bytes = Array(frame.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        XCTAssertEqual(
            written, bytes.count,
            "short write to control fifo: \(String(cString: strerror(errno)))"
        )
    }

    private func waitUntilGroupLeader(_ pid: pid_t, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pgid = (try? psValue(["-o", "pgid=", "-p", String(pid)])) ?? ""
            if pgid == String(pid) { return }
            usleep(50_000)
        }
        XCTFail("process \(pid) never became its own group leader")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func groupHasNonZombieMember(_ pgid: pid_t) -> Bool {
        guard let output = try? psValue(["-eo", "pgid=,stat="]) else { return false }
        return output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == Substring(String(pgid)) else { return false }
            return !fields[1].hasPrefix("Z")
        }
    }

    private func psValue(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
