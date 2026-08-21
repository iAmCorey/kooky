import AppKit
import SwiftUI

/// A parsed `kooky://` deep link. Parsing is structure + character-set
/// validation only — whether the agent is on the roster, the conversation
/// exists, or the directory is real is the handler's concern
/// (`AppDelegate.handleDeepLink`), so the grammar tests need no stores.
///
/// v1 grammar (query form, so `URLComponents` owns all percent-encoding):
///
///     kooky://resume?agent=<agent-id>&id=<conversation-id>[&cwd=<abs-path>]
///
/// `agent` speaks the AgentTemplate/scanner roster ids — the caller contract
/// (external session managers send `claude-code` / `codex` / `copilot` /
/// `cursor` / `opencode` / `kiro` / `gemini`, kooky's template ids). `cwd` is the
/// conversation's project directory: kooky prefers its OWN scan of the
/// agent's session store for the spawn directory, but the scanner caps at
/// 150 records per agent — `cwd` is what lets a caller resume an older
/// conversation the capped scan can't see. The URL carries NO prompt and no
/// command: a link that could inject text into an agent would be an
/// arbitrary-command vector for any page able to render an anchor.
///
/// Two-tier rejection: a URL that isn't a kooky link we recognize parses to
/// `nil` and is dropped silently (the scheme is public surface; arbitrary
/// malformed links must not pop UI), while a RECOGNIZED resume link with
/// parameters kooky refuses parses to `.invalid(reason:)` — the requester
/// (an "Open In" button, a script) expects visible feedback, not a silent no-op.
enum KookyDeepLink: Equatable {
    case resumeSession(agentId: String, conversationId: String, cwd: String?)
    case invalid(reason: String)

    static let scheme = "kooky"

    /// Conversation ids may reach a shell command line (`claude --resume
    /// <id>` via the KOOKY_AGENT eval), so an id from an UNTRUSTED URL must
    /// be shell-inert by construction: alphanumeric head (a leading `-`
    /// would parse as a flag), then `[A-Za-z0-9._-]`. Every real id shape
    /// across the 7 caller agents fits (UUIDs; opencode `ses_1da2…` — `_`
    /// included; gemini `session-2026-07-27T14-11-…`), and nothing in the
    /// set is special to POSIX shells, so this validation IS the
    /// parameterization — with `ConversationResumeStrategy.shellArgument`'s
    /// quoting as the second, independent layer.
    static func isValidConversationId(_ id: String) -> Bool {
        guard let head = id.first, head.isASCII, (head.isLetter || head.isNumber),
              id.count <= 200
        else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }
    }

    /// Scheme and host are case-insensitive per RFC 3986; query names are
    /// not. The agent id is normalized to lowercase (roster ids all are);
    /// the conversation id keeps its exact case. Caller contract: values are
    /// percent-encoded — a space is `%20`, never `+` (URLComponents keeps
    /// `+` literal, and `+` is a legal path character, so form-encoding
    /// callers would silently corrupt every cwd containing a space).
    static func parse(_ url: URL) -> KookyDeepLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // `kooky:///resume` (the natural file:///-habit typo) parses with an
        // EMPTY host and the action in the path — accept it, or the most
        // common hand-written mistake lands in the silent tier.
        var action = components.host?.lowercased()
        if action?.isEmpty != false {
            action = components.path.split(separator: "/").first.map { $0.lowercased() }
        }
        switch action {
        case "resume":
            func value(_ name: String) -> String? {
                components.queryItems?.first { $0.name == name }?.value
            }
            return validateResume(agentId: value("agent"), conversationId: value("id"), cwd: value("cwd"))
        default:
            return nil
        }
    }

    /// Field-level construction shared by `parse` (URL query values) and the
    /// CLI's `resume` verb (argv values) — one grammar, two front doors, so
    /// the CLI can't accept an id the deep link would refuse. Blank values
    /// collapse to missing (`normalizedTitle` is the codebase's one
    /// "blank collapses to nil" rule — not a title here, but the same
    /// trim-to-nil); the agent id lowercases; the conversation id keeps its
    /// exact case.
    static func validateResume(agentId rawAgent: String?, conversationId rawId: String?, cwd rawCwd: String?) -> KookyDeepLink {
        guard let agent = rawAgent.flatMap(normalizedTitle) else { return .invalid(reason: "missing 'agent' parameter") }
        guard agent.count <= 64 else { return .invalid(reason: "agent id is too long") }
        guard let id = rawId.flatMap(normalizedTitle) else { return .invalid(reason: "missing 'id' parameter") }
        guard isValidConversationId(id) else {
            return .invalid(reason: "conversation id contains characters kooky refuses")
        }
        let cwd = rawCwd.flatMap(normalizedTitle)
        if let cwd {
            // Length-capped like the id: these strings reach the failure
            // sheet and the log, and an ARG_MAX-sized value would stall
            // CoreText layout on the main thread.
            guard cwd.count <= 1024 else { return .invalid(reason: "cwd is too long") }
            guard cwd.hasPrefix("/") else { return .invalid(reason: "cwd must be an absolute path") }
        }
        return .resumeSession(agentId: agent.lowercased(), conversationId: id, cwd: cwd)
    }

    /// The canonical spelling of a resume link — the single source for any
    /// future "Copy Deep Link" UI, and what keeps the round-trip test honest.
    static func resumeURL(agentId: String, conversationId: String, cwd: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "resume"
        var items = [
            URLQueryItem(name: "agent", value: agentId),
            URLQueryItem(name: "id", value: conversationId),
        ]
        if let cwd { items.append(URLQueryItem(name: "cwd", value: cwd)) }
        components.queryItems = items
        return components.url
    }
}

// MARK: - Failure sheet

/// A deep link that reached kooky but can't be honored must say so — the
/// caller just activated the app, and pure silence reads as a dead link.
/// Same brutalist family as the clipboard consent sheet; one acknowledge
/// button, ⌘W dismisses (via `ConsentSheetController`'s DismissablePanel).
@MainActor
enum DeepLinkFailurePresenter {
    /// One pending sheet per window, newcomers dropped — the scheme is
    /// public surface, so a script looping bad links must not queue an
    /// unbounded stack of modal sheets (the same bound
    /// `ClipboardConfirmPresenter.pendingByWindow` enforces; an info sheet
    /// can drop newcomers outright since nothing awaits a completion).
    private static let pendingByWindow = NSMapTable<NSWindow, AnyObject>.weakToWeakObjects()

    static func present(on window: NSWindow, reason: String) {
        guard pendingByWindow.object(forKey: window) == nil else { return }
        let controller = ConsentSheetController.present(
            on: window,
            onTeardown: { pendingByWindow.removeObject(forKey: $0) },
            onDecision: { _ in }
        ) { decide in
            DeepLinkFailureSheet(reason: reason) { decide(true) }
        }
        pendingByWindow.setObject(controller, forKey: window)
    }
}

private struct DeepLinkFailureSheet: View {
    let reason: String
    let acknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "DEEP-LINK", bundle: .kookyResources))
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                .padding(.bottom, 18)

            Text("Can't open this link", bundle: .kookyResources)
                .font(Theme.display(20, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)

            Text(reason)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 6)

            HStack(spacing: 10) {
                Spacer()
                BracketButton("ok") { acknowledge() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }
}
