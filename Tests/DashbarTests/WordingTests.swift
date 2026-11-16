import Foundation
import Testing
@testable import Dashbar

/// The words and number formats the panel shows: one way to write a duration, a reset, a limit's name and a big count.
@Suite struct WordingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // Fri 15 Jan 2027, 08:00 UTC

    @Test func tokenCountsHaveATrillionsTierAndStayShort() {
        #expect(Fmt.tokens(9_990_000_000) == "9.99B")
        #expect(Fmt.tokens(12_400_000_000) == "12.4B")
        #expect(Fmt.tokens(345_000_000_000) == "345B")
        #expect(Fmt.tokens(1_200_000_000_000) == "1.20T")
        #expect(Fmt.tokens(45_600_000_000_000) == "45.6T")
        #expect(Fmt.tokens(123_000_000_000_000) == "123T")
        for n in [9_999_999_999, 99_999_999_999, 999_999_999_999, 9_999_999_999_999] {
            #expect(Fmt.tokens(n).count <= 6, "\(Fmt.tokens(n))")
        }
    }

    @Test func durationsDropZeroPartsAndKeepASecondUnitPastADay() {
        #expect(Fmt.span(45) == "45s")
        #expect(Fmt.span(20 * 3600) == "20h")
        #expect(Fmt.span(2 * 3600 + 5 * 60) == "2h 5m")
        #expect(Fmt.span(86400) == "1d")
        #expect(Fmt.span(86400 + 4 * 3600) == "1d 4h")
        #expect(Fmt.ago(now.addingTimeInterval(-20 * 3600), now: now) == "20h")
        #expect(Fmt.ago(now.addingTimeInterval(-(28 * 3600 + 59)), now: now) == "1d 4h")
        #expect(Fmt.ago(now.addingTimeInterval(5), now: now) == "0s")
    }

    @Test func resetsSayHowLongWithinADayAndWhenAfter() {
        let utc = TimeZone(identifier: "UTC")!
        func resets(_ seconds: TimeInterval, _ locale: String) -> String {
            Fmt.resets(now.addingTimeInterval(seconds), now: now, locale: Locale(identifier: locale), timeZone: utc)
        }
        #expect(resets(2 * 3600 + 10 * 60, "en_GB") == "resets in 2h 10m")
        #expect(resets(30, "en_GB") == "resets in less than a minute")
        #expect(resets(3 * 3600, "en_GB") == "resets in 3h")
        // A day or more: the weekday and time, in the locale's clock.
        #expect(resets(6 * 86400 - 3600 * 23, "en_GB") == "resets Wed 09:00")
        #expect(resets(6 * 86400 - 3600 * 23, "en_US") == "resets Wed 9:00\u{202F}AM")
        // Six days or more, where a weekday could be mistaken for today's: the date.
        #expect(resets(6.5 * 86400, "en_GB") == "resets 21 Jan")
    }

    @Test func usedPercentShowsTheRealFigureOverTheLimit() {
        #expect(Fmt.usedPercent(15.4) == "15% used")
        #expect(Fmt.usedPercent(130) == "130% used")
        #expect(Fmt.usedPercent(-3) == "0% used")
    }

    @Test func limitsAreNamedByTheirLength() {
        #expect(RateLimit.name(window: 5 * 3600) == "5-hour")
        #expect(RateLimit.name(window: 7 * 86400) == "Weekly")
        #expect(RateLimit.name(window: 86400) == "Daily")
        #expect(RateLimit.name(window: 30 * 86400) == "Monthly")
        #expect(RateLimit.name(window: 8 * 3600) == "8-hour")
        #expect(RateLimit.name(window: 3 * 86400) == "3-day")
        #expect(ClaudePlanLimits.label(for: "five_hour") == RateLimit.name(window: 5 * 3600))
        #expect(ClaudePlanLimits.label(for: "seven_day") == "Weekly")
        #expect(ClaudePlanLimits.label(for: "seven_day_opus") == "Weekly · Opus")
    }

    @Test func codexWindowsUseTheSameNames() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("2026/11/06/rollout-1.jsonl", lines: [
            ["timestamp": Fixture.now, "type": "session_meta", "payload": ["cwd": "/Users/x/dev/api"]],
            ["timestamp": Fixture.now, "type": "event_msg", "payload": ["type": "token_count",
                "info": ["total_token_usage": ["input_tokens": 10, "cached_input_tokens": 0, "output_tokens": 5]],
                "rate_limits": ["primary": ["used_percent": 12.0, "window_minutes": 300],
                                "secondary": ["used_percent": 40.0, "window_minutes": 10080]]]],
        ])
        let scanner = CodexUsageScanner(root: fx.root)
        _ = scanner.scan()
        #expect(scanner.limits.map(\.label) == ["5-hour", "Weekly"])
    }

    @Test func sessionsTodayCountsOnlySinceMidnight() {
        var book = UsageBook()
        let t = TokenTotals(input: 10, messages: 1)
        book.add(t, at: Date(), model: "m", project: "p", session: "today")
        book.add(t, at: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-60), model: "m", project: "p", session: "yesterday")
        #expect(book.summary(found: true).sessionsToday == 1)
    }

    @Test func zeroRowsFoldButTheTightestLimitStays() {
        func l(_ name: String, _ used: Double) -> RateLimit { RateLimit(label: name, usedPercent: used, resetsAt: nil) }
        // Only one row at 0% in a long list is not worth folding.
        #expect(RateLimit.fold([l("a", 7), l("b", 0), l("c", 27), l("d", 4)]).folded.isEmpty)
        let some = RateLimit.fold([l("a", 0), l("b", 3), l("c", 0), l("d", 0.2)])
        #expect(some.shown.map(\.label) == ["b"])
        #expect(some.folded.map(\.label) == ["a", "c", "d"])
        // All at 0% in a long list: the first stays, the rest fold.
        let none = RateLimit.fold([l("a", 0), l("b", 0), l("c", 0), l("d", 0)])
        #expect(none.shown.map(\.label) == ["a"])
        #expect(none.folded.map(\.label) == ["b", "c", "d"])
        // Under half a percent reads as 0%, so it folds too.
        #expect(RateLimit.fold([l("a", 0), l("b", 0.4), l("c", 5), l("d", 9)]).folded.map(\.label) == ["a", "b"])
    }

    @Test func threeOrFewerLimitRowsNeverFold() {
        func l(_ name: String, _ used: Double) -> RateLimit { RateLimit(label: name, usedPercent: used, resetsAt: nil) }
        // Claude early in its windows: the 5-hour and Weekly limits are the ones people look for, so all three show.
        let claude = RateLimit.fold([l("5-hour", 0), l("Weekly", 0), l("Extra usage", 27)])
        #expect(claude.shown.map(\.label) == ["5-hour", "Weekly", "Extra usage"])
        #expect(claude.folded.isEmpty)
        #expect(RateLimit.fold([l("a", 0), l("b", 0), l("c", 0)]).folded.isEmpty)
        #expect(RateLimit.fold([l("a", 0), l("b", 0)]).folded.isEmpty)
        #expect(RateLimit.fold([l("a", 0)]).shown.count == 1)
    }

    @Test func paceCaptionsAllSayWhatIsLeftAtThisRate() {
        #expect(LimitBar.text(.under) == "At this rate, plenty left when it resets")
        #expect(LimitBar.text(.onPace) == "At this rate, lasts until it resets")
        #expect(LimitBar.text(.usedUp) == "Used up until it resets")
        #expect(LimitBar.text(.runsOut(Date())).hasPrefix("At this rate, runs out"))
    }

    @Test func widgetFootnotesNameTheirSpan() {
        #expect(WidgetRow.sessionsText(1) == "1 session today")
        #expect(WidgetRow.sessionsText(6) == "6 sessions today")
        #expect(WidgetRow.changeText(this: 103, last: 100) == "Up 3% on the 7 days before")
        #expect(WidgetRow.changeText(this: 100, last: 100) == "Same as the 7 days before")
        #expect(WidgetRow.changeText(this: 5, last: 0) == "No usage the 7 days before")
        #expect(WidgetRow.messagesHelp(1).contains("1 message today"))
        #expect(UsagePeriod.today.tokensLine(153_000_000) == "153M tokens today")
        #expect(UsagePeriod.week.tokensLine(1_140_000_000) == "1.14B tokens in 7 days")
    }

    @Test func smallLabels() {
        #expect(NowSessionLine.moreAgents(1) == "1 more agent")
        #expect(NowSessionLine.moreAgents(3) == "3 more agents")
        #expect(PermissionPrompt.remaining(now.addingTimeInterval(26), now: now) == "0:26 left")
        #expect(AntigravityLimitsBlock.ageLine(writtenAt: now.addingTimeInterval(-7 * 60), now: now)
                == "Updated 7m ago · refreshes next time you use the Antigravity CLI")
        #expect(Fmt.driveBytes(994_662_584_320) == "995 GB")
        #expect(Fmt.driveBytes(421_370_000_000) == "421 GB")
    }

    @Test func otherToolsLeaveOutAppsThatHostAListedSession() {
        let agents = [AgentProcess(name: "Codex", count: 2), AgentProcess(name: "T3 Code", count: 1),
                      AgentProcess(name: "Cursor", count: 1)]
        #expect(AgentChips.items(agents, hosts: ["T3 Code", "Terminal"]) == ["Codex ×2", "Cursor"])
        #expect(AgentChips.items([AgentProcess(name: "Codex app", count: 1)], hosts: ["Codex"]).isEmpty)
        #expect(AgentChips.items(agents, hosts: []).count == 3)
        // opencode's sessions are listed by workspace, so its process is never an "other AI tool" chip.
        #expect(AgentProcesses.read(executables: ["/opt/homebrew/bin/opencode", "/usr/local/bin/aider"]).map(\.name) == ["Aider"])
    }
}
