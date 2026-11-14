import Foundation

// MARK: - Plan-limit history

/// Readings of the 5-hour and weekly plan windows (Claude and Codex) over time, kept on this Mac so the History page
/// can show how full each past window got and how the current one is going.
///
/// Two tiers keep it small: recent readings (`samples`, at most one per series per `bucket`, for `sampleDays`), and a
/// summary of every window whose readings have aged out (`archived`, for `windowDays`). Readings only arrive while
/// Claude Code or Codex is in use, so a typical file is a few tens of kilobytes; even with all four series read
/// around the clock it stays under about 350 KB.
struct PlanHistory: Codable, Equatable {
    enum Provider: String, Codable, CaseIterable { case claude, codex }

    enum Kind: String, Codable, CaseIterable {
        case fiveHour, weekly
        var length: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 86400 }
    }

    struct Series: Hashable, Codable {
        var provider: Provider
        var kind: Kind
        /// "c5", "cw", "x5", "xw": the compact form samples are saved with.
        var code: String { (provider == .claude ? "c" : "x") + (kind == .fiveHour ? "5" : "w") }
        init(_ provider: Provider, _ kind: Kind) { self.provider = provider; self.kind = kind }
        init?(code: String) {
            guard code.count == 2 else { return nil }
            switch code.first { case "c": provider = .claude; case "x": provider = .codex; default: return nil }
            switch code.last { case "5": kind = .fiveHour; case "w": kind = .weekly; default: return nil }
        }
    }

    /// One reading. Saved as `["c5", 1763100000, 42.5, 1763110800]` to keep the file small.
    struct Sample: Codable, Equatable {
        var series: Series
        var at: Date
        var used: Double
        var resetsAt: Date?

        init(series: Series, at: Date, used: Double, resetsAt: Date?) {
            self.series = series; self.at = at; self.used = used; self.resetsAt = resetsAt
        }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            guard let s = Series(code: try c.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown series")
            }
            series = s
            at = Date(timeIntervalSince1970: try c.decode(Double.self))
            used = try c.decode(Double.self)
            if c.isAtEnd { resetsAt = nil } else { resetsAt = try c.decodeIfPresent(Double.self).map(Date.init(timeIntervalSince1970:)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(series.code)
            try c.encode(at.timeIntervalSince1970.rounded())
            try c.encode((used * 10).rounded() / 10)
            if let resetsAt { try c.encode(resetsAt.timeIntervalSince1970.rounded()) }
        }
    }

    /// One plan window: from its readings, or kept as this summary once they have aged out.
    struct Window: Codable, Equatable, Identifiable {
        var series: Series
        /// When the window was due to reset. Nil when the source didn't say.
        var resetsAt: Date?
        var firstSeen: Date
        var lastSeen: Date
        var peak: Double
        var peakAt: Date
        /// A later window began before this one's reset time: the plan was reset early.
        var endedEarly = false

        var id: String { series.code + String(Int((resetsAt ?? firstSeen).timeIntervalSince1970)) }
        /// When it began: its length before the reset, or the first reading when the reset isn't known.
        var start: Date { resetsAt.map { min(firstSeen, $0.addingTimeInterval(-series.kind.length)) } ?? firstSeen }
        var end: Date { resetsAt ?? lastSeen }
        var hitLimit: Bool { peak >= PlanHistory.limitHit }
        var nearLimit: Bool { peak >= PlanHistory.limitNear }
    }

    /// A reading at or over this counts as having hit the limit (readings are rounded, so 99.5 shows as 100%).
    static let limitHit = 99.5
    static let limitNear = 90.0
    /// At most one reading per series in each slot of this length.
    static let bucket: TimeInterval = 10 * 60
    /// Readings are kept this long: a weekly window and a day either side.
    static let sampleDays = 8.0
    /// Window summaries are kept this long.
    static let windowDays = 90.0
    /// Reset times this close together belong to the same window (Codex works its reset out from "resets in").
    static let sameReset: TimeInterval = 15 * 60

    private(set) var samples: [Sample] = []
    private(set) var archived: [Window] = []

    var isEmpty: Bool { samples.isEmpty && archived.isEmpty }

    /// Which series a limit belongs to: the plan's own 5-hour and weekly windows, not per-model ones ("Weekly · Opus").
    static func kind(of limit: RateLimit) -> Kind? {
        guard !limit.label.contains("·"), let w = limit.window else { return nil }
        if abs(w - Kind.fiveHour.length) <= 1800 { return .fiveHour }
        if abs(w - Kind.weekly.length) <= 6 * 3600 { return .weekly }
        return nil
    }

    /// Adds a reading of each 5-hour and weekly limit taken at `at`. Returns whether anything changed.
    /// Readings for a window that had already reset by `at` are left out: their numbers no longer applied.
    @discardableResult
    mutating func record(_ limits: [RateLimit], provider: Provider, at: Date) -> Bool {
        var changed = false
        for limit in limits {
            guard let kind = Self.kind(of: limit) else { continue }
            if let reset = limit.resetsAt, reset <= at { continue }
            let s = Sample(series: Series(provider, kind), at: at, used: min(max(limit.usedPercent, 0), 100), resetsAt: limit.resetsAt)
            if let i = samples.lastIndex(where: { $0.series == s.series }) {
                let last = samples[i]
                if last.at == s.at { continue }   // the same reading again
                if last.at < s.at, Self.slot(last.at) == Self.slot(s.at), Self.sameWindow(last, s, lastUsed: last.used) {
                    // Same slot, same window: one sample, holding the highest reading and the latest time.
                    let merged = Sample(series: s.series, at: s.at, used: max(last.used, s.used), resetsAt: s.resetsAt ?? last.resetsAt)
                    if merged != last { samples[i] = merged; changed = true }
                    continue
                }
            }
            samples.append(s)
            changed = true
        }
        return changed
    }

    /// Folds in another copy's history (the release and a local build share one file), then compacts.
    mutating func merge(_ other: PlanHistory, now: Date = Date()) {
        samples += other.samples
        archived = Self.mergeWindows(archived, other.archived)
        compact(now: now)
    }

    /// One sample per series per slot (per window), readings older than `sampleDays` folded into window summaries,
    /// summaries older than `windowDays` dropped.
    mutating func compact(now: Date = Date()) {
        var kept: [Sample] = []
        var lastIndex: [Series: Int] = [:]
        for s in samples.sorted(by: { $0.at < $1.at }) {
            if let i = lastIndex[s.series] {
                let last = kept[i]
                if Self.slot(last.at) == Self.slot(s.at), Self.sameWindow(last, s, lastUsed: last.used) {
                    kept[i] = Sample(series: s.series, at: s.at, used: max(last.used, s.used), resetsAt: s.resetsAt ?? last.resetsAt)
                    continue
                }
            }
            lastIndex[s.series] = kept.count
            kept.append(s)
        }
        let cutoff = now.addingTimeInterval(-Self.sampleDays * 86400)
        let old = kept.filter { $0.at < cutoff }
        samples = kept.filter { $0.at >= cutoff }
        if !old.isEmpty { archived = Self.mergeWindows(archived, Self.group(old)) }
        let windowCutoff = now.addingTimeInterval(-Self.windowDays * 86400)
        archived = archived.filter { $0.lastSeen >= windowCutoff }.sorted { $0.firstSeen < $1.firstSeen }
    }

    /// Every window on record, oldest first per series, with early resets marked.
    func windows() -> [Window] {
        var all = Self.mergeWindows(archived, Self.group(samples))
        all.sort { ($0.series.code, $0.firstSeen) < ($1.series.code, $1.firstSeen) }
        for i in all.indices.dropLast() where all[i + 1].series == all[i].series {
            if let reset = all[i].resetsAt, all[i + 1].firstSeen < reset.addingTimeInterval(-Self.sameReset) {
                all[i].endedEarly = true
            }
        }
        return all
    }

    /// The readings of the window in progress for a series: its latest window, if it hasn't reset yet.
    func current(_ series: Series, now: Date = Date()) -> [Sample] {
        let mine = samples.filter { $0.series == series }.sorted { $0.at < $1.at }
        guard let last = mine.last, (last.resetsAt ?? last.at.addingTimeInterval(series.kind.length)) > now else { return [] }
        var run: [Sample] = [last]
        for s in mine.dropLast().reversed() {
            guard Self.sameWindow(s, run[0], lastUsed: s.used) else { break }
            run.insert(s, at: 0)
        }
        return run
    }

    // MARK: Grouping

    private static func slot(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / bucket)) }

    /// Whether `next` (taken after `prev`) belongs to the same window. With reset times, they must agree; without,
    /// a drop in usage or a gap longer than the window means a new one.
    static func sameWindow(_ prev: Sample, _ next: Sample, lastUsed: Double) -> Bool {
        switch (prev.resetsAt, next.resetsAt) {
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= sameReset
        default:
            return next.at.timeIntervalSince(prev.at) < prev.series.kind.length && next.used >= lastUsed - 5
        }
    }

    /// Readings into windows, per series.
    static func group(_ samples: [Sample]) -> [Window] {
        var out: [Window] = []
        for series in Set(samples.map(\.series)) {
            var current: Window?
            var prev: Sample?
            for s in samples.filter({ $0.series == series }).sorted(by: { $0.at < $1.at }) {
                if var w = current, let p = prev, sameWindow(p, s, lastUsed: p.used) {
                    w.lastSeen = s.at
                    if s.used > w.peak { w.peak = s.used; w.peakAt = s.at }
                    if w.resetsAt == nil { w.resetsAt = s.resetsAt }
                    current = w
                } else {
                    if let w = current { out.append(w) }
                    current = Window(series: series, resetsAt: s.resetsAt, firstSeen: s.at, lastSeen: s.at, peak: s.used, peakAt: s.at)
                }
                prev = s
            }
            if let w = current { out.append(w) }
        }
        return out
    }

    /// Joins two lists of windows; the same window in both (same series, same reset) becomes one. Windows within one
    /// list are already distinct, so each of `b` is matched only against `a`.
    static func mergeWindows(_ a: [Window], _ b: [Window]) -> [Window] {
        var out = a
        for w in b {
            if let i = out.indices.prefix(a.count).first(where: { same(out[$0], w) }) {
                var m = out[i]
                m.firstSeen = min(m.firstSeen, w.firstSeen)
                m.lastSeen = max(m.lastSeen, w.lastSeen)
                if w.peak > m.peak { m.peak = w.peak; m.peakAt = w.peakAt }
                if m.resetsAt == nil { m.resetsAt = w.resetsAt }
                out[i] = m
            } else {
                out.append(w)
            }
        }
        return out
    }

    private static func same(_ a: Window, _ b: Window) -> Bool {
        guard a.series == b.series else { return false }
        if let ra = a.resetsAt, let rb = b.resetsAt { return abs(ra.timeIntervalSince(rb)) <= sameReset }
        if a.resetsAt != nil || b.resetsAt != nil { return false }
        let length = a.series.kind.length
        return b.firstSeen <= a.lastSeen.addingTimeInterval(length) && a.firstSeen <= b.lastSeen.addingTimeInterval(length)
    }

    // MARK: Summary

    /// How past windows went: how many there were, how many hit the limit or came close, and the typical peak.
    struct Summary: Equatable {
        var count = 0
        var hits = 0
        var near = 0
        var medianPeak: Double = 0
    }

    /// Finished windows (reset by `now`) that ended within the last `days`.
    func summary(_ series: Series, days: Double = 30, now: Date = Date()) -> Summary {
        let since = now.addingTimeInterval(-days * 86400)
        let done = windows().filter { $0.series == series && $0.end <= now && $0.end >= since }
        guard !done.isEmpty else { return Summary() }
        let peaks = done.map(\.peak).sorted()
        let mid = peaks.count / 2
        let median = peaks.count % 2 == 1 ? peaks[mid] : (peaks[mid - 1] + peaks[mid]) / 2
        return Summary(count: done.count, hits: done.filter(\.hitLimit).count,
                       near: done.filter { $0.nearLimit && !$0.hitLimit }.count, medianPeak: median)
    }

    // MARK: Saving

    /// Shared by every copy of Dashbar on this Mac (the release and a local build read the same plan), so it lives in
    /// the release's folder whichever copy writes it. Each copy merges what is on disk before it writes.
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Dashbar", isDirectory: true).appendingPathComponent("plan-history.json")
    }()

    private struct Envelope: Codable {
        var version: Int
        var samples: [Sample]
        var windows: [Window]
    }
    static let version = 1

    static func load(from url: URL) -> PlanHistory? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let env = try? decoder.decode(Envelope.self, from: data), env.version == version else { return nil }
        var h = PlanHistory()
        h.samples = env.samples
        h.archived = env.windows
        return h
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Envelope(version: Self.version, samples: samples, windows: archived)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Keeps the plan history as readings arrive: in memory, written at most every few minutes (and on quit), merged with
/// what another copy of Dashbar wrote in the meantime.
@MainActor
final class PlanHistoryRecorder {
    private let url: URL
    private(set) lazy var history: PlanHistory = {
        var h = PlanHistory.load(from: url) ?? PlanHistory()
        h.compact()
        return h
    }()
    private var dirty = false
    private var lastSave = Date()
    static let saveEvery: TimeInterval = 5 * 60

    init(url: URL = PlanHistory.defaultURL) { self.url = url }

    /// Records the readings; returns whether the history changed (so the store republishes it only then).
    func record(_ limits: [RateLimit], provider: PlanHistory.Provider, at: Date, now: Date = Date()) -> Bool {
        guard history.record(limits, provider: provider, at: at) else { return false }
        dirty = true
        if now.timeIntervalSince(lastSave) >= Self.saveEvery { save(now: now) }
        return true
    }

    func save(now: Date = Date()) {
        guard dirty else { return }
        if let disk = PlanHistory.load(from: url) { history.merge(disk, now: now) } else { history.compact(now: now) }
        history.save(to: url)
        dirty = false
        lastSave = now
    }
}

// MARK: - Usage history

/// The last 30 days of tokens and estimated cost, from the same day ledger the usage card reads (`UsageBook`), so it
/// costs no extra scan. Sessions aren't kept in that ledger, so there is no per-session view.
struct UsageHistory: Equatable {
    struct Day: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let date: Date
        var tokens: Int
        /// Estimated cost at API list prices of the tokens whose model has a price.
        var cost: Double
    }

    static let days = 30
    /// Oldest first; the last is today. Always `days` long once built, with empty days as zero.
    var days: [Day] = []
    var totals = TokenTotals()
    var cost: Double = 0
    var projects: [Ranked] = []
    var models: [Ranked] = []
    /// Models whose tokens have no price, so the cost leaves them out.
    var unpriced: [String] = []
}

extension UsageBook {
    /// Per-day tokens and cost for the last `UsageHistory.days` days, with the top projects and models over them.
    func history(now: Date = Date(), top: Int = 6) -> UsageHistory {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var h = UsageHistory()
        var models: [String: Int] = [:], projects: [String: Int] = [:]
        var modelCost: [String: Double] = [:], projectCost: [String: Double] = [:], unpriced: Set<String> = []
        for offset in (0..<UsageHistory.days).reversed() {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.dayKey.string(from: date)
            let d = days[key]
            let cost = d?.costByModel.values.reduce(0, +) ?? 0
            h.days.append(.init(key: key, date: date, tokens: d?.totals.total ?? 0, cost: cost))
            guard let d else { continue }
            h.totals.add(d.totals)
            h.cost += cost
            for (k, v) in d.byModel { models[k, default: 0] += v }
            for (k, v) in d.byProject { projects[k, default: 0] += v }
            for (k, v) in d.costByModel { modelCost[k, default: 0] += v }
            for (k, v) in d.costByProject { projectCost[k, default: 0] += v }
            unpriced.formUnion(d.unpricedByModel.keys)
        }
        func rank(_ m: [String: Int], _ c: [String: Double]) -> [Ranked] {
            m.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(top).map { Ranked(name: $0.key, value: $0.value, cost: c[$0.key]) }
        }
        h.models = rank(models, modelCost)
        h.projects = rank(projects, projectCost)
        h.unpriced = unpriced.sorted()
        return h
    }
}
