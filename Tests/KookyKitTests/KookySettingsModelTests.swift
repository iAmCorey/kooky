import XCTest
@testable import KookyKit

@MainActor
final class KookySettingsModelTests: XCTestCase {
    func testNativeAppLanguagePreferenceCodec() {
        XCTAssertEqual(KookyAppLanguage.resolved(nil), .system)
        XCTAssertEqual(KookyAppLanguage.resolved([]), .system)
        XCTAssertEqual(KookyAppLanguage.resolved(["en"]), .english)
        XCTAssertEqual(KookyAppLanguage.resolved(["en_US"]), .english)
        XCTAssertEqual(KookyAppLanguage.resolved(["zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(KookyAppLanguage.resolved(["zh_CN"]), .simplifiedChinese)
        XCTAssertEqual(KookyAppLanguage.resolved(["zh-Hant"]), .system)
        XCTAssertEqual(KookyAppLanguage.resolved(["zh_TW"]), .system)
        XCTAssertEqual(KookyAppLanguage.resolved(["fr"]), .system)
    }

    func testSystemLanguagePreviewUsesFirstSupportedGlobalLanguage() {
        XCTAssertEqual(
            KookyAppLanguage.systemPreferred(
                from: ["fr-FR", "zh-Hans-CN", "en-US"]
            ),
            .simplifiedChinese
        )
        XCTAssertEqual(
            KookyAppLanguage.systemPreferred(
                from: ["fr-FR", "en-US", "zh-Hans-CN"]
            ),
            .english
        )
        XCTAssertEqual(
            KookyAppLanguage.systemPreferred(from: ["zh-Hant", "en-US"]),
            .english
        )
        XCTAssertEqual(
            KookyAppLanguage.systemPreferred(from: ["zh-TW", "en-US"]),
            .english
        )
        XCTAssertEqual(KookyAppLanguage.systemPreferred(from: ["fr-FR"]), .english)
    }

    func testNativeAppLanguageWritesAppleLanguagesWithoutKookyConfig() {
        let suite = "KookyAppLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        KookyAppLanguage.simplifiedChinese.persist(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])

        KookyAppLanguage.english.persist(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

        KookyAppLanguage.system.persist(to: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }

    func testAppLanguageOnlyNeedsRestartAfterSelectionChanges() {
        let model = KookySettingsModel()
        let launchedLanguage = model.appLanguage
        let changedLanguage = KookyAppLanguage.allCases.first { $0 != launchedLanguage }!

        XCTAssertFalse(model.appLanguageNeedsRestart)
        model.appLanguage = changedLanguage
        XCTAssertTrue(model.appLanguageNeedsRestart)
        model.appLanguage = launchedLanguage
        XCTAssertFalse(model.appLanguageNeedsRestart)
    }

    func testSelectedLanguagePreviewUsesItsNativeLocalizationBundle() {
        let chineseBundle = KookyAppLanguage.simplifiedChinese.previewBundle
        XCTAssertEqual(
            String(
                localized: "Changes take effect after restarting Kooky.",
                bundle: chineseBundle
            ),
            "更改将在重启 Kooky 后生效。"
        )
        XCTAssertEqual(
            String(localized: "Restart Kooky", bundle: chineseBundle),
            "重启 Kooky"
        )

        let englishBundle = KookyAppLanguage.english.previewBundle
        XCTAssertEqual(
            String(
                localized: "Changes take effect after restarting Kooky.",
                bundle: englishBundle
            ),
            "Changes take effect after restarting Kooky."
        )
        XCTAssertEqual(
            String(localized: "Restart Kooky", bundle: englishBundle),
            "Restart Kooky"
        )
    }

    func testNativeChineseLocalizationLoadsFromResourceBundle() throws {
        let bundle = try languageBundle("zh-Hans")
        XCTAssertEqual(
            String(localized: "General", bundle: bundle),
            "通用"
        )
        XCTAssertEqual(
            String.localizedStringWithFormat(
                String(localized: "Tab %d", bundle: bundle),
                3
            ),
            "标签页 3"
        )
        XCTAssertEqual(
            String(localized: "restore-window-size", bundle: bundle),
            "重启后恢复窗口大小"
        )
        XCTAssertEqual(
            String(localized: "Restore each window's size after restarting Kooky.", bundle: bundle),
            "重启 Kooky 后恢复每个窗口的大小。"
        )

        XCTAssertEqual(
            String(localized: "Untranslated test key", bundle: bundle),
            "Untranslated test key"
        )
    }

    func testNativeEnglishLocalizationKeepsSourceStrings() throws {
        let bundle = try languageBundle("en")
        XCTAssertEqual(
            String(localized: "General", bundle: bundle),
            "General"
        )
        XCTAssertEqual(
            String(localized: "restore-window-size", bundle: bundle),
            "Restore window size"
        )
    }

    func testKookyResourceBundleIsProcessCached() throws {
        let first = try XCTUnwrap(kookyResourceBundle())
        let second = try XCTUnwrap(kookyResourceBundle())
        XCTAssertTrue(first === second)
        XCTAssertTrue(first === Bundle.kookyResources)
    }

    private func languageBundle(_ identifier: String) throws -> Bundle {
        let resourceURL = try XCTUnwrap(Bundle.kookyResources.resourceURL)
        let candidates = [identifier, identifier.lowercased()]
        return try XCTUnwrap(candidates.lazy.compactMap { language in
            Bundle(url: resourceURL.appendingPathComponent(
                "\(language).lproj",
                isDirectory: true
            ))
        }.first)
    }

    func testShowSearchPillDefaultsToVisible() {
        XCTAssertTrue(
            KookySettingsModel.resolvedShowSearchPill(
                appearance: [:],
                legacyGeneral: [:]
            )
        )
    }

    func testShowSearchPillReadsLegacyGeneralKey() {
        XCTAssertFalse(
            KookySettingsModel.resolvedShowSearchPill(
                appearance: [:],
                legacyGeneral: ["showSearchPill": false]
            )
        )
    }

    func testShowSearchPillPrefersNewAppearanceKey() {
        XCTAssertTrue(
            KookySettingsModel.resolvedShowSearchPill(
                appearance: ["showSearchPill": true],
                legacyGeneral: ["showSearchPill": false]
            )
        )
    }

    func testAgentMenuBarItemDefaultsToVisible() {
        XCTAssertTrue(
            KookySettingsModel.resolvedShowInMenuBar(
                general: [:],
                legacyAppearance: [:]
            )
        )
    }

    func testAgentMenuBarItemReadsGeneralSetting() {
        XCTAssertFalse(
            KookySettingsModel.resolvedShowInMenuBar(
                general: ["showInMenuBar": false],
                legacyAppearance: [:]
            )
        )
    }

    func testAgentMenuBarItemMigratesAppearanceSetting() {
        XCTAssertFalse(
            KookySettingsModel.resolvedShowInMenuBar(
                general: [:],
                legacyAppearance: ["showAgentMenuBarItem": false]
            )
        )
        XCTAssertTrue(
            KookySettingsModel.resolvedShowInMenuBar(
                general: ["showInMenuBar": true],
                legacyAppearance: ["showAgentMenuBarItem": false]
            )
        )
    }
    func testRestoreWindowSizeDefaultsToOff() {
        XCTAssertFalse(KookySettingsModel.resolvedRestoreWindowSize(general: [:]))
    }

    func testRestoreWindowSizeReadsGeneralSetting() {
        XCTAssertTrue(
            KookySettingsModel.resolvedRestoreWindowSize(
                general: ["restoreWindowSize": true]
            )
        )
        XCTAssertFalse(
            KookySettingsModel.resolvedRestoreWindowSize(
                general: ["restoreWindowSize": false]
            )
        )
    }


    func testAgentMenuBarTextIsCappedAtThirtyCharacters() {
        let exact = String(repeating: "a", count: 30)
        XCTAssertEqual(AgentMenuBarController.shortMenuText(exact), exact)

        let long = String(repeating: "b", count: 40)
        let shortened = AgentMenuBarController.shortMenuText(long)
        XCTAssertEqual(shortened.count, 30)
        XCTAssertTrue(shortened.hasSuffix("…"))
        XCTAssertEqual(AgentMenuBarController.shortMenuText("first\nsecond"), "first second")
    }

    func testAgentMenuBarItemShowsPathOnASecondSecondaryLine() throws {
        let attributed = AgentMenuBarController.menuItemAttributedTitle(
            tabTitle: "Fixing scroll",
            path: "~/Github/kookycode"
        )
        XCTAssertEqual(attributed.string, "Fixing scroll\n~/Github/kookycode")

        let subtitleStart = attributed.string.distance(
            from: attributed.string.startIndex,
            to: attributed.string.firstIndex(of: "~")!
        )
        XCTAssertEqual(
            attributed.attribute(.foregroundColor, at: subtitleStart, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor
        )

        let longLabel = AgentMenuBarController.menuItemAttributedTitle(
            tabTitle: String(repeating: "title", count: 8),
            path: "/Users/corey/Github/a-very-long-parent-directory/with-another-level/kookycode"
        ).string
        let parts = longLabel.components(separatedBy: "\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, 34)
        XCTAssertTrue(parts[0].hasSuffix("…"))
        XCTAssertEqual(parts[1].count, 44)
        XCTAssertTrue(parts[1].hasPrefix("…"))
        XCTAssertTrue(parts[1].hasSuffix("/kookycode"))
    }

    func testAgentMenuBarItemOmitsEmptyPathLine() {
        XCTAssertEqual(
            AgentMenuBarController.menuItemAttributedTitle(
                tabTitle: "Fixing scroll",
                path: ""
            ).string,
            "Fixing scroll"
        )
    }

    func testAgentMenuBarCountIsHiddenWhenNoAgentIsRunning() {
        XCTAssertEqual(AgentMenuBarController.countTitle(0), "")
        XCTAssertEqual(AgentMenuBarController.countTitle(1), "1")
        XCTAssertEqual(AgentMenuBarController.countTitle(12), "12")
    }

    func testAgentMenuBarAppActionsAndAwakeModesFollowAgentList() throws {
        let monitor = AgentMonitor()
        let model = KookySettingsModel()
        model.awakeMode = .auto
        let controller = AgentMenuBarController(
            monitor: monitor,
            settings: model,
            onOpenKooky: {},
            onOpenSettings: {}
        )
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.count, 6)
        XCTAssertFalse(menu.items.contains(where: \.isSectionHeader))
        XCTAssertEqual(menu.items[0].title, "No agents running")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "Open Kooky")
        XCTAssertEqual(menu.items[3].title, "Settings…")
        XCTAssertEqual(menu.items[4].title, "Keep Awake")
        XCTAssertEqual(menu.items[5].title, "Quit Kooky")
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNil(item.image, "\(item.title) must remain text-only")
        }

        let awakeItems = try XCTUnwrap(menu.items[4].submenu).items
        XCTAssertEqual(awakeItems.map(\.title), ["Off", "Auto", "Always"])
        XCTAssertEqual(awakeItems.map(\.state), [.off, .on, .off])
        XCTAssertTrue(awakeItems.allSatisfy { $0.image == nil })
    }

    func testKookyMenuBarIconIsAnEighteenPointColourImage() {
        let image = KookyMenuBarIcon.make()
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
    }

    // MARK: - Custom agent persistence

    /// Every field must survive settings.json and come back. Serialise and
    /// parse are written as a pair but live in `save()` / `load()`, so a field
    /// added to one and forgotten in the other would silently reset on the
    /// user's next launch — an imported icon being the case that prompted
    /// this (issue #40).
    ///
    /// The reflection step is what gives the test teeth: every property of
    /// `CustomAgentData` defaults to `""`, so a newly added field would take
    /// its default here, round-trip as `"" == ""`, and pass while being
    /// dropped in production. Enumerating the live property list instead
    /// fails the moment a field exists that this test doesn't populate.
    func testCustomAgentFieldsAreAllRoundTripped() throws {
        let original = CustomAgentData(
            id: "custom-1",
            title: "My Agent",
            command: "aichat --model gpt-4",
            baseAgentId: AgentTemplate.claudeCodeID,
            iconAsset: "custom-1-deadbeef.png",
            symbol: "wand.and.stars",
            tintHex: "FF8800",
            env: "ANTHROPIC_BASE_URL=https://example.test"
        )
        for child in Mirror(reflecting: original).children {
            let name = child.label ?? "(unnamed)"
            let value = try XCTUnwrap(
                child.value as? String,
                "\(name) isn't a String — extend this test to cover its type"
            )
            XCTAssertFalse(
                value.isEmpty,
                "\(name) was added to CustomAgentData but left unset here, so the round trip "
                + "below can't tell whether the codec drops it"
            )
        }
        let dict = KookySettingsModel.serializeCustomAgents([original])
        XCTAssertEqual(
            dict.first?.count, Mirror(reflecting: original).children.count,
            "every field must reach settings.json"
        )
        XCTAssertEqual(try XCTUnwrap(KookySettingsModel.parseCustomAgents(dict).first), original)
    }

    /// Clearing an icon must drop the key entirely rather than write an empty
    /// string, so settings.json only ever carries what the user actually set.
    func testClearedIconDropsTheKey() {
        let dict = KookySettingsModel.serializeCustomAgents([CustomAgentData(id: "custom-1")])
        XCTAssertNil(dict.first?["iconAsset"])
        XCTAssertEqual(dict.first?.count, 1, "only `id` should remain")
    }

    func testParseDropsBuiltinCollisionsAndDuplicates() {
        let parsed = KookySettingsModel.parseCustomAgents([
            ["id": AgentTemplate.claudeCodeID, "title": "impostor"],
            ["id": "custom-1", "title": "first"],
            ["id": "custom-1", "title": "second"],
            ["title": "no id at all"],
        ])
        XCTAssertEqual(parsed.map(\.id), ["custom-1"])
        XCTAssertEqual(parsed.first?.title, "first")
    }

    /// Each baseline key is a promised default that must survive the user's
    /// own ghostty config (see `KookySettings.baselineConfig`); losing a line
    /// is a user-visible regression, not a cleanup.
    func testBaselineConfigPinsPromisedDefaults() {
        for line in [
            "copy-on-select = true",
            "cursor-click-to-move = true",
            "macos-option-as-alt = false",
            "confirm-close-surface = false",
        ] {
            XCTAssertTrue(
                KookySettings.baselineConfig.contains(line + "\n"),
                "baseline lost `\(line)`"
            )
        }
    }

    /// Only a spelling ghostty itself accepts as off reads as off. `0` is
    /// invalid to ghostty's enum parser — the emitted line is rejected, the
    /// baseline `true` stays live, so the toggle must report on. An imported
    /// repeated-line array resolves last-write-wins like ghostty does.
    func testResolvedCopyOnSelectReadsEveryHandWrittenForm() {
        XCTAssertTrue(KookySettingsModel.resolvedCopyOnSelect(nil))
        XCTAssertTrue(KookySettingsModel.resolvedCopyOnSelect(true))
        XCTAssertTrue(KookySettingsModel.resolvedCopyOnSelect("true"))
        XCTAssertTrue(KookySettingsModel.resolvedCopyOnSelect("clipboard"))
        XCTAssertTrue(KookySettingsModel.resolvedCopyOnSelect(0))
        XCTAssertFalse(KookySettingsModel.resolvedCopyOnSelect(false))
        XCTAssertFalse(KookySettingsModel.resolvedCopyOnSelect("false"))
        XCTAssertFalse(KookySettingsModel.resolvedCopyOnSelect(["true", false]))
        XCTAssertTrue(KookySettingsModel.resolvedCopyOnSelect([false, "clipboard"]))
    }

    /// Off writes the explicit `false` that overrides kooky's baseline; on
    /// drops the key. Sole survivor: a user-authored `"clipboard"` (see
    /// `copyOnSelectSavedValue` — the background-blur silent-drop lesson);
    /// redundant spellings of the default are normalized away.
    func testCopyOnSelectSavedValue() {
        XCTAssertEqual(
            KookySettingsModel.copyOnSelectSavedValue(existing: nil, enabled: false) as? Bool,
            false
        )
        XCTAssertEqual(
            KookySettingsModel.copyOnSelectSavedValue(existing: "clipboard", enabled: false) as? Bool,
            false
        )
        XCTAssertNil(KookySettingsModel.copyOnSelectSavedValue(existing: nil, enabled: true))
        XCTAssertNil(KookySettingsModel.copyOnSelectSavedValue(existing: false, enabled: true))
        XCTAssertNil(KookySettingsModel.copyOnSelectSavedValue(existing: "false", enabled: true))
        XCTAssertNil(KookySettingsModel.copyOnSelectSavedValue(existing: "true", enabled: true))
        XCTAssertEqual(
            KookySettingsModel.copyOnSelectSavedValue(existing: "clipboard", enabled: true) as? String,
            "clipboard"
        )
        // An imported array collapses to its effective (last) element.
        XCTAssertEqual(
            KookySettingsModel.copyOnSelectSavedValue(existing: ["true", "clipboard"], enabled: true) as? String,
            "clipboard"
        )
        XCTAssertNil(KookySettingsModel.copyOnSelectSavedValue(existing: [true, false], enabled: true))
    }
}
