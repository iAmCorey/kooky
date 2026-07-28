import AppKit
import GhosttyKit
import XCTest
@testable import KookyKit

@MainActor
final class TerminalKeyRoutingTests: XCTestCase {
    func testMacOSOptionAsAltParsesSupportedSettingsValues() {
        func parsed(_ value: Any?) -> [String: Any] {
            ["terminal": ["macos-option-as-alt": value as Any]]
        }

        XCTAssertEqual(KookySettings.macOSOptionAsAlt(parsed: parsed(true)), .both)
        XCTAssertEqual(KookySettings.macOSOptionAsAlt(parsed: parsed(false)), .disabled)
        XCTAssertEqual(KookySettings.macOSOptionAsAlt(parsed: parsed("left")), .left)
        XCTAssertEqual(KookySettings.macOSOptionAsAlt(parsed: parsed("right")), .right)
        XCTAssertEqual(KookySettings.macOSOptionAsAlt(parsed: parsed("invalid")), .disabled)
        XCTAssertEqual(KookySettings.macOSOptionAsAlt(parsed: nil), .disabled)
    }

    func testLeftOptionModeSendsMetaOnlyForLeftOption() {
        XCTAssertEqual(
            GhosttySurfaceView.metaTextForOptionAsAlt(
                mode: .left,
                pressedOptionSides: [.left],
                modifierFlags: [.option],
                charactersIgnoringModifiers: "z"
            ),
            "\u{1B}z"
        )

        // Returning nil leaves the event on the existing Cocoa text-input
        // path, which commits the right-Option keyboard-layout character Ω.
        XCTAssertNil(
            GhosttySurfaceView.metaTextForOptionAsAlt(
                mode: .left,
                pressedOptionSides: [.right],
                modifierFlags: [.option],
                charactersIgnoringModifiers: "z"
            )
        )
    }

    func testBothAndDisabledOptionModesRouteExpectedSides() {
        for side: GhosttySurfaceView.OptionSides in [.left, .right] {
            XCTAssertEqual(
                GhosttySurfaceView.metaTextForOptionAsAlt(
                    mode: .both,
                    pressedOptionSides: side,
                    modifierFlags: [.option],
                    charactersIgnoringModifiers: "z"
                ),
                "\u{1B}z"
            )
            XCTAssertNil(
                GhosttySurfaceView.metaTextForOptionAsAlt(
                    mode: .disabled,
                    pressedOptionSides: side,
                    modifierFlags: [.option],
                    charactersIgnoringModifiers: "z"
                )
            )
        }
    }

    func testOptionAsAltDoesNotInterceptNormalChineseInput() {
        XCTAssertNil(
            GhosttySurfaceView.metaTextForOptionAsAlt(
                mode: .both,
                pressedOptionSides: [.left],
                modifierFlags: [],
                charactersIgnoringModifiers: "中"
            )
        )
    }

    func testOptionSideTrackingDistinguishesBothSides() {
        var sides: GhosttySurfaceView.OptionSides = []
        sides = GhosttySurfaceView.updatedOptionSides(
            sides,
            eventKeyCode: 58,
            rawModifierFlags: 0x0000_0020
        )
        XCTAssertEqual(sides, [.left])

        sides = GhosttySurfaceView.updatedOptionSides(
            sides,
            eventKeyCode: 61,
            rawModifierFlags: 0x0000_0060
        )
        XCTAssertEqual(sides, [.left, .right])

        sides = GhosttySurfaceView.updatedOptionSides(
            sides,
            eventKeyCode: 58,
            rawModifierFlags: 0x0000_0040
        )
        XCTAssertEqual(sides, [.right])

        sides = GhosttySurfaceView.updatedOptionSides(
            sides,
            eventKeyCode: 61,
            rawModifierFlags: 0
        )
        XCTAssertEqual(sides, [])
    }

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
