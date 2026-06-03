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
        .library(name: "TemperHelperCore", targets: ["TemperHelperCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
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
        .executableTarget(
            name: "Oxine",
            dependencies: [
                "SousShared",
                "PanelKit",
                "SousKit",
                "TemperShared",
                "TemperKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: []
        )
    ]
)
