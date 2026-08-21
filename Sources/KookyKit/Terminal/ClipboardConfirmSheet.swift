import AppKit
import SwiftUI

/// Brutalist consent sheet for risky clipboard access (unsafe paste, OSC 52
/// read/write) — same visual language as `ConfirmRemoveWorktreeSheet` /
/// `CreateWorktreeSheet`. Presented as a window sheet from the surface's
/// window because the trigger is a libghostty callback, not a SwiftUI-owned
/// flow. The contents shown are a SNAPSHOT taken at request time — deciding
/// on re-read pasteboard state would let a racing process swap the payload
/// after the user saw it.
@MainActor
enum ClipboardConfirmPresenter {
    @MainActor
    enum Kind {
        case unsafePaste
        case oscRead
        case oscWrite

        var statusLabel: String {
            switch self {
            case .unsafePaste: String(localized: "UNSAFE-PASTE", bundle: .kookyResources)
            case .oscRead, .oscWrite: String(localized: "CLIPBOARD-ACCESS", bundle: .kookyResources)
            }
        }

        var headline: String {
            switch self {
            case .unsafePaste: String(localized: "Paste looks dangerous", bundle: .kookyResources)
            case .oscRead: String(localized: "Allow clipboard read?", bundle: .kookyResources)
            case .oscWrite: String(localized: "Allow clipboard write?", bundle: .kookyResources)
            }
        }

        var subtitle: String {
            switch self {
            case .unsafePaste:
                String(localized: "The clipboard text contains characters that may run commands the moment they are pasted.", bundle: .kookyResources)
            case .oscRead:
                String(localized: "A program running in the terminal wants to read your clipboard.", bundle: .kookyResources)
            case .oscWrite:
                String(localized: "A program running in the terminal wants to replace your clipboard contents.", bundle: .kookyResources)
            }
        }

        var allowTitle: String {
            switch self {
            case .unsafePaste: String(localized: "paste anyway", bundle: .kookyResources)
            case .oscRead, .oscWrite: String(localized: "allow", bundle: .kookyResources)
            }
        }
    }

    /// One pending consent per parent window. The core never throttles OSC
    /// 52 writes (fire-and-forget) and keeps issuing read requests, so a
    /// looping program could otherwise queue an unbounded stack of modal
    /// sheets — each retaining a full clipboard snapshot (Codex review).
    /// weak-to-weak: entries vanish with either the window or the
    /// controller, so a dead parent can't strand a deny-forever slot.
    private static let pendingByWindow = NSMapTable<NSWindow, AnyObject>.weakToWeakObjects()

    static func present(
        on window: NSWindow,
        kind: Kind,
        contents: String,
        onDecision: @escaping @MainActor (Bool) -> Void
    ) {
        // A consent is already up for this window: deny the newcomer
        // outright — read-class requests still complete (empty string), a
        // write-class deny simply doesn't write. Never queue.
        guard pendingByWindow.object(forKey: window) == nil else {
            onDecision(false)
            return
        }
        let controller = ConsentSheetController.present(
            on: window,
            onTeardown: { clearPending(for: $0) },
            onDecision: onDecision
        ) { decide in
            ClipboardConfirmSheet(kind: kind, contents: contents, decide: decide)
        }
        pendingByWindow.setObject(controller, forKey: window)
    }

    private static func clearPending(for window: NSWindow) {
        pendingByWindow.removeObject(forKey: window)
    }
}

/// Owns one engine-level consent-sheet presentation (clipboard consent,
/// close-tab confirm): the pending decision doubles as the single-shot guard
/// (⌘W's dismiss and a button press can race — first wins, the request
/// completes exactly once), and `keepAlive` is the strong self-reference that
/// stands in for `NSWindow.windowController` being assign-only. No retain
/// cycle: the view tree must reference the controller only weakly, so
/// releasing `keepAlive` after the decision frees the window + any snapshot
/// the view holds.
///
/// `DismissablePanel` is how `handleCloseTab`'s ⌘W dispatch (the v0.39.1
/// issue-#38 seam) asks "how does this panel close" — for a consent sheet,
/// closing means CANCEL, never silently allow.
final class ConsentSheetController: NSWindowController, DismissablePanel {
    private var pending: (@MainActor (Bool) -> Void)?
    private var keepAlive: ConsentSheetController?
    private weak var parentWindow: NSWindow?
    /// Presenter-specific bookkeeping run once at teardown, before the
    /// decision (the clipboard presenter clears its per-window pending slot).
    fileprivate var onTeardown: (@MainActor (NSWindow) -> Void)?
    /// Opaque tag identifying WHAT this sheet is about, for presenters whose
    /// per-window guard has to tell "asked again about the same thing"
    /// (idempotent) from "asked about something else while this one is up"
    /// (must be refused — the pending sheet's decision closure captured the
    /// first subject and will never act on the second).
    var ownerKey: AnyHashable?

    func begin(on parent: NSWindow, onDecision: @escaping @MainActor (Bool) -> Void) {
        pending = onDecision
        parentWindow = parent
        keepAlive = self
        guard let sheet = window else { return }
        parent.beginSheet(sheet)
    }

    func finish(_ allowed: Bool) {
        guard let decide = pending else { return }
        pending = nil
        if let parent = parentWindow {
            if let sheet = window {
                parent.endSheet(sheet)
            }
            onTeardown?(parent)
        }
        decide(allowed)
        keepAlive = nil
    }

    func dismiss() { finish(false) }
}

extension ConsentSheetController {
    /// Builds the standard consent-sheet window — brutalist SwiftUI content,
    /// kooky appearance (AppKit chrome must follow the theme, not the system),
    /// and the `safeAreaRegions = []` workaround (a titled host's hidden
    /// titlebar otherwise insets the fitting height by ~28pt, M5.www) — and
    /// presents it on `parent`. `content` receives a ready-made `decide`
    /// closure that already references the controller WEAKLY — the view tree
    /// outlives the controller through the endSheet fade-out, and building
    /// the weak hop here is what keeps a future sheet from getting it wrong.
    @discardableResult
    static func present(
        on parent: NSWindow,
        onTeardown: (@MainActor (NSWindow) -> Void)? = nil,
        onDecision: @escaping @MainActor (Bool) -> Void,
        content: (_ decide: @escaping (Bool) -> Void) -> some View
    ) -> ConsentSheetController {
        let controller = ConsentSheetController()
        controller.onTeardown = onTeardown
        let host = NSHostingController(
            rootView: content({ [weak controller] allowed in controller?.finish(allowed) })
        )
        host.safeAreaRegions = []
        let sheet = NSWindow(contentViewController: host)
        sheet.appearance = Theme.windowAppearance
        controller.window = sheet
        controller.begin(on: parent, onDecision: onDecision)
        return controller
    }
}

private struct ClipboardConfirmSheet: View {
    let kind: ClipboardConfirmPresenter.Kind
    let contents: String
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.statusLabel)
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                .padding(.bottom, 18)

            Text(kind.headline)
                .font(Theme.display(20, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)

            Text(kind.subtitle)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            preview

            HStack(spacing: 10) {
                Spacer()
                BracketButton("cancel") { decide(false) }
                    .keyboardShortcut(.cancelAction)
                BracketButton(kind.allowTitle) { decide(true) }
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }

    /// Read-only monospaced preview — what lets the user actually judge the
    /// risk. Head-capped: a pathological multi-MB clipboard must not stall
    /// layout, and the head carries the "is this my text" signal.
    private var preview: some View {
        ScrollView {
            Text(String(contents.prefix(4096)))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeForeground.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .frame(height: 120)
        .background(Theme.chromeHover)
        .bracketBorder()
    }
}
