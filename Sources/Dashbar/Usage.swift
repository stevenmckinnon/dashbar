import Foundation

struct TokenTotals: Equatable, Codable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var messages = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ o: TokenTotals) {
        input += o.input; output += o.output
        cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
        messages += o.messages
    }

    /// Field-wise positive growth from `old` to `self` (for streamed/cumulative records).
    func growth(since old: TokenTotals) -> TokenTotals {
        TokenTotals(input: max(0, input - old.input), output: max(0, output - old.output),
                    cacheRead: max(0, cacheRead - old.cacheRead), cacheWrite: max(0, cacheWrite - old.cacheWrite),
                    messages: max(0, messages - old.messages))
    }

    func fieldMax(_ o: TokenTotals) -> TokenTotals {
        TokenTotals(input: max(input, o.input), output: max(output, o.output),
                    cacheRead: max(cacheRead, o.cacheRead), cacheWrite: max(cacheWrite, o.cacheWrite),
                    messages: max(messages, o.messages))
    }
}

struct DayUsage: Codable {
    var totals = TokenTotals()
    var byModel: [String: Int] = [:]
    var byProject: [String: Int] = [:]
}

struct DayPoint: Identifiable {
    let id: String
    let date: Date
    let tokens: Int
    let isToday: Bool
}

struct HourPoint: Identifiable {
    let id: Date
    let tokens: Int
    let messages: Int
    let isNow: Bool
    var date: Date { id }
}

struct Ranked: Identifiable {
    var id: String { name }
    let name: String
    let value: Int
}

struct UsageSummary {
    var found = false
    var today = TokenTotals()
    var week = TokenTotals()
    var last14: [DayPoint] = []
    var topModels: [Ranked] = []
    var topProjects: [Ranked] = []
    var last24: [HourPoint] = []
    var tokens24 = 0
    var sessions24 = 0
    /// Set when logs exist but none could be read, which usually means the format changed.
    var warning: String?

    static let empty = UsageSummary()
}

/// Day-bucketed token ledger shared by all agent scanners.
struct UsageBook: Codable {
    struct HourBucket: Codable {
        var tokens = 0
        var messages = 0
        var sessions = Set<String>()
    }

    private(set) var days: [String: DayUsage] = [:]
    private(set) var hours: [Date: HourBucket] = [:]

    private enum CodingKeys: String, CodingKey { case days, hours }

    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    mutating func add(_ t: TokenTotals, at date: Date, model: String, project: String, session: String? = nil) {
        guard t.total > 0 || t.messages > 0 else { return }
        let key = Self.dayKey.string(from: date)
        var d = days[key] ?? DayUsage()
        d.totals.add(t)
        d.byModel[model, default: 0] += t.total
        d.byProject[project, default: 0] += t.total
        days[key] = d

        let hour = Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
        var b = hours[hour] ?? HourBucket()
        b.tokens += t.total
        b.messages += t.messages
        if let session { b.sessions.insert(session) }
        hours[hour] = b
    }

    /// Drops buckets older than anything the panel shows, so the ledger stays a fixed size.
    mutating func prune(now: Date = Date()) {
        let cutoffDay = Self.dayKey.string(from: now.addingTimeInterval(-31 * 86_400))
        days = days.filter { $0.key >= cutoffDay }
        let cutoffHour = now.addingTimeInterval(-26 * 3_600)
        hours = hours.filter { $0.key >= cutoffHour }
    }

    func summary(found: Bool) -> UsageSummary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var s = UsageSummary(found: found)
        for offset in (0..<14).reversed() {
            let date = cal.date(byAdding: .day, value: -offset, to: today)!
            let key = Self.dayKey.string(from: date)
            let d = days[key]
            s.last14.append(DayPoint(id: key, date: date, tokens: d?.totals.total ?? 0, isToday: offset == 0))
            if offset < 7, let d { s.week.add(d.totals) }
        }
        let t = days[Self.dayKey.string(from: today)] ?? DayUsage()
        s.today = t.totals
        s.topModels = t.byModel.sorted { $0.value > $1.value }.prefix(3).map { Ranked(name: $0.key, value: $0.value) }
        s.topProjects = t.byProject.sorted { $0.value > $1.value }.prefix(4).map { Ranked(name: $0.key, value: $0.value) }

        let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        var sessions = Set<String>()
        for offset in (0..<24).reversed() {
            let h = cal.date(byAdding: .hour, value: -offset, to: nowHour)!
            let b = hours[h]
            s.last24.append(HourPoint(id: h, tokens: b?.tokens ?? 0, messages: b?.messages ?? 0, isNow: offset == 0))
            if let b { sessions.formUnion(b.sessions); s.tokens24 += b.tokens }
        }
        s.sessions24 = sessions.count
        return s
    }
}

/// Reads JSONL files under a root incrementally: each pass only parses bytes appended since the last pass.
struct JSONLTail {
    let root: URL
    let needle: Data
    var windowDays = 30
    /// Bytes consumed per file. Saved between launches so a restart only reads new lines.
    var offsets: [String: UInt64] = [:]
    /// Files that had new lines in the most recent scan.
    private(set) var changed: Set<String> = []

    init(root: URL, needle: String) {
        self.root = root
        self.needle = Data(needle.utf8)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// Calls `handle(path, json)` for each new complete line containing the needle.
    mutating func scan(_ handle: (String, [String: Any]) -> Void) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        var live: [String: UInt64] = [:]
        changed = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  let mtime = rv.contentModificationDate, mtime >= cutoff,
                  let size = rv.fileSize.map(UInt64.init) else { continue }
            var offset = offsets[url.path] ?? 0
            if size < offset { offset = 0 } // file was rewritten
            if size > offset {
                offset = read(url, from: offset) { handle(url.path, $0) }
                changed.insert(url.path)
            }
            live[url.path] = offset
        }
        offsets = live // forget deleted files and ones that aged out of the window
    }

    private func read(_ url: URL, from offset: UInt64, _ handle: ([String: Any]) -> Void) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil else { return offset }
        var consumed = offset
        var carry = Data()
        while true {
            let more: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                carry.append(chunk)
                guard let lastNL = carry.lastIndex(of: 0x0A) else { return true } // very long line; keep reading
                var start = carry.startIndex
                while start <= lastNL {
                    let end = carry[start...lastNL].firstIndex(of: 0x0A)!
                    let line = carry[start..<end]
                    if line.range(of: needle) != nil,
                       let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        handle(obj)
                    }
                    start = end + 1
                }
                consumed += UInt64(lastNL - carry.startIndex + 1)
                carry = Data(carry[(lastNL + 1)...])
                return true
            }
            if !more { break }
        }
        return consumed
    }
}

// MARK: - Claude Code

/// Parses ~/.claude/projects/**/*.jsonl assistant messages.
final class ClaudeUsageScanner {
    static let defaultRoot = homeDir.appendingPathComponent(".claude/projects")

    private var tail: JSONLTail
    private var book = UsageBook()
    /// The same message is written once per content block; keep the largest usage seen per message.
    /// Keyed by file so a file that has gone quiet can be forgotten: its messages are complete.
    private var seen: [String: [String: TokenTotals]] = [:]
    private var lastActivity: [String: Date] = [:]
    private var health = FormatHealth(source: "Claude Code")
    private let cache: ScanCache<State>?
    private var dirty = false

    struct State: Codable {
        var root: String
        var offsets: [String: UInt64]
        var book: UsageBook
        var seen: [String: [String: TokenTotals]]
        var lastActivity: [String: Date]
    }

    init(root: URL = ClaudeUsageScanner.defaultRoot, cache: URL? = nil) {
        tail = JSONLTail(root: root, needle: "\"output_tokens\"")
        self.cache = cache.map { ScanCache(url: $0) }
        if let saved = self.cache?.load(), saved.root == root.path {
            tail.offsets = saved.offsets
            book = saved.book
            seen = saved.seen
            lastActivity = saved.lastActivity
        }
    }

    func scan() -> UsageSummary {
        guard tail.exists else { return .empty }
        var currentFile = ""
        tail.scan { path, obj in
            currentFile = path
            health.candidates += 1
            if ingest(obj, file: currentFile) { health.parsed += 1 }
        }
        let now = Date()
        for path in tail.changed { lastActivity[path] = now; dirty = true }
        // Messages in a file quiet for an hour are finished, so their de-dup entries can go.
        let quiet = lastActivity.filter { now.timeIntervalSince($0.value) > 3_600 }.map(\.key)
        for path in quiet { seen[path] = nil; lastActivity[path] = nil }
        book.prune(now: now)
        var s = book.summary(found: true)
        s.warning = health.warning
        return s
    }

    /// Writes progress to disk if anything changed since the last save.
    func save() {
        guard dirty, let cache else { return }
        cache.save(State(root: tail.root.path, offsets: tail.offsets, book: book, seen: seen, lastActivity: lastActivity))
        dirty = false
    }

    /// Returns whether the line had the shape we expect (even if it's deliberately skipped).
    @discardableResult
    private func ingest(_ obj: [String: Any], file: String) -> Bool {
        guard let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { return false }
        guard obj["type"] as? String == "assistant",
              let ts = obj["timestamp"] as? String, let date = Date.fromISO(ts) else { return true }
        let model = msg["model"] as? String ?? "unknown"
        if model == "<synthetic>" { return true }

        let t = TokenTotals(input: u["input_tokens"] as? Int ?? 0,
                            output: u["output_tokens"] as? Int ?? 0,
                            cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                            cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                            messages: 1)
        let key = "\(msg["id"] as? String ?? UUID().uuidString)|\(obj["requestId"] as? String ?? "")"
        let old = seen[file]?[key] ?? TokenTotals()
        let delta = t.growth(since: old)
        seen[file, default: [:]][key] = t.fieldMax(old)

        let project = (obj["cwd"] as? String).map(Fmt.project(fromCwd:)) ?? "unknown"
        book.add(delta, at: date, model: Fmt.model(model), project: project, session: obj["sessionId"] as? String)
        return true
    }
}

/// Counts lines that look like usage records against lines we could actually read.
/// Many candidates and zero successes means the tool changed its log format.
struct FormatHealth {
    let source: String
    var candidates = 0
    var parsed = 0

    var warning: String? {
        candidates >= 20 && parsed == 0
            ? "Couldn't read \(source) usage. Its log format may have changed, so check for a Dashbar update."
            : nil
    }
}

// MARK: - Codex

struct RateLimit: Identifiable, Codable {
    var id: String { label }
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    /// How long the window lasts, when known, for working out the pace.
    var window: TimeInterval? = nil
}

extension RateLimit {
    enum Pace: Equatable {
        /// Using well under the even rate for the time that has passed.
        case under
        /// Close to the even rate; it should last until the reset.
        case onPace
        /// At the current rate it runs out before the reset.
        case runsOut(Date)
        case usedUp
    }

    /// The share used if usage were spread evenly across the window, given how much of it has passed.
    func expectedPercent(now: Date = Date()) -> Double? {
        guard let window, window > 0, let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= window * 1.02 else { return nil }
        return min(100, max(0, (1 - remaining / window) * 100))
    }

    /// Projects the current rate to the reset. Nil when too little of the window has passed to tell.
    func pace(now: Date = Date()) -> Pace? {
        if usedPercent >= 100 { return .usedUp }
        guard let expected = expectedPercent(now: now), expected >= 5,
              let window, let resetsAt else { return nil }
        let elapsed = window * expected / 100
        let perSecond = usedPercent / elapsed
        if perSecond > 0 {
            let runsOut = now.addingTimeInterval((100 - usedPercent) / perSecond)
            if runsOut < resetsAt { return .runsOut(runsOut) }
        }
        return usedPercent < expected - 10 ? .under : .onPace
    }
}

/// Parses ~/.codex/sessions/**/rollout-*.jsonl `token_count` events (cumulative per session).
final class CodexUsageScanner {
    static let defaultRoot = homeDir.appendingPathComponent(".codex/sessions")

    private var tail: JSONLTail
    private var book = UsageBook()
    private var health = FormatHealth(source: "Codex")
    private let cache: ScanCache<State>?
    private var dirty = false

    struct FileContext: Codable {
        var model = "codex"
        var project = "unknown"
        var cumulative = TokenTotals()
    }

    struct State: Codable {
        var root: String
        var offsets: [String: UInt64]
        var book: UsageBook
        var fileCtx: [String: FileContext]
        var limits: [RateLimit]
        var limitsStamp: Date
    }

    init(root: URL = CodexUsageScanner.defaultRoot, cache: URL? = nil) {
        tail = JSONLTail(root: root, needle: "\"type\":\"")
        self.cache = cache.map { ScanCache(url: $0) }
        if let saved = self.cache?.load(), saved.root == root.path {
            tail.offsets = saved.offsets
            book = saved.book
            fileCtx = saved.fileCtx
            limits = saved.limits
            limitsStamp = saved.limitsStamp
        }
    }

    func save() {
        guard dirty, let cache else { return }
        cache.save(State(root: tail.root.path, offsets: tail.offsets, book: book, fileCtx: fileCtx, limits: limits, limitsStamp: limitsStamp))
        dirty = false
    }

    private var fileCtx: [String: FileContext] = [:]
    private(set) var limits: [RateLimit] = []
    private var limitsStamp = Date.distantPast

    func scan() -> UsageSummary {
        guard tail.exists else { return .empty }
        tail.scan { path, obj in ingest(path, obj) }
        if !tail.changed.isEmpty { dirty = true }
        // Keep per-file context only for files still in the scan window.
        fileCtx = fileCtx.filter { tail.offsets[$0.key] != nil }
        book.prune()
        var s = book.summary(found: true)
        s.warning = health.warning
        return s
    }

    private func ingest(_ path: String, _ obj: [String: Any]) {
        guard let payload = obj["payload"] as? [String: Any] else { return }
        var ctx = fileCtx[path] ?? FileContext()
        defer { fileCtx[path] = ctx }

        switch obj["type"] as? String {
        case "session_meta":
            if let cwd = payload["cwd"] as? String { ctx.project = Fmt.project(fromCwd: cwd) }
        case "turn_context":
            if let m = payload["model"] as? String { ctx.model = m }
            if let cwd = payload["cwd"] as? String { ctx.project = Fmt.project(fromCwd: cwd) }
        case "event_msg" where payload["type"] as? String == "token_count":
            let date = (obj["timestamp"] as? String).flatMap(Date.fromISO) ?? Date()
            health.candidates += 1
            // `info` is null on the first event of a session; only a present-but-unreadable shape counts against us.
            if payload["info"] is NSNull || payload["info"] == nil { health.parsed += 1 }
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                health.parsed += 1
                let input = total["input_tokens"] as? Int ?? 0
                let cached = total["cached_input_tokens"] as? Int ?? 0
                let output = (total["output_tokens"] as? Int ?? 0)
                let cum = TokenTotals(input: max(0, input - cached), output: output, cacheRead: cached)
                var delta = cum.growth(since: ctx.cumulative)
                if delta.total > 0 { delta.messages = 1 }
                ctx.cumulative = cum.fieldMax(ctx.cumulative)
                book.add(delta, at: date, model: ctx.model, project: ctx.project, session: path)
            }
            if let rl = payload["rate_limits"] as? [String: Any], date >= limitsStamp {
                limitsStamp = date
                limits = [("primary", "5h"), ("secondary", "Weekly")].compactMap { key, fallback in
                    guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
                    let label = (w["window_minutes"] as? Int).map { $0 >= 1440 ? "\($0 / 1440)d" : "\($0 / 60)h" } ?? fallback
                    var reset: Date?
                    if let at = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: at) }
                    else if let s = w["resets_in_seconds"] as? Double { reset = date.addingTimeInterval(s) }
                    return RateLimit(label: label + " window", usedPercent: used, resetsAt: reset,
                                     window: (w["window_minutes"] as? Int).map { TimeInterval($0 * 60) })
                }
            }
        default: break
        }
    }
}


// MARK: - Saved scan progress

/// A versioned JSON file in Application Support. A missing, unreadable or older-version
/// file is ignored, and the scan simply starts from scratch.
struct ScanCache<State: Codable> {
    static var version: Int { 1 }
    let url: URL

    private struct Envelope: Codable {
        let version: Int
        let state: State
    }

    func load() -> State? {
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.version == Self.version else { return nil }
        return env.state
    }

    func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(Envelope(version: Self.version, state: state)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// ~/Library/Application Support/Dashbar/<name>
    static func defaultURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Dashbar", isDirectory: true).appendingPathComponent(name)
    }
}
