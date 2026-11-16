import Foundation
import WidgetKit
import DashbarStatus

/// One moment of a Dashbar widget: the snapshot the app last saved (nil before it has saved one) and whether the copy
/// of Dashbar that saved it is still running.
public struct DashbarWidgetEntry: TimelineEntry, Sendable {
    public var date: Date
    public var snapshot: StatusSnapshot?
    public var running: Bool

    public init(date: Date, snapshot: StatusSnapshot?, running: Bool) {
        self.date = date
        self.snapshot = snapshot
        self.running = running
    }
}

/// What a widget shows, worked out from an entry. Kept apart from the views so it can be tested.
public struct WidgetModel: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        /// The app has never saved a snapshot here (never run, an ad-hoc build without an App Group, or a fresh install).
        case noData
        /// Figures from a copy that has since quit: shown dimmed, with when they were read.
        case notRunning(lastSeen: Date)
        case live
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        /// "claude", "codex" or "antigravity": picks the colour.
        public var provider: String
        /// "Claude", "Claude · Work", "Codex", "Antigravity".
        public var name: String
        public var plan: String?
        /// The app's words for why there are no limits (a sign-in to renew), shown in place of the bars.
        public var problem: String?
        public var limits: [StatusSnapshot.Limit]
        /// The reading was kept from an earlier one because the latest failed.
        public var stale: Bool
        public var readAt: Date?
    }

    public var availability: Availability
    public var rows: [Row]
    public var agents: StatusSnapshot.AgentCounts?
    public var paused: Bool
    public var warning: String?

    /// `limitsPerRow` keeps a row to its tightest limits (the medium widget has room for two).
    public init(entry: DashbarWidgetEntry, limitsPerRow: Int = 2) {
        guard let snapshot = entry.snapshot else {
            self.availability = .noData
            self.rows = []
            self.agents = nil
            self.paused = false
            self.warning = nil
            return
        }
        availability = entry.running ? .live : .notRunning(lastSeen: snapshot.generatedAt)
        agents = entry.running ? snapshot.agents : nil
        paused = snapshot.app.paused
        warning = snapshot.warning
        let named: [String: Int] = snapshot.limits.reduce(into: [:]) { $0[$1.provider, default: 0] += 1 }
        rows = snapshot.limits.enumerated().map { index, group in
            let base = Self.providerName(group.provider)
            let name = (named[group.provider] ?? 0) > 1 ? group.account.map { "\(base) · \($0)" } ?? base : base
            return Row(id: "\(index):\(group.provider)", provider: group.provider, name: name, plan: group.plan,
                       problem: group.problem,
                       limits: Self.shown(group.limits, now: entry.date, count: limitsPerRow),
                       stale: group.stale, readAt: group.readAt)
        }
    }

    /// The first Claude account's row, for the small widget.
    public var claude: Row? { rows.first { $0.provider == "claude" } }

    public static func providerName(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "antigravity": return "Antigravity"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// The limits a row shows, at most `count`: windowed limits (the 5-hour and weekly ones) before Claude's extra usage,
    /// and when there are more than fit, the most used, kept in the snapshot's order. A limit whose window has reset since
    /// the reading stays, so the row can say so rather than show an old figure.
    static func shown(_ limits: [StatusSnapshot.Limit], now: Date, count: Int) -> [StatusSnapshot.Limit] {
        let windowed = limits.filter(\.isWindowed)
        let pool = (windowed.isEmpty ? limits : windowed).map { $0.withPace(now: now) }
        guard pool.count > count else { return pool }
        let keep = Set(pool.indices.sorted { pool[$0].usedPercent > pool[$1].usedPercent || (pool[$0].usedPercent == pool[$1].usedPercent && $0 < $1) }
            .prefix(count))
        return pool.indices.filter(keep.contains).map { pool[$0] }
    }

    /// How a bar is coloured: the provider's colour, amber on course to run out, red at 90% or more.
    public enum Fill: Equatable, Sendable { case provider, attention, problem }

    public static func fill(_ limit: StatusSnapshot.Limit) -> Fill {
        let used = min(max(limit.usedPercent, 0), 100)
        if used >= 90 || limit.pace == .usedUp { return .problem }
        if limit.pace == .runsOut { return .attention }
        return .provider
    }

    /// "5-hour", "Weekly": the window's name when known, else the app's label.
    public static func title(_ limit: StatusSnapshot.Limit) -> String { limit.window ?? limit.label }

    /// "55%", rounded as the panel rounds it.
    public static func percent(_ limit: StatusSnapshot.Limit) -> String { "\(Int(min(max(limit.usedPercent, 0), 999).rounded()))%" }

    /// When it resets, as a clock time (so it stays right between refreshes): "14:20" today, "Thu 09:00" within the week,
    /// "3 Dec" beyond.
    public static func resetText(_ date: Date, now: Date, locale: Locale = .autoupdatingCurrent,
                                 timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(style.hour().minute()) }
        if date.timeIntervalSince(now) < 6 * 86400 { return date.formatted(style.weekday(.abbreviated).hour().minute()) }
        return date.formatted(style.day().month(.abbreviated))
    }
}
