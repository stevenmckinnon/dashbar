// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dashbar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dashbar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Dashbar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DashbarTests",
            dependencies: ["Dashbar"],
            path: "Tests/DashbarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
