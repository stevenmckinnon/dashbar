import Foundation

/// What the Usage tab shows, and in what order. Kept apart from the views so the rules are tested.
///
/// The tab has one card per tool (Claude Code, Codex, Google's, opencode). The tool closest to running out of plan comes
/// first, so the card that may need you is the one in view; a tool with nothing to say for the period folds to one line.
/// opencode reports no plan limits (people bring their own provider), so its card ranks by tokens among the tools
/// without limits.
enum UsageRules {
    enum Service: String, CaseIterable, Identifiable {
        case claude, codex, google, opencode
        var id: String { rawValue }
    }

    /// What the rules need to know about one tool's card.
    struct Digest: Equatable {
        let service: Service
        /// Every limit the card shows, across its accounts.
        var limits: [RateLimit] = []
        /// Tokens in the chosen period.
        var tokens = 0
        /// Estimated cost of those tokens at API prices.
        var cost: Double = 0
        /// The card has something it must say: transcripts still scanning, logs it can't read, no transcripts at all,
        /// a limits problem or a setup step. Such a card never folds, so nothing is ever quietly shown as zero.
        var hasNotice = false
    }

    /// How close a limit is to running out, in percent of the plan: the share used, or, when the current rate runs
    /// it out before the reset, the share it would reach by then (over 100). A used-up limit outranks everything.
    static func urgency(_ limit: RateLimit, now: Date) -> Double {
        let used = max(0, limit.usedPercent)
        if used >= 100 { return .infinity }
        if case .runsOut? = limit.pace(now: now), let expected = limit.expectedPercent(now: now), expected > 0 {
            return max(used, used / expected * 100)
        }
        return used
    }

    /// The urgency of the tightest limit that resets on a window (5-hour, Weekly…). Nil when the tool reports none:
    /// a limit with no window (Claude's extra usage) says nothing about running out soon.
    static func urgency(_ limits: [RateLimit], now: Date) -> Double? {
        limits.filter(PlanStrip.isWindowed).map { urgency($0, now: now) }.max()
    }

    /// No usage in the period, no limits and nothing to say: the card folds to a single line.
    static func isIdle(_ d: Digest) -> Bool { d.tokens == 0 && d.limits.isEmpty && !d.hasNotice }

    /// Cards in order: the tool whose tightest windowed limit is closest to running out first (whole percents, as the
    /// rows print them), then by tokens in the period, then Claude Code, Codex, Google, opencode. Tools with no limits follow
    /// every tool with one, and idle tools come last.
    static func order(_ digests: [Digest], now: Date) -> [Digest] {
        func rank(_ d: Digest) -> Int {
            guard let u = urgency(d.limits, now: now) else { return -1 }
            return u.isInfinite ? Int.max : Int(u.rounded())
        }
        func position(_ s: Service) -> Int { Service.allCases.firstIndex(of: s) ?? 0 }
        return digests.map { ($0, isIdle($0), rank($0)) }
            .sorted { a, b in
                if a.1 != b.1 { return !a.1 }
                if a.2 != b.2 { return a.2 > b.2 }
                if a.0.tokens != b.0.tokens { return a.0.tokens > b.0.tokens }
                return position(a.0.service) < position(b.0.service)
            }
            .map(\.0)
    }

    /// The line across tools shows only when at least two used tokens in the period; with one, it would repeat that card.
    static func showsSummary(_ digests: [Digest]) -> Bool { digests.filter { $0.tokens > 0 }.count >= 2 }

    /// The summary's figures: tokens and estimated cost across every tool.
    static func totals(_ digests: [Digest]) -> (tokens: Int, cost: Double, tools: Int) {
        let used = digests.filter { $0.tokens > 0 }
        return (used.reduce(0) { $0 + $1.tokens }, used.reduce(0) { $0 + $1.cost }, used.count)
    }
}
