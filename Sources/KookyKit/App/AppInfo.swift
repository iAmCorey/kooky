import Foundation

/// Single source of truth for product metadata — surfaced by the About panel,
/// Help menu, and window title. Bump `displayVersion` on every release so the
/// About panel matches the latest CHANGELOG `vX.Y` tag.
enum KookyApp {
    static let name = "kooky"
    static let displayVersion = "0.11.6"
    static let tagline = "A minimal modern terminal for AI coding"
    static let author = "Corey Chiu"
    static let authorURL = URL(string: "https://coreychiu.com")!
    static let copyrightYear = "2026"

    static let repositoryURL = URL(string: "https://github.com/iAmCorey/kooky")!
    static let issuesURL = URL(string: "https://github.com/iAmCorey/kooky/issues")!
}
