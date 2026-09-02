import AppKit
import SwiftUI

/// App chrome appearance is independent from the terminal palette. `system`
/// follows macOS and picks the matching light/dark terminal theme; explicit
/// modes pin both AppKit controls and SwiftUI chrome to one side.
enum KookyAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    func resolvesDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    @MainActor
    static var systemIsDark: Bool {
        // Kooky pins individual windows to Aqua/Dark Aqua for stable Liquid
        // Glass, but never pins NSApp itself. Its effective appearance is
        // therefore the supported, live source for the macOS system setting.
        // Unlike AppleInterfaceStyle in UserDefaults, it is not a stale
        // process-cached snapshot after the user flips System Settings.
        resolvesSystemDark(appearance: NSApplication.shared.effectiveAppearance)
    }

    static func resolvesSystemDark(appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Design tokens for kooky's chrome — refined minimal, low-contrast palette,
/// generous rhythm. The terminal theme is the source for the whole window:
/// libghostty gets concrete color config, while SwiftUI chrome derives its
/// own readable foreground / muted / hairline tokens from the same preset.
@MainActor
enum Theme {
    // MARK: Colors

    /// Chrome derives from the terminal theme's `background`; dark themes can
    /// mix it toward black using the configurable chrome ratio.
    static var chromeBackground: Color { Color(nsColor: resolved.chromeBackgroundColor) }
    static var chromeForeground: Color { Color(nsColor: resolved.foregroundColor) }
    static var chromeMuted: Color { resolved.chromeMuted }
    static var chromeFaint: Color { resolved.chromeFaint }
    static var chromeHairline: Color { resolved.chromeHairline }
    /// Softer structural divider used by the main window chrome. Hairlines
    /// remain available for compact controls and overlay detail, while the
    /// window skeleton stays deliberately quieter.
    static var chromeSeparator: Color { resolved.chromeSeparator }
    static var chromeHover: Color { resolved.chromeHover }
    static var chromeActive: Color { resolved.chromeActive }
    /// Stable selected surface for tabs and source-list rows. Keeping this
    /// separate from `chromeActive` prevents selection from looking like a
    /// permanently pressed button.
    static var chromeSelection: Color { resolved.chromeSelection }

    /// Color libghostty draws inside the terminal surface. Exposed as NSColor
    /// so AppKit code (engines, etc.) can reach it without bridging.
    static var terminalSurface: NSColor { resolved.backgroundColor }

    /// System resolves to the system's *current* concrete side. Keeping this
    /// concrete matters for Liquid Glass: changing a window from forced Aqua
    /// to `appearance = nil` can leave an existing NSGlassEffectView cached in
    /// its light rendering even after the window inherits Dark Aqua.
    static var chromeColorScheme: ColorScheme {
        resolvedAppearanceIsDark ? .dark : .light
    }

    static var windowAppearance: NSAppearance? {
        NSAppearance(named: resolvedAppearanceIsDark ? .darkAqua : .aqua)
    }

    private static var resolvedAppearanceIsDark: Bool {
        let model = KookySettingsModel.shared
        // Before the paired-theme schema, an absent terminal.theme was the
        // "Default" sentinel: libghostty inherited Ghostty while kooky's
        // fallback chrome was dark. Preserve both halves for upgraded users
        // until they explicitly touch an Appearance theme control.
        guard model.pairedThemeSchemaEnabled else { return true }
        return model.appearanceMode.resolvesDark(
            systemIsDark: model.systemAppearanceIsDark
        )
    }

    // MARK: Glass — macOS 26 Liquid Glass (opt-in via `background-blur`)

    /// The two glass styles ghostty exposes as `macos-glass-regular` /
    /// `macos-glass-clear`. `official` bridges to AppKit's
    /// `NSGlassEffectView.Style`, which only exists in the macOS 26 SDK —
    /// hence the compiler guard so older toolchains still build.
    enum GlassStyle {
        case regular, clear

        #if compiler(>=6.2)
        @available(macOS 26.0, *)
        var official: NSGlassEffectView.Style {
            switch self {
            case .regular: return .regular
            case .clear: return .clear
            }
        }
        #endif
    }

    /// The glass mode in effect, or `nil` for opaque chrome.
    static var glassStyle: GlassStyle? {
        switch effectiveBlurRaw {
        case "macos-glass-regular": return .regular
        case "macos-glass-clear": return .clear
        default: return nil
        }
    }

    /// The resolved `background-blur` value: kooky's own setting wins whenever
    /// it's present (including an explicit non-glass value like `false` = off),
    /// and the user's ghostty config only fills in when kooky has no opinion at
    /// all. So picking "Off" in kooky overrides a glassy ghostty config, while
    /// a fresh kooky still inherits glass from ghostty. Reading
    /// `KookySettingsModel.shared` registers the `@Observable` dependency so
    /// SwiftUI re-renders the moment the dropdown changes.
    static var effectiveBlurRaw: String? {
        KookySettingsModel.shared.backgroundBlur ?? ghosttyFallback.blur
    }

    /// Whether glass is *actually rendering* — a style is configured AND we're
    /// on macOS 26, where real Liquid Glass exists. Older systems render
    /// nothing (opaque chrome), so this gates window transparency and panel
    /// translucency; `glassStyle` alone only reflects the saved preference.
    static var glassEnabled: Bool {
        if #available(macOS 26.0, *) { return glassStyle != nil }
        return false
    }

    /// Terminal opacity applied when a glass style is on but the user set no
    /// explicit `background-opacity` — enough see-through for the glass to read
    /// without washing out the text. Single source for both the libghostty
    /// config injection (`KookySettings.apply`) and the `backgroundOpacity`
    /// fallback below. `nonisolated` so the non-MainActor config builder can
    /// read it. Tune on macOS 26 hardware.
    nonisolated static let defaultGlassOpacity: Double = 0.82

    /// `background-opacity` clamped to a visible range. Drives the glass tint;
    /// also the value libghostty draws the terminal surface at. Defaults to
    /// 0.82 when a glass mode is on but no opacity was set, so the effect
    /// shows without the user also having to hand-set opacity.
    static var backgroundOpacity: Double {
        let raw = KookySettingsModel.shared.backgroundOpacity
            ?? ghosttyFallback.opacity
            ?? (glassEnabled ? defaultGlassOpacity : 1)
        return max(0.001, min(1, raw))
    }

    /// Tint the window glass leans toward — the terminal background at
    /// `backgroundOpacity`, mirroring ghostty so the glass reads as the
    /// active theme's surface rather than a neutral frost.
    static var glassTint: NSColor {
        resolved.backgroundColor.withAlphaComponent(backgroundOpacity)
    }

    /// When a glass window resigns key, macOS washes the glass to a flat gray.
    /// ghostty masks that by covering the glass with the (slightly saturated)
    /// terminal background, so the inactive window reads as the theme color
    /// instead of gray. This is that overlay color + opacity.
    ///
    /// `clear` glass is far more see-through than `regular`, so it gets a
    /// lighter mask — covering it at the regular opacity would make clear look
    /// like regular's frost when inactive. Heavier on dark themes, where the
    /// gray is most obvious. Tune these on macOS 26 hardware.
    static var glassInactiveTint: Color {
        let saturated = resolved.backgroundColor.adjustingSaturation(by: 1.2)
        let opacity: Double
        switch glassStyle {
        case .clear: opacity = resolved.isLight ? 0.20 : 0.50
        default:     opacity = resolved.isLight ? 0.35 : 0.85
        }
        return Color(nsColor: saturated).opacity(opacity)
    }

    /// Chrome panels (sidebar, tab bar, status bar, menus) sit *in front* of
    /// the single window-level glass layer, so in glass mode they use a
    /// translucent tint of the same terminal theme background to let the
    /// glass read through instead of their own opaque fill. `clear` glass
    /// shows more; `regular` stays a touch more solid.
    static var glassPanelTint: Color {
        let opacity: Double = glassStyle == .clear ? 0.40 : 0.60
        return Color(nsColor: resolved.backgroundColor).opacity(opacity)
    }

    /// `~/.config/ghostty/config` `background-blur` / `background-opacity`,
    /// read once. The fallback for users who configured glass only in ghostty
    /// (issue #26) — kooky's own setting always wins over this. Ghostty-config
    /// edits are rare enough that a process-lifetime cache (no re-read on every
    /// SwiftUI body) is the right trade; toggle live via the Settings dropdown.
    private static let ghosttyFallback: (blur: String?, opacity: Double?) = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var blur: String?
        var opacity: Double?
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key == "background-blur" { blur = val }
            if key == "background-opacity" { opacity = Double(val) }
        }
        return (blur, opacity)
    }()

    /// `Theme.resolved` reads `KookySettingsModel.shared.selectedTerminalTheme` so
    /// SwiftUI's `@Observable` machinery registers the dependency on every
    /// body that touches a chrome token — without that read, body
    /// re-evaluation wouldn't fire on a theme switch. The cache key includes
    /// parsed colors and the chrome mix ratio so every appearance edit rebuilds
    /// the derived chrome tokens.
    static var resolved: Resolved {
        let model = KookySettingsModel.shared
        let isDarkAppearance = resolvedAppearanceIsDark
        let theme = model.selectedTerminalTheme
        let key = Resolved.CacheKey(
            themeId: theme?.id,
            backgroundHex: theme?.backgroundHex,
            foregroundHex: theme?.foregroundHex,
            isDarkAppearance: isDarkAppearance,
            chromeBackgroundMix: model.chromeBackgroundMix
        )
        if let cached = cachedResolved, cached.cacheKey == key { return cached }
        let next = Resolved(
            cacheKey: key,
            theme: theme,
            isDarkAppearance: isDarkAppearance,
            chromeBackgroundMix: model.chromeBackgroundMix
        )
        cachedResolved = next
        return next
    }
    private static var cachedResolved: Resolved?

    /// Snapshot of every token derived from one terminal theme. Computed once
    /// and reused until one of the theme inputs changes — see `Theme.resolved`.
    struct Resolved {
        struct CacheKey: Equatable {
            let themeId: String?
            let backgroundHex: String?
            let foregroundHex: String?
            let isDarkAppearance: Bool
            let chromeBackgroundMix: Double
        }

        let cacheKey: CacheKey
        let backgroundColor: NSColor
        let foregroundColor: NSColor
        let chromeBackgroundColor: NSColor
        let isLight: Bool
        let chromeMuted: Color
        let chromeFaint: Color
        let chromeHairline: Color
        let chromeSeparator: Color
        let chromeHover: Color
        let chromeActive: Color
        let chromeSelection: Color

        @MainActor
        fileprivate init(
            cacheKey: CacheKey,
            theme: KookyTerminalTheme?,
            isDarkAppearance: Bool,
            chromeBackgroundMix: Double
        ) {
            self.cacheKey = cacheKey
            self.backgroundColor = theme.flatMap { NSColor(hex: $0.backgroundHex) }
                ?? (isDarkAppearance ? defaultTerminalSurface : defaultLightTerminalSurface)
            self.foregroundColor = theme.flatMap { NSColor(hex: $0.foregroundHex) }
                ?? (isDarkAppearance ? defaultForeground : defaultLightForeground)
            self.isLight = backgroundColor.relativeLuminance > 0.55
            // Chrome uses the theme background with a configurable dark-theme
            // mix toward black; 0.16 preserves the existing default.
            self.chromeBackgroundColor = isLight
                ? mix(backgroundColor, foregroundColor, 0.035)
                : mix(backgroundColor, sRGBBlack, min(max(chromeBackgroundMix, 0), 1))
            let mutedNS = mix(foregroundColor, chromeBackgroundColor, isLight ? 0.42 : 0.52)
            let faintNS = mix(foregroundColor, chromeBackgroundColor, isLight ? 0.68 : 0.72)
            let fgColor = Color(nsColor: foregroundColor)
            self.chromeMuted = Color(nsColor: mutedNS)
            self.chromeFaint = Color(nsColor: faintNS)
            self.chromeHairline = fgColor.opacity(isLight ? 0.16 : 0.07)
            self.chromeSeparator = fgColor.opacity(isLight ? 0.10 : 0.045)
            self.chromeHover = fgColor.opacity(isLight ? 0.09 : 0.055)
            self.chromeActive = fgColor.opacity(isLight ? 0.18 : 0.13)
            self.chromeSelection = fgColor.opacity(isLight ? 0.14 : 0.10)
        }
    }

    private static let defaultTerminalSurface = NSColor(srgbRed: 40 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1)
    private static let defaultForeground = NSColor(srgbRed: 0xEF / 255, green: 0xEF / 255, blue: 0xF1 / 255, alpha: 1)
    private static let defaultLightTerminalSurface = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255, alpha: 1)
    private static let defaultLightForeground = NSColor(srgbRed: 0x38 / 255, green: 0x3A / 255, blue: 0x42 / 255, alpha: 1)
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
    /// "Operation succeeded" green — tool-call ✓ glyph, copy feedback,
    /// exit-0 tint. Named so success indicators can retune independently
    /// of the git-diff palette if the two ever diverge.
    static let activitySuccess = Color(.sRGB, red: 0.45, green: 0.78, blue: 0.50, opacity: 1)

    /// Git diff colors for the pane's bottom-right status — green for
    /// insertions, red for deletions. Dark chrome reuses the activity hues;
    /// light chrome needs deeper variants because those luminous colors fall
    /// below readable text contrast on a near-white status surface.
    static var gitInsertion: Color {
        resolved.isLight
            ? Color(.sRGB, red: 0.12, green: 0.46, blue: 0.24, opacity: 1)
            : activitySuccess
    }
    static var gitDeletion: Color {
        resolved.isLight
            ? Color(.sRGB, red: 0.68, green: 0.18, blue: 0.20, opacity: 1)
            : activityFailure
    }
    /// The sign is intentionally quieter than its digits, but 60% made the
    /// already-small glyph too faint on light chrome.
    static var gitSignOpacity: Double { resolved.isLight ? 0.78 : 0.60 }

    /// Keep-awake status light (top strip). Tuned to read like the MacBook
    /// keyboard's Caps Lock LED — a bright, luminous emerald.
    static let keepAwakeGreen = Color(.sRGB, red: 0.30, green: 0.91, blue: 0.45, opacity: 1)

    /// Width of a workspace row's colour-tag stripe. Wider than the 1.5pt
    /// compact worktree marker that used to own this slot — that one was
    /// ambient, this one is the only thing on the row the user chose. Note it
    /// does not *replace* that marker: tags are opt-in and nil by default, so
    /// an untagged compact row now carries no stripe at all.
    static let colorTagStripeWidth: CGFloat = 3

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

    // MARK: Chrome controls

    /// Main-window control families. Global toolbar actions use a 28pt hit
    /// square; dense contextual actions use 20pt; the persistent bottom bars
    /// use a 22pt compact height. Width may be larger for a segmented control,
    /// but its vertical geometry still comes from this single scale.
    static let chromeToolbarButtonSize: CGFloat = 28
    static let chromeContextButtonSize: CGFloat = 20
    static let chromeCompactButtonSize: CGFloat = 22
    static let chromeFooterSegmentWidth: CGFloat = 26
    static let chromeOpenInIconSize: CGFloat = 17
    static let chromeSplitChevronWidth: CGFloat = 18
    static let chromeButtonCornerRadius: CGFloat = 5
    static let chromeSelectionCornerRadius: CGFloat = 6
    static let chromeControlSpacing: CGFloat = 2
    static let chromeBarEdgeInset: CGFloat = space2
    static let chromeBottomBarVerticalPadding: CGFloat = 5

    /// Left-sidebar content grid. A 16pt gutter plus a 20pt primary mark is a
    /// conventional desktop source-list rhythm; its 26pt centre also matches
    /// the middle of Kooky's 52pt compact rail. The native traffic-light group
    /// is aligned to this axis by `KookyWindowController` rather than pulling
    /// sidebar content into the window's cramped default 16pt button centre.
    static let sidebarContentLeadingX: CGFloat = 16
    static let sidebarPrimaryIconSize: CGFloat = 20
    static let sidebarLeadingIconCenterX = sidebarContentLeadingX + sidebarPrimaryIconSize / 2

    /// Native macOS titlebar controls are 14pt circles on 23pt centres. After
    /// the close button is aligned to the sidebar axis, reserve the complete
    /// three-button group plus a regular 12pt (`space3`) toolbar-section gap
    /// before the left-sidebar toggle's hit target begins.
    static let titlebarControlRadius: CGFloat = 7
    static let titlebarControlCenterSpacing: CGFloat = 23
    static let topStripLeadingReservedWidth = sidebarLeadingIconCenterX
        + 2 * titlebarControlCenterSpacing
        + titlebarControlRadius
        + space3

    /// The left section title, every pane tab strip, and the full right-panel
    /// title share one baseline. Keeping this in the theme prevents the three
    /// independently-owned surfaces from drifting apart again.
    static let contentHeaderHeight: CGFloat = 42

    /// Shared vertical breathing room for the left workspace rows and the
    /// right agent-panel rows so the two sidebars keep the same density.
    static let sidebarRowVerticalPadding: CGFloat = 9

    // MARK: Motion
    /// Standard transition for chrome state changes (sidebar collapse,
    /// drag-reorder commit). One source so timings can't drift across sites.
    static let chromeTransition: Animation = .easeInOut(duration: 0.2)

}

/// Linear interpolation between two NSColors in sRGB. Module-internal so
/// `Theme.Resolved.init` can reach it without going through `Theme.` (the
/// init is fileprivate already so the helper doesn't need to escape).
extension NSColor {
    /// Multiply saturation (clamped to 1). Mirrors ghostty's inactive-window
    /// tint, which boosts the background's saturation so the masked-inactive
    /// state reads as a deliberate tint rather than a dull wash.
    func adjustingSaturation(by factor: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * factor), brightness: b, alpha: a)
    }
}

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
    let localizesTitle: Bool
    let action: () -> Void

    init(
        _ title: String,
        localizesTitle: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.localizesTitle = localizesTitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if localizesTitle {
                    Text(LocalizedStringKey(title), bundle: .kookyResources)
                } else {
                    Text(verbatim: title)
                }
            }
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

/// Resolves the resource bundle once per process. `.kookyResources` sits on
/// every localization hot path; repeatedly rebuilding candidate URLs and
/// opening the same bundle is pure overhead after the app layout is fixed.
private enum KookyResourceBundleCache {
    static let resolved: Bundle? = {
        let bundleName = "Kooky_KookyKit"
        let candidates: [URL] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ].compactMap { $0?.appendingPathComponent("\(bundleName).bundle") }
        for candidate in candidates {
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return nil
        #endif
    }()

    static let effective = resolved ?? .main
}

/// Replaces SPM's auto-generated `Bundle.module` as the first lookup inside a
/// packaged `.app` (the generated accessor checks the .app root, while
/// resources canonically ship in `Contents/Resources/`). The SPM accessor is
/// still the final fallback for `swift run` and xctest, where its absolute
/// build path is valid.
func kookyResourceBundle() -> Bundle? {
    KookyResourceBundleCache.resolved
}

extension Bundle {
    /// The package resource bundle in both `swift run`/xctest and assembled
    /// `.app` layouts. Localization still uses Foundation/SwiftUI's native
    /// APIs; this only resolves where SwiftPM placed the resources.
    static var kookyResources: Bundle {
        KookyResourceBundleCache.effective
    }
}

@MainActor
func bundleResourceURL(name: String, ext: String, subdirectory: String) -> URL? {
    guard let bundle = kookyResourceBundle() else { return nil }
    if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) { return url }
    return bundle.url(forResource: name, withExtension: ext)
}

/// Parses `#RRGGBB` / `RRGGBB` into sRGB components, or nil for malformed
/// input. Single source for both `Color(hex:)` and `NSColor(hex:)` so any
/// future tolerance changes (e.g. `#RGB` short-form) land in one place.
func parseHexRGB(_ hex: String) -> (r: Double, g: Double, b: Double)? {
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

/// User-assigned workspace marker, drawn as a stripe down the row's leading
/// edge. Deliberately opt-in and sparse: a colour only tells you something
/// when most rows don't have one, so kooky never assigns these automatically —
/// a sidebar where every row is tagged is a sidebar where none of them stand
/// out (issue #43).
///
/// Hues overlap the activity palette on purpose. A tag is a vertical bar on
/// the leading edge and an activity signal is a 6pt dot on the trailing edge,
/// so position and shape already separate them — which frees the tags to use
/// red, the colour users most want for "deal with this one first".
extension NSColor {
    /// `RRGGBB` in sRGB. Nil when the colour has no RGB representation
    /// (pattern or catalog colours), so a caller falls back deterministically
    /// instead of persisting garbage.
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let channel = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X",
                      channel(c.redComponent), channel(c.greenComponent), channel(c.blueComponent))
    }
}

extension WorkspaceTag {
    /// Falls back to gray rather than failing when the stored hex is malformed
    /// — a hand-edited `state.json` costs the user a colour, not the restore.
    /// Lives here, not on the model: `WorkspaceTag` is Foundation-only so the
    /// session layer doesn't take a SwiftUI dependency.
    var swatchColor: Color { Color(hex: colorHex) ?? Color(hex: WorkspaceColorTag.gray.hex)! }
}

extension WorkspaceColorTag {
    /// Resolved once per case — the swatch strip rebuilds its body on every
    /// mouse move across the palette, and re-parsing seven hex strings each
    /// time is pure waste for a compile-time-constant set.
    @MainActor var color: Color { Self.resolved[self] ?? Theme.chromeMuted }

    private static let resolved: [WorkspaceColorTag: Color] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { preset in
            Color(hex: preset.hex).map { (preset, $0) }
        }
    )
}
