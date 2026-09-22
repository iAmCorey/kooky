import AppKit
import SwiftUI

/// Namespace for the View menu's Tab/Workspace switch items. Tags share a
/// single integer field on `NSMenuItem`, so we partition them: 1...9 for tabs
/// (matching ⌘N), 101...109 for workspaces (⌥⌘N). The 100 offset keeps both
/// sets identifiable from `menuNeedsUpdate`.
private enum MenuTag {
    static let tabRange = 1...9
    static let workspaceRange = 101...109
    static func tab(_ n: Int) -> Int { n }
    static func workspace(_ n: Int) -> Int { 100 + n }
    static func tabIndex(from tag: Int) -> Int { tag - 1 }
    static func workspaceIndex(from tag: Int) -> Int { tag - 101 }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    /// AppKit's supported system-appearance signal. Windows carry an explicit
    /// Aqua/Dark Aqua appearance for stable Liquid Glass rendering, so observe
    /// the application (which remains system-owned) rather than any window.
    private var systemAppearanceObservation: NSKeyValueObservation?
    /// File → Open Recent. Items are rebuilt from `RecentFolders` on every
    /// open via the dedicated delegate — the menu itself is a stable shell.
    private let openRecentMenu = NSMenu(title: "Open Recent")
    private let openRecentMenuDelegate = OpenRecentMenuDelegate()
    private var windowControllers: [KookyWindowController] = [] {
        // Every window add/remove flows through this one property, so bump the
        // agent monitor here — the right sidebar re-aggregates over the new
        // window set, and no future mutation site can forget to.
        didSet { AgentMonitor.shared.windowGeneration += 1 }
    }
    private let appPersistence = AppPersistence()
    /// Set in `applicationShouldTerminate` so `windowWillClose` (fired for
    /// every window during ⌘Q) can tell "app quitting" from "user closed
    /// one window" — the former keeps each window's persisted slot.
    private var isTerminating = false
    /// Native surface frees join renderer/PTY threads and must never run on the
    /// main actor. AppKit's terminate-later handshake keeps those workers alive
    /// long enough to finish after ⌘Q or the last window closes.
    private var terminationReplyPending = false
    private var terminationFallback: Task<Void, Never>?
    private var terminatingApplication: NSApplication?
    /// Walks the macOS window cascade so a `⌘⇧N` window doesn't land
    /// exactly on top of the previous one.
    private var cascadePoint = NSPoint.zero
    /// The kooky window that was key most recently. `activeStore` routes
    /// here (not an arbitrary array slot) when a Settings / Update panel is
    /// the key window. Weak so a closed window doesn't pin its store.
    private weak var lastKeyController: KookyWindowController?
    /// Deep links parked until launch completes. AppKit documents no ordering
    /// between a cold-start `application(_:open:)` and
    /// `applicationDidFinishLaunching`, and handling one needs the restored
    /// window set — so URLs buffer here and drain at the end of launch.
    private var pendingDeepLinks: [KookyDeepLink] = []
    private var deepLinksReady = false
    /// Posts macOS notifications when a backgrounded agent needs attention or
    /// a command fails. Bundle-gated, so it no-ops under `swift run`.
    private let notificationManager = NotificationManager()
    /// Native `NSStatusItem` showing the same cross-window live agent set as
    /// the right sidebar. It starts only after `AgentMonitor` is wired below.
    private var agentMenuBarController: AgentMenuBarController?
    /// Agent hook events carry a global surface-UUID. Broadcast to every
    /// window's store — `applyHookEvent` & friends no-op when the session
    /// isn't theirs, so exactly the owning window reacts.
    private lazy var hookServer = HookServer { [weak self] message in
        guard let self else { return }
        for controller in self.windowControllers {
            let store = controller.store
            switch message {
            case .agent(let agent, let event, let sessionId):
                store.applyHookEvent(agent: agent, event: event, sessionId: sessionId)
            case .shellEnvironment(let env, let sessionId):
                store.applyShellEnvironment(env, sessionId: sessionId)
            case .conversationId(let conversationId, let sessionId):
                store.applyConversationId(conversationId: conversationId, sessionId: sessionId)
            case .toolCall(let agent, let toolName, let identifier, let event, let success, let toolUseId, let sessionId):
                store.applyToolCallEvent(
                    agent: agent,
                    toolName: toolName,
                    identifier: identifier,
                    event: event,
                    success: success,
                    toolUseId: toolUseId,
                    sessionId: sessionId
                )
            }
        }
    }


    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        KookyFonts.registerOnce()
        // MUST STAY ABOVE ANY UI CONSTRUCTION — `restoreWindows()` below is the
        // near neighbour that would break it. NSToolTipManager reads this delay
        // once, when it is first created, and never re-reads it; the manager is
        // created by the first SwiftUI view carrying `.help`. Registering after
        // that point is a silent no-op — no error, no log, and no test would
        // catch the revert to the system default.
        //
        // AppKit's tooltip delay has no public API. `NSInitialToolTipDelay`
        // (milliseconds) is the preference it reads — an old key, still honoured
        // as of macOS 26 — and the system default is long enough that an
        // icon-only sidebar hover feels dead (issue #43); 600ms was picked by
        // feel. `register` rather than `set` keeps it a default: nothing is
        // written to the user's plist, and the registration domain is lowest
        // priority, so anyone who set their own value system-wide still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 600])
        // First-launch onboarding (blocking NSAlert if a ghostty config exists)
        // — must run before any window is created and before any libghostty
        // surface is spawned, since `LibghosttyApp` reads `~/.kooky/settings.json`
        // at process init when the first surface is created.
        KookyOnboarding.runIfNeeded()
        let settings = KookySettingsModel.shared
        // Onboarding can construct the shared model before a potential import
        // writes settings.json. Reload so first-launch imports are reflected
        // in the windows created below.
        settings.load()
        // Keep the observable settings model independent of NSApplication.
        // These are the only two imperative app-wide effects a save needs;
        // wiring narrow callbacks here leaves AppDelegate as the owner of
        // windows/stores and keeps standalone model tests AppKit-free.
        settings.onAgentTemplatesChanged = { [weak self] in
            self?.refreshAgentTemplates()
        }
        settings.onThemeAppearanceChanged = { [weak self] in
            self?.refreshThemeAppearances()
        }
        systemAppearanceObservation = NSApp.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, change in
            guard let appearance = change.newValue else { return }
            let isDark = KookyAppearanceMode.resolvesSystemDark(appearance: appearance)
            Task { @MainActor [weak self] in
                self?.handleSystemAppearanceChanged(isDark: isDark)
            }
        }
        KookyShellIntegration.installAgentHooks(sshRemoteAgentDetection: settings.sshRemoteAgentDetection)
        KookyShellIntegration.refreshClaudeCustomSettings(customAgents: settings.customAgents)
        // Opts this process into icon pruning (deletes files), then sweeps
        // whatever a previous run left behind. An xctest process never reaches
        // here, so it can't prune the developer's real icons.
        AgentIconStore.wireForApp()
        AgentIconStore.prune(keeping: settings.customAgents)

        restoreWindows()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMainMenu()
        // Wire the CLI verb executor before the socket opens so the first
        // request can't race an unset handler. The isTerminating guard is
        // the same discipline as the deep-link path: during the ⌘Q drain a
        // request must not spawn a tab into a store that's already flushed
        // (the second persistence flush would write the phantom tab).
        hookServer.onCLIRequest = { [weak self] request, isCallerWaiting, completion in
            guard let self, !self.isTerminating else {
                completion(.failure("kooky is shutting down"))
                return
            }
            self.cliController.handle(
                request,
                isCallerWaiting: isCallerWaiting,
                completion: completion
            )
        }
        hookServer.start()
        // Mirror kooky-cli into Application Support (same Gatekeeper story
        // as KookyHook: /Applications exec-assessment kills fresh-cdhash
        // adhoc binaries run from inside the bundle). Launch-time so the
        // stable path always carries the running build's CLI.
        _ = KookyShellIntegration.kookyCLIBinaryPath
        notificationManager.onActivate = { [weak self] sessionId in
            self?.activateFromNotification(sessionId)
        }
        notificationManager.start()
        // The right-side agent overview reads the global AgentMonitor; give it
        // the live window stores to aggregate + the same reveal-tab jump.
        AgentMonitor.shared.storesProvider = { [weak self] in
            self?.windowControllers.map(\.store) ?? []
        }
        AgentMonitor.shared.onActivate = { [weak self] sessionId in
            self?.activateFromNotification(sessionId)
        }
        let agentMenuBarController = AgentMenuBarController(
            monitor: .shared,
            settings: settings,
            onOpenKooky: { [weak self] in self?.openKookyFromMenuBar() },
            onOpenSettings: { [weak self] in self?.handleOpenSettings() }
        )
        self.agentMenuBarController = agentMenuBarController
        agentMenuBarController.start()
        // Keep-awake watches the same monitor; start after its stores are wired.
        SleepGuard.shared.start()

        // Sweep paste-image cache off the launch hot path. macOS's
        // own Caches eviction is unreliable; without this a heavy
        // Cmd+V-screenshots workflow accumulates GBs over months.
        Task.detached(priority: .utility) {
            KookyShellIntegration.prunePastesCache()
        }

        // LAST: windows + hook server + monitors all exist now, so a deep
        // link that raced launch can finally act.
        deepLinksReady = true
        for link in pendingDeepLinks { handleDeepLink(link) }
        pendingDeepLinks = []
    }

    /// System mode has two jobs on a macOS appearance flip: explicitly apply
    /// the newly resolved Aqua/Dark Aqua appearance to every window (important
    /// for NSGlassEffectView), and reload libghostty with the other palette.
    /// KVO fires after `NSApp.effectiveAppearance` has changed. Mirror that
    /// external AppKit value into the observable settings model first: unlike
    /// a manual Light/Dark picker change, an OS preference flip otherwise
    /// gives SwiftUI no state mutation to invalidate existing glass/chrome
    /// layers, producing a mixed old-background/new-foreground window.
    private func handleSystemAppearanceChanged(isDark: Bool) {
        let settings = KookySettingsModel.shared
        guard settings.systemAppearanceIsDark != isDark else { return }
        settings.systemAppearanceIsDark = isDark
        guard settings.appearanceMode == .system else { return }
        LibghosttyApp.shared.reloadConfig()
        refreshThemeAppearances()
    }

    /// Rebuilds every window persisted in `state.json`, or opens one default
    /// window on a fresh install.
    private func restoreWindows() {
        let ids = appPersistence.windowIds
        if ids.isEmpty {
            addWindow()
        } else {
            for id in ids { addWindow(windowId: id) }
        }
        // `addWindow` keys each as it's created, so the last restored window
        // ends up frontmost — kooky doesn't persist which window was key.
        //
        // Worktree two-way reconcile runs off the main actor so launch
        // isn't blocked by N × `git worktree list` subprocesses. Sidebar
        // paints first; adoptions / zombie removals trickle in once each
        // store's reconcile returns.
        for controller in windowControllers {
            Task { [store = controller.store] in
                await store.reconcileWorktrees()
            }
        }
    }

    /// Creates a window + its own `WorkspaceStore`. A fresh `windowId` (the
    /// `⌘⇧N` default) gets an empty store, which opens one default
    /// workspace; a restored id loads that window's persisted slice.
    @discardableResult
    private func addWindow(windowId: UUID = UUID()) -> KookyWindowController {
        let persistence = WindowPersistence(windowId: windowId, app: appPersistence)
        let store = WorkspaceStore(
            persistence: persistence,
            peerStores: { [weak self] in self?.windowControllers.map(\.store) ?? [] },
            moveToNewWindow: { [weak self] id in self?.moveTabToNewWindow(sessionId: id) },
            onSessionAlert: { [weak self] id, kind in self?.handleSessionAlert(id, kind) },
            noteRecentFolder: { RecentFolders.shared.note($0) }
        )
        let controller = KookyWindowController(windowId: windowId, store: store)
        persistence.frameProvider = { [weak controller] in controller?.persistableFrame }
        controller.onShouldClose = { [weak self] in self?.shouldCloseWindow($0) ?? true }
        controller.onWillClose = { [weak self] in self?.handleWindowWillClose($0) }
        controller.onDidBecomeKey = { [weak self] in self?.lastKeyController = $0 }
        // The window a frame-less newcomer copies its size from: the key
        // window for ⌘⇧N / "Move to New Window", the previous one at launch.
        let reference = activeController?.persistableFrame
        windowControllers.append(controller)
        if let window = controller.window {
            place(window, restoring: appPersistence.frame(for: windowId), inheritingSizeFrom: reference)
            window.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    /// A window with a saved frame goes back where it was (see
    /// `WindowPlacement` for the screen-layout clamping). Without one — fresh
    /// install, a pre-v0.51.9 state.json, ⌘⇧N — it takes the reference
    /// window's size and is centered / cascaded as before; the cascade
    /// continues from wherever the last window landed either way.
    private func place(_ window: NSWindow, restoring saved: PersistedFrame?, inheritingSizeFrom reference: PersistedFrame?) {
        if let saved,
           let frame = WindowPlacement.restoredFrame(
               saved.rect, minSize: window.minSize, screens: NSScreen.screens.map(\.visibleFrame)
           ) {
            window.setFrame(frame, display: false)
            cascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
            return
        }
        if let reference {
            window.setFrame(NSRect(origin: window.frame.origin, size: reference.rect.size), display: false)
        }
        if windowControllers.count == 1 {
            window.center()
            cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        } else {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
    }

    /// Right-click → "Move to New Window": creates a fresh window and pulls
    /// the session into it via the same cross-window machinery as a drag
    /// between existing windows. The new window's throwaway default tab is
    /// discarded once the adoption lands — `discardTab` (vs `closeTab`)
    /// keeps it off the `⌘⇧T` reopen stack since the user never asked for it.
    private func moveTabToNewWindow(sessionId: UUID) {
        let controller = addWindow()
        guard let workspace = controller.store.active,
              let pane = workspace.activePane else { return }
        let defaultTab = pane.tabs.first
        controller.store.handleTabDrop(droppedId: sessionId, to: pane, at: pane.tabs.count, in: workspace)
        // `count > 1` is a soft-fail guard for the rare case where
        // cross-window adoption returned false (e.g. the source store
        // vanished between right-click and here) — without it we'd discard
        // the placeholder, leaving the new window with zero tabs.
        if let defaultTab, pane.tabs.count > 1 {
            controller.store.discardTab(defaultTab, in: workspace)
        }
    }

    /// No other window is on screen. Evaluated against the live array, which
    /// still holds a closing controller until the next-tick drop — so it is
    /// correct from inside both `windowShouldClose` and `windowWillClose`.
    private func isLastWindow(_ controller: KookyWindowController) -> Bool {
        !windowControllers.contains { $0 !== controller && !$0.hiddenOnClose }
    }

    /// User-initiated close of the last window hides it instead — PTYs, agents
    /// and scrollback stay as they are; the next Dock click brings the same
    /// window back. One of several windows, or any window during ⌘Q, really closes.
    private func shouldCloseWindow(_ controller: KookyWindowController) -> Bool {
        guard isLastWindow(controller), !isTerminating else { return true }
        controller.hideInsteadOfClose()
        return false
    }

    private func handleWindowWillClose(_ controller: KookyWindowController) {
        // Keep the persisted slot when this is the last window (it only gets
        // here programmatically — its final workspace went — and the slot is
        // what the next Dock click / launch restores) or when ⌘Q is closing
        // every window. Closing one of several open windows discards just
        // that one.
        if isTerminating || isLastWindow(controller) {
            controller.store.flushPersistence()
        } else {
            appPersistence.removeWindow(controller.windowId)
        }
        controller.store.terminate()
        // Drop the controller next tick — releasing it (and its NSWindow)
        // synchronously inside windowWillClose can crash AppKit mid-close.
        DispatchQueue.main.async { [weak self] in
            self?.windowControllers.removeAll { $0 === controller }
        }
    }

    // MARK: - Dock menu

    /// Right-clicking the Dock tile shows New Window + every workspace across
    /// all windows, each a submenu of its tabs. kooky hides its title bars
    /// (`titleVisibility = .hidden`), so AppKit never populates the Dock's
    /// automatic per-window list — picking a tab raises the window that owns
    /// it, selects the workspace, and focuses the tab.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newWindow = NSMenuItem(
            title: String(localized: "New Window", bundle: .kookyResources),
            action: #selector(handleNewWindow),
            keyEquivalent: ""
        )
        newWindow.target = self
        menu.addItem(newWindow)

        let workspaces = windowControllers.flatMap(\.store.workspaces)
        guard !workspaces.isEmpty else { return menu }
        menu.addItem(.separator())
        for workspace in workspaces {
            let tabs = workspace.root.allPanes.flatMap(\.tabs)
            if tabs.count == 1, let only = tabs.first {
                // Single tab: click the workspace to jump straight to it,
                // no submenu to drill through.
                menu.addItem(dockTabItem(title: dockMenuTitle(for: workspace), sessionId: only.id))
            } else {
                let item = NSMenuItem(title: dockMenuTitle(for: workspace), action: nil, keyEquivalent: "")
                item.submenu = dockTabSubmenu(for: tabs)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// A worktree's branch disambiguates two workspaces sharing a folder name.
    private func dockMenuTitle(for workspace: Workspace) -> String {
        if let branch = workspace.worktreeBranch, !branch.isEmpty {
            return "\(workspace.title) (\(branch))"
        }
        return workspace.title
    }

    /// One item per tab; used when a workspace has more than one.
    private func dockTabSubmenu(for tabs: [Session]) -> NSMenu {
        let submenu = NSMenu()
        for session in tabs {
            submenu.addItem(dockTabItem(title: session.title, sessionId: session.id))
        }
        return submenu
    }

    /// A Dock menu item that jumps to `sessionId`'s tab when clicked.
    private func dockTabItem(title: String, sessionId: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(handleDockJumpToTab(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = sessionId
        return item
    }

    @objc private func handleDockJumpToTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let hit = dockTabLocation(for: id)
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        revealTab(hit.session, in: hit.workspace, controller: hit.controller)
    }

    private func dockTabLocation(for sessionId: UUID)
        -> (controller: KookyWindowController, workspace: Workspace, session: Session)? {
        for controller in windowControllers {
            for workspace in controller.store.workspaces {
                // `pane(containingSessionId:)` short-circuits the tree walk —
                // the codebase prefers it over `allPanes.first(where:)` (per
                // PaneNode.swift), matching the Command Palette's tab jump.
                if let pane = workspace.root.pane(containingSessionId: sessionId),
                   let session = pane.tabs.first(where: { $0.id == sessionId }) {
                    return (controller, workspace, session)
                }
            }
        }
        return nil
    }

    /// Raise a tab's window (restoring it if minimized), select its workspace,
    /// and focus the tab. Shared by the Command Palette's tab pick
    /// (`activate(_:)`) and the Dock menu so the cross-window jump lives in one
    /// place. Callers resolve the (controller, workspace, session) trio their
    /// own way — the palette by coordinate, the Dock by session id.
    private func revealTab(_ session: Session, in workspace: Workspace, controller: KookyWindowController) {
        if let window = controller.window { front(window) }
        controller.store.activateWorkspace(workspace)
        controller.store.activateTab(session, in: workspace)
    }

    /// Deminiaturize-and-front — the shared tail of every "bring a kooky
    /// window to the user" path (tab reveal, menu-bar open, deep link), so a
    /// future fronting fix (Spaces, activation ordering) lands everywhere.
    private func front(_ window: NSWindow) {
        controller(for: window)?.markPresented()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // The app may already be active (last window closed, kooky still
        // frontmost), so `applicationDidBecomeActive` won't fire — clear the
        // active tab's unread here, it is on screen now.
        markVisibleSessionRead()
    }

    // MARK: - Deep links

    /// `kooky://` URL entry point (registered via `CFBundleURLTypes` in the
    /// generated Info.plist, so it only fires in the packaged .app — Launch
    /// Services never routes URLs to a bundle-less `swift run` binary).
    /// Unparseable URLs are dropped silently: the scheme is public surface,
    /// so arbitrary malformed links must not beep or alert.
    public func application(_ application: NSApplication, open urls: [URL]) {
        // Mid-quit links are dropped: the stores are already flushed and
        // terminated, so acting would spawn into a dying app (and the second
        // persistence flush would write the phantom tab to state.json).
        guard !isTerminating else { return }
        let links = urls.compactMap(KookyDeepLink.parse)
        guard deepLinksReady else {
            pendingDeepLinks.append(contentsOf: links)
            return
        }
        for link in links { handleDeepLink(link) }
    }

    private func handleDeepLink(_ link: KookyDeepLink) {
        NSApp.activate(ignoringOtherApps: true)
        switch link {
        case .resumeSession(let agentId, let conversationId, let cwd):
            resumeSessionFromDeepLink(agentId: agentId, conversationId: conversationId, cwd: cwd)
        case .invalid(let reason):
            presentDeepLinkFailure(reason)
        }
    }

    /// Deep-link wrapper around `resumeSession` — failures become the
    /// visible sheet (the link just activated the app, so silence would
    /// read as a dead link), dropped tiers stay log-only exactly as before.
    private func resumeSessionFromDeepLink(agentId: String, conversationId: String, cwd: String?) {
        resumeSession(agentId: agentId, conversationId: conversationId, cwd: cwd) { [weak self] outcome in
            switch outcome {
            case .revealed, .opened:
                break
            case .failed(let reason):
                self?.presentDeepLinkFailure(reason)
            case .dropped(let reason):
                NSLog("kooky: resume request dropped — %@", reason)
            }
        }
    }

    /// Jump to the conversation if a tab is already running it, else find it
    /// in the agent's own session store and resume — the History row's exact
    /// pipeline, so SSH-workspace fallback rides along for free. Spawn-cwd
    /// precedence: the scanner record's cwd while it still exists (local
    /// store is first-hand), else the caller's validated cwd (covers a moved
    /// project AND conversations beyond the scanner's per-agent cap — the
    /// agent itself rejects an id it doesn't know, visibly in the tab), else
    /// the record's dead cwd (`resolvedSpawnCwd` falls back to `$HOME`, the
    /// History row's behavior).
    ///
    /// Shared core for BOTH front doors (kooky://resume, `kooky-cli
    /// resume`): every path lands in `completion` exactly once, and the
    /// wrapper decides the feedback channel — sheet for links, response
    /// line for the CLI. The `dropped` tiers were always silent for links;
    /// keeping them a distinct case preserves that while still answering a
    /// CLI caller.
    /// The whole resume request's budget, and the smaller one each directory
    /// probe gets. The probe budget MUST stay strictly under the request's:
    /// they are checked in series (the outer deadline starts first and is
    /// read after the probes return), so equal budgets make the fallback
    /// unreachable by arithmetic — a probe that runs its full length leaves
    /// the request already expired, and a `--cwd` that resolved perfectly
    /// well gets thrown away with it. That fallback is the entire point of
    /// passing `--cwd` for a project that has since moved.
    static let resumeRequestBudget: Duration = .seconds(10)
    static let resumeProbeBudget: Duration = .seconds(6)

    /// `isCallerWaiting` defaults to "yes" for the deep-link path, whose
    /// caller is a URL that has no connection to lose. The CLI passes a real
    /// check: its caller can ^C or time out while the scan below runs, and
    /// nothing after that point should build a window for them.
    func resumeSession(
        agentId: String,
        conversationId: String,
        cwd: String?,
        isCallerWaiting: @escaping @MainActor () -> Bool = { true },
        completion: @escaping @MainActor (ResumeRequestOutcome) -> Void
    ) {
        // Roster whitelist — the only agents a caller can name are the ones
        // whose session stores kooky itself reads.
        guard AgentSessionScanner.supportedAgentIds.contains(agentId) else {
            completion(.failed("unknown agent '\(agentId)'"))
            return
        }
        if revealOpenConversation(agentId: agentId, conversationId: conversationId) {
            completion(.revealed)
            return
        }
        // Bounds the WHOLE request, not just the probes below: a probe can
        // win its race and still land here after the user has moved on (or
        // after the CLI's own timeout), and a session appearing minutes later
        // is exactly what this used to prevent before the probe refactor
        // replaced it with per-probe races.
        let deadline = RequestDeadline(Self.resumeRequestBudget)
        Task { [weak self] in
            // Store read + cwd stat off-main, and the stat only when it can
            // matter: `cwd` comes from an untrusted caller — a stat against
            // an unmounted network path blocks for the automount timeout —
            // so a scanner hit with a live directory never pays it.
            //
            // The 10s bound is a RACE, not an elapsed-time check afterwards:
            // a stat stuck on a dead mount never returns, so measuring after
            // the await could never fire. Same reasoning (and same helper) as
            // `KookyCLIController.handleOpen`.
            // Two INDEPENDENT races, for the same reason `handleOpen` splits
            // its own: the scanned record's directory can sit on a dead
            // mount (the project moved and the record is stale) while the
            // caller passed a perfectly healthy `--cwd`. Sharing one race
            // let the stale half time out the whole resume, so the good cwd
            // never got its turn. Either probe timing out just means "this
            // source has nothing to offer".
            // The double optional is the race's own: the OUTER nil means the
            // probe timed out, the inner one that it found nothing. Both
            // collapse to "nothing to offer" below.
            // A `Task`, not `async let`: the caller's cwd only matters if the
            // recorded one turns out unusable, and `async let` would still be
            // awaited when this scope exits — so a healthy record would sit
            // out the caller probe's full timeout for a value it never uses.
            // Starting both at once keeps the both-needed case at max() rather
            // than sum(); the loser is simply abandoned (its blocking stat
            // can't be interrupted, but nothing waits on it).
            let callerProbe = Task {
                await withOffMainTimeout(Self.resumeProbeBudget) {
                    cwd.map(URL.init(fileURLWithPath:)).flatMap { isDirectory($0) ? $0 : nil }
                }
            }
            let record = (await withOffMainTimeout(Self.resumeProbeBudget) {
                guard let record = AgentSessionScanner.findRecordInDefaultRoot(
                    agentId: agentId, conversationId: conversationId
                ) else { return (cwd: URL, usable: Bool)?.none }
                return (record.cwd, isDirectory(record.cwd))
            }) ?? nil
            // Precedence unchanged: a usable recorded directory wins, else
            // the caller's, else the recorded one anyway so `resolvedSpawnCwd`
            // can fall back to $HOME rather than refusing outright.
            let spawnCwd: URL?
            if record?.usable == true {
                spawnCwd = record?.cwd
                callerProbe.cancel()
            } else {
                spawnCwd = ((await callerProbe.value) ?? nil) ?? record?.cwd
            }
            guard let self, !self.isTerminating else {
                completion(.dropped("kooky is shutting down"))
                return
            }
            // Before ANY side effect below — the reveal fronts a window, and
            // the resume builds one. A link the user abandoned must not
            // yank kooky forward long after they stopped waiting.
            guard !deadline.hasExpired else {
                completion(.dropped("resume for '\(agentId)' timed out"))
                return
            }
            // Same gate, different cause: the caller may have walked away
            // while the scan ran. Everything below fronts or builds a window.
            guard isCallerWaiting() else {
                completion(.dropped("the caller stopped waiting"))
                return
            }
            // Re-check after the async hop: a double-fired request's first
            // resume may have landed while this one was scanning.
            if self.revealOpenConversation(agentId: agentId, conversationId: conversationId) {
                completion(.revealed)
                return
            }
            guard let spawnCwd else {
                if let cwd {
                    completion(.failed("directory does not exist: \(cwd)"))
                } else {
                    completion(.failed("conversation '\(conversationId)' is not among the newest sessions kooky scans for \(agentId) — pass a cwd (&cwd= / --cwd) to resume an older one"))
                }
                return
            }
            // Refuse BEFORE anything is built. `deepLinkController()` below
            // may create a window, and `handleWindowWillClose` treats a lone
            // window as worth persisting — so a refusal after that point
            // both leaves an empty window on screen and files it in
            // state.json for next launch, once per failed attempt.
            if let refusal = WorkspaceStore.resumeRefusal(
                agentId: agentId, conversationId: conversationId
            ) {
                completion(.failed(refusal.message(agentId: agentId, conversationId: conversationId)))
                return
            }
            guard let landing = self.deepLinkController() else {
                completion(.dropped("kooky is shutting down"))
                return
            }
            let controller = landing.controller
            // Refusals are decided before anything spawns, so a failure
            // leaves no tab behind for a script to accumulate. Nothing is
            // FRONTED yet either: a request that ends in a refusal must not
            // pull the user's window forward to say no, and a window built
            // just for this request has to go back where it came from —
            // otherwise a retrying script leaves a stack of empty windows.
            let session: Session
            switch controller.store.resumeAgentSession(
                agentId: agentId, conversationId: conversationId, cwd: spawnCwd
            ) {
            case .success(let spawned):
                session = spawned
            case .failure(let refusal):
                // Defence in depth: the pre-check above uses the default
                // options provider, this store could in principle carry a
                // different one. Drop the persistence slot AFTER the close —
                // `handleWindowWillClose` flushes on its way out, so removing
                // it first would just be overwritten.
                if landing.builtWindow {
                    controller.window?.close()
                    self.appPersistence.removeWindow(controller.windowId)
                }
                completion(.failed(refusal.message(agentId: agentId, conversationId: conversationId)))
                return
            }
            // Same shape as `kooky-cli open`: a link that arrived with zero
            // terminal windows had one built for it, and that window's seed
            // tab is a byproduct of this resume, not a session of the user's.
            if landing.builtWindow {
                controller.store.discardSeedTab(keeping: session)
            }
            // Front only now, with the tab already in place.
            if let window = controller.window { self.front(window) }
            completion(.opened)
        }
    }

    /// The window a deep link should land in — the active controller, or a
    /// fresh window when none exists (Settings/About can keep the app alive
    /// with zero terminal windows; a valid link must not silently vanish
    /// there, mirroring the Dock menu's New Window recovery).
    /// `builtWindow` is true only when this call created the window. A
    /// window built to serve one request arrives with a seed tab of its own,
    /// and that tab exists solely because the request needed somewhere to
    /// land — see `WorkspaceStore.discardSeedTab(keeping:)`. Reporting the
    /// fact here keeps every caller from re-deriving it (and getting it
    /// subtly wrong: `activeController` can still find a controller in the
    /// window between a close and its deallocation).
    private func deepLinkController() -> (controller: KookyWindowController, builtWindow: Bool)? {
        revealHiddenWindow()
        if let controller = activeController { return (controller, false) }
        guard !isTerminating else { return nil }
        return (addWindow(), true)
    }

    private func presentDeepLinkFailure(_ reason: String) {
        NSLog("kooky: deep link rejected — %@", reason)
        // Defensive cap besides the parse-level limits: the sheet has no
        // scroll view, so an oversized reason must never reach layout.
        let display = reason.count > 500 ? String(reason.prefix(500)) + "…" : reason
        guard let window = deepLinkController()?.controller.window else { return }
        // A sheet on a miniaturized window is invisible (NSApp.activate does
        // not deminiaturize) — front it like the success path does.
        front(window)
        DeepLinkFailurePresenter.present(on: window, reason: display)
    }

    /// True when some window already runs the conversation and was revealed.
    private func revealOpenConversation(agentId: String, conversationId: String) -> Bool {
        // Same one-tick hazard the CLI's `windows` provider filters: a store
        // that has already been terminated is still in the array, and
        // "revealing" one of its tabs would report success for a tab that
        // disappears with the window a moment later.
        for controller in windowControllers where !controller.store.isTerminated {
            if let hit = controller.store.findOpenConversation(agentId: agentId, conversationId: conversationId) {
                revealTab(hit.session, in: hit.workspace, controller: controller)
                return true
            }
        }
        return false
    }

    // MARK: - CLI control channel

    /// Verb executor for `kooky-cli` requests arriving over the hook socket.
    /// The window list, reveal, template lookup, and resume pipeline are
    /// closures so the controller's decisions stay unit-testable without an
    /// AppDelegate (DeepLinkTests' split: pure decisions pinned, AppKit
    /// manual).
    private lazy var cliController = KookyCLIController(
        appVersion: KookyApp.displayVersion,
        windows: { [weak self] in
            guard let self else { return [] }
            // Skip stores already torn down: `handleWindowWillClose` calls
            // `terminate()` synchronously but only drops the controller on
            // the next main-queue tick, so a CLI request that arrives in
            // between would otherwise land a tab in a store that is about to
            // vanish — and answer "ok" with an id nothing can reach.
            return self.windowControllers
                .filter { !$0.store.isTerminated }
                .map { self.cliWindowContext(for: $0) }
        },
        fallbackWindow: { [weak self] in
            guard let self, let landing = self.deepLinkController() else { return nil }
            return (self.cliWindowContext(for: landing.controller), landing.builtWindow)
        },
        activateApp: { NSApp.activate(ignoringOtherApps: true) },
        isShuttingDown: { [weak self] in self?.isTerminating ?? true },
        templates: {
            // Terminal presets first (their ids live in settings alongside
            // agent ids), then the terminal itself, then real agents via
            // `ordered(model:)` — built-ins + customs in the user's Settings
            // order WITH its colliding-id dedup, hidden ones included
            // (hiding curates the `+` menu, it shouldn't break an external
            // script), and never half-configured customs (`isShell` filters
            // those out).
            var roster = KookySettingsModel.shared.terminalPresets.map(AgentTemplate.fromTerminalPreset)
            roster.append(.terminal)
            roster.append(contentsOf: AgentTemplate.ordered(model: KookySettingsModel.shared).filter { !$0.isShell })
            return roster
        },
        resume: { [weak self] agentId, conversationId, cwd, isCallerWaiting, completion in
            // No isTerminating check here — onCLIRequest already gated it in
            // the same synchronous tick, and resumeSession re-checks after
            // its async hop (the load-bearing one).
            guard let self else {
                completion(.dropped("kooky is shutting down"))
                return
            }
            self.resumeSession(
                agentId: agentId,
                conversationId: conversationId,
                cwd: cwd,
                isCallerWaiting: isCallerWaiting,
                completion: completion
            )
        }
    )

    private func cliWindowContext(for controller: KookyWindowController) -> KookyCLIController.WindowContext {
        KookyCLIController.WindowContext(
            store: controller.store,
            // "Active" by kooky's own bookkeeping, not AppKit's isKeyWindow:
            // CLI calls almost always arrive while kooky is in the
            // background, where AppKit reports NO key window and every
            // window would tie at false — activeController falls back to
            // the last key window, which is the one the user works in.
            isKey: controller === activeController,
            reveal: { [weak self, weak controller] session, workspace in
                guard let self, let controller else { return }
                self.revealTab(session, in: workspace, controller: controller)
            },
            window: { [weak controller] in controller?.window }
        )
    }

    // MARK: - Notifications

    /// Called by any window's store when a session raises an alert —
    /// attention, command failure, completion, or a program's own OSC 9/777
    /// notification. Every kind lands in the inbox (visible tab → read); the
    /// system banner only fires for a tab the user can't currently see, and
    /// only when notifications are enabled.
    private func handleSessionAlert(_ sessionId: UUID, _ kind: SessionAlertKind) {
        guard let location = dockTabLocation(for: sessionId) else { return }
        let tab = location.session.title
        let workspace = location.workspace.title
        // A tab that's already on-screen when the event fires lands read — the
        // user is looking at it, so it shouldn't light the bell. Computed once
        // and reused below to also suppress the banner.
        let visible = isSessionVisible(sessionId)
        // Every kind — including completed — lands in the inbox.
        NotificationInbox.shared.add(
            kind: kind,
            sessionId: sessionId,
            agent: location.session.displayAgent,
            tab: tab,
            workspace: workspace,
            isRead: visible
        )
        // System banner: attention / failure only, gated on the setting + its
        // sub-toggle + visibility. Completed is inbox-only (never a banner).
        let settings = KookySettingsModel.shared
        switch kind {
        case .completed:
            return
        case .programNotification(let title, let body):
            // Program-originated (own core-side gate: `desktop-notifications`)
            // — kooky's per-kind sub-toggles don't apply, but the master
            // switch does: a user who turned notifications off must not get
            // banners (or the OS authorization prompt) from a stray OSC 9.
            guard settings.notificationsEnabled, !visible else { return }
            notificationManager.post(
                title: title.isEmpty ? location.session.displayAgent.title : title,
                body: body,
                sessionId: sessionId
            )
        case .attention:
            guard settings.notificationsEnabled, settings.notifyOnAttention,
                  !visible else { return }
            notificationManager.post(
                title: "\(location.session.displayAgent.title) needs you",
                body: tab == workspace ? tab : "\(tab) · \(workspace)",
                sessionId: sessionId
            )
        case .failure:
            guard settings.notificationsEnabled, settings.notifyOnFailure,
                  !visible else { return }
            notificationManager.post(
                title: "\(tab) — command failed",
                body: workspace,
                sessionId: sessionId
            )
        }
    }

    /// True only when the session is the active tab of the active workspace in
    /// the key window AND kooky is frontmost — i.e. the user can already see
    /// it. A backgrounded app, a non-key window, a different workspace/tab, or
    /// a zoom hiding this pane all read as not-visible (→ worth a notification).
    private func isSessionVisible(_ sessionId: UUID) -> Bool {
        guard NSApp.isActive,
              let controller = windowControllers.first(where: { $0.window?.isKeyWindow == true }),
              let workspace = controller.store.workspaces.first(where: { $0.id == controller.store.activeWorkspaceId }),
              let pane = workspace.root.pane(containingSessionId: sessionId),
              pane.activeTabId == sessionId
        else { return false }
        // Zoom hides every pane but the zoomed one.
        if let zoomed = workspace.zoomedPaneId, zoomed != pane.id { return false }
        return true
    }

    /// Mark the currently-visible tab's notifications read — called when kooky
    /// returns to the foreground. `activateTab` only fires on a tab *change*, so
    /// a notification that arrived while the (unchanged) active tab was hidden
    /// would otherwise keep the bell lit after the user is plainly looking at it.
    private func markVisibleSessionRead() {
        guard NSApp.isActive,
              let controller = windowControllers.first(where: { $0.window?.isKeyWindow == true }),
              let workspace = controller.store.workspaces.first(where: { $0.id == controller.store.activeWorkspaceId }),
              let session = workspace.activeSession
        else { return }
        NotificationInbox.shared.markRead(forSession: session.id)
    }

    /// Notification click → bring kooky forward and jump to the tab.
    private func activateFromNotification(_ sessionId: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        guard let location = dockTabLocation(for: sessionId) else { return }
        revealTab(location.session, in: location.workspace, controller: location.controller)
    }

    /// Toggle the agent inbox panel — from the top-chrome bell or ⇧⌘I.
    @objc func handleShowInbox() {
        revealHiddenWindow()
        InboxWindowController.shared.toggle(
            anchor: activeController?.window,
            onActivate: { [weak self] event in self?.activateFromInbox(event) }
        )
    }

    /// Inbox row click → mark that event read, bring kooky forward, jump to the
    /// tab. The jump no-ops if the session has since closed (event outlives it).
    private func activateFromInbox(_ event: NotificationInbox.Event) {
        NotificationInbox.shared.markRead(event.id)
        NSApp.activate(ignoringOtherApps: true)
        guard let location = dockTabLocation(for: event.sessionId) else { return }
        revealTab(location.session, in: location.workspace, controller: location.controller)
        // Jumping in from a notification means the user has now looked at the
        // tab, so clear any lingering command-failure dot on it (the same
        // fields the next-keystroke clear resets) — not just the inbox entry.
        location.session.lastCommandExit = nil
        location.session.lastCommandDuration = nil
    }

    /// The terminal-window controller owning `window`, if it's one of ours.
    private func controller(for window: NSWindow) -> KookyWindowController? {
        windowControllers.first(where: { $0.window === window })
    }

    /// The kooky window that should host a menu action — the key window
    /// when it's one of ours, otherwise the most-recently-key kooky window.
    /// Nil only when no kooky window exists.
    private var activeController: KookyWindowController? {
        if let key = NSApp.keyWindow, let controller = controller(for: key),
           !controller.store.isTerminated {
            return controller
        }
        if let last = lastKeyController, !last.store.isTerminated { return last }
        // Same one-tick window as `windows()` above: a controller whose store
        // is already terminated is still in the array, and handing it to a
        // deep link or the CLI fallback would spawn into a dying store.
        return windowControllers.first { !$0.store.isTerminated }
    }

    /// A close-hidden window is still the user's window. Every path that is
    /// about to show UI in it (⌘T, ⌘O's sheet, ⌘P, the inbox, a deep link,
    /// menu-bar Open, Dock reopen) calls this first so it acts on a window
    /// the user can see. Pure queries — `activeController`, the CLI's
    /// `windows()`, menu validation — never do, so `kooky-cli list` or a
    /// background `rename` can't pop the window. Returns whether one was shown.
    @discardableResult
    private func revealHiddenWindow() -> Bool {
        guard let window = windowControllers
            .first(where: { $0.hiddenOnClose && !$0.store.isTerminated })?.window
        else { return false }
        front(window)
        return true
    }

    /// The `WorkspaceStore` of the key window — the target for menu actions.
    /// When a non-kooky window (Settings / Update) is key, routes to the
    /// most-recently-key kooky window; nil only when no kooky window exists.
    private var activeStore: WorkspaceStore? { activeController?.store }

    /// The key window when it is NOT a terminal window — Settings, About,
    /// the update prompt, a floating panel, or a sheet. The Close shortcuts
    /// must target it (or no-op) instead of riding `activeStore`'s fallback
    /// into a terminal window the user isn't looking at (issue #38).
    private var keyAuxiliaryWindow: NSWindow? {
        guard let key = NSApp.keyWindow, controller(for: key) == nil else { return nil }
        return key
    }

    /// Pushes edited agent templates into already-open tabs. Called from
    /// `KookySettingsModel.save()`; see `WorkspaceStore.refreshAgentTemplates`.
    func refreshAgentTemplates() {
        for controller in windowControllers {
            controller.store.refreshAgentTemplates()
        }
    }

    /// Re-applies `Theme.windowAppearance` to every kooky-owned window so a
    /// theme switch flips title bar / traffic lights / sheets in lockstep
    /// with the SwiftUI chrome. Enumerated rather than walking `NSApp.windows`
    /// because the latter touches system-spawned panels (alerts, color
    /// pickers) that aren't ours.

    func refreshThemeAppearances() {
        let appearance = Theme.windowAppearance
        // Glass needs non-opaque windows so the glass layer can sample the
        // desktop; reverting to opaque restores the default background so a
        // glass→off toggle doesn't leave a window see-through. Every kooky
        // window (main + the shared panels) carries glass on macOS 26.
        let auxiliary = [
            KookySettingsWindowController.shared.window,
            UpdatePromptWindowController.shared.window,
            CommandPaletteWindowController.shared.window,
            InboxWindowController.shared.window,
            AboutWindowController.shared.window,
        ]
        for window in windowControllers.map(\.window) + auxiliary {
            window?.appearance = appearance
            window?.applyGlassBacking()
        }
    }

    /// Terminal-style: the last window hides instead of closing
    /// (`shouldCloseWindow`); ⌘Q quits.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click / `open -a` with nothing on screen: bring the close-hidden
    /// window back (AppKit's default reopen only un-minimizes), or, with no
    /// window at all, restore the persisted set as a relaunch would.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !isTerminating, !hasVisibleWindows else { return true }
        if revealHiddenWindow() { return false }
        guard windowControllers.isEmpty else { return true }
        restoreWindows()
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReplyPending { return .terminateLater }

        // Runs before AppKit closes the windows, so every `windowWillClose`
        // that follows sees the flag and keeps its persisted slot. Start every
        // surface before waiting: one slow agent must not strand another tab.
        isTerminating = true
        for controller in windowControllers {
            controller.store.flushPersistence()
            controller.store.terminate()
        }
        guard !SurfaceTeardownCoordinator.shared.isDrained else { return .terminateNow }

        terminationReplyPending = true
        terminatingApplication = sender
        SurfaceTeardownCoordinator.shared.whenDrained { [weak self] in
            self?.finishDeferredTermination()
        }
        terminationFallback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.finishDeferredTermination()
        }
        return .terminateLater
    }

    private func finishDeferredTermination() {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        terminationFallback?.cancel()
        terminationFallback = nil
        terminatingApplication?.reply(toApplicationShouldTerminate: true)
        terminatingApplication = nil
    }

    public func applicationWillTerminate(_ notification: Notification) {
        terminationFallback?.cancel()
        terminationFallback = nil
        systemAppearanceObservation = nil
        // `windowWillClose` is not reliably delivered to every window during
        // app termination, so flush each live window's store here — the 1s
        // `scheduleSave` debounce would otherwise drop changes made in the
        // final second before ⌘Q.
        for controller in windowControllers {
            controller.store.flushPersistence()
        }
        // If closed-lid mode is engaged, re-enable lid sleep before dying —
        // a system-wide pmset flag outlives the process, unlike assertions.
        SleepGuard.shared.shutdownCleanup()
        agentMenuBarController?.stop()
        hookServer.stop()
        KookyShellIntegration.cleanup()
    }

    /// Returning to the foreground counts as seeing the active tab — clear its
    /// unread so a notification that landed while kooky was backgrounded doesn't
    /// strand the bell's red dot (the tab didn't change, so `activateTab`
    /// wouldn't fire).
    public func applicationDidBecomeActive(_ notification: Notification) {
        markVisibleSessionRead()
    }

    // MARK: - Menu

    /// Builds the menu bar at app launch. Keyboard shortcuts route through
    /// NSMenu first, so they fire even though `GhosttySurfaceView.keyDown`
    /// captures every other key — the menu system gets first dibs on `⌘x`
    /// before keyDown sees the event.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu — system-routed selectors via the responder chain. About
        // routes to our own handler so we can populate the panel without a
        // bundled Info.plist (the responder-chain default reads from there).
        mainMenu.addItem(submenu(buildMenu(title: KookyApp.name, entries: [
            selfRow("About \(KookyApp.name)", #selector(handleAbout)),
            selfRow("Check for Updates…", #selector(handleCheckForUpdates(_:))),
            .separator,
            selfRow("Settings…", #selector(handleOpenSettings), ","),
            .separator,
            responderRow("Hide \(KookyApp.name)", #selector(NSApplication.hide(_:)), "h"),
            responderRow("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
            responderRow("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator,
            responderRow("Quit \(KookyApp.name)", #selector(NSApplication.terminate(_:)), "q"),
        ])))

        openRecentMenu.title = String(localized: "Open Recent", bundle: .kookyResources)
        openRecentMenuDelegate.rebuild = { [weak self] menu in self?.rebuildOpenRecentMenu(menu) }
        openRecentMenu.delegate = openRecentMenuDelegate
        mainMenu.addItem(submenu(buildMenu(title: "File", entries: [
            selfRow("New Tab", #selector(handleNewTab), "t"),
            selfRow("New Workspace", #selector(handleNewWorkspace), "n"),
            selfRow("New SSH Workspace…", #selector(handleNewSSHWorkspace)),
            selfRow("New Window", #selector(handleNewWindow), "n", modifiers: [.command, .shift]),
            .separator,
            selfRow("Quick Open…", #selector(handleQuickOpen), "p"),
            selfRow("Notifications", #selector(handleShowInbox), "i", modifiers: [.command, .shift]),
            selfRow("Open Folder…", #selector(handleOpenFolder), "o"),
            .sub(openRecentMenu),
            .separator,
            selfRow("Close Tab", #selector(handleCloseTab), "w"),
            selfRow("Reopen Closed Tab", #selector(handleReopenClosedTab), "t", modifiers: [.command, .shift]),
            selfRow("Close Workspace", #selector(handleCloseWorkspace), "w", modifiers: [.command, .shift]),
            .separator,
            selfRow("Rename Tab…", #selector(handleRenameTab), "r"),
            selfRow("Rename Workspace…", #selector(handleRenameWorkspace), "r", modifiers: [.command, .shift]),
        ])))

        // Edit menu — first-responder selectors so libghostty's NSResponder
        // implementation handles copy/paste inside the surface.
        mainMenu.addItem(submenu(buildMenu(title: "Edit", entries: [
            responderRow("Cut", #selector(NSText.cut(_:)), "x"),
            responderRow("Copy", #selector(NSText.copy(_:)), "c"),
            responderRow("Paste", #selector(NSText.paste(_:)), "v"),
            responderRow("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator,
            selfRow("Find…", #selector(handleFind), "f"),
            selfRow("Find Next", #selector(handleFindNext), "g"),
            selfRow("Find Previous", #selector(handleFindPrevious), "g", modifiers: [.command, .shift]),
            .separator,
            selfRow("Compose Prompt…", #selector(handleComposePrompt), "l"),
        ])))

        let tabSwitchRows: [MenuEntry] = MenuTag.tabRange.map { n in
            selfRow(
                String.localizedStringWithFormat(
                    String(localized: "Tab %d", bundle: .kookyResources),
                    n
                ),
                #selector(handleSwitchTab(_:)),
                "\(n)",
                tag: MenuTag.tab(n)
            )
        }
        let workspaceSwitchRows: [MenuEntry] = (1...9).map { n in
            selfRow(
                String.localizedStringWithFormat(
                    String(localized: "Workspace %d", bundle: .kookyResources),
                    n
                ),
                #selector(handleSwitchWorkspace(_:)),
                "\(n)",
                modifiers: [.command, .option],
                tag: MenuTag.workspace(n)
            )
        }
        let viewEntries: [MenuEntry] = [
            selfRow("Toggle Sidebar", #selector(handleToggleSidebar), "s", modifiers: [.command, .control]),
            .separator,
            selfRow("Increase Font Size", #selector(handleIncreaseFontSize), "="),
            selfRow("Decrease Font Size", #selector(handleDecreaseFontSize), "-"),
            selfRow("Default Font Size", #selector(handleResetFontSize), "0"),
            .separator,
            selfRow("Clear Pane", #selector(handleClearScrollback), "k"),
            .separator,
            // Arrow function-keys via NSEvent's specialKey codepoints — AppKit
            // renders them as ↑/↓ glyphs in the menu. Routed through libghostty
            // bindings so the engine is the single source of truth on what
            // counts as a prompt boundary.
            selfRow("Jump to Previous Prompt", #selector(handleJumpToPreviousPrompt), "\u{F700}"),
            selfRow("Jump to Next Prompt", #selector(handleJumpToNextPrompt), "\u{F701}"),
            .separator,
            selfRow("Split Right", #selector(handleSplitRight), "d"),
            selfRow("Split Down", #selector(handleSplitDown), "d", modifiers: [.command, .shift]),
            selfRow("Zoom Pane", #selector(handleToggleZoom), "e", modifiers: [.command, .shift]),
            selfRow("Focus Previous Pane", #selector(handleFocusPreviousPane), "["),
            selfRow("Focus Next Pane", #selector(handleFocusNextPane), "]"),
            .separator,
            // ⌃⇥ / ⌃⇧⇥ cycle within the focused pane's tab list — same gesture
            // browsers use. Discrete from ⌘1-⌘9 below which jumps to a tab by
            // ordinal; cycle wraps at the ends and doesn't need a digit key.
            selfRow("Next Tab", #selector(handleNextTab), "\t", modifiers: [.control]),
            selfRow("Previous Tab", #selector(handlePreviousTab), "\t", modifiers: [.control, .shift]),
            .separator,
        ]
        + tabSwitchRows
        + [.separator]
        + workspaceSwitchRows
        + [
            .separator,
            responderRow("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]),
        ]
        let viewMenu = buildMenu(title: "View", entries: viewEntries)
        viewMenu.delegate = self
        mainMenu.addItem(submenu(viewMenu))

        let windowMenu = buildMenu(title: "Window", entries: [
            responderRow("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            responderRow("Zoom", #selector(NSWindow.performZoom(_:))),
            selfRow("Center", #selector(handleCenterWindow)),
        ])
        mainMenu.addItem(submenu(windowMenu))

        #if DEBUG
        mainMenu.addItem(submenu(buildMenu(title: "Debug", entries: [
            selfRow("Cycle Activity", #selector(handleCycleActivity), "a", modifiers: [.command, .shift]),
        ])))
        #endif

        let helpMenu = buildMenu(title: "Help", entries: [
            selfRow("Report an Issue", #selector(handleOpenIssues)),
            selfRow("View on GitHub", #selector(handleOpenRepo)),
        ])
        mainMenu.addItem(submenu(helpMenu))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - Menu DSL

    private struct MenuRow {
        let title: String
        let selector: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let target: AnyObject?
        let tag: Int
    }

    private enum MenuEntry {
        case row(MenuRow)
        case separator
        /// Nested submenu at this position (e.g. File → Open Recent, whose
        /// items a delegate rebuilds on every open).
        case sub(NSMenu)
    }

    /// Item routed to `self` — used for the AppDelegate's own `handle*`
    /// methods that need a concrete target.
    private func selfRow(_ title: String, _ selector: Selector, _ key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> MenuEntry {
        .row(MenuRow(
            title: String(
                localized: String.LocalizationValue(title),
                bundle: .kookyResources
            ),
            selector: selector,
            key: key,
            modifiers: modifiers,
            target: self,
            tag: tag
        ))
    }

    /// Item with `target: nil` — AppKit dispatches via the responder chain.
    /// Used for system selectors like `NSWindow.performZoom(_:)` and
    /// `NSText.cut(_:)`, which let libghostty / the active window handle them.
    private func responderRow(_ title: String, _ selector: Selector, _ key: String = "",
                              modifiers: NSEvent.ModifierFlags = .command) -> MenuEntry {
        .row(MenuRow(
            title: String(
                localized: String.LocalizationValue(title),
                bundle: .kookyResources
            ),
            selector: selector,
            key: key,
            modifiers: modifiers,
            target: nil,
            tag: 0
        ))
    }

    private func buildMenu(title: String, entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu(title: String(
            localized: String.LocalizationValue(title),
            bundle: .kookyResources
        ))
        for entry in entries {
            switch entry {
            case .row(let row):
                let item = NSMenuItem(title: row.title, action: row.selector, keyEquivalent: row.key)
                item.keyEquivalentModifierMask = row.modifiers
                item.target = row.target
                item.tag = row.tag
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .sub(let nested):
                menu.addItem(submenu(nested))
            }
        }
        return menu
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        // AppKit's menu bar renders the menu item's own title — submenu.title
        // isn't used as a fallback. An empty title degrades to "NSMenuItem"
        // in the bar, so copy the submenu's title across.
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    // MARK: - Menu actions

    @objc private func handleNewWindow() {
        // ⌘⇧N is already in-app, but the Dock-tile "New Window" can fire while
        // kooky is in the background — without activating, the new window opens
        // behind whatever app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        revealHiddenWindow()
        addWindow()
    }

    @objc private func handleNewTab() {
        revealHiddenWindow()
        guard let store = activeStore, let workspace = store.active else { return }
        // Keyboard convention: ⌘T is deterministic — open the user's default
        // agent if set, otherwise Terminal. The visual `+` button keeps the
        // "Ask each time" popover for mouse interaction.
        let template = AgentTemplate.defaultLaunchTemplate(model: KookySettingsModel.shared) ?? .terminal
        store.addTab(in: workspace, template: template)
    }

    @objc private func handleNewWorkspace() {
        revealHiddenWindow()
        activeStore?.addWorkspace()
    }

    /// File menu / command palette: the store parks the request and reveals
    /// a hidden sidebar; the animation wrap keeps the reveal from snapping
    /// (matches the palette's worktree-create routing).
    @objc private func handleNewSSHWorkspace() {
        revealHiddenWindow()
        guard let store = activeStore else { return }
        withAnimation(Theme.chromeTransition) {
            store.requestCreateSSHWorkspace()
        }
    }

    /// Rebuilt on every submenu open — folders that vanished from disk are
    /// filtered by `existing`, and duplicate folder names fall back to the
    /// abbreviated path so two repos both named `app` stay tellable apart.
    private func rebuildOpenRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let folders = RecentFolders.shared.existing
        let nameCounts = Dictionary(grouping: folders, by: \.lastPathComponent).mapValues(\.count)
        for url in folders {
            let abbreviated = (url.path as NSString).abbreviatingWithTildeInPath
            let title = nameCounts[url.lastPathComponent, default: 0] > 1 ? abbreviated : url.lastPathComponent
            let item = NSMenuItem(title: title, action: #selector(handleOpenRecentFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url.path
            item.toolTip = abbreviated
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !folders.isEmpty { menu.addItem(.separator()) }
        // macOS convention: Clear Menu is always present, disabled when
        // there's nothing to clear (nil action → auto-disabled). Enabled off
        // the RAW list, not the disk-filtered `folders`: when every recorded
        // dir is deleted/unmounted the menu shows empty, but the hidden
        // entries still hold list slots — Clear must stay reachable (Codex).
        let clear = NSMenuItem(
            title: String(localized: "Clear Menu", bundle: .kookyResources),
            action: RecentFolders.shared.paths.isEmpty ? nil : #selector(handleClearRecentFolders),
            keyEquivalent: ""
        )
        clear.target = self
        menu.addItem(clear)
    }

    /// One seam for both open-recent entry points (menu item + ⌘P palette)
    /// so a future behavior change — say, jump to an existing workspace
    /// instead of adding a duplicate — can't land in one and not the other
    /// (the `revealTab` precedent).
    private func openRecentFolder(atPath path: String) {
        revealHiddenWindow()
        activeStore?.addWorkspace(workingDirectory: URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc private func handleOpenRecentFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openRecentFolder(atPath: path)
    }

    @objc private func handleClearRecentFolders() {
        RecentFolders.shared.clear()
    }

    /// Internal (not `private`) so `#selector` in `ContentView` can typecheck.
    /// The runtime dispatch goes through Obj-C selectors either way.
    @objc func handleQuickOpen() {
        revealHiddenWindow()
        // Built fresh every open so a workspace added / tab renamed since
        // the panel was last shown reflects in the index without us
        // tracking invalidations. `toggle` makes ⌘P symmetric — press to
        // open, press again (or Esc) to dismiss.
        CommandPaletteWindowController.shared.toggle(
            items: { [weak self] in
                guard let self else { return [] }
                return PaletteIndex.build(
                    controllers: self.windowControllers,
                    model: KookySettingsModel.shared,
                    recentFolders: RecentFolders.shared.existing
                )
            },
            anchor: activeController?.window,
            onActivate: { [weak self] item in self?.activate(item) }
        )
    }

    /// Routes a palette pick to the owning window + workspace. Workspace
    /// and tab picks raise their owning window first so a cross-window
    /// jump lands in front. Agent / preset picks spawn in the *currently*
    /// active workspace (matches the muscle memory of ⌘T).
    private func activate(_ item: PaletteItem) {
        switch item.kind {
        case .workspace(let wsId, let winId):
            guard let target = windowControllers.first(where: { $0.windowId == winId }),
                  let ws = target.store.workspaces.first(where: { $0.id == wsId }) else { return }
            if let window = target.window { front(window) }
            target.store.activateWorkspace(ws)
        case .tab(let sId, let wsId, let winId):
            // `pane(containingSessionId:)` short-circuits on the first
            // matching pane; the codebase prefers it over `allPanes.first(where:)`
            // for tree walks (per PaneNode.swift doc).
            guard let target = windowControllers.first(where: { $0.windowId == winId }),
                  let ws = target.store.workspaces.first(where: { $0.id == wsId }),
                  let pane = ws.root.pane(containingSessionId: sId),
                  let session = pane.tabs.first(where: { $0.id == sId }) else { return }
            revealTab(session, in: ws, controller: target)
        case .createWorktree(let wsId, let winId):
            guard let target = windowControllers.first(where: { $0.windowId == winId }),
                  let ws = target.store.workspaces.first(where: { $0.id == wsId }) else { return }
            if let window = target.window { front(window) }
            target.store.activateWorkspace(ws)
            target.store.pendingCreateWorktreeRequest = ws
            if target.store.sidebarMode == .hidden {
                // Matches ContentView / View menu's reveal behaviour — without
                // the animation wrap the sidebar snaps from 0 to 220pt the moment
                // the palette routes a worktree-create request through.
                withAnimation(Theme.chromeTransition) {
                    target.store.setSidebarMode(.full)
                }
            }
        case .agent(let templateId):
            guard let store = activeStore, let ws = store.active else { return }
            let template = AgentTemplate.visibleOrdered(model: KookySettingsModel.shared)
                .first(where: { $0.id == templateId }) ?? .terminal
            store.addTab(in: ws, template: template)
        case .createSSHWorkspace:
            handleNewSSHWorkspace()
        case .openRecentFolder(let path):
            openRecentFolder(atPath: path)
        }
    }

    @objc private func handleOpenFolder() {
        revealHiddenWindow()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = String(localized: "Open Folder", bundle: .kookyResources)
        panel.message = String(localized: "Choose a folder to open as a workspace.", bundle: .kookyResources)

        let controller = activeController
        let store = controller?.store
        // Start the picker at the active workspace's cwd — the user is
        // usually picking something nearby (sibling project, parent dir).
        panel.directoryURL = store?.active?.workingDirectory

        let openPicked: () -> Void = {
            for url in panel.urls { store?.addWorkspace(workingDirectory: url) }
        }
        if let window = controller?.window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { openPicked() }
            }
        } else if panel.runModal() == .OK {
            openPicked()
        }
    }

    @objc private func handleCloseTab() {
        if let aux = keyAuxiliaryWindow {
            // ⌘W closes the auxiliary window itself, never a terminal tab
            // hidden behind it. Floating panels dismiss via their
            // controllers (orderOut, not close); sheets cancel through
            // their owning UI (open panel directly, sidebar sheets via the
            // store signal — their `@State` lives in `SidebarView`).
            if let panel = aux.windowController as? DismissablePanel {
                panel.dismiss()
            } else if let panel = aux as? NSSavePanel {
                panel.cancel(nil)
            } else if let parent = aux.sheetParent,
                      let controller = controller(for: parent) {
                controller.store.requestDismissActiveSheet()
            } else if aux.styleMask.contains(.closable) {
                aux.performClose(nil)
            }
            return
        }
        guard let store = activeStore, let workspace = store.active,
              let session = workspace.activeSession else { return }
        ConfirmCloseTab.request(session, in: workspace, store: store)
    }

    @objc private func handleReopenClosedTab() {
        activeStore?.reopenLastClosedTab()
    }

    @objc private func handleNextTab() {
        guard let store = activeStore, let workspace = store.active else { return }
        store.cycleTab(in: workspace, direction: 1)
    }

    @objc private func handlePreviousTab() {
        guard let store = activeStore, let workspace = store.active else { return }
        store.cycleTab(in: workspace, direction: -1)
    }

    @objc private func handleSplitRight() {
        guard let store = activeStore, let workspace = store.active,
              let pane = workspace.activePane else { return }
        store.splitPane(pane, orientation: .horizontal, in: workspace)
    }

    @objc private func handleSplitDown() {
        guard let store = activeStore, let workspace = store.active,
              let pane = workspace.activePane else { return }
        store.splitPane(pane, orientation: .vertical, in: workspace)
    }

    @objc private func handleToggleZoom() {
        guard let store = activeStore, let workspace = store.active else { return }
        // `withAnimation` (matching `handleToggleSidebar`) propagates the
        // transaction to *every* view change triggered by the mutation —
        // SplitContainer's fraction/offset morph AND the outer
        // PaneStatusBar visibility transition both animate together.
        withAnimation(Theme.chromeTransition) {
            store.toggleZoom(in: workspace)
        }
    }

    @objc private func handleFocusNextPane() {
        cyclePaneFocus(forward: true)
    }

    @objc private func handleFocusPreviousPane() {
        cyclePaneFocus(forward: false)
    }

    private func cyclePaneFocus(forward: Bool) {
        guard let store = activeStore, let workspace = store.active else { return }
        let panes = workspace.root.allPanes
        guard panes.count > 1 else { return }
        let currentId = workspace.activePaneId ?? panes.first?.id
        let idx = panes.firstIndex(where: { $0.id == currentId }) ?? 0
        store.focusPane(panes[panes.cyclicIndex(from: idx, step: forward ? 1 : -1)], in: workspace)
    }

    @objc private func handleCloseWorkspace() {
        guard keyAuxiliaryWindow == nil else { return }
        guard let store = activeStore, let workspace = store.active else { return }
        store.requestCloseWorkspace(workspace)
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Hidden NSMenuItems don't fire their keyEquivalents — pressing ⌘5
        // with 3 tabs is a no-op, matching what the menu shows.
        let store = activeStore
        let tabCount = store?.active?.activePane?.tabs.count ?? 0
        let workspaceCount = store?.workspaces.count ?? 0
        for item in menu.items {
            if MenuTag.tabRange.contains(item.tag) {
                item.isHidden = item.tag > tabCount
            } else if MenuTag.workspaceRange.contains(item.tag) {
                item.isHidden = MenuTag.workspaceIndex(from: item.tag) >= workspaceCount
            }
        }
    }

    /// App-scoped File/Window actions remain available while Settings or
    /// another auxiliary window is key. Terminal-scoped actions do not: a
    /// shortcut pressed in Settings must never mutate the last terminal
    /// window hidden behind it. AppKit asks this for both menu display and
    /// key-equivalent routing, which keeps the responder boundary in one
    /// native validation hook instead of duplicating guards in every action.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItemMatches(menuItem, #selector(handleCloseTab)) {
            if let auxiliary = keyAuxiliaryWindow {
                return auxiliary.windowController is DismissablePanel
                    || auxiliary is NSSavePanel
                    || auxiliary.sheetParent != nil
                    || auxiliary.styleMask.contains(.closable)
            }
            return activeStore?.active?.activeSession != nil
        }

        let terminalWindowIsKey = keyAuxiliaryWindow == nil

        if menuItemMatches(
            menuItem,
            #selector(handleFind),
            #selector(handleFindNext),
            #selector(handleFindPrevious),
            #selector(handleComposePrompt),
            #selector(handleRenameTab),
            #selector(handleIncreaseFontSize),
            #selector(handleDecreaseFontSize),
            #selector(handleResetFontSize),
            #selector(handleClearScrollback),
            #selector(handleJumpToPreviousPrompt),
            #selector(handleJumpToNextPrompt)
        ) {
            return terminalWindowIsKey && activeStore?.active?.activeSession != nil
        }

        if menuItemMatches(
            menuItem,
            #selector(handleSplitRight),
            #selector(handleSplitDown)
        ) {
            return terminalWindowIsKey && activeStore?.active?.activePane != nil
        }

        if menuItemMatches(menuItem, #selector(handleToggleZoom)) {
            return terminalWindowIsKey && (activeStore?.active?.canZoom ?? false)
        }

        if menuItemMatches(
            menuItem,
            #selector(handleFocusPreviousPane),
            #selector(handleFocusNextPane)
        ) {
            return terminalWindowIsKey
                && (activeStore?.active?.root.allPanes.count ?? 0) > 1
        }

        if menuItemMatches(
            menuItem,
            #selector(handleNextTab),
            #selector(handlePreviousTab)
        ) {
            return terminalWindowIsKey
                && (activeStore?.active?.activePane?.tabs.count ?? 0) > 1
        }

        if menuItemMatches(menuItem, #selector(handleSwitchTab(_:))) {
            let index = MenuTag.tabIndex(from: menuItem.tag)
            let count = activeStore?.active?.activePane?.tabs.count ?? 0
            return terminalWindowIsKey && index >= 0 && index < count
        }

        if menuItemMatches(menuItem, #selector(handleSwitchWorkspace(_:))) {
            let index = MenuTag.workspaceIndex(from: menuItem.tag)
            let count = activeStore?.workspaces.count ?? 0
            return terminalWindowIsKey && index >= 0 && index < count
        }

        if menuItemMatches(
            menuItem,
            #selector(handleToggleSidebar),
            #selector(handleCloseWorkspace),
            #selector(handleRenameWorkspace)
        ) {
            return terminalWindowIsKey && activeStore?.active != nil
        }

        if menuItemMatches(menuItem, #selector(handleReopenClosedTab)) {
            return terminalWindowIsKey && (activeStore?.canReopenClosedTab ?? false)
        }

        #if DEBUG
        if menuItemMatches(menuItem, #selector(handleCycleActivity)) {
            return terminalWindowIsKey && activeStore?.active?.activeSession != nil
        }
        #endif

        return true
    }

    private func menuItemMatches(_ item: NSMenuItem, _ selectors: Selector...) -> Bool {
        guard let action = item.action else { return false }
        return selectors.contains(action)
    }

    @objc private func handleIncreaseFontSize() {
        activeStore?.active?.activeSession?.engine.performAction("increase_font_size:1")
    }

    @objc private func handleDecreaseFontSize() {
        activeStore?.active?.activeSession?.engine.performAction("decrease_font_size:1")
    }

    @objc private func handleResetFontSize() {
        activeStore?.active?.activeSession?.engine.performAction("reset_font_size")
    }

    @objc private func handleClearScrollback() {
        activeStore?.active?.activeSession?.engine.performAction("clear_screen")
    }

    @objc private func handleJumpToPreviousPrompt() {
        activeStore?.active?.activeSession?.engine.performAction("jump_to_prompt:-1")
    }

    @objc private func handleJumpToNextPrompt() {
        activeStore?.active?.activeSession?.engine.performAction("jump_to_prompt:1")
    }

    @objc private func handleToggleSidebar() {
        guard let store = activeStore else { return }
        withAnimation(Theme.chromeTransition) {
            store.setSidebarMode(store.sidebarMode.next)
        }
    }

    @objc private func handleFind() {
        guard let session = activeStore?.active?.activeSession else { return }
        // ⌘F is a toggle on the active tab. Search state is per-session, so
        // ⌘F in pane A doesn't affect pane B's open search bar — both can
        // be active simultaneously, each with their own needle / count.
        if session.searchActive {
            session.engine.performAction("end_search")
        } else {
            session.engine.performAction("start_search")
        }
    }

    @objc private func handleComposePrompt() {
        guard let session = activeStore?.active?.activeSession else { return }
        // ⌘L toggles the composer on the active tab. Per-session, like search.
        session.composerActive.toggle()
    }

    @objc private func handleFindNext() {
        activeStore?.active?.activeSession?.engine.performAction("navigate_search:next")
    }

    @objc private func handleFindPrevious() {
        activeStore?.active?.activeSession?.engine.performAction("navigate_search:previous")
    }

    @objc private func handleRenameTab() {
        activeStore?.requestRenameActiveTab()
    }

    @objc private func handleRenameWorkspace() {
        activeStore?.requestRenameActiveWorkspace()
    }

    @objc private func handleAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func handleOpenIssues() {
        NSWorkspace.shared.open(KookyApp.issuesURL)
    }

    @objc private func handleOpenRepo() {
        NSWorkspace.shared.open(KookyApp.repositoryURL)
    }

    @objc private func handleCheckForUpdates(_ sender: NSMenuItem) {
        let originalTitle = sender.title
        sender.title = String(localized: "Checking for Updates…", bundle: .kookyResources)
        sender.isEnabled = false
        // KOOKY_FAKE_VERSION lets us preview the "newer release" prompt without
        // mutating KookyApp.displayVersion. Launch via:
        //   open --env KOOKY_FAKE_VERSION=0.11.0 /Applications/Kooky.app
        let currentVersion = ProcessInfo.processInfo.environment["KOOKY_FAKE_VERSION"]
            ?? KookyApp.displayVersion
        Task { @MainActor in
            let outcome = await UpdateChecker.check(currentVersion: currentVersion)
            sender.title = originalTitle
            sender.isEnabled = true
            UpdatePromptWindowController.present(outcome: outcome, currentVersion: currentVersion)
        }
    }

    @objc private func handleOpenSettings() {
        // Pass a live resolver, not a snapshot — the Settings window is a
        // singleton that outlives any one window; a captured store would
        // dangle once its window closed.
        KookySettingsWindowController.show(storeProvider: { [weak self] in self?.activeStore })
    }

    private func openKookyFromMenuBar() {
        NSApp.activate(ignoringOtherApps: true)
        if revealHiddenWindow() { return }
        guard let window = activeController?.window else { return }
        front(window)
    }

    @objc private func handleCenterWindow() {
        // NSWindow.center() takes no sender arg, so it can't be a direct
        // first-responder selector — wrap it.
        NSApp.keyWindow?.center()
    }

    @objc private func handleSwitchTab(_ sender: NSMenuItem) {
        let index = MenuTag.tabIndex(from: sender.tag)
        guard let store = activeStore, let workspace = store.active,
              let pane = workspace.activePane,
              index >= 0, index < pane.tabs.count else { return }
        store.activateTab(pane.tabs[index], in: workspace)
    }

    @objc private func handleSwitchWorkspace(_ sender: NSMenuItem) {
        let index = MenuTag.workspaceIndex(from: sender.tag)
        guard let store = activeStore,
              index >= 0, index < store.workspaces.count else { return }
        store.activateWorkspace(store.workspaces[index])
    }

    #if DEBUG
    /// Cycles through every dot state in precedence order: idle → running
    /// → failure → attention → idle. Used to preview the dot palette without
    /// running real agents / commands.
    @objc private func handleCycleActivity() {
        guard let session = activeStore?.active?.activeSession else { return }
        let isFailure = session.lastCommandExit.map { $0 != 0 } ?? false
        switch (session.activityState, isFailure) {
        case (.idle, false):
            session.activityState = .running
        case (.running, _):
            session.activityState = .idle
            session.lastCommandExit = 1
            session.lastCommandDuration = 0.42
        case (.idle, true):
            session.activityState = .attention
        case (.attention, _):
            session.activityState = .idle
            session.lastCommandExit = nil
            session.lastCommandDuration = nil
        }
    }
    #endif
}

/// Dedicated delegate for File → Open Recent. A separate object — not
/// `AppDelegate` — on purpose: (1) `menuHasKeyEquivalent` returning false
/// exempts this menu from AppKit's key-equivalent scan, which otherwise
/// calls `menuNeedsUpdate` on EVERY ⌘-keypress (hot in a terminal app) and
/// would re-stat every recent path + fetch its folder icon per keystroke;
/// (2) implementing that method on `AppDelegate` would also divert the View
/// menu, whose ⌘1-9 hidden-item gating depends on the `menuNeedsUpdate`
/// populate path.
private final class OpenRecentMenuDelegate: NSObject, NSMenuDelegate {
    var rebuild: (NSMenu) -> Void = { _ in }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false // recent items never carry key equivalents
    }
}
