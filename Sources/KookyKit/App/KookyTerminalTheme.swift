import Foundation
import AppKit

struct KookyTerminalTheme: Identifiable, Hashable {
    static let bundledStoredValuePrefix = "kooky:"
    static let defaultLightID = "one-light"
    static let defaultDarkID = "one-dark"
    static var defaultLightStoredValue: String { bundledStoredValue(for: defaultLightID) }
    static var defaultDarkStoredValue: String { bundledStoredValue(for: defaultDarkID) }

    enum Source: Hashable {
        case bundled
        case ghosttyUser
    }

    let id: String
    let title: String
    let storedValue: String
    let backgroundHex: String
    let foregroundHex: String
    let lines: [String]
    let source: Source
    /// Absolute source path for scanned Ghostty user themes. Passing this to
    /// libghostty as the config source keeps relative path options anchored to
    /// the theme file instead of kooky's process working directory.
    let userThemeURL: URL?

    var isBundled: Bool { source == .bundled }

    /// Ghostty theme files may contain every regular config key except
    /// `theme` and `config-file`. Native theme loading ignores those two; when
    /// kooky applies a selected user theme after Ghostty's default config, it
    /// must preserve the same boundary rather than promoting them into the
    /// main config.
    var loadableLines: [String] {
        guard !isBundled else { return lines }
        return lines.filter { line in
            guard let key = Self.configKey(in: line) else { return true }
            return key != "theme" && key != "config-file"
        }
    }

    /// Light/dark split for the picker's section grouping. Uses the same
    /// luminance threshold `Theme.Resolved` applies when deciding chrome
    /// appearance, so a theme listed under "Dark" is exactly one that renders
    /// dark chrome.
    var isDark: Bool {
        (NSColor(hex: backgroundHex)?.relativeLuminance ?? 0) <= 0.55
    }

    static let presets: [KookyTerminalTheme] = loadBundledPresets()

    private static func loadBundledPresets() -> [KookyTerminalTheme] {
        guard let resourceURL = kookyResourceBundle()?.resourceURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: resourceURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls.filter { url in
            url.pathExtension.isEmpty
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parseBundledTheme(text, id: url.lastPathComponent)
        }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func parseBundledTheme(_ text: String, id: String) -> KookyTerminalTheme? {
        let values = parseGhosttyConfigLines(text)
        let palette = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "palette" else { return nil }
            let rawColor = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard let separator = rawColor.firstIndex(of: "=") else { return nil }
            return unwrapQuotes(
                String(rawColor[rawColor.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let titlePrefix = "# Kooky theme:"
        let title = firstLine.trimmingCharacters(in: .whitespaces).hasPrefix(titlePrefix)
            ? String(firstLine.trimmingCharacters(in: .whitespaces).dropFirst(titlePrefix.count))
                .trimmingCharacters(in: .whitespaces)
            : id

        guard let background = values["background"],
              let foreground = values["foreground"],
              let cursor = values["cursor-color"],
              let selectionBackground = values["selection-background"],
              let selectionForeground = values["selection-foreground"],
              palette.count == 16 else { return nil }
        return KookyTerminalTheme(
            id: id,
            title: String(title),
            background: background,
            foreground: foreground,
            cursor: cursor,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: palette
        )
    }

    static func preset(for storedValue: String) -> KookyTerminalTheme? {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNamespaced = trimmed.hasPrefix(bundledStoredValuePrefix)
        let id = isNamespaced
            ? String(trimmed.dropFirst(bundledStoredValuePrefix.count))
            : trimmed
        return presets.first { theme in
            theme.id == id || (!isNamespaced && theme.title == trimmed)
        }
    }

    static func availableThemes(userThemeDirectory: URL = ghosttyUserThemesDirectory()) -> [KookyTerminalTheme] {
        presets + userThemes(in: userThemeDirectory)
    }

    static func theme(for storedValue: String, in themes: [KookyTerminalTheme]) -> KookyTerminalTheme? {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(bundledStoredValuePrefix) {
            return themes.first { $0.isBundled && $0.storedValue == trimmed }
        }
        // Unprefixed values predate the bundled namespace and are also how
        // Ghostty persists user theme file names. Prefer a real user theme so
        // adding a bundled preset with the same name cannot change an existing
        // user's colors after an upgrade. Fall back to the old bundled id /
        // display-name aliases when no matching user file exists.
        if let userTheme = themes.first(where: {
            !$0.isBundled
                && ($0.id == trimmed || $0.title == trimmed || $0.storedValue == trimmed)
        }) {
            return userTheme
        }
        return themes.first {
            $0.isBundled && ($0.id == trimmed || $0.title == trimmed)
        }
    }

    static func ghosttyUserThemesDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("ghostty/themes", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".config/ghostty/themes", isDirectory: true)
    }

    static func userThemes(in directory: URL) -> [KookyTerminalTheme] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }.compactMap { url -> KookyTerminalTheme? in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let values = parseGhosttyConfigLines(text)
            return KookyTerminalTheme(
                userThemeName: url.lastPathComponent,
                background: values["background"],
                foreground: values["foreground"],
                lines: text.split(whereSeparator: \.isNewline).map(String.init),
                url: url
            )
        }
    }

    static func bundledStoredValue(for id: String) -> String {
        bundledStoredValuePrefix + id
    }

    private init(
        id: String,
        title: String,
        background: String,
        foreground: String,
        cursor: String,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String]
    ) {
        self.id = id
        self.title = title
        self.storedValue = Self.bundledStoredValue(for: id)
        self.backgroundHex = background
        self.foregroundHex = foreground
        self.source = .bundled
        self.userThemeURL = nil
        self.lines = [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursor)",
            "selection-background = \(selectionBackground)",
            "selection-foreground = \(selectionForeground)",
        ] + palette.enumerated().map { idx, color in
            "palette = \(idx)=\(color)"
        }
    }

    private init(
        userThemeName: String,
        background: String?,
        foreground: String?,
        lines: [String],
        url: URL
    ) {
        self.id = "ghostty-user:\(userThemeName)"
        self.title = userThemeName
        self.storedValue = userThemeName
        self.backgroundHex = background ?? "#282C34"
        self.foregroundHex = foreground ?? "#EFEFF1"
        self.lines = lines
        self.source = .ghosttyUser
        self.userThemeURL = url.standardizedFileURL
    }

    private static func configKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    }

    private static func parseGhosttyConfigLines(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            values[key] = unwrapQuotes(rawValue)
        }
        return values
    }

    private static func unwrapQuotes(_ raw: String) -> String {
        guard raw.count >= 2,
              raw.first == raw.last,
              raw.first == "\"" || raw.first == "'" else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}
