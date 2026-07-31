import Darwin
import XCTest
@testable import KookyKit

final class RemoteRuntimeScriptsTests: XCTestCase {
    func testGeneratedControlAndBootstrapScriptsArePOSIXShellSyntax() throws {
        let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        for script in [
            RemoteRuntimeScripts.bootstrapScript,
            RemoteRuntimeScripts.watchCommand(token: token),
            RemoteRuntimeScripts.cleanupCommand(token: token),
        ] {
            let process = Process()
            let input = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n"]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = error
            try process.run()
            input.fileHandleForWriting.write(Data(script.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let diagnostic = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        }
    }

    func testBootstrapStaysWithinMoshInlineLimitAfterQuoting() {
        let quoted = KookyShellIntegration.quote(RemoteRuntimeScripts.bootstrapScript)
        XCTAssertLessThanOrEqual(
            quoted.lengthOfBytes(using: .utf8),
            MoshCommandBuilder.maximumRemoteCommandBytes
        )
    }

    func testRuntimeContractHasPrivateDirectoryAtomicStateAndBoundedProducerFrames() {
        let script = RemoteRuntimeScripts.bootstrapScript
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains("mkdir -m 700"))
        XCTAssertTrue(script.contains("mkfifo -m 600"))
        XCTAssertTrue(script.contains("events.log"))
        XCTAssertTrue(script.contains("state.tmp"))
        XCTAssertTrue(script.contains("mv -f"))
        XCTAssertTrue(script.contains("P/1\\t"))
        XCTAssertTrue(script.contains("KRP/1\\t"))
        XCTAssertTrue(script.contains("leader.pid"))
        XCTAssertTrue(script.contains("leader.pgid"))
        XCTAssertTrue(script.contains("leader.start"))
        XCTAssertTrue(script.contains("parent.pid"))
        XCTAssertTrue(script.contains("parent.start"))
        XCTAssertTrue(script.contains("parent.command"))
        XCTAssertTrue(script.contains("_kooky_supervise_collector"))
        XCTAssertTrue(script.contains("collector-supervisor.pid"))
        XCTAssertTrue(script.contains("KOOKY_REMOTE_RUNTIME"))
        XCTAssertTrue(script.contains("SNAPSHOT\\t0\\t-\\tidle\\t-\\t0"))
        XCTAssertTrue(script.contains("recover.tmp"))
    }

    func testRuntimeTokenIsConsumedOnceAndNotLeakedToChildShell() throws {
        let script = RemoteRuntimeScripts.bootstrapScript
        XCTAssertTrue(
            script.contains("unset KOOKY_RUNTIME_TOKEN"),
            "runtime token must be unset so it does not leak into the handoff"
        )

        // Functionally confirm the exported token does not survive to the point
        // where the nested `sh -lc` handoff runs. Replay the bootstrap's token
        // capture + unset prologue, then assert a child shell sees it empty.
        let stub = """
        _kooky_token=${KOOKY_RUNTIME_TOKEN:-}
        unset KOOKY_RUNTIME_TOKEN
        sh -c 'printf "child_token=[%s]\\n" "${KOOKY_RUNTIME_TOKEN:-}"'
        """
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.environment = ["KOOKY_RUNTIME_TOKEN": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(stub.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let out = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertTrue(out.contains("child_token=[]"), out)
    }

    func testWatchAndCleanupValidateTokenOwnerModeAndProcessIdentity() {
        let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let watch = RemoteRuntimeScripts.watchCommand(token: token)
        let cleanup = RemoteRuntimeScripts.cleanupCommand(token: token)

        for script in [watch, cleanup] {
            XCTAssertTrue(script.contains("stat -c %u"))
            XCTAssertTrue(script.contains("stat -f %u"))
            XCTAssertTrue(script.contains("[ ! -L"))
            XCTAssertTrue(script.contains(token.uuidString.lowercased()))
        }
        XCTAssertTrue(cleanup.contains("ps -o pgid="))
        XCTAssertTrue(cleanup.contains("ps -o lstart="))
        XCTAssertTrue(cleanup.contains("kill -TERM"))
        XCTAssertFalse(cleanup.contains("rm -rf /"))
    }

    func testPromptHotPathsAvoidExternalTextFilters() {
        let script = KookyShellIntegration.remoteAgentBootstrapScript
        XCTAssertFalse(script.contains("| sed "))
        XCTAssertFalse(script.contains("| tr "))
        XCTAssertFalse(script.contains("python"))
        XCTAssertTrue(script.contains("precmd"))
        XCTAssertTrue(script.contains("PROMPT_COMMAND"))
        XCTAssertTrue(script.contains("fish_prompt"))
    }

    func testRemoteCodexNotifyOverrideParsesAsTomlArrayNotString() throws {
        let script = KookyShellIntegration.remoteAgentBootstrapScript

        // Regression guard for the "expected a sequence in `notify`" crash: the
        // remote wrapper lives in a Swift RAW string, where a double backslash
        // (`\\"`) survives verbatim into the file. The remote /bin/sh then
        // collapses `\\` → `\` and the following `"` closes the shell quote
        // early, so codex receives one mangled STRING
        // (`notify=[\/…hook\,\AGENT\,…]`) instead of a TOML array. The override
        // must therefore be single-backslash escaped (`\"`).
        XCTAssertTrue(
            script.contains(#"notify=[\"$KOOKY_REMOTE_HOOK\",\"AGENT\",\"codex\",\"attention\"]"#),
            "codex notify override must be single-backslash escaped in the raw string"
        )
        XCTAssertFalse(
            script.contains(##"notify=[\\""##),
            "double-backslash escaping mangles notify into a string on the remote"
        )

        // Functional proof: run the ACTUAL generated injection line under
        // /bin/sh with a stub `codex` and assert the argv it receives is a
        // real quoted array.
        let notifyLine = try XCTUnwrap(
            script
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { $0.contains("-c \"notify=") }
        ).trimmingCharacters(in: .whitespaces)

        let hook = "/run/user/1000/kooky-1000/dead-beef/kooky-remote-hook"
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-codex-stub-\(UUID().uuidString)")
        try #"""
        #!/bin/sh
        for a in "$@"; do printf '%s\n' "$a"; done
        """#.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path
        )
        defer { try? FileManager.default.removeItem(at: stub) }

        let harness = """
        _kooky_real=\(KookyShellIntegration.quote(stub.path))
        KOOKY_REMOTE_HOOK=\(KookyShellIntegration.quote(hook))
        \(notifyLine)
        """

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(harness.utf8))
        try input.fileHandleForWriting.close()
        let stdout = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        process.waitUntilExit()

        let argv = stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(argv.first, "-c")
        XCTAssertEqual(
            argv.dropFirst().first,
            "notify=[\"\(hook)\",\"AGENT\",\"codex\",\"attention\"]",
            "codex must receive notify as a TOML array, not a backslash-mangled string"
        )
    }

    func testCleanupFailsClosedWhenLiveProcessStartIdentityDoesNotMatch() throws {
        let fixture = try makeCleanupFixture(leaderPID: getpid())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let livePGID = try psValue(["-o", "pgid=", "-p", String(getpid())])
        let liveParentStart = try psValue([
            "-o", "lstart=", "-p", String(getppid()),
        ])
        let liveParentCommand = try psValue([
            "-o", "comm=", "-p", String(getppid()),
        ])
        try write(livePGID, named: "leader.pgid", in: fixture.runtime)
        try write("identity-does-not-match", named: "leader.start", in: fixture.runtime)
        try write(String(getppid()), named: "parent.pid", in: fixture.runtime)
        try write(liveParentStart, named: "parent.start", in: fixture.runtime)
        try write(liveParentCommand, named: "parent.command", in: fixture.runtime)

        let status = try runCleanup(
            token: fixture.token,
            runtimeRoot: fixture.root
        )

        XCTAssertEqual(status, 76)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.runtime.path))
    }

    func testCleanupRemovesExactStaleRuntimeWhenRecordedLeaderIsGone() throws {
        let fixture = try makeCleanupFixture(leaderPID: 99_999_999)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("99999999", named: "leader.pgid", in: fixture.runtime)
        try write("stale", named: "leader.start", in: fixture.runtime)
        try write("99999998", named: "parent.pid", in: fixture.runtime)
        try write("stale", named: "parent.start", in: fixture.runtime)
        try write("mosh-server", named: "parent.command", in: fixture.runtime)

        let status = try runCleanup(
            token: fixture.token,
            runtimeRoot: fixture.root
        )

        XCTAssertEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtime.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    private func makeCleanupFixture(
        leaderPID: pid_t
    ) throws -> (root: URL, runtime: URL, token: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-cleanup-\(UUID().uuidString)")
        let token = UUID()
        let base = root.appendingPathComponent("kooky-\(getuid())")
        let runtime = base.appendingPathComponent(token.uuidString.lowercased())
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtime.path
        )
        try write(token.uuidString.lowercased(), named: "token", in: runtime)
        try write(String(leaderPID), named: "leader.pid", in: runtime)
        return (root, runtime, token)
    }

    private func runCleanup(token: UUID, runtimeRoot: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteRuntimeScripts.cleanupCommand(token: token)]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = runtimeRoot.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
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
        XCTAssertEqual(process.terminationStatus, 0)
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ value: String, named name: String, in directory: URL) throws {
        try Data((value + "\n").utf8).write(
            to: directory.appendingPathComponent(name)
        )
    }
}
