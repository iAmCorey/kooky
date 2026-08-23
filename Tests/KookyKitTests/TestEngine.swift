import AppKit
@testable import KookyKit

/// In-memory stand-in for `TerminalEngine` so `WorkspaceStore` tests don't
/// need libghostty or a real PTY. Records calls so tests can assert on them.
@MainActor
final class TestEngine: TerminalEngine {
    /// Accepts first responder like the real surface view does, so focus
    /// assertions against `window.firstResponder` work in host tests.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    let view: NSView = FocusableView()
    func renderNowIfNeeded() {}
    var backgroundColor: NSColor { .black }
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onProcessExitedCleanly: (() -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    var needsConfirmQuit = false
    var onLinkHover: ((String?) -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var pasteUploadHostProvider: (() -> String?)?
    var isRemoteSessionProvider: (() -> Bool)?
    var foregroundPid: pid_t? { nil }

    private(set) var startedConfigs: [TerminalSessionConfig] = []
    private(set) var terminateCount = 0

    func start(config: TerminalSessionConfig) {
        startedConfigs.append(config)
    }

    func terminate() {
        terminateCount += 1
    }

    private var sizeSuspendCount = 0
    var suspendsSizePropagation: Bool { sizeSuspendCount > 0 }
    func beginSizePropagationSuspension() { sizeSuspendCount += 1 }
    func endSizePropagationSuspension() { sizeSuspendCount = max(0, sizeSuspendCount - 1) }
    var grabsFocusOnMount: Bool = true
    var spawnsWhileHidden: Bool = false
    private(set) var flushSizeCount: Int = 0
    func flushSize() { flushSizeCount += 1 }

    private(set) var performedActions: [String] = []
    @discardableResult
    func performAction(_ name: String) -> Bool {
        performedActions.append(name)
        return true
    }

    private(set) var corePasteCount: Int = 0
    func pasteFromClipboardViaCore() -> Bool {
        corePasteCount += 1
        return true
    }

    private(set) var sentInputs: [String] = []
    func sendInput(_ text: String) {
        sentInputs.append(text)
    }

    private(set) var pastedTexts: [String] = []
    func paste(_ text: String) {
        pastedTexts.append(text)
    }

    var nextSelection: String?
    func readSelection() -> String? {
        nextSelection
    }

    func emitPwd(_ path: String) {
        onPwdChange?(path)
    }

    func emitCommandFinished(exit: Int?, duration: TimeInterval) {
        onCommandFinished?(exit, duration)
    }

    func emitUserInput() {
        onUserInput?()
    }

    func emitTitle(_ title: String) {
        onTitleChange?(title)
    }
}
