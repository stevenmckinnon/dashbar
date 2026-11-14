import Foundation

// MARK: - Subagents of live Claude Code sessions

/// One subagent (Agent or Task tool) of a live Claude Code session.
///
/// Claude Code keeps each one beside the session's transcript, in `<projects>/<project>/<sessionId>/subagents/`:
/// `agent-<id>.jsonl` is its transcript (records carry `isSidechain: true` and `agentId`) and `agent-<id>.meta.json`
/// says what it is (`description`, `agentType`, `model`, `requestShape` "foreground" or "background") and gains
/// `finished: true` when it ends.
struct Subagent: Identifiable, Equatable {
    let id: String
    let description: String
    /// "general-purpose", "Explore", a custom agent's name.
    let type: String
    /// The model its last reply used (a display name), or the alias it was asked for.
    var model: String?
    let background: Bool
    let started: Date
    var lastActivity: Date
    var finished: Bool
    /// When it finished, so a finished one can drop off after `SubagentReader.linger`.
    var finishedAt: Date?
    /// Tokens it has used so far (input, output and cache), when its transcript was read.
    var tokens: Int = 0

    var isRunning: Bool { !finished }
    /// "Explore · Sonnet 4.6 · background"
    var detail: String {
        ([type, model, background ? "background" : nil] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }
}

extension Array where Element == Subagent {
    var running: [Subagent] { filter(\.isRunning) }

    /// "4 subagents running", "1 subagent running · 1 done", "2 subagents done".
    var summary: String {
        let r = running.count, done = count - r
        if r == 0 { return done == 1 ? "1 subagent done" : "\(done) subagents done" }
        let lead = r == 1 ? "1 subagent running" : "\(r) subagents running"
        return done > 0 ? lead + " · \(done) done" : lead
    }

    /// One line per subagent for a tooltip: "Review the diff · 4m".
    func tooltip(now: Date = Date()) -> String {
        map { a in "\(a.description) · " + (a.isRunning ? Fmt.ago(a.started, now: now) : "done") }.joined(separator: "\n")
    }
}

/// Lists each live session's subagents. It reads only what changed: a metadata file again only when it was modified,
/// and a transcript only from where the last pass stopped (and only with `detail`, for the open panel or window).
final class SubagentReader {
    /// How long a finished subagent stays listed.
    static let linger: TimeInterval = 90
    /// A subagent that hasn't written for this long, without saying it finished, is taken to have stopped.
    static let quiet: TimeInterval = 30 * 60

    static let formatWarning = "Couldn't read Claude Code's subagents. Its subagent file format may have changed, so check for a Dashbar update."

    struct Reading: Equatable {
        /// Keyed by session ID. Sessions without subagents to show are left out.
        var bySession: [String: [Subagent]] = [:]
        var warning: String?
        var runningCount: Int { bySession.values.reduce(0) { $0 + $1.running.count } }
    }

    private struct Meta {
        let mtime: Date
        let created: Date
        let description: String
        let type: String
        let model: String?
        let background: Bool
        let finished: Bool
    }

    private struct Tail {
        var offset: UInt64 = 0
        /// The largest usage seen per message: the same message is written once per content block.
        var perMessage: [String: Int] = [:]
        var model: String?
        var last: Date?
        var tokens: Int { perMessage.values.reduce(0, +) }
    }

    private var metas: [String: Meta] = [:]
    private var tails: [String: Tail] = [:]
    private let needle = Data("\"usage\"".utf8)

    init() {}

    /// `transcript` finds a session's transcript (`<sessionId>.jsonl`); its subagents sit in the folder of the same name.
    func read(_ sessions: [LiveSession], transcript: (LiveSession) -> URL?, detail: Bool, now: Date = Date()) -> Reading {
        var out = Reading()
        var seen = Set<String>()
        var unreadable = false
        for s in sessions {
            guard let t = transcript(s) else { continue }
            let dir = t.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            let r = read(dir: dir, sessionStarted: s.startedAt, detail: detail, now: now, seen: &seen)
            if r.unreadable { unreadable = true }
            if !r.agents.isEmpty { out.bySession[s.id] = r.agents }
        }
        metas = metas.filter { seen.contains($0.key) }
        tails = tails.filter { seen.contains($0.key) }
        out.warning = unreadable ? Self.formatWarning : nil
        return out
    }

    /// One session's subagents folder. `unreadable` when it holds recent subagent files Dashbar can't make sense of.
    func read(dir: URL, sessionStarted: Date?, detail: Bool, now: Date = Date(),
              seen: inout Set<String>) -> (agents: [Subagent], unreadable: Bool) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else {
            return ([], false)
        }
        var transcripts: [String: (url: URL, mtime: Date, created: Date, size: UInt64)] = [:]
        var metaFiles: [String: URL] = [:]
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("agent-") else { continue }
            if name.hasSuffix(".meta.json") {
                metaFiles[String(name.dropFirst(6).dropLast(10))] = url
            } else if name.hasSuffix(".jsonl") {
                let rv = try? url.resourceValues(forKeys: Set(keys))
                let mtime = rv?.contentModificationDate ?? .distantPast
                transcripts[String(name.dropFirst(6).dropLast(6))] =
                    (url, mtime, rv?.creationDate ?? mtime, UInt64(rv?.fileSize ?? 0))
            }
        }

        var agents: [Subagent] = []
        var recentFiles = 0, readable = 0
        for id in Set(transcripts.keys).union(metaFiles.keys) {
            let t = transcripts[id]
            // Only what was written lately judges the format: old files keep whatever format they were written in.
            // A brand-new transcript may not have its metadata yet.
            let recent = t.map { now.timeIntervalSince($0.mtime) < Self.quiet && now.timeIntervalSince($0.created) > 10 } ?? false
            if recent { recentFiles += 1 }
            guard let metaURL = metaFiles[id] else { continue }
            let key = metaURL.path
            guard let meta = loadMeta(metaURL, key: key) else { continue }
            seen.insert(key)
            if recent { readable += 1 }

            let lastWrite = max(t?.mtime ?? meta.mtime, meta.mtime)
            // From an earlier run of a resumed session: it can't be running in this one.
            if let sessionStarted, lastWrite < sessionStarted.addingTimeInterval(-5) { continue }
            var finished = meta.finished
            var finishedAt: Date? = finished ? meta.mtime : nil
            // Resumed after it finished: its transcript grew again after the metadata said so.
            if finished, let t, t.mtime > meta.mtime.addingTimeInterval(10) { finished = false; finishedAt = nil }
            if !finished, now.timeIntervalSince(lastWrite) > Self.quiet { finished = true; finishedAt = lastWrite }
            if let finishedAt, now.timeIntervalSince(finishedAt) > Self.linger { continue }

            var agent = Subagent(id: id, description: meta.description, type: meta.type, model: meta.model,
                                 background: meta.background, started: min(meta.created, t?.created ?? meta.created),
                                 lastActivity: lastWrite, finished: finished, finishedAt: finishedAt)
            if let t { seen.insert(t.url.path) }   // keep its read position while the panel is closed
            if detail, let t {
                let tail = readTail(t.url, size: t.size)
                agent.tokens = tail.tokens
                if let m = tail.model { agent.model = Fmt.model(m) }
                if let last = tail.last { agent.lastActivity = max(agent.lastActivity, last) }
            }
            agents.append(agent)
        }
        // Running first, then the newest.
        agents.sort { ($0.isRunning ? 0 : 1, $1.started, $0.id) < ($1.isRunning ? 0 : 1, $0.started, $1.id) }
        return (agents, recentFiles > 0 && readable == 0)
    }

    private func loadMeta(_ url: URL, key: String) -> Meta? {
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let mtime = rv?.contentModificationDate ?? .distantPast
        if let m = metas[key], m.mtime == mtime { return m }
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = o["agentType"] as? String else {
            metas[key] = nil
            return nil
        }
        let description = (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? type
        let m = Meta(mtime: mtime, created: rv?.creationDate ?? mtime, description: description, type: type,
                     model: (o["model"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() },
                     background: o["requestShape"] as? String == "background",
                     finished: o["finished"] as? Bool == true)
        metas[key] = m
        return m
    }

    /// Reads the transcript's new bytes for token usage, the model and the time of the last record.
    private func readTail(_ url: URL, size: UInt64) -> Tail {
        var tail = tails[url.path] ?? Tail()
        if size < tail.offset { tail = Tail() }   // rewritten shorter
        guard size > tail.offset, let h = try? FileHandle(forReadingFrom: url) else { return tail }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: tail.offset)) != nil, let data = try? h.readToEnd(),
              let lastNL = data.lastIndex(of: 0x0A) else { return tail }
        for line in data[..<lastNL].split(separator: 0x0A) where line.range(of: needle) != nil {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["type"] as? String == "assistant", let m = o["message"] as? [String: Any],
                  let u = m["usage"] as? [String: Any] else { continue }
            let total = (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
                + (u["cache_read_input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
            let id = m["id"] as? String ?? UUID().uuidString
            tail.perMessage[id] = Swift.max(tail.perMessage[id] ?? 0, total)
            if let model = m["model"] as? String, model != "<synthetic>" { tail.model = model }
            if let ts = o["timestamp"] as? String, let d = Date.fromISO(ts) { tail.last = d }
        }
        tail.offset += UInt64(data.distance(from: data.startIndex, to: lastNL) + 1)
        tails[url.path] = tail
        return tail
    }
}
