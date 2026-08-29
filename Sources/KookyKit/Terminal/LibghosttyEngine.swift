import AppKit
import GhosttyKit


// MARK: - LibghosttyApp

/// Process-wide libghostty runtime. ghostty_init runs once; every Surface is
/// created against this single app handle. Ticks are event-driven via
/// `wakeup_cb`; libghostty signals when it has work, we hop to main and drain.
@MainActor
final class LibghosttyApp {
    static let shared = LibghosttyApp()

    private(set) var app: ghostty_app_t?

    private init() {
        var argv: [UnsafeMutablePointer<CChar>?] = [nil]
        let initResult = argv.withUnsafeMutableBufferPointer {
            ghostty_init(0, $0.baseAddress)
        }
        guard initResult == 0 else {
            NSLog("kooky: ghostty_init failed (\(initResult))")
            return
        }

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: kookyWakeupCb,
            action_cb: kookyActionCb,
            read_clipboard_cb: kookyReadClipboardCb,
            confirm_read_clipboard_cb: kookyConfirmReadClipboardCb,
            write_clipboard_cb: kookyWriteClipboardCb,
            close_surface_cb: kookyCloseSurfaceCb,
            tmux_control_cb: nil
        )

        guard let config = KookySettings.makeGhosttyConfig() else {
            NSLog("kooky: ghostty_config_new failed")
            return
        }
        self.app = ghostty_app_new(&runtime, config)
        if self.app == nil {
            NSLog("kooky: ghostty_app_new failed")
        }
        currentConfig = config
        refreshHostConfig()
        reportColorScheme()
        // Immediately re-apply the SAME config handle now that the color
        // scheme above has seeded the app's conditional state.
        // `ghostty_app_new` stores the config with its BUILT-AT conditional
        // state (light); on a dark theme the set_color_scheme flips the app
        // state, and the next `ghostty_surface_new` — the restore-spawned
        // first tab — detects the mismatch and REBUILDS its per-surface
        // config from the original parse. That rebuild drops everything
        // kooky injected via the surface-config env_vars (ZDOTDIR,
        // KOOKY_SURFACE_ID, …): the first tab's shell spawns with no kooky
        // integration at all — no shell hooks, no OSC 7/133, dead
        // red-dot/title/cwd tracking (the "restored tab is silent" bug). The
        // core's own corrective RELOAD_CONFIG action is coalesced onto the
        // next runloop turn, which is too late — restore wins the race.
        // Re-applying synchronously here puts the conditional-applied config
        // in place before any surface can exist. Deliberately NOT a full
        // `reloadConfig()`: the config was built microseconds ago (a rebuild
        // re-reads the ghostty config + settings.json from disk for an
        // identical result), nothing host-side changed, and `currentConfig`
        // stays this same still-alive handle — the core deep-copies what it
        // keeps.
        if let app = self.app {
            ghostty_app_update_config(app, config)
        }

        // Input-source switches (US → Pinyin → Dvorak…) must invalidate the
        // core's cached keymap — `ghostty_surface_key_translation_mods` and
        // `physical:`-style key handling read it, so a stale keymap skews the
        // very translation the option-as-alt path depends on (issue #46
        // follow-up from the host-gap audit). Block observer + assumeIsolated
        // because LibghosttyApp isn't an NSObject (no selector dispatch);
        // `queue: .main` already delivers on the main thread.
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let app = LibghosttyApp.shared.app else { return }
                ghostty_app_keyboard_changed(app)
            }
        }
    }

    /// The config currently applied to the app. libghostty's embedded API
    /// clones on app-new and update-config, but freeing the config RIGHT
    /// AFTER `ghostty_app_new` makes the next `ghostty_surface_new` fail
    /// (verified empirically — some part of the clone still references the
    /// original's memory, a path upstream never exercises because
    /// Ghostty.app keeps each config alive until the next reload replaces
    /// it). Mirror that lifecycle: exactly ONE config is ever alive, each
    /// freed when its successor is applied, so reloads no longer accumulate
    /// leaked configs (the old code freed nothing, ever).
    private var currentConfig: ghostty_config_t?


    func reloadConfig() {
        guard let app else { return }
        guard let config = KookySettings.makeGhosttyConfig() else {
            NSLog("kooky: ghostty_config_new failed during reload")
            return
        }
        // One app-level update IS the whole reload: upstream App.updateConfig
        // fans the config out to every surface itself (change_config message)
        // and each surface ends its own updateConfig with queueRender — a
        // second per-surface pass would rebuild + reapply the same config N
        // times per reload (and leak N more copies).
        ghostty_app_update_config(app, config)
        // The fan-out is synchronous and deep-copies what it keeps, so the
        // PREVIOUS config is unreferenced once update returns.
        if let previous = currentConfig { ghostty_config_free(previous) }
        currentConfig = config
        refreshHostConfig()
        reportColorScheme()
    }

    /// Tells the core whether kooky's ACTIVE THEME is dark — deliberately not
    /// the system appearance: a program asking "is the background dark?"
    /// (nvim `background` autodetect, delta, mode 2031 reports, the CSI ?996n
    /// query) wants the terminal's colors, and kooky's theme can disagree
    /// with the OS. BOTH levels, mirroring ghostty.app: the app call only
    /// updates the App's own conditional state — it never touches a surface
    /// — while the query/report/conditional-theme state lives PER SURFACE
    /// (verified: app-only calls left every surface answering "light"
    /// forever). Same-value calls short-circuit core-side at both levels, so
    /// the reload → report loop can't cycle.
    private func reportColorScheme() {
        guard let app else { return }
        let scheme = Self.currentColorScheme
        ghostty_app_set_color_scheme(app, scheme)
        for surface in GhosttySurfaceRegistry.allSurfaces() {
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }

    static var currentColorScheme: ghostty_color_scheme_e {
        Theme.chromeColorScheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    /// Coalesces the per-surface RELOAD_CONFIG fan-out (every surface answers
    /// a color-scheme flip with its own action) into one rebuild on the next
    /// runloop turn.
    private var reloadPending = false
    func reloadConfigCoalesced() {
        guard !reloadPending else { return }
        reloadPending = true
        dispatchToMain {
            self.reloadPending = false
            self.reloadConfig()
        }
    }

    /// Host-side config kooky itself acts on (the core only stores these —
    /// the host must implement the behavior). Cached at config apply because
    /// `focusFollowsMouse` is read per mouseMoved and a bell flood shouldn't
    /// re-read three keys per ring; refreshed by init + every reload, which
    /// is what keeps a settings edit applying without restart.
    struct HostConfig {
        var focusFollowsMouse = false
        // bell-features upstream default: attention + title. kooky implements
        // system/audio/attention; title/border are ghostty.app-chrome forms
        // kooky's own tab UI doesn't mirror.
        var bellSystem = false
        var bellAudio = false
        var bellAttention = true
        var bellAudioPath: String?
        var bellAudioVolume: Float = 0.5
        /// `macos-auto-secure-input` — the gate is host-side by upstream
        /// design (the core always emits SECURE_INPUT on password-prompt
        /// detection; the host decides whether to honor it).
        var autoSecureInput = true
        /// `background-opacity` from the MERGED config — what the settings
        /// slider shows/overrides when kooky's own key is unset but an
        /// inherited ghostty config supplies a value (Codex P2: without the
        /// merged truth the slider claimed 100% while the window rendered at
        /// the inherited 0.6, and couldn't override it).
        var backgroundOpacity: Double = 1
        /// `background-blur` as a radius (`true`/a number; 0 = off, the
        /// `macos-glass-*` forms are kooky's own glass path). A positive
        /// radius is what licenses window translucency without glass —
        /// bare opacity with NO frosting underneath leaks the desktop
        /// through kooky's layered chrome at visibly different levels
        /// (inactive-pane dimming, sidebar, top strip all multiply
        /// differently), so it stays opaque by design.
        var windowBlurRadius: Int = 0
    }
    private(set) var hostConfig = HostConfig()

    /// The configured bell sound, decoded once per config apply — building
    /// an NSSound per ring re-reads the file on the main thread (a visible
    /// hitch when the page cache is cold), and a ring-local instance can be
    /// released before playback finishes.
    private(set) var bellSound: NSSound?

    private func refreshHostConfig() {
        guard let config = currentConfig else { return }
        var next = HostConfig()
        var ffm = false
        if get(config, "focus-follows-mouse", &ffm) { next.focusFollowsMouse = ffm }
        var bell: CUnsignedInt = 0
        if get(config, "bell-features", &bell) {
            next.bellSystem = bell & (1 << 0) != 0
            next.bellAudio = bell & (1 << 1) != 0
            next.bellAttention = bell & (1 << 2) != 0
        }
        var path = ghostty_config_path_s()
        if get(config, "bell-audio-path", &path), let cstr = path.path {
            let str = String(cString: cstr)
            next.bellAudioPath = str.isEmpty ? nil : str
        }
        var volume: Double = 0
        if get(config, "bell-audio-volume", &volume) {
            next.bellAudioVolume = Float(volume)
        }
        var secure = true
        if get(config, "macos-auto-secure-input", &secure) { next.autoSecureInput = secure }
        var opacity: Double = 1
        if get(config, "background-opacity", &opacity) { next.backgroundOpacity = opacity }
        var blur: Int16 = 0
        if get(config, "background-blur", &blur), blur > 0 {
            next.windowBlurRadius = Int(blur)
        }
        if next.bellAudioPath != hostConfig.bellAudioPath {
            bellSound = next.bellAudioPath.flatMap { NSSound(contentsOfFile: $0, byReference: false) }
        }
        hostConfig = next
    }

    /// `ghostty_config_get` writes directly into caller-owned C storage.
    /// Taking an UnsafeMutablePointer here (rather than accepting `inout` and
    /// taking `&out` again) both models that ABI accurately and avoids Swift's
    /// unsafe generic raw-pointer diagnostic.
    private func get<T>(
        _ config: ghostty_config_t,
        _ key: String,
        _ out: UnsafeMutablePointer<T>
    ) -> Bool {
        ghostty_config_get(config, out, key, UInt(key.utf8.count))
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}

// MARK: - C callbacks

private let kookyWakeupCb: ghostty_runtime_wakeup_cb = { _ in
    dispatchToMain { LibghosttyApp.shared.tick() }
}

/// Replaces the general pasteboard's contents. Must run on main so the change
/// notification reaches clipboard managers (Paste, Maccy, …) — otherwise the
/// value lands but listeners miss it. The single write site app-wide — OSC 52
/// allow, consent-sheet allow, ⌘C, and every UI "Copy" row/button.
@MainActor
func writeToGeneralPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

/// `\a` reached the terminal — play the configured bell (upstream
/// ghosttyBellDidRing semantics; the core debounces rings at 100ms so a bell
/// flood can't hammer this). `requestUserAttention` only bounces the Dock
/// when kooky isn't frontmost — the OS handles that gate.
@MainActor
private func handleBellRing() {
    let cfg = LibghosttyApp.shared.hostConfig
    if cfg.bellSystem {
        NSSound.beep()
    }
    if cfg.bellAudio, let sound = LibghosttyApp.shared.bellSound {
        // stop() restarts playback for a re-ring inside the debounce window.
        sound.stop()
        sound.volume = cfg.bellAudioVolume
        sound.play()
    }
    if cfg.bellAttention {
        NSApp.requestUserAttention(.informationalRequest)
    }
}

/// Main-actor hop for view-less core callbacks (bell, cursor visibility,
/// pasteboard writes) — the sibling of `dispatchToView` for work that needs
/// no originating surface.
private func dispatchToMain(_ work: @MainActor @escaping () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated(work)
    }
}

/// Weak set of live surfaces, for the ONE state the core keeps per surface
/// with NO app-level fan-out: the color scheme (996 query / mode 2031 /
/// conditional-theme resolution). The v0.17.0 registry was deleted in
/// v0.45.3 because config reloads DO fan out app-side — that reasoning
/// still holds; this exists only for `reportColorScheme`, which verified
/// that app-level-only calls leave every surface answering "light" forever.
@MainActor
enum GhosttySurfaceRegistry {
    private static let views = NSHashTable<GhosttySurfaceView>.weakObjects()

    static func add(_ view: GhosttySurfaceView) { views.add(view) }

    static func allSurfaces() -> [ghostty_surface_t] {
        views.allObjects.compactMap(\.surface)
    }
}

/// Hops to main + recovers the originating `GhosttySurfaceView` from libghostty's
/// userdata pointer. Action_cb runs on whichever thread libghostty signals
/// from; SwiftUI / our @MainActor state requires main, hence the bounce.
/// The pointer transits as an `Int` bit pattern because Swift 6 concurrency
/// flags `UnsafeMutableRawPointer` capture across the dispatch boundary.
private func dispatchToView(_ userdata: UnsafeMutableRawPointer, _ work: @MainActor @escaping (GhosttySurfaceView) -> Void) {
    let bits = Int(bitPattern: userdata)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(pointer).takeUnretainedValue()
            work(view)
        }
    }
}

private let kookyActionCb: ghostty_runtime_action_cb = { _, target, action in
    // Before the surface-target guard: the APP-level color-scheme path emits
    // RELOAD_CONFIG with an APP target (App.colorSchemeEvent), which the
    // guard below would silently drop. Coalesced either way.
    if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
        dispatchToMain { LibghosttyApp.shared.reloadConfigCoalesced() }
        return true
    }
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let userdata = ghostty_surface_userdata(surface)
    else { return false }

    switch action.tag {
    case GHOSTTY_ACTION_SCROLLBAR:
        let bar = action.action.scrollbar
        dispatchToView(userdata) { $0.applyScrollbar(total: bar.total, offset: bar.offset, len: bar.len) }
        return true
    case GHOSTTY_ACTION_PWD:
        guard let cstr = action.action.pwd.pwd else { return true }
        let pwd = String(cString: cstr)
        dispatchToView(userdata) {
            $0.currentDirectory = URL(fileURLWithPath: pwd)
            $0.onPwdChange?(pwd)
        }
        return true
    case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
        // OSC 0 / OSC 2 (and ghostty's tab-title variant). An `ssh` session's
        // remote shell emits its own `user@host:dir` title — surfacing it
        // keeps the tab + workspace name honest about where the shell is.
        let titleAction = action.tag == GHOSTTY_ACTION_SET_TITLE
            ? action.action.set_title
            : action.action.set_tab_title
        guard let cstr = titleAction.title else { return true }
        let title = String(cString: cstr)
        dispatchToView(userdata) { $0.onTitleChange?(title) }
        return true
    case GHOSTTY_ACTION_OPEN_URL:
        // libghostty sends both real URLs and matched filesystem paths through
        // this action. `URL(string:)` also accepts scheme-less paths, but those
        // are not file URLs and NSWorkspace cannot open them as documents.
        // Resolve on the originating view so relative paths use that session's
        // live OSC-7 cwd and SSH paths can be suppressed safely.
        let urlAction = action.action.open_url
        guard let cstr = urlAction.url, urlAction.len > 0 else { return false }
        let buffer = UnsafeRawBufferPointer(start: cstr, count: Int(urlAction.len))
        let rawTarget = String(decoding: buffer, as: UTF8.self)
        dispatchToView(userdata) { $0.open(target: rawTarget) }
        return true
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        let shape = action.action.mouse_shape
        dispatchToView(userdata) { $0.applyMouseShape(shape) }
        return true
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        // exit 0 → user typed `exit` / `logout`; auto-close the kooky tab
        // by returning `true` (suppresses libghostty's "press any key to
        // close" message) AND dispatching the callback that fires `closeTab`.
        // Non-zero exit (crash, segfault, bad command) returns `false` so
        // libghostty's default UI stays — user can read the error before
        // dismissing with a keypress.
        let exit = action.action.child_exited.exit_code
        guard exit == 0 else { return false }
        dispatchToView(userdata) { $0.onProcessExitedCleanly?() }
        return true
    case GHOSTTY_ACTION_COMMAND_FINISHED:
        // Shell emitted `OSC 133;D[;exit]` — last command done. exit=-1 means
        // the shell omitted the field; pass `nil` upward so the UI can pick a
        // neutral treatment instead of pretending we know it succeeded.
        let finished = action.action.command_finished
        let exit: Int? = finished.exit_code < 0 ? nil : Int(finished.exit_code)
        let duration = TimeInterval(finished.duration) / 1_000_000_000
        dispatchToView(userdata) { $0.onCommandFinished?(exit, duration) }
        return true
    case GHOSTTY_ACTION_START_SEARCH:
        // libghostty entered search mode (or updated the needle). The needle
        // pointer is a libghostty-owned C string — copy into Swift before
        // hopping main, so we don't read freed memory after dispatch.
        let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
        dispatchToView(userdata) { $0.onSearchStart?(needle) }
        return true
    case GHOSTTY_ACTION_END_SEARCH:
        dispatchToView(userdata) { $0.onSearchEnd?() }
        return true
    case GHOSTTY_ACTION_SEARCH_TOTAL:
        let total = Int(action.action.search_total.total)
        dispatchToView(userdata) { $0.onSearchTotal?(total) }
        return true
    case GHOSTTY_ACTION_SEARCH_SELECTED:
        let selected = Int(action.action.search_selected.selected)
        dispatchToView(userdata) { $0.onSearchSelected?(selected) }
        return true
    case GHOSTTY_ACTION_RENDER:
        // libghostty marked content dirty — wake the per-surface render link so
        // the next vsync presents it. This is the whole render loop now that the
        // polling Timer is gone (issue #29); without it nothing would ever draw.
        dispatchToView(userdata) { $0.setNeedsRender() }
        return true
    case GHOSTTY_ACTION_RENDERER_HEALTH:
        // Diagnostic only (NOT part of the frame loop): surfaces a degraded GPU /
        // Metal state that would otherwise be silent — the blind spot to check
        // first if any visual corruption survives the render-loop fix.
        if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY {
            NSLog("kooky: ghostty renderer reported UNHEALTHY")
        }
        return true
    case GHOSTTY_ACTION_SECURE_INPUT:
        // OSC 133 password-prompt detection → hold Carbon secure keyboard
        // input while the prompt is focused (macos-auto-secure-input).
        let mode = action.action.secure_input
        dispatchToView(userdata) { $0.applySecureInput(mode) }
        return true
    case GHOSTTY_ACTION_RING_BELL:
        // `\a` — bell-features decides audio/attention; no view state needed.
        dispatchToMain { handleBellRing() }
        return true
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
        // ⌘-hover enters/leaves a link (`link-previews` gates emission
        // core-side). len == 0 = left the link; copy before hopping main.
        let link = action.action.mouse_over_link
        let url: String? = link.len > 0 ? link.url.map { String(cString: $0) } : nil
        dispatchToView(userdata) { $0.onLinkHover?(url) }
        return true
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        // OSC 9 / OSC 777 — copy the core-owned strings BEFORE hopping main.
        let n = action.action.desktop_notification
        let title = n.title.map { String(cString: $0) } ?? ""
        let body = n.body.map { String(cString: $0) } ?? ""
        guard !title.isEmpty || !body.isEmpty else { return true }
        dispatchToView(userdata) { $0.onDesktopNotification?(title, body) }
        return true
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        // mouse-hide-while-typing: the core says hide on text keypress and
        // show on movement/scroll; setHiddenUntilMouseMoves matches — the OS
        // un-hides on motion even if a VISIBLE action never lands.
        let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
        dispatchToMain { NSCursor.setHiddenUntilMouseMoves(!visible) }
        return true
    default:
        return false
    }
}

/// Serves OSC 52 reads AND core-initiated pastes (the ⌘V/right-click text
/// path routes through `paste_from_clipboard` so `clipboard-paste-protection`
/// gets a look at the content). Reads the system pasteboard and answers via
/// `ghostty_surface_complete_clipboard_request`; if the core judges the
/// content risky it calls back through `confirm_read_clipboard` before
/// completing. Fires off-main; both the pasteboard read and the completion
/// hop to main (same rule as the write callback). The `state` pointer is a
/// core-owned request that stays valid until completed — transit as Int bits
/// like `dispatchToView`.
private let kookyReadClipboardCb: ghostty_runtime_read_clipboard_cb = { userdata, kind, state in
    guard kind == GHOSTTY_CLIPBOARD_STANDARD, let userdata, let state else { return false }
    let stateBits = Int(bitPattern: state)
    dispatchToView(userdata) { view in
        view.completeClipboardRequest(
            stateBits: stateBits,
            text: NSPasteboard.general.string(forType: .string) ?? "",
            confirmed: false
        )
    }
    return true
}

/// The core judged a clipboard read risky — an unsafe paste (newline into a
/// non-bracketed prompt, `clipboard-paste-protection`) or an OSC 52 read
/// needing authorization (`clipboard-read = ask`). Show a consent sheet;
/// BOTH outcomes must complete the request (deny = empty string) or the
/// core-side request object leaks (upstream `clipboardConfirmationComplete`
/// contract).
private let kookyConfirmReadClipboardCb: ghostty_runtime_confirm_read_clipboard_cb = { userdata, str, state, request in
    guard let userdata, let str, let state else { return }
    let contents = String(cString: str)
    let stateBits = Int(bitPattern: state)
    dispatchToView(userdata) { view in
        view.presentClipboardConfirmation(contents: contents, stateBits: stateBits, request: request)
    }
}

private let kookyWriteClipboardCb: ghostty_runtime_write_clipboard_cb = { userdata, kind, contents, count, confirm in
    guard kind == GHOSTTY_CLIPBOARD_STANDARD,
          let contents,
          count > 0
    else { return }
    // libghostty hands us multiple MIME variants of the same selection (e.g.
    // text/plain + text/html). Pick the plain-text variant; fall back to the
    // first entry. NEVER concatenate — they're alternative representations,
    // not separate lines.
    let buffer = UnsafeBufferPointer(start: contents, count: count)
    let preferred = buffer.first { entry in
        guard let mime = entry.mime else { return false }
        return String(cString: mime) == "text/plain"
    } ?? buffer.first
    guard let chosen = preferred, let dataPtr = chosen.data else { return }
    let text = String(cString: dataPtr)
    guard !text.isEmpty else { return }
    // `confirm` = `clipboard-write = ask`: an OSC 52 write needs user consent
    // before touching the pasteboard (it used to be silently dropped, so
    // `ask` behaved as `allow`). The core doesn't wait on write requests —
    // the host owns the dialog AND the write (upstream osc_52_write branch).
    if confirm, let userdata {
        dispatchToView(userdata) { view in
            view.presentClipboardWriteConfirmation(contents: text)
        }
        return
    }
    // libghostty fires this on its own thread; the write helper is main-only.
    dispatchToMain { writeToGeneralPasteboard(text) }
}
private let kookyCloseSurfaceCb: ghostty_runtime_close_surface_cb = { _, _ in }

// MARK: - LibghosttyEngine

@MainActor
final class LibghosttyEngine: TerminalEngine {
    private let surfaceView: GhosttySurfaceView

    var view: NSView { surfaceView }
    func renderNowIfNeeded() {
        surfaceView.renderNowIfNeeded()
    }
    var backgroundColor: NSColor { Theme.terminalSurface }
    var onPwdChange: ((String) -> Void)? {
        get { surfaceView.onPwdChange }
        set { surfaceView.onPwdChange = newValue }
    }
    var onTitleChange: ((String) -> Void)? {
        get { surfaceView.onTitleChange }
        set { surfaceView.onTitleChange = newValue }
    }
    var onFocus: (() -> Void)? {
        get { surfaceView.onFocus }
        set { surfaceView.onFocus = newValue }
    }
    var onCommandFinished: ((Int?, TimeInterval) -> Void)? {
        get { surfaceView.onCommandFinished }
        set { surfaceView.onCommandFinished = newValue }
    }
    var onUserInput: (() -> Void)? {
        get { surfaceView.onUserInput }
        set { surfaceView.onUserInput = newValue }
    }
    var onDesktopNotification: ((String, String) -> Void)? {
        get { surfaceView.onDesktopNotification }
        set { surfaceView.onDesktopNotification = newValue }
    }
    var onLinkHover: ((String?) -> Void)? {
        get { surfaceView.onLinkHover }
        set { surfaceView.onLinkHover = newValue }
    }
    var onProcessExitedCleanly: (() -> Void)? {
        get { surfaceView.onProcessExitedCleanly }
        set { surfaceView.onProcessExitedCleanly = newValue }
    }
    var onSearchStart: ((String) -> Void)? {
        get { surfaceView.onSearchStart }
        set { surfaceView.onSearchStart = newValue }
    }
    var onSearchEnd: (() -> Void)? {
        get { surfaceView.onSearchEnd }
        set { surfaceView.onSearchEnd = newValue }
    }
    var onSearchTotal: ((Int) -> Void)? {
        get { surfaceView.onSearchTotal }
        set { surfaceView.onSearchTotal = newValue }
    }
    var onSearchSelected: ((Int) -> Void)? {
        get { surfaceView.onSearchSelected }
        set { surfaceView.onSearchSelected = newValue }
    }
    var pasteUploadHostProvider: (() -> String?)? {
        get { surfaceView.pasteUploadHostProvider }
        set { surfaceView.pasteUploadHostProvider = newValue }
    }
    var isRemoteSessionProvider: (() -> Bool)? {
        get { surfaceView.isRemoteSessionProvider }
        set { surfaceView.isRemoteSessionProvider = newValue }
    }
    var foregroundPid: pid_t? { surfaceView.foregroundPid }

    init() {
        surfaceView = GhosttySurfaceView()
    }

    func start(config: TerminalSessionConfig) {
        // Surface creation is deferred to viewDidMoveToWindow: SwiftUI's
        // onAppear fires before the NSView has a window, and libghostty needs
        // both a window and real bounds to attach its Metal layer.
        surfaceView.pendingConfig = config
        surfaceView.createSurfaceIfReady()
    }

    func terminate() {
        surfaceView.releaseSurface()
    }

    var grabsFocusOnMount: Bool {
        get { surfaceView.grabsFocusOnMount }
        set { surfaceView.grabsFocusOnMount = newValue }
    }

    var spawnsWhileHidden: Bool {
        get { surfaceView.spawnsWhileHidden }
        set { surfaceView.spawnsWhileHidden = newValue }
    }

    var suspendsSizePropagation: Bool { surfaceView.suspendsSizePropagation }
    func beginSizePropagationSuspension() { surfaceView.beginSizePropagationSuspension() }
    func endSizePropagationSuspension() { surfaceView.endSizePropagationSuspension() }

    func flushSize() {
        surfaceView.flushPropagateSize()
    }

    @discardableResult
    func performAction(_ name: String) -> Bool {
        surfaceView.performAction(name)
    }

    func sendInput(_ text: String) {
        surfaceView.sendInput(text)
    }

    func readSelection() -> String? {
        surfaceView.readSelection()
    }

    func paste(_ text: String) {
        surfaceView.paste(text)
    }

    func pasteFromClipboardViaCore() -> Bool {
        surfaceView.pasteFromClipboardViaCore()
    }

    var needsConfirmQuit: Bool {
        guard let surface = surfaceView.surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }
}

// MARK: - GhosttySurfaceView

/// AppKit host view that libghostty renders into directly. The view's pointer
/// lives in `ghostty_surface_config_s.platform.macos.nsview`; libghostty owns
/// the Metal layer and draws into it.
@MainActor
final class GhosttySurfaceView: NSView {
    /// Vsync-aligned render driver. Replaces the old free-running 60Hz `Timer`,
    /// which presented off-vsync into the IOSurfaceLayer → beat-frequency judder
    /// + torn frames on a ProMotion (120Hz) display, most visible while scrolling
    /// a full-screen TUI (Claude Code / Codex) where every frame is a fresh full
    /// repaint (issue #29). The link self-pauses when there's nothing to draw and
    /// resumes on the next `GHOSTTY_ACTION_RENDER` (or a seed event), so an idle
    /// terminal costs zero GPU work.
    private var renderLink: CADisplayLink?
    /// Set by `GHOSTTY_ACTION_RENDER` and seeded after every surface mutation we
    /// drive ourselves (size / scale / config / first frame / focus). Read on each
    /// link tick: render exactly when dirty, otherwise pause until the next
    /// request. Writer and reader both end up on main, so a plain `Bool` is safe.
    private var needsRender = true
    private let scrollIndicator = ScrollIndicator()
    private var lastScrollbar: (total: UInt64, offset: UInt64, len: UInt64)?
    /// Whether the viewport is currently pinned to the bottom (latest output).
    /// Tracked from every SCROLLBAR action so `propagateSizeToSurface` can
    /// re-pin to the bottom after a resize without yanking a user who has
    /// scrolled up into scrollback. Starts true: a fresh surface whose content
    /// fits on screen is trivially at the bottom.
    private var viewportAtBottom = true

    /// ghostty's scrollbar `offset` is measured from the TOP (0 = top of
    /// scrollback); the viewport sits at the bottom (active area) when it spans
    /// down to the last row, i.e. `offset + len == total`. Content that fits on
    /// screen (`total <= len`) is trivially at the bottom.
    static func isViewportAtBottom(total: UInt64, offset: UInt64, len: UInt64) -> Bool {
        total <= len || offset + len >= total
    }

    /// Last backing scale we propagated to libghostty. libghostty captures the
    /// scale once at surface creation and never hears about display moves on
    /// its own, so we re-push it from `viewDidChangeBackingProperties`. Tracked
    /// so a colorspace-only backing change (same scale) doesn't fire a
    /// gratuitous resize. Seeded at surface creation.
    private var lastBackingScale: CGFloat?

    /// Last pixel size pushed to libghostty via `ghostty_surface_set_size`. Lets
    /// `propagateSizeToSurface` drop a redundant push of an identical size — each
    /// push is a SIGWINCH that thrashes the shell (conda scrollback-wipe +
    /// prompt-reflow flicker, issue #29 audit). Reset on surface teardown so a
    /// re-created surface always re-syncs.
    private var lastPushedSizePx: (UInt32, UInt32)?

    var pendingConfig: TerminalSessionConfig?
    /// Whether this session speaks the kitty keyboard protocol (CSI-u), the
    /// standard modern-TUI "newline instead of send". True for agent TUIs
    /// (omp, …); false for plain shells and Claude Code, which use the
    /// `\`+CR trick. Copied from the config at surface creation.
    var kittyProtocol = false
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onProcessExitedCleanly: (() -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    var onLinkHover: ((String?) -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var pasteUploadHostProvider: (() -> String?)?
    var isRemoteSessionProvider: (() -> Bool)?
    var currentDirectory: URL?
    var foregroundPid: pid_t? {
        guard let surface else { return nil }
        let pid = pid_t(ghostty_surface_foreground_pid(surface))
        return pid > 0 ? pid : nil
    }
    /// Key-window transition observers for the current window — secure input
    /// must drop when the password prompt's window loses key (its
    /// firstResponder survives, so become/resign can't tell us).
    private var keyWindowObservers: [NSObjectProtocol] = []

    /// Read in `viewDidMoveToWindow` to gate the mount-time first-responder
    /// grab; set by `TerminalTabHost` from the pane's active state. See
    /// `TerminalEngine.grabsFocusOnMount` for why this remains a mount-time
    /// gate (issue #24).
    var grabsFocusOnMount = true

    /// `TerminalEngine.spawnsWhileHidden` — exempts createSurfaceIfReady's
    /// hidden gate so a CLI background tab's shell starts without ever being
    /// shown (issue #59). Render gating (`updateRenderLink`) deliberately
    /// does NOT consult this: the surface exists and streams, but a hidden
    /// view still draws nothing.
    var spawnsWhileHidden = false

    private(set) var surface: ghostty_surface_t? {
        didSet {
            // force: a fresh surface must be sized even if the pixel size matches
            // what a prior surface on this view was last sent (dedup would skip).
            if surface != nil { propagateSizeToSurface(force: true) }
            updateRenderLink()
        }
    }
    /// In-progress IME preedit string. `setMarkedText` writes it,
    /// `unmarkText` / `insertText` clear it. Mirrors ghostty.app's
    /// `markedText` field — `hasMarkedText() = !markedText.isEmpty`,
    /// load-bearing for keyDown's Enter / arrow / Esc gating while a
    /// candidate window is open.
    private var markedText: String = ""
    /// Non-nil signals "we're inside `keyDown`'s `handleEvent` call".
    /// IME callbacks during that window batch into here instead of
    /// pushing each transient state straight to libghostty — without
    /// batching, libghostty receives a noisy sequence of preedit /
    /// clear / commit for every keystroke and leaves stray cells on
    /// long sequences (the v0.11.4 `\u{3000}`-looking phantom space
    /// between 发's). Cleared by keyDown's `defer`. Mirrors ghostty's
    /// `keyTextAccumulator` pattern verbatim.
    private var keyTextAccumulator: [String]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ScrollIndicator.install(scrollIndicator, in: self)
        updateTrackingAreas()
        wireScrollDrag()
        // Accept Finder-style file drops — the user drags a file or folder
        // onto the terminal pane and we inject its backslash-escaped
        // absolute path (or paths, space-separated) as if it were pasted.
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL]) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let escaped = KookyShellIntegration.backslashEscapedFileURLs(urls)
        else { return false }
        paste(escaped)
        return true
    }

    private func wireScrollDrag() {
        scrollIndicator.onDragKnobTo = { [weak self] desiredPosition in
            guard let self, let surface = self.surface,
                  let last = self.lastScrollbar,
                  last.total > last.len
            else { return }
            let maxOffset = last.total - last.len
            let desiredOffset = UInt64(Double(maxOffset) * (1.0 - desiredPosition))
            let lineDelta = Int64(last.offset) - Int64(desiredOffset)
            guard lineDelta != 0 else { return }
            ghostty_surface_mouse_scroll(surface, 0, Double(lineDelta), 0)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // `.activeWhenFirstResponder` keeps non-focused panes from receiving
        // mouseMoved and stomping on the focused surface's hover (it also
        // keeps their `cursorUpdate` from painting a stale cached shape the
        // core has no way to correct). focus-follows-mouse lives at the
        // SwiftUI layer — `PaneView.onHover` covers the whole pane including
        // this surface's frame, since tracking areas are geometric and a
        // child NSView doesn't occlude the hosting view's.
        // `.cursorUpdate` lets us re-apply `currentCursor` whenever the mouse
        // re-enters the surface — libghostty's `MOUSE_SHAPE` action only fires
        // when the shape *changes*, so without this the I-beam → pointer
        // transition wouldn't recover after the cursor briefly leaves.
        let options: NSTrackingArea.Options = [
            .activeWhenFirstResponder, .mouseMoved, .cursorUpdate, .inVisibleRect,
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    private var currentCursor: NSCursor = .iBeam

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    /// Map libghostty's `ghostty_action_mouse_shape_e` to an `NSCursor` and
    /// apply it. Skip the `.set()` syscall when the cursor hasn't changed —
    /// libghostty's contract is "fires on shape change" but defensive callers
    /// can repeat the same shape and we shouldn't churn AppKit.
    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_MOVE: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY: cursor = .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: cursor = .dragLink
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        guard currentCursor !== cursor else { return }
        currentCursor = cursor
        cursor.set()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // No deinit: Swift 6's nonisolated deinit can't touch @MainActor state.
    // Teardown is the explicit `releaseSurface()` path, called from
    // `LibghosttyEngine.terminate()` when a session is closed.

    func releaseSurface() {
        guard let dying = surface else { return }
        // Despite the C API's `foreground_pid` name, libghostty returns the
        // PTY's `tcgetpgrp` value. An interactive shell puts its foreground
        // agent job in this separate process group, outside the shell group
        // covered by native surface teardown.
        let foreground = ghostty_surface_foreground_pid(dying)
        let foregroundProcessGroup = foreground > 0 && foreground <= UInt64(pid_t.max)
            ? pid_t(foreground)
            : nil
        // Deregister from secure input BEFORE freeing — a surface closed at a
        // password prompt must not strand the process-wide Carbon flag.
        passwordInput = false
        // Null first so any guard-on-surface check post-free sees the cleared
        // state immediately; the local `dying` keeps the handle for free.
        surface = nil
        lastPushedSizePx = nil
        let retainedHostBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())
        SurfaceTeardownCoordinator.shared.enqueue(
            surfaceBits: UInt(bitPattern: dying),
            foregroundProcessGroup: foregroundProcessGroup,
            retainedHostBits: retainedHostBits
        )
    }

    /// Whether the PTY is at a password prompt (core's OSC 133 detection).
    /// Registration with the process-wide secure-input holder tracks this
    /// flag AND real keyboard ownership — the Carbon flag should only be
    /// held while the password prompt is actually receiving keystrokes.
    var passwordInput = false {
        didSet {
            guard passwordInput != oldValue else { return }
            syncSecureInputHolding()
        }
    }

    /// The one derivation of "does this surface own the keyboard": first
    /// responder in ITS window, and that window is the key window — another
    /// kooky window / Settings / a sheet keeps its own firstResponder, so
    /// key-ness is what distinguishes "receiving keystrokes" from "parked"
    /// (Codex review: a non-key password prompt must not hold the
    /// process-wide flag while the user types elsewhere).
    private func syncSecureInputHolding() {
        KookySecureInput.shared.setHolding(
            ObjectIdentifier(self),
            passwordInput
                && window?.firstResponder === self
                && (window?.isKeyWindow ?? false)
        )
    }

    /// The config gate only blocks ENTERING the password state — OFF always
    /// lands, so flipping `macos-auto-secure-input` off mid-prompt can't
    /// strand a stale ON that re-enables on the next focus (Codex review).
    /// A surface already ON when the setting flips keeps protection until
    /// its own OFF arrives (the prompt ends) — accepted residual window.
    func applySecureInput(_ mode: ghostty_action_secure_input_e) {
        switch mode {
        case GHOSTTY_SECURE_INPUT_OFF:
            passwordInput = false
        case GHOSTTY_SECURE_INPUT_ON:
            guard LibghosttyApp.shared.hostConfig.autoSecureInput else { return }
            passwordInput = true
        case GHOSTTY_SECURE_INPUT_TOGGLE:
            if passwordInput {
                passwordInput = false
            } else if LibghosttyApp.shared.hostConfig.autoSecureInput {
                passwordInput = true
            }
        default: break
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-subscribe key-window transitions for the CURRENT window: a
        // window losing key keeps its firstResponder, so become/resign never
        // fire — these notifications are the only signal that a password
        // prompt's surface stopped (or resumed) owning the keyboard.
        keyWindowObservers.forEach(NotificationCenter.default.removeObserver)
        keyWindowObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyWindowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncSecureInputHolding() }
                })
            }
        }
        syncSecureInputHolding()
        if window != nil {
            // A pre-existing surface means the view re-entered a window
            // (cross-window tab move) rather than being created fresh:
            // createSurfaceIfReady no-ops and surface.didSet won't re-push the
            // size, so we owe an explicit re-sync (issue #8). Deferred because
            // at adoption time the destination leaf's layout hasn't sized this
            // view yet — push once the turn settles so the surface relearns
            // final geometry. force: the frame may be numerically unchanged
            // across the move, which the pixel-dedup would otherwise skip.
            // No focus handling here: `PaneTreeHostView.syncFocus` is the one
            // keyboard authority (the old per-view mount-grab raced, issue #24).
            let reattaching = surface != nil
            createSurfaceIfReady()
            // Defer until after SwiftUI's hosting finishes its current event
            // loop pass, otherwise the originating button click reclaims focus.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                // Only the active pane grabs focus on (re)mount — otherwise
                // sibling panes' surfaces race and the last mount wins
                // (issue #24). Size re-sync below runs regardless of focus.
                // Hidden = a background workspace's container (C2 keeps every
                // workspace mounted). A surface that isn't visible must never
                // take the keyboard, whatever its pane-level flag says —
                // engine-side belt for the view-layer condition (Codex P1).
                if self.grabsFocusOnMount, !self.isHiddenOrHasHiddenAncestor {
                    window.makeFirstResponder(self)
                }
                // Re-sync size on reattach (cross-pane / cross-window tab
                // moves): propagateSizeToSurface no-ops while detached, and an
                // unchanged-frame reattach fires neither backing-properties
                // nor setFrameSize callbacks. force: the pixel-dedup would
                // otherwise skip the unchanged size libghostty must relearn
                // (issue #8).
                if reattaching { self.propagateSizeToSurface(force: true) }
            }
        }
        updateRenderLink()
    }

    /// Mark the surface dirty and wake the render link so the next vsync presents
    /// the new frame. Idempotent and cheap — call it from `GHOSTTY_ACTION_RENDER`
    /// and after any surface mutation we initiate, so a frame is never stranded
    /// waiting for an action that may have already fired before the link ran.
    func setNeedsRender() {
        needsRender = true
        renderLink?.isPaused = false
    }

    /// Present the active surface immediately instead of waiting for the next vsync.
    func renderNowIfNeeded() {
        guard let surface, !isHiddenOrHasHiddenAncestor else { return }
        needsRender = false
        ghostty_surface_render_now(surface)
    }

    /// Render link runs only when the surface exists, the view is in a window,
    /// AND it's actually visible. Background tabs / workspaces stay mounted
    /// (the AppKit pane host switches by `isHidden`, never by detaching), so
    /// the hidden check is what keeps an invisible streaming terminal at zero
    /// GPU — the same guarantee the old detach-on-switch world had.
    /// `setNeedsRender()` still latches while hidden; the first tick after
    /// unhide presents the accumulated state.
    private func updateRenderLink() {
        if surface != nil, window != nil, !isHiddenOrHasHiddenAncestor {
            startRenderLink()
        } else {
            stopRenderLink()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRenderLink()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        // Surfaces are created lazily on first *reveal* (not first mount):
        // a restored background tab must not spawn its shell + Metal surface
        // until the user actually switches to it — the same laziness the old
        // detached-view world provided. (One exemption: `spawnsWhileHidden`,
        // CLI background tabs — those views arrive here with the surface
        // already created, so this call no-ops.)
        createSurfaceIfReady()
        // A hidden tab may have missed geometry changes. Re-sync only when it
        // becomes visible, avoiding background SIGWINCH while preserving the
        // first visible frame's dimensions.
        if surface != nil { propagateSizeToSurface(force: true) }
        updateRenderLink()
    }

    func createSurfaceIfReady() {
        guard surface == nil,
              let window,
              !isHiddenOrHasHiddenAncestor || spawnsWhileHidden,
              let config = pendingConfig,
              let app = LibghosttyApp.shared.app
        else { return }

        let scale = Double(window.backingScaleFactor)
        // Pin contentsScale so Core Animation doesn't double-scale ghostty's
        // already-pixel-correct render.
        layer?.contentsScale = scale
        // Seed so the first viewDidChangeBackingProperties on this display is a
        // no-op; only a real cross-display scale change re-pushes (issue #8).
        lastBackingScale = window.backingScaleFactor

        let workingDir = config.workingDirectory ?? NSHomeDirectory()
        currentDirectory = URL(fileURLWithPath: workingDir)
        // This is the moment the process is actually born — a restored tab's
        // config may have been built days ago (issue #45 Codex P2: a bash
        // launcher path cached in `pendingConfig` outlives the $TMPDIR
        // cleanup). Rewrite every shell's bridge so the cached paths are live.
        KookyShellIntegration.ensureSpawnBridges()
        // Merge our wrapper ZDOTDIR into the caller's env dict. AgentTemplate
        // populates KOOKY_AGENT here so the wrapper .zshrc auto-launches the
        // selected CLI before the user ever sees a shell prompt. nil = the
        // bridge rc couldn't be (re)written; skip the injection so zsh loads
        // the user's real rc chain instead of a dead ZDOTDIR (issue #45).
        var envDict = config.environment
        if let zshDirectory = KookyShellIntegration.zshDirectory {
            envDict[KookyShellIntegration.zdotdirKey] = zshDirectory
        }
        // Dynamic count of env entries — strdup each, free after surface_new.
        // libghostty copies the strings during init, so the lifetime only needs
        // to span the call below.
        let envCStrings = envDict.flatMap { (k, v) -> [UnsafeMutablePointer<CChar>] in
            [strdup(k)!, strdup(v)!]
        }
        defer { envCStrings.forEach { free($0) } }
        var envVars = stride(from: 0, to: envCStrings.count, by: 2).map { i in
            ghostty_env_var_s(key: envCStrings[i], value: envCStrings[i + 1])
        }

        let new: ghostty_surface_t? = workingDir.withCString { wdPtr in
            // command is populated by TerminalSessionConfig.defaultShell() — bypass
            // /usr/bin/login so we don't get a "Last login:…" line each session.
            config.command.withCString { cmdPtr in
                var surfaceConfig = ghostty_surface_config_new()
                surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
                surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
                // Userdata lets the @convention(c) action callback recover the
                // originating Swift view from a surface-scoped event.
                surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
                surfaceConfig.scale_factor = scale
                surfaceConfig.working_directory = wdPtr
                surfaceConfig.command = cmdPtr
                return envVars.withUnsafeMutableBufferPointer { buf in
                    surfaceConfig.env_vars = buf.baseAddress
                    surfaceConfig.env_var_count = buf.count
                    return ghostty_surface_new(app, &surfaceConfig)
                }
            }
        }

        guard let new else {
            NSLog("kooky: ghostty_surface_new failed")
            return
        }
        surface = new
        pendingConfig = nil
        kittyProtocol = config.kittyProtocol
        // A fresh surface's conditional state defaults to LIGHT — seed it with
        // kooky's active theme so the 996 query / mode 2031 / conditional
        // themes are right from the first prompt, and register for the
        // per-surface fan-out on later theme switches.
        GhosttySurfaceRegistry.add(self)
        ghostty_surface_set_color_scheme(new, LibghosttyApp.currentColorScheme)
        ghostty_surface_refresh(new)
    }

    private func startRenderLink() {
        guard renderLink == nil else {
            // Already running (e.g. a workspace-switch remount) — just make sure
            // the first frame back on screen actually draws.
            setNeedsRender()
            return
        }
        // `NSView.displayLink(target:selector:)` (macOS 14+) is the only display
        // link variant that auto-retargets to whichever display the view occupies
        // and follows the window across displays (Retina 120Hz ↔ external 60Hz),
        // so we never hand-track `NSScreen.maximumFramesPerSecond`. The frame-rate
        // range lets ProMotion run up to 120 while the system throttles for power.
        let link = displayLink(target: self, selector: #selector(renderTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        renderLink = link
        setNeedsRender()
    }

    private func stopRenderLink() {
        renderLink?.invalidate()
        renderLink = nil
    }

    /// Vsync tick — render exactly when there's a pending change, otherwise pause
    /// the link so an idle terminal costs nothing. Runs on main (the link is added
    /// to `RunLoop.main`); `render_now` is the synchronous encode+present, so it
    /// must run inline here — deferring it through a `Task` would re-add the
    /// one-frame phase error this whole change exists to remove (issue #29).
    @objc private func renderTick(_ link: CADisplayLink) {
        guard let surface else { return }
        guard needsRender else {
            // Nothing pending — sleep until the next setNeedsRender() wakes us.
            // Any source that changes pixels (RENDER action, resize, focus) also
            // un-pauses, so we can never strand a frame here.
            link.isPaused = true
            return
        }
        needsRender = false
        ghostty_surface_render_now(surface)
    }

    override var acceptsFirstResponder: Bool { true }

    /// Refcount of active size-propagation suspenders — pane zoom, status-bar
    /// height change, split-divider drag can overlap. Per-frame `setFrameSize` /
    /// `viewDidEndLiveResize` skip the SIGWINCH-propagating `ghostty_surface_set_size`
    /// while this is > 0; each owner pushes one final size via `flushPropagateSize`
    /// after its `end`. A plain shared Bool let a second owner's un-suspend clobber
    /// a first owner's still-active suspend mid-interaction (issue #29 review); the
    /// count composes N overlapping owners so suspension holds until the LAST ends.
    private var sizePropagationSuspendCount = 0
    var suspendsSizePropagation: Bool { sizePropagationSuspendCount > 0 }
    func beginSizePropagationSuspension() { sizePropagationSuspendCount += 1 }
    func endSizePropagationSuspension() { sizePropagationSuspendCount = max(0, sizePropagationSuspendCount - 1) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // AppKit calls this whenever this view's own frame changes — single
        // canonical hook (the legacy `resizeSubviews(withOldSize:)` would
        // double-propagate). Two paths defer the libghostty push rather than fire
        // it per frame:
        //  • suspendsSizePropagation — pane-zoom animation; flushPropagateSize
        //    settles it.
        //  • window live-resize — a window-edge drag fires setFrameSize on every
        //    frame, each a set_size → SIGWINCH, thrashing the shell (conda
        //    scrollback wipe + prompt-reflow flicker, issue #29 audit).
        //    viewDidEndLiveResize pushes once with the final size.
        if suspendsSizePropagation { return }
        if window?.inLiveResize == true { return }
        propagateSizeToSurface()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // If a pane-zoom / status-bar animation is mid-flight, its own flush
        // (after the suspend window clears) is the authoritative settle — don't
        // leak a set_size here inside the very window the suspend exists to
        // silence (the drag has ended by then, so that flush is no longer gated).
        if suspendsSizePropagation { return }
        // Push the final size once the window-drag settles. Pixel-dedup makes a
        // drag that returns to the original size a no-op, so the shell sees at
        // most ONE SIGWINCH per resize (a genuine cell-count change) instead of
        // the per-frame burst.
        propagateSizeToSurface()
    }

    func flushPropagateSize() {
        // If a window-edge live-resize is in progress, defer to viewDidEndLiveResize
        // for the settle — pushing here would leak a set_size mid-drag (the exact
        // SIGWINCH the live-resize defer exists to suppress). The drag-end push
        // re-syncs the final size regardless.
        if window?.inLiveResize == true { return }
        // force: the pane-zoom path suspended per-frame pushes during the
        // animation, so libghostty may be a frame behind; re-sync unconditionally
        // even if the settled pixel size matches the last one we sent.
        propagateSizeToSurface(force: true)
    }

    /// Fires when the window moves to a display with a different backing scale
    /// (e.g. a Retina laptop screen → a 1x external monitor) — or on a
    /// colorspace change. libghostty captured the scale at surface creation and
    /// has no other way to learn the window changed displays; left stale, it
    /// keeps sizing the cell grid at the old DPI while receiving the new
    /// display's pixel dimensions, so the grid no longer fills the surface — a
    /// blank gutter on the right and input overflowing the viewport (issue #8).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        // Skip colorspace-only changes (same scale) so we don't fire a
        // gratuitous set_size → SIGWINCH (conda scrollback-wipe known issue).
        guard scale != lastBackingScale else { return }
        lastBackingScale = scale
        layer?.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        // A scale change already shifts the pixel size (px = points × scale) so
        // the dedup wouldn't skip it; force is belt-and-suspenders so the grid is
        // guaranteed to relearn the new DPI (issue #8) right after set_content_scale.
        propagateSizeToSurface(force: true)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            if let surface { ghostty_surface_set_focus(surface, true); setNeedsRender() }
            // Explicit, not syncSecureInputHolding(): AppKit hasn't set
            // window.firstResponder to self yet inside becomeFirstResponder.
            // Key-ness still gates; if the window becomes key a beat later,
            // the didBecomeKey observer re-syncs.
            KookySecureInput.shared.setHolding(
                ObjectIdentifier(self),
                passwordInput && (window?.isKeyWindow ?? false)
            )
            onFocus?()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if let surface {
                ghostty_surface_set_focus(surface, false)
                setNeedsRender()
            }
            KookySecureInput.shared.setHolding(ObjectIdentifier(self), false)
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        let mods = event.modifierFlags
        let cmd = mods.contains(.command)
        let cmdOnly = cmd && mods.intersection([.shift, .control, .option]).isEmpty

        // Cmd+V: read the system pasteboard directly and inject as text via
        // the paste path so bracketed-paste mode wraps it correctly. The
        // right-click Paste menu shares the same path via `paste(_:)`.
        // `readTerminalPasteText` covers fileURLs (Finder Copy → full
        // path, not bare filename) and raw image data (screenshots →
        // spilled to a cache PNG so agents can open it as a path).
        if cmdOnly, event.charactersIgnoringModifiers?.lowercased() == "v" {
            // One entry owns the whole tier ladder: remote upload for SSH
            // workspaces, off-main transcode for clipboard images, escaped
            // paths for files — and plain text handed to the core's protected
            // paste path (clipboard-paste-protection).
            if KookyShellIntegration.paste(
                from: .general,
                host: pasteUploadHostProvider?(),
                plainText: .viaCore({ [weak self] in self?.pasteFromClipboardViaCore() ?? false }),
                deliver: { [weak self] in self?.paste($0) }
            ) {
                return
            }
        }

        // Cmd+C with a live selection — without this branch libghostty's
        // bypassed keybinding system would leave Cmd+C dead.
        if cmdOnly,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           ghostty_surface_has_selection(surface)
        {
            performCopy()
            return
        }

        // macOS Cocoa text-edit shortcuts → the control bytes readline / zsh
        // ZLE already bind. Without this Cmd combos get swallowed by the
        // responder chain, and libghostty's default Option+Delete sequence
        // isn't what most shells recognise.
        if cmdOnly {
            switch event.keyCode {
            case 123: sendInputBytes("\u{01}", to: surface); return  // Cmd+← → ^A
            case 124: sendInputBytes("\u{05}", to: surface); return  // Cmd+→ → ^E
            case 51:  sendInputBytes("\u{15}", to: surface); return  // Cmd+⌫ → ^U
            default:  break
            }
        }
        if mods.contains(.option), !cmd, !mods.contains(.control), event.keyCode == 51 {
            sendInputBytes("\u{17}", to: surface)                    // Option+⌫ → ^W
            return
        }

        // Any other Cmd+combo: hand off to AppKit's responder chain so menu
        // key equivalents (Cmd+W close, Cmd+T new tab — when M4 wires them)
        // can fire instead of being swallowed by the PTY.
        if cmd {
            super.keyDown(with: event)
            return
        }

        // Cursor keys are mode-aware: after a TUI enables DECCKM (`smkx`),
        // libghostty must switch them from CSI (`ESC [ A`) to SS3
        // (`ESC O A`). Route the physical key event through libghostty so
        // old terminfo-strict programs (vim 7.2 on CentOS 6, etc.) see the
        // active mode instead of kooky hard-coding CSI forever. If libghostty
        // declines the key — shouldn't happen for a focused surface — fall
        // back to the CSI form; a non-mode-aware arrow still beats a dead one.
        if !hasMarkedText(),
           Self.shouldForwardModeAwareKeyToLibghostty(keyCode: event.keyCode, modifierFlags: mods) {
            if !sendKey(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface),
               let bytes = Self.handWrittenEscapeSequence(forKeyCode: event.keyCode, modifierFlags: mods, newlineModifier: KookySettingsModel.shared.composerNewlineModifier.flag,
                          kittyProtocol: kittyProtocol) {
                sendInputBytes(bytes, to: surface)
            }
            return
        }

        // Kooky-specific functional keys with explicit byte behavior. Skipped
        // while IME is composing so Enter / Esc / arrows can dismiss / accept
        // the candidate window without leaking through to the PTY.
        if !hasMarkedText(),
           let bytes = Self.handWrittenEscapeSequence(forKeyCode: event.keyCode, modifierFlags: mods, newlineModifier: KookySettingsModel.shared.composerNewlineModifier.flag,
                          kittyProtocol: kittyProtocol) {
            sendInputBytes(bytes, to: surface)
            return
        }

        // No pre-IME Ctrl fast path on purpose: the IME gets first dibs on
        // every key (some IMEs bind non-composing Ctrl combos — Rime's
        // Ctrl+`), and a Ctrl combo it produces no text for is sent from the
        // empty-accumulator branch below. The old raw-byte path covered only
        // AppKit-pre-translated Ctrl+letter, leaving Ctrl+Space / Ctrl+digit
        // / Ctrl+punctuation dead (issue #54).

        // Regular text + IME composition. inputContext routes through
        // NSTextInputClient: insertText for committed input, setMarkedText
        // for in-progress composition. We batch all IME effects via
        // keyTextAccumulator so libghostty sees one atomic preedit-sync
        // + one text-commit per keystroke instead of per-IME-callback —
        // critical for CJK composition where rapid transient preedit
        // states otherwise leak phantom cells.
        //
        // The IME must translate with the mods libghostty says participate in
        // text translation — `macos-option-as-alt` strips Option here, so a
        // configured Left Option+Z translates to "z" (which the key encoder
        // turns into ESC z) instead of macOS's Ω (issue #46). When the mods
        // are unchanged we MUST reuse the original event object: AppKit does
        // object-identity tracking somewhere and a rebuilt event breaks
        // Korean-style IMEs (upstream SurfaceView_AppKit keyDown comment).
        let translationGhosttyMods = Self.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(surface, Self.mapModifiers(mods))
        )
        var translationMods = mods
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhosttyMods.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }
        let translationEvent: NSEvent
        if translationMods == mods {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }
        let hadMarkedTextBefore = !markedText.isEmpty
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        inputContext?.handleEvent(translationEvent)
        // Only sync preedit when there's a state change to communicate.
        // Sending `ghostty_surface_preedit(nil, 0)` on every keystroke
        // (including pure ASCII typing) was confusing libghostty's wrap
        // accounting on long lines — once the line wrapped, the original
        // first row would scroll out of view as if the surface were only
        // a few rows tall.
        syncPreedit(clearIfNeeded: hadMarkedTextBefore)
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                sendKeyText(text, event: event, translationMods: translationMods, to: surface)
            }
        } else if mods.contains(.control), !hasMarkedText(), !hadMarkedTextBefore {
            // The IME produced no text for a Ctrl combo — the normal case
            // outside composition. Send the full key event so libghostty's
            // encoder owns the bytes (its ctrlSeq table: Ctrl+Space → NUL,
            // Ctrl+3 → ESC, …) and kitty sessions get CSI-u (issue #54).
            // Keys `handWrittenEscapeSequence` claims (Ctrl+Enter/Tab/
            // arrows/F1-12) are intercepted above and never reach here.
            // Scoped to Ctrl on purpose — every other empty-accumulator
            // keystroke still sends nothing (the v0.45.7 containment
            // stands; widening also means plumbing `composing` through
            // makeKeyEvent and porting upstream's composing-control
            // suppression, not just dropping this guard). The marked-text
            // guards keep composition-adjacent Ctrl combos (Japanese
            // Ctrl+H deleting a preedit char) with the IME.
            if !sendKey(event: event, action: GHOSTTY_ACTION_PRESS, translationMods: translationMods,
                        text: Self.keyEventText(for: event, translationMods: translationMods), surface: surface),
               let fallback = Self.legacyControlBytes(unshiftedCodepoint: Self.unshiftedCodepoint(of: event)) {
                sendInputBytes(fallback, to: surface)
            }
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if !markedText.isEmpty {
            markedText.withCString { cstr in
                ghostty_surface_preedit(surface, cstr, UInt(strlen(cstr)))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// Commits text from an IME composition or AppKit text-input session through
    /// libghostty's key-event API. We do this instead of `ghostty_surface_text_input`
    /// because the key-event path keeps cursor/wrap accounting in sync with how
    /// libghostty's grid expects user-driven keystrokes to advance; `text_input`
    /// is a lower-level injection that miscalculates wrap on long multi-byte
    /// sequences. Control bytes (< 0x20) still go through `text_input`: an
    /// encoder key event would re-encode the physical key, not the byte the
    /// IME committed (deliberately untouched by issue #54's encoder routing).
    /// Mirrors ghostty.app's `committedPreeditTextAction` pattern.
    /// `event` + `translationMods` (keyDown's batched path) attach the real
    /// key identity to the committed text: keycode, real mods (sided bits
    /// included), and consumed_mods = the mods the IME translation actually
    /// consumed. That trio is what lets libghostty's key encoder implement
    /// `macos-option-as-alt` — Alt in `mods` but absent from `consumed_mods`
    /// means "not consumed by translation" → encode ESC-prefix instead of the
    /// translated character (issue #46). Callers outside keyDown (mouse-click
    /// candidate commit) pass no event and keep the bare-text shape, mirroring
    /// ghostty.app's `committedPreeditTextAction`.
    private func sendKeyText(
        _ text: String,
        event: NSEvent? = nil,
        translationMods: NSEvent.ModifierFlags? = nil,
        to surface: ghostty_surface_t
    ) {
        guard !text.isEmpty else { return }
        if let first = text.utf8.first, first < 0x20 {
            sendInputBytes(text, to: surface)  // control byte → fires onUserInput there
            return
        }
        // Visible typed text is the start of the next command — clear a stale
        // command-failure dot (libghostty exposes no command-START signal). The
        // control-byte branch above routes through sendInputBytes, which fires
        // its own onUserInput, so only this visible-text path needs one here.
        onUserInput?()
        // Nil event (mouse-click candidate commit) keeps the bare zeroed shape.
        var key_ev = event.map { Self.makeKeyEvent(for: $0, translationMods: translationMods) }
            ?? ghostty_input_key_s()
        key_ev.action = GHOSTTY_ACTION_PRESS
        Self.send(key_ev, text: text, to: surface)
    }

    private func sendInputBytes(_ bytes: String, to surface: ghostty_surface_t) {
        // Chokepoint for input delivered as raw bytes — Return / Tab /
        // function keys (handWrittenEscapeSequence), the Cocoa edit shortcuts
        // (Cmd+←/→/⌫, Option+⌫), pill injection (sendInput), IME-committed
        // control bytes (sendKeyText), and the two declined-key fallbacks.
        // All start the next command, so clear a stale failure dot here once
        // rather than at each caller. Encoder-routed keys (`sendKey`) and
        // paste (`ghostty_surface_text`) fire it at their own sites.
        onUserInput?()
        bytes.withCString { cstr in
            ghostty_surface_text_input(surface, cstr, UInt(strlen(cstr)))
        }
    }

    func sendInput(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Pill-injected commands (nvm use, git checkout, unset proxy) are the
        // next command too; sendInputBytes fires onUserInput to clear the dot.
        sendInputBytes(text, to: surface)
    }

    /// Physical keys whose output depends on libghostty's terminal mode state.
    /// Keep these out of `handWrittenEscapeSequence`: hard-coded CSI cursor
    /// bytes break applications that requested application cursor keys.
    nonisolated static func shouldForwardModeAwareKeyToLibghostty(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else {
            return false
        }
        switch keyCode {
        case 123, 124, 125, 126: return true  // left, right, down, up
        default: return false
        }
    }

/// Map kooky's own functional-key policy to bytes. Returns `nil` for
/// normal text and mode-aware physical keys that must go through
/// `ghostty_surface_key`.
nonisolated static func handWrittenEscapeSequence(
    forKeyCode code: UInt16,
    modifierFlags mods: NSEvent.ModifierFlags,
    newlineModifier: NSEvent.ModifierFlags = .shift,
    kittyProtocol: Bool = false
) -> String? {
    let modDigit = csiModifierDigit(shift: mods.contains(.shift),
                                    alt: mods.contains(.option),
                                    ctrl: mods.contains(.control))

    switch code {
    // Functional
    case 36, 76:
        // Return / keypad Return (76).
        //
        // kitty-protocol TUIs (omp, cmux) recognize "newline instead of send"
        // ONLY as Shift+Enter's CSI-u (`ESC[27;2;13~`) — omp doesn't honor a
        // different modifier's CSI-u. So the user's configured newline combo
        // is remapped onto that sequence: whatever combo they picked sends
        // `ESC[27;2;13~` and omp newlines. Every OTHER Return — plain Enter,
        // or a different modifier combo — just sends `\r` (the "send" key).
        // It must NOT return nil here: a nil falls through to the IME/text
        // branch below, which swallows the key and leaves Enter dead.
        if kittyProtocol {
            return mods.contains(newlineModifier) ? "\u{1B}[27;2;13~" : "\r"
        }
        // Otherwise (zsh line-continuation, Claude Code's documented `\` +
        // Enter trick) the configured newline combo sends `\` then CR;
        // `\n` alone is useless: ZLE binds it to accept-line.
        return mods.contains(newlineModifier) ? "\\\r" : "\r"
        case 48:  return mods.contains(.shift) ? "\u{1B}[Z" : "\t"  // Tab / Shift+Tab
        case 51:  return "\u{7F}"                          // Backspace (DEL)
        case 53:  return "\u{1B}"                          // Escape

        // Modified arrows (`ESC [ 1;m x`) resolve here. Unmodified arrows are
        // routed through `ghostty_surface_key` in `keyDown` so libghostty
        // picks CSI vs SS3 per DECCKM; these `csiArrow` forms are also that
        // path's fallback if libghostty declines the key.
        case 123: return csiArrow("D", modDigit: modDigit)
        case 124: return csiArrow("C", modDigit: modDigit)
        case 125: return csiArrow("B", modDigit: modDigit)
        case 126: return csiArrow("A", modDigit: modDigit)

        // Control pad
        case 115: return csiArrow("H", modDigit: modDigit)  // Home
        case 119: return csiArrow("F", modDigit: modDigit)  // End
        case 116: return csiTilde("5", modDigit: modDigit)  // Page Up
        case 121: return csiTilde("6", modDigit: modDigit)  // Page Down
        case 117: return csiTilde("3", modDigit: modDigit)  // Forward Delete
        case 114: return csiTilde("2", modDigit: modDigit)  // Help / Insert

        // Function keys
        case 122: return ssFnKey("P", modDigit: modDigit)   // F1
        case 120: return ssFnKey("Q", modDigit: modDigit)   // F2
        case 99:  return ssFnKey("R", modDigit: modDigit)   // F3
        case 118: return ssFnKey("S", modDigit: modDigit)   // F4
        case 96:  return csiTilde("15", modDigit: modDigit) // F5
        case 97:  return csiTilde("17", modDigit: modDigit) // F6
        case 98:  return csiTilde("18", modDigit: modDigit) // F7
        case 100: return csiTilde("19", modDigit: modDigit) // F8
        case 101: return csiTilde("20", modDigit: modDigit) // F9
        case 109: return csiTilde("21", modDigit: modDigit) // F10
        case 103: return csiTilde("23", modDigit: modDigit) // F11
        case 111: return csiTilde("24", modDigit: modDigit) // F12

        default:  return nil
        }
    }

    /// CSI modifier digit: 2 = Shift, 3 = Alt, 4 = Shift+Alt, 5 = Ctrl, … 8.
    /// Returns nil when no modifier is set so the unmodified sequence is used.
    nonisolated private static func csiModifierDigit(shift: Bool, alt: Bool, ctrl: Bool) -> Int? {
        let mask = (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        return mask == 0 ? nil : mask + 1
    }

    nonisolated private static func csiArrow(_ final: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[1;\(m)\(final)" }
        return "\u{1B}[\(final)"
    }

    nonisolated private static func csiTilde(_ number: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[\(number);\(m)~" }
        return "\u{1B}[\(number)~"
    }

    nonisolated private static func ssFnKey(_ final: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[1;\(m)\(final)" }
        return "\u{1B}O\(final)"
    }

    /// Last-resort byte for a Ctrl combo `ghostty_surface_key` returned false
    /// for. Strictly, false means the core deliberately IGNORED the key (its
    /// `InputEffect.ignored`, "should be forwarded to other subsystems"), not
    /// that it failed — but for a Ctrl combo on a focused terminal there is
    /// no known trigger, and if it ever happens a legacy byte beats a dead
    /// key (conscious keep; the cursor-key path makes the same call with
    /// `handWrittenEscapeSequence`). Table mirrors ghostty's `ctrlSeq`
    /// (src/input/key_encode.zig), keyed on the unshifted codepoint like the
    /// encoder itself. Two deliberate divergences for a fallback-only path:
    /// i/m/[ get their legacy xterm bytes even though ghostty CSI-u's them
    /// (fixterms), and keys with no legacy byte (Ctrl+` …) return nil —
    /// those only exist under the kitty protocol, which a declining
    /// libghostty can't emit anyway.
    nonisolated static func legacyControlBytes(unshiftedCodepoint scalar: UInt32) -> String? {
        let byte: UInt8
        switch scalar {
        case 0x20, 0x32, 0x40: byte = 0x00             // Space, 2, @ → NUL
        case 0x33, 0x5B: byte = 0x1B                   // 3, [ → ESC
        case 0x34, 0x5C: byte = 0x1C                   // 4, \ → FS
        case 0x35, 0x5D: byte = 0x1D                   // 5, ] → GS
        case 0x36, 0x5E, 0x7E: byte = 0x1E             // 6, ^, ~ → RS
        case 0x37, 0x2F, 0x5F: byte = 0x1F             // 7, /, _ → US
        case 0x38, 0x3F: byte = 0x7F                   // 8, ? → DEL
        case 0x30, 0x31, 0x39: byte = UInt8(scalar)    // 0, 1, 9 → literal digit
        case 0x61...0x7A: byte = UInt8(scalar - 0x60)  // a…z → C0 0x01…0x1A
        default: return nil
        }
        return String(Unicode.Scalar(byte))
    }

    override func keyUp(with event: NSEvent) {
        // Intentionally do not forward key-release to libghostty: when an
        // app (e.g. Codex / ratatui-crossterm) pushes kitty keyboard
        // protocol with event-types enabled, libghostty turns the release
        // into an escape sequence that the app then re-interprets as a
        // second press, doubling every keystroke (codex#18564). Press +
        // modifier flagsChanged carry enough state for libghostty's
        // internal modifier tracking; release is only meaningful to
        // applications that opt into the kitty enhancement, and those that
        // do tend to mishandle it.
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else {
            super.flagsChanged(with: event)
            return
        }
        sendKey(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface)
    }

    override func doCommand(by selector: Selector) {
        // Deliberately empty. Not calling super is what suppresses the system
        // beep NSResponder's default raises for unimplemented standard-key-
        // binding commands (Ctrl+A → moveToBeginningOfParagraph: …), which
        // every Ctrl+letter now triggers via `handleEvent`. ghostty.app
        // overrides this too, though its version also redispatches
        // performKeyEquivalent-originated events — kooky doesn't need that
        // (Cmd combos exit keyDown before the IME). NB: this silences the
        // beep for ALL unhandled keys, not just the Ctrl combos keyDown
        // encodes. Byte encoding happens in keyDown, never here.
    }

    private var scrollAccum: NSPoint = .zero
    private static let scrollLinePoints: Double = 20.0

    override func scrollWheel(with event: NSEvent) {
        guard let surface else {
            super.scrollWheel(with: event)
            return
        }
        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate point deltas and only forward when we cross a
            // line threshold. libghostty's mouse_scroll treats integer-ish
            // deltas as line counts, so naive scaling lands on whole-line jumps
            // for every tiny finger movement.
            scrollAccum.x += event.scrollingDeltaX
            scrollAccum.y += event.scrollingDeltaY
            let dx = (scrollAccum.x / Self.scrollLinePoints).rounded(.towardZero)
            let dy = (scrollAccum.y / Self.scrollLinePoints).rounded(.towardZero)
            guard dx != 0 || dy != 0 else { return }
            ghostty_surface_mouse_scroll(surface, dx, dy, 0)
            scrollAccum.x -= dx * Self.scrollLinePoints
            scrollAccum.y -= dy * Self.scrollLinePoints
        } else {
            // Wheel: already in line ticks.
            ghostty_surface_mouse_scroll(surface,
                                         event.scrollingDeltaX,
                                         event.scrollingDeltaY,
                                         0)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking an unfocused pane must focus it. AppKit does NOT move
        // first responder to a plain NSView on click — only controls do
        // that themselves (ghostty.app's SurfaceView does the same) — so
        // without this a split sibling could never be focused by mouse:
        // the click forwarded to libghostty but keyboard focus stayed put.
        // Masked for years because a single pane grabs focus at mount and
        // never competes; ⌘[/⌘] and the tab bar were the only real paths.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        forwardMouseEvent(event, button: (.PRESS, .LEFT))
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event, button: (.RELEASE, .LEFT))
    }

    // Middle button (buttonNumber 2): the core owns the behavior —
    // `middle-click-action` defaults to paste, routed through the protected
    // clipboard-request path; with mouse reporting on, the TUI gets the
    // event instead. Other "other" buttons (side buttons 3+) stay with
    // AppKit — the core has no bindings for them.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        // Middle-click usually pastes (the start of the next command) — clear
        // a stale failure dot like every other paste path (Codex review).
        // Fired unconditionally: with mouse reporting on this is a TUI event
        // instead, but "user acted on the terminal" is exactly the signal the
        // dot clears on, and the dot is long gone inside a running TUI anyway.
        onUserInput?()
        forwardMouseEvent(event, button: (.PRESS, .MIDDLE))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        forwardMouseEvent(event, button: (.RELEASE, .MIDDLE))
    }

    /// Direct selection extraction — bypasses the libghostty binding +
    /// write_clipboard_cb path so `keyDown`'s Cmd+C fallback works
    /// regardless of which keys are bound for copy in the active config.
    /// The right-click "Copy" entry in the SwiftUI popover takes the same
    /// path via the `TerminalEngine.readSelection()` interface.
    private func performCopy() {
        guard let str = readSelection() else { return }
        writeToGeneralPasteboard(str)
    }

    func readSelection() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        // libghostty allocated the buffer; we must hand it back, otherwise every
        // read leaks the selection's bytes.
        defer { ghostty_surface_free_text(surface, &text) }
        guard let textPtr = text.text, text.text_len > 0 else { return nil }
        let data = Data(bytes: textPtr, count: Int(text.text_len))
        guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return nil }
        return str
    }

    func paste(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Pasting (⌘V) or dropping a file (performDragOperation routes here)
        // is the start of the next command too — same stale-failure-dot clear
        // as a keystroke, covering paste-with-trailing-newline that runs on
        // arrival, which a Return-key trigger would miss.
        onUserInput?()
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    // MARK: - Clipboard requests (OSC 52 read + protected paste)

    /// Single primitive for libghostty named binding actions — the engine's
    /// `performAction`, the protected paste below, and the resize re-pin all
    /// funnel through here (3 call sites; the call shape must not fork).
    @discardableResult
    func performAction(_ name: String) -> Bool {
        guard let surface else { return false }
        return name.withCString { cstr in
            ghostty_surface_binding_action(surface, cstr, UInt(name.utf8.count))
        }
    }

    /// Plain-text paste via the core's own `paste_from_clipboard` binding —
    /// the read callback answers with the pasteboard text and the core's
    /// safety check (`clipboard-paste-protection`) gets to veto/confirm
    /// before anything reaches the PTY. `paste(_:)` bypasses that check by
    /// design (kooky-constructed file paths / image cache paths), so every
    /// USER-initiated plain-text paste must come through here instead.
    func pasteFromClipboardViaCore() -> Bool {
        // Same next-command signal as the direct paste path.
        onUserInput?()
        return performAction("paste_from_clipboard")
    }

    /// Answers a core-owned clipboard request. `stateBits` is the request
    /// pointer in Int transit form (see `dispatchToView`); the request stays
    /// valid until this call, so every code path that receives one MUST end
    /// here exactly once — deny answers with an empty string, never silence.
    func completeClipboardRequest(stateBits: Int, text: String, confirmed: Bool) {
        guard let surface, let state = UnsafeMutableRawPointer(bitPattern: stateBits) else { return }
        text.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }

    /// Consent sheet for a risky clipboard READ (unsafe paste / OSC 52 read).
    /// Both buttons complete the request: Allow returns the contents with
    /// confirmed=true (the core re-checks nothing further), Cancel returns an
    /// empty string so the core-side request object is freed.
    func presentClipboardConfirmation(
        contents: String,
        stateBits: Int,
        request: ghostty_clipboard_request_e
    ) {
        let decide: @MainActor (Bool) -> Void = { [weak self] allowed in
            self?.completeClipboardRequest(
                stateBits: stateBits,
                text: allowed ? contents : "",
                confirmed: true
            )
        }
        guard let window else {
            // No window to anchor a sheet (detached/background surface) — deny.
            decide(false)
            return
        }
        ClipboardConfirmPresenter.present(
            on: window,
            kind: request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? .unsafePaste : .oscRead,
            contents: contents,
            onDecision: decide
        )
    }

    /// Consent sheet for `clipboard-write = ask` (OSC 52 write). The core
    /// doesn't hold a request open for writes — the host owns both the dialog
    /// and, on consent, the pasteboard write itself.
    func presentClipboardWriteConfirmation(contents: String) {
        guard let window else { return }
        ClipboardConfirmPresenter.present(
            on: window,
            kind: .oscWrite,
            contents: contents
        ) { allowed in
            guard allowed else { return }
            writeToGeneralPasteboard(contents)
        }
    }

    /// Open a libghostty link action using the configured editor / browser,
    /// falling back to the system default. URLs work in both local and remote
    /// sessions; filesystem paths are local only because a remote path has no
    /// safe LaunchServices meaning.
    func open(target rawTarget: String) {
        guard let target = TerminalOpenTargetResolver.resolve(
            rawTarget,
            currentDirectory: currentDirectory
        ) else { return }

        let model = KookySettingsModel.shared
        switch target {
        case .file:
            let isRemote = isRemoteSessionProvider?() == true
                || TerminalRemoteProcessDetector.isRemoteConnection(pid: foregroundPid)
            guard !isRemote else { return }
            let apps = OpenInResolver.installedFileLinkApps()
            if let app = OpenInApp.preferred(id: model.fileLinkAppId, available: apps),
               OpenInResolver.open(url: target.url, with: app) {
                return
            }
        case .url(let url):
            guard url.isWebLink else {
                NSWorkspace.shared.open(url)
                return
            }
            let apps = OpenInResolver.installedBrowserLinkApps()
            if let app = OpenInApp.preferred(id: model.webLinkAppId, available: apps),
               OpenInResolver.open(url: url, with: app) {
                return
            }
        }
        NSWorkspace.shared.open(target.url)
    }

    /// Drives the scroll indicator from libghostty's SCROLLBAR action. Skips
    /// the layout pass entirely when the values haven't changed (libghostty
    /// emits these liberally).
    func applyScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        // Track bottom-pinned state on every tick — including the ones we skip
        // below for indicator purposes — so the resize re-pin in
        // propagateSizeToSurface always sees a current value.
        viewportAtBottom = Self.isViewportAtBottom(total: total, offset: offset, len: len)
        guard total > len, len > 0 else { return }
        let next = (total: total, offset: offset, len: len)
        let previous = lastScrollbar
        guard previous?.total != total
                || previous?.offset != offset
                || previous?.len != len else { return }
        lastScrollbar = next

        let maxOffset = total - len
        let position = 1.0 - Double(offset) / Double(maxOffset)
        let proportion = Double(len) / Double(total)
        scrollIndicator.update(position: max(0, min(1, position)), proportion: proportion)
        if previous?.offset != offset {
            scrollIndicator.flash()
        }
    }

    private func forwardMouseEvent(_ event: NSEvent, button: (state: ghostty_input_mouse_state_e, code: ghostty_input_mouse_button_e)? = nil) {
        guard let surface else { return }
        let mods = Self.mapModifiers(event.modifierFlags)
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, mods)
        if let button {
            _ = ghostty_surface_mouse_button(surface, button.state, button.code, mods)
        }
    }

    @discardableResult
    private func sendKey(
        event: NSEvent,
        action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        surface: ghostty_surface_t
    ) -> Bool {
        // Any real keypress is the start of the next command (arrows recall
        // history, ^C/^R/tmux-prefix act on it) — clear a stale failure dot.
        // A bare modifier press (flagsChanged routes here too) must not.
        if event.type == .keyDown { onUserInput?() }
        return Self.send(
            Self.makeKeyEvent(for: event, action: action, translationMods: translationMods),
            text: text,
            to: surface
        )
    }

    /// Build the `ghostty_input_key_s` identity for a physical key event —
    /// mirrors ghostty.app's `ghosttyKeyEvent`: `consumed_mods` = the mods
    /// text translation used minus ctrl/cmd (their long-standing heuristic:
    /// those two never contribute to translation), `unshifted_codepoint` for
    /// the encoder's ctrlSeq keying. Text is separate: `keyEventText`
    /// derives it, `send` attaches it.
    nonisolated static func makeKeyEvent(
        for event: NSEvent,
        action: ghostty_input_action_e = GHOSTTY_ACTION_PRESS,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mapModifiers(event.modifierFlags)
        // NSEvent raises NSInternalInconsistencyException on `characters*` for
        // FlagsChanged events (modifier-only, no text) — and that ObjC unwind
        // through this Swift frame is undefined behavior, thousands of times a
        // day (every Shift/Cmd/Option press). Modifiers carry their state via
        // `mods` + `keycode` alone, matching ghostty.app's flagsChanged path.
        guard event.type == .keyDown || event.type == .keyUp else { return key }
        key.consumed_mods = mapModifiers(
            (translationMods ?? event.modifierFlags).subtracting([.control, .command])
        )
        key.unshifted_codepoint = unshiftedCodepoint(of: event)
        return key
    }

    /// First scalar of the event's characters with no modifiers applied — the
    /// value the encoder's ctrlSeq table keys on. keyDown/keyUp only (the
    /// `characters*` APIs raise on FlagsChanged, see `makeKeyEvent`).
    nonisolated static func unshiftedCodepoint(of event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp else { return 0 }
        return event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
    }

    /// The text to attach to a key event — ghostty.app's `ghosttyCharacters`
    /// + `keyAction` attach rule: an AppKit pre-translated control byte
    /// (Ctrl+A → "\u{01}") becomes the un-ctrl'd character so the encoder
    /// owns C0 mapping (and kitty sessions get CSI-u); a Private-Use-Area
    /// function-key "character" (NSUpArrowFunctionKey = 0xF700) becomes nil
    /// so the encoder keys off `keycode`; text still < 0x20 after
    /// un-ctrl'ing (Ctrl+Enter → "\r") becomes nil — the encoder derives
    /// those from keycode + mods.
    nonisolated static func keyEventText(
        for event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> String? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        // When the translation mods equal the event's own, read `.characters`
        // off the original event, not a re-translation — dead-key state only
        // lives on the real event.
        var text = event.characters
        if let translationMods, translationMods != event.modifierFlags {
            text = event.characters(byApplyingModifiers: translationMods)
        }
        if text?.count == 1, let scalar = text?.unicodeScalars.first {
            if scalar.value < 0x20 {
                text = event.characters(
                    byApplyingModifiers: (translationMods ?? event.modifierFlags).subtracting(.control)
                )
            } else if (0xE000...0xF8FF).contains(scalar.value) {
                text = nil
            }
        }
        if (text?.utf8.first ?? 0) < 0x20 { text = nil }
        return text
    }

    /// Attach `text` (if any) with the C-string lifetime `ghostty_surface_key`
    /// needs, and deliver. Callers hand text that is already attach-clean —
    /// `keyEventText` never returns a control byte, and `sendKeyText`'s
    /// visible-text guarantee covers the other caller.
    @discardableResult
    nonisolated static func send(
        _ key: ghostty_input_key_s,
        text: String?,
        to surface: ghostty_surface_t
    ) -> Bool {
        var key = key
        guard let text, !text.isEmpty else {
            return ghostty_surface_key(surface, key)
        }
        return text.withCString { cstr in
            key.text = cstr
            return ghostty_surface_key(surface, key)
        }
    }

    nonisolated static func mapModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        // Sided bits (device-dependent NSEvent raw flags, mirroring ghostty.app's
        // ghosttyMods) — `macos-option-as-alt = left|right` needs to know WHICH
        // Option is down; libghostty's translation-mods + key encoder read these.
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK)   != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK)   != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK)   != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    /// Inverse of `mapModifiers` for the four base modifiers only — used to
    /// fold libghostty's `ghostty_surface_key_translation_mods` answer back
    /// into NSEvent flags for the translation event (mirrors ghostty.app's
    /// `eventModifierFlags`). Sided/caps bits deliberately don't round-trip:
    /// the caller only transplants the four base flags onto the real event's
    /// flags, so device-dependent bits stay whatever the hardware reported.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue  != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue   != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    private func propagateSizeToSurface(force: Bool = false) {
        // Require a live window — never propagate while detached. A workspace
        // switch briefly removes the session's NSView from the window
        // (ContentView's `.id(workspace.id)` rebuild); the old `?? 2.0` scale
        // fallback then sized the grid at 2x on a 1x external display, so text
        // overflowed and stuck until the next resize (issue #8 follow-up — only
        // on the 1x monitor, never on the 2x laptop where the fallback matched).
        // viewDidMoveToWindow re-syncs on reattach.
        guard let surface, let window, force || !isHiddenOrHasHiddenAncestor else { return }
        let scale = window.backingScaleFactor
        let widthPx = UInt32(bounds.size.width * scale)
        let heightPx = UInt32(bounds.size.height * scale)
        // SwiftUI's tab-swap rebuild briefly hands us a 0-sized frame before
        // layout completes; pushing 0 to libghostty shrinks its row count and
        // never fully recovers, so the visible buffer creeps upward each swap.
        guard widthPx > 0, heightPx > 0 else { return }
        // Drop a redundant push of an identical pixel size. SwiftUI re-layouts,
        // sub-cell setFrameSize nudges, and the viewDidEndLiveResize flush all
        // re-enter with the same frame; each ghostty_surface_set_size is a
        // SIGWINCH that thrashes the shell (conda scrollback-wipe, prompt-reflow
        // flicker — issue #29 audit). Keyed on PIXELS (bounds × scale), NOT
        // cols×rows, so a cross-display DPI change still pushes (px = points ×
        // scale shifts with the scale); only a true no-op is dropped. `force`
        // covers the paths that must re-sync even an unchanged size — surface
        // create, reattach, post-zoom flush, DPI change.
        if !force, let last = lastPushedSizePx, last == (widthPx, heightPx) { return }
        lastPushedSizePx = (widthPx, heightPx)
        ghostty_surface_set_size(surface, widthPx, heightPx)
        // ghostty does NOT re-pin the viewport to the bottom on resize — it only
        // follows the latest output when a PTY write or keystroke calls
        // scroll(.active). A resize (live window drag → SIGWINCH-per-frame,
        // status-bar appear/disappear flush, pane-zoom flush, fullscreen) can
        // therefore strand the viewport above the active area while output is
        // streaming, leaving the prompt + newest output rendered below the fold
        // (issue #7). ghostty's `scroll-to-bottom = output` config that would
        // paper over this is unimplemented upstream, so re-pin ourselves — but
        // only when we were already at the bottom, so a user reading scrollback
        // isn't yanked down mid-resize.
        if viewportAtBottom {
            performAction("scroll_to_bottom")
        }
        // Render the resized frame on the next vsync without waiting for
        // libghostty's async RENDER action — removes the ordering dependency
        // between set_size and the render loop.
        setNeedsRender()
    }
}

// MARK: - Ghostty enum sugar

private extension ghostty_input_mouse_state_e {
    static var PRESS: Self { GHOSTTY_MOUSE_PRESS }
    static var RELEASE: Self { GHOSTTY_MOUSE_RELEASE }
}

private extension ghostty_input_mouse_button_e {
    static var LEFT: Self { GHOSTTY_MOUSE_LEFT }
    static var MIDDLE: Self { GHOSTTY_MOUSE_MIDDLE }
    static var RIGHT: Self { GHOSTTY_MOUSE_RIGHT }
}

// MARK: - NSTextInputClient (IME / 中日韩 composition)

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Commit ends composition. If we're inside keyDown's IME batching
        // window the actual byte send is deferred until after the preedit
        // sync (one atomic transaction); otherwise (e.g. dictation outside
        // a real keystroke) we send immediately.
        markedText = ""
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface, !text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
            sendKeyText(text, to: surface)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Inside keyDown we defer the libghostty sync until handleEvent
        // returns; outside (rare — layout change mid-compose) we sync
        // immediately so the candidate window has a current anchor.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        markedText = ""
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Anchor the IME candidate window at the real cursor cell so 中日韩
        // composition reads naturally. libghostty hands us the rect in
        // surface-local top-left coords; AppKit's NSView is bottom-left,
        // so flip Y before handing the rect up to the window → screen
        // conversion chain that NSTextInputClient expects.
        guard let surface, let window else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(
            x: x,
            y: bounds.height - y - h,
            width: w,
            height: h
        )
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
}
