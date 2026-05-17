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
            close_surface_cb: kookyCloseSurfaceCb
        )

        let config = ghostty_config_new()
        // Config precedence, last-write wins:
        //   ghostty defaults → kooky baselines → ~/.kooky/settings.json
        // So user's kooky settings beat both, and kooky baselines fill in
        // features we want on by default (e.g. `cursor-click-to-move`)
        // without forcing users to edit their ghostty config.
        ghostty_config_load_default_files(config)
        // Click anywhere on the current zsh / bash prompt to jump the
        // shell cursor there — requires the OSC 133 prompt marker our
        // wrapper rc already emits with the `cl=line` metadata libghostty
        // needs to recognise it.
        let baseline = "cursor-click-to-move = true\n"
        baseline.withCString { cstr in
            "kooky-baseline".withCString { source in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)), source)
            }
        }
        KookySettings.apply(to: config)
        ghostty_config_finalize(config)

        self.app = ghostty_app_new(&runtime, config)
        if self.app == nil {
            NSLog("kooky: ghostty_app_new failed")
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}

// MARK: - C callbacks

private let kookyWakeupCb: ghostty_runtime_wakeup_cb = { _ in
    DispatchQueue.main.async {
        MainActor.assumeIsolated { LibghosttyApp.shared.tick() }
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
        dispatchToView(userdata) { $0.onPwdChange?(pwd) }
        return true
    case GHOSTTY_ACTION_OPEN_URL:
        // libghostty resolves ⌘+click hits and hands us the URL string. We
        // route it to the default browser, but return `false` when we can't
        // parse the string so libghostty falls back to its own opener — some
        // OSC 8 / unescaped `file://` shapes that `URL(string:)` rejects can
        // still be opened by ghostty's built-in path.
        let urlAction = action.action.open_url
        guard let cstr = urlAction.url, urlAction.len > 0 else { return false }
        let buffer = UnsafeRawBufferPointer(start: cstr, count: Int(urlAction.len))
        let urlString = String(decoding: buffer, as: UTF8.self)
        guard let url = URL(string: urlString) else { return false }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
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
    default:
        return false
    }
}

private let kookyReadClipboardCb: ghostty_runtime_read_clipboard_cb = { _, _, _ in false }
private let kookyConfirmReadClipboardCb: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in }
private let kookyWriteClipboardCb: ghostty_runtime_write_clipboard_cb = { _, kind, contents, count, _ in
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
    // libghostty fires this on its own thread; NSPasteboard writes must be on
    // main for change-notification propagation to clipboard managers
    // (Paste, Maccy, etc.) — otherwise the value lands but listeners miss it.
    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
private let kookyCloseSurfaceCb: ghostty_runtime_close_surface_cb = { _, _ in }

// MARK: - LibghosttyEngine

@MainActor
final class LibghosttyEngine: TerminalEngine {
    private let surfaceView: GhosttySurfaceView

    var view: NSView { surfaceView }
    var backgroundColor: NSColor { Theme.terminalSurface }
    var onPwdChange: ((String) -> Void)? {
        get { surfaceView.onPwdChange }
        set { surfaceView.onPwdChange = newValue }
    }
    var onFocus: (() -> Void)? {
        get { surfaceView.onFocus }
        set { surfaceView.onFocus = newValue }
    }
    var onCommandFinished: ((Int?, TimeInterval) -> Void)? {
        get { surfaceView.onCommandFinished }
        set { surfaceView.onCommandFinished = newValue }
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
    var foregroundPid: pid_t? {
        guard let surface = surfaceView.surface else { return nil }
        let pid = pid_t(ghostty_surface_foreground_pid(surface))
        return pid > 0 ? pid : nil
    }

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

    @discardableResult
    func performAction(_ name: String) -> Bool {
        guard let surface = surfaceView.surface else { return false }
        return name.withCString { cstr in
            ghostty_surface_binding_action(surface, cstr, UInt(name.utf8.count))
        }
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
}

// MARK: - GhosttySurfaceView

/// AppKit host view that libghostty renders into directly. The view's pointer
/// lives in `ghostty_surface_config_s.platform.macos.nsview`; libghostty owns
/// the Metal layer and draws into it.
@MainActor
final class GhosttySurfaceView: NSView {
    private static let defaultBackingScale: CGFloat = 2.0

    private var drawTimer: Timer?
    private let scrollIndicator = ScrollIndicator()
    private var lastScrollbar: (total: UInt64, offset: UInt64, len: UInt64)?

    var pendingConfig: TerminalSessionConfig?
    var onPwdChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onProcessExitedCleanly: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    private(set) var surface: ghostty_surface_t? {
        didSet {
            if surface != nil { propagateSizeToSurface() }
            updateDrawTimer()
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
              !urls.isEmpty else { return false }
        let escaped = urls.map { KookyShellIntegration.backslashEscape($0.path) }.joined(separator: " ")
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
        // mouseMoved and stomping on the focused surface's hover.
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
        // Null first so any guard-on-surface check post-free sees the cleared
        // state immediately; the local `dying` keeps the handle for free.
        surface = nil
        ghostty_surface_free(dying)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            createSurfaceIfReady()
            // Defer until after SwiftUI's hosting finishes its current event
            // loop pass, otherwise the originating button click reclaims focus.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
        updateDrawTimer()
    }

    /// Draw timer runs only when the surface exists AND the view is in a window.
    /// Without the window guard, hidden sessions keep driving 60Hz
    /// `ghostty_surface_draw` into a detached IOSurfaceLayer.
    private func updateDrawTimer() {
        if surface != nil, window != nil {
            startDrawTimer()
        } else {
            stopDrawTimer()
        }
    }

    func createSurfaceIfReady() {
        guard surface == nil,
              let window,
              let config = pendingConfig,
              let app = LibghosttyApp.shared.app
        else { return }

        let scale = Double(window.backingScaleFactor)
        // Pin contentsScale so Core Animation doesn't double-scale ghostty's
        // already-pixel-correct render.
        layer?.contentsScale = scale

        let workingDir = config.workingDirectory ?? NSHomeDirectory()
        // Merge our wrapper ZDOTDIR into the caller's env dict. AgentTemplate
        // populates KOOKY_AGENT here so the wrapper .zshrc auto-launches the
        // selected CLI before the user ever sees a shell prompt.
        var envDict = config.environment
        envDict[KookyShellIntegration.zdotdirKey] = KookyShellIntegration.zshDirectory
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
        ghostty_surface_refresh(new)
    }

    private func startDrawTimer() {
        stopDrawTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let surface = self.surface else { return }
                ghostty_surface_draw(surface)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        drawTimer = timer
    }

    private func stopDrawTimer() {
        drawTimer?.invalidate()
        drawTimer = nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // AppKit calls this whenever this view's own frame changes — single
        // canonical hook. The legacy `resizeSubviews(withOldSize:)` would
        // double-propagate.
        propagateSizeToSurface()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            if let surface { ghostty_surface_set_focus(surface, true) }
            onFocus?()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface {
            ghostty_surface_set_focus(surface, false)
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
        // Match by physical keyCode (kVK_ANSI_V = 9), not
        // `charactersIgnoringModifiers` — the latter still reflects the
        // active keyboard layout, so on Cyrillic/Dvorak/AZERTY Cmd+V would
        // compare against "м"/"."/"…" and silently no-op.
        if cmdOnly,
           event.keyCode == 9,
           let pasted = NSPasteboard.general.string(forType: .string),
           !pasted.isEmpty
        {
            paste(pasted)
            return
        }

        // Cmd+C with a live selection — without this branch libghostty's
        // bypassed keybinding system would leave Cmd+C dead. keyCode 8 =
        // kVK_ANSI_C, layout-independent (see Cmd+V comment above).
        if cmdOnly,
           event.keyCode == 8,
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

        // Special / navigation keys with full modifier handling (CSI mod
        // digit 2…8 = 1 + Shift + 2·Alt + 4·Ctrl). Skipped while IME is
        // composing so Enter / Esc / arrows can dismiss / accept the
        // candidate window without leaking through to the PTY.
        if !hasMarkedText(), let bytes = Self.escapeSequence(for: event) {
            sendInputBytes(bytes, to: surface)
            return
        }

        // Ctrl+letter — NSEvent already gives the control byte (Ctrl+A →
        // "\u{01}"); IME would swallow these, so we forward them ourselves.
        if mods.contains(.control), !mods.contains(.option),
           let chars = event.characters, !chars.isEmpty,
           let scalar = chars.unicodeScalars.first?.value, scalar < 0x20 {
            sendInputBytes(chars, to: surface)
            return
        }

        // Regular text + IME composition. inputContext routes through
        // NSTextInputClient: insertText for committed input, setMarkedText
        // for in-progress composition. We batch all IME effects via
        // keyTextAccumulator so libghostty sees one atomic preedit-sync
        // + one text-commit per keystroke instead of per-IME-callback —
        // critical for CJK composition where rapid transient preedit
        // states otherwise leak phantom cells.
        let hadMarkedTextBefore = !markedText.isEmpty
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        inputContext?.handleEvent(event)
        // Only sync preedit when there's a state change to communicate.
        // Sending `ghostty_surface_preedit(nil, 0)` on every keystroke
        // (including pure ASCII typing) was confusing libghostty's wrap
        // accounting on long lines — once the line wrapped, the original
        // first row would scroll out of view as if the surface were only
        // a few rows tall.
        syncPreedit(clearIfNeeded: hadMarkedTextBefore)
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                sendKeyText(text, to: surface)
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
    /// sequences. Control bytes (< 0x20) still go through `text_input` — those
    /// are post-translation control sequences kooky already encodes itself.
    /// Mirrors ghostty.app's `committedPreeditTextAction` pattern.
    private func sendKeyText(_ text: String, to surface: ghostty_surface_t) {
        guard !text.isEmpty else { return }
        if let first = text.utf8.first, first < 0x20 {
            sendInputBytes(text, to: surface)
            return
        }
        text.withCString { ptr in
            var key_ev = ghostty_input_key_s()
            key_ev.action = GHOSTTY_ACTION_PRESS
            key_ev.keycode = 0
            key_ev.text = ptr
            key_ev.composing = false
            key_ev.mods = GHOSTTY_MODS_NONE
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.unshifted_codepoint = 0
            _ = ghostty_surface_key(surface, key_ev)
        }
    }

    private func sendInputBytes(_ bytes: String, to surface: ghostty_surface_t) {
        bytes.withCString { cstr in
            ghostty_surface_text_input(surface, cstr, UInt(strlen(cstr)))
        }
    }

    func sendInput(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        sendInputBytes(text, to: surface)
    }

    /// Map an NSEvent to the byte sequence a TUI expects on the PTY. Returns
    /// `nil` for anything that's just plain typed text (handled by the caller
    /// via `event.characters`).
    private static func escapeSequence(for event: NSEvent) -> String? {
        let code = event.keyCode
        let mods = event.modifierFlags
        let modDigit = csiModifierDigit(shift: mods.contains(.shift),
                                        alt: mods.contains(.option),
                                        ctrl: mods.contains(.control))

        switch code {
        // Functional
        case 36:
            // Shift+Enter: send `\` then CR — zsh line-continuation and
            // Claude Code's documented `\` + Enter → newline trick both
            // honor this. `\n` alone is useless: ZLE binds it to accept-line.
            return mods.contains(.shift) ? "\\\r" : "\r"
        case 48:  return mods.contains(.shift) ? "\u{1B}[Z" : "\t"  // Tab / Shift+Tab
        case 51:  return "\u{7F}"                          // Backspace (DEL)
        case 53:  return "\u{1B}"                          // Escape

        // Arrows
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
    private static func csiModifierDigit(shift: Bool, alt: Bool, ctrl: Bool) -> Int? {
        let mask = (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        return mask == 0 ? nil : mask + 1
    }

    private static func csiArrow(_ final: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[1;\(m)\(final)" }
        return "\u{1B}[\(final)"
    }

    private static func csiTilde(_ number: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[\(number);\(m)~" }
        return "\u{1B}[\(number)~"
    }

    private static func ssFnKey(_ final: String, modDigit: Int?) -> String {
        if let m = modDigit { return "\u{1B}[1;\(m)\(final)" }
        return "\u{1B}O\(final)"
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
        forwardMouseEvent(event, button: (.PRESS, .LEFT))
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event, button: (.RELEASE, .LEFT))
    }

    /// Direct selection extraction — bypasses the libghostty binding +
    /// write_clipboard_cb path so `keyDown`'s Cmd+C fallback works
    /// regardless of which keys are bound for copy in the active config.
    /// The right-click "Copy" entry in the SwiftUI popover takes the same
    /// path via the `TerminalEngine.readSelection()` interface.
    private func performCopy() {
        guard let str = readSelection() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
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
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    /// Drives the scroll indicator from libghostty's SCROLLBAR action. Skips
    /// the layout pass entirely when the values haven't changed (libghostty
    /// emits these liberally).
    func applyScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
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

    private func sendKey(event: NSEvent, action: ghostty_input_action_e, surface: ghostty_surface_t) {
        let mods = Self.mapModifiers(event.modifierFlags)
        // libghostty's `keycode` is a W3C UIEvents code (its own enum), not
        // Apple's keyCode. Without translation, special keys (arrows, function
        // keys, home/end/…) are silently dropped.
        let translated = Self.mapAppleKeyCode(event.keyCode)
        let chars = event.characters ?? ""
        // NSEvent gives function/arrow keys a Private-Use-Area "character"
        // (e.g. NSUpArrowFunctionKey = 0xF700). Those aren't real text — strip
        // them so libghostty relies on `keycode` instead and emits the correct
        // escape sequence (CSI A/B/C/D, etc.).
        let firstScalar = chars.unicodeScalars.first?.value ?? 0
        let textToSend = (firstScalar >= 0xE000 && firstScalar <= 0xF8FF) ? "" : chars

        textToSend.withCString { cstr in
            var key = ghostty_input_key_s()
            key.action = action
            key.mods = mods
            key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            key.keycode = UInt32(translated.rawValue)
            key.text = textToSend.isEmpty ? nil : cstr
            key.unshifted_codepoint = 0
            key.composing = false
            _ = ghostty_surface_key(surface, key)
        }
    }

    private static func mapAppleKeyCode(_ apple: UInt16) -> ghostty_input_key_e {
        switch apple {
        // Letters (Apple QWERTY layout)
        case 0:  return GHOSTTY_KEY_A
        case 11: return GHOSTTY_KEY_B
        case 8:  return GHOSTTY_KEY_C
        case 2:  return GHOSTTY_KEY_D
        case 14: return GHOSTTY_KEY_E
        case 3:  return GHOSTTY_KEY_F
        case 5:  return GHOSTTY_KEY_G
        case 4:  return GHOSTTY_KEY_H
        case 34: return GHOSTTY_KEY_I
        case 38: return GHOSTTY_KEY_J
        case 40: return GHOSTTY_KEY_K
        case 37: return GHOSTTY_KEY_L
        case 46: return GHOSTTY_KEY_M
        case 45: return GHOSTTY_KEY_N
        case 31: return GHOSTTY_KEY_O
        case 35: return GHOSTTY_KEY_P
        case 12: return GHOSTTY_KEY_Q
        case 15: return GHOSTTY_KEY_R
        case 1:  return GHOSTTY_KEY_S
        case 17: return GHOSTTY_KEY_T
        case 32: return GHOSTTY_KEY_U
        case 9:  return GHOSTTY_KEY_V
        case 13: return GHOSTTY_KEY_W
        case 7:  return GHOSTTY_KEY_X
        case 16: return GHOSTTY_KEY_Y
        case 6:  return GHOSTTY_KEY_Z

        // Digits (top row)
        case 29: return GHOSTTY_KEY_DIGIT_0
        case 18: return GHOSTTY_KEY_DIGIT_1
        case 19: return GHOSTTY_KEY_DIGIT_2
        case 20: return GHOSTTY_KEY_DIGIT_3
        case 21: return GHOSTTY_KEY_DIGIT_4
        case 23: return GHOSTTY_KEY_DIGIT_5
        case 22: return GHOSTTY_KEY_DIGIT_6
        case 26: return GHOSTTY_KEY_DIGIT_7
        case 28: return GHOSTTY_KEY_DIGIT_8
        case 25: return GHOSTTY_KEY_DIGIT_9

        // Punctuation
        case 50: return GHOSTTY_KEY_BACKQUOTE
        case 27: return GHOSTTY_KEY_MINUS
        case 24: return GHOSTTY_KEY_EQUAL
        case 33: return GHOSTTY_KEY_BRACKET_LEFT
        case 30: return GHOSTTY_KEY_BRACKET_RIGHT
        case 42: return GHOSTTY_KEY_BACKSLASH
        case 41: return GHOSTTY_KEY_SEMICOLON
        case 39: return GHOSTTY_KEY_QUOTE
        case 43: return GHOSTTY_KEY_COMMA
        case 47: return GHOSTTY_KEY_PERIOD
        case 44: return GHOSTTY_KEY_SLASH

        // Functional
        case 36: return GHOSTTY_KEY_ENTER
        case 48: return GHOSTTY_KEY_TAB
        case 49: return GHOSTTY_KEY_SPACE
        case 51: return GHOSTTY_KEY_BACKSPACE
        case 53: return GHOSTTY_KEY_ESCAPE

        // Modifiers
        case 54: return GHOSTTY_KEY_META_RIGHT
        case 55: return GHOSTTY_KEY_META_LEFT
        case 56: return GHOSTTY_KEY_SHIFT_LEFT
        case 57: return GHOSTTY_KEY_CAPS_LOCK
        case 58: return GHOSTTY_KEY_ALT_LEFT
        case 59: return GHOSTTY_KEY_CONTROL_LEFT
        case 60: return GHOSTTY_KEY_SHIFT_RIGHT
        case 61: return GHOSTTY_KEY_ALT_RIGHT
        case 62: return GHOSTTY_KEY_CONTROL_RIGHT
        case 63: return GHOSTTY_KEY_FN

        // Control pad
        case 114: return GHOSTTY_KEY_HELP
        case 115: return GHOSTTY_KEY_HOME
        case 116: return GHOSTTY_KEY_PAGE_UP
        case 117: return GHOSTTY_KEY_DELETE
        case 119: return GHOSTTY_KEY_END
        case 121: return GHOSTTY_KEY_PAGE_DOWN

        // Arrows
        case 123: return GHOSTTY_KEY_ARROW_LEFT
        case 124: return GHOSTTY_KEY_ARROW_RIGHT
        case 125: return GHOSTTY_KEY_ARROW_DOWN
        case 126: return GHOSTTY_KEY_ARROW_UP

        // Function keys
        case 122: return GHOSTTY_KEY_F1
        case 120: return GHOSTTY_KEY_F2
        case 99:  return GHOSTTY_KEY_F3
        case 118: return GHOSTTY_KEY_F4
        case 96:  return GHOSTTY_KEY_F5
        case 97:  return GHOSTTY_KEY_F6
        case 98:  return GHOSTTY_KEY_F7
        case 100: return GHOSTTY_KEY_F8
        case 101: return GHOSTTY_KEY_F9
        case 109: return GHOSTTY_KEY_F10
        case 103: return GHOSTTY_KEY_F11
        case 111: return GHOSTTY_KEY_F12
        case 105: return GHOSTTY_KEY_F13
        case 107: return GHOSTTY_KEY_F14
        case 113: return GHOSTTY_KEY_F15
        case 106: return GHOSTTY_KEY_F16
        case 64:  return GHOSTTY_KEY_F17
        case 79:  return GHOSTTY_KEY_F18
        case 80:  return GHOSTTY_KEY_F19

        // Numpad
        case 82: return GHOSTTY_KEY_NUMPAD_0
        case 83: return GHOSTTY_KEY_NUMPAD_1
        case 84: return GHOSTTY_KEY_NUMPAD_2
        case 85: return GHOSTTY_KEY_NUMPAD_3
        case 86: return GHOSTTY_KEY_NUMPAD_4
        case 87: return GHOSTTY_KEY_NUMPAD_5
        case 88: return GHOSTTY_KEY_NUMPAD_6
        case 89: return GHOSTTY_KEY_NUMPAD_7
        case 91: return GHOSTTY_KEY_NUMPAD_8
        case 92: return GHOSTTY_KEY_NUMPAD_9
        case 65: return GHOSTTY_KEY_NUMPAD_DECIMAL
        case 67: return GHOSTTY_KEY_NUMPAD_MULTIPLY
        case 69: return GHOSTTY_KEY_NUMPAD_ADD
        case 71: return GHOSTTY_KEY_NUMPAD_CLEAR
        case 75: return GHOSTTY_KEY_NUMPAD_DIVIDE
        case 76: return GHOSTTY_KEY_NUMPAD_ENTER
        case 78: return GHOSTTY_KEY_NUMPAD_SUBTRACT
        case 81: return GHOSTTY_KEY_NUMPAD_EQUAL

        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    private static func mapModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func propagateSizeToSurface() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? Self.defaultBackingScale
        let widthPx = UInt32(bounds.size.width * scale)
        let heightPx = UInt32(bounds.size.height * scale)
        // SwiftUI's tab-swap rebuild briefly hands us a 0-sized frame before
        // layout completes; pushing 0 to libghostty shrinks its row count and
        // never fully recovers, so the visible buffer creeps upward each swap.
        guard widthPx > 0, heightPx > 0 else { return }
        ghostty_surface_set_size(surface, widthPx, heightPx)
    }
}

// MARK: - Ghostty enum sugar

private extension ghostty_input_mouse_state_e {
    static var PRESS: Self { GHOSTTY_MOUSE_PRESS }
    static var RELEASE: Self { GHOSTTY_MOUSE_RELEASE }
}

private extension ghostty_input_mouse_button_e {
    static var LEFT: Self { GHOSTTY_MOUSE_LEFT }
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
