// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dashbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dashbar",
            path: "Sources/Dashbar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
