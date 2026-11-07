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
    /// Projections from the first minutes of a window swing wildly, so "runs out" waits for a quarter of it.
    static let minimumElapsedPercent = 25.0
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
        if case .runsOut? = limit.pace(now: now), (limit.expectedPercent(now: now) ?? 0) >= minimumElapsedPercent {
            return .runsOut
        }
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
}
