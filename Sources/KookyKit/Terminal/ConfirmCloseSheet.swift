import AppKit
import SwiftUI

/// `confirm-close-surface`: closing a tab whose process is still working
/// (vim, a build, an agent) asks first. Only USER-initiated single-tab
/// closes route here (⌘W, the tab's ✕, right-click Close) — workspace/window
/// cascades and process-exit auto-close call `closeTab` directly, so closing
/// a window can't stack N confirmations. The judgment is the core's own
/// (`needsConfirmQuit` = config × live child process; a dead child never
/// confirms), and kooky's baseline pins the config to false — this whole
/// path is opt-in via `terminal.confirm-close-surface`.
@MainActor
enum ConfirmCloseTab {
    /// What `request` actually did — the CLI answers its caller from this,
    /// so every case has to be the truth rather than an intent.
    enum Outcome: Equatable {
        /// No confirmation was needed (or none could be anchored) and the
        /// tab is closed.
        case closed
        /// A sheet for THIS tab is up; the user decides.
        case confirming
        /// The window already has a confirmation pending for a DIFFERENT
        /// tab. Nothing happened to this one — an in-app caller no-ops
        /// (the pending sheet is window-modal, so the user can't have
        /// reached the tab bar anyway) and the CLI refuses out loud
        /// instead of reporting a confirmation that isn't about its tab.
        case windowBusy
    }

    /// One pending confirmation per window. In-app the sheet is
    /// window-modal so a second ✕/⌘W can't reach the tab bar, but the CLI's
    /// `close` verb has no such shield — a scripted loop would stack N
    /// sheets otherwise (the ConsentSheetController-consumer rule from the
    /// deep-link failure presenter: every consumer brings its own guard).
    private static let pendingByWindow = NSMapTable<NSWindow, AnyObject>.weakToWeakObjects()

    /// `anchorWindow` lets a caller that KNOWS the tab's window (the CLI
    /// controller) pin the sheet there. Without it the fallbacks can both be
    /// nil for a background app + detached engine view, and the guard would
    /// silently kill the process a confirmation was supposed to protect.
    ///
    /// Reports what this call DID, so the CLI states a fact instead of
    /// re-deriving the guard chain and lying on the edges.
    /// `willPresent` runs immediately before a confirmation becomes the
    /// thing the user is looking at — and NOT on the `.windowBusy` path.
    /// The CLI uses it to front the app and reveal the tab: doing that up
    /// front instead would leave a refused request having switched the
    /// visible tab to B while the sheet on screen still asks about A.
    @discardableResult
    static func request(
        _ session: Session,
        in workspace: Workspace,
        store: WorkspaceStore,
        anchorWindow: NSWindow? = nil,
        willPresent: (() -> Void)? = nil
    ) -> Outcome {
        // The tab bar's ✕ can target a background tab whose engine view is
        // detached (window nil) — anchor on the key window then.
        guard session.engine.needsConfirmQuit,
              let window = session.engine.view.window ?? anchorWindow ?? NSApp.keyWindow
        else {
            store.closeTab(session, in: workspace)
            return .closed
        }
        // A pending sheet belongs to ONE tab — its decision closure captured
        // that tab. Returning "confirming" for a different tab would tell
        // the caller a confirmation is on screen for a tab nobody will ever
        // act on; a repeat ask for the SAME tab is genuinely idempotent.
        if let pending = pendingByWindow.object(forKey: window) as? ConsentSheetController {
            guard pending.ownerKey == AnyHashable(session.id) else { return .windowBusy }
            // Already asking about THIS tab — still worth surfacing, in case
            // the user navigated away while it waited.
            willPresent?()
            return .confirming
        }
        // A window can be busy with a sheet that isn't ours — a clipboard
        // consent, a worktree removal confirm, an NSOpenPanel. AppKit would
        // QUEUE ours behind it, so the CLI would report "confirmation shown"
        // for a dialog the user cannot see yet, having already been switched
        // to the target tab underneath it. Checked AFTER our own table, so a
        // repeat ask about the same tab stays idempotent.
        guard window.attachedSheet == nil else { return .windowBusy }
        willPresent?()
        let controller = ConsentSheetController.present(
            on: window,
            onTeardown: { pendingByWindow.removeObject(forKey: $0) },
            onDecision: { [weak store, weak session, weak workspace] confirmed in
                guard confirmed, let store, let session, let workspace else { return }
                store.closeTab(session, in: workspace)
            }
        ) { decide in
            ConfirmCloseSheet(tabTitle: session.title, decide: decide)
        }
        controller.ownerKey = AnyHashable(session.id)
        pendingByWindow.setObject(controller, forKey: window)
        return .confirming
    }
}

private struct ConfirmCloseSheet: View {
    let tabTitle: String
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "CLOSE-TAB", bundle: .kookyResources))
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                .padding(.bottom, 18)

            Text(String.localizedStringWithFormat(
                String(localized: "Close “%@”?", bundle: .kookyResources),
                tabTitle
            ))
                .font(Theme.display(20, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
                .lineLimit(2)

            Text(String(localized: "A process is still running in this tab; closing will terminate it.", bundle: .kookyResources))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            HStack(spacing: 10) {
                Spacer()
                BracketButton("cancel") { decide(false) }
                    .keyboardShortcut(.cancelAction)
                BracketButton("close tab") { decide(true) }
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
