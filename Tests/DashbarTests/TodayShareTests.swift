import Foundation
import Testing
@testable import Dashbar
import DashbarStatus

@Suite struct TodayShareTests {
    /// A fixed zone so midnight is the same wherever the tests run.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let cal = TodayShareTests.utc
    let day: TimeInterval = 86400
    let hour: TimeInterval = 3600
    let week: TimeInterval = 7 * 86400

    /// Saturday 21 November 2026, 00:00 UTC.
    var midnight: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 21))! }

    func weekly(_ used: Double, reset: Date, label: String = "Weekly") -> RateLimit {
        RateLimit(label: label, usedPercent: used, resetsAt: reset, window: week)
    }

    func sample(_ used: Double, at: Date, reset: Date?) -> PlanHistory.Sample {
        PlanHistory.Sample(series: .init(.claude, .weekly), at: at, used: used, resetsAt: reset)
    }

    @Test func midWeekSpreadsWhatWasLeftAtMidnightOverTheDaysLeft() throws {
        let now = midnight.addingTimeInterval(14 * hour)
        let reset = midnight.addingTimeInterval(4 * day)          // four days from midnight
        let samples = [sample(20, at: midnight.addingTimeInterval(-6 * hour), reset: reset),
                       sample(32, at: midnight.addingTimeInterval(-10 * 60), reset: reset),   // the last before midnight
                       sample(35, at: midnight.addingTimeInterval(9 * hour), reset: reset)]
        let s = try #require(TodayShare.compute(weekly(38, reset: reset), samples: samples, now: now, calendar: cal))
        #expect(s.startOfDay == 32)
        #expect(s.share == 17)                                     // 68% left over 4 days
        #expect(s.usedToday == 6)
        #expect(s.mark == 49)
        #expect(!s.reached && !s.over)
        #expect(s.caption(pace: .onPace, now: now) == "Today 6% of about 17% · lasts until it resets")
        #expect(s.caption(pace: nil, now: now) == "Today 6% of about 17%")
    }

    @Test func partDaysCountAsFractions() throws {
        let now = midnight.addingTimeInterval(10 * hour)
        let reset = midnight.addingTimeInterval(2.5 * day)
        let s = try #require(TodayShare.compute(weekly(50, reset: reset), samples: [sample(50, at: midnight, reset: reset)],
                                                now: now, calendar: cal))
        #expect(s.share == 20)                                     // 50% over 2.5 days
    }

    @Test func staysFixedAsTheDayIsUsed() throws {
        let reset = midnight.addingTimeInterval(4 * day)
        let samples = [sample(32, at: midnight.addingTimeInterval(-hour), reset: reset)]
        let morning = try #require(TodayShare.compute(weekly(33, reset: reset), samples: samples,
                                                      now: midnight.addingTimeInterval(8 * hour), calendar: cal))
        let evening = try #require(TodayShare.compute(weekly(60, reset: reset), samples: samples,
                                                      now: midnight.addingTimeInterval(20 * hour), calendar: cal))
        #expect(morning.share == evening.share)
        #expect(evening.usedToday == 28)
    }

    @Test func resetLaterTodayLeavesEverything() throws {
        let now = midnight.addingTimeInterval(9 * hour)
        let reset = midnight.addingTimeInterval(18 * hour)
        let s = try #require(TodayShare.compute(weekly(80, reset: reset), samples: [sample(70, at: midnight.addingTimeInterval(-hour), reset: reset)],
                                                now: now, calendar: cal))
        #expect(s.share == 30)                                     // under a day left: all that's left
        #expect(s.usedToday == 10)
    }

    @Test func windowThatBeganTodayStartsAtZero() throws {
        let now = midnight.addingTimeInterval(15 * hour)
        let reset = midnight.addingTimeInterval(10 * hour + week)   // began at 10:00 today
        // A reading from the window before (another reset time) must not count.
        let samples = [sample(95, at: midnight.addingTimeInterval(-hour), reset: midnight.addingTimeInterval(10 * hour)),
                       sample(4, at: midnight.addingTimeInterval(12 * hour), reset: reset)]
        let s = try #require(TodayShare.compute(weekly(8, reset: reset), samples: samples, now: now, calendar: cal))
        #expect(s.startOfDay == 0)
        #expect(s.usedToday == 8)
        #expect(abs(s.share - 100 / (7 + 10.0 / 24)) < 0.001)
    }

    @Test func noReadingsAtAllStartsTheDayNow() throws {
        let reset = midnight.addingTimeInterval(3 * day)
        let s = try #require(TodayShare.compute(weekly(40, reset: reset), samples: [], now: midnight.addingTimeInterval(12 * hour), calendar: cal))
        #expect(s.startOfDay == 40)
        #expect(s.usedToday == 0)
        #expect(s.share == 20)
    }

    @Test func onlyReadingsAfterMidnightUseTheFirstOfThem() throws {
        let reset = midnight.addingTimeInterval(3 * day)
        let samples = [sample(41, at: midnight.addingTimeInterval(11 * hour), reset: reset),
                       sample(44, at: midnight.addingTimeInterval(9 * hour), reset: reset),   // any order
                       sample(50, at: midnight.addingTimeInterval(13 * hour), reset: nil)]
        let s = try #require(TodayShare.compute(weekly(52, reset: reset), samples: samples, now: midnight.addingTimeInterval(14 * hour), calendar: cal))
        #expect(s.startOfDay == 44)
        #expect(s.usedToday == 8)
    }

    @Test func readingsAfterNowAreIgnored() throws {
        let reset = midnight.addingTimeInterval(3 * day)
        let samples = [sample(30, at: midnight.addingTimeInterval(-hour), reset: reset),
                       sample(10, at: midnight.addingTimeInterval(20 * hour), reset: reset)]
        let s = try #require(TodayShare.compute(weekly(35, reset: reset), samples: samples, now: midnight.addingTimeInterval(8 * hour), calendar: cal))
        #expect(s.startOfDay == 30)
    }

    @Test func overTheShare() throws {
        let now = midnight.addingTimeInterval(16 * hour)
        let reset = midnight.addingTimeInterval(4 * day)
        let s = try #require(TodayShare.compute(weekly(42, reset: reset), samples: [sample(16, at: midnight, reset: reset)], now: now, calendar: cal))
        #expect(s.share == 21)
        #expect(s.usedToday == 26)
        #expect(s.reached && s.over)
        #expect(s.caption(pace: .onPace, now: now) == "Today 26%, over today's 21% · lasts until it resets")
        #expect(s.spoken.contains("over today's share of 21 percent"))
    }

    @Test func atTheShareReadsAsUnder() throws {
        let reset = midnight.addingTimeInterval(4 * day)
        let s = try #require(TodayShare.compute(weekly(37.2, reset: reset), samples: [sample(16, at: midnight, reset: reset)],
                                                now: midnight.addingTimeInterval(16 * hour), calendar: cal))
        #expect(s.reached)
        #expect(!s.over)
        #expect(s.caption(pace: nil) == "Today 21% of about 21%")
    }

    @Test func usedUpHasNoShareLeft() throws {
        let reset = midnight.addingTimeInterval(2 * day)
        let s = try #require(TodayShare.compute(weekly(100, reset: reset), samples: [sample(100, at: midnight.addingTimeInterval(-hour), reset: reset)],
                                                now: midnight.addingTimeInterval(9 * hour), calendar: cal))
        #expect(s.share == 0)
        #expect(s.usedToday == 0)
        #expect(s.caption(pace: .usedUp) == "Today 0% of about 0% · used up until it resets")
    }

    @Test func aReadingThatDroppedNeverGoesBelowZero() throws {
        let reset = midnight.addingTimeInterval(3 * day)
        let s = try #require(TodayShare.compute(weekly(20, reset: reset), samples: [sample(25, at: midnight.addingTimeInterval(-hour), reset: reset)],
                                                now: midnight.addingTimeInterval(9 * hour), calendar: cal))
        #expect(s.usedToday == 0)
    }

    @Test func onlyWeeklyOrLongerLimitsWithAReset() {
        let now = midnight.addingTimeInterval(9 * hour)
        let five = RateLimit(label: "5-hour", usedPercent: 40, resetsAt: now.addingTimeInterval(2 * hour), window: 5 * 3600)
        let extra = RateLimit(label: "Extra usage", usedPercent: 27, resetsAt: nil, window: nil)
        let noReset = RateLimit(label: "Weekly", usedPercent: 27, resetsAt: nil, window: week)
        let monthly = RateLimit(label: "Monthly", usedPercent: 10, resetsAt: now.addingTimeInterval(20 * day), window: 30 * day)
        #expect(TodayShare.compute(five, samples: [], now: now, calendar: cal) == nil)
        #expect(TodayShare.compute(extra, samples: [], now: now, calendar: cal) == nil)
        #expect(TodayShare.compute(noReset, samples: [], now: now, calendar: cal) == nil)
        #expect(TodayShare.compute(weekly(30, reset: now.addingTimeInterval(-60)), samples: [], now: now, calendar: cal) == nil)   // reset already
        #expect(TodayShare.compute(monthly, samples: [], now: now, calendar: cal) != nil)
        #expect(!TodayShare.applies(to: five) && TodayShare.applies(to: monthly))
    }

    @Test func midnightFollowsTheLocalCalendarOnAClockChangeDay() throws {
        // Sunday 1 November 2026: US clocks go back an hour at 02:00, so the day is 25 hours long.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let localMidnight = ny.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let now = localMidnight.addingTimeInterval(12 * hour)
        let reset = localMidnight.addingTimeInterval(3 * day)
        let samples = [sample(30, at: localMidnight.addingTimeInterval(-60), reset: reset),
                       sample(33, at: localMidnight.addingTimeInterval(60), reset: reset)]
        let s = try #require(TodayShare.compute(weekly(36, reset: reset), samples: samples, now: now, calendar: ny))
        #expect(s.startOfDay == 30)
        #expect(abs(s.share - 70.0 / 3) < 0.001)
        #expect(s.usedToday == 6)
    }

    @Test func paceTailsReadAfterTheShare() {
        #expect(TodayShare.paceTail(.under) == "plenty left at this rate")
        #expect(TodayShare.paceTail(.onPace) == "lasts until it resets")
        #expect(TodayShare.paceTail(.usedUp) == "used up until it resets")
        let now = Date()
        #expect(TodayShare.paceTail(.runsOut(now.addingTimeInterval(60)), now: now).hasPrefix("runs out "))
    }

    // MARK: The alert

    func share(_ used: Double, start: Double, reset: Date, now: Date) -> (limit: RateLimit, share: TodayShare?) {
        let l = weekly(used, reset: reset)
        return (l, TodayShare.compute(l, samples: [sample(start, at: midnight.addingTimeInterval(-60), reset: reset)], now: now, calendar: cal))
    }

    @Test func alertsOncePerLimitPerDayWhenTheShareIsReached() {
        let now = midnight.addingTimeInterval(15 * hour)
        let reset = midnight.addingTimeInterval(4 * day)
        #expect(TodayShareAlerts.check(provider: "Claude", limits: [share(40, start: 32, reset: reset, now: now)], sent: [],
                                       limitAlertsSent: [], now: now, calendar: cal).isEmpty)   // 8% of 17%
        let first = TodayShareAlerts.check(provider: "Claude", limits: [share(50, start: 32, reset: reset, now: now)], sent: [],
                                           limitAlertsSent: [], now: now, calendar: cal)
        #expect(first.count == 1)
        #expect(first.first?.title == "Claude Weekly")
        #expect(first.first?.body == "You've used today's share (17%). Going on is fine; tomorrow's share will be smaller.")
        #expect(first.first?.key == "Claude|Weekly|2026-11-21")
        #expect(first.first?.claimKey.contains("Claude") == false)
        let again = TodayShareAlerts.check(provider: "Claude", limits: [share(55, start: 32, reset: reset, now: now)],
                                           sent: Set(first.map(\.key)), limitAlertsSent: [], now: now, calendar: cal)
        #expect(again.isEmpty)
        // The next day is news again.
        let tomorrow = now.addingTimeInterval(day)
        let next = TodayShareAlerts.check(provider: "Claude", limits: [share(90, start: 55, reset: reset, now: tomorrow)],
                                          sent: Set(first.map(\.key)), limitAlertsSent: [], now: tomorrow, calendar: cal)
        #expect(next.map(\.key) == ["Claude|Weekly|2026-11-22"])
        #expect(TodayShareAlerts.prune(Set(first.map(\.key) + next.map(\.key)), now: tomorrow, calendar: cal) == ["Claude|Weekly|2026-11-22"])
    }

    @Test func noAlertAfterAMoreUrgentOneOrLateInTheDay() {
        let now = midnight.addingTimeInterval(15 * hour)
        let reset = midnight.addingTimeInterval(4 * day)
        let window = "Claude|Weekly|\(Int((reset.timeIntervalSince1970 / LimitAlerts.bucket).rounded()))"
        for kind in [LimitAlert.Kind.runsOut, .usedUp] {
            #expect(TodayShareAlerts.check(provider: "Claude", limits: [share(50, start: 32, reset: reset, now: now)], sent: [],
                                           limitAlertsSent: ["\(window)#\(kind.rawValue)"], now: now, calendar: cal).isEmpty)
        }
        // "Nearly used" (80%) is less urgent: it doesn't stop this one.
        #expect(TodayShareAlerts.check(provider: "Claude", limits: [share(50, start: 32, reset: reset, now: now)], sent: [],
                                       limitAlertsSent: ["\(window)#1"], now: now, calendar: cal).count == 1)
        let late = midnight.addingTimeInterval(23.5 * hour)
        #expect(TodayShareAlerts.check(provider: "Claude", limits: [share(50, start: 32, reset: reset, now: late)], sent: [],
                                       limitAlertsSent: [], now: late, calendar: cal).isEmpty)
        // Used up: the existing alert covers it.
        #expect(TodayShareAlerts.check(provider: "Claude", limits: [share(100, start: 32, reset: reset, now: now)], sent: [],
                                       limitAlertsSent: [], now: now, calendar: cal).isEmpty)
        // A limit with no share (5-hour) never alerts.
        let five = RateLimit(label: "5-hour", usedPercent: 99, resetsAt: now.addingTimeInterval(hour), window: 5 * 3600)
        #expect(TodayShareAlerts.check(provider: "Claude", limits: [(five, nil)], sent: [], limitAlertsSent: [], now: now, calendar: cal).isEmpty)
    }

    // MARK: The status file

    @Test func statusFileCarriesTheShareForWeeklyLimitsOnly() {
        let now = Date()
        let reset = now.addingTimeInterval(3 * day)
        let samples = [PlanHistory.Sample(series: .init(.claude, .weekly), at: Calendar.current.startOfDay(for: now).addingTimeInterval(-60),
                                          used: 30, resetsAt: reset)]
        let w = CLIStatus.limit(weekly(36, reset: reset), samples: samples, now: now)
        #expect(w.todayShare != nil && w.usedToday == 6)
        let five = CLIStatus.limit(RateLimit(label: "5-hour", usedPercent: 40, resetsAt: now.addingTimeInterval(hour), window: 5 * 3600),
                                   samples: samples, now: now)
        #expect(five.todayShare == nil && five.usedToday == nil)
        #expect(CLIStatus.limit(weekly(36, reset: reset), now: now).todayShare == nil)   // no series
    }

    @Test func statusTextAddsTodaysShareOnTheSameDayOnly() {
        let now = Date()
        func text(generated: Date) -> String {
            let snap = StatusSnapshot(generatedAt: generated, app: .init(name: "Dashbar", version: "1", pid: 1, paused: false),
                                      limits: [.init(provider: "claude", limits: [
                                          .init(label: "Weekly", window: "Weekly", windowSeconds: week, usedPercent: 38,
                                                resetsAt: now.addingTimeInterval(3 * day), todayShare: 21.4, usedToday: 6.2)])])
            return StatusFormat(now: now).status(snap)
        }
        #expect(text(generated: now).contains("today 6% of 21%"))
        #expect(!text(generated: now.addingTimeInterval(-2 * day)).contains("today 6%"))
    }
}
