// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Oxine",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Oxine", targets: ["Oxine"]),
        .executable(name: "com.oxine.soushelper", targets: ["SousHelper"])
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
        .executableTarget(
            name: "Oxine",
            dependencies: [
                "SousShared",
                "PanelKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: []
        )
    ]
)
