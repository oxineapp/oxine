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
        .executable(name: "SousVide", targets: ["SousVide"]),
        .executable(name: "com.sousvide.soushelper", targets: ["SousVideHelper"])
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
        .executableTarget(
            name: "Oxine",
            dependencies: [
                "SousShared",
                "PanelKit",
                "SousKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: []
        ),
        // The standalone sous-vide app's daemon (its own brand).
        .executableTarget(
            name: "SousVideHelper",
            dependencies: ["SousShared", "SousHelperCore"]
        ),
        // The standalone sous-vide peer app: Sous feature + shared chrome, its
        // own branding. Reuses PanelKit + SousKit, no copy-paste.
        .executableTarget(
            name: "SousVide",
            dependencies: [
                "SousShared",
                "PanelKit",
                "SousKit",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        )
    ]
)
