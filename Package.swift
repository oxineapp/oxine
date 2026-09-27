// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Oxine",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Oxine", targets: ["Oxine"]),
        .executable(name: "com.oxine.soushelper", targets: ["SousHelper"]),
        .executable(name: "com.oxine.temperhelper", targets: ["TemperHelper"]),
        // Shared libraries consumed by the standalone sous-vide app (alfaoz/sous-vide
        // depends on this package and builds its own app + helper on top of these).
        .library(name: "PanelKit", targets: ["PanelKit"]),
        .library(name: "SousKit", targets: ["SousKit"]),
        .library(name: "SousShared", targets: ["SousShared"]),
        .library(name: "SousHelperCore", targets: ["SousHelperCore"]),
        // Temper (thermal/performance + fan control) as reusable products too.
        .library(name: "TemperKit", targets: ["TemperKit"]),
        .library(name: "TemperShared", targets: ["TemperShared"]),
        .library(name: "TemperHelperCore", targets: ["TemperHelperCore"]),
        // NotchKit: the brand-neutral notch-companion engine + built-in modules,
        // built on PanelKit chrome. Reusable like the other kits.
        .library(name: "NotchKit", targets: ["NotchKit"]),
        // TapKit: the shared audio engine (Core Audio process taps) behind every
        // audio app. One hub owns the taps, so Decant and Sommelier never need
        // each other installed and never fight over a process.
        .library(name: "TapKit", targets: ["TapKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        // The proven notch presentation layer (window, shape, geometry, fluid
        // expand/compact + hover). NotchKit wraps this and contributes modules.
        // Vendored from MrKai77/DynamicNotchKit 1.1.0 with a window-lifecycle
        // fix (vendor/DynamicNotchKit/PATCHES.md). A target, not a local
        // package, so apps that depend on this package by URL still resolve.
        .target(
            name: "DynamicNotchKit",
            path: "vendor/DynamicNotchKit/Sources/DynamicNotchKit"
        ),
        // Pure lyric plumbing (LRC parsing, line lookup, overlay layout math):
        // no AppKit, so it stays unit-testable in isolation.
        .target(name: "LyricsCore"),
        // The wire format for notch notices between Oxine and outside tools.
        .target(name: "NoticeBridge"),
        // Notice Playground: a separate developer app for trying notch
        // notices against a running Oxine. Not part of Oxine or its store.
        .executableTarget(name: "NoticePlayground", dependencies: ["NoticeBridge"]),
        // Chat Demo: a pretend chat app that runs inside Oxine like a store
        // app, for trying the chat surfaces, message notices and the notch's
        // attention glow without a real messenger. `chatdemo.sh` installs it.
        .executableTarget(name: "ChatDemo", dependencies: ["OxineAppSDK"]),
        // The app side of the apps protocol, for apps written in Swift.
        .target(name: "OxineAppSDK"),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"]),
        .testTarget(name: "NotchKitTests", dependencies: ["NotchKit", "LyricsCore"]),
        // Types shared verbatim across the app↔daemon XPC boundary.
        .target(
            name: "SousShared"
        ),
        // The daemon's reusable engine: SMC access, the safety-guarded
        // maintenance loop, and the brand-parameterized XPC runtime. Each brand
        // builds a tiny @main helper on top of this.
        .target(
            name: "SousHelperCore",
            dependencies: ["SousShared"]
        ),
        // Oxine's privileged battery-control daemon. Tiny on purpose: just an
        // entry point that runs SousHelperCore with the Oxine branding.
        .executableTarget(
            name: "SousHelper",
            dependencies: ["SousShared", "SousHelperCore"]
        ),
        // Brand-neutral panel chrome shared by Oxine and the standalone sous-vide
        // app: glass shell, theme, size store, Sparkle updater UI, crash reporter.
        .target(
            name: "PanelKit",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        // The Sous battery feature as a reusable module: manager, view, helper
        // client, power-flow diagram, and battery metrics. Built on PanelKit
        // chrome + the shared XPC types, so both Oxine and the standalone
        // sous-vide app embed the same feature.
        .target(
            name: "SousKit",
            dependencies: ["SousShared", "PanelKit"]
        ),
        // Types shared across the app↔fan-daemon XPC boundary.
        .target(
            name: "TemperShared"
        ),
        // The fan daemon's reusable engine: SMC fan access (with the Ftst unlock),
        // the safety-guarded re-assert loop, and the brand-parameterized runtime.
        .target(
            name: "TemperHelperCore",
            dependencies: ["TemperShared"]
        ),
        // Oxine's privileged fan-control daemon. Tiny entry point over the core.
        .executableTarget(
            name: "TemperHelper",
            dependencies: ["TemperShared", "TemperHelperCore"]
        ),
        // The Temper thermal/performance dashboard + fan control as a reusable
        // module, built on PanelKit chrome + the shared XPC types.
        .target(
            name: "TemperKit",
            dependencies: ["TemperShared", "PanelKit"]
        ),
        // The notch companion as a reusable module: the notch window/geometry/
        // state engine, the module protocol, and the built-in modules (now playing,
        // mirror, shelf, calendar). Built on PanelKit chrome + theme.
        .target(
            name: "NotchKit",
            dependencies: [
                "LyricsCore",
                "PanelKit",
                "DynamicNotchKit",
                "NoticeBridge"
            ]
        ),
        // Per-app audio without a virtual device: process taps, the private
        // aggregate devices that replay them, app grouping, and the hub that
        // arbitrates between the apps using them. No UI.
        .target(name: "TapKit"),
        .executableTarget(
            name: "Oxine",
            dependencies: [
                "TapKit",
                "SousShared",
                "PanelKit",
                "SousKit",
                "TemperShared",
                "TemperKit",
                "NotchKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: []
        )
    ]
)
