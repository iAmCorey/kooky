import XCTest
@testable import KookyKit
import KookyHookKit

/// Pins `KookyCLIController`'s verb decisions against TestEngine stores —
/// the DeepLinkTests split: pure decisions here, window fronting manual.
/// Every dependency is injected; `revealed` / `activations` / `resumeCalls`
/// record the AppKit-facing seams.
@MainActor
final class CLIControllerTests: XCTestCase {
    private let dirA = "/tmp/kooky-cli-test-a"
    private let dirB = "/tmp/kooky-cli-test-b"
    /// A REAL symlink to `dirB`. `/tmp` itself can't serve as one: Foundation
    /// special-cases /tmp, /var and /etc, so `resolvingSymlinksInPath()`
    /// leaves `/tmp/...` alone and a fixture built on it silently tests
    /// nothing (the same trap the file tree hit in M5.pppp).
    private let dirBLink = "/tmp/kooky-cli-test-b-link"

    private var revealed: [(session: UUID, workspace: UUID)] = []
    private var activations = 0
    private var resumeCalls: [(agent: String, id: String, cwd: String?)] = []

    override func setUp() {
        super.setUp()
        revealed = []
        activations = 0
        resumeCalls = []
        for path in [dirA, dirB] {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try? FileManager.default.removeItem(atPath: dirBLink)
        try? FileManager.default.createSymbolicLink(atPath: dirBLink, withDestinationPath: dirB)
    }

    private func makeStore() -> WorkspaceStore { makeTestStore() }

    private func makeController(
        stores: [WorkspaceStore],
        keyIndex: Int = 0,
        templates: [AgentTemplate] = [.terminal],
        resumeOutcome: ResumeRequestOutcome = .opened,
        isShuttingDown: Bool = false,
        fallbackStore: WorkspaceStore? = nil,
        anchorWindow: NSWindow? = nil
    ) -> KookyCLIController {
        let context: @MainActor (WorkspaceStore, Bool) -> KookyCLIController.WindowContext = { [weak self] store, isKey in
            KookyCLIController.WindowContext(
                store: store,
                isKey: isKey,
                reveal: { session, workspace in self?.revealed.append((session.id, workspace.id)) },
                window: { anchorWindow }
            )
        }
        return KookyCLIController(
            appVersion: "9.9.9-test",
            windows: { stores.enumerated().map { context($1, $0 == keyIndex) } },
            // A store passed as `fallbackStore` stands in for a window the
            // fallback had to BUILD; falling back to `stores.first` is an
            // already-open window it merely found.
            fallbackWindow: {
                if let built = fallbackStore { return (context(built, true), true) }
                return stores.first.map { (context($0, true), false) }
            },
            activateApp: { [weak self] in self?.activations += 1 },
            isShuttingDown: { isShuttingDown },
            templates: { templates },
            resume: { [weak self] agent, id, cwd, _, completion in
                self?.resumeCalls.append((agent, id, cwd))
                completion(resumeOutcome)
            }
        )
    }

    /// `open` hops off-main for its cwd stat, so responses are awaited; the
    /// continuation resuming exactly once IS the handler's completion
    /// contract (a leaked completion hangs the test).
    private func respond(_ controller: KookyCLIController, _ request: KookyCLIRequest) async -> KookyCLIResponse {
        await withCheckedContinuation { continuation in
            controller.handle(request) { continuation.resume(returning: $0) }
        }
    }

    private func engine(_ session: Session) -> TestEngine {
        session.engine as! TestEngine
    }

    // MARK: status / protocol gate

    func testStatusCarriesVersion() async {
        let controller = makeController(stores: [makeStore()])
        let response = await respond(controller, KookyCLIRequest(verb: .status))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.appVersion, "9.9.9-test")
        XCTAssertEqual(response.protocolVersion, KookyCLIProtocol.version)
    }

    func testNewerProtocolIsRefused() async {
        let controller = makeController(stores: [makeStore()])
        var request = KookyCLIRequest(verb: .status)
        request.protocolVersion = KookyCLIProtocol.version + 1
        let response = await respond(controller, request)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("protocol") == true)
    }

    func testUnknownVerbIsRefused() async {
        let controller = makeController(stores: [makeStore()])
        var request = KookyCLIRequest(verb: .status)
        request.verb = "dance"
        let response = await respond(controller, request)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("unknown verb") == true)
    }

    // MARK: list

    func testListWalksWindowsWorkspacesAndTabs() async throws {
        let store = makeStore()
        let workspace = store.workspaces[0]
        store.addTab(in: workspace, template: .claudeCode)
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .list))
        let windows = try XCTUnwrap(response.windows)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows[0].isKey)
        let ws = try XCTUnwrap(windows[0].workspaces.first)
        XCTAssertTrue(ws.isActive)
        XCTAssertEqual(ws.tabs.count, 2)
        let shellTab = ws.tabs[0]
        XCTAssertEqual(shellTab.agent, "terminal")
        XCTAssertNil(shellTab.agentState)
        XCTAssertFalse(shellTab.isActive)
        let agentTab = ws.tabs[1]
        XCTAssertEqual(agentTab.agent, "claude-code")
        XCTAssertEqual(agentTab.agentState, "idle")
        XCTAssertTrue(agentTab.isActive)
        XCTAssertEqual(agentTab.id, workspace.activeSession?.id.uuidString)
    }

    // MARK: open

    func testOpenPlainTerminalTab() async throws {
        let store = makeStore()
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA))
        XCTAssertTrue(response.ok)
        let session = try XCTUnwrap(store.active?.activeSession)
        XCTAssertEqual(response.tabId, session.id.uuidString)
        XCTAssertEqual(engine(session).startedConfigs.first?.workingDirectory, dirA)
        XCTAssertNil(engine(session).startedConfigs.first?.environment["KOOKY_AGENT"])
        XCTAssertEqual(revealed.last?.session, session.id)
        XCTAssertEqual(activations, 1)
    }

    func testOpenWithCommandRidesKookyAgent() async throws {
        let store = makeStore()
        let controller = makeController(stores: [store])
        let command = "npx @deepseek-ai/dsh web"
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA, command: command))
        XCTAssertTrue(response.ok)
        let session = try XCTUnwrap(store.active?.activeSession)
        XCTAssertEqual(engine(session).startedConfigs.first?.environment["KOOKY_AGENT"], command)
        XCTAssertEqual(engine(session).startedConfigs.first?.workingDirectory, dirA)
        XCTAssertTrue(session.agent.isShell, "a raw command tab stays a shell tab — wrappers promote the icon if it's an agent")
    }

    func testOpenWithAgentTemplate() async throws {
        let store = makeStore()
        let controller = makeController(stores: [store], templates: [.terminal, .claudeCode])
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA, agent: "claude-code"))
        XCTAssertTrue(response.ok)
        let session = try XCTUnwrap(store.active?.activeSession)
        XCTAssertEqual(session.agent.id, "claude-code")
        XCTAssertEqual(engine(session).startedConfigs.first?.environment["KOOKY_AGENT"], "claude")
        XCTAssertEqual(engine(session).startedConfigs.first?.workingDirectory, dirA)
    }

    func testOpenAgentIdMatchesCaseInsensitively() async throws {
        // The resume door lowercases agent ids (deep-link grammar); the open
        // door accepts the same spelling via a unique case-folded match.
        let store = makeStore()
        let controller = makeController(stores: [store], templates: [.terminal, .claudeCode])
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA, agent: "Claude-Code"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(store.active?.activeSession?.agent.id, "claude-code")
    }

    func testOpenRefusesBadCwd() async {
        let store = makeStore()
        let controller = makeController(stores: [store])
        let missing = await respond(controller, KookyCLIRequest(verb: .open, cwd: "/tmp/kooky-cli-test-definitely-missing"))
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(missing.error?.contains("does not exist") == true)
        let relative = await respond(controller, KookyCLIRequest(verb: .open, cwd: "relative/path"))
        XCTAssertFalse(relative.ok)
        XCTAssertTrue(relative.error?.contains("absolute") == true)
        XCTAssertEqual(store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count, 1, "refusals must not spawn tabs")
    }

    /// `open` hops off-main to stat an untrusted cwd; ⌘Q can land during
    /// that hop. Adding a session after the terminate drain has flushed
    /// every store to state.json both loses the tab and briefly runs it.
    /// `guard let self` does not catch this — the controller is an
    /// AppDelegate property that outlives the drain.
    func testOpenIsDroppedWhileShuttingDown() async {
        let store = makeStore()
        let controller = makeController(stores: [store], isShuttingDown: true)
        let before = store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(
            store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count,
            before,
            "a request landing after the quit drain must not spawn a session"
        )
        XCTAssertEqual(activations, 0, "and must not yank a quitting app frontmost")
    }

    /// When every workspace is remote, `open` has to create a local one.
    /// That new workspace already comes up with a tab, so adding a second
    /// one beside it left a blank shell and a stray PTY behind every call.
    func testOpenIntoAnAllSSHWindowLeavesExactlyOneTab() async throws {
        let store = makeStore()
        for workspace in store.workspaces { workspace.sshRemoteHost = "build-box" }
        let controller = makeController(stores: [store])

        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA, command: "make test"))
        XCTAssertTrue(response.ok)

        let local = try XCTUnwrap(store.workspaces.first { $0.sshRemoteHost == nil })
        let tabs = local.root.allPanes.flatMap(\.tabs)
        XCTAssertEqual(tabs.count, 1, "one `open` must produce one tab, not a blank shell plus the real one")
        XCTAssertEqual(response.tabId, tabs.first?.id.uuidString)
        // The surviving tab is the REQUESTED launch, not a default shell.
        XCTAssertEqual(engine(try XCTUnwrap(tabs.first)).startedConfigs.first?.environment["KOOKY_AGENT"], "make test")
    }

    /// A pending confirm sheet belongs to ONE tab — its decision closure
    /// captured that tab. Answering "confirmation shown" for a different
    /// tab tells the caller a dialog is up that will never act on its
    /// request: the user answers, tab A closes, tab B was never touched,
    /// and the CLI already reported success.
    func testConfirmCloseRefusesASecondTabWhileAnotherConfirmationIsUp() throws {
        _ = NSApplication.shared
        let store = makeStore()
        let workspace = store.workspaces[0]
        let first = try XCTUnwrap(workspace.activeSession)
        let second = store.addTab(in: workspace)
        engine(first).needsConfirmQuit = true
        engine(second).needsConfirmQuit = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        let opened = ConfirmCloseTab.request(first, in: workspace, store: store, anchorWindow: window)
        XCTAssertEqual(opened, .confirming)

        // Asking again about the SAME tab is genuinely idempotent.
        XCTAssertEqual(
            ConfirmCloseTab.request(first, in: workspace, store: store, anchorWindow: window),
            .confirming
        )

        // A DIFFERENT tab must be refused, not absorbed into A's sheet.
        XCTAssertEqual(
            ConfirmCloseTab.request(second, in: workspace, store: store, anchorWindow: window),
            .windowBusy
        )
        XCTAssertTrue(
            workspace.root.allPanes.flatMap(\.tabs).contains { $0.id == second.id },
            "the refused tab must still be open — nothing acted on it"
        )
    }

    /// With Settings/About keeping the app alive but no terminal window
    /// left, `open` has to build the window itself — and a new window is
    /// born with a tab. Landing the requested tab beside it left a blank
    /// shell and a second PTY the caller never learns about (it only gets
    /// one id back, so it can't close the stray one either).
    func testOpenThatBuildsTheWindowLeavesExactlyOneTab() async throws {
        // A store fresh out of `addWindow()`: one workspace, one seed tab.
        let built = makeStore()
        let controller = makeController(stores: [], fallbackStore: built)

        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA, command: "make test"))
        XCTAssertTrue(response.ok)

        let tabs = built.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }
        XCTAssertEqual(tabs.count, 1, "the window's seed tab must not outlive the call that built it")
        let survivor = try XCTUnwrap(tabs.first)
        XCTAssertEqual(response.tabId, survivor.id.uuidString, "and the survivor is the tab the caller was told about")
        XCTAssertEqual(engine(survivor).startedConfigs.first?.environment["KOOKY_AGENT"], "make test")
    }

    /// The mirror of the above, and the more important half: when kooky
    /// already HAS a window, its tabs are the user's. `open` adds to them
    /// and must never tidy one away.
    func testOpenIntoAnExistingWindowKeepsTheTabsAlreadyThere() async throws {
        let store = makeStore()
        let workspace = store.workspaces[0]
        let existing = try XCTUnwrap(workspace.activeSession)
        let controller = makeController(stores: [store])

        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA))
        XCTAssertTrue(response.ok)

        let tabs = store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(tabs.contains { $0.id == existing.id }, "the user's own tab must survive an `open`")
    }

    /// Repeat "open in kooky" calls for one project pile into that
    /// project's workspace instead of scattering across the window.
    func testOpenPilesIntoTheWorkspaceAlreadyRootedAtThatDirectory() async throws {
        let store = makeStore()
        let target = store.addWorkspace(workingDirectory: URL(fileURLWithPath: dirB))
        // Hand ACTIVE back to the seed workspace. `addWorkspace` activates
        // what it creates, and the placement ladder falls back to the active
        // workspace — so leaving `target` active makes a match and a total
        // miss land in the same place, and the assertion below would hold
        // either way (verified: it did, until this line existed).
        store.activateWorkspace(store.workspaces[0])
        let controller = makeController(stores: [store])

        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirB))
        XCTAssertTrue(response.ok)

        let landedHere = target.root.allPanes.flatMap(\.tabs).contains { $0.id.uuidString == response.tabId }
        XCTAssertTrue(landedHere, "the tab belongs in the workspace already rooted at that directory")
    }

    /// The match is on RESOLVED paths, which is why it survives the caller
    /// and the workspace spelling the same directory differently — the
    /// everyday case, since a shell reports the LOGICAL cwd while the
    /// workspace may hold either spelling.
    func testOpenMatchesAWorkspaceThroughASymlinkedSpelling() async throws {
        let store = makeStore()
        let target = store.addWorkspace(workingDirectory: URL(fileURLWithPath: dirB))
        store.activateWorkspace(store.workspaces[0])   // see the note above
        let controller = makeController(stores: [store])
        // Prove the fixture is a link that actually resolves, or the test
        // would pass for the wrong reason.
        try XCTSkipUnless(
            URL(fileURLWithPath: dirBLink).resolvingSymlinksInPath().path == dirB,
            "symlink fixture unavailable"
        )

        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirBLink))
        XCTAssertTrue(response.ok)

        let landedHere = target.root.allPanes.flatMap(\.tabs).contains { $0.id.uuidString == response.tabId }
        XCTAssertTrue(landedHere, "\(dirBLink) and \(dirB) are the same directory and must match")

        // The other direction, because both sides get resolved: here the
        // WORKSPACE holds the symlinked spelling (a folder dragged in via
        // its link) and the caller passes the real path.
        let reverseStore = makeStore()
        let reverseTarget = reverseStore.addWorkspace(workingDirectory: URL(fileURLWithPath: dirBLink))
        reverseStore.activateWorkspace(reverseStore.workspaces[0])
        let reverseController = makeController(stores: [reverseStore])

        let reverse = await respond(reverseController, KookyCLIRequest(verb: .open, cwd: dirB))
        XCTAssertTrue(reverse.ok)
        let landedThere = reverseTarget.root.allPanes.flatMap(\.tabs).contains { $0.id.uuidString == reverse.tabId }
        XCTAssertTrue(landedThere, "a workspace rooted through the link must match the real path too")
    }

    /// A Terminal preset IS a pinned directory, so `--cwd` is optional for
    /// one. Before this, `--cwd` was mandatory and always won, which meant
    /// naming a preset changed nothing about where the tab opened — the one
    /// thing a preset is for.
    func testOpenWithATerminalPresetUsesThePresetsOwnDirectory() async throws {
        let preset = AgentTemplate.fromTerminalPreset(TerminalPreset(id: "preset-1", title: "Notes", path: dirB))
        let store = makeStore()
        let controller = makeController(stores: [store], templates: [.terminal, preset])

        let response = await respond(controller, KookyCLIRequest(verb: .open, agent: "preset-1"))
        XCTAssertTrue(response.ok, response.error ?? "")

        let session = try XCTUnwrap(store.active?.activeSession)
        XCTAssertEqual(engine(session).startedConfigs.first?.workingDirectory, dirB)
    }

    /// Precedence matches `WorkspaceStore.addTab`: an explicit path wins
    /// over the preset's pinned one, because the caller said where.
    func testExplicitCwdWinsOverAPresetsOwnDirectory() async throws {
        let preset = AgentTemplate.fromTerminalPreset(TerminalPreset(id: "preset-1", title: "Notes", path: dirB))
        let store = makeStore()
        let controller = makeController(stores: [store], templates: [.terminal, preset])

        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA, agent: "preset-1"))
        XCTAssertTrue(response.ok, response.error ?? "")

        let session = try XCTUnwrap(store.active?.activeSession)
        XCTAssertEqual(engine(session).startedConfigs.first?.workingDirectory, dirA)
    }

    /// Only presets carry a directory — everything else still needs one, and
    /// the refusal has to say which case it is.
    /// Issue #56: no `--cwd` means "wherever I already am" — the tab lands in
    /// the active workspace and inherits ITS directory, rather than being
    /// refused or guessing at one.
    func testOpenWithoutCwdLandsInTheActiveWorkspaceDirectory() async throws {
        let store = makeStore()
        let target = store.addWorkspace(workingDirectory: URL(fileURLWithPath: dirB))
        let controller = makeController(stores: [store], templates: [.terminal, .claudeCode])

        let response = await respond(controller, KookyCLIRequest(verb: .open, agent: "claude-code"))
        XCTAssertTrue(response.ok, "no directory named is a legitimate request: \(response.error ?? "")")

        let session = try XCTUnwrap(target.activeSession)
        XCTAssertEqual(response.tabId, session.id.uuidString)
        XCTAssertEqual(session.agent.id, "claude-code")
        XCTAssertEqual(
            engine(session).startedConfigs.first?.workingDirectory, dirB,
            "the tab inherits the active workspace's own directory"
        )
    }

    /// A directory that WAS named still has to be usable — dropping the
    /// required-ness of `--cwd` must not drop its validation.
    func testOpenStillValidatesADirectoryThatWasNamed() async {
        let controller = makeController(stores: [makeStore()])
        let relative = await respond(controller, KookyCLIRequest(verb: .open, cwd: "relative/path"))
        XCTAssertFalse(relative.ok)
        XCTAssertTrue(relative.error?.contains("absolute") == true)

        let missing = await respond(controller, KookyCLIRequest(verb: .open, cwd: "/tmp/kooky-cli-test-definitely-missing"))
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(missing.error?.contains("does not exist") == true)
    }

    /// The bound has to be a RACE. A blocked synchronous `realpath`/`stat`
    /// never returns, so an elapsed-time check written after the await can
    /// never run — which is exactly how the first version of this deadline
    /// was wrong.
    func testOffMainTimeoutGivesUpOnACallThatNeverReturns() async {
        let started = ContinuousClock.now
        let result: Int? = await withOffMainTimeout(.milliseconds(200)) {
            Thread.sleep(forTimeInterval: 5)   // stands in for a dead mount
            return 42
        }
        XCTAssertNil(result, "a stuck call must surface as nil, not as its eventual value")
        XCTAssertLessThan(
            ContinuousClock.now - started, .seconds(3),
            "the caller must be released on the deadline, not when the filesystem gives up"
        )
    }

    func testOffMainTimeoutReturnsTheValueWhenItArrivesInTime() async {
        let result: Int? = await withOffMainTimeout(.seconds(5)) { 7 }
        XCTAssertEqual(result, 7)
    }

    /// `RequestDeadline` bounds the REQUEST; `withOffMainTimeout` bounds one
    /// piece of blocking work. Conflating them removed the end-to-end check
    /// once already, so pin the distinction: a budget that has run out says
    /// so even though no blocking work is involved at all.
    func testRequestDeadlineExpiresIndependentlyOfAnyWork() {
        XCTAssertTrue(RequestDeadline(.zero).hasExpired)
        XCTAssertFalse(RequestDeadline(.seconds(60)).hasExpired)
    }

    /// The heaviest case in this whole seam: `open -e` runs an arbitrary
    /// command. If the caller ^C'd (or timed out) while the directory scan
    /// ran, spawning anyway executes that command for someone who was told
    /// the request failed — and who may have retried, so it runs twice.
    func testOpenIsAbandonedWhenTheCallerStopsWaiting() async {
        let store = makeStore()
        let controller = makeController(stores: [store])
        let before = store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count

        let response: KookyCLIResponse = await withCheckedContinuation { continuation in
            controller.handle(
                KookyCLIRequest(verb: .open, cwd: dirA, command: "touch /tmp/should-never-run"),
                isCallerWaiting: { false }
            ) { continuation.resume(returning: $0) }
        }

        XCTAssertFalse(response.ok)
        XCTAssertEqual(
            store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count, before,
            "no tab — and therefore no command — for a caller that already left"
        )
        XCTAssertEqual(activations, 0, "and no stealing focus for it either")
    }

    /// A probe budget equal to the request budget makes every fallback that
    /// depends on the probe timing out UNREACHABLE — the request deadline
    /// starts first and is read after the probe returns, so it has always
    /// expired by then. That arithmetic silently killed `resume --cwd` for a
    /// project whose recorded directory had moved. Pin the relation on both
    /// paths so a future tweak to either number has to stay honest.
    func testProbeBudgetsStayUnderTheirRequestBudgets() {
        XCTAssertLessThan(
            KookyCLIController.directoryProbeBudget,
            KookyCLIController.asyncVerbDeadline,
            "an open probe that runs its full length must still leave the request alive"
        )
        XCTAssertLessThan(
            AppDelegate.resumeProbeBudget,
            AppDelegate.resumeRequestBudget,
            "a resume probe timing out must leave room to use the caller's cwd instead"
        )
    }

    func testOpenRefusesUnknownAgentAndListsKnownIds() async {
        let controller = makeController(stores: [makeStore()], templates: [.terminal, .claudeCode])
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA, agent: "hal9000"))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("hal9000") == true)
        XCTAssertTrue(response.error?.contains("claude-code") == true)
    }

    func testOpenRefusesCommandPlusAgent() async {
        let controller = makeController(stores: [makeStore()], templates: [.terminal, .claudeCode])
        let response = await respond(
            controller,
            KookyCLIRequest(verb: .open, cwd: dirA, command: "ls", agent: "claude-code")
        )
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("mutually exclusive") == true)
    }

    func testOpenPrefersWorkspaceAlreadyRootedAtCwd() async throws {
        let store = makeStore()
        let matching = store.addWorkspace(workingDirectory: URL(fileURLWithPath: dirA))
        store.activateWorkspace(store.workspaces[0])
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA))
        XCTAssertTrue(response.ok)
        let tab = try XCTUnwrap(matching.root.allPanes.flatMap(\.tabs).last)
        XCTAssertEqual(response.tabId, tab.id.uuidString)
        XCTAssertEqual(revealed.last?.workspace, matching.id)
    }

    func testOpenSkipsSSHWorkspacesAndFallsBackToLocal() async throws {
        let store = makeStore()
        let ssh = store.addWorkspace(workingDirectory: URL(fileURLWithPath: dirB), sshRemoteHost: "devbox")
        XCTAssertEqual(store.activeWorkspaceId, ssh.id)
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA))
        XCTAssertTrue(response.ok)
        let local = store.workspaces[0]
        XCTAssertNil(local.sshRemoteHost)
        XCTAssertEqual(revealed.last?.workspace, local.id, "an SSH-active window must land the tab in a local workspace")
        let session = try XCTUnwrap(local.root.allPanes.flatMap(\.tabs).last)
        XCTAssertNil(engine(session).startedConfigs.first?.environment["KOOKY_AGENT"], "local open must not be wrapped in kooky-ssh")
    }

    func testOpenCreatesLocalWorkspaceWhenEveryWorkspaceIsSSH() async throws {
        let store = makeStore()
        store.workspaces[0].sshRemoteHost = "devbox"
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .open, cwd: dirA))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(store.workspaces.count, 2)
        let created = try XCTUnwrap(store.workspaces.last)
        XCTAssertNil(created.sshRemoteHost)
        XCTAssertEqual(created.workingDirectory.path, dirA)
        XCTAssertEqual(revealed.last?.workspace, created.id)
    }

    func testOpenWithTitleSeedsTheUserOverrideFromTheFirstFrame() async throws {
        let store = makeStore()
        let controller = makeController(stores: [store])
        let response = await respond(
            controller,
            KookyCLIRequest(verb: .open, cwd: dirA, title: "  build watcher  ")
        )
        XCTAssertTrue(response.ok)
        let session = try XCTUnwrap(store.active?.activeSession)
        XCTAssertEqual(session.customTitle, "build watcher", "title normalizes like the rename popover's")
        XCTAssertEqual(session.title, "build watcher", "the override outranks the cwd-derived title")
    }

    func testOpenNoFocusLandsTheTabInTheBackground() async throws {
        let store = makeStore()
        let workspace = store.workspaces[0]
        let visible = try XCTUnwrap(workspace.activeSession)
        var request = KookyCLIRequest(verb: .open, cwd: dirA)
        request.noFocus = true
        let controller = makeController(stores: [store])
        let response = await respond(controller, request)
        XCTAssertTrue(response.ok)
        let tabs = workspace.root.allPanes.flatMap(\.tabs)
        XCTAssertEqual(tabs.count, 2)
        let opened = try XCTUnwrap(tabs.first { $0.id.uuidString == response.tabId })
        XCTAssertEqual(engine(opened).startedConfigs.first?.workingDirectory, dirA)
        XCTAssertEqual(
            workspace.activeSession?.id, visible.id,
            "a background tab must not replace what the user is looking at"
        )
        XCTAssertTrue(revealed.isEmpty, "no window fronting")
        XCTAssertEqual(activations, 0, "no app activation")
        XCTAssertTrue(
            response.note?.contains("background") == true,
            "the answer states the tab is running, not waiting to be shown"
        )
        // "Background" means the command RUNS (issue #59): the whole spawn
        // chain must be armed — the engine exempted from the hidden gate,
        // and the session flagged so PaneView keeps an offscreen mount up.
        XCTAssertTrue(opened.spawnsInBackground)
        XCTAssertTrue(engine(opened).spawnsWhileHidden)
    }

    func testBackgroundSpawnFlagSurvivesActivateThenSwitchAway() async throws {
        // Activation is a model write; the offscreen mount is a NEXT-FRAME
        // view effect. Clearing the flag on activation raced the two: an
        // activate-then-switch-away landing inside one render commit
        // stranded a never-spawned tab (Codex P2). The flag is lifelong —
        // after switching away it must still be set, so PaneView's filter
        // brings the hidden mount back and the shell still spawns.
        let store = makeStore()
        let workspace = store.workspaces[0]
        let original = try XCTUnwrap(workspace.activeSession)
        var request = KookyCLIRequest(verb: .open, cwd: dirA)
        request.noFocus = true
        let controller = makeController(stores: [store])
        let response = await respond(controller, request)
        let opened = try XCTUnwrap(
            workspace.root.allPanes.flatMap(\.tabs).first { $0.id.uuidString == response.tabId }
        )
        XCTAssertTrue(opened.spawnsInBackground)
        store.activateTab(opened, in: workspace)
        store.activateTab(original, in: workspace)
        XCTAssertTrue(
            opened.spawnsInBackground,
            "the flag must survive an activate-then-switch-away so the offscreen mount returns"
        )
    }

    func testOpenNoFocusWithZeroTerminalWindowsIsRefusedBeforeBuildingOne() async {
        // The window-building fallback fronts what it builds — exactly the
        // promise --no-focus makes. Refusing must come BEFORE the side
        // effect: a fallback invocation here is itself the failure.
        let controller = KookyCLIController(
            appVersion: "9.9.9-test",
            windows: { [] },
            fallbackWindow: {
                XCTFail("--no-focus must never build (and front) a window")
                return nil
            },
            activateApp: { [weak self] in self?.activations += 1 },
            templates: { [.terminal] },
            resume: { _, _, _, _, completion in completion(.opened) }
        )
        var request = KookyCLIRequest(verb: .open, cwd: dirA)
        request.noFocus = true
        let response = await respond(controller, request)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("no terminal window") == true)
        XCTAssertEqual(activations, 0)
    }

    func testOpenNoFocusIntoAFreshWorkspaceKeepsTheActiveWorkspace() async throws {
        let store = makeStore()
        store.workspaces[0].sshRemoteHost = "devbox"
        let sshWorkspace = store.workspaces[0]
        var request = KookyCLIRequest(verb: .open, cwd: dirA)
        request.noFocus = true
        let controller = makeController(stores: [store])
        let response = await respond(controller, request)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(
            store.activeWorkspaceId, sshWorkspace.id,
            "the fresh workspace appears in the sidebar without stealing the active one"
        )
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertEqual(activations, 0)
    }

    // MARK: focus

    func testFocusRevealsTheTab() async throws {
        let store = makeStore()
        let session = try XCTUnwrap(store.active?.activeSession)
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .focus, tab: session.id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(revealed.last?.session, session.id)
        XCTAssertEqual(activations, 1)
    }

    func testFocusUnknownTabIsRefused() async {
        let controller = makeController(stores: [makeStore()])
        let response = await respond(controller, KookyCLIRequest(verb: .focus, tab: UUID().uuidString))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("no tab with id") == true)
        XCTAssertTrue(revealed.isEmpty)
    }

    // MARK: close

    func testCloseRemovesTheTabWithoutConfirmWhenEngineDoesNotAsk() async {
        let store = makeStore()
        let workspace = store.workspaces[0]
        let extra = store.addTab(in: workspace)
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .close, tab: extra.id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.note, "closed")
        XCTAssertFalse(workspace.root.allPanes.flatMap(\.tabs).contains { $0.id == extra.id })
        XCTAssertTrue(revealed.isEmpty, "a silent close must not yank the app frontmost")
        XCTAssertEqual(activations, 0)
    }

    func testCloseWithNoAnchorableWindowClosesSilentlyAndSaysSo() async throws {
        // The engine wants a confirmation, but the injected window() is nil
        // and NSApp has no key window, so ConfirmCloseTab has nothing to
        // anchor a sheet on and falls back to a plain close. Two things
        // follow, and both are about reporting FACTS over the pre-read:
        // the note says "closed" (not "confirmation shown"), and nothing is
        // fronted or revealed — no confirmation reached the screen, so the
        // call has no business stealing focus or pointing at a tab it just
        // destroyed. ConfirmCloseTab reads NSApp.keyWindow (an IUO), so make
        // sure the shared application exists when this test runs alone.
        _ = NSApplication.shared
        try XCTSkipIf(NSApp?.keyWindow != nil, "a key window would host a real confirm sheet")
        let store = makeStore()
        let workspace = store.workspaces[0]
        let extra = store.addTab(in: workspace)
        engine(extra).needsConfirmQuit = true
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .close, tab: extra.id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.note, "closed")
        XCTAssertFalse(workspace.root.allPanes.flatMap(\.tabs).contains { $0.id == extra.id })
        XCTAssertTrue(revealed.isEmpty, "no confirmation was shown, so nothing should have been revealed")
        XCTAssertEqual(activations, 0, "a silent background close must not front the app")
    }

    /// A close refused because the window is already confirming ANOTHER tab
    /// changed nothing — so it must not change what the user is looking at
    /// either. Revealing B underneath a sheet that asks about A is worse
    /// than not revealing at all.
    func testCloseRefusedAsWindowBusyLeavesTheViewAlone() async throws {
        _ = NSApplication.shared
        let store = makeStore()
        let workspace = store.workspaces[0]
        let first = try XCTUnwrap(workspace.activeSession)
        let second = store.addTab(in: workspace)
        engine(first).needsConfirmQuit = true
        engine(second).needsConfirmQuit = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // Park a confirmation for `first` on that window.
        XCTAssertEqual(
            ConfirmCloseTab.request(first, in: workspace, store: store, anchorWindow: window),
            .confirming
        )

        let controller = makeController(stores: [store], anchorWindow: window)
        let response = await respond(controller, KookyCLIRequest(verb: .close, tab: second.id.uuidString))

        XCTAssertFalse(response.ok)
        XCTAssertTrue(revealed.isEmpty, "a refused close must not switch the visible tab")
        XCTAssertEqual(activations, 0, "nor front the app for something it declined to do")
        XCTAssertTrue(
            workspace.root.allPanes.flatMap(\.tabs).contains { $0.id == second.id },
            "and the tab it refused to close must still be open"
        )
    }

    func testCloseRefusesLastTabOfWorktreeWorkspace() async {
        // Closing it would cascade into worktree removal behind an in-app
        // confirmation a background CLI call can't honestly drive — the
        // refusal must arrive instead of a fake "closed".
        let store = makeStore()
        let workspace = store.workspaces[0]
        workspace.worktreeParentId = UUID()
        let only = workspace.root.allPanes[0].tabs[0]
        let controller = makeController(stores: [store])
        let response = await respond(controller, KookyCLIRequest(verb: .close, tab: only.id.uuidString))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("worktree") == true)
        XCTAssertTrue(workspace.root.allPanes.flatMap(\.tabs).contains { $0.id == only.id }, "the tab must survive the refusal")
    }

    func testCloseUnknownTabIsRefused() async {
        let controller = makeController(stores: [makeStore()])
        let response = await respond(controller, KookyCLIRequest(verb: .close, tab: UUID().uuidString))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("no tab with id") == true)
    }

    // MARK: rename

    func testRenameSetsTheTitleWithoutStealingFocus() async throws {
        let store = makeStore()
        let session = try XCTUnwrap(store.active?.activeSession)
        let controller = makeController(stores: [store])
        let response = await respond(
            controller,
            KookyCLIRequest(verb: .rename, tab: session.id.uuidString, title: "deploy log")
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.note, "renamed")
        XCTAssertEqual(session.customTitle, "deploy log")
        XCTAssertTrue(revealed.isEmpty, "rename is pure metadata — it must not front anything")
        XCTAssertEqual(activations, 0)
    }

    func testRenameRefusesUnknownTabAndBlankTitle() async throws {
        let store = makeStore()
        let session = try XCTUnwrap(store.active?.activeSession)
        session.customTitle = "keep me"
        let controller = makeController(stores: [store])

        let unknown = await respond(
            controller,
            KookyCLIRequest(verb: .rename, tab: UUID().uuidString, title: "x")
        )
        XCTAssertFalse(unknown.ok)
        XCTAssertTrue(unknown.error?.contains("no tab with id") == true)

        // A direct caller's blank title must refuse, never CLEAR the name
        // (renameTab's blank-clears is the in-app popover's affordance).
        let blank = await respond(
            controller,
            KookyCLIRequest(verb: .rename, tab: session.id.uuidString, title: "   ")
        )
        XCTAssertFalse(blank.ok)
        XCTAssertEqual(session.customTitle, "keep me")
    }

    // MARK: resume

    func testResumeForwardsValidatedFieldsToThePipeline() async {
        let controller = makeController(stores: [makeStore()], resumeOutcome: .opened)
        let response = await respond(
            controller,
            KookyCLIRequest(verb: .resume, cwd: dirA, agent: "Claude-Code", conversationId: "abc-123")
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.note, "resumed in a new tab")
        XCTAssertEqual(resumeCalls.count, 1)
        XCTAssertEqual(resumeCalls.first?.agent, "claude-code", "agent id lowercases exactly like the deep link")
        XCTAssertEqual(resumeCalls.first?.id, "abc-123")
        XCTAssertEqual(resumeCalls.first?.cwd, dirA)
        XCTAssertEqual(activations, 1)
    }

    func testResumeRevealedOutcomeReads() async {
        let controller = makeController(stores: [makeStore()], resumeOutcome: .revealed)
        let response = await respond(
            controller,
            KookyCLIRequest(verb: .resume, agent: "codex", conversationId: "abc")
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.note, "revealed the open conversation tab")
    }

    func testResumeFailureAndDropRefuseWithoutActivating() async {
        // A failed script call must not yank kooky frontmost.
        for outcome in [ResumeRequestOutcome.failed("boom"), .dropped("gone")] {
            let controller = makeController(stores: [makeStore()], resumeOutcome: outcome)
            let response = await respond(
                controller,
                KookyCLIRequest(verb: .resume, agent: "codex", conversationId: "abc")
            )
            XCTAssertFalse(response.ok)
        }
        XCTAssertEqual(activations, 0)
    }

    func testResumeRefusesShellHostileConversationId() async {
        let controller = makeController(stores: [makeStore()])
        let response = await respond(
            controller,
            KookyCLIRequest(verb: .resume, agent: "claude-code", conversationId: "a;rm -rf ~")
        )
        XCTAssertFalse(response.ok)
        XCTAssertTrue(resumeCalls.isEmpty, "a refused id must never reach the resume pipeline")
    }

    func testResumeRefusesAgentOutsideScannerRoster() async {
        // `amp` is a real launch template but has no readable session store,
        // so it is exactly the "valid-looking but non-resumable" case.
        let controller = makeController(stores: [makeStore()])
        let response = await respond(
            controller,
            KookyCLIRequest(verb: .resume, agent: "amp", conversationId: "abc")
        )
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("resumable agents") == true)
        XCTAssertTrue(resumeCalls.isEmpty)
        XCTAssertEqual(activations, 0, "a refused agent must not activate the app")
    }
}
