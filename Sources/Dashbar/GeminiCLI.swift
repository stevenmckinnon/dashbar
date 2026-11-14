import Foundation
import Darwin

// MARK: - Gemini CLI usage (~/.gemini/tmp/<project>/chats/session-*.jsonl)

/// Reads Gemini CLI's session logs incrementally, like the Claude Code and Codex scanners.
///
/// Each session is a JSONL file: a header (`sessionId`, `projectHash`, `startTime`…), then one record per message
/// (`id`, `timestamp`, `type`: "user" or "gemini", `content`), with `{"$set": …}` updates in between. A "gemini" record
/// is written again under the same `id` when its token counts arrive (`model`, `tokens`: input, output, cached,
/// thoughts, tool, total), so only what a message's counts grew by is added. Message text is never kept.
final class GeminiUsageScanner {
    static let defaultRoot = homeDir.appendingPathComponent(".gemini/tmp")

    private var tail: JSONLTail
    private var book = UsageBook()
    /// Token counts seen per message, keyed by file then message id, so a rewritten record only adds its growth.
    private var seen: [String: [String: TokenTotals]] = [:]
    /// "gemini" records still without token counts, and when they were written. One that never gets counts means the
    /// format changed (see `scan`).
    private var pending: [String: Date] = [:]
    private var lastActivity: [String: Date] = [:]
    private var health = FormatHealth(source: "Gemini CLI")
    private let cache: ScanCache<State>?
    private var dirty = false
    /// Project folder names by project directory (from its `.project_root`), read once each.
    private var projects: [String: String] = [:]

    struct State: Codable {
        var root: String
        var offsets: [String: UInt64]
        var book: UsageBook
        var seen: [String: [String: TokenTotals]]
        var lastActivity: [String: Date]
    }

    /// How long a "gemini" record may wait for its token counts before it counts against the format.
    static let tokenGrace: TimeInterval = 10 * 60

    init(root: URL = GeminiUsageScanner.defaultRoot, cache: URL? = nil) {
        tail = JSONLTail(root: root, needles: ["\"gemini\"", "\"tokens\""])
        self.cache = cache.map { ScanCache(url: $0) }
        if let saved = self.cache?.load(), saved.root == root.path {
            tail.offsets = saved.offsets
            book = saved.book
            seen = saved.seen
            lastActivity = saved.lastActivity
        }
    }

    var currentBook: UsageBook { book }
    /// Gemini CLI has saved sessions on this Mac.
    var found: Bool { !tail.offsets.isEmpty }

    func scan(now: Date = Date()) -> UsageSummary {
        guard tail.exists else { return .empty }
        tail.scan { line in
            guard let obj = line.json else { health.record(false, recent: line.recent); return }
            ingest(obj, file: line.path, recent: line.recent)
        }
        for path in tail.changed { lastActivity[path] = now; dirty = true }
        // A reply whose counts never came: the field was renamed or moved.
        for (key, at) in pending where now.timeIntervalSince(at) > Self.tokenGrace {
            health.record(false, recent: now.timeIntervalSince(at) < 2 * 86400)
            pending[key] = nil
        }
        let quiet = lastActivity.filter { now.timeIntervalSince($0.value) > 3_600 }.map(\.key)
        for path in quiet { seen[path] = nil; lastActivity[path] = nil }
        book.prune(now: now)
        guard found else { return .empty }
        var s = book.summary(found: true)
        s.warning = health.warning
        return s
    }

    func save() {
        guard dirty, let cache else { return }
        cache.save(State(root: tail.root.path, offsets: tail.offsets, book: book, seen: seen, lastActivity: lastActivity))
        dirty = false
    }

    private func ingest(_ obj: [String: Any], file: String, recent: Bool) {
        guard obj["type"] as? String == "gemini", let id = obj["id"] as? String else { return }
        let date = (obj["timestamp"] as? String).flatMap(Date.fromISO) ?? Date()
        let key = file + "|" + id
        guard let tokens = obj["tokens"] else {
            if pending[key] == nil, seen[file]?[id] == nil { pending[key] = date }
            return
        }
        guard let t = tokens as? [String: Any], let input = t["input"] as? Int, let output = t["output"] as? Int else {
            health.record(false, recent: recent)
            return
        }
        health.record(true, recent: recent)
        pending[key] = nil
        let cached = t["cached"] as? Int ?? 0, thoughts = t["thoughts"] as? Int ?? 0, tool = t["tool"] as? Int ?? 0
        // The prompt count includes cached tokens; thinking is billed as output; tool-use prompts as input.
        let totals = TokenTotals(input: max(0, input - cached) + tool, output: output + thoughts, cacheRead: cached, messages: 1)
        let old = seen[file]?[id] ?? TokenTotals()
        let delta = totals.growth(since: old)
        seen[file, default: [:]][id] = totals.fieldMax(old)
        guard delta.total > 0 else { return }
        let model = obj["model"] as? String ?? "gemini"
        let cost = Pricing.cost(delta, model: model, promptTokens: input + tool)
        book.add(delta, at: date, model: model, project: project(ofFile: file), session: file, cost: cost)
    }

    /// `<root>/<project>/chats/<session>.jsonl`: the project's folder name from its `.project_root`, else the
    /// directory's own name.
    private func project(ofFile file: String) -> String {
        let dir = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        if let known = projects[dir.path] { return known }
        let name = GeminiCLI.projectRoot(of: dir).map(Fmt.project(fromCwd:)) ?? dir.lastPathComponent
        projects[dir.path] = name
        return name
    }
}

// MARK: - Live Gemini CLI sessions

enum GeminiCLI {
    /// The full path of the folder a Gemini CLI project directory is for (`.project_root`), if it says.
    static func projectRoot(of dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(".project_root"), options: .uncached),
              data.count < 4096,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("/") else { return nil }
        return text
    }

    /// A Gemini CLI process: `gemini` itself, or Node running its script (`node …/bin/gemini`, `…/@google/gemini-cli/…`).
    static func isGemini(name: String, commandLine: String?) -> Bool {
        if name == "gemini" { return true }
        guard ["node", "bun"].contains(name), let commandLine else { return false }
        return commandLine.split(separator: " ").dropFirst().contains { arg in
            arg.hasSuffix("/gemini") || arg == "gemini" || arg.contains("/@google/gemini-cli/") || arg.contains("/gemini-cli/")
        }
    }

    /// Seconds since the last write after which a session counts as idle.
    static let activeWindow: TimeInterval = 20

    /// One live session per Gemini CLI process. `activity` gives when that folder's newest session log was last written.
    static func live(processes: [(pid: Int32, cwd: String, started: Date?)], activity: (String) -> Date?,
                     busySince: inout [Int32: Date], now: Date = Date(),
                     root: (String) -> String = Fmt.root(fromCwd:)) -> [LiveSession] {
        var out: [LiveSession] = []
        var live = Set<Int32>()
        for p in processes {
            let r = root(p.cwd.isEmpty ? homeDir.path : p.cwd)
            let last = activity(r)
            let busy = last.map { now.timeIntervalSince($0) < activeWindow } ?? false
            live.insert(p.pid)
            if busy { if busySince[p.pid] == nil { busySince[p.pid] = last ?? now } } else { busySince[p.pid] = nil }
            var s = LiveSession(id: "gemini-\(p.pid)", pid: p.pid, name: Fmt.project(fromCwd: r), cwd: p.cwd,
                                status: busy ? "busy" : "idle",
                                since: busy ? busySince[p.pid] ?? now : (last ?? p.started ?? now), entrypoint: "cli", root: r)
            s.agent = .geminiCLI
            out.append(s)
        }
        busySince = busySince.filter { live.contains($0.key) }
        return out
    }
}

/// Finds Google's agents among running processes in one pass: Gemini CLI, the Antigravity CLI and the Antigravity app.
/// Command lines are read only for Node processes, once per process.
final class GoogleProcesses {
    enum Kind { case gemini, agy, antigravityApp }

    struct Found {
        var gemini: [(pid: Int32, cwd: String, started: Date?)] = []
        var agy: [(pid: Int32, root: String)] = []
        var appRunning = false
    }

    private var known: [Int32: (started: Date?, kind: Kind?)] = [:]

    func scan() -> Found {
        var out = Found()
        var seen = Set<Int32>()
        var gemini: [Int32: (cwd: String, started: Date?, parent: Int32)] = [:]
        for pid in Proc.allPIDs() {
            let name = Proc.name(pid)
            guard ["node", "bun", "gemini", "agy", "Antigravity"].contains(name) else { continue }
            seen.insert(pid)
            let info = Proc.bsdInfo(pid)
            var kind: Kind?
            if let hit = known[pid], hit.started == info?.started {
                kind = hit.kind
            } else {
                switch name {
                case "agy": kind = .agy
                case "Antigravity": kind = (Proc.path(pid)?.contains("/Antigravity.app/Contents/MacOS/") ?? false) ? .antigravityApp : nil
                default: kind = GeminiCLI.isGemini(name: name, commandLine: Proc.commandLine(pid)) ? .gemini : nil
                }
                known[pid] = (info?.started, kind)
            }
            switch kind {
            case .gemini?: gemini[pid] = (Proc.cwd(pid) ?? "", info?.started, info?.parent ?? 0)
            case .agy?: out.agy.append((pid, Fmt.root(fromCwd: Proc.cwd(pid) ?? homeDir.path)))
            case .antigravityApp?: out.appRunning = true
            case nil: break
            }
        }
        known = known.filter { seen.contains($0.key) }
        // Gemini CLI relaunches itself as a child with more memory: count the outermost process only.
        out.gemini = gemini.filter { gemini[$0.value.parent] == nil }.map { ($0.key, $0.value.cwd, $0.value.started) }
            .sorted { $0.pid < $1.pid }
        return out
    }
}

/// Collects every Google agent's live sessions for the store's live refresh. Cheap when none of them is installed:
/// one pass over process names, and a few stat calls.
final class GoogleCollector {
    private let processes = GoogleProcesses()
    private let app = AntigravityApp()
    private var busySince: [Int32: Date] = [:]
    /// Gemini CLI project directories by the folder they're for, re-listed at most once a minute.
    private var geminiDirs: [String: URL] = [:]
    private var geminiDirsAt = Date.distantPast
    let geminiRoot: URL
    let agySessions: URL

    init(geminiRoot: URL = GeminiUsageScanner.defaultRoot, agySessions: URL = AntigravityStatusLine.sessionsDir) {
        self.geminiRoot = geminiRoot
        self.agySessions = agySessions
    }

    func read(now: Date = Date()) -> GoogleLive {
        let found = processes.scan()
        var out = GoogleLive()
        if !found.gemini.isEmpty {
            out.sessions += GeminiCLI.live(processes: found.gemini, activity: { [self] root in latestActivity(root, now: now) },
                                           busySince: &busySince, now: now)
        }
        if FileManager.default.fileExists(atPath: agySessions.path) {
            out.sessions += AntigravityStatusLine.live(AntigravityStatusLine.readSessions(dir: agySessions, maxAge: 12 * 3600, now: now),
                                                       processes: found.agy, now: now)
        }
        if found.appRunning {
            let reading = app.read(now: now)
            out.sessions += reading.sessions
            out.warning = reading.warning
        }
        return out
    }

    /// When the newest session log of the Gemini CLI project for this folder was last written.
    private func latestActivity(_ root: String, now: Date) -> Date? {
        if now.timeIntervalSince(geminiDirsAt) > 60 || geminiDirs[root] == nil && now.timeIntervalSince(geminiDirsAt) > 5 {
            geminiDirsAt = now
            var map: [String: URL] = [:]
            for dir in (try? FileManager.default.contentsOfDirectory(at: geminiRoot, includingPropertiesForKeys: nil)) ?? [] {
                if let r = GeminiCLI.projectRoot(of: dir) { map[Fmt.root(fromCwd: r)] = dir }
            }
            geminiDirs = map
        }
        guard let dir = geminiDirs[root] else { return nil }
        let chats = dir.appendingPathComponent("chats")
        let files = (try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }
}
