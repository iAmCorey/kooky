import Darwin
import Foundation

// The `kooky-cli` front half: argv parsing, output rendering, and the
// request/response socket transport. Pure helpers in KookyHookKit so the
// per-verb grammar (required flags, mutual exclusion, UUID shape) is
// unit-testable without spawning the binary — `Sources/KookyCLI/main.swift`
// stays a thin dispatcher, mirroring how KookyHook leans on Parser.swift.

/// A parsed CLI invocation. `help` renders locally; everything else maps
/// 1:1 onto a `KookyCLIRequest`.
public enum KookyCLICommand: Equatable, Sendable {
    /// `cwd` is optional ONLY because a Terminal preset carries its own
    /// directory; every other template still needs one, which the app
    /// enforces (it is the side that knows what a template id resolves to).
    case open(cwd: String?, command: String?, agent: String?)
    case resume(agent: String, id: String, cwd: String?)
    case list(json: Bool)
    case focus(tab: String)
    case close(tab: String)
    case status(json: Bool)
    case help
}

public struct KookyCLIParseFailure: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

extension KookyHookKit {
    /// Per-verb flag grammar. Value flags take exactly the next token
    /// verbatim (so `-e "claude -p 'hi'"` and dash-leading values survive);
    /// bool flags stand alone.
    private struct VerbSpec {
        let valueFlags: Set<String>
        let boolFlags: Set<String>
        let usage: String
    }

    private static let verbSpecs: [String: VerbSpec] = [
        "open": VerbSpec(
            valueFlags: ["--cwd", "-e", "--agent"],
            boolFlags: [],
            usage: "usage: kooky-cli open [--cwd <dir>] [-e <command> | --agent <template-id>]"
        ),
        "resume": VerbSpec(
            valueFlags: ["--agent", "--id", "--cwd"],
            boolFlags: [],
            usage: "usage: kooky-cli resume --agent <agent-id> --id <conversation-id> [--cwd <dir>]"
        ),
        "list": VerbSpec(
            valueFlags: [],
            boolFlags: ["--json"],
            usage: "usage: kooky-cli list [--json]"
        ),
        "focus": VerbSpec(
            valueFlags: ["--tab"],
            boolFlags: [],
            usage: "usage: kooky-cli focus --tab <session-uuid>"
        ),
        "close": VerbSpec(
            valueFlags: ["--tab"],
            boolFlags: [],
            usage: "usage: kooky-cli close --tab <session-uuid>"
        ),
        "status": VerbSpec(
            valueFlags: [],
            boolFlags: ["--json"],
            usage: "usage: kooky-cli status [--json]"
        ),
    ]

    private static func unknownVerbFailure(_ verb: String) -> KookyCLIParseFailure {
        KookyCLIParseFailure(
            "unknown command '\(verb)' — one of: open, resume, list, focus, close, status. Run `kooky-cli --help`."
        )
    }

    /// Parses `kooky-cli` arguments (argv minus the binary name).
    public static func parseCLICommand(_ args: [String]) -> Result<KookyCLICommand, KookyCLIParseFailure> {
        // Help is a VERB-position word or a bare flag token — never scanned
        // out of flag values, or `open -e "--help"` would print help instead
        // of running the caller's command (value flags promise to take the
        // next token verbatim).
        guard let verb = args.first else { return .success(.help) }
        if verb == "help" || verb == "--help" || verb == "-h" { return .success(.help) }
        guard let spec = verbSpecs[verb] else {
            return .failure(unknownVerbFailure(verb))
        }

        var values: [String: String] = [:]
        var bools: Set<String> = []
        var i = 1
        while i < args.count {
            let arg = args[i]
            if spec.boolFlags.contains(arg) {
                bools.insert(arg)
                i += 1
                continue
            }
            if spec.valueFlags.contains(arg) {
                guard i + 1 < args.count else {
                    return .failure(KookyCLIParseFailure("\(arg) expects a value. \(spec.usage)"))
                }
                guard values[arg] == nil else {
                    return .failure(KookyCLIParseFailure("duplicate \(arg). \(spec.usage)"))
                }
                // A blank value counts as "flag not passed", for EVERY value
                // flag rather than just `--cwd`. Scripts write
                // `--cwd "$MAYBE_DIR"`, and an unset variable must not turn
                // into "wherever the CLI happens to be running" once
                // `normalizeCLIPath` absolutizes it against the process cwd —
                // by then it is a perfectly valid path and every downstream
                // "is it empty" check is already too late.
                //
                // The value is stored VERBATIM, never trimmed: `-e " cmd"`
                // uses a leading space deliberately (zsh's HIST_IGNORE_SPACE
                // keeps such a command out of history).
                let raw = args[i + 1]
                if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    values[arg] = raw
                }
                i += 2
                continue
            }
            if arg == "--help" || arg == "-h" {
                return .success(.help)
            }
            return .failure(KookyCLIParseFailure("unknown argument '\(arg)'. \(spec.usage)"))
        }

        func require(_ flag: String) -> Result<String, KookyCLIParseFailure> {
            guard let value = values[flag], !value.isEmpty else {
                return .failure(KookyCLIParseFailure("\(flag) is required. \(spec.usage)"))
            }
            return .success(value)
        }
        func requireTab() -> Result<String, KookyCLIParseFailure> {
            require("--tab").flatMap { raw in
                guard let uuid = UUID(uuidString: raw) else {
                    return .failure(KookyCLIParseFailure(
                        "--tab expects a session UUID — copy one from `kooky-cli list`."
                    ))
                }
                return .success(uuid.uuidString)
            }
        }

        switch verb {
        case "open":
            let command = values["-e"]
            let agent = values["--agent"]
            if command != nil, agent != nil {
                return .failure(KookyCLIParseFailure("-e and --agent are mutually exclusive. \(spec.usage)"))
            }
            // `--cwd` is optional everywhere: a Terminal preset brings its
            // own directory, and with no directory named at all the tab
            // opens wherever the active workspace already is. Bare
            // `kooky-cli open` is therefore "give me a new tab".
            return .success(.open(cwd: values["--cwd"], command: command, agent: agent))
        case "resume":
            return require("--agent").flatMap { agent in
                require("--id").map { id in
                    .resume(agent: agent, id: id, cwd: values["--cwd"])
                }
            }
        case "list":
            return .success(.list(json: bools.contains("--json")))
        case "focus":
            return requireTab().map { .focus(tab: $0) }
        case "close":
            return requireTab().map { .close(tab: $0) }
        case "status":
            return .success(.status(json: bools.contains("--json")))
        default:
            // Unreachable while the switch covers every verbSpecs key; kept
            // identical to the entry guard so a future verb added to the
            // table but not here still fails with the full message.
            return .failure(unknownVerbFailure(verb))
        }
    }

    /// The wire request for a parsed command; nil for `help` (local-only).
    /// Path normalization is the caller's job — this maps fields verbatim.
    public static func cliRequest(for command: KookyCLICommand) -> KookyCLIRequest? {
        switch command {
        case .open(let cwd, let cmd, let agent):
            return KookyCLIRequest(verb: .open, cwd: cwd, command: cmd, agent: agent)
        case .resume(let agent, let id, let cwd):
            return KookyCLIRequest(verb: .resume, cwd: cwd, agent: agent, conversationId: id)
        case .list:
            return KookyCLIRequest(verb: .list)
        case .focus(let tab):
            return KookyCLIRequest(verb: .focus, tab: tab)
        case .close(let tab):
            return KookyCLIRequest(verb: .close, tab: tab)
        case .status:
            return KookyCLIRequest(verb: .status)
        case .help:
            return nil
        }
    }

    /// Tilde-expands, absolutizes against `base` (the CLI process cwd), and
    /// standardizes. The server still validates existence + absoluteness —
    /// this only saves callers from spelling out `$PWD`.
    public static func normalizeCLIPath(_ path: String, relativeTo base: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (base as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    // MARK: - Rendering

    public static func renderCLIHelp() -> String {
        """
        kooky-cli — control a running kooky from scripts and other apps

        usage: kooky-cli <command> [options]

          open [--cwd <dir>] [-e <command> | --agent <template-id>]
                                  open a new tab at <dir>; -e runs a shell
                                  command there, --agent starts an agent
                                  (built-in, Settings → Agents custom, or a
                                  Terminal preset). Without --cwd the tab
                                  opens where the active workspace already
                                  is — a Terminal preset uses its own path
          resume --agent <agent-id> --id <conversation-id> [--cwd <dir>]
                                  reopen an agent conversation (same
                                  semantics as kooky://resume deep links)
          list [--json]           windows → workspaces → tabs, with ids
          focus --tab <uuid>      bring a tab to the front
          close --tab <uuid>      close a tab (in-app confirmation rules apply)
          status [--json]         app version + protocol; exits 1 when
                                  kooky isn't running

        Exit code 0 means the request was accepted; anything else prints one
        reason line on stderr. Every command except `status` launches kooky
        first if it isn't running.
        """
    }

    public static func renderCLIList(_ windows: [KookyCLIWindowInfo]) -> String {
        guard !windows.isEmpty else { return "no windows" }
        var lines: [String] = []
        for window in windows {
            lines.append("window \(window.index)\(window.isKey ? " (key)" : "")")
            for workspace in window.workspaces {
                let path = abbreviatePath(workspace.path)
                lines.append("  workspace \"\(plain(workspace.title))\"\(workspace.isActive ? " (active)" : "") — \(path)")
                for tab in workspace.tabs {
                    let marker = tab.isActive ? "*" : " "
                    let state = tab.agentState.map { " (\(plain($0)))" } ?? ""
                    lines.append("  \(marker) \(tab.id)  \(plain(tab.agent))\(state)  \"\(plain(tab.title))\" — \(abbreviatePath(tab.cwd))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Flattens one value into something safe to print on the caller's
    /// terminal. Tab titles come from OSC 0/2 — i.e. whatever program is
    /// running, including one on the far side of an ssh — and a directory
    /// name may legally contain a newline (`mkdir $'a\nb'`), so an
    /// un-sanitized value can forge whole `list` rows (pointing a script at
    /// the wrong tab id) or inject ANSI/OSC sequences into the terminal that
    /// reads the output. Control characters become spaces rather than being
    /// dropped, so a forged row still reads as one row of one entry.
    /// `--json` needs none of this — JSONEncoder escapes them.
    ///
    /// This is the CLI-output twin of KookyKit's `singleLine(_:)` rule
    /// (M5.aaaaa): any value interpolated into a multi-line composed string
    /// must be flattened first. It additionally strips non-newline control
    /// characters, which only matter when the sink is a terminal.
    ///
    /// EVERY dynamic value the CLI prints goes through this — list rows,
    /// error lines, notes, the app's reported version. Not just the ones
    /// that obviously come from a terminal title: a refusal message quotes
    /// the caller's own `--agent` value back at them, and that string came
    /// from whatever tool invoked kooky-cli.
    public static func plain(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            let isC0OrDelete = scalar.value < 0x20 || scalar.value == 0x7F
            // C1 (0x80–0x9F) is a second escape space some terminals honor,
            // and U+2028/2029 are Unicode's own line breaks.
            let isC1 = (0x80...0x9F).contains(scalar.value)
            let isUnicodeBreak = scalar.value == 0x2028 || scalar.value == 0x2029
            return isC0OrDelete || isC1 || isUnicodeBreak ? " " : scalar
        }))
    }

    public static func renderCLIListJSON(_ windows: [KookyCLIWindowInfo]) -> String {
        struct Payload: Encodable {
            let windows: [KookyCLIWindowInfo]
        }
        return encodeJSON(Payload(windows: windows))
    }

    public static func renderCLIStatusJSON(running: Bool, appVersion: String?, serverProtocol: Int?) -> String {
        struct Payload: Encodable {
            let running: Bool
            let appVersion: String?
            let protocolVersion: Int?
            let cliProtocolVersion: Int
        }
        return encodeJSON(Payload(
            running: running,
            appVersion: appVersion,
            protocolVersion: serverProtocol,
            cliProtocolVersion: KookyCLIProtocol.version
        ))
    }

    private static func encodeJSON(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Abbreviate first, THEN sanitize — flattening a newline inside the
    /// path ahead of the tilde match would stop `$HOME` from matching.
    private static func abbreviatePath(_ path: String) -> String {
        plain((path as NSString).abbreviatingWithTildeInPath)
    }
}

// MARK: - Transport

/// One-shot request/response over the hook socket. Unlike `sendPayload`
/// (fire-and-forget, blocking), this runs the whole exchange non-blocking
/// under a single deadline so a stuck or older app (which never answers)
/// surfaces as a typed failure instead of a hung CLI process.
public enum KookyCLITransport {
    public enum Failure: Error, Equatable, Sendable {
        /// No listener on the socket path (app not running / socket gone).
        case connectFailed
        case writeFailed
        /// Connected but no full reply line arrived before the deadline —
        /// commonly a kooky build too old to speak the CLI protocol.
        case timedOut
        /// The server closed without answering — same "older app" signature.
        case closedWithoutReply
        case replyTooLarge
    }

    public static func roundTrip(
        line: Data,
        socketPath: String,
        timeout: TimeInterval
    ) -> Result<Data, Failure> {
        let deadline = DispatchTime.now() + timeout
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.connectFailed) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // A kooky too old to speak this protocol reads once and closes, so a
        // request that spans several writes (a long `open -e`) can hit a
        // gone peer mid-write. Without this that raises SIGPIPE and the CLI
        // dies by signal — no exit code we chose, no message. With it the
        // write returns EPIPE and the caller gets the "older kooky" line.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        guard let rc = KookyHookKit.withUnixSocketAddress(path: socketPath, { addr, len in
            connect(fd, addr, len)
        }) else {
            return .failure(.connectFailed)
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return .failure(.connectFailed) }
            guard poll(fd, events: Int16(POLLOUT), deadline: deadline) else { return .failure(.connectFailed) }
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
            guard soError == 0 else { return .failure(.connectFailed) }
        }

        var offset = 0
        let bytes = [UInt8](line)
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + offset, bytes.count - offset)
            }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard poll(fd, events: Int16(POLLOUT), deadline: deadline) else { return .failure(.timedOut) }
                continue
            }
            // The peer hung up mid-request — same "server won't answer"
            // situation the read loop reports, so share its message
            // (the older-kooky hint) instead of the generic send failure.
            if n < 0, errno == EPIPE || errno == ECONNRESET {
                return .failure(.closedWithoutReply)
            }
            return .failure(.writeFailed)
        }

        var reply = Data()
        var sawNewline = false
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !sawNewline {
            guard reply.count < KookyCLIProtocol.maxResponseLineBytes else { return .failure(.replyTooLarge) }
            guard poll(fd, events: Int16(POLLIN), deadline: deadline) else { return .failure(.timedOut) }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                if buffer[0..<n].contains(0x0A) { sawNewline = true }
                reply.append(contentsOf: buffer[0..<n])
                continue
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            // EOF (or hard error) before a full line: the server hung up
            // without answering.
            return .failure(.closedWithoutReply)
        }
        if let newline = reply.firstIndex(of: 0x0A) {
            reply = reply.prefix(upTo: newline)
        }
        return .success(reply)
    }

    private static func poll(_ fd: Int32, events: Int16, deadline: DispatchTime) -> Bool {
        while true {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            guard deadline.uptimeNanoseconds > nowNs else { return false }
            let remainingMs = Int32(min((deadline.uptimeNanoseconds - nowNs) / 1_000_000, 60_000))
            var pollFd = pollfd(fd: fd, events: events, revents: 0)
            let rc = Darwin.poll(&pollFd, 1, max(remainingMs, 1))
            if rc > 0 { return true }
            if rc == 0 { continue }
            if errno == EINTR { continue }
            return false
        }
    }
}
