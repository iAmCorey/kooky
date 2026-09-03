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
        let up = try Self.keyDownEvent(keyCode: 126, characters: "\u{F700}", mods: [])
        try withManualSurface { surface, output in
            XCTAssertEqual(try Self.bytes(for: up, on: surface, output: output), "\u{1B}[A")
            Self.feed("\u{1B}[?1h", to: surface)
            XCTAssertEqual(try Self.bytes(for: up, on: surface, output: output), "\u{1B}OA")
        }
    }

    // MARK: - Ctrl combos through the libghostty key encoder (issue #54)

    /// The `od -c` contract for Ctrl combos, end to end through the REAL
    /// production key-event construction (`makeKeyEvent`) and a real
    /// libghostty surface. Events are synthesized with the exact
    /// `characters` macOS delivers for each combo: AppKit pre-translates
    /// only Ctrl+letter into a control byte; Ctrl+Space / Ctrl+digit arrive
    /// as plain text — the class of keys that used to die in the IME path.
    func testCtrlCombosEncodeGhosttyCtrlSeqBytes() throws {
        // (keyCode, macOS-delivered characters, unshifted char, expected bytes)
        let cases: [(UInt16, String, String, String)] = [
            (49, " ", " ", "\u{00}"),       // Ctrl+Space → NUL
            (18, "1", "1", "1"),            // Ctrl+1 → literal "1" (xterm legacy)
            (19, "2", "2", "\u{00}"),       // Ctrl+2 → NUL
            (20, "3", "3", "\u{1B}"),       // Ctrl+3 → ESC
            (28, "8", "8", "\u{7F}"),       // Ctrl+8 → DEL
            (0, "\u{01}", "a", "\u{01}"),   // Ctrl+A → ^A (pre-translated byte)
            (8, "\u{03}", "c", "\u{03}"),   // Ctrl+C → ^C
        ]
        try withManualSurface { surface, output in
            for (keyCode, chars, unshifted, expected) in cases {
                let event = try Self.keyDownEvent(
                    keyCode: keyCode, characters: chars, mods: [.control],
                    requireUnshifted: unshifted
                )
                XCTAssertEqual(
                    try Self.bytes(for: event, on: surface, output: output), expected,
                    "wrong bytes for Ctrl+\(unshifted)"
                )
            }
        }
    }

    /// Under the kitty keyboard protocol a TUI expects CSI-u, which only the
    /// encoder can emit — the old path (raw pre-translated control byte via
    /// `text_input`) bypassed it entirely. Ctrl+C with "disambiguate escape
    /// codes" pushed must come out as `ESC [99;5u`, not 0x03.
    func testCtrlLetterUnderKittyProtocolEncodesCSIu() throws {
        try withManualSurface { surface, output in
            Self.feed("\u{1B}[>1u", to: surface)
            let event = try Self.keyDownEvent(
                keyCode: 8, characters: "\u{03}", mods: [.control], requireUnshifted: "c"
            )
            XCTAssertEqual(try Self.bytes(for: event, on: surface, output: output), "\u{1B}[99;5u")
        }
    }

    func testMakeKeyEventCtrlComboShape() throws {
        // Ctrl+Space: plain-text characters ride through as `text`, the
        // encoder's ctrlSeq keys on it; ctrl never lands in consumed_mods.
        let space = try Self.keyDownEvent(
            keyCode: 49, characters: " ", mods: [.control], requireUnshifted: " "
        )
        let spaceKey = GhosttySurfaceView.makeKeyEvent(for: space)
        XCTAssertEqual(GhosttySurfaceView.keyEventText(for: space), " ")
        XCTAssertEqual(spaceKey.unshifted_codepoint, 0x20)
        XCTAssertNotEqual(spaceKey.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertEqual(spaceKey.consumed_mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)

        // Ctrl+A: AppKit pre-translated "\u{01}" must NOT be sent as text —
        // the un-ctrl'd character is (ghostty.app's ghosttyCharacters rule).
        let letterA = try Self.keyDownEvent(
            keyCode: 0, characters: "\u{01}", mods: [.control], requireUnshifted: "a"
        )
        XCTAssertEqual(GhosttySurfaceView.keyEventText(for: letterA), "a")
        XCTAssertEqual(
            GhosttySurfaceView.makeKeyEvent(for: letterA).unshifted_codepoint,
            UInt32(UnicodeScalar("a").value)
        )

        // Ctrl+Enter: still a control byte after un-ctrl'ing → no text; the
        // encoder derives the sequence from keycode + mods (keyAction rule).
        let enter = try Self.keyDownEvent(keyCode: 36, characters: "\r", mods: [.control])
        XCTAssertNil(GhosttySurfaceView.keyEventText(for: enter))
    }

    func testMakeKeyEventStripsFunctionKeyPUAText() throws {
        // Arrow keys carry a Private-Use-Area "character" (0xF700) — not real
        // text. The cursor-key path (v0.12.4) depends on this staying nil so
        // libghostty keys off `keycode` and honors DECCKM (asserted end to
        // end by testGhosttyCursorKeyTracksApplicationCursorMode, which
        // presses through the same production pieces).
        let up = try Self.keyDownEvent(keyCode: 126, characters: "\u{F700}", mods: [])
        XCTAssertNil(GhosttySurfaceView.keyEventText(for: up))
        XCTAssertEqual(GhosttySurfaceView.makeKeyEvent(for: up).keycode, 126)
    }

    func testMakeKeyEventFlagsChangedNeverTouchesCharacters() throws {
        // Reading `characters*` on a FlagsChanged event raises
        // NSInternalInconsistencyException (the v0.31.6 crash class) — the
        // builder must return the bare mods+keycode shape without ever
        // calling those APIs.
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.control],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 59
        ) else {
            throw XCTSkip("could not synthesize a flagsChanged event")
        }
        let key = GhosttySurfaceView.makeKeyEvent(for: event)
        XCTAssertNil(GhosttySurfaceView.keyEventText(for: event))
        XCTAssertEqual(GhosttySurfaceView.unshiftedCodepoint(of: event), 0)
        XCTAssertEqual(key.unshifted_codepoint, 0)
        XCTAssertEqual(key.consumed_mods.rawValue, 0)
        XCTAssertNotEqual(key.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
    }

    func testMakeKeyEventConsumedModsFollowTranslationMods() throws {
        // consumed_mods = translation mods − ctrl − cmd (ghostty.app's
        // heuristic). With macos-option-as-alt stripping option from the
        // translation mods, option must stay OUT of consumed_mods so the
        // encoder ESC-prefixes (issue #46's machinery, now on this path too).
        let event = try Self.keyDownEvent(
            keyCode: 8, characters: "\u{03}", mods: [.control, .option]
        )
        let asAlt = GhosttySurfaceView.makeKeyEvent(for: event, translationMods: [.control])
        XCTAssertEqual(asAlt.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)

        let asText = GhosttySurfaceView.makeKeyEvent(
            for: event, translationMods: [.control, .option]
        )
        XCTAssertNotEqual(asText.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
    }

    func testLegacyControlBytesMirrorsGhosttyCtrlSeq() {
        func byte(_ ch: Unicode.Scalar) -> String? {
            GhosttySurfaceView.legacyControlBytes(unshiftedCodepoint: ch.value)
        }
        XCTAssertEqual(byte(" "), "\u{00}")
        XCTAssertEqual(byte("0"), "0")
        XCTAssertEqual(byte("1"), "1")
        XCTAssertEqual(byte("2"), "\u{00}")
        XCTAssertEqual(byte("3"), "\u{1B}")
        XCTAssertEqual(byte("4"), "\u{1C}")
        XCTAssertEqual(byte("5"), "\u{1D}")
        XCTAssertEqual(byte("6"), "\u{1E}")
        XCTAssertEqual(byte("7"), "\u{1F}")
        XCTAssertEqual(byte("8"), "\u{7F}")
        XCTAssertEqual(byte("9"), "9")
        XCTAssertEqual(byte("/"), "\u{1F}")
        XCTAssertEqual(byte("?"), "\u{7F}")
        XCTAssertEqual(byte("@"), "\u{00}")
        XCTAssertEqual(byte("\\"), "\u{1C}")
        XCTAssertEqual(byte("]"), "\u{1D}")
        XCTAssertEqual(byte("^"), "\u{1E}")
        XCTAssertEqual(byte("_"), "\u{1F}")
        XCTAssertEqual(byte("~"), "\u{1E}")
        XCTAssertEqual(byte("a"), "\u{01}")
        XCTAssertEqual(byte("l"), "\u{0C}")
        XCTAssertEqual(byte("z"), "\u{1A}")
        // No legacy byte — only exists under the kitty protocol.
        XCTAssertNil(byte("`"))
        XCTAssertNil(byte("é"))
    }

    /// Ctrl+Shift+letter is ghostty's deliberate fixterms divergence: it
    /// CSI-u's even in legacy mode so programs can tell Ctrl+C from
    /// Ctrl+Shift+C (matches kitty; ghostty.app ships this). Old kooky sent
    /// 0x03 for both — this pins the upstream-parity change of behavior.
    func testCtrlShiftLetterEncodesCSIu() throws {
        try withManualSurface { surface, output in
            let event = try Self.keyDownEvent(
                keyCode: 8, characters: "\u{03}", mods: [.control, .shift], requireUnshifted: "c"
            )
            XCTAssertEqual(try Self.bytes(for: event, on: surface, output: output), "\u{1B}[99;6u")
        }
    }

    // MARK: - Return through the libghostty key encoder (issue #72)

    /// The `od -c` contract for Return, through the production key-event
    /// pieces and a real surface. kooky used to hand-write Shift+Enter as
    /// `\` + CR (a Claude Code trick); every TUI on the kitty keyboard
    /// protocol rendered that as a literal backslash. The encoder emits
    /// xterm modifyOtherKeys in legacy mode and CSI-u once a program pushes
    /// kitty flags — the two forms Claude Code / pi / omp actually parse.
    func testReturnVariantsEncodeLegacyThenKittySequences() throws {
        typealias Case = (name: String, code: UInt16, mods: NSEvent.ModifierFlags, legacy: String, kitty: String)
        let cases: [Case] = [
            //  name            code  mods        legacy               kitty
            ("Return",          36,   [],         "\r",                "\r"),
            ("Shift+Return",    36,   [.shift],   "\u{1B}[27;2;13~",   "\u{1B}[13;2u"),
            ("Ctrl+Return",     36,   [.control], "\u{1B}[27;5;13~",   "\u{1B}[13;5u"),
            ("Option+Return",   36,   [.option],  "\u{1B}\r",          "\u{1B}[13;3u"),
            ("Keypad Enter",    76,   [],         "\r",                "\u{1B}[57414u"),
        ]
        try withManualSurface { surface, output in
            @MainActor func check(_ phase: String, _ expected: (Case) -> String) throws {
                for c in cases {
                    let event = try Self.keyDownEvent(keyCode: c.code, characters: "\r", mods: c.mods)
                    XCTAssertNil(GhosttySurfaceView.keyEventText(for: event), "\(c.name) must carry no text")
                    XCTAssertEqual(
                        try Self.bytes(for: event, on: surface, output: output), expected(c),
                        "\(phase) bytes for \(c.name)"
                    )
                }
            }
            try check("legacy") { $0.legacy }
            Self.feed("\u{1B}[>1u", to: surface)
            try check("kitty") { $0.kitty }
        }
    }

    /// Pins the contract helper's config guard using a binding ghostty ships
    /// by default on macOS (`super+c` → copy), so a machine whose config
    /// binds a contract key gets a SKIP with a reason, never a red row.
    func testContractHelperSkipsKeysBoundByGhosttyConfig() throws {
        let cmdC = try Self.keyDownEvent(keyCode: 8, characters: "c", mods: [.command], requireUnshifted: "c")
        try withManualSurface { surface, output in
            XCTAssertThrowsError(try Self.bytes(for: cmdC, on: surface, output: output)) { error in
                XCTAssertTrue(error is XCTSkip, "expected XCTSkip, got \(type(of: error))")
            }
        }
    }

    // MARK: - Helpers

    /// Runs `body` against a real manual-IO libghostty surface whose PTY-side
    /// writes land in `output` instead of a live shell.
    private func withManualSurface(
        _ body: (ghostty_surface_t, ManualGhosttyOutput) throws -> Void
    ) throws {
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
        try body(surface, output)
    }

    /// `requireUnshifted` skips (not fails) when the CURRENT keyboard layout
    /// doesn't map the keycode to the expected US character —
    /// `characters(byApplyingModifiers:)` re-translates from the keycode.
    private static func keyDownEvent(
        keyCode: UInt16,
        characters: String,
        mods: NSEvent.ModifierFlags,
        requireUnshifted: String? = nil
    ) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
        if let requireUnshifted {
            try XCTSkipUnless(
                event.characters(byApplyingModifiers: []) == requireUnshifted,
                "keyboard layout does not map keyCode \(keyCode) to \(requireUnshifted)"
            )
        }
        return event
    }

    /// Feeds PTY-side bytes (a mode switch, a kitty flags push) to the surface.
    private static func feed(_ bytes: String, to surface: ghostty_surface_t) {
        bytes.withCString { cstr in
            ghostty_surface_process_output(surface, cstr, UInt(strlen(cstr)))
        }
    }

    /// Drains stale output, presses `event` through the SAME production
    /// pieces `sendKey` composes — `makeKeyEvent` + `keyEventText` + `send`,
    /// so a regression in any of them reddens the od-contract assertions —
    /// and returns only the bytes that press produced. A declined key fails
    /// the test at the caller's line.
    ///
    /// Skips (never fails) when THIS machine's ghostty config binds the key:
    /// the shared `LibghosttyApp` loads `~/.config/ghostty/config`, and a
    /// binding runs instead of the encoder — a developer following the
    /// CHANGELOG's own `keybind = shift+enter=…` advice would otherwise
    /// redden the Shift+Return row.
    private static func bytes(
        for event: NSEvent,
        on surface: ghostty_surface_t,
        output: ManualGhosttyOutput,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let key = GhosttySurfaceView.makeKeyEvent(for: event)
        let text = GhosttySurfaceView.keyEventText(for: event)
        try XCTSkipIf(
            isBinding(key, text: text, on: surface),
            "keyCode \(event.keyCode) mods \(event.modifierFlags.rawValue) is bound by this machine's ghostty config"
        )
        _ = output.takeString()
        let accepted = GhosttySurfaceView.send(key, text: text, to: surface)
        XCTAssertTrue(accepted, "libghostty declined keyCode \(event.keyCode)", file: file, line: line)
        return output.takeString()
    }

    private static func isBinding(
        _ key: ghostty_input_key_s, text: String?, on surface: ghostty_surface_t
    ) -> Bool {
        var key = key
        var flags = ghostty_binding_flags_e(rawValue: 0)
        guard let text, !text.isEmpty else {
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        return text.withCString { cstr in
            key.text = cstr
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
    }

    /// Return forwards to libghostty with any modifier (Cmd combos exit
    /// `keyDown` before the predicate runs); its hand-written entry is the
    /// decline fallback only — CR for a bare Return, nothing for a modified
    /// one the core declined, never the old `\` + CR trick (issue #72).
    func testReturnForwardsToLibghosttyAndFallsBackToPlainCROnly() {
        for keyCode: UInt16 in [36, 76] {
            for mods: NSEvent.ModifierFlags in [[], [.shift], [.control], [.option], [.shift, .option]] {
                XCTAssertTrue(
                    GhosttySurfaceView.shouldForwardModeAwareKeyToLibghostty(
                        keyCode: keyCode, modifierFlags: mods
                    ),
                    "keyCode \(keyCode) mods \(mods.rawValue) must forward"
                )
            }
            XCTAssertEqual(
                GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: keyCode, modifierFlags: []),
                "\r"
            )
            XCTAssertNil(
                GhosttySurfaceView.handWrittenEscapeSequence(forKeyCode: keyCode, modifierFlags: [.shift]),
                "a modified Return the core declined must stay declined, not become a submit"
            )
        }
    }

    func testNonCursorSpecialKeysKeepExplicitSequences() {
        XCTAssertFalse(
            GhosttySurfaceView.shouldForwardModeAwareKeyToLibghostty(keyCode: 48, modifierFlags: [.shift])
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
