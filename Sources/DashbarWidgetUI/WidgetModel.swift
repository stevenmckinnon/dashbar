import Foundation
import WidgetKit
import DashbarStatus

/// One moment of a Dashbar widget: the snapshot the app last saved (nil before it has saved one) and whether the copy
/// of Dashbar that saved it is still running.
public struct DashbarWidgetEntry: TimelineEntry, Sendable {
    public var date: Date
    public var snapshot: StatusSnapshot?
    public var running: Bool
    /// The widget belongs to a local build (`Dashbar Local`), so its header says "Local". Offline renders leave it out.
    public var local: Bool

    public init(date: Date, snapshot: StatusSnapshot?, running: Bool, local: Bool = false) {
        self.date = date
        self.snapshot = snapshot
        self.running = running
        self.local = local
    }
}

/// The tools a widget of its own can show. Claude, Codex and Antigravity have plan limits; OpenCode and GitHub Copilot
/// only usage.
public enum WidgetTool: String, CaseIterable, Sendable {
    case claude, codex, antigravity, opencode, copilot

    /// What the widget calls it: "OpenCode" and "GitHub Copilot" exactly.
    public var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .copilot: return "GitHub Copilot"
        }
    }

    /// Its id in the snapshot's limits (`LimitGroup.provider`), and the colour it takes.
    public var provider: String { rawValue }
    /// Its id in `usageTotals`: Antigravity's tokens count with the Gemini CLI's, under "google".
    public var usageID: String { self == .antigravity ? "google" : rawValue }
    public var hasLimits: Bool { [.claude, .codex, .antigravity].contains(self) }
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
    /// The Show in Dashbar switches that are off ("codex", "google", "opencode", "copilot").
    public var hidden: Set<String>
    /// Each tool's totals for today, in the snapshot's order. Nil when the snapshot has none, or only another day's
    /// (a snapshot from before midnight is never shown as today's).
    public var today: [StatusSnapshot.ToolTotal]?
    /// The tools the snapshot counts usage for at all: the ones with logs.
    public var usageTools: Set<String>
    public var local: Bool

    /// `limitsPerRow` keeps a row to its tightest limits (the medium widget has room for two).
    public init(entry: DashbarWidgetEntry, limitsPerRow: Int = 2) {
        local = entry.local
        guard let snapshot = entry.snapshot else {
            self.availability = .noData
            self.rows = []
            self.agents = nil
            self.paused = false
            self.warning = nil
            self.hidden = []
            self.today = nil
            self.usageTools = []
            return
        }
        hidden = Set(snapshot.hidden ?? [])
        usageTools = Set(snapshot.usageTotals?.tools.map(\.tool) ?? [])
        today = snapshot.usageTotals.flatMap { $0.day == StatusSnapshot.dayKey(entry.date) ? $0.tools : nil }
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
    public var claude: Row? { row(.claude) }

    /// The first account's row of `tool`, for its small widget.
    public func row(_ tool: WidgetTool) -> Row? { rows.first { $0.provider == tool.provider } }

    /// Whether `tool` is switched off in Dashbar (Settings, Integrations, Show in Dashbar).
    public func hides(_ tool: WidgetTool) -> Bool { hidden.contains(StatusSnapshot.switchID(tool.provider)) }

    /// `tool`'s totals today: nil when it has none (no logs, or nothing since midnight).
    public func today(_ tool: WidgetTool) -> StatusSnapshot.ToolTotal? {
        today?.first { $0.tool == tool.usageID && $0.total > 0 }
    }

    /// What a tool's own widget says in place of its figures, or nil when it has figures to show. Never a blank, and
    /// never a zero that could pass for a reading.
    public func message(_ tool: WidgetTool) -> String? {
        if availability == .noData {
            return tool.hasLimits ? "Open Dashbar to see your \(tool.name) plan limits here."
                                  : "Open Dashbar to see \(tool.name)'s usage here."
        }
        if hides(tool) { return "\(tool.name) is switched off in Dashbar." }
        if tool.hasLimits {
            guard let row = row(tool) else {
                switch tool {
                case .claude: return "No Claude plan limits. Dashbar shows them once they're set up in its Settings."
                case .codex:
                    return usageTools.contains("codex") ? "No Codex plan limits yet. Codex reports them as you use it."
                                                        : "No Codex usage yet."
                default:
                    return "No Antigravity plan limits yet. They come from the Antigravity CLI's status line, added in Dashbar's Settings."
                }
            }
            if let problem = row.problem { return problem }
            if row.limits.isEmpty { return "No \(tool.name) plan limits reported." }
            return nil
        }
        if !usageTools.contains(tool.usageID) { return "No \(tool.name) usage yet." }
        if today(tool) == nil { return "No \(tool.name) usage today." }
        return nil
    }

    /// The tools the usage widget lists: each with tokens today, in the snapshot's order (Claude Code, Codex, Google's,
    /// OpenCode, GitHub Copilot).
    public var usageRows: [StatusSnapshot.ToolTotal] {
        (today ?? []).filter { $0.total > 0 && !hidden.contains(StatusSnapshot.switchID($0.tool)) }
    }

    /// What the usage widget calls a tool: the Usage tab's card titles.
    public static func usageName(_ total: StatusSnapshot.ToolTotal) -> String {
        switch total.tool {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "copilot": return "GitHub Copilot"
        default: return total.name
        }
    }

    /// "12.4M", "830K", "1.14B": the app's token figures (`Fmt.tokens`).
    public static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 100_000_000_000_000...: return String(format: "%.0fT", d / 1e12)
        case 10_000_000_000_000...: return String(format: "%.1fT", d / 1e12)
        case 1_000_000_000_000...: return String(format: "%.2fT", d / 1e12)
        case 100_000_000_000...: return String(format: "%.0fB", d / 1e9)
        case 10_000_000_000...: return String(format: "%.1fB", d / 1e9)
        case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
        case 10_000_000...: return String(format: "%.0fM", d / 1e6)
        case 1_000_000...: return String(format: "%.1fM", d / 1e6)
        case 10_000...: return String(format: "%.0fK", d / 1e3)
        case 1_000...: return String(format: "%.1fK", d / 1e3)
        default: return "\(max(0, n))"
        }
    }

    /// "$0.42", "$12.40", "$1,240", "<$0.01": the app's cost figures (`Fmt.usd`).
    public static func usd(_ d: Double) -> String {
        if d <= 0 { return "$0" }
        if d < 0.01 { return "<$0.01" }
        if d < 100 { return String(format: "$%.2f", d) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: d.rounded())) ?? String(Int(d.rounded())))
    }

    /// "12 premium requests today", nil for none: Copilot saves the count when a session ends, so a zero mid-session
    /// means "not known yet", as the app's Usage card treats it.
    public static func premiumLine(_ n: Double?) -> String? {
        guard let n, n > 0 else { return nil }
        let figure = n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
        return "\(figure) premium request\(n == 1 ? "" : "s") today"
    }

    /// The small Antigravity widget's names for its limits: each by its quota group ("Gemini", "Claude and GPT"), as the
    /// medium widget names them, or by its window when it has none. Two that would read the same keep their whole label.
    public static func groupTitles(_ limits: [StatusSnapshot.Limit]) -> [String] {
        let base = limits.map { qualifier($0) ?? title($0) }
        return limits.indices.map { i in base.filter { $0 == base[i] }.count > 1 ? limits[i].label : base[i] }
    }

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

    /// What a limit's name says besides its window: its quota group ("Gemini" in "Gemini · Weekly", Antigravity's
    /// grouped limits as the app names them) or its model ("Opus" in Claude's "Weekly · Opus"). Nil when there is none.
    public static func qualifier(_ limit: StatusSnapshot.Limit) -> String? {
        let parts = limit.label.components(separatedBy: " · ")
        guard parts.count > 1 else { return nil }
        let rest = parts.filter { $0 != limit.window }
        return rest.count < parts.count && !rest.isEmpty ? rest.joined(separator: " · ") : nil
    }

    /// The names a row prints for its limits, one each, so no two read the same. Each is its window's name (`short`:
    /// "5h", "wk", as `dashbar line` prints it; else "5-hour", "Weekly"); where two would share one, as Antigravity's
    /// weekly limits for two quota groups do, each is named by what else its label says instead: the medium widget
    /// prints the group ("Gemini", "Claude and GPT") and keeps the reset time beside it, the small one the whole label.
    public static func titles(_ limits: [StatusSnapshot.Limit], short: Bool) -> [String] {
        let base = limits.map { short ? StatusFormat.shortWindow($0) : title($0) }
        return limits.indices.map { i in
            guard base.filter({ $0 == base[i] }).count > 1 else { return base[i] }
            if short, let q = qualifier(limits[i]) { return q }
            return limits[i].label
        }
    }

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
