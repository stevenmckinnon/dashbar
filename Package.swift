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
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "DashbarStatus"],
            path: "Sources/Dashbar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The status the app saves for the command-line tool, and the tool's reading and printing of it. Foundation only.
        .target(
            name: "DashbarStatus",
            path: "Sources/DashbarStatus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `dashbar`, bundled as Dashbar.app/Contents/Helpers/dashbar. Named dashbar-cli here: on a case-insensitive disk
        // a product called dashbar would collide with Dashbar in the build folder.
        .executableTarget(
            name: "dashbar-cli",
            dependencies: ["DashbarStatus"],
            path: "Sources/dashbar-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DashbarTests",
            dependencies: ["Dashbar", "DashbarStatus"],
            path: "Tests/DashbarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
