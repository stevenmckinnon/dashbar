import Foundation
import Testing
@testable import Dashbar

@Suite struct PlanHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    func fiveHour(_ used: Double, reset: Date, label: String = "5-hour") -> RateLimit {
        RateLimit(label: label, usedPercent: used, resetsAt: reset, window: 5 * 3600)
    }

    @Test func keepsOneSamplePerSlotWithTheHighestReading() {
        var h = PlanHistory()
        let reset = t0.addingTimeInterval(4 * hour)
        // Three readings inside one 10-minute slot, then one in the next.
        let slot = (t0.timeIntervalSince1970 / PlanHistory.bucket).rounded(.down) * PlanHistory.bucket
        let start = Date(timeIntervalSince1970: slot)
        let first = h.record([fiveHour(10, reset: reset)], provider: .claude, at: start.addingTimeInterval(30))
        let higher = h.record([fiveHour(14, reset: reset)], provider: .claude, at: start.addingTimeInterval(200))
        let again = h.record([fiveHour(14, reset: reset)], provider: .claude, at: start.addingTimeInterval(200))   // same reading again
        #expect(first && higher && !again)
        h.record([fiveHour(12, reset: reset)], provider: .claude, at: start.addingTimeInterval(400))
        h.record([fiveHour(20, reset: reset)], provider: .claude, at: start.addingTimeInterval(700))
        #expect(h.samples.count == 2)
        #expect(h.samples.map(\.used) == [14, 20])
    }

    @Test func ignoresPerModelWindowsAndReadingsAfterTheReset() {
        var h = PlanHistory()
        let reset = t0.addingTimeInterval(hour)
        h.record([RateLimit(label: "Weekly · Opus", usedPercent: 40, resetsAt: reset, window: 7 * 86400),
                  RateLimit(label: "Extra usage", usedPercent: 40, resetsAt: reset)], provider: .claude, at: t0)
        #expect(h.isEmpty)
        h.record([fiveHour(50, reset: t0)], provider: .claude, at: t0.addingTimeInterval(60))   // already reset
        #expect(h.isEmpty)
        h.record([RateLimit(label: "7d window", usedPercent: 3, resetsAt: reset, window: 7 * 86400)], provider: .codex, at: t0)
        #expect(h.samples.first?.series == .init(.codex, .weekly))
    }

    @Test func compactionFoldsOldReadingsIntoWindowsAndDropsAncientOnes() {
        var h = PlanHistory()
        // A window 20 days ago (peak 80) and one 100 days ago.
        for (daysAgo, peak) in [(20.0, 80.0), (100.0, 60.0)] {
            let start = t0.addingTimeInterval(-daysAgo * 86400)
            for step in 0...10 {
                h.record([fiveHour(peak * Double(step) / 10, reset: start.addingTimeInterval(5 * hour))], provider: .claude,
                         at: start.addingTimeInterval(Double(step) * 1200))
            }
        }
        h.record([fiveHour(5, reset: t0.addingTimeInterval(4 * hour))], provider: .claude, at: t0)
        h.compact(now: t0)
        #expect(h.samples.count == 1)                 // only the recent reading stays as a sample
        let windows = h.windows()
        #expect(windows.count == 2)                   // the 100-day-old window is gone
        #expect(windows.first?.peak == 80)
    }

    @Test func savedFileRoundTripsAndStaysCompact() throws {
        var h = PlanHistory()
        for i in 0..<50 {
            h.record([fiveHour(Double(i), reset: t0.addingTimeInterval(5 * hour))], provider: .claude, at: t0.addingTimeInterval(Double(i) * 600))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        h.save(to: url)
        let loaded = try #require(PlanHistory.load(from: url))
        #expect(loaded.samples == h.samples)
        #expect(try Data(contentsOf: url).count < 50 * 50)   // about 40 bytes a reading
    }

    @Test func eachAccountIsItsOwnSeries() {
        var h = PlanHistory()
        let reset = t0.addingTimeInterval(5 * hour)
        h.record([fiveHour(10, reset: reset)], provider: .claude, at: t0)
        h.record([fiveHour(70, reset: reset)], provider: .claude, account: "1a2b3c4d", at: t0)
        h.record([fiveHour(80, reset: reset)], provider: .claude, account: "1a2b3c4d", at: t0.addingTimeInterval(hour))
        let mine = PlanHistory.Series(.claude, .fiveHour), work = PlanHistory.Series(.claude, .fiveHour, account: "1a2b3c4d")
        #expect(h.current(mine, now: t0.addingTimeInterval(hour)).map(\.used) == [10])
        #expect(h.current(work, now: t0.addingTimeInterval(hour)).map(\.used) == [70, 80])
        let windows = h.windows()
        #expect(windows.count == 2)
        #expect(Set(windows.map(\.id)).count == 2)
        #expect(h.accounts(.claude) == [nil, "1a2b3c4d"])
        #expect(h.accounts(.codex).isEmpty)
    }

    @Test func otherAccountsAreSavedBesideTheDefaultFileWhichKeepsItsFormat() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = try fx.dir("support").appendingPathComponent("plan-history.json")
        // A file from before accounts: it is the default account's.
        let old = #"{"version":1,"samples":[["c5",1800000000,12.5,1800018000]],"windows":[]}"#
        try Data(old.utf8).write(to: url)
        var h = try #require(PlanHistory.load(from: url))
        #expect(h.samples.first?.series == .init(.claude, .fiveHour))
        h.record([fiveHour(40, reset: t0.addingTimeInterval(5 * hour))], provider: .claude, account: "1a2b3c4d", at: t0.addingTimeInterval(600))
        h.record([RateLimit(label: "7d window", usedPercent: 3, resetsAt: t0.addingTimeInterval(86400), window: 7 * 86400)],
                 provider: .codex, account: "99aa00ff", at: t0)
        h.save(to: url)

        // The default file holds only the default account, in the old compact form.
        let main = try String(contentsOf: url, encoding: .utf8)
        #expect(main.contains(#"["c5",1800000000,12.5,1800018000]"#))
        #expect(!main.contains("40"))
        let work = PlanHistory.url(for: "1a2b3c4d", base: url)
        #expect(work.lastPathComponent == "plan-history-1a2b3c4d.json")
        #expect(try String(contentsOf: work, encoding: .utf8).contains(#""c5""#))
        #expect(!(try String(contentsOf: work, encoding: .utf8).contains("1a2b3c4d")))

        let loaded = try #require(PlanHistory.load(from: url))
        #expect(Set(loaded.samples.map(\.series.account)) == [nil, "1a2b3c4d", "99aa00ff"])
        #expect(loaded.samples.first { $0.series.account == "1a2b3c4d" }?.used == 40)
        #expect(loaded.samples.first { $0.series.account == "99aa00ff" }?.series.provider == .codex)
        // Something else beside it is not an account.
        try Data(old.utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("plan-history-backup.json"))
        #expect(PlanHistory.load(from: url)?.samples.count == loaded.samples.count)
    }

    @Test func mergingAnotherCopysHistoryDoesNotDuplicate() {
        var a = PlanHistory(), b = PlanHistory()
        let reset = t0.addingTimeInterval(5 * hour)
        a.record([fiveHour(10, reset: reset)], provider: .claude, at: t0)
        b.record([fiveHour(10, reset: reset)], provider: .claude, at: t0)
        b.record([fiveHour(30, reset: reset)], provider: .claude, at: t0.addingTimeInterval(hour))
        a.merge(b, now: t0.addingTimeInterval(hour))
        #expect(a.samples.map(\.used) == [10, 30])
    }

    @Test func findsEachWindowsPeakIncludingAGapAndAnEarlyReset() {
        var h = PlanHistory()
        let reset1 = t0.addingTimeInterval(5 * hour)
        // Window 1: readings, a two-hour gap, then more readings with the same reset time: still one window.
        h.record([fiveHour(20, reset: reset1)], provider: .claude, at: t0.addingTimeInterval(600))
        h.record([fiveHour(45, reset: reset1)], provider: .claude, at: t0.addingTimeInterval(1800))
        h.record([fiveHour(70, reset: reset1)], provider: .claude, at: t0.addingTimeInterval(1800 + 2 * hour))
        // Reset early: an hour before reset1 a new window with a later reset time and low usage appears.
        let reset2 = reset1.addingTimeInterval(4 * hour)
        h.record([fiveHour(3, reset: reset2)], provider: .claude, at: reset1.addingTimeInterval(-hour))
        h.record([fiveHour(100, reset: reset2)], provider: .claude, at: reset1.addingTimeInterval(hour))
        // Codex reset times drift by seconds between readings: same window.
        h.record([fiveHour(8, reset: reset1, label: "5h window")], provider: .codex, at: t0)
        h.record([fiveHour(9, reset: reset1.addingTimeInterval(7), label: "5h window")], provider: .codex, at: t0.addingTimeInterval(900))

        let claude = h.windows().filter { $0.series.provider == .claude }
        #expect(claude.count == 2)
        #expect(claude[0].peak == 70)
        #expect(claude[0].endedEarly)
        #expect(!claude[0].hitLimit)
        #expect(claude[1].peak == 100 && claude[1].hitLimit)
        #expect(h.windows().filter { $0.series.provider == .codex }.count == 1)

        let s = h.summary(.init(.claude, .fiveHour), now: reset2.addingTimeInterval(60))
        #expect(s == .init(count: 2, hits: 1, near: 0, medianPeak: 85))
        // Before the second resets, only the first is finished; the current window holds the second's readings.
        let mid = reset1.addingTimeInterval(2 * hour)
        #expect(h.summary(.init(.claude, .fiveHour), now: mid).count == 1)
        #expect(h.current(.init(.claude, .fiveHour), now: mid).map(\.used) == [3, 100])
    }

    @Test func withoutResetTimesADropStartsANewWindow() {
        var h = PlanHistory()
        let limit = { (used: Double) in RateLimit(label: "5-hour", usedPercent: used, resetsAt: nil, window: 5 * 3600) }
        h.record([limit(30)], provider: .claude, at: t0)
        h.record([limit(60)], provider: .claude, at: t0.addingTimeInterval(hour))
        h.record([limit(5)], provider: .claude, at: t0.addingTimeInterval(2 * hour))
        #expect(h.windows().map(\.peak) == [60, 5])
    }
}

@Suite struct UsageHistoryTests {
    @Test func thirtyDaysOfTokensAndCostByDayWithTopProjectsAndModels() {
        var book = UsageBook()
        let now = Date()
        func add(_ daysAgo: Int, _ out: Int, model: String, project: String, cost: Double?) {
            let t = TokenTotals(output: out, messages: 1)
            book.add(t, at: now.addingTimeInterval(-Double(daysAgo) * 86_400), model: model, project: project, cost: cost)
        }
        add(0, 100, model: "Opus", project: "a", cost: 1.5)
        add(0, 50, model: "Sonnet", project: "b", cost: 0.25)
        add(2, 300, model: "Opus", project: "b", cost: 4)
        add(29, 10, model: "mystery", project: "a", cost: nil)
        add(31, 999, model: "Opus", project: "c", cost: 9)   // outside the 30 days

        let h = book.history(now: now)
        #expect(h.days.count == 30)
        #expect(h.days.last?.tokens == 150)
        #expect(abs((h.days.last?.cost ?? 0) - 1.75) < 1e-9)
        #expect(h.days[27].tokens == 300)
        #expect(h.days.first?.tokens == 10 && h.days.first?.cost == 0)
        #expect(h.totals.output == 460)
        #expect(abs(h.cost - 5.75) < 1e-9)
        #expect(h.projects.map(\.name) == ["b", "a"])
        #expect(h.projects.first?.value == 350)
        #expect(h.models.first?.name == "Opus" && h.models.first?.cost == 5.5)
        #expect(h.unpriced == ["mystery"])
        #expect(book.summary(found: true).history == h)
    }
}
