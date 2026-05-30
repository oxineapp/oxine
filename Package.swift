// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MenubarApp",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MenubarApp", targets: ["MenubarApp"])
    ],
    targets: [
        .executableTarget(
            name: "MenubarApp",
            dependencies: [],
            resources: []
        )
    ]
)
