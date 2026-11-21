import Foundation

/// How much of a weekly (or longer) plan limit can be used today and still last until it resets.
///
/// What was left at local midnight, spread evenly over the days left from midnight to the reset (part days count, but
/// never fewer than one, so on the last day the share is everything left). Worked out from where the day started, not
/// from the live reading, so it stays fixed for the day and never shrinks as it is used.
struct TodayShare: Equatable {
    /// The share used when today began (%), from the plan history.
    let startOfDay: Double
    /// Today's share (%), on top of `startOfDay`.
    let share: Double
    /// Used since midnight (%).
    let usedToday: Double

    /// Where the bar's tick goes (%).
    var mark: Double { min(100, startOfDay + share) }
    /// Today has used at least its share.
    var reached: Bool { usedToday >= share }
    /// Today is clearly past its share, as the caption says it: by more than rounding.
    var over: Bool { usedToday.rounded() > share.rounded() }

    /// Weekly or longer, with a reset time: the limits a day's share makes sense for. Never 5-hour windows, and never
    /// a limit without a window or reset (Claude's "Extra usage").
    static func applies(to limit: RateLimit) -> Bool {
        guard let window = limit.window, window >= 6 * 86400, limit.resetsAt != nil else { return false }
        return true
    }

    /// Today's share of `limit`, from its series' readings (`samples`, any order, any window; only those of this
    /// window up to `now` are used). Nil for a limit it doesn't apply to, or one that has already reset.
    static func compute(_ limit: RateLimit, samples: [PlanHistory.Sample], now: Date,
                        calendar: Calendar = .current) -> TodayShare? {
        guard applies(to: limit), let window = limit.window, let resetsAt = limit.resetsAt, resetsAt > now else { return nil }
        let midnight = calendar.startOfDay(for: now)
        let windowStart = resetsAt.addingTimeInterval(-window)
        let used = min(max(limit.usedPercent, 0), 100)

        let start: Double
        if windowStart > midnight {
            start = 0   // the window began today, so the day began with it empty
        } else {
            let mine = samples.filter { s in
                guard s.at <= now, s.at >= windowStart else { return false }
                if let r = s.resetsAt { return abs(r.timeIntervalSince(resetsAt)) <= PlanHistory.sameReset }
                return true
            }.sorted { $0.at < $1.at }
            if let before = mine.last(where: { $0.at <= midnight }) {
                start = before.used
            } else if let first = mine.first {
                start = first.used   // Dashbar wasn't reading at midnight: the day's first reading
            } else {
                start = used         // nothing on record: today starts now
            }
        }
        let base = min(max(start, 0), 100)
        let left = 100 - base
        let daysLeft = max(1, resetsAt.timeIntervalSince(midnight) / 86400)
        let share = min(max(left / daysLeft, 0), left)
        return TodayShare(startOfDay: base, share: share, usedToday: max(0, used - base))
    }

    // MARK: Wording

    /// The caption under a weekly row, replacing the pace line: "Today 6% of about 21% · plenty left at this rate",
    /// "Today 26%, over today's 21% · lasts until it resets". Without a pace yet, only the part before "·".
    func caption(pace: RateLimit.Pace?, now: Date = Date()) -> String {
        let today = Int(usedToday.rounded()), of = Int(share.rounded())
        let head = over ? "Today \(today)%, over today's \(of)%" : "Today \(today)% of about \(of)%"
        guard let pace else { return head }
        return head + " \u{00B7} " + Self.paceTail(pace, now: now)
    }

    /// The pace line, shortened to follow the share: "plenty left at this rate", "runs out Mon 14:20".
    static func paceTail(_ pace: RateLimit.Pace, now: Date = Date()) -> String {
        switch pace {
        case .under: return "plenty left at this rate"
        case .onPace: return "lasts until it resets"
        case .usedUp: return "used up until it resets"
        case .runsOut(let date):
            let when = Calendar.current.isDate(date, inSameDayAs: now)
                ? "at " + date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "runs out \(when)"
        }
    }

    /// For VoiceOver and the tooltip: "Used 6 percent today, of about 21 percent that would last until it resets".
    var spoken: String {
        let today = Int(usedToday.rounded()), of = Int(share.rounded())
        return over
            ? "Used \(today) percent today, over today's share of \(of) percent that would last until it resets"
            : "Used \(today) percent today, of about \(of) percent that would last until it resets"
    }

    var help: String {
        "The tick marks today's share: what was left at midnight, spread evenly over the days until it resets "
            + "(\(Int(share.rounded()))% today). Going over is fine; the days after get a smaller share."
    }
}
