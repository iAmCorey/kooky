import AppKit
import SwiftUI

/// Design tokens for kooky's chrome — refined minimal, low-contrast palette,
/// generous rhythm. The terminal theme is the source for the whole window:
/// libghostty gets concrete color config, while SwiftUI chrome derives its
/// own readable foreground / muted / hairline tokens from the same preset.
@MainActor
enum Theme {
    // MARK: Glass mode

    /// Cached glass state — recomputed by `reloadGlass()` on config reload.
    /// Reading disk on every SwiftUI body evaluation would be a hot-path I/O
    /// bottleneck, so we compute once and invalidate explicitly.
    private(set) static var glassEnabled: Bool = computeGlassEnabled()

    /// Recompute the cached glass flag. Called from `refreshThemeAppearances`
    /// so any config change (theme or blur) picks up the new state.
    static func reloadGlass() {
        glassEnabled = computeGlassEnabled()
    }

    private static func computeGlassEnabled() -> Bool {
        if let parsed = KookySettings.loadParsed(),
           let terminal = parsed["terminal"] as? [String: Any],
           let blur = terminal["background-blur"] as? String {
            return blur.hasPrefix("macos-glass")
        }
        return detectGhosttyGlass()
    }

    private static func detectGhosttyGlass() -> Bool {
        let ghosttyConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
        guard let raw = try? String(contentsOf: ghosttyConfig, encoding: .utf8) else { return false }
        return raw.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return false }
            guard let eq = trimmed.firstIndex(of: "=") else { return false }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return key == "background-blur" && val.hasPrefix("macos-glass")
        }
    }

    // MARK: Colors

    static var chromeBackground: Color {
        glassEnabled ? Color(nsColor: resolved.chromeBackgroundColor).opacity(0.65) : Color(nsColor: resolved.chromeBackgroundColor)
    }
    static var chromeForeground: Color { Color(nsColor: resolved.foregroundColor) }
    static var chromeMuted: Color { resolved.chromeMuted }
    static var chromeFaint: Color { resolved.chromeFaint }
    static var chromeHairline: Color { resolved.chromeHairline }
    static var chromeHover: Color { resolved.chromeHover }
    static var chromeActive: Color { resolved.chromeActive }

    /// Color libghostty draws inside the terminal surface. Exposed as NSColor
    /// so AppKit code (engines, etc.) can reach it without bridging.
    static var terminalSurface: NSColor { resolved.backgroundColor }

    static var chromeColorScheme: ColorScheme { resolved.isLight ? .light : .dark }

    static var windowAppearance: NSAppearance? {
        NSAppearance(named: resolved.isLight ? .aqua : .darkAqua)
    }

    /// `Theme.resolved` reads `KookySettingsModel.shared.selectedTerminalTheme` so
    /// SwiftUI's `@Observable` machinery registers the dependency on every
    /// body that touches a chrome token — without that read, body
    /// re-evaluation wouldn't fire on a theme switch. The cache key includes
    /// parsed background / foreground colors so a user theme file refreshes
    /// chrome when Settings reloads after the file changes.
    static var resolved: Resolved {
        let theme = KookySettingsModel.shared.selectedTerminalTheme
        let key = Resolved.CacheKey(
            themeId: theme?.id,
            backgroundHex: theme?.backgroundHex,
            foregroundHex: theme?.foregroundHex
        )
        if let cached = cachedResolved, cached.cacheKey == key { return cached }
        let next = Resolved(cacheKey: key, theme: theme)
        cachedResolved = next
        return next
    }
    private static var cachedResolved: Resolved?

    /// Snapshot of every token derived from one terminal theme. Computed once
    /// and reused until the theme id changes — see `Theme.resolved`.
    struct Resolved {
        struct CacheKey: Equatable {
            let themeId: String?
            let backgroundHex: String?
            let foregroundHex: String?
        }

        let cacheKey: CacheKey
        let backgroundColor: NSColor
        let foregroundColor: NSColor
        let chromeBackgroundColor: NSColor
        let isLight: Bool
        let chromeMuted: Color
        let chromeFaint: Color
        let chromeHairline: Color
        let chromeHover: Color
        let chromeActive: Color

        @MainActor
        fileprivate init(cacheKey: CacheKey, theme: KookyTerminalTheme?) {
            self.cacheKey = cacheKey
            self.backgroundColor = theme.flatMap { NSColor(hex: $0.backgroundHex) } ?? defaultTerminalSurface
            self.foregroundColor = theme.flatMap { NSColor(hex: $0.foregroundHex) } ?? defaultForeground
            self.isLight = backgroundColor.relativeLuminance > 0.55
            // Chrome sits one step off the surface so the terminal reads as
            // the framed canvas. Dark themes nudge toward black, light
            // themes toward the ink — keeps the chrome readable on each.
            self.chromeBackgroundColor = isLight
                ? mix(backgroundColor, foregroundColor, 0.035)
                : mix(backgroundColor, sRGBBlack, 0.16)
            let mutedNS = mix(foregroundColor, chromeBackgroundColor, isLight ? 0.42 : 0.52)
            let faintNS = mix(foregroundColor, chromeBackgroundColor, isLight ? 0.68 : 0.72)
            let fgColor = Color(nsColor: foregroundColor)
            self.chromeMuted = Color(nsColor: mutedNS)
            self.chromeFaint = Color(nsColor: faintNS)
            self.chromeHairline = fgColor.opacity(isLight ? 0.16 : 0.07)
            self.chromeHover = fgColor.opacity(isLight ? 0.11 : 0.07)
            self.chromeActive = fgColor.opacity(isLight ? 0.20 : 0.15)
        }
    }

    private static let defaultTerminalSurface = NSColor(srgbRed: 40 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1)
    private static let defaultForeground = NSColor(srgbRed: 0xEF / 255, green: 0xEF / 255, blue: 0xF1 / 255, alpha: 1)
    /// `NSColor.black` lives in `NSDeviceRGBColorSpace`; bridging to sRGB
    /// on every `mix(_, .black, _)` call is wasted work. Pre-convert once.
    private static let sRGBBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// Activity-dot palette — one design token per signal so sidebar workspace
    /// rows and tab pills read identically. Hue picked for at-a-glance read:
    /// cool blue == "thinking", warm amber == "needs you", warm red == "look
    /// when free". Precedence (where multiple apply) is encoded by callers.
    static let activityRunning = Color(.sRGB, red: 0.41, green: 0.69, blue: 0.86, opacity: 1)
    static let activityAttention = Color(.sRGB, red: 0.91, green: 0.69, blue: 0.40, opacity: 1)
    static let activityFailure = Color(.sRGB, red: 0.91, green: 0.40, blue: 0.40, opacity: 1)

    /// Git diff colors for the pane's bottom-right status — green for
    /// insertions, red for deletions. `gitDeletion` reuses the failure red so
    /// "red == something to look at" stays consistent across signals.
    static let gitInsertion = Color(.sRGB, red: 0.45, green: 0.78, blue: 0.50, opacity: 1)
    static let gitDeletion = activityFailure

    // MARK: Fonts
    private static let displayName = "Onest"
    private static let monoName = "JetBrainsMono-Regular"

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(displayName, size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(monoName, size: size).weight(weight)
    }

    // MARK: Spacing rhythm — multiples of 4. Use space3+ for chrome breathing.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24

    // MARK: Motion
    /// Standard transition for chrome state changes (sidebar collapse,
    /// drag-reorder commit). One source so timings can't drift across sites.
    static let chromeTransition: Animation = .easeInOut(duration: 0.2)

}

/// Linear interpolation between two NSColors in sRGB. Module-internal so
/// `Theme.Resolved.init` can reach it without going through `Theme.` (the
/// init is fileprivate already so the helper doesn't need to escape).
private func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
    let ca = a.usingColorSpace(.sRGB) ?? a
    let cb = b.usingColorSpace(.sRGB) ?? b
    let t = max(0, min(1, amount))
    return NSColor(
        srgbRed: ca.redComponent * (1 - t) + cb.redComponent * t,
        green: ca.greenComponent * (1 - t) + cb.greenComponent * t,
        blue: ca.blueComponent * (1 - t) + cb.blueComponent * t,
        alpha: ca.alphaComponent * (1 - t) + cb.alphaComponent * t
    )
}

// MARK: - Brutalist primitives

/// 1pt hairline stroke, sharp corners — the brutalist border shared by
/// `BracketButton`, settings option fields, and the update prompt window.
extension View {
    func bracketBorder() -> some View {
        overlay(Rectangle().stroke(Theme.chromeHairline, lineWidth: 1))
    }
}

/// Plain-text `[bracketed]` button. Hairline border, mono, sharp corners.
struct BracketButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(11.5, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .bracketBorder()
        }
        .buttonStyle(.plain)
    }
}

/// Registers bundled fonts at app launch via Core Text. SPM resources show up
/// in `Bundle.module`; CTFontManagerRegisterFontsForURL exposes them by family
/// name so SwiftUI's Font.custom("...") finds them.
@MainActor
enum KookyFonts {
    static func registerOnce() {
        guard !registered else { return }
        registered = true
        for name in ["Onest", "JetBrainsMono-Regular"] {
            guard let url = bundleResourceURL(name: name, ext: "ttf", subdirectory: "Fonts") else {
                NSLog("kooky: missing font \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("kooky: font register failed for \(name): \(String(describing: error?.takeRetainedValue()))")
            }
        }
    }

    private static var registered = false
}

/// Replaces SPM's auto-generated `Bundle.module`, which `fatalError`s on
/// first access inside a `.app` (it only checks `Bundle.main.bundleURL` —
/// the .app root — but resources canonically ship in `Contents/Resources/`).
@MainActor
func bundleResourceURL(name: String, ext: String, subdirectory: String) -> URL? {
    let bundleName = "Kooky_KookyKit"
    let candidates: [URL] = [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
    ].compactMap { $0?.appendingPathComponent("\(bundleName).bundle") }
    for candidate in candidates {
        guard let bundle = Bundle(url: candidate) else { continue }
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) { return url }
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }
    }
    return nil
}

/// Parses `#RRGGBB` / `RRGGBB` into sRGB components, or nil for malformed
/// input. Single source for both `Color(hex:)` and `NSColor(hex:)` so any
/// future tolerance changes (e.g. `#RGB` short-form) land in one place.
private func parseHexRGB(_ hex: String) -> (r: Double, g: Double, b: Double)? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return (
        Double((v >> 16) & 0xFF) / 255,
        Double((v >> 8) & 0xFF) / 255,
        Double(v & 0xFF) / 255
    )
}

extension Color {
    /// `Color(hex: "D97757")` or `Color(hex: "#D97757")`. Returns nil for
    /// malformed input so callers can fall back deterministically.
    init?(hex: String) {
        guard let rgb = parseHexRGB(hex) else { return nil }
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        guard let rgb = parseHexRGB(hex) else { return nil }
        self.init(srgbRed: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: 1)
    }

    var relativeLuminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }
}
