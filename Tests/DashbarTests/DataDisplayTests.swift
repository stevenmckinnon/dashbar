import Foundation
import Testing
@testable import Dashbar

/// The small charts and meters: what they draw for a given reading.
@Suite struct DataDisplayTests {
    @Test func metersDrawNothingAtZeroAndASliverForATinyShare() {
        #expect(Meter.width(0, in: 200) == 0)
        #expect(Meter.width(-0.2, in: 200) == 0)
        #expect(Meter.width(0.001, in: 200, minimum: 3) == 3)
        #expect(Meter.width(0.5, in: 200) == 100)
        #expect(Meter.width(1.4, in: 200) == 200)
        #expect(Meter.width(0.5, in: 0) == 0)
    }

    @Test func limitBarFillsWhatTheRowPrints() {
        #expect(LimitBar.shownFraction(0.4) == 0)      // printed "0% used": no fill
        #expect(LimitBar.shownFraction(0.6) == 0.01)   // printed "1% used": a sliver
        #expect(LimitBar.shownFraction(55) == 0.55)
        #expect(LimitBar.shownFraction(130) == 1)
    }

    @Test func limitBarTurnsAmberWhenRunningOutAndRedWhenNearlyUsedUp() {
        #expect(LimitBar.fillState(used: 40, pace: .onPace) == .normal)
        #expect(LimitBar.fillState(used: 40, pace: nil) == .normal)
        #expect(LimitBar.fillState(used: 70, pace: .runsOut(Date())) == .attention)
        #expect(LimitBar.fillState(used: 92, pace: .runsOut(Date())) == .problem)
        #expect(LimitBar.fillState(used: 100, pace: .usedUp) == .problem)
    }

    @Test func paceMarkOnlyWithAPaceReading() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 2% of a 5-hour window gone: too early for a pace reading, so no mark (it used to sit on the 0% stub).
        let early = RateLimit(label: "5-hour", usedPercent: 0, resetsAt: now.addingTimeInterval(0.98 * 5 * 3600), window: 5 * 3600)
        #expect(early.pace(now: now) == nil)
        #expect(early.paceMark(now: now) == nil)
        // Half the window gone: a reading, and the mark at 50%.
        let half = RateLimit(label: "5-hour", usedPercent: 20, resetsAt: now.addingTimeInterval(2.5 * 3600), window: 5 * 3600)
        #expect(half.pace(now: now) == .under)
        #expect(abs((half.paceMark(now: now) ?? 0) - 50) < 0.001)
        // No window or reset time: nothing to place a mark by.
        #expect(RateLimit(label: "Extra usage", usedPercent: 27, resetsAt: nil, window: nil).paceMark(now: now) == nil)
    }

    @Test func contextIsNeutralThenAmberThenRed() {
        #expect(ContextRing.level(0.15) == .fine)
        #expect(ContextRing.level(0.69) == .fine)
        #expect(ContextRing.level(0.70) == .filling)
        #expect(ContextRing.level(0.84) == .filling)
        #expect(ContextRing.level(0.85) == .nearlyFull)
    }

    @Test func sessionDotsMatchTheCountAndCapWithMore() {
        let few = SessionDots.layout(waiting: 1, working: 1, idle: 2)
        #expect(few.dots == [.waiting, .working, .idle, .idle])
        #expect(few.more == 0)
        #expect(SessionDots.layout(waiting: 0, working: 0, idle: 0).dots.isEmpty)
        #expect(SessionDots.layout(waiting: 0, working: 0, idle: 6).more == 0)
        // Past six, four dots and "+N", needs-you and working first so they're never the ones cut.
        let many = SessionDots.layout(waiting: 2, working: 3, idle: 5)
        #expect(many.dots == [.waiting, .waiting, .working, .working])
        #expect(many.more == 6)
        #expect(many.dots.count + many.more == 10)
    }

    @Test func sessionDotsSayTheCountsInWords() {
        #expect(SessionDots.label(waiting: 1, working: 1, idle: 2) == "Agents, 4 sessions: 1 needs you, 1 working, 2 idle")
        #expect(SessionDots.label(waiting: 0, working: 0, idle: 3) == "Agents, 3 sessions: 3 idle")
        #expect(SessionDots.label(waiting: 2, working: 0, idle: 0) == "Agents, 2 sessions: 2 need you")
        #expect(SessionDots.label(waiting: 0, working: 0, idle: 0) == "Agents, no sessions")
    }

    @Test func cleanupTileNamesTheLargestFolder() {
        let items = [
            CleanupItem(path: "/p/a/node_modules", kind: "node_modules", project: "storefront-web", size: 1_480_000_000),
            CleanupItem(path: "~/Library/Developer/Xcode/DerivedData", kind: "DerivedData", project: "Xcode", size: 2_300_000_000),
        ]
        #expect(TileRow.biggest(items)?.name == "Xcode")
        #expect(TileRow.biggest(items)?.size == 2_300_000_000)
        #expect(TileRow.biggest([]) == nil)
    }

    @Test func memoryLineScaleKeepsASmallDriftSmall() {
        // A 3% drift spans under a fifth of the height instead of all of it.
        let values = [1.08, 1.09, 1.10, 1.11]
        let d = Sparkbars.lineDomain(values)
        #expect((1.11 - 1.08) / (d.upperBound - d.lowerBound) < 0.2)
        // A big swing still uses the full height.
        let swing = Sparkbars.lineDomain([1, 4])
        #expect(swing == 1...4)
        #expect(Sparkbars.lineDomain([]) == 0...0)
        #expect(Sparkbars.lineDomain([0, 0]) == 0...0)
    }

    @Test func dayBarsLabelEachDayWithItsInitialInTheUsersLanguage() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        #expect(DayBars.initial(monday, locale: Locale(identifier: "en_US")) == "M")
        #expect(DayBars.initial(monday, locale: Locale(identifier: "fr_FR")).uppercased() == "L")
        #expect(DayBars.initial(monday, locale: Locale(identifier: "de_DE")) == "M")
    }
}
