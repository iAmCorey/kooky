import Darwin
import Foundation
import KookyHookKit

// kooky-hook: invoked by an agent's hook system (Claude Code's `--settings`
// hooks, Codex equivalents, …) and the shell precmd hook (`env` mode) to
// ping the running kooky app over a unix socket. Payload building +
// stdin parsing live in `KookyHookKit` so they're unit-testable; this
// file stays a thin dispatcher.
//
// Exit codes:
//   0 — IPC succeeded, OR caller is outside kooky (no surface id) / args
//       malformed (programmer error). Both are "no retry needed."
//   1 — IPC failed (kooky not listening, socket gone, write error). Shell
//       callers use this to keep their dedup cache un-advanced so the next
//       prompt re-attempts. Without this distinction, a single transient
//       failure (kooky restarting, socket recreated) would freeze the env
//       cache permanently.
//
// Usage: kooky-hook <agent> <event>
//   <agent> ∈ claude | codex | pi (or any AgentTemplate.id)
//   <event> ∈ running | attention | idle    (lifecycle events)
//           | PreToolUse | PostToolUse      (Claude tool events — stdin JSON)
//           | conversation <id>             (extension-reported resume id — Pi)
//           | tool <pre|post> <id> <name> <identifier> [ok|fail]
//                                            (extension-reported tool call — Pi)
// Usage: kooky-hook env <VIRTUAL_ENV> <CONDA_DEFAULT_ENV> <NVM_BIN> <NVM_DIR> <NODE_VERSION> <https_proxy> <http_proxy> <all_proxy>
// Reads:  $KOOKY_SURFACE_ID       UUID of the originating session
// Reads:  stdin                   Hook commands carrying --hook-stdin pipe a
//                                 JSON object. The helper extracts that
//                                 agent's exact session/conversation id and
//                                 mirrors it as `kind: conversationId`.

let surface = ProcessInfo.processInfo.environment["KOOKY_SURFACE_ID"] ?? ""
guard !surface.isEmpty else { exit(0) }

let socketPath = KookyHookKit.socketPath

// Do not read stdin here: it belongs to the shell editor and may already
// contain the user's next keystrokes. The reply travels over the socket.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "shell-command" {
    guard let surface = UUID(uuidString: surface),
          let pid = Int32(CommandLine.arguments[2]),
          let command = KookyHookKit.fetchShellCommand(surface: surface, shellPID: pid) else { exit(1) }
    print(command)
    exit(0)
}

// Drain stdin once up-front so the tool parser and conversation-id mirror
// don't double-read a single-pass stream. The explicit marker is essential:
// bracket-wrapper pings inherit the agent invocation's stdin, which may be a
// user-supplied pipe. Reading merely because `isatty == 0` would consume that
// input before the real agent sees it.
let agentArg = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : ""
let readsHookStdin = CommandLine.arguments.contains(KookyHookKit.hookStdinMarker)
let stdinData: Data = (readsHookStdin && isatty(fileno(stdin)) == 0)
    ? ((try? FileHandle.standardInput.readToEnd()) ?? Data())
    : Data()

let payloadObject: [String: String]
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "env" {
    let envArgs = Array(CommandLine.arguments.dropFirst(2))
    payloadObject = KookyHookKit.buildEnvPayload(surface: surface, args: envArgs)
} else if CommandLine.arguments.count >= 3 {
    let agent = CommandLine.arguments[1]
    let event = CommandLine.arguments[2]
    if event == "conversation" {
        // Extension-reported conversation id (Pi): the agent's extension hands
        // kooky the session id directly as argv[3] — no stdin JSON to parse
        // (unlike Claude's hook mirror below). Reuses the same conversationId
        // payload, so WorkspaceStore persists it + prepends `--session <id>`
        // on next launch.
        let id = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : ""
        guard !id.isEmpty else { exit(0) }
        let payload = KookyHookKit.buildConversationIdPayload(surface: surface, conversationId: id)
        exit(KookyHookKit.sendPayload(payload, to: socketPath) ? 0 : 1)
    }
    if event == "tool" {
        // Extension-reported tool call (Pi): the extension hands the already-
        // extracted fields as argv — no stdin JSON to parse (unlike Claude's
        // `parseToolEventPayload`). Funnels through the same
        // `buildToolEventPayload` so the `kind:"tool"` wire shape is identical
        // across agents. argv layout:
        //   kooky-hook <agent> tool pre  <toolCallId> <toolName> <identifier>
        //   kooky-hook <agent> tool post <toolCallId> <toolName> <identifier> <ok|fail>
        let args = CommandLine.arguments
        func at(_ i: Int) -> String { args.indices.contains(i) ? args[i] : "" }
        let phase = at(3)
        let toolName = at(5)
        guard phase == "pre" || phase == "post", !toolName.isEmpty else { exit(0) }
        // Any value other than "fail" (incl. missing) is treated as success —
        // the extension sends "ok"/"fail" off pi's `isError`.
        let success: Bool? = phase == "post" ? (at(7) != "fail") : nil
        let toolUseId = at(4)
        let payload = KookyHookKit.buildToolEventPayload(
            surface: surface,
            agent: agent,
            toolName: toolName,
            identifier: at(6),
            event: phase,
            toolUseId: toolUseId.isEmpty ? nil : toolUseId,
            success: success
        )
        exit(KookyHookKit.sendPayload(payload, to: socketPath) ? 0 : 1)
    }
    if event == "PreToolUse" || event == "PostToolUse" || event == "PostToolUseFailure" {
        // Tool event: stdin JSON is mandatory. Bail silently if it's
        // missing or malformed — pill UI just won't render this call.
        guard let tool = KookyHookKit.parseToolEventPayload(
            from: stdinData,
            surface: surface,
            agent: agent
        ) else { exit(0) }
        payloadObject = tool
    } else {
        payloadObject = KookyHookKit.buildLifecyclePayload(
            agent: agent,
            event: event,
            surface: surface
        )
    }
} else {
    exit(0)
}

let eventSent = KookyHookKit.sendPayload(payloadObject, to: socketPath)

// Bonus payload: hook stdin carries the exact session id for Claude, Gemini,
// Copilot, Cursor, Kimi, Kiro, Droid, and Antigravity. Mirror it through the
// same agent-neutral wire message that Pi/OpenCode/Amp use via argv.
if KookyHookKit.shouldMirrorConversationId(
    agent: agentArg,
    payload: payloadObject,
    environment: ProcessInfo.processInfo.environment
),
   let conversationId = KookyHookKit.parseConversationId(from: stdinData, agent: agentArg) {
    let payload = KookyHookKit.buildConversationIdPayload(
        surface: surface,
        conversationId: conversationId
    )
    _ = KookyHookKit.sendPayload(payload, to: socketPath)
}

exit(eventSent ? 0 : 1)
