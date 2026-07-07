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

        guard let config = KookySettings.makeGhosttyConfig() else {
            NSLog("kooky: ghostty_config_new failed")
            return
        }
        self.app = ghostty_app_new(&runtime, config)
        if self.app == nil {
            NSLog("kooky: ghostty_app_new failed")
        }
    }

    func reloadConfig() {
        guard let app else { return }
        // Parse settings.json + load ghostty defaults once for the entire
        // reload — `makeGhosttyConfig` is called once per ghostty receiver
        // (app + each surface) but they all need an identical config, so
        // share the parsed kooky-side dict to avoid N+1 disk reads + JSON
        // parses for a window with many panes.
        let parsed = KookySettings.loadParsed()
        guard let config = KookySettings.makeGhosttyConfig(parsed: parsed) else {
            NSLog("kooky: ghostty_config_new failed during reload")
            return
        }
        ghostty_app_update_config(app, config)
        GhosttySurfaceRegistry.updateAll(parsed: parsed)
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
    var remoteHostProvider: (() -> String?)? {
        get { surfaceView.remoteHostProvider }
        set { surfaceView.remoteHostProvider = newValue }
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

    var suspendsSizePropagation: Bool { surfaceView.suspendsSizePropagation }
    func beginSizePropagationSuspension() { surfaceView.beginSizePropagationSuspension() }
    func endSizePropagationSuspension() { surfaceView.endSizePropagationSuspension() }

    var grabsFocusOnMount: Bool {
        get { surfaceView.grabsFocusOnMount }
        set { surfaceView.grabsFocusOnMount = newValue }
    }

    func flushSize() {
        surfaceView.flushPropagateSize()
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

@MainActor
private enum GhosttySurfaceRegistry {
    // `NSHashTable.weakObjects()` handles weak storage + compaction
    // internally — every `register` is O(1), and dead refs disappear on
    // their own (no manual `filter`).
    private static let views: NSHashTable<GhosttySurfaceView> = .weakObjects()

    static func register(_ view: GhosttySurfaceView) {
        views.add(view)
    }

    static func updateAll(parsed: [String: Any]?) {
        for view in views.allObjects {
            view.updateConfigFromSettings(parsed: parsed)
        }
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
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onProcessExitedCleanly: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var remoteHostProvider: (() -> String?)?
    /// Read in `viewDidMoveToWindow` to gate the mount-time first-responder
    /// grab; set by `TerminalView` from the pane's active state. See
    /// `TerminalEngine.grabsFocusOnMount` for the why (issue #24).
    var grabsFocusOnMount = true
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
        GhosttySurfaceRegistry.register(self)
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
        lastPushedSizePx = nil
        ghostty_surface_free(dying)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // A pre-existing surface means we're re-entering a window (workspace
            // switch), not creating fresh: createSurfaceIfReady no-ops and
            // surface.didSet won't re-push the size, so we owe an explicit
            // re-sync below. On first creation didSet already handles it.
            let reattaching = surface != nil
            createSurfaceIfReady()
            // Defer until after SwiftUI's hosting finishes its current event
            // loop pass, otherwise the originating button click reclaims focus.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                // Only the active pane grabs focus on (re)mount — otherwise every
                // pane's surface races on a workspace switch and the last one wins
                // (issue #24). Size re-sync below runs regardless of focus.
                if self.grabsFocusOnMount {
                    window.makeFirstResponder(self)
                }
                // Re-sync size on reattach: propagateSizeToSurface no-ops while
                // detached, and a same-display / unchanged-frame reattach fires
                // neither viewDidChangeBackingProperties nor setFrameSize. force:
                // the frame is usually unchanged across the detach, which the
                // pixel-dedup would otherwise skip — but libghostty needs the
                // re-push to recover (issue #8).
                if reattaching { self.propagateSizeToSurface(force: true) }
            }
        }
        updateRenderLink()
    }

    /// Mark the surface dirty and wake the render link so the next vsync presents
    /// the new frame. Idempotent + cheap — call it from `GHOSTTY_ACTION_RENDER`
    /// and after any surface mutation we initiate, so a frame is never stranded
    /// waiting for an action that may have already fired before the link ran.
    func setNeedsRender() {
        needsRender = true
        renderLink?.isPaused = false
    }

    /// Render link runs only when the surface exists AND the view is in a window.
    /// Without the window guard, hidden sessions (an inactive tab is detached from
    /// the window) would keep ticking against a detached IOSurfaceLayer.
    private func updateRenderLink() {
        if surface != nil, window != nil {
            startRenderLink()
        } else {
            stopRenderLink()
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
        // Seed so the first viewDidChangeBackingProperties on this display is a
        // no-op; only a real cross-display scale change re-pushes (issue #8).
        lastBackingScale = window.backingScaleFactor

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

    func updateConfigFromSettings(parsed: [String: Any]?) {
        guard let surface else { return }
        guard let config = KookySettings.makeGhosttyConfig(parsed: parsed) else {
            NSLog("kooky: ghostty_config_new failed during surface reload")
            return
        }
        ghostty_surface_update_config(surface, config)
        ghostty_surface_refresh(surface)
        setNeedsRender()
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
            onFocus?()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface {
            ghostty_surface_set_focus(surface, false)
            setNeedsRender()
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
        if cmdOnly,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let pasted = KookyShellIntegration.readTerminalPasteText(
               from: .general,
               remoteHost: remoteHostProvider?()
           ),
           !pasted.isEmpty
        {
            paste(pasted)
            return
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
            // Arrow keys at a shell prompt recall history (↑/↓) or move the
            // cursor (←/→) — the start of the next command, so clear a stale
            // command-failure dot. Scrollback is the wheel, not arrows; inside
            // a TUI the dot is already cleared, so this is a no-op there.
            onUserInput?()
            if !sendKey(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface),
               let bytes = Self.handWrittenEscapeSequence(forKeyCode: event.keyCode, modifierFlags: mods) {
                sendInputBytes(bytes, to: surface)
            }
            return
        }

        // Kooky-specific functional keys with explicit byte behavior. Skipped
        // while IME is composing so Enter / Esc / arrows can dismiss / accept
        // the candidate window without leaking through to the PTY.
        if !hasMarkedText(),
           let bytes = Self.handWrittenEscapeSequence(forKeyCode: event.keyCode, modifierFlags: mods) {
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
            sendInputBytes(text, to: surface)  // control byte → fires onUserInput there
            return
        }
        // Visible typed text is the start of the next command — clear a stale
        // command-failure dot (libghostty exposes no command-START signal). The
        // control-byte branch above routes through sendInputBytes, which fires
        // its own onUserInput, so only this visible-text path needs one here.
        onUserInput?()
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
        // Chokepoint for every control-sequence input the user initiates —
        // Return / Tab / function keys (handWrittenEscapeSequence), Ctrl+letter
        // (^R history search, ^C, ^L), the Cocoa edit shortcuts (Cmd+←/→/⌫,
        // Option+⌫), and pill injection (sendInput). All start the next command,
        // so clear a stale failure dot here once rather than at each caller.
        // Visible typing (ghostty_surface_key) and paste (ghostty_surface_text)
        // don't route through here, so they fire at their own sites.
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
        modifierFlags mods: NSEvent.ModifierFlags
    ) -> String? {
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
        // Pasting (⌘V) or dropping a file (performDragOperation routes here)
        // is the start of the next command too — same stale-failure-dot clear
        // as a keystroke, covering paste-with-trailing-newline that runs on
        // arrival, which a Return-key trigger would miss.
        onUserInput?()
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
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
    private func sendKey(event: NSEvent, action: ghostty_input_action_e, surface: ghostty_surface_t) -> Bool {
        let mods = Self.mapModifiers(event.modifierFlags)
        let chars = event.characters ?? ""
        // NSEvent gives function/arrow keys a Private-Use-Area "character"
        // (e.g. NSUpArrowFunctionKey = 0xF700). Those aren't real text — strip
        // them so libghostty relies on `keycode` instead and emits the correct
        // escape sequence (CSI A/B/C/D, etc.).
        let firstScalar = chars.unicodeScalars.first?.value ?? 0
        let textToSend = (firstScalar >= 0xE000 && firstScalar <= 0xF8FF) ? "" : chars

        return textToSend.withCString { cstr in
            var key = ghostty_input_key_s()
            key.action = action
            key.mods = mods
            key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            key.keycode = UInt32(event.keyCode)
            key.text = textToSend.isEmpty ? nil : cstr
            key.unshifted_codepoint = 0
            key.composing = false
            return ghostty_surface_key(surface, key)
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

    private func propagateSizeToSurface(force: Bool = false) {
        // Require a live window — never propagate while detached. A workspace
        // switch briefly removes the session's NSView from the window
        // (ContentView's `.id(workspace.id)` rebuild); the old `?? 2.0` scale
        // fallback then sized the grid at 2x on a 1x external display, so text
        // overflowed and stuck until the next resize (issue #8 follow-up — only
        // on the 1x monitor, never on the 2x laptop where the fallback matched).
        // viewDidMoveToWindow re-syncs on reattach.
        guard let surface, let window else { return }
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
            let action = "scroll_to_bottom"
            action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
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
