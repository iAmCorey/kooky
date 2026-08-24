import Darwin
import Foundation
import KookyHookKit

// kooky-cli: the local control channel for a running kooky. External tools
// (Wake, Raycast, plain scripts) drive kooky through it: open a tab and run
// a command, resume an agent conversation, list / focus / close tabs. Talks
// the request/response branch of the hook socket (`kind: "cli"`); parsing,
// rendering, and transport live in KookyHookKit so they're unit-testable —
// this file is a thin dispatcher, like KookyHook's main.swift.
//
// Exit codes:
//   0 — request accepted by the app (for `close` that means "close
//       requested"; in-app confirmation rules still apply).
//   1 — any failure: app couldn't be launched, bad arguments, unknown tab,
//       refused request, timeout. One human-readable line on stderr.
//
// Every verb except `status` launches kooky first when it isn't running,
// then waits (up to 10s) for the socket to come up.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kooky-cli: \(KookyHookKit.plain(message))\n".utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("kooky-cli: warning: \(KookyHookKit.plain(message))\n".utf8))
}

/// Launch the app this CLI shipped with. Walking up from the (symlink-
/// resolved) executable finds the .app for in-bundle installs; the
/// Application Support mirror copy falls back to LaunchServices by name.
///
/// `background` (open --no-focus on a cold start) adds `-g` so Launch
/// Services doesn't activate kooky. Necessary but possibly not sufficient:
/// the app's own launch sequence calls NSApp.activate itself, which
/// macOS 14's cooperative activation MAY refuse without an activation
/// token — verified on hardware, not guaranteed by contract.
func launchKooky(background: Bool) -> Bool {
    let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let bundle = URL(fileURLWithPath: exePath).resolvingSymlinksInPath()
        .deletingLastPathComponent()  // MacOS
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // Kooky.app
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var arguments = bundle.pathExtension == "app" ? [bundle.path] : ["-a", "Kooky"]
    if background { arguments.insert("-g", at: 0) }
    process.arguments = arguments
    // `open` writes its own diagnostics (app missing, LaunchServices errors)
    // to the stderr it inherits from us. We report the failure ourselves in
    // one line, which is the contract this CLI states — so its output would
    // be a second, uncontrolled line on top of ours.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func printSuccess(_ response: KookyCLIResponse, for command: KookyCLICommand) {
    switch command {
    case .list(let json):
        let windows = response.windows ?? []
        print(json ? KookyHookKit.renderCLIListJSON(windows) : KookyHookKit.renderCLIList(windows))
    case .status(let json):
        if json {
            print(KookyHookKit.renderCLIStatusJSON(
                running: true,
                appVersion: response.appVersion,
                serverProtocol: response.protocolVersion
            ))
        } else {
            let version = response.appVersion ?? "unknown version"
            let proto = response.protocolVersion.map(String.init) ?? "?"
            print("kooky \(KookyHookKit.plain(version)) is running (protocol \(proto))")
        }
    case .open:
        // One line either way; the id stays the third word for scripts.
        let head = response.tabId.map { "opened tab \(KookyHookKit.plain($0))" } ?? "opened"
        print(response.note.map { "\(head) — \(KookyHookKit.plain($0))" } ?? head)
    case .resume, .focus, .close, .rename:
        print(KookyHookKit.plain(response.note ?? "ok"))
    case .help:
        break
    }
}

// MARK: - Main flow

let arguments = Array(CommandLine.arguments.dropFirst())

let parsed: KookyCLICommand
switch KookyHookKit.parseCLICommand(arguments) {
case .success(let value): parsed = value
case .failure(let error): fail(error.message)
}

if parsed == .help {
    print(KookyHookKit.renderCLIHelp())
    exit(0)
}

// Absolutize caller-relative paths against THIS process's cwd — the app
// can't know it. The server still enforces absolute + existing.
let processCwd = FileManager.default.currentDirectoryPath
let command: KookyCLICommand
switch parsed {
case .open(let cwd, let cmd, let agent, let title, let noFocus):
    command = .open(
        cwd: cwd.map { KookyHookKit.normalizeCLIPath($0, relativeTo: processCwd) },
        command: cmd,
        agent: agent,
        title: title,
        noFocus: noFocus
    )
case .resume(let agent, let id, let cwd):
    command = .resume(
        agent: agent,
        id: id,
        cwd: cwd.map { KookyHookKit.normalizeCLIPath($0, relativeTo: processCwd) }
    )
default:
    command = parsed
}

guard let request = KookyHookKit.cliRequest(for: command),
      let line = request.encodedLine()
else {
    fail("internal error: request encoding failed")
}
// Same limit the server's read loop enforces — fail here with the real
// reason instead of a server-side truncation.
guard line.count <= KookyCLIProtocol.maxRequestLineBytes else {
    fail("request is too large (over \(KookyCLIProtocol.maxRequestLineBytes) bytes) — shorten the -e command")
}

let socketPath = KookyHookKit.socketPath
// Reply deadline exceeds the app's own 10s resume-resolution deadline so a
// slow-but-answered resume never reads as a dead server.
let replyTimeout: TimeInterval = 15
let launchTimeout: TimeInterval = 10

func attempt() -> Result<Data, KookyCLITransport.Failure> {
    KookyCLITransport.roundTrip(line: line, socketPath: socketPath, timeout: replyTimeout)
}

var result = attempt()

if case .failure(.connectFailed) = result {
    if case .status(let json) = command {
        // `status` reports instead of launching.
        if json {
            print(KookyHookKit.renderCLIStatusJSON(running: false, appVersion: nil, serverProtocol: nil))
        } else {
            print("kooky is not running")
        }
        exit(1)
    }
    let backgroundLaunch: Bool = {
        if case .open(_, _, _, _, let noFocus) = command { return noFocus }
        return false
    }()
    guard launchKooky(background: backgroundLaunch) else {
        fail("kooky is not running and couldn't be launched")
    }
    let deadline = DispatchTime.now() + launchTimeout
    while true {
        result = attempt()
        if case .failure(.connectFailed) = result, DispatchTime.now() < deadline {
            usleep(250_000)
            continue
        }
        break
    }
}

switch result {
case .failure(.connectFailed):
    fail("kooky did not start listening within \(Int(launchTimeout))s")
case .failure(.timedOut), .failure(.closedWithoutReply):
    fail("kooky is running but didn't answer — it may be older than this kooky-cli (no CLI support). Update kooky, or use the kooky-cli bundled with the running version.")
case .failure(.writeFailed):
    fail("couldn't send the request to kooky")
case .failure(.replyTooLarge):
    fail("kooky sent an oversized reply")
case .success(let data):
    guard let response = KookyCLIResponse.decode(from: data) else {
        fail("couldn't decode kooky's reply")
    }
    // Failures print exactly ONE line (the CLI's stated contract), so the
    // mismatch note waits until we know this is a success. A refusal caused
    // BY the mismatch already says so in its own message.
    guard response.ok else {
        fail(response.error ?? "request refused")
    }
    if let serverProtocol = response.protocolVersion, serverProtocol != KookyCLIProtocol.version {
        warn("protocol mismatch (cli \(KookyCLIProtocol.version), app \(serverProtocol)) — update kooky or use its bundled kooky-cli")
    }
    printSuccess(response, for: command)
    exit(0)
}
