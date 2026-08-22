import AppKit
import Foundation
import GhosttyKit

/// Reads `~/.kooky/settings.json` and forwards its `terminal.*` section to
/// libghostty. JSONC-tolerant (line + block comments stripped before parse).
///
/// The schema has two layers:
///   - kooky-specific keys (`agent`, `sidebar`, `tab`, …) — parsed by kooky,
///     currently mostly template placeholders until each is individually wired
///   - `terminal.*` — flattened to ghostty's key=value format and pushed via
///     `ghostty_config_load_string`, so the user's keys ride on top of ghostty's
///     own `~/.config/ghostty/config` defaults (last write wins).
enum KookySettings {
    static let pairedThemeSchemaVersion = 2

    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kooky", isDirectory: true)

    static let url: URL = directory.appendingPathComponent("settings.json")

    /// Initial `settings.json` written on first launch when the user has no
    /// existing ghostty config to import. The appearance block is the one
    /// active default: its schema marker distinguishes a new install from an
    /// upgraded legacy "Default" user who must keep inheriting Ghostty.
    /// Everything else stays commented out until the user opts in.
    static let defaultTemplate: String = """
    // kooky settings
    // Docs: https://github.com/iAmCorey/kooky#configuration
    // Uncomment a line to override the default.
    {
      // === kooky-specific ===
      // "agents": {
      //   "default": "claude"
      // },
      // "ssh": {
      //   "remoteAgentDetection": true
      // },
      // "sidebar": {
      //   "mode": "full"
      // },
      "appearance": {
        "themeSchemaVersion": 2,
        "mode": "system",
        "lightTheme": "\(KookyTerminalTheme.defaultLightStoredValue)",
        "darkTheme": "\(KookyTerminalTheme.defaultDarkStoredValue)"
      },

      // === Terminal rendering (forwarded to libghostty) ===
      // ghostty key reference: https://ghostty.org/docs/config/reference
      "terminal": {
        // "font-family": "JetBrains Mono",
        // "font-size": 13,
        // "background-opacity": 0.85,
        // macOS 26+: "macos-glass-regular" | "macos-glass-clear" for Liquid Glass
        // "background-blur": "macos-glass-regular"
      }
    }
    """

    /// Parses settings.json into a dictionary, or nil if the file is missing
    /// or unparseable. `.json5Allowed` accepts `//` and `/* */` comments
    /// natively (macOS 12+, kooky's floor is 14). Logs but doesn't surface
    /// UI errors — kooky still launches with libghostty defaults.
    static func loadParsed() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) else {
            NSLog("kooky: settings.json parse failed")
            return nil
        }
        return obj as? [String: Any]
    }

    /// Translates the `terminal.*` subdict to ghostty's flat key=value format
    /// and pushes via `ghostty_config_load_string`. Called after
    /// `ghostty_config_load_default_files` so user's kooky-side keys win over
    /// anything in `~/.config/ghostty/config`. Theme lines emit first; any
    /// user-set `terminal.cursor-color` / `background` / `palette` override
    /// per ghostty last-write-wins.
    @MainActor
    static func apply(parsed: [String: Any]?, to config: ghostty_config_t?) {
        guard let config,
              let parsed else { return }
        let terminal = parsed["terminal"] as? [String: Any] ?? [:]
        var lines: [String] = []
        if let rawTheme = effectiveThemeValue(
            parsed: parsed,
            systemIsDark: KookySettingsModel.shared.systemAppearanceIsDark
        ) {
            if let theme = KookyTerminalTheme.theme(
                for: rawTheme,
                in: KookyTerminalTheme.availableThemes()
            ) {
                // Scanned user themes keep their original lines so selection colors and
                // other theme settings are applied directly; unknown names stay delegated
                // to Ghostty's own theme lookup below.
                if theme.isBundled || !theme.lines.isEmpty {
                    lines.append(contentsOf: theme.lines)
                } else {
                    lines.append(contentsOf: formatGhosttyLines(key: "theme", value: theme.storedValue))
                }
            } else if !rawTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Raw JSON users can still point at a custom Ghostty theme
                // path or name. Namespaced bundled values are handled above.
                lines.append(contentsOf: formatGhosttyLines(key: "theme", value: rawTheme))
            }
        }
        for key in terminal.keys.sorted() where key != "theme" {
            if let value = terminal[key] {
                lines.append(contentsOf: formatGhosttyLines(key: key, value: value))
            }
        }
        // Derive the terminal surface opacity from the glass blur when the user
        // set no explicit `background-opacity`, so every path behaves the same
        // (the Settings dropdown, hand-edited settings.json, and inherited
        // ghostty config): a glass style needs a see-through terminal for the
        // glass to read through, while kooky's "off" (`false`) forces it fully
        // opaque — otherwise an inherited ghostty `background-opacity` would
        // leave the terminal see-through with the glass gone.
        if terminal["background-opacity"] == nil, let blur = blurString(from: terminal["background-blur"]) {
            if isGlassBlur(blur) {
                lines.append("background-opacity = \(Theme.defaultGlassOpacity)")
            } else if isBlurExplicitlyOff(blur) {
                lines.append("background-opacity = 1")
            }
            // A ghostty-native numeric blur — leave opacity alone.
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        text.withCString { cstr in
            "kooky-settings".withCString { sourceName in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)), sourceName)
            }
        }
    }

    /// Resolves the palette kooky should inject into libghostty. Kept pure so
    /// schema precedence and system/light/dark behavior can be pinned in unit
    /// tests without consulting the process's real macOS appearance.
    static func effectiveThemeValue(
        parsed: [String: Any]?,
        systemIsDark: Bool
    ) -> String? {
        let terminal = parsed?["terminal"] as? [String: Any] ?? [:]
        let appearance = parsed?["appearance"] as? [String: Any] ?? [:]

        if hasPairedThemeSchema(appearance) {
            let mode = (appearance["mode"] as? String)
                .flatMap(KookyAppearanceMode.init(rawValue:))
                ?? .system
            let isDark = mode.resolvesDark(systemIsDark: systemIsDark)
            let key = isDark ? "darkTheme" : "lightTheme"
            let fallback = isDark
                ? KookyTerminalTheme.defaultDarkStoredValue
                : KookyTerminalTheme.defaultLightStoredValue
            let raw = (appearance[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : fallback
        }

        // Legacy configurations stay byte-for-byte effective until Settings
        // performs the one-way migration into the paired appearance schema.
        let legacy = (terminal["theme"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy?.isEmpty == false ? legacy : nil
    }

    /// A version marker makes the all-default new schema distinguishable from
    /// the legacy state where no `terminal.theme` meant "inherit Ghostty".
    /// The three original paired keys remain implicit markers so settings
    /// written by prerelease builds of this feature keep working.
    static func hasPairedThemeSchema(_ appearance: [String: Any]) -> Bool {
        appearance.keys.contains("themeSchemaVersion")
            || appearance.keys.contains("mode")
            || appearance.keys.contains("lightTheme")
            || appearance.keys.contains("darkTheme")
    }

    /// Builds the full libghostty configuration used at app start and for
    /// runtime reloads. Keep this as the single source for precedence:
    /// ghostty defaults -> kooky baselines -> ~/.kooky/settings.json.
    /// Ownership: the caller owns the returned config and must keep it
    /// alive until the NEXT config replaces it, then free it — see
    /// `LibghosttyApp.currentConfig` for why freeing sooner is unsafe.
    @MainActor
    static func makeGhosttyConfig() -> ghostty_config_t? {
        let config = ghostty_config_new()
        guard config != nil else { return nil }
        ghostty_config_load_default_files(config)
        let parsed = loadParsed()
        applyBaseline(to: config, parsed: parsed)
        apply(parsed: parsed, to: config)
        ghostty_config_finalize(config)
        return config
    }

    /// Kooky's explicit ghostty overrides. Applied AFTER
    /// `ghostty_config_load_default_files` so they win over the user's own
    /// ghostty config, but BEFORE the settings.json `terminal.*` pass so each
    /// key can still be overridden from ~/.kooky/settings.json.
    /// - cursor-click-to-move: click anywhere on the current zsh / bash prompt
    ///   to jump the shell cursor there (the shell wrapper emits the OSC 133
    ///   `cl=line` markers libghostty needs).
    /// - copy-on-select: ghostty's macOS default (`true`) already reaches the
    ///   system clipboard in kooky (no selection-clipboard support declared →
    ///   libghostty degrades the write to the standard clipboard), but an
    ///   inherited `copy-on-select = false` from the user's ghostty config
    ///   silently killed select-to-copy on those machines (issue #32).
    ///   Declaring it here makes kooky's default hold for everyone.
    /// - macos-option-as-alt: an UNSET value makes libghostty guess per
    ///   keyboard layout (`detectOptionAsAlt` — US layouts default to Option
    ///   acting as Alt, ghostty.app's behavior). kooky's promised default is
    ///   macOS-native Option (special characters / IME), so pin `false`;
    ///   users opt into Alt via `terminal.macos-option-as-alt` (issue #46).
    /// - confirm-close-surface: ghostty defaults to true, but in kooky "a
    ///   process is running" includes every working agent — confirming each
    ///   ⌘W on an active Claude tab would tax kooky's core workflow. Pin
    ///   false (today's behavior); users opt into the guard via
    ///   `terminal.confirm-close-surface`.
    static let baselineConfig = "cursor-click-to-move = true\ncopy-on-select = true\n"
        + "macos-option-as-alt = false\nconfirm-close-surface = false\n"

    /// A `theme = light:…,dark:…` line pointing at two EMPTY sentinel theme
    /// files. The core's color-scheme machinery (CSI ?996n query, mode 2031
    /// reports, conditional resolution) only works when the config USES a
    /// conditional key — `changeConditionalState` short-circuits to "nothing
    /// to do" otherwise, and the termio-side scheme value (what 996 answers
    /// with) is only ever written during that rebuild. Verified: without
    /// this, `ghostty_surface_set_color_scheme` updates surface state that
    /// no report ever reads, and every query answers "light" forever. The
    /// sentinel files are deliberately empty (comments only): they change no
    /// colors — kooky's own concrete color lines load after baseline and
    /// stay the single source of the palette.
    private static let conditionalThemeLine: String? = {
        let dir = KookyShellIntegration.kookyAppSupport("themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = """
        # kooky sentinel theme — intentionally empty. Its presence switches
        # ghostty's conditional-theme machinery on so color-scheme queries
        # (CSI ?996n) and mode 2031 reports follow kooky's active theme.

        """
        let sentinel: (String) -> String? = { name in
            let path = dir.appendingPathComponent(name).path
            KookyShellIntegration.writeFile(at: path, contents: stub)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        guard let light = sentinel("conditional-light"),
              let dark = sentinel("conditional-dark") else { return nil }
        return "theme = light:\(light),dark:\(dark)\n"
    }()

    @MainActor
    private static func applyBaseline(to config: ghostty_config_t?, parsed: [String: Any]?) {
        guard let config else { return }
        var text = baselineConfig
        // The sentinel `theme` line must ONLY load when kooky itself emits the
        // final colors afterwards (paired/bundled themes, or an explicit
        // settings.json theme). In the legacy "inherit Ghostty" state
        // (effectiveThemeValue == nil, kooky writes no theme at all) a later
        // theme line REPLACES the user's own `~/.config/ghostty/config` theme
        // at finalize — the sentinel would wipe their colors to defaults
        // (Codex P1). Those users keep their theme and lose only the 996
        // color-scheme report, same as before this feature.
        if effectiveThemeValue(
            parsed: parsed,
            systemIsDark: KookySettingsModel.shared.systemAppearanceIsDark
        ) != nil, let themeLine = conditionalThemeLine {
            text += themeLine
        }
        text.withCString { cstr in
            "kooky-baseline".withCString { source in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)), source)
            }
        }
    }

    /// The `background-blur` string vocabulary, in ONE place — two sites had
    /// diverged on whether `"0"` counts as off.
    static func isGlassBlur(_ raw: String) -> Bool { raw.hasPrefix("macos-glass") }
    /// Explicit off (`"false"`/`"0"`) — nil/unset is deliberately NOT "off"
    /// (an unset value must leave inherited ghostty config behavior alone).
    static func isBlurExplicitlyOff(_ raw: String) -> Bool { raw == "false" || raw == "0" }

    /// Normalize a raw `background-blur` JSON value to its ghostty string form.
    /// Users can write it as a string (`"macos-glass-regular"`), a JSON bool
    /// (`false` = off), or an integer radius — `as? String` alone would drop
    /// the latter two to `nil`, which reads as "unset" and silently deletes the
    /// key on the next save. Coercing here keeps every form round-tripping.
    static func blurString(from value: Any?) -> String? {
        if let str = value as? String { return str }
        if let num = value as? NSNumber {
            return CFGetTypeID(num) == CFBooleanGetTypeID()
                ? (num.boolValue ? "true" : "false")
                : num.stringValue
        }
        return nil
    }

    private static func formatGhosttyLines(key: String, value: Any) -> [String] {
        if let str = value as? String {
            return ["\(key) = \(str)"]
        }
        if let num = value as? NSNumber {
            // Discriminate bool from numeric — NSNumber bridges both.
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return ["\(key) = \(num.boolValue ? "true" : "false")"]
            }
            return ["\(key) = \(num.stringValue)"]
        }
        if let arr = value as? [Any] {
            // Ghostty's multi-value keys (e.g. `keybind`) use repeated lines.
            return arr.flatMap { formatGhosttyLines(key: key, value: $0) }
        }
        return []
    }

    static func writeDefaultTemplate() {
        ensureDirectory()
        try? defaultTemplate.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `mkdir -p ~/.kooky/`. Idempotent.
    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Pretty-printed, sorted-keys, atomic write of a top-level dict to
    /// `settings.json`. Drops the write on serialization failure rather than
    /// surfacing — same behavior as `loadParsed` on the read side.
    static func write(_ object: [String: Any]) {
        ensureDirectory()
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// First-launch onboarding: when `~/.kooky/` doesn't exist, ask the user
/// whether to import their existing `~/.config/ghostty/config` (if present)
/// or start from a blank kooky template. Either way creates `settings.json`
/// so subsequent launches skip this branch.
@MainActor
enum KookyOnboarding {
    static func runIfNeeded() {
        // Gate on the settings.json file existing rather than the directory —
        // a previous run could have created `~/.kooky/` but failed to write
        // the file (disk full, perms), and skipping onboarding forever in
        // that state leaves the user with no settings at all.
        let fm = FileManager.default
        guard !fm.fileExists(atPath: KookySettings.url.path) else { return }

        let ghosttyConfig = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")

        if fm.fileExists(atPath: ghosttyConfig.path) {
            promptGhosttyImport(from: ghosttyConfig)
        } else {
            KookySettings.writeDefaultTemplate()
        }
    }

    private static func promptGhosttyImport(from path: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Welcome to kooky", bundle: .kookyResources)
        alert.informativeText = String(localized: "We found your existing ghostty configuration. Would you like to import it into kooky?\n\nYou can change settings any time via Help → Open Settings.", bundle: .kookyResources)
        alert.addButton(withTitle: String(localized: "Use ghostty settings", bundle: .kookyResources))
        alert.addButton(withTitle: String(localized: "Start fresh", bundle: .kookyResources))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            importGhosttyConfig(from: path)
        default:
            KookySettings.writeDefaultTemplate()
        }
    }

    /// Reads a ghostty flat-format config, drops comments, and writes the
    /// equivalent JSON under `terminal.*`. The source file is never modified —
    /// kooky owns its own copy after import so future ghostty edits won't leak
    /// in (and vice versa).
    private static func importGhosttyConfig(from path: URL) {
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            KookySettings.writeDefaultTemplate()
            return
        }
        var terminal: [String: Any] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            let value = parseGhosttyValue(rawValue)
            // Ghostty's `keybind` and a few other keys express multi-value
            // bindings as repeated lines — preserve them as a JSON array so
            // `formatGhosttyLines` can re-emit the repeated form.
            if var existing = terminal[key] as? [Any] {
                existing.append(value)
                terminal[key] = existing
            } else if let existing = terminal[key] {
                terminal[key] = [existing, value]
            } else {
                terminal[key] = value
            }
        }
        KookySettings.write(["terminal": terminal])
    }

    private static func parseGhosttyValue(_ raw: String) -> Any {
        var s = raw
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        if s == "true" { return true }
        if s == "false" { return false }
        return s
    }
}
