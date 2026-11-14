import SwiftUI
import AppKit

@main
struct DashbarApp: App {
    /// A snapshot run renders from its own store (`Snapshot`), so the menu bar item gets invented data and nothing is
    /// collected twice.
    @StateObject private var store = Store(demo: CommandLine.arguments.contains("--snapshot"))

    init() {
        Onboarding.decideAtLaunch()   // before anything this launch saves a preference
        _ = Updater.shared   // starts Sparkle's scheduled checks in a built app
        // Belt-and-braces: hide the Dock icon even when run outside the .app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
        BuildInfo.applyLocalIcon()
        if CommandLine.arguments.contains("--bench") { Bench.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.schedule(to: CommandLine.arguments[i + 1])
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
                .onAppear {
                    if CommandLine.arguments.contains("--window") { AppWindow.shared.show(store: store) }
                    Onboarding.showAtLaunchIfNeeded(store: store)
                    if !CommandLine.arguments.contains("--snapshot") { IslandController.shared.start(store: store) }
                }
                .capturesSettingsOpener()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        .commands { WindowCommands() }
    }
}
