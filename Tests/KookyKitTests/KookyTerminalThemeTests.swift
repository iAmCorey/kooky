import XCTest
@testable import KookyKit

@MainActor
final class KookyTerminalThemeTests: XCTestCase {
    func testBundledThemesLoadFromPackagedGhosttyThemeFiles() throws {
        XCTAssertEqual(KookyTerminalTheme.presets.count, 42)
        XCTAssertEqual(
            Set(KookyTerminalTheme.presets.map(\.id)).count,
            KookyTerminalTheme.presets.count
        )
        let theme = try XCTUnwrap(KookyTerminalTheme.preset(for: "one-dark"))
        let resource = try XCTUnwrap(
            Bundle.module.url(forResource: "one-dark", withExtension: nil)
        )
        XCTAssertEqual(
            try String(contentsOf: resource, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .first.map(String.init),
            "# Kooky theme: One Dark"
        )
        XCTAssertEqual(theme.title, "One Dark")
        XCTAssertEqual(theme.lines.first, "background = #282C34")
        XCTAssertEqual(theme.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testPresetLookupAcceptsStableId() {
        let theme = KookyTerminalTheme.preset(for: "solarized-light")
        XCTAssertEqual(theme?.title, "Solarized Light")
        XCTAssertEqual(
            KookyTerminalTheme.preset(for: "kooky:solarized-light"),
            theme
        )
    }

    func testPresetLookupAcceptsLegacyDisplayName() {
        let theme = KookyTerminalTheme.preset(for: "Solarized Light")
        XCTAssertEqual(theme?.id, "solarized-light")
    }

    func testPresetExpandsToConcreteGhosttyColors() {
        let theme = KookyTerminalTheme.preset(for: "dracula")
        XCTAssertEqual(theme?.lines.first, "background = #282A36")
        XCTAssertEqual(theme?.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testNewPresetsAreRegistered() {
        for id in [
            "tokyo-night", "tokyo-day", "gruvbox-dark", "gruvbox-light",
            "ghostty-dark", "one-dark", "one-light",
        ] {
            XCTAssertNotNil(KookyTerminalTheme.preset(for: id), "missing preset \(id)")
        }
    }

    func testCodexOpenSourceThemeSetIsRegisteredWithConcreteTerminalColors() throws {
        let ids = [
            "ayu-dark", "ayu-light", "ayu-mirage",
            "catppuccin-macchiato", "catppuccin-mocha", "dracula-soft",
            "everforest-dark", "everforest-light",
            "github-dark-default", "github-dark-dimmed", "github-dark-high-contrast",
            "github-light-default", "github-light-high-contrast",
            "gruvbox-dark-hard", "gruvbox-dark-soft",
            "gruvbox-light-hard", "gruvbox-light-soft",
            "material-theme", "material-theme-darker", "material-theme-lighter",
            "material-theme-ocean", "material-theme-palenight",
            "monokai", "night-owl", "night-owl-light", "nord",
            "one-dark-pro", "rose-pine-moon",
        ]

        XCTAssertEqual(ids.count, 28)
        for id in ids {
            let theme = try XCTUnwrap(KookyTerminalTheme.preset(for: id), "missing preset \(id)")
            XCTAssertEqual(
                theme.lines.filter { $0.hasPrefix("palette = ") }.count,
                16,
                "incomplete ANSI palette for \(id)"
            )
            for line in theme.lines {
                let color = try XCTUnwrap(line.split(separator: "=").last)
                    .trimmingCharacters(in: .whitespaces)
                XCTAssertEqual(color.count, 7, "non-RGB color in \(id): \(line)")
                XCTAssertEqual(color.first, "#", "invalid color in \(id): \(line)")
                XCTAssertTrue(
                    color.dropFirst().allSatisfy(\.isHexDigit),
                    "invalid color in \(id): \(line)"
                )
            }
        }
    }

    func testBundledThemesAreAlphabeticalByDisplayName() {
        let titles = KookyTerminalTheme.presets.map(\.title)
        XCTAssertEqual(
            titles,
            titles.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        )
    }

    func testGhosttyDarkMatchesPinnedLibghosttyDefaults() {
        let theme = KookyTerminalTheme.preset(for: "ghostty-dark")
        XCTAssertEqual(theme?.title, "Ghostty Dark")
        XCTAssertEqual(theme?.backgroundHex, "#282C34")
        XCTAssertEqual(theme?.foregroundHex, "#FFFFFF")
        XCTAssertEqual(theme?.lines.first, "background = #282C34")
        XCTAssertEqual(theme?.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
        XCTAssertTrue(theme?.lines.contains("palette = 0=#1D1F21") == true)
        XCTAssertTrue(theme?.lines.contains("palette = 15=#EAEAEA") == true)
    }

    func testIsDarkClassifiesPresetsForPickerGrouping() {
        XCTAssertEqual(KookyTerminalTheme.preset(for: "tokyo-night")?.isDark, true)
        XCTAssertEqual(KookyTerminalTheme.preset(for: "gruvbox-dark")?.isDark, true)
        XCTAssertEqual(KookyTerminalTheme.preset(for: "ghostty-dark")?.isDark, true)
        XCTAssertEqual(KookyTerminalTheme.preset(for: "one-dark")?.isDark, true)
        XCTAssertEqual(KookyTerminalTheme.preset(for: "tokyo-day")?.isDark, false)
        XCTAssertEqual(KookyTerminalTheme.preset(for: "gruvbox-light")?.isDark, false)
        XCTAssertEqual(KookyTerminalTheme.preset(for: "one-light")?.isDark, false)
    }

    func testSettingsThemeSelectionPreservesUnknownRawTheme() {
        let state = KookySettingsModel.themeSelection(for: "/Users/me/.config/ghostty/themes/custom")
        XCTAssertEqual(state.selection, KookySettingsModel.customThemeSelection)
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: state.customRawValue
            ),
            "/Users/me/.config/ghostty/themes/custom"
        )
    }

    func testSettingsDefaultThemeSelectionClearsRawThemeWhenChosen() {
        let defaultSelection = KookySettingsModel.themeSelection(for: nil).selection
        XCTAssertNil(
            KookySettingsModel.persistedThemeValue(
                selection: defaultSelection,
                customRawValue: "/Users/me/.config/ghostty/themes/custom"
            )
        )
    }

    func testSettingsPresetThemeSelectionPersistsStableId() {
        let state = KookySettingsModel.themeSelection(for: "Solarized Light")
        XCTAssertEqual(state.selection, "solarized-light")
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil
            ),
            "kooky:solarized-light"
        )
    }

    func testFreshAppearanceDefaultsToSystemWithIndependentThemePair() {
        let preferences = KookySettingsModel.themePreferences(
            appearance: [:],
            legacyRawTheme: nil
        )

        XCTAssertEqual(preferences.mode, .system)
        XCTAssertEqual(preferences.lightSelection, KookyTerminalTheme.defaultLightID)
        XCTAssertEqual(preferences.darkSelection, KookyTerminalTheme.defaultDarkID)
    }

    func testDefaultTemplateOptsNewInstallsIntoPairedThemes() throws {
        let data = try XCTUnwrap(KookySettings.defaultTemplate.data(using: .utf8))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
        )
        let appearance = try XCTUnwrap(parsed["appearance"] as? [String: Any])

        XCTAssertEqual(
            appearance["themeSchemaVersion"] as? Int,
            KookySettings.pairedThemeSchemaVersion
        )
        XCTAssertEqual(
            KookySettings.effectiveThemeValue(parsed: parsed, systemIsDark: false),
            KookyTerminalTheme.defaultLightStoredValue
        )
        XCTAssertEqual(
            KookySettings.effectiveThemeValue(parsed: parsed, systemIsDark: true),
            KookyTerminalTheme.defaultDarkStoredValue
        )
    }

    func testLegacyDefaultKeepsGhosttyInheritance() {
        let parsed: [String: Any] = [
            "appearance": ["showSearchPill": false],
            "terminal": ["font-size": 14],
        ]

        XCTAssertNil(KookySettings.effectiveThemeValue(parsed: parsed, systemIsDark: false))
        XCTAssertNil(KookySettings.effectiveThemeValue(parsed: parsed, systemIsDark: true))
        XCTAssertFalse(
            KookySettingsModel.shouldEnablePairedThemeSchema(
                appearance: ["showSearchPill": false],
                legacyRawTheme: nil
            )
        )
    }

    func testExplicitLegacyThemeOptsIntoLosslessMigration() {
        XCTAssertTrue(
            KookySettingsModel.shouldEnablePairedThemeSchema(
                appearance: [:],
                legacyRawTheme: "dracula"
            )
        )
    }

    func testLegacyThemeMigratesToMatchingSideAndPreservesAppearance() {
        let light = KookySettingsModel.themePreferences(
            appearance: [:],
            legacyRawTheme: "Solarized Light"
        )
        XCTAssertEqual(light.mode, .light)
        XCTAssertEqual(light.lightSelection, "solarized-light")
        XCTAssertEqual(light.darkSelection, KookyTerminalTheme.defaultDarkID)

        let dark = KookySettingsModel.themePreferences(
            appearance: [:],
            legacyRawTheme: "dracula"
        )
        XCTAssertEqual(dark.mode, .dark)
        XCTAssertEqual(dark.lightSelection, KookyTerminalTheme.defaultLightID)
        XCTAssertEqual(dark.darkSelection, "dracula")
    }

    func testPairedThemesAndModeTakePrecedenceOverLegacyTheme() {
        let preferences = KookySettingsModel.themePreferences(
            appearance: [
                "mode": "system",
                "lightTheme": "solarized-light",
                "darkTheme": "dracula",
            ],
            legacyRawTheme: "rose-pine"
        )

        XCTAssertEqual(preferences.mode, .system)
        XCTAssertEqual(preferences.lightSelection, "solarized-light")
        XCTAssertEqual(preferences.darkSelection, "dracula")
    }

    func testEffectiveThemeFollowsModeAndSystemAppearance() {
        let parsed: [String: Any] = [
            "appearance": [
                "mode": "system",
                "lightTheme": "solarized-light",
                "darkTheme": "dracula",
            ],
            "terminal": [:],
        ]
        XCTAssertEqual(
            KookySettings.effectiveThemeValue(parsed: parsed, systemIsDark: false),
            "solarized-light"
        )
        XCTAssertEqual(
            KookySettings.effectiveThemeValue(parsed: parsed, systemIsDark: true),
            "dracula"
        )

        let forcedLight: [String: Any] = [
            "appearance": ["mode": "light", "darkTheme": "dracula"],
            "terminal": [:],
        ]
        XCTAssertEqual(
            KookySettings.effectiveThemeValue(parsed: forcedLight, systemIsDark: true),
            KookyTerminalTheme.defaultLightStoredValue
        )
    }

    func testEffectiveThemeStillAcceptsLegacyTerminalTheme() {
        let parsed: [String: Any] = ["terminal": ["theme": "rose-pine"]]
        XCTAssertEqual(
            KookySettings.effectiveThemeValue(parsed: parsed, systemIsDark: false),
            "rose-pine"
        )
    }

    func testSystemAppearanceResolutionUsesAppKitAppearance() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let highContrastDark = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastDarkAqua))
        let highContrastLight = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastAqua))

        XCTAssertTrue(KookyAppearanceMode.resolvesSystemDark(appearance: dark))
        XCTAssertTrue(KookyAppearanceMode.resolvesSystemDark(appearance: highContrastDark))
        XCTAssertFalse(KookyAppearanceMode.resolvesSystemDark(appearance: light))
        XCTAssertFalse(KookyAppearanceMode.resolvesSystemDark(appearance: highContrastLight))
    }

    func testUserThemesLoadsGhosttyThemeDirectoryFiles() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let themeURL = dir.appendingPathComponent("My Custom Theme")
        try """
        # comments are ignored
        background = #101820
        foreground = "F2AA4C"
        palette = 0=#101820
        """.write(to: themeURL, atomically: true, encoding: .utf8)

        let themes = KookyTerminalTheme.userThemes(in: dir)
        XCTAssertEqual(themes.map(\.title), ["My Custom Theme"])
        XCTAssertEqual(themes.first?.storedValue, "My Custom Theme")
        XCTAssertEqual(themes.first?.backgroundHex, "#101820")
        XCTAssertEqual(themes.first?.foregroundHex, "F2AA4C")
        XCTAssertEqual(themes.first?.isDark, true)
    }

    func testUserThemesAreGroupedByBackgroundLuminance() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #F8F8F8\nforeground = #202020\n"
            .write(
                to: dir.appendingPathComponent("Bright Custom"),
                atomically: true,
                encoding: .utf8
            )
        try "foreground = #FFFFFF\n"
            .write(
                to: dir.appendingPathComponent("Missing Background"),
                atomically: true,
                encoding: .utf8
            )

        let themes = KookyTerminalTheme.userThemes(in: dir)
        XCTAssertEqual(themes.first { $0.title == "Bright Custom" }?.isDark, false)
        XCTAssertEqual(themes.first { $0.title == "Missing Background" }?.isDark, true)
    }

    func testSettingsThemeSelectionAcceptsUserThemeByFileName() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Issue 17")
        try "background = #000000\nforeground = #ffffff\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let custom = KookyTerminalTheme.userThemes(in: dir)
        let state = KookySettingsModel.themeSelection(for: "Issue 17", in: KookyTerminalTheme.presets + custom)
        XCTAssertEqual(state.selection, "ghostty-user:Issue 17")
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil,
                in: KookyTerminalTheme.presets + custom
            ),
            "Issue 17"
        )
    }

    func testUnprefixedCollisionPrefersGhosttyUserThemeWhileNamespaceSelectsBundled() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #010203\nforeground = #F0F0F0\n"
            .write(
                to: dir.appendingPathComponent("nord"),
                atomically: true,
                encoding: .utf8
            )

        let themes = KookyTerminalTheme.presets + KookyTerminalTheme.userThemes(in: dir)
        let legacy = KookySettingsModel.themeSelection(for: "nord", in: themes)
        XCTAssertEqual(legacy.selection, "ghostty-user:nord")
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: legacy.selection,
                customRawValue: nil,
                in: themes
            ),
            "nord"
        )

        let bundled = KookySettingsModel.themeSelection(for: "kooky:nord", in: themes)
        XCTAssertEqual(bundled.selection, "nord")
        XCTAssertEqual(
            KookySettingsModel.persistedThemeValue(
                selection: bundled.selection,
                customRawValue: nil,
                in: themes
            ),
            "kooky:nord"
        )

        try "background = #FDFDFD\nforeground = #101010\n"
            .write(
                to: dir.appendingPathComponent("one-light"),
                atomically: true,
                encoding: .utf8
            )
        let themesWithDefaultCollision = KookyTerminalTheme.presets
            + KookyTerminalTheme.userThemes(in: dir)
        let defaults = KookySettingsModel.themePreferences(
            appearance: ["themeSchemaVersion": 2],
            legacyRawTheme: nil,
            in: themesWithDefaultCollision
        )
        XCTAssertEqual(defaults.lightSelection, KookyTerminalTheme.defaultLightID)
        XCTAssertEqual(defaults.darkSelection, KookyTerminalTheme.defaultDarkID)
    }

    func testGhosttyUserThemesDirectoryHonorsXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let xdg = KookyTerminalTheme.ghosttyUserThemesDirectory(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: home
        )
        XCTAssertEqual(xdg.path, "/tmp/xdg/ghostty/themes")

        let fallback = KookyTerminalTheme.ghosttyUserThemesDirectory(
            environment: [:],
            homeDirectory: home
        )
        XCTAssertEqual(fallback.path, "/Users/example/.config/ghostty/themes")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
