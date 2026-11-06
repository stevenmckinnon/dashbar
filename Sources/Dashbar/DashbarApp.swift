import SwiftUI
import AppKit

@main
struct DashbarApp: App {
    @StateObject private var store = Store()

    init() {
        // Belt-and-braces: hide the Dock icon even when run outside the .app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
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
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        let busy = store.busyCount
        if busy > 0 {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                Text("\(busy)")
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }
}
