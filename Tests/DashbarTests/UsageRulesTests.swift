import Foundation
import Testing
@testable import Dashbar

/// The Usage tab's rules: which tool's card comes first, when the line across tools shows, and when a card folds.
@Suite struct UsageRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A 5-hour limit `elapsed` hours into its window.
    func fiveHour(_ used: Double, elapsed: Double = 2.5) -> RateLimit {
        RateLimit(label: "5-hour", usedPercent: used, resetsAt: now.addingTimeInterval((5 - elapsed) * 3600), window: 5 * 3600)
    }

    func weekly(_ used: Double) -> RateLimit {
        RateLimit(label: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(3.5 * 86400), window: 7 * 86400)
    }

    func digest(_ s: UsageRules.Service, _ limits: [RateLimit] = [], tokens: Int = 0, notice: Bool = false) -> UsageRules.Digest {
        UsageRules.Digest(service: s, limits: limits, tokens: tokens, cost: Double(tokens) / 1_000_000, hasNotice: notice)
    }

    func order(_ d: [UsageRules.Digest]) -> [UsageRules.Service] { UsageRules.order(d, now: now).map(\.service) }

    @Test func tightestLimitLeads() {
        // Codex's weekly is the tightest limit on the tab, so Codex leads though Claude used far more tokens.
        let claude = digest(.claude, [fiveHour(20), weekly(30)], tokens: 150_000_000)
        let codex = digest(.codex, [fiveHour(10), weekly(45)], tokens: 9_000_000)
        #expect(order([claude, codex]) == [.codex, .claude])
    }

    @Test func runningOutOutranksAHigherShareUsed() {
        // 60% used halfway through a 5-hour window runs out before the reset (120% by then); 70% of a fresh week doesn't.
        let fast = fiveHour(60, elapsed: 2.5)
        #expect(UsageRules.urgency(fast, now: now) > 100)
        let claude = digest(.claude, [fast], tokens: 1)
        let codex = digest(.codex, [RateLimit(label: "Weekly", usedPercent: 70, resetsAt: now.addingTimeInterval(6.9 * 86400), window: 7 * 86400)], tokens: 1)
        #expect(order([codex, claude]) == [.claude, .codex])
    }

    @Test func usedUpLeads() {
        let claude = digest(.claude, [fiveHour(100)], tokens: 1)
        let codex = digest(.codex, [fiveHour(95, elapsed: 4.9)], tokens: 1_000)
        #expect(order([codex, claude]) == [.claude, .codex])
    }

    @Test func tiesGoToTokenVolume() {
        // 40.2% and 39.8% print as 40%: a tie, so the busier tool leads.
        let claude = digest(.claude, [weekly(40.2)], tokens: 5)
        let codex = digest(.codex, [weekly(39.8)], tokens: 50)
        #expect(order([claude, codex]) == [.codex, .claude])
    }

    @Test func limitsWithoutAWindowDontCount() {
        // Claude's extra usage at 80% says nothing about running out soon; Codex's 10% weekly does.
        let extra = RateLimit(label: "Extra usage", usedPercent: 80, resetsAt: nil, window: nil)
        #expect(UsageRules.urgency([extra], now: now) == nil)
        let claude = digest(.claude, [extra], tokens: 100)
        let codex = digest(.codex, [weekly(10)], tokens: 1)
        #expect(order([claude, codex]) == [.codex, .claude])
    }

    @Test func toolsWithoutLimitsFollowByVolume() {
        let claude = digest(.claude, [weekly(5)], tokens: 1)
        let google = digest(.google, tokens: 900)
        let codex = digest(.codex, tokens: 100)
        #expect(order([google, codex, claude]) == [.claude, .google, .codex])
    }

    @Test func equalEverythingKeepsTheUsualOrder() {
        #expect(order([digest(.google, tokens: 1), digest(.codex, tokens: 1), digest(.claude, tokens: 1)]) == [.claude, .codex, .google])
    }

    @Test func idleFoldsAndGoesLast() {
        let idle = digest(.claude)
        #expect(UsageRules.isIdle(idle))
        #expect(!UsageRules.isIdle(digest(.claude, tokens: 1)))
        #expect(!UsageRules.isIdle(digest(.codex, [weekly(0)])))   // a limit to show, even at 0%
        // Never a quiet zero: scanning, unreadable logs, no transcripts or a setup step keep the card open.
        #expect(!UsageRules.isIdle(digest(.claude, notice: true)))
        #expect(order([idle, digest(.google, tokens: 1)]) == [.google, .claude])
    }

    @Test func summaryNeedsTwoToolsInUse() {
        #expect(!UsageRules.showsSummary([digest(.claude, tokens: 10)]))
        // An idle second tool would make the total repeat the first card's figure.
        #expect(!UsageRules.showsSummary([digest(.claude, tokens: 10), digest(.codex, [weekly(3)])]))
        #expect(UsageRules.showsSummary([digest(.claude, tokens: 10), digest(.codex, tokens: 2)]))
        let totals = UsageRules.totals([digest(.claude, tokens: 3_000_000), digest(.codex, tokens: 1_000_000), digest(.google)])
        #expect(totals.tokens == 4_000_000)
        #expect(totals.cost == 4)
        #expect(totals.tools == 2)
    }

    @Test func periodWording() {
        #expect(UsagePeriod.today.noUsage == "No usage today")
        #expect(UsagePeriod.week.noUsage == "No usage in 7 days")
        #expect(UsagePeriod.fortnight.span == "in 14 days")
        #expect(ServiceUsageCard.split(TokenTotals(input: 1_200_000, output: 640_000, cacheRead: 148_000_000, cacheWrite: 2_900_000))
                == "In 1.2M · Out 640K · Cache read 148M · Cache write 2.9M")
        #expect(ServiceUsageCard.sessions(1) == "1 session")
    }
}
