import Foundation

/// Private terminal-title marker the ssh wrapper emits for its managed
/// connection handshake. Like `AgentStatusMarker`, it rides the terminal byte
/// stream (OSC 2), and is consumed before it can become a visible tab title.
///
/// SSH workspace state is owned by explicitly created SSH workspaces. A marker
/// observed in an ordinary terminal must not promote that local workspace or
/// tab into remote mode.
///
/// Wire title shape:
///   kooky-remote-login:<destination>
///
/// where `<destination>` is the ssh argument verbatim (`user@host` if a user
/// was given, else bare `host`). Delivered via OSC 2 and intercepted before it
enum RemoteLoginMarker {
    /// `internal` so the ssh wrapper emit interpolates the same constant the
    /// parse reads — one source of truth for the wire prefix.
    static let titlePrefix = "kooky-remote-login:"

    /// Returns the SSH destination (`user@host` or bare `host`), or nil when
    /// `raw` isn't a remote-login marker (or its payload is empty). No separate
    /// `isMarkerTitle`: unlike `AgentStatusMarker` (whose `parseTitle` is
    /// `@MainActor` + returns a tuple), this is non-isolated and already returns
    /// the optional a caller branches on.
    static func parseTitle(_ raw: String) -> String? {
        guard let title = normalizedTitle(raw),
              title.hasPrefix(titlePrefix)
        else { return nil }

        let host = String(title.dropFirst(titlePrefix.count))
        return host.isEmpty ? nil : host
    }
}
