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
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.limits, provider: SnapshotProvider()) { entry in
            LimitsWidgetView(entry: entry).containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Claude plan limits")
        .description("Claude's 5-hour and weekly limits, and when they reset.")
        .supportedFamilies([.systemSmall])
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStatus.Kind.overview, provider: SnapshotProvider()) { entry in
            OverviewWidgetView(entry: entry).containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Plan limits and agents")
        .description("Each tool's plan limits, and how many agents are working or waiting for you.")
        .supportedFamilies([.systemMedium])
    }
}

struct SnapshotProvider: TimelineProvider {
    /// How often WidgetKit asks again when the app hasn't asked it to: often enough that a reset or a quit app shows.
    static let refresh: TimeInterval = 15 * 60
    private static let log = Logger(subsystem: "fun.dashbar.widgets", category: "timeline")

    func placeholder(in context: Context) -> DashbarWidgetEntry {
        DashbarWidgetEntry(date: Date(), snapshot: nil, running: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (DashbarWidgetEntry) -> Void) {
        completion(Self.entry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DashbarWidgetEntry>) -> Void) {
        let now = Date()
        let entry = Self.entry(now: now)
        // Ask again at the next reset if it comes sooner, so a limit that has reset stops showing its old figure.
        let nextReset = entry.snapshot?.limits.flatMap(\.limits).compactMap(\.resetsAt).filter { $0 > now }.min()
        let next = min(now.addingTimeInterval(Self.refresh), nextReset.map { $0.addingTimeInterval(5) } ?? .distantFuture)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func entry(now: Date) -> DashbarWidgetEntry {
        guard let group = Bundle.main.object(forInfoDictionaryKey: WidgetStatus.groupInfoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            log.info("no app group: showing no data")
            return DashbarWidgetEntry(date: now, snapshot: nil, running: false)
        }
        let snapshot = WidgetStatus.load(WidgetStatus.fileURL(container: container))
        let running = snapshot.map { isRunning(pid: $0.app.pid) } ?? false
        log.info("read snapshot: \(snapshot != nil, privacy: .public), app running: \(running, privacy: .public)")
        return DashbarWidgetEntry(date: now, snapshot: snapshot, running: running)
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
