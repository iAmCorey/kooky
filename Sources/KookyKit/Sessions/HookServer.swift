import Darwin
import Foundation
import KookyHookKit

/// Listens on a per-user unix socket for one-shot JSON event lines from
/// hooks (sent by the `KookyHook` CLI): agent lifecycle events and prompt-time
/// shell env snapshots. Wire format is one JSON object per line.
///
/// The hooks themselves run as short-lived child processes of the agent (e.g.
/// Claude Code spawns them per Stop / UserPromptSubmit / Notification). They
/// connect, write one line, close — we accept and read in a single pass.
///
/// The same socket also carries the `kooky-cli` control channel: a line whose
/// `kind` is `"cli"` is a request that gets exactly one JSON response line
/// written back before the connection closes (see `onCLIRequest`). Hook
/// events stay fire-and-forget — the two shapes coexist per connection kind,
/// discriminated by that field, so KookyHook's existing one-way path is
/// untouched.
/// Lifecycle signal an agent's hook fired. Wire format is the raw String
/// case names; the enum lets `WorkspaceStore` switch exhaustively.
enum HookEvent: String {
    case running, attention, idle, ended

    var activityState: SessionActivityState {
        switch self {
        case .running: return .running
        case .attention: return .attention
        case .idle, .ended: return .idle
        }
    }
}

/// PreToolUse / PostToolUse phase carried on `HookMessage.toolCall`. Pre
/// fires before Claude runs the tool; Post fires after — duration / orphan
/// timing are computed `WorkspaceStore`-side from the gap between matched
/// events (KookyHook is fork-per-event and can't keep state).
enum HookToolEvent: String {
    case pre, post
}

enum HookMessage {
    case agent(agent: AgentTemplate, event: HookEvent, sessionId: UUID)
    case shellEnvironment(env: [String: String], sessionId: UUID)
    /// Claude's hook input JSON carries `session_id` (its conversation id).
    /// `KookyHook` extracts it and emits this message so kooky can persist
    /// it on the originating Session and reuse it as `--resume <id>` on
    /// next launch. The agent slug is implicit in the routing (only Claude
    /// pipes session_id today) and the consumer doesn't dispatch per-agent
    /// — so the payload only carries surface + id.
    case conversationId(conversationId: String, sessionId: UUID)
    /// PreToolUse / PostToolUse event for the activity strip. `agent` is
    /// the base AgentTemplate the slug resolves to (Claude builtin today —
    /// custom Claude-based agents share its slug since `from(hookSlug:)`
    /// matches by `initialCommand`). `success` is non-nil only for
    /// `.post` events. `toolUseId` is Claude's per-call stable id when
    /// present (used by `Session.recordToolCallEnd` to match Pre/Post
    /// pairs even when two concurrent calls share `toolName` + truncated
    /// identifier).
    case toolCall(
        agent: AgentTemplate,
        toolName: String,
        identifier: String,
        event: HookToolEvent,
        success: Bool?,
        toolUseId: String?,
        sessionId: UUID
    )
}

@MainActor
final class HookServer {
    typealias Handler = (_ message: HookMessage) -> Void
    /// CLI request handler. Must call the completion EXACTLY once — the
    /// server hands it ownership of the client fd, and the completion is
    /// the only thing that writes the response and closes it. A leaked
    /// completion leaks the fd and leaves the CLI waiting out its timeout.
    /// `isCallerWaiting` answers "is anyone still going to receive this?".
    /// An async verb MUST ask it again immediately before it commits to a
    /// side effect: the pre-dispatch check covers the time a request spent
    /// queued, but `open` and `resume` then go scan the filesystem, and a
    /// caller that gives up (^C, or its own timeout) during that scan would
    /// otherwise still get a tab spawned and its `-e` command executed.
    typealias CLIHandler = @MainActor (
        _ request: KookyCLIRequest,
        _ isCallerWaiting: @escaping @MainActor () -> Bool,
        _ completion: @escaping @MainActor (KookyCLIResponse) -> Void
    ) -> Void

    private let handler: Handler
    private let path: String
    private var listenFd: Int32 = -1
    private var source: DispatchSourceRead?

    /// Set before `start()`. Nil (never wired) answers CLI requests with a
    /// refusal rather than silence, so a misassembled build still fails loud.
    var onCLIRequest: CLIHandler?

    /// `socketPath` is injectable so integration tests can bind a throwaway
    /// path instead of racing a live kooky's production socket.
    init(socketPath: String = HookServer.socketPath, handler: @escaping Handler) {
        self.path = socketPath
        self.handler = handler
    }

    /// Path agents and the CLI both target. `KookyHookKit.socketPath` is the
    /// single source (the clients compile the same constant); this wrapper
    /// only adds the server-side concern of creating the parent directory.
    static let socketPath: String = {
        let path = KookyHookKit.socketPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        return path
    }()

    func start() {
        Self.handleSIGPIPEOnce()
        let path = self.path
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("kooky: HookServer socket() failed")
            return
        }

        guard let bound = KookyHookKit.withUnixSocketAddress(path: path, { addr, len in
            bind(fd, addr, len)
        }) else {
            close(fd)
            NSLog("kooky: HookServer socket path too long")
            return
        }
        guard bound == 0 else {
            NSLog("kooky: HookServer bind() failed errno=\(errno)")
            close(fd)
            return
        }
        // Owner-only: the socket is a local control surface (the CLI can
        // open tabs and run commands through it), so don't leave it at the
        // umask default 0755 even though the parent dir is already 0700.
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            NSLog("kooky: HookServer listen() failed errno=\(errno)")
            close(fd)
            return
        }

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    /// Writing a response to a client that already hung up — its 15s
    /// timeout expired during a slow async verb, or the user ^C'd it —
    /// raises SIGPIPE, and the default disposition is to KILL the process.
    /// Measured: signal termination, so every terminal and every running
    /// agent goes with it, and neither a crash report nor CrashForensics'
    /// atexit trace is produced (atexit does not run for a signal death) —
    /// i.e. the "kooky just vanished, no evidence" shape. The one-way hook
    /// path never wrote back, so this arrived with the request/response
    /// branch.
    ///
    /// This is process-level on purpose: the per-fd SO_NOSIGPIPE option is
    /// rejected with EINVAL once the peer has closed, and a peer that has
    /// already closed IS the hazard.
    ///
    /// It installs an empty HANDLER rather than `SIG_IGN`, and that
    /// distinction is the whole reason this comment is long. Across `exec`,
    /// POSIX keeps *ignored* signals ignored but resets *caught* ones to
    /// their default — and libghostty starts every shell with a plain
    /// fork/exec (`Command.zig`) that touches no signal state. So `SIG_IGN`
    /// would ride into every shell and agent kooky runs, where it silently
    /// changes pipeline semantics: measured, `yes | head -n 1` stops being
    /// killed by SIGPIPE and instead prints "yes: stdout: Broken pipe" and
    /// exits 1 — a visible regression in the terminal kooky exists to be.
    /// An empty handler protects this process exactly as well (the write
    /// returns EPIPE instead of dying) while children come up clean.
    ///
    /// Installed here rather than in the app's `main.swift` so the tests,
    /// which link KookyKit and never run the executable's entry point,
    /// exercise the same protection the app gets.
    private static let sigpipeHandled: Bool = {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGPIPE, &action, nil)
        return true
    }()

    private static func handleSIGPIPEOnce() { _ = sigpipeHandled }

    func stop() {
        source?.cancel()
        source = nil
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptOne() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }
        var ownsFd = true
        defer { if ownsFd { close(clientFd) } }

        // We run on the main queue, so a client that connects and then
        // stalls must not hang the UI. SO_RCVTIMEO/SNDTIMEO bound one
        // syscall; the wall-clock deadlines on the loops below bound the
        // whole exchange — without them a byte-dripping client would reset
        // the 1s each iteration. Real clients (KookyHook, kooky-cli) write
        // immediately and read immediately.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // NB: SIGPIPE protection for the response write is process-level,
        // installed in `start()`. Do NOT "improve" this by setting
        // SO_NOSIGPIPE on `clientFd` here — measured on Darwin, setsockopt
        // returns EINVAL for a socket whose peer has ALREADY closed, which
        // is precisely the case the protection exists for (the client
        // timed out or was ^C'd before our main queue got to accept it).
        // A per-fd option would silently fail to apply in exactly the
        // scenario that kills the app.

        // Read to the line boundary. Hook payloads arrive whole in one read
        // (< 200 B, newline-terminated — same single pass as before); the
        // loop only continues for a line that straddles the 4 KiB buffer,
        // e.g. a CLI `open -e` with a long command.
        let deadline = ContinuousClock.now + .seconds(2)
        var data = Data()
        var sawNewline = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < KookyCLIProtocol.maxRequestLineBytes, ContinuousClock.now < deadline {
            let n = buffer.withUnsafeMutableBufferPointer { read(clientFd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            let chunkHasNewline = buffer[0..<n].contains(0x0A)
            data.append(contentsOf: buffer[0..<n])
            if chunkHasNewline {
                sawNewline = true
                break
            }
        }
        guard !data.isEmpty else {
            // No bytes within SO_RCVTIMEO. For a hook sender this is a
            // dropped event — its write raced the timeout, it exited 0 and
            // won't retry — so leave a trace instead of failing silently.
            NSLog("kooky: HookServer connection produced no data; dropped")
            return
        }

        // An overlong line can't be decoded (it's truncated), but a CLI
        // caller still gets one readable response — silence here would
        // surface as the misleading "kooky didn't answer, update it".
        // Hook senders never read, so answering them is harmless.
        if !sawNewline, data.count >= KookyCLIProtocol.maxRequestLineBytes {
            ownsFd = false
            Self.writeCLIResponseAndClose(
                .failure("request line too long (limit \(KookyCLIProtocol.maxRequestLineBytes) bytes)"),
                fd: clientFd
            )
            return
        }

        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if dict["kind"] as? String == KookyCLIProtocol.kind {
            // Request/response branch: fd ownership moves to the response
            // writer; the handler's completion is what closes it.
            ownsFd = false
            answerCLIRequest(dict: dict, data: data, fd: clientFd)
            return
        }

        guard let message = Self.parseMessage(dict) else { return }
        handler(message)
    }

    /// Answers one CLI request line and closes the fd on every path.
    private func answerCLIRequest(dict: [String: Any], data: Data, fd: Int32) {
        // Version peek BEFORE the typed decode: a future breaking protocol
        // change is exactly what would fail the decode, and "malformed"
        // must never shadow the real message.
        if let requested = dict["protocolVersion"] as? Int, requested > KookyCLIProtocol.version {
            Self.writeCLIResponseAndClose(
                .failure(KookyCLIProtocol.tooNewRequestMessage(requested: requested)),
                fd: fd
            )
            return
        }
        guard let request = KookyCLIRequest.decode(from: data) else {
            Self.writeCLIResponseAndClose(.failure("malformed CLI request"), fd: fd)
            return
        }
        guard let onCLIRequest else {
            Self.writeCLIResponseAndClose(.failure("kooky's CLI handler is not ready"), fd: fd)
            return
        }
        // A CLI request is a REQUEST, not a fire-and-forget event: if the
        // caller is already gone there is nobody to receive the answer, and
        // performing it anyway means `open -e` runs a command whose invoker
        // was told it failed — and may have retried, so it runs twice.
        //
        // This has to live HERE rather than in the controller: the request
        // can sit in the listen queue for as long as the main thread is
        // blocked, and `RequestDeadline` only starts counting once the
        // controller finally sees it. Asking the kernel whether the peer
        // hung up covers the whole span before that point.
        guard !Self.peerHasHungUp(fd) else {
            NSLog("kooky: CLI client hung up before dispatch; request dropped")
            close(fd)
            return
        }
        // Single-shot latch: a handler bug that completes twice would
        // otherwise double-close the fd — and the second close can hit a
        // RECYCLED descriptor (a pty, a kqueue watcher), which surfaces as
        // unrelated sessions dying. The leak half of the contract (never
        // completing) stays a convention, probed by the integration tests'
        // await-based exchanges.
        var completed = false
        // Shares `completed` with the completion below: once answered, the
        // fd is closed and peeking at it would read a recycled descriptor.
        let isCallerWaiting: @MainActor () -> Bool = {
            !completed && !Self.peerHasHungUp(fd)
        }
        onCLIRequest(request, isCallerWaiting) { response in
            guard !completed else {
                NSLog("kooky: CLI handler completed twice; extra response dropped")
                return
            }
            completed = true
            Self.writeCLIResponseAndClose(response, fd: fd)
        }
    }

    /// Whether the client has closed its end. The request line is already
    /// consumed at this point, so a zero-length peek means EOF — the peer
    /// closed — while `EAGAIN` means the connection is simply idle, which is
    /// what a healthy client waiting for its answer looks like.
    private static func peerHasHungUp(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, Int32(MSG_PEEK) | Int32(MSG_DONTWAIT)) == 0
    }

    private static func writeCLIResponseAndClose(_ response: KookyCLIResponse, fd: Int32) {
        defer { close(fd) }
        guard let line = response.encodedLine() else { return }
        let deadline = ContinuousClock.now + .seconds(3)
        let bytes = [UInt8](line)
        var offset = 0
        while offset < bytes.count, ContinuousClock.now < deadline {
            let n = bytes.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + offset, bytes.count - offset)
            }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0, errno == EINTR { continue }
            // Client gone or stalled past SO_SNDTIMEO — its own read
            // timeout is the fallback.
            return
        }
    }

    private static let envKeys = [
        "VIRTUAL_ENV", "CONDA_DEFAULT_ENV",
        "NVM_BIN", "NVM_DIR", "KOOKY_NODE_VERSION",
        "https_proxy", "http_proxy", "all_proxy",
    ]

    static func parseMessage(_ data: Data) -> HookMessage? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseMessage(dict)
    }

    static func parseMessage(_ dict: [String: Any]) -> HookMessage? {
        guard
            let surface = dict["surface"] as? String,
            let id = UUID(uuidString: surface)
        else { return nil }

        if dict["kind"] as? String == "env" {
            let env = Dictionary(uniqueKeysWithValues: envKeys.map { key in
                (key, dict[key] as? String ?? "")
            })
            return .shellEnvironment(env: env, sessionId: id)
        }

        if dict["kind"] as? String == "conversationId",
           let conversationId = dict["conversationId"] as? String,
           !conversationId.isEmpty {
            return .conversationId(conversationId: conversationId, sessionId: id)
        }

        if dict["kind"] as? String == "tool" {
            guard
                let agentSlug = dict["agent"] as? String,
                let agent = AgentTemplate.from(hookSlug: agentSlug),
                let toolName = dict["tool_name"] as? String, !toolName.isEmpty,
                let identifier = dict["identifier"] as? String,
                let eventRaw = dict["event"] as? String,
                let event = HookToolEvent(rawValue: eventRaw)
            else { return nil }

            // success ships as a literal "true" / "false" string on .post;
            // .pre omits it. Strict equality with "true" — any other value
            // ("TRUE", "1", "yes", "") coerces to false. KookyHookKit owns
            // the wire shape and ships exactly "true" / "false", so the
            // strict check is a wire-protocol contract not a parse heuristic.
            // Missing field on .post leaves success nil — the consumer
            // (WorkspaceStore.applyToolCallEvent) treats nil as success
            // (rather than guess-fail an unparseable response).
            var success: Bool? = nil
            if event == .post, let s = dict["success"] as? String {
                success = (s == "true")
            }

            // tool_use_id ships only when Claude includes it (recent CLI);
            // nil-tolerant on the consumer side so old payloads still work.
            let toolUseId = (dict["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            return .toolCall(
                agent: agent,
                toolName: toolName,
                identifier: identifier,
                event: event,
                success: success,
                toolUseId: toolUseId,
                sessionId: id
            )
        }

        guard
            let agentSlug = dict["agent"] as? String,
            let eventName = dict["event"] as? String,
            let agent = AgentTemplate.from(hookSlug: agentSlug),
            let event = HookEvent(rawValue: eventName)
        else { return nil }
        return .agent(agent: agent, event: event, sessionId: id)
    }
}
