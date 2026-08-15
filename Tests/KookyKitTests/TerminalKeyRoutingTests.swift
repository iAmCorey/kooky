import AppKit
import GhosttyKit
import XCTest
@testable import KookyKit

@MainActor
final class TerminalKeyRoutingTests: XCTestCase {
    func testArrowKeysRouteThroughLibghosttyForApplicationCursorMode() {
        let arrowKeyCodes: [UInt16] = [123, 124, 125, 126] // left, right, down, up

        for keyCode in arrowKeyCodes {
            XCTAssertTrue(
                GhosttySurfaceView.shouldForwardModeAwareKeyToLibghostty(
                    keyCode: keyCode,
                    modifierFlags: []
                )
            )
        }
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 126, modifierFlags: []),
            "\u{1B}[A"
        )
    }

    func testModifiedArrowKeysKeepExplicitCsiModifierSequences() {
        XCTAssertFalse(
            GhosttySurfaceView.shouldForwardModeAwareKeyToLibghostty(
                keyCode: 126,
                modifierFlags: [.control]
            )
        )
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 126, modifierFlags: [.control]),
            "\u{1B}[1;5A"
        )
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 123, modifierFlags: [.shift, .option]),
            "\u{1B}[1;4D"
        )
    }

    func testViewportAtBottomDetection() {
        // ghostty's scrollbar offset is measured from the top; the bottom
        // (active area) is offset + len == total. This predicate gates the
        // resize re-pin that fixes issue #7.

        // Pinned to the bottom: viewport spans down to the last row.
        XCTAssertTrue(GhosttySurfaceView.isViewportAtBottom(total: 100, offset: 76, len: 24))
        // Scrolled up into scrollback: top of viewport above the active area.
        XCTAssertFalse(GhosttySurfaceView.isViewportAtBottom(total: 100, offset: 0, len: 24))
        XCTAssertFalse(GhosttySurfaceView.isViewportAtBottom(total: 100, offset: 50, len: 24))
        // Content fits on screen (no scrollback): trivially at the bottom.
        XCTAssertTrue(GhosttySurfaceView.isViewportAtBottom(total: 24, offset: 0, len: 24))
        XCTAssertTrue(GhosttySurfaceView.isViewportAtBottom(total: 10, offset: 0, len: 24))
    }

    func testGhosttyCursorKeyTracksApplicationCursorMode() throws {
        guard let app = LibghosttyApp.shared.app else {
            throw XCTSkip("libghostty app did not initialize")
        }

        // libghostty attaches its Metal layer when the surface is created,
        // which needs a real window (see CLAUDE.md / `viewDidMoveToWindow`).
        // A windowless NSView makes `ghostty_surface_new` fail intermittently.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view
        let output = ManualGhosttyOutput()
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = 2
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = manualGhosttyWrite
        surfaceConfig.io_write_userdata = Unmanaged.passUnretained(output).toOpaque()

        guard let surface = ghostty_surface_new(app, &surfaceConfig) else {
            throw XCTSkip("manual libghostty surface did not initialize")
        }
        // libghostty holds the raw `nsview` pointer; keep the window (which
        // retains the view) alive past every surface call and the free.
        defer {
            ghostty_surface_free(surface)
            withExtendedLifetime(window) {}
        }

        ghostty_surface_set_size(surface, 800, 600)
        ghostty_surface_set_focus(surface, true)

        XCTAssertTrue(Self.pressArrowUp(on: surface))
        XCTAssertEqual(output.takeString(), "\u{1B}[A")

        "\u{1B}[?1h".withCString { cstr in
            ghostty_surface_process_output(surface, cstr, UInt(strlen(cstr)))
        }
        XCTAssertTrue(Self.pressArrowUp(on: surface))
        XCTAssertEqual(output.takeString(), "\u{1B}OA")
    }

    func testNonCursorSpecialKeysKeepExplicitSequences() {
        XCTAssertFalse(
            GhosttySurfaceView.shouldForwardModeAwareKeyToLibghostty(
                keyCode: 36,
                modifierFlags: []
            )
        )
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 36, modifierFlags: []),
            "\r"
        )
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 36, modifierFlags: [.shift]),
            "\\\r"
        )
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 48, modifierFlags: [.shift]),
            "\u{1B}[Z"
        )
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 122, modifierFlags: []),
            "\u{1B}OP"
        )
    }

    func testModifiedNonCursorSpecialKeysStillEncodeCsiModifierDigit() {
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 115, modifierFlags: [.control]),
            "\u{1B}[1;5H"
        )
        XCTAssertEqual(
            GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: 116, modifierFlags: [.shift, .option]),
            "\u{1B}[5;4~"
        )
    }

    private static func pressArrowUp(on surface: ghostty_surface_t) -> Bool {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = 126
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        return ghostty_surface_key(surface, key)
    }

    /// Builds the key event exactly the way `GhosttySurfaceView.sendKey` does
    /// after the ctrl-capture fix: control bytes stripped from `text`,
    /// `unshifted_codepoint` filled from the unshifted character, ctrl/command
    /// removed from `consumed_mods`. This is the contract that makes
    /// libghostty's encoder produce the ghostty `ctrlSeq` bytes.
    private static func pressKey(
        on surface: ghostty_surface_t,
        keyCode: UInt16,
        unshiftedCodepoint: UInt32,
        mods: NSEvent.ModifierFlags
    ) -> Bool {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GhosttySurfaceView.mapModifiers(mods)
        key.consumed_mods = GhosttySurfaceView.mapModifiers(mods.subtracting([.control, .command]))
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.unshifted_codepoint = unshiftedCodepoint
        key.composing = false
        return ghostty_surface_key(surface, key)
    }

    private func withManualSurface(
        _ body: (ghostty_surface_t, ManualGhosttyOutput) throws -> Void
    ) throws {
        guard let app = LibghosttyApp.shared.app else {
            throw XCTSkip("libghostty app did not initialize")
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view
        let output = ManualGhosttyOutput()
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = 2
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = manualGhosttyWrite
        surfaceConfig.io_write_userdata = Unmanaged.passUnretained(output).toOpaque()

        guard let surface = ghostty_surface_new(app, &surfaceConfig) else {
            throw XCTSkip("manual libghostty surface did not initialize")
        }
        defer {
            ghostty_surface_free(surface)
            withExtendedLifetime(window) {}
        }
        ghostty_surface_set_size(surface, 800, 600)
        ghostty_surface_set_focus(surface, true)
        try body(surface, output)
    }

    /// The `od -c` contract: what ghostty.app emits for each Ctrl combo.
    /// macOS virtual keycodes: space=49, 1=18, 2=19, 3=20, 8=28, a=0, c=8.
    func testCtrlCombosEncodeGhosttyCtrlSeqBytes() throws {
        try withManualSurface { surface, output in
            // (keyCode, unshifted codepoint, expected bytes)
            let cases: [(UInt16, UInt32, String)] = [
                (49, 0x20, "\u{00}"),  // Ctrl+Space → NUL
                (18, 0x31, "1"),       // Ctrl+1 → literal "1" (ctrl ignored)
                (19, 0x32, "\u{00}"),  // Ctrl+2 → NUL
                (20, 0x33, "\u{1B}"),  // Ctrl+3 → ESC
                (28, 0x38, "\u{7F}"),  // Ctrl+8 → DEL
                (0, 0x61, "\u{01}"),   // Ctrl+A → ^A
                (8, 0x63, "\u{03}"),   // Ctrl+C → ^C
            ]
            for (keyCode, codepoint, expected) in cases {
                output.takeString()  // drain any pending bytes
                XCTAssertTrue(
                    Self.pressKey(on: surface, keyCode: keyCode,
                                  unshiftedCodepoint: codepoint, mods: [.control]),
                    "libghostty declined keyCode \(keyCode)"
                )
                XCTAssertEqual(
                    output.takeString(), expected,
                    "keyCode \(keyCode) (unshifted U+\(String(codepoint, radix: 16)))"
                )
            }
        }
    }

    /// Ctrl+Shift+letter: libghostty declines when it has no `text` to
    /// shift-demote (uppercase 'A' → 'a'), so kooky falls back to the
    /// handwritten ctrlSeq table — which collapses shift and still emits the
    /// same C0 byte. This mirrors the pre-fix behavior (NSEvent's
    /// `characters` for Ctrl+Shift+A is already "\u{01}").
    func testCtrlShiftLetterFallsBackToSameControlByte() throws {
        try withManualSurface { surface, output in
            output.takeString()
            let consumed = Self.pressKey(on: surface, keyCode: 0,
                                         unshiftedCodepoint: 0x61, mods: [.control, .shift])
            if consumed {
                // Encoder handled it (newer libghostty with demote-by-keycode).
                XCTAssertEqual(output.takeString(), "\u{01}")
            } else {
                // Declined → keyDown falls back to legacyControlByte.
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero,
                    modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0,
                    context: nil, characters: "\u{01}", charactersIgnoringModifiers: "a",
                    isARepeat: false, keyCode: 0
                )!
                XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event), "\u{01}")
            }
        }
    }

    func testLegacyControlByteFallbackMatchesGhosttyCtrlSeq() {
        func event(keyCode: UInt16, unshifted: String) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.control], timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: unshifted,
                isARepeat: false, keyCode: keyCode
            )!
        }
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 49, unshifted: " ")), "\u{00}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 18, unshifted: "1")), "1")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 19, unshifted: "2")), "\u{00}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 20, unshifted: "3")), "\u{1B}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 21, unshifted: "4")), "\u{1C}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 23, unshifted: "5")), "\u{1D}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 22, unshifted: "6")), "\u{1E}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 26, unshifted: "7")), "\u{1F}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 28, unshifted: "8")), "\u{7F}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 25, unshifted: "9")), "9")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 44, unshifted: "/")), "\u{1F}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 0, unshifted: "a")), "\u{01}")
        XCTAssertEqual(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 37, unshifted: "l")), "\u{0C}")
        // No legacy byte: Ctrl+` only exists under the kitty protocol.
        XCTAssertNil(GhosttySurfaceView.legacyControlByte(forKeyEvent: event(keyCode: 50, unshifted: "`")))
    }
    func testMapModifiersCarriesSidedOptionBits() {
        // Device-dependent NSEvent bits: left Option = NX_DEVICELALTKEYMASK
        // (0x20), right Option = NX_DEVICERALTKEYMASK (0x40). libghostty's
        // `macos-option-as-alt = left|right` needs the RIGHT bit to tell the
        // sides apart (issue #46).
        let base = NSEvent.ModifierFlags.option.rawValue
        let leftOption = NSEvent.ModifierFlags(rawValue: base | 0x20)
        let rightOption = NSEvent.ModifierFlags(rawValue: base | 0x40)

        let left = GhosttySurfaceView.mapModifiers(leftOption).rawValue
        XCTAssertNotEqual(left & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertEqual(left & GHOSTTY_MODS_ALT_RIGHT.rawValue, 0)

        let right = GhosttySurfaceView.mapModifiers(rightOption).rawValue
        XCTAssertNotEqual(right & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertNotEqual(right & GHOSTTY_MODS_ALT_RIGHT.rawValue, 0)
    }

    func testEventModifierFlagsRoundTripsBaseModifiers() {
        // The reverse map only carries the four base modifiers — that's all
        // the translation-event transplant reads. Sided/caps bits stay with
        // the hardware event.
        let combos: [NSEvent.ModifierFlags] = [
            [], [.shift], [.control], [.option], [.command],
            [.shift, .option], [.control, .option, .command],
            [.shift, .control, .option, .command],
        ]
        for flags in combos {
            let roundTripped = GhosttySurfaceView.eventModifierFlags(
                mods: GhosttySurfaceView.mapModifiers(flags)
            )
            XCTAssertEqual(roundTripped, flags, "round-trip failed for \(flags.rawValue)")
        }
    }
}

private final class ManualGhosttyOutput {
    private var data = Data()

    func append(_ ptr: UnsafePointer<CChar>, count: Int) {
        data.append(UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: count)
    }

    func takeString() -> String {
        defer { data.removeAll(keepingCapacity: true) }
        return String(decoding: data, as: UTF8.self)
    }
}

private let manualGhosttyWrite: ghostty_io_write_cb = { userdata, ptr, len in
    guard let userdata, let ptr else { return }
    let output = Unmanaged<ManualGhosttyOutput>.fromOpaque(userdata).takeUnretainedValue()
    output.append(ptr, count: Int(len))
}
