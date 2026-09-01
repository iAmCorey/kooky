import Foundation
import GhosttyKit
import XCTest
@testable import KookyKit

@MainActor
final class KookySettingsUserThemeTests: XCTestCase {
    func testSelectedUserThemeAppliesReportedOptionsAfterInheritedConfig() throws {
        _ = LibghosttyApp.shared
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let themeURL = directory.appendingPathComponent("Issue 68")
        try """
        cursor-style = block
        shell-integration-features = no-cursor
        cursor-color = #ffcc00
        selection-background = #89ebff
        selection-foreground = #000000
        bell-audio-path = sounds/bell.wav
        """.write(to: themeURL, atomically: true, encoding: .utf8)

        let themes = KookyTerminalTheme.userThemes(in: directory)
        let theme = try XCTUnwrap(themes.first)
        XCTAssertEqual(theme.userThemeURL, themeURL.standardizedFileURL)

        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        load(
            "cursor-style = bar\ncursor-color = #010203\nselection-background = #111111\n",
            sourceName: "inherited-config",
            into: config
        )
        KookySettings.apply(
            parsed: parsed(theme: theme.storedValue),
            to: config,
            themes: themes
        )
        ghostty_config_finalize(config)

        XCTAssertEqual(value("cursor-style", in: config), "block")
        XCTAssertEqual(value("cursor-color", in: config), "#ffcc00")
        XCTAssertEqual(value("selection-background", in: config), "#89ebff")
        XCTAssertEqual(value("selection-foreground", in: config), "#000000")
        XCTAssertTrue(value("shell-integration-features", in: config)?.contains("no-cursor") == true)
        XCTAssertEqual(
            value("bell-audio-path", in: config),
            directory.appendingPathComponent("sounds/bell.wav").path
        )
    }

    func testUserThemeKeepsThemeFileBoundaryAndTerminalOverrides() throws {
        _ = LibghosttyApp.shared
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nestedThemeURL = directory.appendingPathComponent("Nested")
        try "selection-background = #123456\n"
            .write(to: nestedThemeURL, atomically: true, encoding: .utf8)
        let includedConfigURL = directory.appendingPathComponent("included")
        try "selection-foreground = #654321\n"
            .write(to: includedConfigURL, atomically: true, encoding: .utf8)
        let selectedThemeURL = directory.appendingPathComponent("Selected")
        try """
          theme = \(nestedThemeURL.path)
        config-file = \(includedConfigURL.path)
        cursor-color = #ffcc00
        """.write(to: selectedThemeURL, atomically: true, encoding: .utf8)

        let themes = KookyTerminalTheme.userThemes(in: directory)
        let theme = try XCTUnwrap(themes.first { $0.title == "Selected" })
        XCTAssertFalse(theme.loadableLines.contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("theme =")
        })
        XCTAssertFalse(theme.loadableLines.contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("config-file =")
        })
        XCTAssertTrue(theme.loadableLines.contains("cursor-color = #ffcc00"))

        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        KookySettings.apply(
            parsed: parsed(
                theme: theme.storedValue,
                terminal: ["cursor-color": "#010203"]
            ),
            to: config,
            themes: themes
        )
        ghostty_config_finalize(config)

        XCTAssertEqual(value("cursor-color", in: config), "#010203")
        XCTAssertNotEqual(value("selection-background", in: config), "#123456")
        XCTAssertNotEqual(value("selection-foreground", in: config), "#654321")
    }

    private func parsed(
        theme: String,
        terminal: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "appearance": [
                "themeSchemaVersion": KookySettings.pairedThemeSchemaVersion,
                "mode": "light",
                "lightTheme": theme,
                "darkTheme": theme,
            ],
            "terminal": terminal,
        ]
    }

    private func load(
        _ text: String,
        sourceName: String,
        into config: ghostty_config_t
    ) {
        text.withCString { cstr in
            sourceName.withCString { source in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)), source)
            }
        }
    }

    private func value(_ key: String, in config: ghostty_config_t) -> String? {
        let prefix = "\(key) = "
        return serialized(config)
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func serialized(_ config: ghostty_config_t) -> String {
        let value = ghostty_config_serialize(config)
        defer { ghostty_string_free(value) }
        guard let ptr = value.ptr else { return "" }
        let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: Int(value.len)),
            as: UTF8.self
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-user-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
