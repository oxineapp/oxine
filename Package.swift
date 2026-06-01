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
        // The privileged battery-control daemon. Tiny on purpose: it owns the
        // SMC connection, a safety-guarded maintenance loop, and nothing else.
        .executableTarget(
            name: "SousHelper",
            dependencies: ["SousShared"]
        ),
        .executableTarget(
            name: "Oxine",
            dependencies: [
                "SousShared",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: []
        )
    ]
)
