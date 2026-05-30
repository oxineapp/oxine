// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Oxine",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Oxine", targets: ["Oxine"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Oxine",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            resources: []
        )
    ]
)
