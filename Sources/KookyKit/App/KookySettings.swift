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
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kooky", isDirectory: true)

    static let url: URL = directory.appendingPathComponent("settings.json")

    /// Initial `settings.json` written on first launch when the user has no
    /// existing ghostty config to import. Everything is commented out so the
    /// file reads as a discoverable template instead of a thicket of
    /// overrides; uncomment to opt in.
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

      // === Terminal rendering (forwarded to libghostty) ===
      // ghostty key reference: https://ghostty.org/docs/config/reference
      "terminal": {
        // "font-family": "JetBrains Mono",
        // "font-size": 13,
        // "theme": "dracula",
        // "background-opacity": 0.85,
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
    static func apply(parsed: [String: Any]?, to config: ghostty_config_t?) {
        guard let config,
              let parsed,
              let terminal = parsed["terminal"] as? [String: Any],
              !terminal.isEmpty else { return }
        var lines: [String] = []
        if let rawTheme = terminal["theme"] as? String {
            if let preset = KookyTerminalTheme.preset(for: rawTheme) {
                lines.append(contentsOf: preset.lines)
            } else if !rawTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Raw JSON users can still point at a custom Ghostty theme
                // path or name. The Settings UI only writes bundled preset ids.
                lines.append(contentsOf: formatGhosttyLines(key: "theme", value: rawTheme))
            }
        }
        for key in terminal.keys.sorted() where key != "theme" {
            if let value = terminal[key] {
                lines.append(contentsOf: formatGhosttyLines(key: key, value: value))
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

    /// Builds the full libghostty configuration used at app start and for
    /// runtime reloads. Keep this as the single source for precedence:
    /// ghostty defaults -> kooky baselines -> ~/.kooky/settings.json.
    /// Pass `parsed` when the caller already loaded settings.json (e.g.
    /// `LibghosttyApp.reloadConfig` building one config per surface) to
    /// avoid re-reading the file N times.
    static func makeGhosttyConfig(parsed: [String: Any]? = nil) -> ghostty_config_t? {
        let config = ghostty_config_new()
        guard config != nil else { return nil }
        ghostty_config_load_default_files(config)
        applyBaseline(to: config)
        apply(parsed: parsed ?? loadParsed(), to: config)
        ghostty_config_finalize(config)
        return config
    }

    private static func applyBaseline(to config: ghostty_config_t?) {
        guard let config else { return }
        // Click anywhere on the current zsh / bash prompt to jump the shell
        // cursor there. The shell wrapper emits OSC 133 prompt markers with
        // the `cl=line` metadata libghostty needs to recognise it.
        let baseline = "cursor-click-to-move = true\n"
        baseline.withCString { cstr in
            "kooky-baseline".withCString { source in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)), source)
            }
        }
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
