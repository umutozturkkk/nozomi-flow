// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NozomiFlow",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "NozomiFlow",
            dependencies: ["NozomiFlowKit"],
            path: "Sources/NozomiFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "NozomiFlowKit",
            path: "Sources/NozomiFlowKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NozomiFlowKitTests",
            dependencies: ["NozomiFlowKit"],
            path: "Tests/NozomiFlowKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
