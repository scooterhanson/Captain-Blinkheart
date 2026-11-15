// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptainBlinkheart",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Captain Blinkheart", targets: ["SceneBridgeApp"]),
        .library(name: "SceneBridgeCore", targets: ["SceneBridgeCore"])
    ],
    targets: [
        .target(
            name: "SceneBridgeCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SceneBridgeApp",
            dependencies: ["SceneBridgeCore"]
        ),
        .testTarget(
            name: "SceneBridgeAppTests",
            dependencies: ["SceneBridgeCore"]
        )
    ]
)
