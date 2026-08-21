// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kooky",
    defaultLocalization: "en",
    platforms: [
        // .v14 floor — `@Observable` macro requires Sonoma+. Dropping further
        // would mean reverting all session models to ObservableObject + @Published.
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        // Thin executable: main.swift only. Everything else lives in KookyKit so
        // tests can `@testable import` it (SPM doesn't allow importing executables).
        .executableTarget(
            name: "Kooky",
            dependencies: ["KookyKit"],
            path: "Sources/Kooky"
        ),
        // Tiny stand-alone CLI invoked from Claude Code / Codex hooks. Reads
        // $KOOKY_SURFACE_ID from env, opens the unix socket the running app
        // owns, writes one JSON line, exits. Doesn't link KookyKit on purpose
        // — keeps the binary fast and dependency-free.
        .executableTarget(
            name: "KookyHook",
            dependencies: ["KookyHookKit"],
            path: "Sources/KookyHook"
        ),
        // User-facing control CLI (`kooky-cli`): open tabs / run commands /
        // resume conversations / list / focus / close / status over the same
        // unix socket, but request-response instead of fire-and-forget.
        // Separate from KookyHook on purpose — hook argv is positional
        // (`kooky-hook <agent> <event>`) and a custom agent id could collide
        // with a verb. Doesn't link KookyKit for the same reason KookyHook
        // doesn't: the binary must stay small and AppKit-free. The target
        // IS the shipped binary name so one name holds across dev builds,
        // the bundle, and the Application Support mirror (nobody imports an
        // executable, so the mangled module name never surfaces).
        .executableTarget(
            name: "kooky-cli",
            dependencies: ["KookyHookKit"],
            path: "Sources/KookyCLI"
        ),
        // Payload builders + stdin parsing extracted out of `main.swift` so
        // they're unit-testable without spawning a subprocess. Foundation /
        // Darwin only — must not depend on KookyKit (would bloat the CLI).
        .target(
            name: "KookyHookKit",
            path: "Sources/KookyHookKit"
        ),
        .target(
            name: "KookyKit",
            dependencies: [
                "GhosttyKit",
                // CLI wire types (KookyCLIRequest/Response) — compiled into
                // both ends so the protocol can't drift. One-way dependency;
                // KookyHookKit stays Foundation/Darwin-only.
                "KookyHookKit",
            ],
            path: "Sources/KookyKit",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // libghostty bundles C++ deps (glslang, spirv-cross, imgui)
                // and uses Metal for rendering; link the system frameworks.
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                // Text Input Services — libghostty uses TIS to read the active
                // keyboard layout. Pulled in implicitly by SwiftTerm before;
                // now declared directly.
                .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            // Run scripts/setup-libghostty.sh to populate this; not committed.
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .testTarget(
            name: "KookyKitTests",
            // KookyHookKit is listed so socket integration tests can drive
            // HookServer with the real CLI transport client.
            dependencies: ["KookyKit", "KookyHookKit"],
            path: "Tests/KookyKitTests"
        ),
        .testTarget(
            name: "KookyHookKitTests",
            dependencies: ["KookyHookKit"],
            path: "Tests/KookyHookKitTests"
        ),
    ]
)
