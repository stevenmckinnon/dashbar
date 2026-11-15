import Foundation

/// What the panel's Overview shows, and when. Kept apart from the views so the rules are tested.
///
/// The Overview answers three questions in order: does anything need me, what is working, will I run out of plan.
/// On a quiet day it should say so in one look, so anything that only restates "nothing is happening" stays hidden.
enum OverviewRules {
    /// How long after its agent goes idle a workspace keeps the Now card, so a finished turn is still in view.
    static let recentIdle: TimeInterval = 10 * 60
    /// The clean-up line shows from 1 GB (decimal, as the Clean-up tab counts it).
    static let cleanupThreshold: UInt64 = 1_000_000_000

    /// The workspace the Now card features: one whose agent is waiting for you, then one that is working, then the one
    /// whose agent went idle most recently, but only within `recentIdle`. Nil when everything has been idle for longer:
    /// then every workspace is an ordinary row.
    static func nowWorkspace(_ workspaces: [Workspace], now: Date,
                             working: (Workspace) -> Bool = { $0.isBusy }) -> Workspace? {
        if let waiting = workspaces.first(where: \.isWaiting) { return waiting }
        if let busy = workspaces.first(where: working) { return busy }
        guard let recent = workspaces.filter({ !$0.sessions.isEmpty }).max(by: { latest($0) < latest($1) }),
              now.timeIntervalSince(latest(recent)) < recentIdle else { return nil }
        return recent
    }

    /// When the workspace's agents last changed state.
    static func latest(_ w: Workspace) -> Date { w.sessions.map(\.since).max() ?? .distantPast }

    /// The Servers card shows on Overview only for dev servers no workspace row already shows (Docker, servers started
    /// from / or ~). An empty card, or one kept alive only by other apps listening, belongs to the Servers tab.
    static func showsServersCard(looseServers: [Listener]) -> Bool { !looseServers.isEmpty }

    /// The clean-up line shows once the caches are scanned and add up to 1 GB or more.
    static func showsCleanupLine(scanned: Bool, total: UInt64) -> Bool { scanned && total >= cleanupThreshold }
}

/// The Overview's plan limits strip: one row per account, each with its tightest limit.
enum PlanStrip {
    /// The limit most at risk: one on course to run out (or used up) before one that isn't, then the highest share
    /// used. Ties keep the provider's own order, so "5-hour" comes before "Weekly". Only limits that reset on a window
    /// (5-hour, Weekly…) count, since they are what "how much plan is left" means; one with no window (Claude's extra
    /// usage) headlines only when the provider reports nothing else.
    static func tightest(_ limits: [RateLimit], now: Date = Date()) -> RateLimit? {
        let windowed = limits.filter(isWindowed)
        var best: (limit: RateLimit, risk: Bool)?
        for l in windowed.isEmpty ? limits : windowed {
            let risk = atRisk(l.pace(now: now))
            guard let b = best else { best = (l, risk); continue }
            if (risk && !b.risk) || (risk == b.risk && l.usedPercent > b.limit.usedPercent) { best = (l, risk) }
        }
        return best?.limit
    }

    /// A limit that resets: it has a window length or a reset time.
    static func isWindowed(_ l: RateLimit) -> Bool { l.window != nil || l.resetsAt != nil }

    static func atRisk(_ pace: RateLimit.Pace?) -> Bool {
        switch pace {
        case .runsOut?, .usedUp?: return true
        default: return false
        }
    }

    /// A limit's name when its own is too long for the strip: its window's name, the way every tool names its rows
    /// ("Gemini Argon · Weekly" → "Weekly"), or else the part after its group's name, or else its own name.
    static func shortLabel(_ l: RateLimit) -> String {
        if let window = l.window { return RateLimit.name(window: window) }
        if let last = l.label.components(separatedBy: " · ").last, !last.isEmpty { return last }
        return l.label
    }

    /// The strip keeps a row to one line unless its limit is on course to run out (or used up): only then does it
    /// carry the pace caption the full row has.
    static func showsCaption(_ pace: RateLimit.Pace?) -> Bool { atRisk(pace) }

    /// What VoiceOver reads for a row: "Claude, 5-hour limit, 55 percent used, resets in 2h 11m".
    static func spoken(provider: String, limit: RateLimit, now: Date = Date()) -> String {
        var parts = [provider, "\(limit.label) limit", "\(Int(max(0, limit.usedPercent).rounded())) percent used"]
        if let r = limit.resetsAt { parts.append(Fmt.resets(r, now: now)) }
        if let pace = limit.pace(now: now), showsCaption(pace) { parts.append(LimitBar.text(pace)) }
        return parts.joined(separator: ", ")
    }
}
