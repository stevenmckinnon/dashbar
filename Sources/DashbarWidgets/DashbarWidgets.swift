import SwiftUI
import WidgetKit
import AppKit
import os
import DashbarStatus
import DashbarWidgetUI

/// The widget extension (`Contents/PlugIns/DashbarWidgets.appex`). It runs sandboxed: it reads only the snapshot the app
/// saves in their shared App Group container, and sends nothing.
@main
struct DashbarWidgetBundle: WidgetBundle {
    var body: some Widget {
        LimitsWidget()
        OverviewWidget()
        UsageWidget()
        CodexLimitsWidget()
        AntigravityLimitsWidget()
        OpenCodeWidget()
        CopilotWidget()
    }
}

/// Every widget is a static configuration of its own kind: a configurable one needs App Intents, whose metadata only
/// Xcode's build generates. Each lists in the gallery for everyone; one for a tool someone doesn't use says so in words.
enum Gallery {
    /// A local build's extension says so (`DashbarLocalBuild` in its Info.plist), so its widgets read apart from the release's.
    static let isLocal = Bundle.main.object(forInfoDictionaryKey: WidgetStatus.localInfoKey) as? Bool == true

    static func description(_ text: String) -> Text {
        Text(isLocal ? text + " From the local build." : text)
    }

    static func background() -> some View { Color(nsColor: .windowBackgroundColor) }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.limits, provider: SnapshotProvider()) { entry in
            LimitsWidgetView(entry: entry).containerBackground(for: .widget) { Gallery.background() }
        }
        .configurationDisplayName("Claude plan limits")
        .description(Gallery.description("Claude's 5-hour and weekly limits, and when they reset."))
        .supportedFamilies([.systemSmall])
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.overview, provider: SnapshotProvider()) { entry in
            OverviewWidgetView(entry: entry).containerBackground(for: .widget) { Gallery.background() }
        }
        .configurationDisplayName("Plan limits and agents")
        .description(Gallery.description("Each tool's plan limits, and how many agents are working."))
        .supportedFamilies([.systemMedium])
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.usage, provider: SnapshotProvider()) { entry in
            UsageWidgetView(entry: entry).containerBackground(for: .widget) { Gallery.background() }
        }
        .configurationDisplayName("Tokens today")
        .description(Gallery.description("Each tool's tokens today, with the estimated cost at API prices."))
        .supportedFamilies([.systemMedium])
    }
}

struct CodexLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.codex, provider: SnapshotProvider()) { entry in
            ToolLimitsWidgetView(entry: entry, tool: .codex).containerBackground(for: .widget) { Gallery.background() }
        }
        .configurationDisplayName("Codex plan limits")
        .description(Gallery.description("Codex's 5-hour and weekly limits, and when they reset."))
        .supportedFamilies([.systemSmall])
    }
}

struct AntigravityLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.antigravity, provider: SnapshotProvider()) { entry in
            ToolLimitsWidgetView(entry: entry, tool: .antigravity).containerBackground(for: .widget) { Gallery.background() }
        }
        .configurationDisplayName("Antigravity plan limits")
        .description(Gallery.description("Antigravity's two tightest quota limits, and when they reset."))
        .supportedFamilies([.systemSmall])
    }
}

struct OpenCodeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.opencode, provider: SnapshotProvider()) { entry in
            ToolUsageWidgetView(entry: entry, tool: .opencode).containerBackground(for: .widget) { Gallery.background() }
        }
        .configurationDisplayName("OpenCode usage")
        .description(Gallery.description("OpenCode's tokens today and the model it used most."))
        .supportedFamilies([.systemSmall])
    }
}

struct CopilotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.copilot, provider: SnapshotProvider()) { entry in
            ToolUsageWidgetView(entry: entry, tool: .copilot).containerBackground(for: .widget) { Gallery.background() }
        }
        .configurationDisplayName("GitHub Copilot usage")
        .description(Gallery.description("GitHub Copilot's tokens and premium requests today."))
        .supportedFamilies([.systemSmall])
    }
}

struct SnapshotProvider: TimelineProvider {
    /// How often WidgetKit asks again when the app hasn't asked it to: often enough that a reset or a quit app shows.
    static let refresh: TimeInterval = 15 * 60
    private static let log = Logger(subsystem: "fun.dashbar.widgets", category: "timeline")

    func placeholder(in context: Context) -> DashbarWidgetEntry {
        DashbarWidgetEntry(date: Date(), snapshot: nil, running: false, local: Gallery.isLocal)
    }

    func getSnapshot(in context: Context, completion: @escaping (DashbarWidgetEntry) -> Void) {
        completion(Self.entry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DashbarWidgetEntry>) -> Void) {
        let now = Date()
        let entry = Self.entry(now: now)
        // Ask again at the next reset if it comes sooner, so a limit that has reset stops showing its old figure.
        let nextReset = entry.snapshot?.limits.flatMap(\.limits).compactMap(\.resetsAt).filter { $0 > now }.min()
        // And just after midnight, so "today" starts again from nothing rather than showing yesterday's tokens.
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        let next = [now.addingTimeInterval(Self.refresh), nextReset.map { $0.addingTimeInterval(5) },
                    midnight.map { $0.addingTimeInterval(5) }].compactMap { $0 }.min() ?? now.addingTimeInterval(Self.refresh)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func entry(now: Date) -> DashbarWidgetEntry {
        guard let group = Bundle.main.object(forInfoDictionaryKey: WidgetStatus.groupInfoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            log.info("no app group: showing no data")
            return DashbarWidgetEntry(date: now, snapshot: nil, running: false, local: Gallery.isLocal)
        }
        let snapshot = WidgetStatus.load(WidgetStatus.fileURL(container: container))
        let running = snapshot.map { isRunning(pid: $0.app.pid) } ?? false
        log.info("read snapshot: \(snapshot != nil, privacy: .public), app running: \(running, privacy: .public)")
        return DashbarWidgetEntry(date: now, snapshot: snapshot, running: running, local: Gallery.isLocal)
    }

    /// Whether the copy of Dashbar that owns this extension is running as `pid`. The app is this bundle's id without
    /// its last part (`fun.dashbar.app.local.widgets` belongs to `fun.dashbar.app.local`), so the release and a local
    /// build never vouch for each other.
    static func isRunning(pid: Int32) -> Bool {
        guard let id = Bundle.main.bundleIdentifier, let dot = id.lastIndex(of: ".") else { return false }
        let app = String(id[..<dot])
        return NSRunningApplication.runningApplications(withBundleIdentifier: app).contains { $0.processIdentifier == pid }
    }
}
