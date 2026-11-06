import SwiftUI
import AppKit

@main
struct DashbarApp: App {
    @StateObject private var store = Store()

    init() {
        // Belt-and-braces: hide the Dock icon even when run outside the .app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
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
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: Store
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let busy = store.busyCount
        HStack(spacing: 4) {
            Image(nsImage: BrandMark.menuBarImage(working: busy > 0))
            if let text = stats(busy: busy) {
                text.monospacedDigit()
            }
        }
    }

    /// Working agents first, then whichever stats the user turned on, each led by its symbol.
    private func stats(busy: Int) -> Text? {
        let s = store.system
        var parts: [Text] = []
        if busy > 0 { parts.append(Text("\(busy)")) }
        if settings.menuCPU {
            parts.append(Text("\(Image(systemName: "cpu")) \(Int((s.cpu * 100).rounded()))%"))
        }
        if settings.menuMemory {
            let used = Int((Double(s.memUsed) / Double(max(s.memTotal, 1)) * 100).rounded())
            parts.append(Text("\(Image(systemName: "memorychip")) \(used)%"))
        }
        if settings.menuNetwork {
            parts.append(Text("\(Image(systemName: "arrow.down")) \(Fmt.shortRate(s.netDown))"))
        }
        if settings.menuLimit, settings.claudeLimits, store.claudePlan?.problem == nil,
           let r = ClaudePlanLimits.menuBarReading(store.claudePlan?.limits ?? []) {
            parts.append(Text("\(Image(systemName: r.atRisk ? "exclamationmark.triangle.fill" : "gauge.with.needle")) \(r.name) \(r.leftPercent)% left"))
        }
        guard var text = parts.first else { return nil }
        for part in parts.dropFirst() { text = text + Text("  ") + part }
        return text
    }
}
