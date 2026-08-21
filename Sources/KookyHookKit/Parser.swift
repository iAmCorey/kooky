import Darwin
import Foundation

/// Pure helpers for `KookyHook` CLI: builds the JSON payloads it ships to
/// `HookServer` and writes them across the unix socket the running app owns.
/// Lives in its own library target so unit tests can verify parsing logic
/// (malformed JSON, missing fields, wrong types, future PreToolUse /
/// PostToolUse payloads) without spawning a subprocess. Stays off
/// `KookyKit` on purpose — the CLI binary must remain dependency-free.
public enum KookyHookKit {
    public static var socketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("kooky/socket").path
    }

    /// One-shot socket write. Returns true on success. `HookServer` accepts
    /// one payload per connection so each call opens / writes / closes.
    public static func sendPayload(_ object: [String: String], to path: String) -> Bool {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return false }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let connected = withUnixSocketAddress(path: path) { addr, len in
            connect(fd, addr, len)
        }
        guard connected == 0 else { return false }

        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written >= 0
    }

    /// Builds the `sockaddr_un` for a unix socket path and hands it to
    /// `body` (a `connect` or `bind` call). Nil when the path doesn't fit
    /// `sun_path` (the `<` bound keeps the implicit NUL terminator). The
    /// single home for this fiddly construction — the hook sender, the CLI
    /// transport, and HookServer's bind all route through it, so the length
    /// guard can't drift between the three.
    public static func withUnixSocketAddress<R>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, len)
            }
        }
    }

    /// Env-snapshot payload from positional args. Order follows the
    /// `kooky-hook env ...` calling convention in `ShellIntegration.swift`'s
    /// precmd hook: VIRTUAL_ENV, CONDA_DEFAULT_ENV, NVM_BIN, NVM_DIR,
    /// KOOKY_NODE_VERSION, https_proxy, http_proxy, all_proxy.
    public static func buildEnvPayload(surface: String, args: [String]) -> [String: String] {
        func arg(_ index: Int) -> String { args.indices.contains(index) ? args[index] : "" }
        return [
            "kind": "env",
            "surface": surface,
            "VIRTUAL_ENV": arg(0),
            "CONDA_DEFAULT_ENV": arg(1),
            "NVM_BIN": arg(2),
            "NVM_DIR": arg(3),
            "KOOKY_NODE_VERSION": arg(4),
            "https_proxy": arg(5),
            "http_proxy": arg(6),
            "all_proxy": arg(7),
        ]
    }

    /// Lifecycle payload (running / attention / idle / ended).
    public static func buildLifecyclePayload(agent: String, event: String, surface: String) -> [String: String] {
        [
            "agent": agent,
            "event": event,
            "surface": surface,
        ]
    }

    /// Marker appended only to commands launched by a real agent hook. Shell
    /// wrapper lifecycle pings intentionally omit it: they inherit the
    /// terminal's stdin, and draining a redirected stdin there could steal
    /// the user's prompt before the agent reads it.
    public static let hookStdinMarker = "--hook-stdin"

    /// Pulls an exact conversation id out of an agent hook's stdin JSON.
    /// Hook ecosystems disagree on casing, so the key mapping is explicit
    /// per binary slug instead of accepting any vaguely id-shaped field (a
    /// tool/subagent id must never become the tab's resume target).
    public static func parseConversationId(from data: Data, agent: String) -> String? {
        let keys: [String]
        switch agent {
        case "claude", "gemini", "kimi", "kiro-cli", "droid":
            keys = ["session_id"]
        case "copilot", "reasonix":
            keys = ["sessionId", "session_id"]
        case "cursor-agent":
            keys = ["conversation_id", "conversationId"]
        case "agy":
            keys = ["conversationId"]
        default:
            return nil
        }
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in keys {
            guard let raw = parsed[key] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        return nil
    }

    /// Backward-compatible spelling kept for focused Claude parser tests and
    /// callers outside the executable target.
    public static func parseClaudeConversationId(from data: Data) -> String? {
        parseConversationId(from: data, agent: "claude")
    }

    /// Wrapper-scoped marker for a Claude invocation whose session cannot be
    /// resumed. The wrapper exports it only to that Claude process tree, so a
    /// later normal `claude` run in the same terminal is unaffected.
    public static let claudeNoSessionPersistenceKey = "KOOKY_CLAUDE_NO_SESSION_PERSISTENCE"

    /// Whether the CLI should mirror this hook payload's conversation id.
    /// Tool payloads are deliberately skipped because lifecycle hooks already
    /// carry the same id and tool-heavy turns would otherwise multiply IPC.
    /// Claude's ephemeral process marker remains its one agent-specific veto.
    public static func shouldMirrorConversationId(
        agent: String,
        payload: [String: String],
        environment: [String: String]
    ) -> Bool {
        guard payload["agent"] == agent, payload["kind"] != "tool" else { return false }
        if agent == "claude",
           environment[claudeNoSessionPersistenceKey] == "1" {
            return false
        }
        switch agent {
        case "claude", "gemini", "copilot", "cursor-agent", "kimi", "kiro-cli", "droid", "agy", "reasonix":
            return true
        default:
            return false
        }
    }

    public static func shouldMirrorClaudeConversationId(
        payload: [String: String],
        environment: [String: String]
    ) -> Bool {
        shouldMirrorConversationId(agent: "claude", payload: payload, environment: environment)
    }

    /// ConversationId payload routed to `HookServer` so `WorkspaceStore`
    /// can persist it on `Session` and prepend `--resume <id>` to
    /// `KOOKY_AGENT` on next launch.
    public static func buildConversationIdPayload(surface: String, conversationId: String) -> [String: String] {
        [
            "kind": "conversationId",
            "surface": surface,
            "conversationId": conversationId,
        ]
    }

    /// Maximum bytes / characters carried by the cross-boundary `identifier`
    /// field. Per `/plan-eng-review` D2 — KookyHook truncates at source so
    /// large `tool_input` payloads (Edit / Write file content) never reach
    /// the 4 KiB HookServer buffer. Counted in `Character`s, not UTF-8
    /// bytes — CJK identifiers stay readable instead of mid-codepoint cut.
    public static let identifierMaxLength = 80

    /// Parse a Claude Code PreToolUse / PostToolUse / PostToolUseFailure
    /// stdin JSON into a minimal tool-event payload routed to `HookServer`.
    /// Returns nil for any non-tool event (`SessionStart`,
    /// `UserPromptSubmit`, etc.) or malformed input — caller doesn't have
    /// to pre-filter.
    ///
    /// Payload shape:
    /// ```
    /// {
    ///   "kind": "tool",
    ///   "surface": <UUID>,
    ///   "agent":   <claude | claude-base custom agent slug>,
    ///   "tool_name": <Bash | Edit | Read | ...>,
    ///   "identifier": <truncated file path / command / url>,
    ///   "event":     <"pre" | "post">,
    ///   "success":   <"true" | "false">   (only on event=="post")
    ///   "tool_use_id": <Claude's per-call id>  (when present)
    /// }
    /// ```
    ///
    /// `identifier` is extracted from `tool_input` per tool kind, control
    /// characters collapsed to spaces, then truncated to 80 chars. Bulk
    /// data (full file content, Bash output) never crosses this boundary.
    ///
    /// `PostToolUseFailure` is recognised as a Post variant whose `success`
    /// is forced to `false` without inspecting `tool_response` — Claude
    /// fires this distinct event only when the tool itself errored, so
    /// the heuristic-free signal beats the `tool_response` text scan.
    public static func parseToolEventPayload(
        from data: Data,
        surface: String,
        agent: String
    ) -> [String: String]? {
        let keys = ToolPayloadKeys.forAgent(agent)
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = parsed[keys.event] as? String,
              let toolName = parsed[keys.name] as? String,
              !toolName.isEmpty
        else { return nil }

        let event: String
        let postSuccessOverride: Bool?  // nil → heuristic, true/false → forced
        switch hookEventName {
        case "PreToolUse":         event = "pre";  postSuccessOverride = nil
        case "PostToolUse":        event = "post"; postSuccessOverride = nil
        case "PostToolUseFailure": event = "post"; postSuccessOverride = false
        default:                   return nil  // not a tool event we handle
        }

        let toolInput = parsed[keys.args] as? [String: Any] ?? [:]
        let rawIdentifier = extractIdentifier(toolName: toolName, toolInput: toolInput)

        // PostToolUseFailure forces success=false (Claude's own signal);
        // PostToolUse falls back to the heuristic over `tool_response`. Pre
        // carries no success.
        // A non-empty `failure` field is an explicit error signal and outranks
        // the `tool_response` text heuristic — Reasonix leaves `toolResult`
        // empty on a failed call and puts the message in `error`, which the
        // heuristic alone would read as a clean success.
        let explicitFailure = keys.failure
            .flatMap { parsed[$0] as? String }
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            == true
        let success: Bool? = event == "post"
            ? (postSuccessOverride ?? (explicitFailure ? false : detectSuccess(toolResponse: parsed[keys.result])))
            : nil

        return buildToolEventPayload(
            surface: surface,
            agent: agent,
            toolName: toolName,
            identifier: rawIdentifier,
            event: event,
            toolUseId: keys.callId.flatMap { parsed[$0] as? String },
            success: success
        )
    }

    /// Assemble the agent-agnostic `kind:"tool"` payload routed to
    /// `HookServer` → `WorkspaceStore.applyToolCallEvent` → the status-bar
    /// pill. Single source for the wire shape so it can't drift between the
    /// two producers: `parseToolEventPayload` (Claude — extracts these
    /// fields from hook stdin JSON) and KookyHook's `tool` argv branch (Pi —
    /// the extension hands the fields straight from `tool_execution_*`
    /// events). `identifier` is control-stripped + truncated here, the one
    /// place it happens; `toolUseId` is emitted only when non-empty (Pi's
    /// `toolCallId` and Claude's `tool_use_id` both land here so Pre/Post
    /// match by stable id); `success` only rides `event == "post"`.
    public static func buildToolEventPayload(
        surface: String,
        agent: String,
        toolName: String,
        identifier: String,
        event: String,
        toolUseId: String?,
        success: Bool?
    ) -> [String: String] {
        var payload: [String: String] = [
            "kind":       "tool",
            "surface":    surface,
            "agent":      agent,
            "tool_name":  toolName,
            "identifier": truncateForPayload(identifier),
            "event":      event,
        ]
        if let toolUseId, !toolUseId.isEmpty {
            payload["tool_use_id"] = toolUseId
        }
        if event == "post", let success {
            payload["success"] = success ? "true" : "false"
        }
        return payload
    }

    /// How one agent spells the fields of a tool-event hook payload.
    ///
    /// Agents that adopt Claude's hook CONTRACT (same event names, one JSON
    /// line on stdin) do not necessarily adopt its field names — Reasonix
    /// sends `event`/`toolName`/`toolArgs`/`toolResult`. Keying the spelling
    /// off the agent, rather than trying every name on every field, matches
    /// how `parseConversationId` already handles the same disagreement, and
    /// keeps a generic key like `event` from being live for agents that mean
    /// something else by it.
    ///
    /// `callId` is optional because it is the one field an agent can simply
    /// not have: Reasonix exposes no per-call id, so its Pre/Post pairs fall
    /// back to `Session.recordToolCallEnd`'s name+identifier match. Modelling
    /// it as an empty slot rather than an untried key is what makes that
    /// limitation visible here instead of surprising at the pill.
    ///
    /// `failure` is the inverse case — a field Claude has no equivalent for.
    /// Reasonix carries a failed tool's message in `error` while `toolResult`
    /// may be empty, so reading only the result would score every failure as
    /// a success.
    struct ToolPayloadKeys {
        let event: String
        let name: String
        let args: String
        let result: String
        let callId: String?
        let failure: String?

        static let claude = ToolPayloadKeys(
            event: "hook_event_name",
            name: "tool_name",
            args: "tool_input",
            result: "tool_response",
            callId: "tool_use_id",
            failure: nil
        )

        static let reasonix = ToolPayloadKeys(
            event: "event",
            name: "toolName",
            args: "toolArgs",
            result: "toolResult",
            callId: nil,
            failure: "error"
        )

        /// Claude is the default so every Claude-based custom agent — which
        /// ships hooks through `claudeHooksObject` under its own slug — keeps
        /// working without being enumerated.
        static func forAgent(_ agent: String) -> ToolPayloadKeys {
            switch agent {
            case "reasonix": return .reasonix
            default:         return .claude
            }
        }
    }

    /// Pick the most descriptive single string out of `tool_input` per
    /// tool kind — what pill UI shows as the "what" of the call. Unknown
    /// tools fall back to the first non-empty string value (alphabetised
    /// by key so the choice is deterministic across runs — Swift dict
    /// iteration order isn't stable). Empty if everything's empty.
    ///
    /// Matching is case-insensitive and file tools accept `path` as well as
    /// Claude's `file_path`, because agents that reuse Claude's hook contract
    /// do not reuse its tool vocabulary: Reasonix names them `bash` /
    /// `edit_file` with a `path` argument. Without both, every such call
    /// drops to the `default:` scan and Reasonix's `edit_file`
    /// (`{new_string, old_string, path}`) alphabetises to `new_string` — the
    /// pill would show the file's new CONTENT instead of its path. The same
    /// divergence is already handled for Pi at the two other consumers
    /// (`toolIcon` / `toolCounts` lowercase; the Pi extension ships its own
    /// JS identifier helper) — this parser is the one that never got it.
    static func extractIdentifier(toolName: String, toolInput: [String: Any]) -> String {
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = toolInput[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        switch toolName.lowercased() {
        case "bash":
            return string("command") ?? ""
        case "edit", "write", "read", "notebookedit", "multiedit", "edit_file", "write_file", "read_file":
            return string("file_path", "path") ?? ""
        case "glob":
            return string("pattern", "path") ?? ""
        case "grep", "search":
            return string("pattern") ?? ""
        case "webfetch", "websearch":
            return string("url", "query") ?? ""
        case "task":
            return string("description", "prompt") ?? ""
        default:
            // Unknown tool — pick the first non-empty String value, with
            // keys sorted alphabetically so the choice is deterministic
            // (Swift dictionary iteration order isn't stable across runs,
            // and the pill would otherwise show different identifiers for
            // the same payload between invocations). Common-case tools
            // above have explicit dispatch.
            for key in toolInput.keys.sorted() {
                if let str = toolInput[key] as? String, !str.isEmpty { return str }
            }
            return ""
        }
    }

    /// Collapse ALL C0 control bytes (0x00-0x1F) + DEL (0x7F) to single
    /// spaces, then truncate to `identifierMaxLength` characters. Strips
    /// the whole control range — not just `\n` `\r` `\t` — because pill
    /// UI is a single-line `Text` view and any embedded NUL / BEL / ESC /
    /// FS/GS/RS/US can perturb rendering, screen-reader output, or the
    /// Pre/Post match key used in `Session.recordToolCallEnd`. Truncates
    /// by `Character` count so CJK stays whole.
    static func truncateForPayload(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.map { scalar -> Character in
            // C0 controls (0x00-0x1F) + DEL (0x7F)
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return " "
            }
            return Character(scalar)
        })
        return String(cleaned.prefix(identifierMaxLength))
    }

    /// PostToolUse success heuristic — Claude doesn't expose a structured
    /// success/failure flag in PostToolUse hook stdin, so we read
    /// `tool_response` (when present + a String) and look for common
    /// error markers. Missing / non-string response → defaults to true
    /// (don't false-flag tools we can't read). Conservative for v1.
    static func detectSuccess(toolResponse: Any?) -> Bool {
        guard let response = toolResponse as? String, !response.isEmpty else { return true }
        let lowered = response.lowercased()
        let errorMarkers = [
            "error:",
            "failed:",
            "exception:",
            "fatal:",
            "<error>",
            "permission denied",
            "command not found",
            "no such file",
        ]
        return !errorMarkers.contains { lowered.contains($0) }
    }
}
