import AppKit
import Foundation
import GhosttyKit

/// Kooky's input-routing interpretation of Ghostty's `macos-option-as-alt`
/// setting. libghostty still receives the original terminal setting, but text
/// that Cocoa has already translated (for example Option+Z → Ω) no longer
/// carries its physical Option modifier. The terminal view needs this small
/// mirror to decide whether to bypass Cocoa before that translation happens.
enum KookyMacOSOptionAsAlt: Equatable {
    case disabled
    case both
    case left
    case right

    init(settingsValue: Any?) {
        if let number = settingsValue as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = number.boolValue ? .both : .disabled
            return
        }

        switch settingsValue as? String {
        case "left": self = .left
        case "right": self = .right
        default: self = .disabled
        }
    }

    func treatsAsAlt(leftOptionPressed: Bool, rightOptionPressed: Bool) -> Bool {
        switch self {
        case .disabled: return false
        case .both: return leftOptionPressed || rightOptionPressed
        case .left: return leftOptionPressed
        case .right: return rightOptionPressed
        }
    }
}

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

    /// Refreshed whenever Kooky builds the configuration passed to libghostty.
    /// `GhosttySurfaceView` reads this on the main thread before handing a
    /// regular key to Cocoa's text-input system.
    @MainActor private(set) static var activeMacOSOptionAsAlt: KookyMacOSOptionAsAlt = .disabled

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

    /// Extract the Kooky-side input-routing value from `terminal`. Invalid,
    /// missing, and unsupported values preserve native macOS character input.
    static func macOSOptionAsAlt(parsed: [String: Any]?) -> KookyMacOSOptionAsAlt {
        let terminal = parsed?["terminal"] as? [String: Any]
        return KookyMacOSOptionAsAlt(settingsValue: terminal?["macos-option-as-alt"])
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
                if theme.isBundled {
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
        if terminal["background-opacity"] == nil {
            switch blurString(from: terminal["background-blur"]) {
            case let blur? where blur.hasPrefix("macos-glass"):
                lines.append("background-opacity = \(Theme.defaultGlassOpacity)")
            case "false", "0":
                lines.append("background-opacity = 1")
            default:
                break  // unset, or a ghostty-native blur — leave opacity alone
            }
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
        let parsed = loadParsed()
        activeMacOSOptionAsAlt = macOSOptionAsAlt(parsed: parsed)
        let config = ghostty_config_new()
        guard config != nil else { return nil }
        ghostty_config_load_default_files(config)
        applyBaseline(to: config)
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
    static let baselineConfig = "cursor-click-to-move = true\ncopy-on-select = true\n"

    private static func applyBaseline(to config: ghostty_config_t?) {
        guard let config else { return }
        baselineConfig.withCString { cstr in
            "kooky-baseline".withCString { source in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)), source)
            }
        }
    }

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
        alert.messageText = "Welcome to kooky"
        alert.informativeText = "We found your existing ghostty configuration. Would you like to import it into kooky?\n\nYou can change settings any time via Help → Open Settings."
        alert.addButton(withTitle: "Use ghostty settings")
        alert.addButton(withTitle: "Start fresh")

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
