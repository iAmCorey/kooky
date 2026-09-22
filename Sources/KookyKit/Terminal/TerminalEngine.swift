import AppKit

struct TerminalSessionConfig {
    var command: String
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]

    static func defaultShell() -> TerminalSessionConfig {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? KookyShellIntegration.zshPath
        return TerminalSessionConfig(command: shell, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Pinned zsh — pairs with the ZDOTDIR wrapper for KOOKY_AGENT + OSC 7.
    static func zshShell() -> TerminalSessionConfig {
        TerminalSessionConfig(command: KookyShellIntegration.zshPath, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Bash via launcher script — direct `--rcfile` flags don't work because
    /// libghostty makes every `command` a login shell, which strips
    /// `--rcfile` semantics. Launcher re-execs as interactive non-login.
    static func bashShell(launcher: String) -> TerminalSessionConfig {
        TerminalSessionConfig(command: launcher, arguments: [], workingDirectory: nil, environment: [:])
    }

    /// fish via `XDG_DATA_DIRS` injection: we prepend kooky's data root so fish
    /// auto-loads our `fish/vendor_conf.d/kooky.fish` (the integration hooks).
    /// No launcher / `-C` — both run after `config.fish` and get swallowed by
    /// shell-wrapping autocomplete tools (Fig / Amazon Q / kiro); vendor_conf.d
    /// is read by every fish, including the inner shell those tools re-`exec`.
    /// fish adds its own default vendor dirs (homebrew, ~/.local/share)
    /// independently of `XDG_DATA_DIRS`, so prepending here can't drop them.
    static func fishShell() -> TerminalSessionConfig {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? KookyShellIntegration.fishPath
        let existing = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
        return TerminalSessionConfig(
            command: shell,
            arguments: [],
            workingDirectory: nil,
            environment: ["XDG_DATA_DIRS": "\(KookyShellIntegration.fishVendorDataRoot):\(existing)"]
        )
    }
}

@MainActor
protocol TerminalEngine: AnyObject {
    var view: NSView { get }
    func renderNowIfNeeded()
    /// The owning window was ordered out (closed-but-alive) or brought back.
    /// Off screen, an engine must stop presenting frames: the PTY keeps
    /// running, only the GPU work stops. Default no-op for engines that
    /// never render (tests).
    func setOnScreen(_ onScreen: Bool)
    var backgroundColor: NSColor { get }
    /// Called when the engine observes a working-directory change (libghostty's
    /// `GHOSTTY_ACTION_PWD`, fired when the shell emits OSC 7). Lets the
    /// workspace track the active tab's cwd so new tabs inherit the latest path.
    var onPwdChange: ((String) -> Void)? { get set }
    /// Called when the running program sets the terminal title via an `OSC 0`
    /// / `OSC 2` escape sequence (libghostty's `GHOSTTY_ACTION_SET_TITLE`).
    /// Drives the tab + workspace name so an `ssh` into a remote host — whose
    /// shell emits its own `user@host:dir` title — shows in kooky's chrome.
    var onTitleChange: ((String) -> Void)? { get set }
    /// Called when this engine's surface becomes the window's first responder
    /// (i.e. the user clicked into it). Lets the workspace mark the matching
    /// leaf as focused so split-aware operations (cwd tracking, ⌘D inheritance)
    /// follow the visually-active pane.
    var onFocus: (() -> Void)? { get set }
    /// Called when libghostty sees `OSC 133;D` from the shell — the
    /// most-recent command's exit code and run duration. `exitCode` is `nil`
    /// when the shell omitted it from the OSC sequence.
    var onCommandFinished: ((Int?, TimeInterval) -> Void)? { get set }
    /// Fires when the user begins the next command — any keystroke (typing,
    /// Return, arrows, Ctrl / edit shortcuts), paste, or programmatic injection.
    /// libghostty exposes command *finish* (OSC 133;D) but not command *start*,
    /// so user input is the signal a session uses to clear a stale command-
    /// failure dot the moment the user moves on.
    var onUserInput: (() -> Void)? { get set }
    /// Search lifecycle from libghostty's `start_search` / `end_search` /
    /// `navigate_search` keybinds. While `onSearchStart` is the most recent
    /// signal, libghostty owns the input loop and reports the current needle
    /// + total / selected match index back through these callbacks. The UI
    /// is a passive mirror — kooky doesn't push the needle string itself.
    var onSearchStart: ((String) -> Void)? { get set }
    var onSearchEnd: (() -> Void)? { get set }
    var onSearchTotal: ((Int) -> Void)? { get set }
    var onSearchSelected: ((Int) -> Void)? { get set }
    /// SSH destination pasted files should be uploaded to before their path
    /// is injected, or nil for plain local paste. Wired by `WorkspaceStore`
    /// to the session's spawn-pinned `sshWorkspaceHost` — NOT the marker-
    /// driven `remoteHost` status-bar signal, which the name deliberately
    /// avoids. The engine asks at paste time instead of caching so tab moves
    /// across panes/windows can't strand a stale host.
    var pasteUploadHostProvider: (() -> String?)? { get set }
    /// Whether filesystem paths emitted by this surface belong to a remote
    /// machine. Plain URLs remain openable; only scheme-less/file URL targets
    /// are suppressed so an SSH path can never accidentally open a same-named
    /// local file. Asked at click time because remote-login markers can change
    /// during a session.
    var isRemoteSessionProvider: (() -> Bool)? { get set }
    /// PID of the foreground process inside the surface. Used only as an
    /// initial/fallback env snapshot before the prompt hook reports live
    /// `VIRTUAL_ENV` / `NVM_BIN`.
    var foregroundPid: pid_t? { get }
    /// Fires when the surface's child process exits cleanly (exit code 0
    /// — `exit` / `logout` typed in the shell). Non-zero exits intentionally
    /// don't fire this — libghostty's "press any key to close" message
    /// stays so the user can read crash output before dismissing.
    var onProcessExitedCleanly: (() -> Void)? { get set }
    /// A program in the terminal posted a desktop notification (OSC 9 /
    /// OSC 777) — (title, body). The store routes it to the app-level
    /// notification pipeline (visibility suppression + UN banner).
    var onDesktopNotification: ((String, String) -> Void)? { get set }
    /// Whether closing this surface deserves a confirmation — the core's
    /// own judgment (`confirm-close-surface` config × a live child process).
    var needsConfirmQuit: Bool { get }
    /// ⌘-hover entered (url) / left (nil) a link — drives the URL preview
    /// badge. Emission is gated core-side by `link-previews`.
    var onLinkHover: ((String?) -> Void)? { get set }
    func start(config: TerminalSessionConfig)
    func terminate()
    /// True while ANY owner holds a size-propagation suspension. While set, AppKit
    /// `setFrameSize` callbacks skip `ghostty_surface_set_size` so an animated /
    /// interactive layout change (pane zoom, status-bar height, split-divider drag)
    /// doesn't fire a SIGWINCH burst per intermediate frame — the documented
    /// "12-24 set_size calls per toggle" scrollback-wipe that hits conda users
    /// (see CLAUDE.md known issues). **Refcounted**: three owners can overlap, so
    /// a plain shared Bool let one owner's un-suspend clobber another's still-active
    /// suspend (issue #29 review). Mutate through the balanced begin/end pair —
    /// each owner must pair its own `begin` with exactly one `end` (gate re-arms
    /// behind a per-owner flag/token so you don't double-count), and follow the
    /// `end` with `flushSize()` so libghostty's grid catches up to the final size.
    var suspendsSizePropagation: Bool { get }
    func beginSizePropagationSuspension()
    func endSizePropagationSuspension()
    /// Force a one-shot size sync of the surface to the current view
    /// frame. Used when un-suspending after an animation.
    func flushSize()
    /// Gates whether the engine's view grabs keyboard first-responder when it
    /// mounts into a window. `TerminalTabHost` sets it from the pane's active
    /// state so first visits land focus only when the pane is active (issue #24).
    /// Workspace switches no longer re-mount anything (persistent containers);
    /// those are `PaneTreeHostView.syncFocus`'s job. Default true: a single pane
    /// or a fresh split/tab still grabs focus on mount.
    var grabsFocusOnMount: Bool { get set }
    /// Exempts THIS engine from the lazy spawn-on-reveal gate: its surface
    /// (and shell) comes up even while the view is hidden. Set for tabs the
    /// CLI opens with --no-focus — "background" means the command RUNS
    /// (issue #59), not "loads when you look at it". Spawn-only: rendering
    /// stays visibility-gated, so a hidden streaming terminal still costs
    /// zero GPU.
    var spawnsWhileHidden: Bool { get set }
    /// Trigger a libghostty named action (e.g. `increase_font_size:1`,
    /// `decrease_font_size:1`, `reset_font_size`, `clear_screen`). Returns
    /// `true` when the engine recognised and dispatched the action.
    @discardableResult
    func performAction(_ name: String) -> Bool
    /// Sends committed text into the PTY as if the user typed it.
    func sendInput(_ text: String)
    /// Routes `text` through the engine's paste path — wrapped in
    /// bracketed-paste sequences when the shell has enabled them so
    /// `zsh` line-editor multi-line guards and `vim` paste mode behave
    /// the same as a real ⌘V. The right-click "Paste" menu item uses
    /// this instead of `sendInput` so the two paths can't drift.
    func paste(_ text: String)
    /// Plain-text paste through the engine's OWN clipboard-request path so
    /// `clipboard-paste-protection` inspects the content before it reaches
    /// the PTY. `paste(_:)` bypasses that check by design (kooky-constructed
    /// file/image paths) — user-initiated plain-text pastes go here.
    func pasteFromClipboardViaCore() -> Bool
    /// Returns the current selection as a UTF-8 string, or nil if no
    /// selection is active. Powers the right-click "Ask agent" path and
    /// the menu-bar Copy item — same surface, two callers.
    func readSelection() -> String?
}

extension TerminalEngine {
    func setOnScreen(_ onScreen: Bool) {}
}
