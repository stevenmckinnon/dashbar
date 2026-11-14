import Foundation

/// Invented history for the History page in screenshots: 30 days of usage and a month of plan windows that agree with
/// the demo's current limits. Built through the real `UsageBook` and `PlanHistory`, so the page shows what they compute.
@MainActor
extension DemoData {
    static func applyHistory(to store: Store, now: Date) {
        var rng = DemoRandom(seed: 7)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // Usage: the last 14 days match the usage card's chart; the 16 before are invented the same way.
        let recent = [38, 91, 64, 120, 87, 15, 6, 102, 133, 96, 148, 119, 141, 152]
        let earlier = [74, 58, 12, 4, 88, 109, 97, 126, 81, 9, 3, 66, 94, 118, 71, 22]
        let millions = earlier + recent
        let projects = [("storefront-web", 0.52), ("billing-api", 0.24), ("docs-site", 0.14), ("notes-ios", 0.10)]
        var claude = UsageBook(), codex = UsageBook()
        for (i, m) in millions.enumerated() {
            guard let day = cal.date(byAdding: .day, value: i - (millions.count - 1), to: today) else { continue }
            let noon = day.addingTimeInterval(13 * 3600)
            let total = Double(m) * 1_000_000
            for (project, share) in projects {
                let wobble = 0.8 + 0.4 * rng.next()
                for (model, id, part) in [("Opus 5.5", "claude-opus-5-5", 0.76), ("Sonnet 5.5", "claude-sonnet-5-5", 0.24)] {
                    let t = Self.split(total * share * wobble * part, messages: Int(total * share * part / 600_000))
                    claude.add(t, at: noon, model: model, project: project, cost: Pricing.cost(t, model: id, oneHourShare: 0.3))
                }
            }
            // Codex on about a third of the days, mostly in one project.
            if m > 60, rng.next() < 0.55 {
                let t = Self.split(total / 9 * (0.6 + 0.8 * rng.next()), messages: m / 4)
                let project = rng.next() < 0.7 ? "ml-notebooks" : "storefront-web"
                codex.add(t, at: noon, model: "gpt-5-codex", project: project, cost: Pricing.cost(t, model: "gpt-5-codex"))
            }
        }
        store.claude.history = claude.history(now: now)
        store.codex.history = codex.history(now: now)

        // Plan windows, ending in the demo's current readings.
        var history = PlanHistory()
        Self.simulate(&history, provider: .claude, now: now, days: millions, rng: &rng,
                      current5h: (55, now.addingTimeInterval(2.2 * 3600)), currentWeek: (38, now.addingTimeInterval(3.5 * 86400)),
                      windowsPerDay: 3, peakScale: 0.62)
        Self.simulate(&history, provider: .codex, now: now, days: millions, rng: &rng,
                      current5h: (21, now.addingTimeInterval(3.4 * 3600)), currentWeek: (34, now.addingTimeInterval(4.1 * 86400)),
                      windowsPerDay: 1, peakScale: 0.35)
        // DASHBAR_DEMO_ACCOUNTS=2: the Work account's Claude windows, as their own series.
        for other in store.claudeAccountLimits {
            let five = other.limits.first { PlanHistory.kind(of: $0) == .fiveHour }, week = other.limits.first { PlanHistory.kind(of: $0) == .weekly }
            guard let five, let week, let r5 = five.resetsAt, let rw = week.resetsAt else { continue }
            Self.simulate(&history, provider: .claude, now: now, days: millions.map { $0 * 3 / 2 }, rng: &rng,
                          current5h: (five.usedPercent, r5), currentWeek: (week.usedPercent, rw),
                          windowsPerDay: 2, peakScale: 0.6, account: AgentAccounts.hash(other.path))
        }
        // DASHBAR_DEMO_GOOGLE=1: Antigravity's model groups, each its own series, and Google's usage.
        for group in store.antigravityLimits?.groups ?? [] {
            let five = group.limits.first { PlanHistory.kind(of: $0) == .fiveHour }, week = group.limits.first { PlanHistory.kind(of: $0) == .weekly }
            guard let five, let week, let r5 = five.resetsAt, let rw = week.resetsAt else { continue }
            Self.simulate(&history, provider: .antigravity, now: now, days: millions.map { $0 / 2 }, rng: &rng,
                          current5h: (five.usedPercent, r5), currentWeek: (week.usedPercent, rw),
                          windowsPerDay: 1, peakScale: group.key == "gemini" ? 0.5 : 0.3, account: AntigravityLimits.historyKey(group.key))
        }
        if store.google.found {
            var google = UsageBook()
            for (i, m) in millions.enumerated() where m > 50 && rng.next() < 0.6 {
                guard let day = cal.date(byAdding: .day, value: i - (millions.count - 1), to: today) else { continue }
                let t = Self.split(Double(m) * 1_000_000 / 12, messages: m / 5)
                google.add(t, at: day.addingTimeInterval(15 * 3600), model: "gemini-3.8-flash", project: "docs-site",
                           cost: Pricing.cost(t, model: "gemini-3.8-flash"))
                let a = TokenTotals(input: m * 9_000, output: m * 2_500, messages: m / 8)
                google.add(a, at: day.addingTimeInterval(16 * 3600), model: "Gemini 4 Argon (Medium)", project: "ml-notebooks",
                           cost: Double(m) * 0.012)
            }
            store.google.history = google.history(now: now)
        }
        history.compact(now: now)
        store.planHistory = history
    }

    /// Tokens shaped like real agent use: almost all cache reads.
    private static func split(_ total: Double, messages: Int) -> TokenTotals {
        TokenTotals(input: Int(total * 0.008), output: Int(total * 0.0044), cacheRead: Int(total * 0.9706),
                    cacheWrite: Int(total * 0.017), messages: max(1, messages))
    }

    /// Readings every 10 minutes through each 5-hour window on busy days; the weekly window rises with them.
    private static func simulate(_ history: inout PlanHistory, provider: PlanHistory.Provider, now: Date, days: [Int],
                                 rng: inout DemoRandom, current5h: (Double, Date), currentWeek: (Double, Date),
                                 windowsPerDay: Int, peakScale: Double, account: String? = nil) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let fiveHours = PlanHistory.Kind.fiveHour.length, week = PlanHistory.Kind.weekly.length

        // Past 5-hour windows: (start, peak) for each, on days with real use.
        var windows: [(start: Date, peak: Double)] = []
        var lastEnd = Date.distantPast
        for (i, m) in days.enumerated().dropLast() where m > 20 {
            guard let day = cal.date(byAdding: .day, value: i - (days.count - 1), to: today) else { continue }
            for w in 0..<windowsPerDay {
                let start = max(lastEnd, day.addingTimeInterval(Double(9 + w * 5) * 3600 + rng.next() * 1800))
                guard rng.next() < 0.85 || w == 0 else { continue }
                lastEnd = start.addingTimeInterval(fiveHours)
                var peak = min(100, Double(m) * peakScale * (0.55 + 0.6 * rng.next()))
                if peak > 88 && rng.next() < 0.5 { peak = 100 }   // now and then, the limit
                windows.append((start, max(6, peak)))
            }
        }
        let currentStart = current5h.1.addingTimeInterval(-fiveHours)
        windows = windows.filter { $0.start.addingTimeInterval(fiveHours) <= currentStart }

        // Weekly windows reset on the same weekday and time as the current one.
        func weekReset(for date: Date) -> Date {
            var reset = currentWeek.1
            while reset.addingTimeInterval(-week) > date { reset.addTimeInterval(-week) }
            return reset
        }
        func limits(_ used5: Double, _ reset5: Date, _ usedW: Double, _ resetW: Date) -> [RateLimit] {
            [RateLimit(label: "5-hour", usedPercent: used5, resetsAt: reset5, window: fiveHours),
             RateLimit(label: "Weekly", usedPercent: usedW, resetsAt: resetW, window: week)]
        }

        // Each week's 5-hour peaks add up to that week's peak; the current week ends at its current reading.
        var byWeek: [Date: [(start: Date, peak: Double)]] = [:]
        for w in windows { byWeek[weekReset(for: w.start), default: []].append(w) }
        var weekTarget: [Date: Double] = [:]
        for (reset, ws) in byWeek {
            weekTarget[reset] = reset == currentWeek.1 ? 0 : min(100, (48 + 40 * rng.next() + (ws.count > 12 ? 12 : 0)) * (provider == .claude ? 1 : 0.55))
        }
        let currentWeekPast = (byWeek[currentWeek.1] ?? []).reduce(0) { $0 + $1.peak }
        let currentWeekScale = currentWeek.0 / max(1, currentWeekPast + current5h.0)

        var weekUsed: [Date: Double] = [:]
        func run(start: Date, peak: Double, until end: Date, scale: Double, resetW: Date) {
            let active = 0.55 + 0.4 * rng.next()
            let base = weekUsed[resetW] ?? 0
            var t = start.addingTimeInterval(600)
            let stop = min(end, start.addingTimeInterval(fiveHours * active))
            while t <= stop {
                let f = t.timeIntervalSince(start) / stop.timeIntervalSince(start)
                let used = min(100, peak * min(1, pow(f, 0.9) * (peak >= 100 ? 1.15 : 1)))
                history.record(limits(used, start.addingTimeInterval(fiveHours), min(100, base + used * scale), resetW),
                               provider: provider, account: account, at: t)
                t.addTimeInterval(600)
            }
            weekUsed[resetW] = base + peak * scale
        }
        for w in windows.sorted(by: { $0.start < $1.start }) {
            let resetW = weekReset(for: w.start)
            let scale = resetW == currentWeek.1
                ? currentWeekScale
                : (weekTarget[resetW] ?? 0) / max(1, (byWeek[resetW] ?? []).reduce(0) { $0 + $1.peak })
            run(start: w.start, peak: w.peak, until: w.start.addingTimeInterval(fiveHours), scale: scale, resetW: resetW)
        }
        // The window in progress: readings up to now, ending exactly at the current figures.
        let base = weekUsed[currentWeek.1] ?? 0
        var t = currentStart.addingTimeInterval(900)
        while t < now {
            let f = t.timeIntervalSince(currentStart) / now.timeIntervalSince(currentStart)
            let used = current5h.0 * min(1, f + 0.08 * sin(f * 9))
            history.record(limits(max(0, used), current5h.1, base + (currentWeek.0 - base) * f, currentWeek.1), provider: provider, account: account, at: t)
            t.addTimeInterval(600)
        }
        history.record(limits(current5h.0, current5h.1, currentWeek.0, currentWeek.1), provider: provider, account: account, at: now.addingTimeInterval(-40))
    }
}

/// A small fixed-seed generator, so every demo render looks the same.
struct DemoRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    /// 0..<1
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
