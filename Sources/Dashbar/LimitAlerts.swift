import Foundation

/// Notifications for plan limits, worked out from the same readings and pace maths as the panel.
///
/// Each limit can raise three alerts per window, and only ever escalates: "nearly used" (80%), "runs out"
/// (at the current rate it is gone before it resets) and "used up". Once one has been sent, a less urgent one
/// for the same window never follows it. A new window (a new reset time) starts afresh.
struct LimitAlert: Equatable {
    enum Kind: Int, Comparable {
        case nearlyUsed = 1, runsOut, usedUp
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let kind: Kind
    /// The limit and window this alert belongs to: "Claude|5-hour|<reset bucket>".
    let window: String
    let title: String
    let body: String

    /// What's remembered once it has been sent.
    var sentKey: String { "\(window)#\(kind.rawValue)" }
}

enum LimitAlerts {
    static let nearlyUsedPercent = 80.0
    /// Reset times are bucketed so a reading that drifts by seconds still counts as the same window.
    static let bucket: TimeInterval = 15 * 60

    static func check(provider: String, limits: [RateLimit], sent: Set<String>, now: Date = Date()) -> [LimitAlert] {
        limits.compactMap { limit in
            guard let resetsAt = limit.resetsAt, resetsAt > now else { return nil }
            let window = "\(provider)|\(limit.label)|\(Int((resetsAt.timeIntervalSince1970 / bucket).rounded()))"
            guard let kind = kind(for: limit, now: now) else { return nil }
            let alreadySent = sent.compactMap { key -> Int? in
                guard key.hasPrefix(window + "#") else { return nil }
                return Int(key.dropFirst(window.count + 1))
            }.max() ?? 0
            guard kind.rawValue > alreadySent else { return nil }
            return LimitAlert(kind: kind, window: window, title: "\(provider) \(limit.label)",
                              body: body(kind, limit: limit, resetsAt: resetsAt, now: now))
        }
    }

    /// The most urgent alert that applies right now, if any.
    static func kind(for limit: RateLimit, now: Date) -> LimitAlert.Kind? {
        if limit.usedPercent >= 100 { return .usedUp }
        if case .runsOut? = limit.pace(now: now) { return .runsOut }   // pace waits for a quarter of the window
        if limit.usedPercent >= nearlyUsedPercent { return .nearlyUsed }
        return nil
    }

    static func body(_ kind: LimitAlert.Kind, limit: RateLimit, resetsAt: Date, now: Date) -> String {
        let untilReset = Fmt.duration(resetsAt.timeIntervalSince(now))
        switch kind {
        case .usedUp:
            return "Used up. It resets in \(untilReset)."
        case .nearlyUsed:
            return "\(Int(limit.usedPercent.rounded()))% used. It resets in \(untilReset)."
        case .runsOut:
            guard case .runsOut(let at)? = limit.pace(now: now) else { return "Running out before it resets." }
            let time = at.formatted(date: Calendar.current.isDate(at, inSameDayAs: now) ? .omitted : .abbreviated,
                                    time: .shortened)
            return "At this rate it runs out at \(time), \(Fmt.duration(resetsAt.timeIntervalSince(at))) before it resets."
        }
    }

    /// Forgets windows that have already reset, so the remembered set stays small.
    static func prune(_ sent: Set<String>, now: Date = Date()) -> Set<String> {
        sent.filter { key in
            guard let window = key.split(separator: "#").first,
                  let bucketValue = window.split(separator: "|").last.flatMap({ Double($0) }) else { return false }
            return bucketValue * bucket > now.timeIntervalSince1970 - bucket
        }
    }

    /// How long a claim between copies of Dashbar holds: far longer than the gap between two copies seeing the same
    /// reading, and shorter than a window, so the next window's alert is news again.
    static let claimWindow: TimeInterval = 6 * 3600

    /// The release and a local build read the same limits, so each alert is claimed before it is posted and only the
    /// first copy posts it. The claim's file name is a hash: it holds no provider, account or limit name.
    static func claimKey(_ sentKey: String) -> String { "limit-" + AgentAccounts.hash(sentKey) }
}

/// "Claude 5-hour: it has reset", the other side of "used up".
///
/// Only a limit Dashbar saw used up (100%) is followed, so the notification is rare and always means something: you
/// were stopped, and now you can carry on. 90% wouldn't do: most windows pass 90% and reset without anyone waiting on
/// them. (Claude's "rate limited" state is about reading the plan usage too often, not the plan limit, so it plays no
/// part.) A followed window is remembered across relaunches, so a reset that happened while Dashbar was quit is still
/// announced when it opens again, unless that was more than `staleAfter` ago. A reset nobody saw used up is never news.
struct LimitReset: Equatable {
    let title: String
    let body: String
    /// The same in every running copy of Dashbar (the release and a local build), so only the first posts it.
    let claimKey: String
}

enum LimitResets {
    /// Waits a minute past the reset time, so a reading taken right at the reset has caught up.
    static let grace: TimeInterval = 60
    /// A reset this long ago is old news: whoever was waiting has seen it by now.
    static let staleAfter: TimeInterval = 12 * 3600
    /// Readings whose reset time drifts by less than this are the same window.
    static let drift = LimitAlerts.bucket

    /// One followed window: "Claude|5-hour@1800018000", the limit and when that used-up window resets.
    struct Followed: Hashable {
        let limit: String
        let resetsAt: Date

        init(limit: String, resetsAt: Date) {
            self.limit = limit
            self.resetsAt = Date(timeIntervalSince1970: resetsAt.timeIntervalSince1970.rounded())
        }

        init?(_ saved: String) {
            guard let at = saved.lastIndex(of: "@"), let seconds = Double(saved[saved.index(after: at)...]) else { return nil }
            self.init(limit: String(saved[..<at]), resetsAt: Date(timeIntervalSince1970: seconds))
        }

        var saved: String { "\(limit)@\(Int(resetsAt.timeIntervalSince1970))" }
    }

    /// Follows `provider`'s used-up windows and returns the ones that have reset since, with what to remember next.
    /// Windows saved for other providers pass through untouched.
    static func check(provider: String, limits: [RateLimit], followed saved: Set<String>,
                      now: Date = Date()) -> (resets: [LimitReset], followed: Set<String>) {
        var followed = Set(saved.compactMap(Followed.init))
        let prefix = provider + "|"

        // Follow every window used up right now. A drifting reset time replaces its entry rather than adding one.
        for limit in limits {
            guard limit.usedPercent >= 100, let resetsAt = limit.resetsAt, resetsAt > now else { continue }
            let name = prefix + limit.label
            followed = followed.filter { $0.limit != name || abs($0.resetsAt.timeIntervalSince(resetsAt)) > drift }
            followed.insert(Followed(limit: name, resetsAt: resetsAt))
        }

        var resets: [LimitReset] = []
        for window in followed.sorted(by: { $0.saved < $1.saved }) {
            guard window.limit.hasPrefix(prefix), now >= window.resetsAt.addingTimeInterval(grace) else { continue }
            followed.remove(window)
            guard now.timeIntervalSince(window.resetsAt) <= staleAfter else { continue }
            let label = String(window.limit.dropFirst(prefix.count))
            // Still used up with a reset ahead: the window moved, or the next one is used up already. Not news.
            let stillUsedUp = limits.contains { $0.label == label && $0.usedPercent >= 100 && ($0.resetsAt ?? .distantPast) > now }
            guard !stillUsedUp else { continue }
            resets.append(LimitReset(title: "\(provider) \(label)",
                                     body: "It has reset. You can pick up where you left off.",
                                     claimKey: "limit-reset-" + AgentAccounts.hash(window.saved)))
        }
        return (resets, Set(followed.map(\.saved)))
    }

    /// Forgets windows whose reset is old news, whichever provider they belong to.
    static func prune(_ saved: Set<String>, now: Date = Date()) -> Set<String> {
        saved.filter { Followed($0).map { now.timeIntervalSince($0.resetsAt) <= staleAfter } ?? false }
    }

    /// Posts each reset once across every running copy of Dashbar.
    static func deliver(_ resets: [LimitReset], claims: AnnouncementClaims, now: Date = Date(), post: (LimitReset) -> Void) {
        for reset in resets where claims.claim(reset.claimKey, window: LimitAlerts.claimWindow, now: now) { post(reset) }
    }
}

/// "Claude Weekly: you've used today's share", an earlier heads-up than "runs out", off by default.
///
/// Once per limit per day, when today's use reaches today's share (`TodayShare`). Not sent when a more urgent alert
/// for the same window ("runs out", "used up") has already gone out, when the limit is used up, or in the last hour of
/// the day, when easing off no longer helps and tomorrow's share is about to start.
struct TodayShareAlert: Equatable {
    /// "Claude|Weekly|2026-11-21": the limit and the local day.
    let key: String
    let title: String
    let body: String
    /// The same in every running copy of Dashbar, so only the first posts it. A hash: no provider or limit name.
    var claimKey: String { "share-" + AgentAccounts.hash(key) }
}

enum TodayShareAlerts {
    static let settingKey = "notifyOnTodayShare"
    /// No alert this close to midnight.
    static let quietBeforeMidnight: TimeInterval = 3600

    /// `limits` pairs each limit with its today's share (nil where it has none). `sent` is what was already sent
    /// (`TodayShareAlert.key`), `limitAlertsSent` the plan limit alerts' memory (`LimitAlert.sentKey`).
    static func check(provider: String, limits: [(limit: RateLimit, share: TodayShare?)], sent: Set<String>,
                      limitAlertsSent: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> [TodayShareAlert] {
        let day = dayKey(now, calendar: calendar)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              tomorrow.timeIntervalSince(now) > quietBeforeMidnight else { return [] }
        return limits.compactMap { item in
            guard let share = item.share, share.reached, share.share > 0, item.limit.usedPercent < 100,
                  let resetsAt = item.limit.resetsAt, resetsAt > now else { return nil }
            let key = "\(provider)|\(item.limit.label)|\(day)"
            guard !sent.contains(key) else { return nil }
            // A more urgent alert for this window already said more than this one would.
            let window = "\(provider)|\(item.limit.label)|\(Int((resetsAt.timeIntervalSince1970 / LimitAlerts.bucket).rounded()))"
            let urgent = [LimitAlert.Kind.runsOut, .usedUp].contains { limitAlertsSent.contains("\(window)#\($0.rawValue)") }
            guard !urgent else { return nil }
            return TodayShareAlert(key: key, title: "\(provider) \(item.limit.label)",
                                   body: "You've used today's share (\(Int(share.share.rounded()))%). Going on is fine; tomorrow's share will be smaller.")
        }
    }

    /// "2026-11-21" in the local calendar.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Keeps only today's keys.
    static func prune(_ sent: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        let day = dayKey(now, calendar: calendar)
        return sent.filter { $0.hasSuffix("|" + day) }
    }

    /// Posts each alert once across every running copy of Dashbar.
    static func deliver(_ alerts: [TodayShareAlert], claims: AnnouncementClaims, now: Date = Date(), post: (TodayShareAlert) -> Void) {
        for alert in alerts where claims.claim(alert.claimKey, window: LimitAlerts.claimWindow, now: now) { post(alert) }
    }
}
