import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App-specific macOS language preference. This only reads/writes the
/// `AppleLanguages` preference consumed by Foundation at the next launch;
/// string lookup remains entirely native (`String(localized:)` /
/// `LocalizedStringKey`) with no Kooky localization layer.
enum KookyAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    private static let supportedLocalizationIdentifiers = [
        KookyAppLanguage.english.rawValue,
        KookyAppLanguage.simplifiedChinese.rawValue,
    ]

    var id: String { rawValue }

    /// Language resource bundle used only by the Settings language preview.
    /// String lookup itself remains Foundation-native; selecting System
    /// Default resolves against the global Apple language list first.
    var previewBundle: Bundle {
        let language = self == .system ? Self.systemPreferred() : self
        guard let resourceURL = Bundle.kookyResources.resourceURL else {
            return .kookyResources
        }
        for identifier in [language.rawValue, language.rawValue.lowercased()] {
            let url = resourceURL.appendingPathComponent(
                "\(identifier).lproj",
                isDirectory: true
            )
            if let bundle = Bundle(url: url) { return bundle }
        }
        return .kookyResources
    }

    static func resolved(_ rawValue: Any?) -> KookyAppLanguage {
        let identifier: String?
        if let values = rawValue as? [String] {
            identifier = values.first
        } else {
            identifier = rawValue as? String
        }
        guard let identifier else { return .system }
        let components = identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            .split(separator: "-")
        switch components.first {
        case "en": return .english
        case "zh":
            let usesTraditionalChinese = components.contains("hant")
                || components.contains("tw")
                || components.contains("hk")
                || components.contains("mo")
            return usesTraditionalChinese ? .system : .simplifiedChinese
        default: return .system
        }
    }

    static func current(
        defaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> KookyAppLanguage {
        guard let bundleIdentifier,
              let domain = defaults.persistentDomain(forName: bundleIdentifier) else {
            return .system
        }
        return resolved(domain["AppleLanguages"])
    }

    static func systemPreferred(defaults: UserDefaults = .standard) -> KookyAppLanguage {
        let rawValue = defaults
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
        return systemPreferred(from: rawValue)
    }

    static func systemPreferred(from rawValue: Any?) -> KookyAppLanguage {
        let identifiers: [String]
        if let values = rawValue as? [String] {
            identifiers = values
        } else if let value = rawValue as? String {
            identifiers = [value]
        } else {
            identifiers = []
        }
        guard let preferred = Bundle.preferredLocalizations(
            from: supportedLocalizationIdentifiers,
            forPreferences: identifiers
        ).first else {
            return .english
        }
        return preferred.caseInsensitiveCompare(simplifiedChinese.rawValue) == .orderedSame
            ? .simplifiedChinese
            : .english
    }

    func persist(to defaults: UserDefaults = .standard) {
        switch self {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// `@Observable` mirror of the typed slice of `~/.kooky/settings.json` we
/// expose in the Settings UI. Loads on init, debounces writes back to disk
/// so rapid `Stepper` taps don't thrash the file. Only knows about keys that
/// have working bindings in libghostty today — kooky-specific keys
/// (`agent.*`, `sidebar.*`, …) live in settings.json but aren't surfaced in
/// the UI yet, because their behavior isn't wired and shipping a hollow
/// toggle is worse than no toggle.
@Observable
@MainActor
final class KookySettingsModel {
    /// Singleton so non-Settings UI surfaces (TabBarView's `+` menu, etc.)
    /// observe the same instance and react to user edits without a reload.
    static let shared = KookySettingsModel()

    /// Narrow app-boundary callbacks. Tests and standalone model instances
    /// keep the no-op defaults; AppDelegate wires the shared instance once at
    /// launch, so persistence never reaches through global NSApp.delegate.
    @ObservationIgnored var onAgentTemplatesChanged: () -> Void = {}
    @ObservationIgnored var onThemeAppearanceChanged: () -> Void = {}

    /// Stored by macOS in the app preference domain, not settings.json.
    /// `launchedAppLanguage` stays pinned for this process so Settings can
    /// distinguish a pending preference from the language currently in use.
    private let launchedAppLanguage: KookyAppLanguage
    var appLanguage: KookyAppLanguage
    var appLanguageNeedsRestart: Bool {
        appLanguage != launchedAppLanguage
    }

    var fontFamily: String = ""
    /// `nil` = not overridden — let libghostty fall back to ghostty's own
    /// config (or its default). Writing a default 13 unconditionally would
    /// silently shadow the user's `~/.config/ghostty/config` font-size.
    var fontSize: Int? = nil
    var cursorStyle: String = "block"
    /// `terminal.background-blur` — one of ghostty's `macos-glass-*` values
    /// turns on macOS 26 Liquid Glass chrome. No UI control yet (set it in
    /// settings.json or ghostty config); kept observable so chrome re-renders
    /// live when it changes. `nil` = opaque chrome.
    var backgroundBlur: String? = nil
    /// `terminal.background-opacity` (0...1). Drives both libghostty's surface
    /// alpha and kooky's glass tint. `nil` = unset (libghostty default).
    var backgroundOpacity: Double? = nil
    /// Dark chrome background mix toward black. Stored under
    /// `appearance.chromeBackgroundMix`; 0.16 preserves the existing default.
    var chromeBackgroundMix: Double = KookySettingsModel.defaultChromeBackgroundMix
    /// Window-control appearance and terminal palettes are separate choices.
    /// System follows macOS, while Light/Dark pin that appearance; the active
    /// side then selects its own terminal theme.
    var appearanceMode: KookyAppearanceMode = .system
    /// Live system side, mirrored into observable state. Reading AppKit's
    /// `effectiveAppearance` on demand resolves the right value, but SwiftUI
    /// cannot observe that external value — System mode would therefore swap
    /// libghostty's foreground while leaving existing glass/chrome layers on
    /// the old background. AppDelegate updates this from the appearance KVO
    /// callback so every Theme consumer invalidates in the same render pass.
    var systemAppearanceIsDark: Bool = KookyAppearanceMode.systemIsDark
    var lightTerminalThemeSelection: String = KookySettingsModel.defaultLightThemeSelection
    var darkTerminalThemeSelection: String = KookySettingsModel.defaultDarkThemeSelection
    var terminalThemeChoices: [KookyTerminalTheme] = KookyTerminalTheme.availableThemes()
    /// Unknown raw theme values from hand-edited settings.json. Each side is
    /// retained independently so unrelated Settings edits never erase a
    /// custom Ghostty theme path/name the picker cannot represent.
    private var customLightTerminalThemeRawValue: String? = nil
    private var customDarkTerminalThemeRawValue: String? = nil
    /// False only for the old no-theme "Default" state, whose contract was to
    /// inherit Ghostty's config. Unrelated Settings saves keep that state;
    /// changing any Appearance theme control opts into the paired schema.
    private(set) var pairedThemeSchemaEnabled: Bool = false

    /// User-customised order for the `+` menu agent list (Terminal stays
    /// pinned first regardless). Empty = use `AgentTemplate.all` order.
    /// Unknown ids are dropped on load; ids absent from this array but
    /// present in `AgentTemplate.all` are appended after, so a new agent
    /// shipped in a future kooky still shows up.
    var agentOrder: [String] = []
    var hiddenAgents: Set<String> = []
    /// Per-agent CLI options appended after the binary name when launching.
    /// E.g. `agentOptions["claude-code"] = "--model opus"` → KOOKY_AGENT
    /// becomes `claude --model opus`. The wrapper rc's `eval` splits on
    /// whitespace, so users handle their own quoting for spaces.
    var agentOptions: [String: String] = [:]
    /// `id` of the template that `+` / `⌘T` should open without prompting.
    /// `nil` (or pointing to a now-hidden / unknown agent) means "ask each
    /// time" — the popover stays. Terminal is always a valid choice.
    var defaultAgentId: String? = nil
    /// User-defined agent entries (`agents.custom` in settings.json). Each
    /// becomes a runtime `AgentTemplate` via `AgentTemplate.fromCustom`,
    /// joins the `+` menu / Settings list alongside the builtin agents,
    /// and supports the same visibility / order / options machinery.
    var customAgents: [CustomAgentData] = []
    /// User-defined "Terminal at <path>" presets (`terminals.presets` in
    /// settings.json). Independent of `agentOrder` / `hiddenAgents` /
    /// `agentOptions` — presets have their own list under Settings →
    /// Terminals, not a sub-section of the Agents one.
    var terminalPresets: [TerminalPreset] = []
    /// Sibling of `hiddenAgents` for the preset list. Hidden presets stay
    /// in `terminalPresets` so the user can re-enable without re-configuring.
    var hiddenPresets: Set<String> = []
    /// Pane status bar slots in user-chosen order. Default = the order
    /// kooky shipped before customisation (`StatusBarItemKind.defaultOrder`).
    /// Hand-edited settings.json with an unknown raw value or a duplicate
    /// drops the offending entry; missing entries are appended in default
    /// order on load so a new kind shipped in a future kooky still shows.
    var statusBarItems: [StatusBarItemKind] = StatusBarItemKind.defaultOrder
    /// Sibling of `hiddenAgents` for status bar slots. Hidden slots stay
    /// in `statusBarItems` so the user can re-enable without losing their
    /// custom order.
    var hiddenStatusBarItems: Set<StatusBarItemKind> = []
    /// Per-agent visibility of the tool-call activity pill, keyed by builtin
    /// agent id (`claude-code`, `pi`). Empty = every tool-reporting agent
    /// shows its pill (the default). An id in the set suppresses that agent's
    /// pill only — Claude and Pi toggle independently. Customs follow their
    /// base id, so a Claude-based custom honours the `claude-code` entry.
    /// Persisted under `statusbar.toolCallHidden`.
    var hiddenToolCallAgents: Set<String> = []
    /// Per-agent visibility of the usage gauge (Codex's account rate-limit
    /// windows), keyed like `hiddenToolCallAgents`. Empty = every usage-
    /// reporting agent shows its gauge (the default; currently only Codex).
    /// Persisted under `statusbar.usageHidden`. An open `Set` (not a closed
    /// enum) so a future usage-reporting agent's id round-trips untouched.
    var hiddenUsageAgents: Set<String> = []
    /// When true, kooky launches supported agent tabs with that CLI's exact
    /// resume command using the conversation id persisted on each tab. When
    /// false, every agent tab starts fresh — but the persisted conversation
    /// id stays on disk so turning the toggle back on can resume it later.
    var resumeConversations: Bool = true
    /// Last agent picked from an "Ask AI" control — drives the split button's
    /// brand mark + plain-click target, the `lastOpenInAppId` model.
    /// Persisted under `agents.lastAsk`.
    var lastAskAgentId: String? = nil

    /// Remember an Ask-AI pick so the split button's plain click tracks the
    /// user's last choice. Imperative save, not the Settings `.onChange`
    /// autosave chain — that chain is only mounted while the Settings window
    /// is open, and Ask controls fire with it closed.
    func noteAskAgentPicked(_ id: String) {
        guard lastAskAgentId != id else { return }
        lastAskAgentId = id
        scheduleSave()
    }
    /// Opt-in SSH integration for remote agent status. Disabled by default:
    /// when enabled, kooky installs an `ssh` wrapper that injects temporary
    /// marker-emitting agent wrappers into plain interactive `ssh host`
    /// sessions. The marker receiver itself is always available.
    var sshRemoteAgentDetection: Bool = false
    /// Shows the `⌘P` search pill in the top chrome strip. When false the
    /// pill is hidden (the palette stays reachable via `⌘P` / the File menu).
    /// Persisted under `appearance.showSearchPill` (only when non-default).
    /// The legacy `general.showSearchPill` key is still read during migration.
    var showSearchPill: Bool = true
    /// Select-to-copy: selected terminal text lands on the system clipboard
    /// the moment the mouse releases. On by default via kooky's baseline even
    /// when an inherited ghostty config disables it (issue #32, see
    /// `KookySettings.baselineConfig`). Persisted under
    /// `terminal.copy-on-select` (only when off).
    var copyOnSelect: Bool = true
    /// Shows Kooky in the system menu bar, including the live agent count and
    /// quick app actions. Persisted under `general.showInMenuBar`, only when
    /// non-default. The old `appearance.showAgentMenuBarItem` key is read once
    /// for migration.
    var showInMenuBar: Bool = true

    /// Whether the agent panel repeats each session's workspace tag as a stripe
    /// (and a `#name` hover line). Persisted under
    /// `appearance.showAgentPanelTag`, only when non-default. Worth a toggle
    /// because the panel is the one place tags aren't sparse — every agent in a
    /// tagged project carries that project's colour, so several rows can share
    /// one stripe.
    var showAgentPanelTag: Bool = true
    /// The sleep-protection dial (see `AwakeMode`): off / auto /
    /// always. `SleepGuard` observes this. The `always` notch needs the
    /// one-time privileged helper (`ClosedLidSleep`); first selection
    /// triggers the admin auth. Persisted under `general.awakeMode`
    /// (non-default only; default `auto`).
    var awakeMode: AwakeMode = .auto
    /// Bumped on every real dial change so the status light can play one
    /// short confirmation pulse. A *continuous* animation is what made #39
    /// expensive — anything that changes on screen forever keeps the whole
    /// display compositing at full refresh rate, however few pixels it
    /// touches. This counter is the trigger, deliberately not the view's own
    /// mount: a launch restore, a new window, or any SwiftUI rebuild leaves
    /// it untouched, so the light only pulses for a change the user just made.
    var awakeDialPulse: Int = 0
    /// Master switch for macOS notifications about a non-visible tab. When
    /// off, nothing is posted. The first post triggers the OS permission
    /// prompt. Persisted under `notifications.enabled` (only when non-default).
    var notificationsEnabled: Bool = true
    /// Per-kind sub-toggles, gated behind `notificationsEnabled`: notify when
    /// an agent starts waiting on you, and when a command exits non-zero.
    /// Persisted under `notifications.attention` / `.failure` (non-default only).
    var notifyOnAttention: Bool = true
    var notifyOnFailure: Bool = true
    /// "Open in" picker (top-chrome split button): user-customised order of
    /// `OpenInApp` ids; installed apps absent from this list follow in catalog
    /// order. Persisted under `openin.order`.
    var openInAppOrder: [String] = []
    /// Installed "Open in" apps the user suppressed from the picker. Sibling of
    /// `hiddenAgents`. Persisted under `openin.hidden`.
    var hiddenOpenInApps: Set<String> = []
    /// Last app picked from the "Open in" control — drives the split button's
    /// icon + plain-click target. Persisted under `openin.lastUsed`.
    var lastOpenInAppId: String? = nil
    /// Preferred editor for filesystem links Cmd+Clicked in a terminal.
    /// `nil` follows the macOS file association. Persisted under
    /// `openin.fileLinks`.
    var fileLinkAppId: String? = nil
    /// Preferred browser for http/https links Cmd+Clicked in a terminal.
    /// `nil` follows the macOS default browser. Persisted under
    /// `openin.webLinks`.
    var webLinkAppId: String? = nil

    private var saveWork: DispatchWorkItem?

    /// The single entry for changing the awake dial — the status light,
    /// the Settings control, and SleepGuard's reconcile seams all funnel
    /// here. Persists, and stepping into `always` for the first time runs
    /// the one-time privileged install (native admin prompt); a
    /// cancelled/failed auth falls back to `auto` unless the user already
    /// moved the dial again meanwhile. `runInstall: false` is the
    /// reconcile variant — external-state absorption must never pop the
    /// auth dialog.
    func applyAwakeMode(_ mode: AwakeMode, runInstall: Bool = true) {
        if mode != awakeMode { awakeDialPulse &+= 1 }
        awakeMode = mode
        scheduleSave()
        guard runInstall, mode == .always, !ClosedLidSleep.isInstalled else { return }
        ClosedLidSleep.install { [weak self] ok in
            guard let self else { return }
            if ok {
                // The dial moved to `always` BEFORE the helper existed, so
                // SleepGuard's earlier refresh saw helperReady == false and
                // engaged nothing — and a successful install changes no
                // observed state. Re-reconcile explicitly or the first
                // authorization never actually disables lid sleep.
                SleepGuard.shared.refresh()
            } else if self.awakeMode == .always {
                // Back through the single entry so the fallback also pulses
                // the light — the dial moved without the user touching it.
                self.applyAwakeMode(.auto, runInstall: false)
            }
        }
    }

    init() {
        let language = KookyAppLanguage.current()
        launchedAppLanguage = language
        appLanguage = language
        load()
    }

    func load() {
        let parsed = KookySettings.loadParsed() ?? [:]
        appLanguage = .current()
        terminalThemeChoices = KookyTerminalTheme.availableThemes()
        let terminal = parsed["terminal"] as? [String: Any] ?? [:]
        let appearance = parsed["appearance"] as? [String: Any] ?? [:]
        fontFamily = (terminal["font-family"] as? String) ?? ""
        fontSize = nil
        if let n = terminal["font-size"] as? Int {
            fontSize = n
        } else if let d = terminal["font-size"] as? Double {
            fontSize = Int(d)
        }
        cursorStyle = (terminal["cursor-style"] as? String) ?? "block"
        copyOnSelect = Self.resolvedCopyOnSelect(terminal["copy-on-select"])
        // Tolerate a JSON bool / numeric `background-blur` so a hand-edited
        // `false` isn't read as "unset" and then deleted on the next save.
        backgroundBlur = KookySettings.blurString(from: terminal["background-blur"])
        if let o = terminal["background-opacity"] as? Double {
            backgroundOpacity = o
        } else if let i = terminal["background-opacity"] as? Int {
            backgroundOpacity = Double(i)
        } else {
            backgroundOpacity = nil
        }
        chromeBackgroundMix = Self.resolvedChromeBackgroundMix(appearance["chromeBackgroundMix"])
        let themePreferences = Self.themePreferences(
            appearance: appearance,
            legacyRawTheme: terminal["theme"] as? String,
            in: terminalThemeChoices
        )
        pairedThemeSchemaEnabled = Self.shouldEnablePairedThemeSchema(
            appearance: appearance,
            legacyRawTheme: terminal["theme"] as? String
        )
        appearanceMode = themePreferences.mode
        lightTerminalThemeSelection = themePreferences.lightSelection
        darkTerminalThemeSelection = themePreferences.darkSelection
        customLightTerminalThemeRawValue = themePreferences.customLightRawValue
        customDarkTerminalThemeRawValue = themePreferences.customDarkRawValue

        let agents = parsed["agents"] as? [String: Any] ?? [:]
        agentOrder = (agents["order"] as? [String]) ?? []
        hiddenAgents = Set((agents["hidden"] as? [String]) ?? [])
        agentOptions = (agents["options"] as? [String: String]) ?? [:]
        defaultAgentId = agents["default"] as? String
        resumeConversations = (agents["resumeConversations"] as? Bool) ?? true
        lastAskAgentId = agents["lastAsk"] as? String

        let ssh = parsed["ssh"] as? [String: Any] ?? [:]
        sshRemoteAgentDetection = (ssh["remoteAgentDetection"] as? Bool) ?? false

        let general = parsed["general"] as? [String: Any] ?? [:]
        showInMenuBar = Self.resolvedShowInMenuBar(
            general: general,
            legacyAppearance: appearance
        )
        showAgentPanelTag = (appearance["showAgentPanelTag"] as? Bool) ?? true
        showSearchPill = Self.resolvedShowSearchPill(
            appearance: appearance,
            legacyGeneral: general
        )
        awakeMode = (general["awakeMode"] as? String).flatMap(AwakeMode.init) ?? .auto

        let notifications = parsed["notifications"] as? [String: Any] ?? [:]
        notificationsEnabled = (notifications["enabled"] as? Bool) ?? true
        notifyOnAttention = (notifications["attention"] as? Bool) ?? true
        notifyOnFailure = (notifications["failure"] as? Bool) ?? true

        let openin = parsed["openin"] as? [String: Any] ?? [:]
        openInAppOrder = (openin["order"] as? [String]) ?? []
        hiddenOpenInApps = Set((openin["hidden"] as? [String]) ?? [])
        lastOpenInAppId = openin["lastUsed"] as? String
        fileLinkAppId = openin["fileLinks"] as? String
        webLinkAppId = openin["webLinks"] as? String

        customAgents = Self.parseCustomAgents((agents["custom"] as? [[String: Any]]) ?? [])

        let statusbar = parsed["statusbar"] as? [String: Any] ?? [:]
        if let rawOrder = statusbar["order"] as? [String] {
            var seen: Set<StatusBarItemKind> = []
            let parsedOrder = rawOrder.compactMap { raw -> StatusBarItemKind? in
                guard let item = StatusBarItemKind(rawValue: raw), !seen.contains(item) else { return nil }
                seen.insert(item)
                return item
            }
            // Insert any items shipped in a kooky version newer than the
            // user's saved file at the position they hold in `defaultOrder`,
            // not blindly appended. Appending would break the equality
            // check at `statusOrderIsDefault` for upgrading users whose
            // saved order was the old default — they'd start writing an
            // explicit (now non-default) `statusbar.order` block to
            // settings.json on first save and `hasCustomisation` would
            // report true forever even though they never customised.
            let missing = StatusBarItemKind.allCases.filter { !seen.contains($0) }
            var rebuilt = parsedOrder
            for newKind in missing {
                // The default position is the slot it occupies in defaultOrder.
                // Anchor relative to the nearest already-present neighbour so
                // user-customised orders preserve the intent (e.g., if the
                // user moved gitDiff first, .toolCallActivity still inserts
                // before pythonVenv — its defaultOrder right neighbour).
                let defaultIndex = StatusBarItemKind.defaultOrder.firstIndex(of: newKind) ?? rebuilt.count
                let rightNeighbours = StatusBarItemKind.defaultOrder.suffix(from: defaultIndex + 1)
                let insertBefore = rebuilt.firstIndex(where: { rightNeighbours.contains($0) }) ?? rebuilt.count
                rebuilt.insert(newKind, at: insertBefore)
            }
            statusBarItems = rebuilt
        } else {
            statusBarItems = StatusBarItemKind.defaultOrder
        }
        let rawHiddenStatus = (statusbar["hidden"] as? [String]) ?? []
        hiddenStatusBarItems = Set(rawHiddenStatus.compactMap(StatusBarItemKind.init(rawValue:)))
        hiddenToolCallAgents = Set((statusbar["toolCallHidden"] as? [String]) ?? [])
        hiddenUsageAgents = Set((statusbar["usageHidden"] as? [String]) ?? [])

        let terminals = parsed["terminals"] as? [String: Any] ?? [:]
        hiddenPresets = Set((terminals["hidden"] as? [String]) ?? [])
        let rawPresets = (terminals["presets"] as? [[String: Any]]) ?? []
        // Same id-uniqueness defence as customAgents — a hand-edited
        // settings.json with a duplicate or a builtin-colliding preset id
        // would otherwise produce two AgentTemplate rows with the same id
        // (visibleOrdered would still surface both, but ForEach renders
        // glitchy and id-based lookups become non-deterministic).
        var presetSeen: Set<String> = []
        let builtinIds = Set(AgentTemplate.builtin.map(\.id))
        let customIds = Set(customAgents.map(\.id))
        terminalPresets = rawPresets.compactMap { dict -> TerminalPreset? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            if builtinIds.contains(id) || customIds.contains(id) { return nil }
            if !presetSeen.insert(id).inserted { return nil }
            return TerminalPreset(
                id: id,
                title: (dict["title"] as? String) ?? "",
                path: (dict["path"] as? String) ?? ""
            )
        }
    }

    /// settings.json ⇄ `CustomAgentData`. Extracted from `load()` / `save()`
    /// as a pair, and kept adjacent, because they have to agree key-for-key:
    /// a field serialised but not parsed (or vice versa) silently drops the
    /// user's setting on the next launch, with nothing at the call site to
    /// hint at the asymmetry. `testCustomAgentFieldsAreAllRoundTripped`
    /// enumerates the fields off a reflected instance, so a field added to
    /// `CustomAgentData` and wired into neither side fails there.
    static func parseCustomAgents(_ raw: [[String: Any]]) -> [CustomAgentData] {
        let builtinIds = Set(AgentTemplate.builtin.map(\.id))
        var seen: Set<String> = []
        return raw.compactMap { dict -> CustomAgentData? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            // Drop hand-edited collisions with builtin agents, and the
            // second occurrence of a duplicated id, so the live `all` list
            // is guaranteed-unique downstream.
            if builtinIds.contains(id) { return nil }
            if !seen.insert(id).inserted { return nil }
            return CustomAgentData(
                id: id,
                title: (dict["title"] as? String) ?? "",
                command: (dict["command"] as? String) ?? "",
                baseAgentId: (dict["baseAgentId"] as? String) ?? "",
                iconAsset: (dict["iconAsset"] as? String) ?? "",
                symbol: (dict["symbol"] as? String) ?? "",
                tintHex: (dict["tintHex"] as? String) ?? "",
                env: (dict["env"] as? String) ?? ""
            )
        }
    }

    /// Empty fields drop their key so settings.json only carries what the
    /// user actually set.
    static func serializeCustomAgents(_ agents: [CustomAgentData]) -> [[String: Any]] {
        agents.compactMap { c in
            guard !c.id.isEmpty else { return nil }
            var dict: [String: Any] = ["id": c.id]
            if !c.title.isEmpty { dict["title"] = c.title }
            if !c.command.isEmpty { dict["command"] = c.command }
            if !c.baseAgentId.isEmpty { dict["baseAgentId"] = c.baseAgentId }
            if !c.iconAsset.isEmpty { dict["iconAsset"] = c.iconAsset }
            if !c.symbol.isEmpty { dict["symbol"] = c.symbol }
            if !c.tintHex.isEmpty { dict["tintHex"] = c.tintHex }
            if !c.env.isEmpty { dict["env"] = c.env }
            return dict
        }
    }

    /// Schedules a debounced write. UI bindings call this on every change;
    /// the 300ms timer collapses a burst of edits (Stepper, typing, etc.)
    /// into one write.
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Cancels the pending debounce and writes synchronously. Called from
    /// the Restart flow so the new instance is guaranteed to see the user's
    /// latest edits.
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        save()
    }

    /// Appearance controls are the explicit opt-in boundary for legacy
    /// Default users. Font, cursor, agent, and other saves must not cross it.
    func activatePairedThemeSchemaAndSave() {
        pairedThemeSchemaEnabled = true
        flushSave()
    }

    private func save() {
        var parsed = KookySettings.loadParsed() ?? [:]
        var terminal = parsed["terminal"] as? [String: Any] ?? [:]
        let previousTerminal = terminal
        let previousAppearance = parsed["appearance"] as? [String: Any] ?? [:]
        var appearance = previousAppearance
        if KookySettings.hasPairedThemeSchema(appearance) {
            pairedThemeSchemaEnabled = true
        }
        // Sentinel values (empty string / nil / "block") drop the key so
        // libghostty falls back to ghostty's own config or its own default.
        terminal["font-family"] = fontFamily.isEmpty ? nil : fontFamily
        terminal["font-size"] = fontSize
        terminal["cursor-style"] = cursorStyle == "block" ? nil : cursorStyle
        terminal["copy-on-select"] = Self.copyOnSelectSavedValue(
            existing: terminal["copy-on-select"],
            enabled: copyOnSelect
        )
        terminal["background-blur"] = backgroundBlur
        terminal["background-opacity"] = backgroundOpacity
        // Explicit legacy themes can migrate losslessly to their matching
        // side. A missing legacy theme is different: it was the old Default
        // sentinel and must keep inheriting Ghostty until the user edits an
        // Appearance theme control.
        if pairedThemeSchemaEnabled {
            terminal.removeValue(forKey: "theme")
        }
        parsed["terminal"] = terminal

        let nonEmptyOptions = agentOptions.filter { !$0.value.isEmpty }
        let serialisedCustom = Self.serializeCustomAgents(customAgents)
        let allDefaults = agentOrder.isEmpty
            && hiddenAgents.isEmpty
            && nonEmptyOptions.isEmpty
            && defaultAgentId == nil
            && serialisedCustom.isEmpty
            && resumeConversations  // default-true is the no-op case
            && lastAskAgentId == nil
        if allDefaults {
            parsed.removeValue(forKey: "agents")
        } else {
            var agents = parsed["agents"] as? [String: Any] ?? [:]
            agents["order"] = agentOrder.isEmpty ? nil : agentOrder
            agents["hidden"] = hiddenAgents.isEmpty ? nil : Array(hiddenAgents).sorted()
            agents["options"] = nonEmptyOptions.isEmpty ? nil : nonEmptyOptions
            agents["default"] = defaultAgentId
            agents["custom"] = serialisedCustom.isEmpty ? nil : serialisedCustom
            // Only serialise when non-default to keep settings.json lean.
            agents["resumeConversations"] = resumeConversations ? nil : false
            agents["lastAsk"] = lastAskAgentId
            parsed["agents"] = agents
        }

        var ssh = parsed["ssh"] as? [String: Any] ?? [:]
        ssh["remoteAgentDetection"] = sshRemoteAgentDetection ? true : nil
        if ssh.isEmpty {
            parsed.removeValue(forKey: "ssh")
        } else {
            parsed["ssh"] = ssh
        }

        var general = parsed["general"] as? [String: Any] ?? [:]
        // One-way compatibility migrations: consume the old homes above, but
        // only write each setting's current namespace from now on.
        general.removeValue(forKey: "showSearchPill")
        general.removeValue(forKey: "language")
        general["showInMenuBar"] = showInMenuBar ? nil : false
        general["awakeMode"] = awakeMode == .auto ? nil : awakeMode.rawValue
        if general.isEmpty {
            parsed.removeValue(forKey: "general")
        } else {
            parsed["general"] = general
        }

        let lightTheme = Self.persistedThemeValue(
            selection: lightTerminalThemeSelection,
            customRawValue: customLightTerminalThemeRawValue,
            in: terminalThemeChoices
        )
        let darkTheme = Self.persistedThemeValue(
            selection: darkTerminalThemeSelection,
            customRawValue: customDarkTerminalThemeRawValue,
            in: terminalThemeChoices
        )
        if pairedThemeSchemaEnabled {
            appearance["themeSchemaVersion"] = KookySettings.pairedThemeSchemaVersion
            appearance["mode"] = appearanceMode == .system ? nil : appearanceMode.rawValue
            appearance["lightTheme"] = lightTheme == KookyTerminalTheme.defaultLightStoredValue
                ? nil
                : lightTheme
            appearance["darkTheme"] = darkTheme == KookyTerminalTheme.defaultDarkStoredValue
                ? nil
                : darkTheme
        }
        appearance["chromeBackgroundMix"] = abs(
            min(max(chromeBackgroundMix, 0), 1) - Self.defaultChromeBackgroundMix
        ) < 0.0005 ? nil : min(max(chromeBackgroundMix, 0), 1)
        appearance["showSearchPill"] = showSearchPill ? nil : false
        appearance.removeValue(forKey: "showAgentMenuBarItem")
        appearance["showAgentPanelTag"] = showAgentPanelTag ? nil : false
        if appearance.isEmpty {
            parsed.removeValue(forKey: "appearance")
        } else {
            parsed["appearance"] = appearance
        }

        var notifications = parsed["notifications"] as? [String: Any] ?? [:]
        notifications["enabled"] = notificationsEnabled ? nil : false
        notifications["attention"] = notifyOnAttention ? nil : false
        notifications["failure"] = notifyOnFailure ? nil : false
        if notifications.isEmpty {
            parsed.removeValue(forKey: "notifications")
        } else {
            parsed["notifications"] = notifications
        }

        var openin = parsed["openin"] as? [String: Any] ?? [:]
        openin["order"] = openInAppOrder.isEmpty ? nil : openInAppOrder
        openin["hidden"] = hiddenOpenInApps.isEmpty ? nil : Array(hiddenOpenInApps).sorted()
        openin["lastUsed"] = lastOpenInAppId
        openin["fileLinks"] = fileLinkAppId
        openin["webLinks"] = webLinkAppId
        if openin.isEmpty {
            parsed.removeValue(forKey: "openin")
        } else {
            parsed["openin"] = openin
        }

        let serialisedPresets: [[String: Any]] = terminalPresets.compactMap { p in
            guard !p.id.isEmpty else { return nil }
            var dict: [String: Any] = ["id": p.id]
            if !p.title.isEmpty { dict["title"] = p.title }
            if !p.path.isEmpty { dict["path"] = p.path }
            return dict
        }
        if serialisedPresets.isEmpty && hiddenPresets.isEmpty {
            parsed.removeValue(forKey: "terminals")
        } else {
            var terminals = parsed["terminals"] as? [String: Any] ?? [:]
            terminals["presets"] = serialisedPresets.isEmpty ? nil : serialisedPresets
            terminals["hidden"] = hiddenPresets.isEmpty ? nil : Array(hiddenPresets).sorted()
            parsed["terminals"] = terminals
        }

        let statusOrderIsDefault = statusBarItems == StatusBarItemKind.defaultOrder
        if statusOrderIsDefault && hiddenStatusBarItems.isEmpty && hiddenToolCallAgents.isEmpty && hiddenUsageAgents.isEmpty {
            parsed.removeValue(forKey: "statusbar")
        } else {
            var statusbar = parsed["statusbar"] as? [String: Any] ?? [:]
            statusbar["order"] = statusOrderIsDefault ? nil : statusBarItems.map(\.rawValue)
            statusbar["hidden"] = hiddenStatusBarItems.isEmpty ? nil : hiddenStatusBarItems.map(\.rawValue).sorted()
            statusbar["toolCallHidden"] = hiddenToolCallAgents.isEmpty ? nil : Array(hiddenToolCallAgents).sorted()
            statusbar["usageHidden"] = hiddenUsageAgents.isEmpty ? nil : Array(hiddenUsageAgents).sorted()
            parsed["statusbar"] = statusbar
        }

        KookySettings.write(parsed)
        KookyShellIntegration.refreshClaudeCustomSettings(customAgents: customAgents)
        // Same live-set sweep as the line above, for imported agent icons —
        // covers deletion, reset-to-defaults, a cleared icon, the file a
        // re-import superseded, and anything a hand-edited settings.json
        // dropped.
        AgentIconStore.prune(keeping: customAgents)
        // `Session.agent` is a snapshot taken at spawn, so an edit to a custom
        // agent (a newly imported logo, a rename) would otherwise only reach
        // tabs opened afterwards. Unconditional: the store gates on an actual
        // template change, and this already runs behind the save debounce.
        onAgentTemplatesChanged()
        KookyShellIntegration.refreshSshRemoteAgentDetection(enabled: sshRemoteAgentDetection)
        // Theme, appearance mode, or glass (blur / opacity) diff triggers the chrome /
        // window-appearance refresh — font and cursor changes also flow
        // through `reloadConfig` so libghostty picks up the new values, but
        // they don't change chrome tokens, so skip the window pass for them.
        let appearanceThemeChanged = (previousAppearance["mode"] as? String) != (appearance["mode"] as? String)
            || (previousAppearance["lightTheme"] as? String) != (appearance["lightTheme"] as? String)
            || (previousAppearance["darkTheme"] as? String) != (appearance["darkTheme"] as? String)
            || (previousAppearance["themeSchemaVersion"] as? NSNumber) != (appearance["themeSchemaVersion"] as? NSNumber)
            || (previousAppearance["chromeBackgroundMix"] as? NSNumber) != (appearance["chromeBackgroundMix"] as? NSNumber)
        let themeChanged = (previousTerminal["theme"] as? String) != (terminal["theme"] as? String)
            || appearanceThemeChanged
        let glassChanged = (previousTerminal["background-blur"] as? String) != (terminal["background-blur"] as? String)
            || (previousTerminal["background-opacity"] as? NSNumber) != (terminal["background-opacity"] as? NSNumber)
        let terminalChanged = !NSDictionary(dictionary: previousTerminal).isEqual(to: terminal)
        if terminalChanged || appearanceThemeChanged {
            LibghosttyApp.shared.reloadConfig()
            if themeChanged || glassChanged {
                onThemeAppearanceChanged()
            }
        }
    }

    func resetAgentCustomisation() {
        agentOrder = []
        hiddenAgents = []
        agentOptions = [:]
        defaultAgentId = nil
        customAgents = []
        scheduleSave()
    }

    static let defaultLightThemeSelection = KookyTerminalTheme.defaultLightID
    static let defaultDarkThemeSelection = KookyTerminalTheme.defaultDarkID
    /// Retained for the raw-theme codec and migration tests. The new UI always
    /// has a concrete default on each side rather than an unstyled sentinel.
    static let defaultThemeSelection = "__kooky-default-theme"
    static let customThemeSelection = "__kooky-custom-theme"

    struct ThemePreferences: Equatable {
        let mode: KookyAppearanceMode
        let lightSelection: String
        let darkSelection: String
        let customLightRawValue: String?
        let customDarkRawValue: String?
    }

    static func resolvedShowSearchPill(
        appearance: [String: Any],
        legacyGeneral: [String: Any]
    ) -> Bool {
        (appearance["showSearchPill"] as? Bool)
            ?? (legacyGeneral["showSearchPill"] as? Bool)
            ?? true
    }

    static func resolvedChromeBackgroundMix(_ rawValue: Any?) -> Double {
        let value: Double
        if let number = rawValue as? NSNumber {
            value = number.doubleValue
        } else {
            value = defaultChromeBackgroundMix
        }
        return min(max(value, 0), 1)
    }

    /// The importer stores repeated ghostty config lines as a JSON array and
    /// `formatGhosttyLines` re-emits them in order, so — per ghostty's
    /// last-write-wins — the LAST element is the effective value.
    private static func lastGhosttyValue(_ raw: Any?) -> Any? {
        (raw as? [Any])?.last ?? raw
    }

    /// ghostty's `copy-on-select` is an enum (`false` / `true` / `clipboard`)
    /// a user can hand-write in any JSON form — bool, string, or a
    /// repeated-line array. Only a spelling ghostty itself accepts as off
    /// (`false`) reads as off: an invalid value like `0` is REJECTED by
    /// ghostty's parser, so kooky's baseline `true` stays live and the toggle
    /// must report on, not echo the user's intent (Codex P2).
    static func resolvedCopyOnSelect(_ raw: Any?) -> Bool {
        KookySettings.blurString(from: lastGhosttyValue(raw)) != "false"
    }

    /// What `save()` stores for `terminal.copy-on-select`. Off is an explicit
    /// `false` (it must override kooky's baseline `true`); on drops the key.
    /// The one survivor is a hand-written `"clipboard"` (an array collapses to
    /// its effective element): inside kooky it behaves exactly like `true` (no
    /// selection clipboard declared), but it's user-authored config this
    /// toggle didn't change — deleting it on an unrelated save is the
    /// background-blur silent-drop class. NB: that makes this the 2nd
    /// hand-rolled round-trip tolerance for a `terminal.*` key (`blurString`
    /// is the 1st); a 3rd should instead generalize `save()` to
    /// write-only-on-change across the terminal passthrough.
    static func copyOnSelectSavedValue(existing: Any?, enabled: Bool) -> Any? {
        guard enabled else { return false }
        return (lastGhosttyValue(existing) as? String) == "clipboard" ? "clipboard" : nil
    }

    static func resolvedShowInMenuBar(
        general: [String: Any],
        legacyAppearance: [String: Any]
    ) -> Bool {
        (general["showInMenuBar"] as? Bool)
            ?? (legacyAppearance["showAgentMenuBarItem"] as? Bool)
            ?? true
    }

    var selectedTerminalTheme: KookyTerminalTheme? {
        guard pairedThemeSchemaEnabled else { return nil }
        let selection = appearanceMode.resolvesDark(systemIsDark: systemAppearanceIsDark)
            ? darkTerminalThemeSelection
            : lightTerminalThemeSelection
        return terminalThemeChoices.first { $0.id == selection }
    }

    var customLightTerminalThemeLabel: String? {
        Self.customThemeLabel(
            selection: lightTerminalThemeSelection,
            rawValue: customLightTerminalThemeRawValue
        )
    }

    var customDarkTerminalThemeLabel: String? {
        Self.customThemeLabel(
            selection: darkTerminalThemeSelection,
            rawValue: customDarkTerminalThemeRawValue
        )
    }

    private static func customThemeLabel(selection: String, rawValue: String?) -> String? {
        guard selection == customThemeSelection else { return nil }
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "Custom (%@)", bundle: .kookyResources),
            raw
        )
    }

    var bundledTerminalThemes: [KookyTerminalTheme] {
        terminalThemeChoices.filter(\.isBundled)
    }

    var darkBundledThemes: [KookyTerminalTheme] {
        bundledTerminalThemes.filter(\.isDark)
    }

    var lightBundledThemes: [KookyTerminalTheme] {
        bundledTerminalThemes.filter { !$0.isDark }
    }

    var ghosttyUserThemes: [KookyTerminalTheme] {
        terminalThemeChoices.filter { !$0.isBundled }
    }

    var darkGhosttyUserThemes: [KookyTerminalTheme] {
        ghosttyUserThemes.filter(\.isDark)
    }

    var lightGhosttyUserThemes: [KookyTerminalTheme] {
        ghosttyUserThemes.filter { !$0.isDark }
    }

    /// Loads the new paired-theme schema and performs an in-memory migration
    /// from the old `terminal.theme` value. A legacy known light/dark theme is
    /// placed on the matching side and pins that appearance, preserving what
    /// the user saw before upgrading; the first subsequent save writes only
    /// the new schema. A fresh install defaults to System + One Light/Dark.
    static func themePreferences(
        appearance: [String: Any],
        legacyRawTheme: String?,
        in themes: [KookyTerminalTheme] = KookyTerminalTheme.presets
    ) -> ThemePreferences {
        let explicitMode = (appearance["mode"] as? String).flatMap(KookyAppearanceMode.init(rawValue:))

        func state(for raw: String?, defaultSelection: String) -> (selection: String, customRawValue: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return themeSelection(
                for: trimmed.isEmpty ? defaultSelection : trimmed,
                in: themes
            )
        }

        let hasPairedTheme = KookySettings.hasPairedThemeSchema(appearance)
        if hasPairedTheme {
            let light = state(
                for: appearance["lightTheme"] as? String,
                defaultSelection: KookyTerminalTheme.defaultLightStoredValue
            )
            let dark = state(
                for: appearance["darkTheme"] as? String,
                defaultSelection: KookyTerminalTheme.defaultDarkStoredValue
            )
            return ThemePreferences(
                mode: explicitMode ?? .system,
                lightSelection: light.selection,
                darkSelection: dark.selection,
                customLightRawValue: light.customRawValue,
                customDarkRawValue: dark.customRawValue
            )
        }

        let legacyTrimmed = legacyRawTheme?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !legacyTrimmed.isEmpty {
            let legacy = themeSelection(for: legacyTrimmed, in: themes)
            let knownLegacy = themes.first { $0.id == legacy.selection }
            // Unknown raw paths were rendered with dark fallback chrome in the
            // old implementation, so dark is the compatibility-safe side.
            let legacyIsDark = knownLegacy?.isDark ?? true
            let light = legacyIsDark
                ? state(for: nil, defaultSelection: KookyTerminalTheme.defaultLightStoredValue)
                : legacy
            let dark = legacyIsDark
                ? legacy
                : state(for: nil, defaultSelection: KookyTerminalTheme.defaultDarkStoredValue)
            return ThemePreferences(
                mode: explicitMode ?? (legacyIsDark ? .dark : .light),
                lightSelection: light.selection,
                darkSelection: dark.selection,
                customLightRawValue: light.customRawValue,
                customDarkRawValue: dark.customRawValue
            )
        }

        let light = state(for: nil, defaultSelection: KookyTerminalTheme.defaultLightStoredValue)
        let dark = state(for: nil, defaultSelection: KookyTerminalTheme.defaultDarkStoredValue)
        return ThemePreferences(
            mode: explicitMode ?? .system,
            lightSelection: light.selection,
            darkSelection: dark.selection,
            customLightRawValue: light.customRawValue,
            customDarkRawValue: dark.customRawValue
        )
    }

    static func shouldEnablePairedThemeSchema(
        appearance: [String: Any],
        legacyRawTheme: String?
    ) -> Bool {
        let legacy = legacyRawTheme?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return KookySettings.hasPairedThemeSchema(appearance) || !legacy.isEmpty
    }

    static func themeSelection(
        for rawTheme: String?,
        in themes: [KookyTerminalTheme] = KookyTerminalTheme.presets
    ) -> (selection: String, customRawValue: String?) {
        guard let rawTheme,
              !rawTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (defaultThemeSelection, nil)
        }
        if let theme = KookyTerminalTheme.theme(for: rawTheme, in: themes) {
            return (theme.id, nil)
        }
        return (customThemeSelection, rawTheme)
    }

    static func persistedThemeValue(
        selection: String,
        customRawValue: String?,
        in themes: [KookyTerminalTheme] = KookyTerminalTheme.presets
    ) -> String? {
        if selection == defaultThemeSelection {
            return nil
        }
        if selection == customThemeSelection {
            let raw = customRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        return themes.first { $0.id == selection }?.storedValue
    }

    /// Appends a new blank custom agent. The id is `custom-N`, the title is
    /// empty (user fills it inline) — `AgentTemplate.fromCustom` falls back
    /// to showing the id as title until the user edits it.
    func addCustomAgent() {
        let usedIds = Set(AgentTemplate.builtin.map(\.id) + customAgents.map(\.id))
        var n = customAgents.count + 1
        var candidate = "custom-\(n)"
        while usedIds.contains(candidate) { n += 1; candidate = "custom-\(n)" }
        customAgents.append(CustomAgentData(id: candidate))
        scheduleSave()
    }

    func deleteCustomAgent(id: String) {
        customAgents.removeAll { $0.id == id }
        agentOrder.removeAll { $0 == id }
        hiddenAgents.remove(id)
        agentOptions.removeValue(forKey: id)
        if defaultAgentId == id { defaultAgentId = nil }
        scheduleSave()
    }

    /// `preset-N` slug deliberately doesn't reuse the `custom-N` namespace
    /// so a hand-edited settings.json with a preset id stays distinct
    /// from a custom-agent id on the same numeric tail.
    func addTerminalPreset() {
        let usedIds = Set(
            AgentTemplate.builtin.map(\.id)
            + customAgents.map(\.id)
            + terminalPresets.map(\.id)
        )
        var n = terminalPresets.count + 1
        while usedIds.contains("preset-\(n)") { n += 1 }
        terminalPresets.append(TerminalPreset(id: "preset-\(n)"))
        scheduleSave()
    }

    func resetStatusBar() {
        statusBarItems = StatusBarItemKind.defaultOrder
        hiddenStatusBarItems = []
        hiddenToolCallAgents = []
        hiddenUsageAgents = []
        scheduleSave()
    }

    /// Clears "Open in" order + hidden customisation. Leaves `lastOpenInAppId`
    /// so the split button keeps pointing at the app the user last used.
    func resetOpenIn() {
        openInAppOrder = []
        hiddenOpenInApps = []
        scheduleSave()
    }

    func deleteTerminalPreset(id: String) {
        terminalPresets.removeAll { $0.id == id }
        hiddenPresets.remove(id)
        // Stale-default cleanup: if the user had this preset set as the
        // default for `+` / `⌘T`, the saved id would otherwise point at a
        // now-gone row → `defaultLaunchTemplate` returns nil → +/⌘T
        // silently fall back to the popover. Matches `deleteCustomAgent`.
        if defaultAgentId == id { defaultAgentId = nil }
        scheduleSave()
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, codingAgents, terminalPresets, openIn, statusBar, notifications, advanced

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .general: return String(localized: "General", bundle: .kookyResources)
        case .appearance: return String(localized: "Appearance", bundle: .kookyResources)
        case .codingAgents: return String(localized: "Agents", bundle: .kookyResources)
        case .terminalPresets: return String(localized: "Terminals", bundle: .kookyResources)
        case .openIn: return String(localized: "Open in", bundle: .kookyResources)
        case .statusBar: return String(localized: "Status Bar", bundle: .kookyResources)
        case .notifications: return String(localized: "Notifications", bundle: .kookyResources)
        case .advanced: return String(localized: "Advanced", bundle: .kookyResources)
        }
    }
}

/// Settings panel. Brutalist-minimal:
///   - sidebar list reads like a config-key index: mono font, `▸` prefix on
///     the selected row, no pill highlights, no icons
///   - detail surface is unboxed — rows are hairline-separated, labels are
///     kebab-case config keys in mono, headers use Onest display for the
///     single human-readable hook
///   - all separators are 1pt hairlines, all corners are sharp
/// The goal is to feel like polishing a `.toml` in a clean GUI, not a SaaS
/// settings panel.
struct KookySettingsView: View {
    @Bindable var model: KookySettingsModel
    let onOpenInTab: () -> Void
    @State private var selected: SettingsCategory = .general

    var body: some View {
        // The autosave `.onChange` observers are split across two statements
        // via an intermediate `let`: a single chain this long (16 modifiers)
        // overruns the Swift type-checker's budget ("unable to type-check in
        // reasonable time"). Each half stays comfortably under the limit.
        let core = HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.chromeHairline).frame(width: 1)
            ScrollView { detail }
                .frame(maxWidth: .infinity)
        }
        .glassWindowBackground(fallback: Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .onChange(of: model.fontFamily) { _, _ in model.scheduleSave() }
        .onChange(of: model.fontSize) { _, _ in model.scheduleSave() }
        .onChange(of: model.cursorStyle) { _, _ in model.scheduleSave() }
        .onChange(of: model.appearanceMode) { _, _ in model.activatePairedThemeSchemaAndSave() }
        .onChange(of: model.lightTerminalThemeSelection) { _, _ in model.activatePairedThemeSchemaAndSave() }
        .onChange(of: model.darkTerminalThemeSelection) { _, _ in model.activatePairedThemeSchemaAndSave() }
        .onChange(of: model.backgroundBlur) { _, _ in model.flushSave() }
        .onChange(of: model.backgroundOpacity) { _, _ in model.scheduleSave() }
        .onChange(of: model.agentOrder) { _, _ in model.scheduleSave() }
        .onChange(of: model.hiddenAgents) { _, _ in model.scheduleSave() }
        .onChange(of: model.agentOptions) { _, _ in model.scheduleSave() }
        .onChange(of: model.defaultAgentId) { _, _ in model.scheduleSave() }
        .onChange(of: model.openInAppOrder) { _, _ in model.scheduleSave() }
        .onChange(of: model.hiddenOpenInApps) { _, _ in model.scheduleSave() }
        .onChange(of: model.fileLinkAppId) { _, _ in model.scheduleSave() }
        .onChange(of: model.webLinkAppId) { _, _ in model.scheduleSave() }

        return core
            .onChange(of: model.customAgents) { _, _ in model.scheduleSave() }
            .onChange(of: model.resumeConversations) { _, _ in model.scheduleSave() }
            .onChange(of: model.sshRemoteAgentDetection) { _, _ in model.scheduleSave() }
            .onChange(of: model.showSearchPill) { _, _ in model.scheduleSave() }
            .onChange(of: model.copyOnSelect) { _, _ in model.scheduleSave() }
            .onChange(of: model.showInMenuBar) { _, _ in model.scheduleSave() }
            .onChange(of: model.showAgentPanelTag) { _, _ in model.scheduleSave() }
            .onChange(of: model.terminalPresets) { _, _ in model.scheduleSave() }
            .onChange(of: model.hiddenPresets) { _, _ in model.scheduleSave() }
            .onChange(of: model.statusBarItems) { _, _ in model.scheduleSave() }
            .onChange(of: model.hiddenStatusBarItems) { _, _ in model.scheduleSave() }
            .onChange(of: model.hiddenToolCallAgents) { _, _ in model.scheduleSave() }
            .onChange(of: model.hiddenUsageAgents) { _, _ in model.scheduleSave() }
            .onChange(of: model.notificationsEnabled) { _, _ in model.scheduleSave() }
            .onChange(of: model.notifyOnAttention) { _, _ in model.scheduleSave() }
            .onChange(of: model.notifyOnFailure) { _, _ in model.scheduleSave() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "SETTINGS", bundle: .kookyResources))
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 18)
            ForEach(SettingsCategory.allCases) { category in
                sidebarRow(category)
            }
            Spacer()
        }
        .frame(width: 168, alignment: .topLeading)
        .background(Theme.chromeFaint.opacity(0.08))
    }

    private func sidebarRow(_ category: SettingsCategory) -> some View {
        let isSelected = selected == category
        return HStack(spacing: 0) {
            Text(isSelected ? "▸" : " ")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.chromeForeground : Color.clear)
                .frame(width: 14, alignment: .leading)
            Text(category.title)
                .font(Theme.mono(12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.chromeForeground : Theme.chromeMuted)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { selected = category }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selected == .general
                || selected == .appearance
                || selected == .codingAgents
                || selected == .terminalPresets
            {
                Color.clear.frame(height: 26)
            } else {
                HStack(spacing: 14) {
                    Text(selected.title)
                        .font(Theme.display(18, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                    // The Notifications section's master switch lives on the title
                    // row; its per-kind sub-toggles sit in the body below.
                    if selected == .notifications {
                        Spacer(minLength: 14)
                        Toggle("", isOn: $model.notificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 22)
                Rectangle()
                    .fill(Theme.chromeHairline)
                    .frame(width: 32, height: 1)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }
            switch selected {
            case .general: generalDetail
            case .appearance: appearanceDetail
            case .codingAgents: codingAgentsDetail
            case .terminalPresets: terminalPresetsDetail
            case .openIn: openInDetail
            case .statusBar: statusBarDetail
            case .notifications: notificationsDetail
            case .advanced: advancedDetail
            }
            Spacer(minLength: 28)
        }
    }

    private var appearanceDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Appearance") {
                SettingsRow(label: "mode") {
                    Picker("", selection: $model.appearanceMode) {
                        Text(String(localized: "Follow System", bundle: .kookyResources)).tag(KookyAppearanceMode.system)
                        Text(String(localized: "Light", bundle: .kookyResources)).tag(KookyAppearanceMode.light)
                        Text(String(localized: "Dark", bundle: .kookyResources)).tag(KookyAppearanceMode.dark)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsHairline()
                SettingsRow(label: "light-theme") {
                    themeControl(
                        selection: $model.lightTerminalThemeSelection,
                        customLabel: model.customLightTerminalThemeLabel,
                        bundledThemes: model.lightBundledThemes,
                        userThemes: model.lightGhosttyUserThemes
                    )
                }
                SettingsHairline()
                SettingsRow(label: "dark-theme") {
                    themeControl(
                        selection: $model.darkTerminalThemeSelection,
                        customLabel: model.customDarkTerminalThemeLabel,
                        bundledThemes: model.darkBundledThemes,
                        userThemes: model.darkGhosttyUserThemes
                    )
                }
            }

            SettingsSection(title: "Terminal") {
                SettingsRow(label: "font-family") {
                    Picker("", selection: $model.fontFamily) {
                        Text(String(localized: "Default", bundle: .kookyResources)).tag("")
                        Divider()
                        ForEach(Self.monospaceFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 180, alignment: .trailing)
                }
                SettingsHairline()
                SettingsRow(label: "font-size") {
                    HStack(spacing: 8) {
                        Text("\(model.fontSize ?? Self.defaultFontSize)")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.chromeForeground)
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                        Stepper("", value: fontSizeBinding, in: 8...32)
                            .labelsHidden()
                    }
                }
                SettingsHairline()
                SettingsRow(label: "cursor-style") {
                    Picker("", selection: $model.cursorStyle) {
                        Text(String(localized: "Block", bundle: .kookyResources)).tag("block")
                        Text(String(localized: "Underline", bundle: .kookyResources)).tag("underline")
                        Text(String(localized: "Bar", bundle: .kookyResources)).tag("bar")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 180, alignment: .trailing)
                }
                SettingsHairline()
                SettingsRow(label: "liquid-glass") {
                    // Real Liquid Glass on macOS 26+; no effect on older systems.
                    // Tags are ghostty's `background-blur` values; "Off" stores
                    // `false` so it overrides a glassy ghostty config.
                    Picker("", selection: glassSelection) {
                        Text(String(localized: "Off", bundle: .kookyResources)).tag("false")
                        Text(String(localized: "Regular", bundle: .kookyResources)).tag("macos-glass-regular")
                        Text(String(localized: "Clear Glass", bundle: .kookyResources)).tag("macos-glass-clear")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 180, alignment: .trailing)
                }
                SettingsCaption("Requires macOS 26 or later.")
                SettingsHairline()
                SettingsRow(label: "background-opacity") {
                    HStack(spacing: 8) {
                        Text(backgroundOpacityLabel)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.chromeForeground)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Slider(value: backgroundOpacityBinding, in: 0.3...1.0, step: 0.01)
                            .frame(width: 140)
                    }
                }
                SettingsCaption("Window translucency — takes effect with liquid-glass or a numeric background-blur; opaque otherwise.")
                terminalRestartCallout
            }
            .padding(.top, 22)

            SettingsSection(title: "Window Chrome") {
                SettingsRow(label: "chrome-background-mix") {
                    HStack(spacing: 8) {
                        Text(chromeBackgroundMixLabel)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.chromeForeground)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Slider(value: chromeBackgroundMixBinding, in: 0...1, step: 0.01)
                            .frame(width: 140)
                    }
                }
                SettingsCaption("Dark chrome background mix toward black. 0% uses the theme background unchanged; 16% is the default.")
                SettingsHairline()
                SettingsRow(label: "show-search-pill") {
                    Toggle("", isOn: $model.showSearchPill)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsHairline()
                SettingsRow(label: "show-agent-panel-tag") {
                    Toggle("", isOn: $model.showAgentPanelTag)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .padding(.top, 22)
        }
    }

    private var generalDetail: some View {
        let previewBundle = model.appLanguage.previewBundle
        let restartCaption = String(
            localized: "Changes take effect after restarting Kooky.",
            bundle: previewBundle
        )
        let restartTitle = String(
            localized: "Restart Kooky",
            bundle: previewBundle
        )
        let systemDefaultTitle = String(
            localized: "System Default",
            bundle: KookyAppLanguage.system.previewBundle
        )

        return VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "App Language / 应用语言", localizesLabel: false) {
                Picker("", selection: Binding(
                    get: { model.appLanguage },
                    set: { language in
                        guard model.appLanguage != language else { return }
                        language.persist()
                        model.appLanguage = language
                    }
                )) {
                    Text(verbatim: systemDefaultTitle)
                        .tag(KookyAppLanguage.system)
                    Text(verbatim: "English")
                        .tag(KookyAppLanguage.english)
                    Text(verbatim: "简体中文")
                        .tag(KookyAppLanguage.simplifiedChinese)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 190, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text(verbatim: restartCaption)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                Spacer(minLength: 12)
                if model.appLanguageNeedsRestart {
                    BracketButton(restartTitle, localizesTitle: false, action: restartApp)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 10)

            SettingsSection(title: "Startup") {
                SettingsRow(label: "default-new-tab") {
                    Picker("", selection: $model.defaultAgentId) {
                        Text(String(localized: "Ask each time", bundle: .kookyResources)).tag(String?.none)
                        Divider()
                        ForEach(AgentTemplate.visibleOrdered(model: model)) { template in
                            Text(template.title).tag(String?.some(template.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 180, alignment: .trailing)
                }
            }
            .padding(.top, 22)

            SettingsSection(title: "Clipboard") {
                SettingsRow(label: "copy-on-select") {
                    Toggle("", isOn: $model.copyOnSelect)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsCaption("Selecting text copies it to the clipboard immediately.")
            }
            .padding(.top, 22)

            SettingsSection(title: "Menu Bar") {
                SettingsRow(label: "show-in-menu-bar") {
                    Toggle("", isOn: $model.showInMenuBar)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .padding(.top, 22)

            SettingsSection(title: "System") {
                // One dial, three notches of sleep protection (see AwakeMode).
                // Segmented, not a menu — all three notches visible at once.
                // The binding funnels through applyAwakeMode so the always-notch
                // auth flow runs no matter which control moved the dial.
                SettingsRow(label: "keep-awake") {
                    Picker("", selection: Binding(
                        get: { model.awakeMode },
                        set: { model.applyAwakeMode($0) }
                    )) {
                        Text(String(localized: "Off", bundle: .kookyResources)).tag(AwakeMode.off)
                        Text(String(localized: "Auto", bundle: .kookyResources)).tag(AwakeMode.auto)
                        Text(String(localized: "Always", bundle: .kookyResources)).tag(AwakeMode.always)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // Segmented pickers greedily stretch on macOS; pin to the
                    // intrinsic width so the row's Spacer right-aligns it like
                    // every other trailing control.
                    .fixedSize()
                }
                SettingsCaption("Auto: stay awake while agents or SSH work even lid closed.\nAlways: always stay awake.")
                SettingsHairline()
                // SSH remote agent detection lives here now (it was its own
                // one-toggle category before). The settings.json key stays
                // `ssh.remoteAgentDetection`; only the UI home moved.
                SettingsRow(label: "remote-agent-detection") {
                    Toggle("", isOn: $model.sshRemoteAgentDetection)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .padding(.top, 22)

            OpenWithPreferences(model: model)
                .padding(.top, 22)
        }
    }

    private var terminalPresetsDetail: some View {
        SettingsSection(title: "Presets") {
            TerminalPresetsList(model: model)
        }
    }

    private var openInDetail: some View {
        OpenInReorderList(model: model)
    }

    private var statusBarDetail: some View {
        StatusBarReorderList(model: model)
    }

    private var codingAgentsDetail: some View {
        SettingsSection(title: "Presets") {
            VStack(alignment: .leading, spacing: 0) {
                AgentReorderList(model: model)
                SettingsHairline()
                SettingsRow(label: "resume-conversation-when-reopen") {
                    Toggle("", isOn: $model.resumeConversations)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var notificationsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "agent") {
                Toggle("", isOn: $model.notifyOnAttention)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.notificationsEnabled)
            }
            SettingsRow(label: "command") {
                Toggle("", isOn: $model.notifyOnFailure)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.notificationsEnabled)
            }
        }
    }

    private var advancedDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "~/.kooky/settings.json") {
                BracketButton("open in new tab", action: onOpenInTab)
            }
            Text(String(localized: "Edit the raw JSON for any key not exposed above. Comments (`//`, `/* */`) are accepted.", bundle: .kookyResources))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.horizontal, 28)
                .padding(.top, 16)
        }
    }

    private var terminalRestartCallout: some View {
        HStack(spacing: 12) {
            Text(String(localized: "Theme reloads existing panes. Font and cursor changes may need restart.", bundle: .kookyResources))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeMuted)
            Spacer()
            BracketButton("restart kooky", action: restartApp)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
    }

    private func restartApp() {
        // Naively `openApplication` + `terminate` races: the new instance
        // boots while the old one still holds `~/Library/Application
        // Support/kooky/socket` and the persisted workspace file. The new
        // instance reads stale state and binds to the socket that the old
        // `applicationWillTerminate` is about to delete, leaving KookyHook
        // unable to reach anyone.
        //
        // Fix: sync-flush settings, detach a bash helper that waits for the
        // current PID to fully exit, then `open` a fresh instance. The
        // helper inherits PID 1 once kooky dies, so it keeps running after
        // our terminate.
        model.flushSave()
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = KookyShellIntegration.quote(Bundle.main.bundlePath)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.3; open -n \(bundle)"
        ]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func themeControl(
        selection: Binding<String>,
        customLabel: String?,
        bundledThemes: [KookyTerminalTheme],
        userThemes: [KookyTerminalTheme]
    ) -> some View {
        Picker("", selection: selection) {
            if let customLabel {
                Text(customLabel).tag(KookySettingsModel.customThemeSelection)
            }
            Section(String(localized: "Built-in", bundle: .kookyResources)) {
                ForEach(bundledThemes) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            if !userThemes.isEmpty {
                Section(String(localized: "Custom", bundle: .kookyResources)) {
                    ForEach(userThemes) { theme in
                        Text(theme.title).tag(theme.id)
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 220, alignment: .trailing)
    }

    /// Falls back to 13 when the user hasn't explicitly chosen a size —
    /// matches libghostty's own default so the Stepper display doesn't lie.
    private static let defaultFontSize = 13

    /// Bridges `model.fontSize: Int?` to `Stepper`'s required `Binding<Int>`.
    /// Reading the Stepper always shows a concrete number; writing sets the
    /// optional, which `save()` then writes only when non-nil.
    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { model.fontSize ?? Self.defaultFontSize },
            set: { model.fontSize = $0 }
        )
    }

    /// nil = unset (fully opaque, the ghostty default). Snapping ≥0.995 back
    /// to nil keeps the settings.json non-default-only: dragging to the right
    /// edge removes the key instead of pinning `1.0`.
    /// The MERGED opacity: kooky's own key, else the inherited ghostty-config
    /// value from the live host config — the slider must show (and be able to
    /// override) what the window actually renders at (Codex P2).
    private var effectiveBackgroundOpacity: Double {
        model.backgroundOpacity ?? LibghosttyApp.shared.hostConfig.backgroundOpacity
    }

    private var backgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { effectiveBackgroundOpacity },
            set: {
                let rounded = ($0 * 100).rounded() / 100
                let next: Double?
                if rounded >= 0.995 {
                    // 100% may only mean "unset" when nothing underneath is
                    // translucent — with an inherited value below 1, removing
                    // kooky's key would resurrect it, so full-right writes an
                    // EXPLICIT 1.0 override instead.
                    let inheritedClean = model.backgroundOpacity == nil
                        && LibghosttyApp.shared.hostConfig.backgroundOpacity >= 0.995
                    next = inheritedClean ? nil : 1.0
                } else {
                    next = rounded
                }
                // Equality-gate: @Observable setters invalidate dependents on
                // every write, and a drag emits many ticks that round to the
                // same 1% step — an ungated write re-renders every glass
                // layer + the sidebar per tick for nothing.
                if next != model.backgroundOpacity { model.backgroundOpacity = next }
            }
        )
    }

    private var backgroundOpacityLabel: String {
        "\(Int((effectiveBackgroundOpacity * 100).rounded()))%"
    }
    private var chromeBackgroundMixBinding: Binding<Double> {
        Binding(
            get: { model.chromeBackgroundMix },
            set: {
                let next = min(max(($0 * 100).rounded() / 100, 0), 1)
                if next != model.chromeBackgroundMix { model.chromeBackgroundMix = next }
            }
        )
    }

    private var chromeBackgroundMixLabel: String {
        "\(Int((model.chromeBackgroundMix * 100).rounded()))%"
    }

    /// The picker shows what's *in effect* (kooky's own value, else the ghostty
    /// fallback, else off), but always writes an explicit value — so picking
    /// "Off" stores `false` rather than clearing the key, keeping it distinct
    /// from "never set" (which is what defers to the ghostty config).
    ///
    /// The blur→opacity coupling lives in `KookySettings.apply` (the libghostty
    /// config builder), not here — so it holds for every config path and never
    /// clobbers a `background-opacity` the user set by hand.
    private var glassSelection: Binding<String> {
        Binding(
            get: {
                switch Theme.effectiveBlurRaw {
                case "macos-glass-regular": return "macos-glass-regular"
                case "macos-glass-clear": return "macos-glass-clear"
                default: return "false"
                }
            },
            set: { model.backgroundBlur = $0 }
        )
    }

    private static let monospaceFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .compactMap { family -> String? in
                guard let font = NSFont(name: family, size: 12), font.isFixedPitch else { return nil }
                return family
            }
            .sorted()
    }()

}

private struct SettingsRow<Trailing: View>: View {
    let label: String
    let localizesLabel: Bool
    @ViewBuilder var trailing: () -> Trailing

    init(
        label: String,
        localizesLabel: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.label = label
        self.localizesLabel = localizesLabel
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if localizesLabel {
                    Text(LocalizedStringKey(label), bundle: .kookyResources)
                } else {
                    Text(verbatim: label)
                }
            }
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.chromeForeground)
            Spacer(minLength: 14)
            trailing()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
    }
}

private struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chromeHairline.opacity(0.55))
            .frame(height: 1)
            .padding(.horizontal, 28)
    }
}

/// Muted footer note under a section's rows. This is the row-inset caption
/// variant only — the file's other muted texts use different paddings on
/// purpose (Advanced's JSON note, inline button labels).
private struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(LocalizedStringKey(text), bundle: .kookyResources)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.chromeMuted)
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 10)
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let localizesTitle: Bool

    var body: some View {
        Group {
            if localizesTitle {
                Text(LocalizedStringKey(title), bundle: .kookyResources)
            } else {
                Text(verbatim: title)
            }
        }
            .font(Theme.display(18, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let localizesTitle: Bool
    let content: Content

    init(
        title: String,
        localizesTitle: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.localizesTitle = localizesTitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: title, localizesTitle: localizesTitle)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Reorderable list of non-terminal agent templates. The user's saved order
/// (`model.agentOrder`) is the source of truth; templates absent from it
/// (e.g. a fresh kooky install, or a new agent in a future version) are
/// appended in their default `AgentTemplate.all` position.
private struct AgentReorderList: View {
    @Bindable var model: KookySettingsModel
    @State private var draggingId: String?
    @State private var endTargeted: Bool = false
    @State private var expandedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, template in
                if index > 0 { SettingsHairline() }
                AgentRow(
                    template: template,
                    visible: !model.hiddenAgents.contains(template.id),
                    isDragging: draggingId == template.id,
                    isExpanded: expandedId == template.id,
                    isCustom: isCustomId(template.id),
                    options: Binding(
                        get: { model.agentOptions[template.id] ?? "" },
                        set: { model.agentOptions[template.id] = $0 }
                    ),
                    title: customBinding(id: template.id, \.title),
                    command: customBinding(id: template.id, \.command),
                    baseAgentId: customBinding(id: template.id, \.baseAgentId),
                    env: customBinding(id: template.id, \.env),
                    iconAsset: customBinding(id: template.id, \.iconAsset),
                    onToggleVisible: { toggle(template.id) },
                    onToggleExpanded: {
                        expandedId = expandedId == template.id ? nil : template.id
                    },
                    onChooseIcon: { chooseIcon(forAgentId: template.id) },
                    onBeginDrag: { draggingId = template.id },
                    onDrop: { droppedId in
                        defer { draggingId = nil }
                        return reorder(draggedId: droppedId, before: template.id)
                    },
                    onDelete: isCustomId(template.id) ? { model.deleteCustomAgent(id: template.id) } : nil
                )
            }
            // Trailing drop catcher — drag past the last row to send the
            // agent to the end of the list. Without this, the bottom-most
            // position is only reachable by dropping onto the second-to-last
            // row, which reads wrong.
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingId = nil }
                    guard let id = items.first else { return false }
                    return moveToEnd(id)
                } isTargeted: { endTargeted = $0 }
            HStack {
                Button {
                    let newId = model.customAgents.last?.id
                    model.addCustomAgent()
                    if let id = model.customAgents.last?.id, id != newId {
                        expandedId = id
                    }
                } label: {
                    Text(String(localized: "+ add custom agent", bundle: .kookyResources))
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .bracketBorder()
                }
                .buttonStyle(.plain)
                Spacer()
                if hasCustomisation {
                    Button(String(localized: "reset to defaults", bundle: .kookyResources)) { model.resetAgentCustomisation() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .underline()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
        }
    }

    private func isCustomId(_ id: String) -> Bool {
        model.customAgents.contains(where: { $0.id == id })
    }

    /// Imports a logo for `id`. Sheet-modal on the Settings window, so
    /// resolving the agent by id in the completion handler is race-free
    /// (same reasoning as `chooseFolder(forPresetId:)`).
    private func chooseIcon(forAgentId id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .svg]
        panel.message = String(localized: "Choose an icon for this agent.", bundle: .kookyResources)
        let assign: (URL) -> Void = { url in
            guard let idx = model.customAgents.firstIndex(where: { $0.id == id }) else { return }
            do {
                model.customAgents[idx].iconAsset = try AgentIconStore.importIcon(from: url, agentId: id)
            } catch {
                // Deferred a runloop turn: the panel sheet is still attached
                // when its completion handler runs, and an app-modal alert
                // raised under it can land behind the sheet.
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Couldn't use that icon", bundle: .kookyResources)
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
        KookySettingsWindowController.shared.present(panel, onAccept: assign)
    }

    /// Binding into a specific custom agent's field. Returns a no-op binding
    /// if the row is a built-in agent (`AgentRow` ignores these bindings
    /// when `isCustom == false`).
    private func customBinding(id: String, _ key: WritableKeyPath<CustomAgentData, String>) -> Binding<String> {
        Binding(
            get: { model.customAgents.first(where: { $0.id == id })?[keyPath: key] ?? "" },
            set: { newValue in
                guard let idx = model.customAgents.firstIndex(where: { $0.id == id }) else { return }
                model.customAgents[idx][keyPath: key] = newValue
            }
        )
    }

    /// All non-terminal templates in the user's chosen order — visible and
    /// hidden alike. Hidden agents render greyed out but stay wherever the
    /// user dragged them, so toggling visibility doesn't move them. The
    /// `+` menu's filter to visible-only lives in `AgentTemplate.visibleOrdered`.
    private var rows: [AgentTemplate] { AgentTemplate.ordered(model: model) }

    private var hasCustomisation: Bool {
        !model.agentOrder.isEmpty
            || !model.hiddenAgents.isEmpty
            || model.agentOptions.values.contains(where: { !$0.isEmpty })
            || model.defaultAgentId != nil
            || !model.customAgents.isEmpty
    }

    private func toggle(_ id: String) {
        if model.hiddenAgents.contains(id) {
            model.hiddenAgents.remove(id)
        } else {
            model.hiddenAgents.insert(id)
        }
    }

    private func reorder(draggedId: String, before targetId: String) -> Bool {
        var ids = rows.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              let targetIdx = ids.firstIndex(of: targetId),
              sourceIdx != targetIdx else { return false }
        let item = ids.remove(at: sourceIdx)
        // After remove, target index shifts left by 1 if source was earlier.
        let adjustedTarget = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx
        ids.insert(item, at: adjustedTarget)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.agentOrder = ids
        }
        return true
    }

    private func moveToEnd(_ draggedId: String) -> Bool {
        var ids = rows.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              sourceIdx != ids.count - 1 else { return false }
        let item = ids.remove(at: sourceIdx)
        ids.append(item)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.agentOrder = ids
        }
        return true
    }
}

private struct AgentRow: View {
    let template: AgentTemplate
    let visible: Bool
    let isDragging: Bool
    let isExpanded: Bool
    let isCustom: Bool
    @Binding var options: String
    /// Title binding — only consulted when `isCustom` so the user can rename
    /// their custom agent inline. Bound to a no-op for builtin rows.
    @Binding var title: String
    /// Launch-command binding — same scoping rule as `title`.
    @Binding var command: String
    /// `baseAgentId` binding — same scoping rule as `title`/`command`. Empty
    /// string = no base (generic icon + no wrapper inheritance).
    @Binding var baseAgentId: String
    /// Env-block binding (`.env` syntax) — same scoping rule as `title`;
    /// additionally only shown for Claude-Code-based customs.
    @Binding var env: String
    /// Stored icon name — same scoping rule as `title`. Written by
    /// `onChooseIcon` (via `AgentIconStore`), cleared to fall back to the
    /// "based on" agent's mark.
    @Binding var iconAsset: String
    let onToggleVisible: () -> Void
    let onToggleExpanded: () -> Void
    let onChooseIcon: () -> Void
    let onBeginDrag: () -> Void
    let onDrop: (String) -> Bool
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ReorderHandle(payload: template.id, onBeginDrag: onBeginDrag)
                AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 14)
                    .opacity(visible ? 1.0 : 0.35)
                Text(template.title)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
                Spacer(minLength: 14)
                disclosureButton
                Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(ReorderDropZone(row: template.id, isDragging: isDragging, decode: { $0 }, onDrop: onDrop))
            if isExpanded { expandedForm }
        }
        .opacity(isDragging ? 0.35 : 1.0)
    }

    private var disclosureButton: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted.opacity(isExpanded ? 1.0 : 0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Indent the expansion sub-row so it visually hangs under the agent
    /// name. Approximates `row hpad + handle + spacing + icon` from the
    /// HStack above; a magic-but-named constant keeps the layout legible
    /// without reaching for `.alignmentGuide`.
    private static let optionsRowIndent: CGFloat = 56

    @ViewBuilder
    private var expandedForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCustom {
                basedOnRow
                iconRow
                editRow(label: "title", placeholder: "My Agent", text: $title)
                if baseAgentId.isEmpty {
                    editRow(label: "command", placeholder: "aichat --model gpt-4", text: $command)
                }
                if baseAgentId == AgentTemplate.claudeCodeID {
                    editRow(
                        label: "env",
                        placeholder: "ANTHROPIC_BASE_URL=https://...\nANTHROPIC_AUTH_TOKEN=sk-...",
                        text: $env,
                        axis: .vertical
                    )
                }
            }
            editRow(label: "options", placeholder: "--model opus", text: $options)
            if isCustom {
                HStack {
                    Spacer()
                    if let onDelete {
                        Button(String(localized: "delete", bundle: .kookyResources), action: onDelete)
                            .buttonStyle(.plain)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.activityFailure.opacity(0.85))
                            .underline()
                    }
                }
                .padding(.leading, Self.optionsRowIndent)
                .padding(.trailing, 22)
                .padding(.top, 4)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 12)
        .id(template.id)
    }

    /// "based on" picker — inherits icon / tint / wrapper / launch binary
    /// from the chosen builtin. Empty = generic SF Symbol fallback,
    /// no wrapper-fired lifecycle, `command` field required.
    /// Switching to a non-empty base clears `command` so a stale override
    /// can't silently win over the base's binary.
    private var basedOnRow: some View {
        HStack(spacing: 10) {
            Text(String(localized: "based on", bundle: .kookyResources))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
            Picker("", selection: $baseAgentId) {
                Text(String(localized: "(none)", bundle: .kookyResources)).tag("")
                Divider()
                ForEach(AgentTemplate.builtin.filter { !$0.isShell }) { template in
                    Text(template.title).tag(template.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 160)
            .onChange(of: baseAgentId) { _, new in
                if !new.isEmpty { command = "" }
            }
        }
        .padding(.leading, Self.optionsRowIndent)
        .padding(.trailing, 22)
    }

    /// "icon" row — import a logo for this agent, or clear back to the
    /// "based on" agent's mark. The preview reads `template.iconAsset` rather
    /// than the `$iconAsset` binding so it shows what actually renders in the
    /// tab bar: an empty binding means "inherit", which only `fromCustom`
    /// resolves.
    private var iconRow: some View {
        HStack(spacing: 10) {
            Text(String(localized: "icon", bundle: .kookyResources))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
            AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 18)
                .frame(width: 26, height: 26)
                .bracketBorder()
            // Padding and border go INSIDE the label: applied to the Button
            // they enlarge its layout frame without extending the hit region,
            // so the drawn border would ring a dead zone (~56% of the visible
            // box). Matches `+ add custom agent` above.
            Button(action: onChooseIcon) {
                Text(String(localized: "choose…", bundle: .kookyResources))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .bracketBorder()
            }
            .buttonStyle(.plain)
            if !iconAsset.isEmpty {
                // Clearing only drops the reference; `save()`'s prune deletes
                // the file once no agent names it.
                Button(String(localized: "clear", bundle: .kookyResources)) { iconAsset = "" }
                    .buttonStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .underline()
            }
            Spacer(minLength: 8)
            Text(String.localizedStringWithFormat(
                String(
                    localized: "png · jpg · svg — %d×%d or larger",
                    bundle: .kookyResources
                ),
                AgentIconStore.recommendedDimension,
                AgentIconStore.recommendedDimension
            ))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.chromeMuted.opacity(0.7))
        }
        .padding(.leading, Self.optionsRowIndent)
        .padding(.trailing, 22)
    }

    private func editRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        axis: Axis = .horizontal
    ) -> some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: 10) {
            Text(LocalizedStringKey(label), bundle: .kookyResources)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
                // drop the label to the multi-line field's first text line
                .padding(.top, axis == .vertical ? 6 : 0)
            Group {
                if axis == .vertical {
                    TextField(
                        String(
                            localized: String.LocalizationValue(placeholder),
                            bundle: .kookyResources
                        ),
                        text: text,
                        axis: .vertical
                    )
                    .lineLimit(3...12)
                } else {
                    TextField(
                        String(
                            localized: String.LocalizationValue(placeholder),
                            bundle: .kookyResources
                        ),
                        text: text
                    )
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .bracketBorder()
        }
        .padding(.leading, Self.optionsRowIndent)
        .padding(.trailing, 22)
    }

}

/// Singleton NSWindowController so reopening Settings reuses the same window
/// (preserves position, doesn't stack). `show(storeProvider:)` is the only
/// entry point; the provider resolves the *current* active window's store
/// each time "Open in New Tab" runs — a captured store would dangle once
/// its window closed.
@MainActor
final class KookySettingsWindowController: NSWindowController {
    static let shared = KookySettingsWindowController()
    private let model = KookySettingsModel.shared
    private var storeProvider: (() -> WorkspaceStore?)?
    private var host: NSHostingController<KookySettingsView>?

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(storeProvider: @escaping () -> WorkspaceStore?) {
        let controller = shared
        controller.storeProvider = storeProvider
        controller.buildWindowIfNeeded()
        controller.model.load()
        if controller.window?.isVisible != true {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let view = KookySettingsView(model: model) { [weak self] in
            self?.openSettingsInNewTab()
        }
        let host = NSHostingController(rootView: view)
        self.host = host
        let window = NSWindow(contentViewController: host)
        window.title = String(localized: "Settings", bundle: .kookyResources)
        // Keep the title set (Window menu / accessibility) but hide the text in
        // the bar, matching the main window + About + the floating panels.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 680, height: 460))
        window.isReleasedWhenClosed = false
        window.appearance = Theme.windowAppearance
        // Glass runs edge to edge under a transparent full-size titlebar;
        // content keeps its safe-area inset, so rows still sit below the bar.
        window.configureGlassChrome()
        self.window = window
    }

    /// Settings-owned open panels always attach to the Settings window, not
    /// whichever unrelated auxiliary window happens to be globally key when
    /// the action runs. The modal fallback only covers tests or a future
    /// programmatic call before the Settings window has been built.
    func present(_ panel: NSOpenPanel, onAccept: @escaping (URL) -> Void) {
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { onAccept(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            onAccept(url)
        }
    }

    /// Opens `~/.kooky/settings.json` in a new kooky tab via `$EDITOR`
    /// (defaulting to `vi`). Falls back to the system default editor (via
    /// NSWorkspace) when no active workspace exists.
    private func openSettingsInNewTab() {
        // Ensure the file exists so the editor lands in a real document.
        if !FileManager.default.fileExists(atPath: KookySettings.url.path) {
            KookySettings.writeDefaultTemplate()
        }
        guard let store = storeProvider?(), let workspace = store.active else {
            NSWorkspace.shared.open(KookySettings.url)
            return
        }
        // KOOKY_AGENT is auto-evaluated by the wrapper rcfile; shell expands
        // `${EDITOR:-vi}` at runtime, so the user's chosen editor wins.
        let template = AgentTemplate(
            id: "kooky-settings-editor",
            title: "settings.json",
            symbol: "doc.text",
            iconAsset: nil,
            tintHex: nil,
            initialCommand: "${EDITOR:-vi} \(KookyShellIntegration.quote(KookySettings.url.path))"
        )
        let session = store.addTab(in: workspace, template: template)
        session.customTitle = "settings.json"
        window?.orderOut(nil)
    }
}

private struct TerminalPresetsList: View {
    @Bindable var model: KookySettingsModel
    @State private var draggingId: String?
    @State private var endTargeted: Bool = false
    @State private var expandedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.terminalPresets.enumerated()), id: \.element.id) { index, preset in
                if index > 0 { SettingsHairline() }
                TerminalPresetRow(
                    id: preset.id,
                    visible: !model.hiddenPresets.contains(preset.id),
                    isDragging: draggingId == preset.id,
                    isExpanded: expandedId == preset.id,
                    title: titleBinding(id: preset.id),
                    path: pathBinding(id: preset.id),
                    onToggleVisible: { toggleVisible(preset.id) },
                    onToggleExpanded: {
                        expandedId = expandedId == preset.id ? nil : preset.id
                    },
                    onChooseFolder: { chooseFolder(forPresetId: preset.id) },
                    onDelete: { model.deleteTerminalPreset(id: preset.id) },
                    onBeginDrag: { draggingId = preset.id },
                    onDrop: { droppedId in
                        defer { draggingId = nil }
                        return reorder(draggedId: droppedId, before: preset.id)
                    }
                )
            }
            // Trailing drop catcher — drop past the last row to send the
            // preset to the bottom of the list. Without this, the bottom
            // slot is only reachable by dropping ON the last row (which
            // means "before it"), which reads wrong.
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingId = nil }
                    guard let id = items.first else { return false }
                    return moveToEnd(id)
                } isTargeted: { endTargeted = $0 }
            HStack {
                Button {
                    // Auto-expand the freshly-added preset so the user
                    // doesn't have to chase the disclosure chevron.
                    // Matches `AgentReorderList`'s "+ add custom agent".
                    let priorId = model.terminalPresets.last?.id
                    model.addTerminalPreset()
                    if let newId = model.terminalPresets.last?.id, newId != priorId {
                        expandedId = newId
                    }
                } label: {
                    Text(String(localized: "+ add terminal preset", bundle: .kookyResources))
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .bracketBorder()
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, model.terminalPresets.isEmpty ? 6 : 14)

            if model.terminalPresets.isEmpty {
                Text(String(localized: "Each preset becomes a Terminal entry in the + menu that always spawns in the configured folder, regardless of the active workspace.", bundle: .kookyResources))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
            }
        }
    }

    /// Resolves bindings by id (not by index) so a deletion that shifts
    /// indices doesn't leave a row writing into the wrong preset.
    private func titleBinding(id: String) -> Binding<String> {
        Binding(
            get: { model.terminalPresets.first(where: { $0.id == id })?.title ?? "" },
            set: { newValue in
                guard let idx = model.terminalPresets.firstIndex(where: { $0.id == id }) else { return }
                model.terminalPresets[idx].title = newValue
            }
        )
    }

    private func pathBinding(id: String) -> Binding<String> {
        Binding(
            get: { model.terminalPresets.first(where: { $0.id == id })?.path ?? "" },
            set: { newValue in
                guard let idx = model.terminalPresets.firstIndex(where: { $0.id == id }) else { return }
                model.terminalPresets[idx].path = newValue
            }
        )
    }

    /// Opens NSOpenPanel as a sheet on the Settings window. Sheet-modal
    /// blocks edits to the underlying view, so resolving the preset by id
    /// in the completion handler is race-free.
    private func chooseFolder(forPresetId id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder for this terminal preset.", bundle: .kookyResources)
        let assign: (URL) -> Void = { url in
            // Resolve by id so a concurrent deletion (or a parallel
            // Settings window mutating the same singleton) doesn't write
            // into the wrong row. Stored with `~` for HOME so the preset
            // survives a `$HOME` move.
            guard let idx = model.terminalPresets.firstIndex(where: { $0.id == id }) else { return }
            model.terminalPresets[idx].path = (url.path as NSString).abbreviatingWithTildeInPath
        }
        KookySettingsWindowController.shared.present(panel, onAccept: assign)
    }

    private func toggleVisible(_ id: String) {
        if model.hiddenPresets.contains(id) {
            model.hiddenPresets.remove(id)
        } else {
            model.hiddenPresets.insert(id)
        }
    }

    /// Reorder by moving `draggedId` to just before `targetId`. Same shift-
    /// adjust as `AgentReorderList.reorder` — removing from a position earlier
    /// than the target shifts every later index left by one.
    private func reorder(draggedId: String, before targetId: String) -> Bool {
        let ids = model.terminalPresets.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedId),
              let targetIdx = ids.firstIndex(of: targetId),
              sourceIdx != targetIdx else { return false }
        var presets = model.terminalPresets
        let item = presets.remove(at: sourceIdx)
        let adjustedTarget = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx
        presets.insert(item, at: adjustedTarget)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.terminalPresets = presets
        }
        return true
    }

    private func moveToEnd(_ draggedId: String) -> Bool {
        guard let sourceIdx = model.terminalPresets.firstIndex(where: { $0.id == draggedId }),
              sourceIdx != model.terminalPresets.count - 1 else { return false }
        var presets = model.terminalPresets
        let item = presets.remove(at: sourceIdx)
        presets.append(item)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.terminalPresets = presets
        }
        return true
    }
}

private struct TerminalPresetRow: View {
    let id: String
    let visible: Bool
    let isDragging: Bool
    let isExpanded: Bool
    @Binding var title: String
    @Binding var path: String
    let onToggleVisible: () -> Void
    let onToggleExpanded: () -> Void
    let onChooseFolder: () -> Void
    let onDelete: () -> Void
    let onBeginDrag: () -> Void
    let onDrop: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ReorderHandle(payload: id, onBeginDrag: onBeginDrag)
                AgentIconView(
                    asset: AgentTemplate.terminal.iconAsset,
                    fallbackSymbol: AgentTemplate.terminal.symbol,
                    size: 14
                )
                .opacity(visible ? 1.0 : 0.35)
                Text(displayTitle)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
                Spacer(minLength: 14)
                disclosureButton
                Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(ReorderDropZone(row: id, isDragging: isDragging, decode: { $0 }, onDrop: onDrop))
            if isExpanded { expandedForm }
        }
        .opacity(isDragging ? 0.35 : 1.0)
    }

    private var displayTitle: String {
        TerminalPreset(id: id, title: title, path: path).displayTitle
    }

    private var disclosureButton: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted.opacity(isExpanded ? 1.0 : 0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Indent the expansion sub-rows so they visually hang under the row
    /// title, matching `AgentRow.optionsRowIndent`.
    private static let editRowIndent: CGFloat = 56

    private var expandedForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            editRow(label: "name", placeholder: "Work", text: $title)
            HStack(alignment: .center, spacing: 10) {
                Text(String(localized: "path", bundle: .kookyResources))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .frame(width: 50, alignment: .leading)
                TextField("~/projects/foo", text: $path)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .bracketBorder()
                // Padding inside the label — see the note on the icon row's
                // `choose…` button; outside the Button it draws a border
                // around a dead click zone.
                Button(action: onChooseFolder) {
                    Text(String(localized: "choose", bundle: .kookyResources))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .bracketBorder()
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, Self.editRowIndent)
            .padding(.trailing, 22)
            HStack {
                Spacer()
                Button(String(localized: "delete", bundle: .kookyResources), action: onDelete)
                    .buttonStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.activityFailure.opacity(0.85))
                    .underline()
            }
            .padding(.leading, Self.editRowIndent)
            .padding(.trailing, 22)
            .padding(.top, 4)
        }
        .padding(.bottom, 12)
    }

    private func editRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(LocalizedStringKey(label), bundle: .kookyResources)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 50, alignment: .leading)
            TextField(
                String(
                    localized: String.LocalizationValue(placeholder),
                    bundle: .kookyResources
                ),
                text: text
            )
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .bracketBorder()
        }
        .padding(.leading, Self.editRowIndent)
        .padding(.trailing, 22)
    }

}

private struct StatusBarReorderList: View {
    @Bindable var model: KookySettingsModel
    @State private var draggingItem: StatusBarItemKind?
    @State private var endTargeted: Bool = false

    /// Items that participate in drag-reorder + right-side FlowLayout
    /// rendering. Excludes `.toolCallActivity` because its visual position
    /// is hardcoded (leftmost in the bar) and reordering wouldn't change
    /// anything visible. It still appears in the list under the "claude
    /// code" section, but without a drag handle.
    private var reorderableItems: [StatusBarItemKind] {
        model.statusBarItems.filter { !$0.isHardcodedSlot }
    }

    /// Builtin agents that report account usage (Codex). Their section shows a
    /// usage-gauge toggle.
    private var usageAgentIds: Set<String> { [AgentTemplate.codex.id] }

    /// Builtin agents with any status-bar feature (tool-call activity and/or a
    /// usage gauge), in builtin order — so the per-agent sections read
    /// Claude Code → Codex → Pi. Each renders one section (header + the
    /// feature toggles that apply to it); a future agent slots in by its
    /// builtin position automatically.
    private var statusAgents: [AgentTemplate] {
        AgentTemplate.builtin.filter { $0.reportsToolCalls || usageAgentIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Environment")
            ForEach(Array(reorderableItems.enumerated()), id: \.element) { index, item in
                if index > 0 { SettingsHairline() }
                StatusBarRow(
                    item: item,
                    visible: !model.hiddenStatusBarItems.contains(item),
                    isDragging: draggingItem == item,
                    reorderable: true,
                    onToggleVisible: { toggleVisible(item) },
                    onBeginDrag: { draggingItem = item },
                    onDrop: { droppedItem in
                        defer { draggingItem = nil }
                        return reorder(draggedItem: droppedItem, before: item)
                    }
                )
            }
            // One section per agent (header = icon + name), grouped by agent,
            // not by feature. Each agent's section shows the toggles for the
            // status-bar features it supports — tool-call pill and/or usage
            // gauge. Ordered Claude Code → Codex → Pi via `statusAgents`.
            ForEach(statusAgents) { agent in
                SettingsHairline()
                sectionHeader(agent.title, agentAsset: agent.iconAsset)
                if agent.reportsToolCalls {
                    StatusBarRow(
                        item: .toolCallActivity,
                        visible: !model.hiddenToolCallAgents.contains(agent.id),
                        isDragging: false,
                        reorderable: false,
                        onToggleVisible: { model.hiddenToolCallAgents.formSymmetricDifference([agent.id]) },
                        onBeginDrag: nil,
                        onDrop: nil
                    )
                }
                if usageAgentIds.contains(agent.id) {
                    StatusBarRow(
                        item: .codexUsage,
                        visible: !model.hiddenUsageAgents.contains(agent.id),
                        isDragging: false,
                        reorderable: false,
                        onToggleVisible: { model.hiddenUsageAgents.formSymmetricDifference([agent.id]) },
                        onBeginDrag: nil,
                        onDrop: nil
                    )
                }
            }
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingItem = nil }
                    guard let raw = items.first,
                          let dropped = StatusBarItemKind(rawValue: raw),
                          !dropped.isHardcodedSlot
                    else { return false }
                    return moveToEnd(dropped)
                } isTargeted: { endTargeted = $0 }

            HStack {
                Spacer()
                if hasCustomisation {
                    Button(String(localized: "reset to defaults", bundle: .kookyResources)) { model.resetStatusBar() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .underline()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
        }
    }

    /// Brutalist mono section heading. `agentAsset`, when set, prepends
    /// the agent's iconAsset (e.g. `AgentTemplate.claudeCode.iconAsset`
    /// → the AgentIconView's rendered Claude mark) so a section belonging
    /// to a specific agent reads at a glance without a wall of text.
    private func sectionHeader(_ text: String, agentAsset: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let agentAsset {
                AgentIconView(asset: agentAsset, fallbackSymbol: "sparkles", size: 16)
            }
            Text(LocalizedStringKey(text), bundle: .kookyResources)
                .font(Theme.mono(12, weight: .medium))
                .foregroundStyle(Theme.chromeMuted)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var hasCustomisation: Bool {
        model.statusBarItems != StatusBarItemKind.defaultOrder
            || !model.hiddenStatusBarItems.isEmpty
            || !model.hiddenToolCallAgents.isEmpty
            || !model.hiddenUsageAgents.isEmpty
    }

    private func toggleVisible(_ item: StatusBarItemKind) {
        if model.hiddenStatusBarItems.contains(item) {
            model.hiddenStatusBarItems.remove(item)
        } else {
            model.hiddenStatusBarItems.insert(item)
        }
    }


    private func reorder(draggedItem: StatusBarItemKind, before target: StatusBarItemKind) -> Bool {
        var order = model.statusBarItems
        guard let src = order.firstIndex(of: draggedItem),
              let dst = order.firstIndex(of: target),
              src != dst else { return false }
        let moved = order.remove(at: src)
        let adjusted = src < dst ? dst - 1 : dst
        order.insert(moved, at: adjusted)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.statusBarItems = order
        }
        return true
    }

    private func moveToEnd(_ item: StatusBarItemKind) -> Bool {
        var order = model.statusBarItems
        guard let src = order.firstIndex(of: item), src != order.count - 1 else { return false }
        let moved = order.remove(at: src)
        order.append(moved)
        withAnimation(.easeInOut(duration: 0.18)) {
            model.statusBarItems = order
        }
        return true
    }
}

private struct StatusBarRow: View {
    let item: StatusBarItemKind
    let visible: Bool
    let isDragging: Bool
    /// When `false` the drag handle is replaced by an invisible spacer
    /// (matching `ReorderHandle`'s 22pt frame so the icon column stays
    /// aligned) and the row no longer hosts a `ReorderDropZone`. Used by
    /// the `.toolCallActivity` row whose position is hardcoded in the bar.
    let reorderable: Bool
    let onToggleVisible: () -> Void
    let onBeginDrag: (() -> Void)?
    let onDrop: ((StatusBarItemKind) -> Bool)?

    var body: some View {
        HStack(spacing: 12) {
            if reorderable, let onBeginDrag {
                ReorderHandle(payload: item.rawValue, onBeginDrag: onBeginDrag)
            }
            // No else — non-reorderable rows skip the handle column
            // entirely and the label hugs the row's left edge. Their
            // visual alignment matches the section header above (both
            // start 22pt in from the panel edge via the row padding).
            if let symbol = item.symbol {
                // Kinds with their own SF Symbol surface it here (Python
                // venv "p.circle.fill" etc.). `.toolCallActivity` returns
                // nil — its visual identity comes from the tool-call section
                // header's agent marks (Claude + Pi) rather than a per-row glyph.
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
                    .frame(width: 14)
                    .opacity(visible ? 1.0 : 0.4)
            }
            Text(item.displayName)
                .font(Theme.mono(12.5))
                .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
            Spacer(minLength: 14)
            Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(reorderableBackground)
        .opacity(isDragging ? 0.35 : 1.0)
    }

    @ViewBuilder
    private var reorderableBackground: some View {
        if reorderable, let onDrop {
            ReorderDropZone(row: item, isDragging: isDragging,
                            decode: StatusBarItemKind.init(rawValue:),
                            onDrop: onDrop)
        } else {
            EmptyView()
        }
    }
}

/// Settings → General → Open With. Chooses the applications terminal links
/// use. Installed
/// apps are resolved on every appearance so installing an editor / browser
/// while kooky is running is reflected the next time Settings opens.
private struct OpenWithPreferences: View {
    @Bindable var model: KookySettingsModel
    @State private var refreshTick = 0

    private var fileApps: [OpenInApp] {
        OpenInResolver.installedFileLinkApps()
    }

    private var browserApps: [OpenInApp] {
        OpenInResolver.installedBrowserLinkApps()
    }

    var body: some View {
        let _ = refreshTick
        return SettingsSection(title: "Open With") {
            SettingsRow(label: "file-links") {
                appPicker(selection: $model.fileLinkAppId, apps: fileApps)
            }
            SettingsHairline()
            SettingsRow(label: "web-links") {
                appPicker(selection: $model.webLinkAppId, apps: browserApps)
            }
        }
        .onAppear {
            OpenInResolver.invalidate()
            refreshTick += 1
        }
    }

    private func appPicker(
        selection: Binding<String?>,
        apps: [OpenInApp]
    ) -> some View {
        Picker("", selection: selection) {
            Text(String(localized: "System Default", bundle: .kookyResources)).tag(String?.none)
            if !apps.isEmpty {
                Divider()
                ForEach(apps) { app in
                    HStack(spacing: 7) {
                        OpenInAppIcon(app: app, size: 14)
                        Text(app.title)
                    }
                    .tag(String?.some(app.id))
                }
            }
            if let selected = selection.wrappedValue,
               !apps.contains(where: { $0.id == selected }) {
                Divider()
                Text(String.localizedStringWithFormat(
                    String(localized: "Unavailable (%@)", bundle: .kookyResources),
                    selected
                ))
                .tag(String?.some(selected))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 180, alignment: .trailing)
    }
}

/// Settings → Open in. Lists the catalog apps installed on this Mac (Finder
/// always present) with a visibility toggle + drag-reorder; the order + hidden
/// set drive the top-chrome split button's picker. Uninstalled catalog apps
/// are omitted — there's nothing to toggle. Mirrors `StatusBarReorderList`.
private struct OpenInReorderList: View {
    @Bindable var model: KookySettingsModel
    @State private var draggingId: String?
    @State private var endTargeted = false
    /// Bumped in `onAppear` after invalidating the resolver cache, to force
    /// `apps` to re-resolve this appearance (cache-clear alone isn't an
    /// observable change). See `onAppear` below.
    @State private var refreshTick = 0

    private var apps: [OpenInApp] {
        OpenInResolver.installedApps(model: model)
    }

    var body: some View {
        // Reading `refreshTick` registers the dependency so its onAppear bump
        // (below) invalidates this body and re-resolves `apps` against the
        // freshly-cleared resolver cache.
        let _ = refreshTick
        return VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Apps installed on this Mac. The top-bar button opens the current tab's folder in your last-used one.", bundle: .kookyResources))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)

            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { SettingsHairline() }
                OpenInRow(
                    app: app,
                    visible: !model.hiddenOpenInApps.contains(app.id),
                    isDragging: draggingId == app.id,
                    onToggleVisible: { toggleVisible(app.id) },
                    onBeginDrag: { draggingId = app.id },
                    onDrop: { droppedId in
                        defer { draggingId = nil }
                        return reorder(draggedId: droppedId, before: app.id)
                    }
                )
            }

            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .dropIndicator(active: endTargeted, on: .top, offset: 4)
                .dropDestination(for: String.self) { items, _ in
                    defer { draggingId = nil }
                    guard let id = items.first else { return false }
                    return moveToEnd(id)
                } isTargeted: { endTargeted = $0 }

            HStack {
                Spacer()
                if hasCustomisation {
                    Button(String(localized: "reset to defaults", bundle: .kookyResources)) { model.resetOpenIn() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .underline()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
        }
        // Drop any stale install/uninstall cache the top-bar button populated
        // during this session, then bump `refreshTick` so the list re-resolves
        // `apps` against the cleared cache on this same appearance — clearing
        // the cache isn't observable, so without the bump a newly-installed app
        // wouldn't show (or an uninstalled one wouldn't drop) until an unrelated
        // re-render.
        .onAppear {
            OpenInResolver.invalidate()
            refreshTick += 1
        }
    }

    private var hasCustomisation: Bool {
        !model.openInAppOrder.isEmpty || !model.hiddenOpenInApps.isEmpty
    }

    private func toggleVisible(_ id: String) {
        if model.hiddenOpenInApps.contains(id) {
            model.hiddenOpenInApps.remove(id)
        } else {
            model.hiddenOpenInApps.insert(id)
        }
    }

    /// Rewrites `openInAppOrder` to the full installed sequence after the move
    /// so the saved order is meaningful (rather than the sparse default).
    private func reorder(draggedId: String, before targetId: String) -> Bool {
        var order = apps.map(\.id)
        guard let src = order.firstIndex(of: draggedId),
              let dst = order.firstIndex(of: targetId),
              src != dst else { return false }
        let moved = order.remove(at: src)
        let adjusted = src < dst ? dst - 1 : dst
        order.insert(moved, at: adjusted)
        persistOrder(order)
        return true
    }

    private func moveToEnd(_ id: String) -> Bool {
        var order = apps.map(\.id)
        guard let src = order.firstIndex(of: id), src != order.count - 1 else { return false }
        let moved = order.remove(at: src)
        order.append(moved)
        persistOrder(order)
        return true
    }

    /// Persist a reordered *installed* sequence, keeping any previously-saved
    /// ids that aren't currently installed (appended at the tail) so an
    /// uninstall → reorder → reinstall round-trip doesn't drop that app's slot.
    private func persistOrder(_ installedOrder: [String]) {
        let installedSet = Set(installedOrder)
        let preserved = model.openInAppOrder.filter { !installedSet.contains($0) }
        withAnimation(.easeInOut(duration: 0.18)) {
            model.openInAppOrder = installedOrder + preserved
        }
    }
}

private struct OpenInRow: View {
    let app: OpenInApp
    let visible: Bool
    let isDragging: Bool
    let onToggleVisible: () -> Void
    let onBeginDrag: () -> Void
    let onDrop: (String) -> Bool

    var body: some View {
        HStack(spacing: 12) {
            ReorderHandle(payload: app.id, onBeginDrag: onBeginDrag)
            OpenInAppIcon(app: app, size: 16)
                .opacity(visible ? 1.0 : 0.4)
            Text(app.title)
                .font(Theme.mono(12.5))
                .foregroundStyle(visible ? Theme.chromeForeground : Theme.chromeMuted)
            Spacer(minLength: 14)
            Toggle("", isOn: Binding(get: { visible }, set: { _ in onToggleVisible() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(ReorderDropZone(row: app.id, isDragging: isDragging, decode: { $0 }, onDrop: onDrop))
        .opacity(isDragging ? 0.35 : 1.0)
    }
}
