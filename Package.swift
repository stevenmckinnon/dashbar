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
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "DashbarStatus", "DashbarWidgetUI"],
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
        // The desktop widgets' views and what they show, shared by the extension and the app (which renders them offline
        // for `--snapshot --widget`). Built for app extensions, so the extension can link it.
        .target(
            name: "DashbarWidgetUI",
            dependencies: ["DashbarStatus"],
            path: "Sources/DashbarWidgetUI",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-application-extension"])]
        ),
        // The widget extension's executable, bundled by build.sh as Contents/PlugIns/DashbarWidgets.appex. Its entry point is
        // WidgetKit's, through the `@main` WidgetBundle.
        .executableTarget(
            name: "DashbarWidgets",
            dependencies: ["DashbarStatus", "DashbarWidgetUI"],
            path: "Sources/DashbarWidgets",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension"])]
        ),
        .testTarget(
            name: "DashbarTests",
            dependencies: ["Dashbar", "DashbarStatus", "DashbarWidgetUI"],
            path: "Tests/DashbarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
