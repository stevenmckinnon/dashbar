import Foundation

struct TokenTotals: Equatable {
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

struct DayUsage {
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

    static let empty = UsageSummary()
}

/// Day-bucketed token ledger shared by all agent scanners.
struct UsageBook {
    private(set) var days: [String: DayUsage] = [:]

    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    mutating func add(_ t: TokenTotals, at date: Date, model: String, project: String) {
        guard t.total > 0 || t.messages > 0 else { return }
        let key = Self.dayKey.string(from: date)
        var d = days[key] ?? DayUsage()
        d.totals.add(t)
        d.byModel[model, default: 0] += t.total
        d.byProject[project, default: 0] += t.total
        days[key] = d
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
        return s
    }
}

/// Reads JSONL files under a root incrementally: each pass only parses bytes appended since the last pass.
struct JSONLTail {
    let root: URL
    let needle: Data
    var windowDays = 30
    private var offsets: [String: UInt64] = [:]

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
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  let mtime = rv.contentModificationDate, mtime >= cutoff,
                  let size = rv.fileSize.map(UInt64.init) else { continue }
            var offset = offsets[url.path] ?? 0
            if size < offset { offset = 0 } // file was rewritten
            guard size > offset else { continue }
            offsets[url.path] = read(url, from: offset) { handle(url.path, $0) }
        }
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
    private var tail = JSONLTail(root: homeDir.appendingPathComponent(".claude/projects"), needle: "\"output_tokens\"")
    private var book = UsageBook()
    /// The same message is written once per content block; keep the largest usage seen per message.
    private var seen: [String: TokenTotals] = [:]

    func scan() -> UsageSummary {
        guard tail.exists else { return .empty }
        tail.scan { _, obj in ingest(obj) }
        return book.summary(found: true)
    }

    private func ingest(_ obj: [String: Any]) {
        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String, let date = Date.fromISO(ts) else { return }
        let model = msg["model"] as? String ?? "unknown"
        if model == "<synthetic>" { return }

        let t = TokenTotals(input: u["input_tokens"] as? Int ?? 0,
                            output: u["output_tokens"] as? Int ?? 0,
                            cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                            cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                            messages: 1)
        let key = "\(msg["id"] as? String ?? UUID().uuidString)|\(obj["requestId"] as? String ?? "")"
        let old = seen[key] ?? TokenTotals()
        let delta = t.growth(since: old)
        seen[key] = t.fieldMax(old)

        let project = (obj["cwd"] as? String).map(Fmt.project(fromCwd:)) ?? "unknown"
        book.add(delta, at: date, model: Fmt.model(model), project: project)
    }
}

// MARK: - Codex

struct RateLimit: Identifiable {
    var id: String { label }
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

/// Parses ~/.codex/sessions/**/rollout-*.jsonl `token_count` events (cumulative per session).
final class CodexUsageScanner {
    private var tail = JSONLTail(root: homeDir.appendingPathComponent(".codex/sessions"), needle: "\"type\":\"")
    private var book = UsageBook()
    private var fileCtx: [String: (model: String, project: String, cumulative: TokenTotals)] = [:]
    private(set) var limits: [RateLimit] = []
    private var limitsStamp = Date.distantPast

    func scan() -> UsageSummary {
        guard tail.exists else { return .empty }
        tail.scan { path, obj in ingest(path, obj) }
        return book.summary(found: true)
    }

    private func ingest(_ path: String, _ obj: [String: Any]) {
        guard let payload = obj["payload"] as? [String: Any] else { return }
        var ctx = fileCtx[path] ?? (model: "codex", project: "unknown", cumulative: TokenTotals())
        defer { fileCtx[path] = ctx }

        switch obj["type"] as? String {
        case "session_meta":
            if let cwd = payload["cwd"] as? String { ctx.project = Fmt.project(fromCwd: cwd) }
        case "turn_context":
            if let m = payload["model"] as? String { ctx.model = m }
            if let cwd = payload["cwd"] as? String { ctx.project = Fmt.project(fromCwd: cwd) }
        case "event_msg" where payload["type"] as? String == "token_count":
            let date = (obj["timestamp"] as? String).flatMap(Date.fromISO) ?? Date()
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                let input = total["input_tokens"] as? Int ?? 0
                let cached = total["cached_input_tokens"] as? Int ?? 0
                let output = (total["output_tokens"] as? Int ?? 0)
                let cum = TokenTotals(input: max(0, input - cached), output: output, cacheRead: cached)
                var delta = cum.growth(since: ctx.cumulative)
                if delta.total > 0 { delta.messages = 1 }
                ctx.cumulative = cum.fieldMax(ctx.cumulative)
                book.add(delta, at: date, model: ctx.model, project: ctx.project)
            }
            if let rl = payload["rate_limits"] as? [String: Any], date >= limitsStamp {
                limitsStamp = date
                limits = [("primary", "5h"), ("secondary", "Weekly")].compactMap { key, fallback in
                    guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
                    let label = (w["window_minutes"] as? Int).map { $0 >= 1440 ? "\($0 / 1440)d" : "\($0 / 60)h" } ?? fallback
                    var reset: Date?
                    if let at = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: at) }
                    else if let s = w["resets_in_seconds"] as? Double { reset = date.addingTimeInterval(s) }
                    return RateLimit(label: label + " window", usedPercent: used, resetsAt: reset)
                }
            }
        default: break
        }
    }
}
