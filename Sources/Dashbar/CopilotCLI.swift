import Foundation
import SwiftUI

// MARK: - GitHub Copilot CLI (github.com/github/copilot-cli)

/// What GitHub Copilot CLI keeps on this Mac, and the little of it Dashbar reads. Sources, checked 16 Nov 2026:
///
/// - Its folder is `$COPILOT_HOME`, else `~/.copilot` (docs.github.com/en/copilot/reference/copilot-cli-reference/
///   cli-config-dir-reference; changelog 1.0.x: "COPILOT_HOME and --config-dir"; an old `$XDG_CONFIG_HOME/.copilot` is
///   moved into `~/.copilot` by the CLI itself, so XDG isn't read here).
/// - Each session is a folder `session-state/<uuid>/` (changelog 0.0.3xx: "New sessions are stored in
///   ~/.copilot/session-state") holding `events.jsonl`, an append-only event log, and `workspace.yaml`, session metadata
///   with the session's `cwd` and the host in `client_name` (`github/cli` for the terminal; `vscode`, `vscode-agent-host`
///   and `github/autopilot` for other hosts sharing the store). While a process has the session open the folder also holds
///   `inuse.<pid>.lock` (specstoryai/getspecstory `COPILOTCLI-FORMAT.md`, observed on 1.0.105; github/copilot-cli#2446,
///   #2655 for `workspace.yaml`). A folder can lack `events.jsonl` (an aborted start leaves an empty scaffold, #2836; old
///   transcripts are pruned) — then usage is unknown, never zero.
/// - The event log's format is not documented (github/copilot-cli#3551). The closest thing to a schema is the Copilot SDK's
///   generated types (github/copilot-sdk `nodejs/src/generated/session-events.ts`): each line is
///   `{type, data, id, timestamp, parentId}`, and events marked `ephemeral` are never written to disk. Per-call usage
///   (`assistant.usage`) is ephemeral, so tokens reach the file only in `session.shutdown` (#1394, fixed in 1.0.x: "Session
///   usage metrics … are now persisted to events.jsonl after each session ends"), whose `data` carries `modelMetrics`
///   (per model: `requests.{count,cost}`, `usage.{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens,
///   reasoningTokens}`), `totalPremiumRequests` and `currentModel`. Its totals are "session-wide accumulated" and survive a
///   resume, so a resumed session's next shutdown repeats what was already counted: Dashbar adds only the growth.
///
/// Dashbar reads, and keeps, only: folder names, file dates and sizes, `cwd` and `client_name` from `workspace.yaml` (never
/// `summary` or `name`, which hold a title), each event's `type` near the end of the log (for working, waiting or idle), and
/// from `session.shutdown` lines only the metric fields above. Never message text, prompts, tool arguments or results,
/// file paths from `codeChanges`, or any sign-in.
enum CopilotCLI {
    /// As GitHub's docs name it, for headings. `shortName` is for compact session lines ("Copilot is working").
    static let displayName = "GitHub Copilot CLI"
    static let shortName = "Copilot"
    static let formatWarning = "Couldn't read GitHub Copilot CLI's usage. Its session log format may have changed, so check for a Dashbar update."

    /// `$COPILOT_HOME` when it's an absolute path, else `~/.copilot`.
    static func homeURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["COPILOT_HOME"], h.hasPrefix("/") { return URL(fileURLWithPath: h) }
        return homeDir.appendingPathComponent(".copilot")
    }

    static func sessionStateURL(home: URL = homeURL()) -> URL { home.appendingPathComponent("session-state") }

    /// Whether Copilot CLI has run on this Mac: its folder has sessions or logs (folder checks only).
    static func isPresent(home: URL) -> Bool {
        let fm = FileManager.default
        return ["session-state", "logs", "hooks/\(CopilotBridge.configName)"].contains {
            fm.fileExists(atPath: home.appendingPathComponent($0).path)
        }
    }

    // MARK: workspace.yaml

    /// The two fields Dashbar takes from `workspace.yaml`.
    struct Workspace: Equatable {
        var cwd: String?
        var client: String?
    }

    /// Reads only the top-level `cwd:` and `client_name:` lines (plain, single- or double-quoted scalars). Every other line,
    /// including `summary:` and `name:`, is skipped without being kept.
    static func parseWorkspace(_ text: String) -> Workspace {
        var out = Workspace()
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let first = raw.first, first != " ", first != "\t", first != "#" else { continue }   // top level only
            if raw.hasPrefix("cwd:") { out.cwd = scalar(raw.dropFirst(4)) }
            else if raw.hasPrefix("client_name:") { out.client = scalar(raw.dropFirst(12)) }
        }
        if let c = out.cwd, !c.hasPrefix("/") { out.cwd = nil }
        return out
    }

    private static func scalar(_ s: Substring) -> String? {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q {
            v = String(v.dropFirst().dropLast())
            if q == "\"" { v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            else { v = v.replacingOccurrences(of: "''", with: "'") }
        } else if let hash = v.range(of: " #") {
            v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return v.isEmpty || v.count > 4096 ? nil : v
    }

    static func readWorkspace(_ folder: URL) -> Workspace? {
        let url = folder.appendingPathComponent("workspace.yaml")
        guard let data = try? Data(contentsOf: url, options: .uncached), data.count < 256 * 1024 else { return nil }
        return parseWorkspace(String(decoding: data, as: UTF8.self))
    }

    /// The terminal CLI's own sessions. The same store also holds VS Code's and the Copilot app's, which are other
    /// products: their folders are skipped. VS Code's CLI integration (`vscode`) runs this CLI, so it counts. Sessions from
    /// before `client_name` existed count too.
    static func isCLIClient(_ client: String?) -> Bool {
        guard let client, !client.isEmpty else { return true }
        return client == "github/cli" || client == "vscode"
    }

    // MARK: State from the event log

    enum Activity: Equatable {
        case working
        /// `permission.requested` with no answer yet (persisted, unlike the ephemeral prompts for typed input).
        case waitingForPermission
        case idle
        /// Nothing in the tail says: fall back on how recently the log was written.
        case unknown
    }

    /// Events that mean the agent is mid-turn. All persisted (not `ephemeral`) in the SDK's schema.
    static let workingTypes: Set<String> = [
        "user.message", "assistant.turn_start", "assistant.message", "assistant.reasoning", "tool.execution_start",
        "tool.execution_complete", "tool.user_requested", "permission.completed", "subagent.started",
        "session.compaction_start", "external_tool.requested", "external_tool.completed",
    ]
    /// Events after which nothing more happens until you type.
    static let idleTypes: Set<String> = [
        "assistant.turn_end", "session.task_complete", "abort", "session.shutdown", "session.start", "session.resume",
        "session.error",
    ]
    /// A turn ending is followed at once by the next one while tools run; only a pause this long means the agent stopped.
    static let turnGap: TimeInterval = 4
    /// Seconds since the last write after which an unclassified log counts as idle.
    static let activeWindow: TimeInterval = 20
    /// A turn that started with no write for this long is taken to have stopped (a crash mid-turn, say).
    static let staleRun: TimeInterval = 30 * 60
    /// Idle sessions stay listed this long after their last write, while Copilot runs.
    static let idleShown: TimeInterval = 30 * 60

    /// The state from the newest meaningful event (types newest first; others, such as `hook.start`, are passed over).
    static func activity(types: [String], modified: Date, now: Date) -> Activity {
        let age = now.timeIntervalSince(modified)
        for t in types {
            if t == "permission.requested" { return .waitingForPermission }
            if t == "assistant.turn_end" && age < turnGap { return .working }
            if idleTypes.contains(t) { return .idle }
            if workingTypes.contains(t) { return age < staleRun ? .working : .idle }
        }
        return .unknown
    }

    /// The `type` of each complete line in the last `maxBytes` of the log, newest first. Each line is parsed only to take
    /// its `type`; nothing else is kept.
    static func recentTypes(_ url: URL, maxBytes: UInt64 = 64 * 1024, limit: Int = 24) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        guard (try? h.seek(toOffset: start)) != nil, let data = try? h.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }               // cut mid-line
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }         // still being written
        var out: [String] = []
        for line in lines.reversed() {
            guard out.count < limit else { break }
            if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let t = o["type"] as? String {
                out.append(t)
            }
        }
        return out
    }

    // MARK: Session folders

    /// One session folder as the live reading sees it.
    struct SessionFolder: Equatable {
        var id: String
        var cwd: String?
        var client: String?
        /// `events.jsonl`'s modification time; nil when the session has none.
        var eventsModified: Date?
        /// From `inuse.<pid>.lock` names.
        var lockPIDs: [Int32] = []
        var activity: Activity = .unknown
    }

    /// `inuse.<pid>.lock` → pid.
    static func lockPIDs(_ names: [String]) -> [Int32] {
        names.compactMap { name in
            guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
            return Int32(name.dropFirst(6).dropLast(5))
        }
    }

    // MARK: Live sessions

    /// Copilot's live sessions, while it runs: each folder a running Copilot holds open (its lock, else the newest session
    /// in that process's folder written since it started), with the hook's state where it is the newer news. A folder
    /// where Copilot runs with no session yet still shows, idle. Nothing shows when no Copilot process runs.
    static func live(folders: [SessionFolder], bridged: [CopilotBridge.SessionState],
                     processes: [(pid: Int32, cwd: String, started: Date?)], aliases: [Int32: Int32] = [:],
                     now: Date = Date(), root: (String) -> String = Fmt.root(fromCwd:)) -> [LiveSession] {
        guard !processes.isEmpty else { return [] }
        let home = homeDir.path
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let states = Dictionary(bridged.map { ($0.id, $0) }, uniquingKeysWith: { $0.writtenAt > $1.writtenAt ? $0 : $1 })
        var out: [LiveSession] = []
        var claimed = Set<Int32>(), idsShown = Set<String>()

        func add(_ f: SessionFolder, pid: Int32, processCwd: String) {
            let cwd = f.cwd ?? processCwd
            let rt = root(cwd.isEmpty ? home : cwd)
            var status = "idle", since = f.eventsModified ?? now, waitingFor: String?
            let modified = f.eventsModified ?? .distantPast
            if let b = states[f.id], b.writtenAt >= modified.addingTimeInterval(-5), b.state != "ended" {
                status = b.liveStatus
                since = b.writtenAt
            } else {
                switch f.activity {
                case .working: status = "busy"
                case .waitingForPermission: status = "waiting"; waitingFor = "permission prompt"
                case .idle: status = "idle"
                case .unknown: status = now.timeIntervalSince(modified) < activeWindow ? "busy" : "idle"
                }
            }
            out.append(session(id: f.id, cwd: cwd, root: rt, status: status, since: since, pid: pid, waitingFor: waitingFor))
            idsShown.insert(f.id)
        }

        let usable = folders.filter { isCLIClient($0.client) }.sorted { ($0.eventsModified ?? .distantPast) > ($1.eventsModified ?? .distantPast) }
        // 1. Folders a running Copilot has locked.
        for f in usable {
            guard let pid = f.lockPIDs.lazy.map({ aliases[$0] ?? $0 }).first(where: { byPID[$0] != nil }), let p = byPID[pid] else { continue }
            add(f, pid: pid, processCwd: p.cwd)
            claimed.insert(pid)
        }
        // 2. No lock (an older or newer layout): the newest session in the process's folder written since it started.
        for p in processes where !claimed.contains(p.pid) {
            let rt = root(p.cwd.isEmpty ? home : p.cwd)
            let started = p.started ?? .distantPast
            if let f = usable.first(where: { f in
                !idsShown.contains(f.id) && f.lockPIDs.isEmpty && (f.eventsModified ?? .distantPast) >= started.addingTimeInterval(-60)
                    && f.cwd.map(root) == rt
            }) {
                add(f, pid: p.pid, processCwd: p.cwd)
                claimed.insert(p.pid)
            }
        }
        // 3. Sessions only the hook knows about yet, in a folder where Copilot runs.
        let runningRoots = Dictionary(processes.map { (root($0.cwd.isEmpty ? home : $0.cwd), $0.pid) }, uniquingKeysWith: { a, _ in a })
        for b in states.values.sorted(by: { $0.writtenAt > $1.writtenAt })
        where !idsShown.contains(b.id) && b.state != "ended" && !b.directory.isEmpty && now.timeIntervalSince(b.writtenAt) < idleShown {
            let rt = root(b.directory)
            guard let pid = runningRoots[rt], !claimed.contains(pid) else { continue }
            out.append(session(id: b.id, cwd: b.directory, root: rt, status: b.liveStatus, since: b.writtenAt, pid: pid, waitingFor: nil))
            idsShown.insert(b.id)
            claimed.insert(pid)
        }
        // 4. Copilot running with nothing written yet.
        for p in processes where !claimed.contains(p.pid) {
            let rt = root(p.cwd.isEmpty ? home : p.cwd)
            guard rt != home, rt != "/" else { continue }
            out.append(session(id: "pid-\(p.pid)", cwd: rt, root: rt, status: "idle", since: p.started ?? now, pid: p.pid, waitingFor: nil))
        }
        return out
    }

    private static func session(id: String, cwd: String, root: String, status: String, since: Date, pid: Int32,
                                waitingFor: String?) -> LiveSession {
        var s = LiveSession(id: "copilot-" + id, pid: pid, name: Fmt.project(fromCwd: root), cwd: cwd, status: status,
                            since: since, entrypoint: "cli", root: root, waitingFor: waitingFor)
        s.agent = .copilot
        return s
    }

    // MARK: Processes

    /// A Copilot CLI process: its own binary (Homebrew's cask, the install script, and the native binary the npm package
    /// starts), or Node running the npm package `@github/copilot`. Not the editors' `@github/copilot-language-server`.
    static func isCopilot(name: String, commandLine: String?) -> Bool {
        if name == "copilot" { return true }
        guard ["node", "bun"].contains(name), let commandLine else { return false }
        return commandLine.split(separator: " ").dropFirst().prefix(3).contains { arg in
            arg == "copilot" || arg.hasSuffix("/bin/copilot") || arg.contains("/@github/copilot/")
        }
    }
}

// MARK: - Collecting

/// Finds Copilot among running processes: the outermost of each (the npm package's Node wrapper starts the native
/// binary as its child). Command lines are read only for Node and Bun processes, once per process.
final class CopilotProcesses {
    private var known: [Int32: (started: Date?, match: Bool)] = [:]

    /// The outermost processes, and every matched child mapped to its outermost (a lock may name either).
    func scan() -> (processes: [(pid: Int32, cwd: String, started: Date?)], aliases: [Int32: Int32]) {
        var seen = Set<Int32>()
        var found: [Int32: (cwd: String, started: Date?, parent: Int32)] = [:]
        for pid in Proc.allPIDs() {
            let name = Proc.name(pid)
            guard ["copilot", "node", "bun"].contains(name) else { continue }
            seen.insert(pid)
            let info = Proc.bsdInfo(pid)
            let match: Bool
            if let hit = known[pid], hit.started == info?.started { match = hit.match }
            else {
                match = CopilotCLI.isCopilot(name: name, commandLine: name == "copilot" ? nil : Proc.commandLine(pid))
                known[pid] = (info?.started, match)
            }
            if match { found[pid] = (Proc.cwd(pid) ?? "", info?.started, info?.parent ?? 0) }
        }
        known = known.filter { seen.contains($0.key) }
        var aliases: [Int32: Int32] = [:]
        for pid in found.keys {
            var top = pid, hops = 0
            while let parent = found[top]?.parent, found[parent] != nil, hops < 8 { top = parent; hops += 1 }
            if top != pid { aliases[pid] = top }
        }
        let outer = found.filter { found[$0.value.parent] == nil }.map { ($0.key, $0.value.cwd, $0.value.started) }.sorted { $0.0 < $1.0 }
        return (outer.map { (pid: $0.0, cwd: $0.1, started: $0.2) }, aliases)
    }
}

/// Copilot's live sessions for the store's live refresh. Cheap for someone who doesn't use it: one pass over process
/// names, and nothing else unless Copilot is running. Then only session folders changed since the oldest Copilot
/// started (or already open) are listed, and `workspace.yaml` is read again only when it changes.
final class CopilotCollector {
    private let processes = CopilotProcesses()
    let sessionState: URL
    let bridgeDir: URL
    private var workspaces: [String: (modified: Date?, value: CopilotCLI.Workspace)] = [:]
    private var open = Set<String>()

    init(sessionState: URL = CopilotCLI.sessionStateURL(), bridgeDir: URL = CopilotBridge.statesDir) {
        self.sessionState = sessionState
        self.bridgeDir = bridgeDir
    }

    func read(now: Date = Date()) -> [LiveSession] {
        let found = processes.scan()
        guard !found.processes.isEmpty else { open = []; return [] }
        let oldest = found.processes.compactMap(\.started).min() ?? now.addingTimeInterval(-CopilotCLI.idleShown)
        let folders = self.folders(changedSince: oldest.addingTimeInterval(-120), now: now)
        open = Set(folders.filter { !$0.lockPIDs.isEmpty }.map(\.id))
        let states = FileManager.default.fileExists(atPath: bridgeDir.path)
            ? CopilotBridge.readStates(dir: bridgeDir, maxAge: 12 * 3600, now: now) : []
        return CopilotCLI.live(folders: folders, bridged: states, processes: found.processes, aliases: found.aliases, now: now)
    }

    private func folders(changedSince cutoff: Date, now: Date) -> [CopilotCLI.SessionFolder] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let dirs = try? fm.contentsOfDirectory(at: sessionState, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var out: [CopilotCLI.SessionFolder] = []
        for dir in dirs {
            guard let v = try? dir.resourceValues(forKeys: Set(keys)), v.isDirectory == true else { continue }
            let id = dir.lastPathComponent
            // A lock is created when a session opens, which changes the folder's date; an open session stays a candidate.
            guard (v.contentModificationDate ?? .distantPast) >= cutoff || open.contains(id) else { continue }
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let events = dir.appendingPathComponent("events.jsonl")
            let eventsModified = names.contains("events.jsonl")
                ? (try? events.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
            var f = CopilotCLI.SessionFolder(id: id, eventsModified: eventsModified, lockPIDs: CopilotCLI.lockPIDs(names))
            guard !f.lockPIDs.isEmpty || (eventsModified ?? .distantPast) >= cutoff else { continue }
            let ws = workspace(dir, id: id, present: names.contains("workspace.yaml"))
            f.cwd = ws.cwd
            f.client = ws.client
            if let m = eventsModified, CopilotCLI.isCLIClient(ws.client) {
                f.activity = CopilotCLI.activity(types: CopilotCLI.recentTypes(events), modified: m, now: now)
            }
            out.append(f)
        }
        return out
    }

    private func workspace(_ dir: URL, id: String, present: Bool) -> CopilotCLI.Workspace {
        guard present else { return CopilotCLI.Workspace() }
        let url = dir.appendingPathComponent("workspace.yaml")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = workspaces[id], cached.modified == modified { return cached.value }
        let value = CopilotCLI.readWorkspace(dir) ?? CopilotCLI.Workspace()
        workspaces[id] = (modified, value)
        if workspaces.count > 200 { workspaces = workspaces.filter { open.contains($0.key) || $0.key == id } }
        return value
    }
}

// MARK: - Usage

/// Copilot's usage for the Usage tab and History: tokens and model mix from the ledger, and premium requests by day.
struct CopilotUsage: Equatable {
    var summary = UsageSummary.empty
    /// Premium requests by day (`UsageBook.dayKey`).
    var premiumByDay: [String: Double] = [:]
    /// Recent CLI sessions with no event log, whose usage can't be known.
    var unknownSessions = 0

    static let empty = CopilotUsage()

    /// Whether the Usage tab has a card for Copilot: a log was read, or a session's usage is unknown.
    var shows: Bool { summary.found || unknownSessions > 0 }

    func premium(_ period: UsagePeriod, now: Date = Date()) -> Double {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<period.days).reduce(0) { sum, offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return sum }
            return sum + (premiumByDay[UsageBook.dayKey.string(from: d)] ?? 0)
        }
    }
}

/// One model's figures from a `session.shutdown` line, cumulative for the session.
struct CopilotModelMetric: Equatable, Codable {
    var tokens = TokenTotals()
    var premium: Double = 0
}

/// Reads `session.shutdown` lines incrementally from every CLI session's `events.jsonl`, adding what each model's
/// cumulative totals grew by since the session's last shutdown. Other lines are skipped by a cheap byte match before
/// any parsing (as `JSONLTail` does); a line that contains the needle but isn't a shutdown event (a prompt quoting it,
/// say) is passed over.
final class CopilotUsageScanner {
    struct State: Codable {
        var root: String
        var offsets: [String: UInt64]
        /// Per session, per model: the cumulative figures already booked.
        var booked: [String: [String: CopilotModelMetric]]
        var bookedPremium: [String: Double]
        var book: UsageBook
        var premiumByDay: [String: Double]
    }

    let root: URL
    private var tail: JSONLTail
    private var booked: [String: [String: CopilotModelMetric]] = [:]
    private var bookedPremium: [String: Double] = [:]
    private var book = UsageBook()
    private var premiumByDay: [String: Double] = [:]
    private var projects: [String: String] = [:]
    private var workspaces: [String: CopilotCLI.Workspace] = [:]
    /// Recent shutdown lines that couldn't be read, in a row.
    private var unreadableRun = 0
    private let cache: ScanCache<State>?
    private var dirty = false
    private var found = false

    init(root: URL = CopilotCLI.sessionStateURL(), cache: URL? = nil) {
        self.root = root
        tail = JSONLTail(root: root, needles: ["\"session.shutdown\""])
        self.cache = cache.map { ScanCache(url: $0) }
        if let saved = self.cache?.load(), saved.root == root.path {
            tail.offsets = saved.offsets
            booked = saved.booked
            bookedPremium = saved.bookedPremium
            book = saved.book
            premiumByDay = saved.premiumByDay
        }
    }

    func scan(now: Date = Date()) -> CopilotUsage {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { found = false; return .empty }
        let cutoff = now.addingTimeInterval(-31 * 86400), recentCutoff = now.addingTimeInterval(-2 * 86400)
        var unknown = 0, live: [String: UInt64] = [:], anyLog = false
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let session = dir.lastPathComponent
            let events = dir.appendingPathComponent("events.jsonl")
            guard let v = try? events.resourceValues(forKeys: Set(keys)), let mtime = v.contentModificationDate,
                  let size = v.fileSize.map(UInt64.init) else {
                // No event log: usage unknown, for a real session (one with its metadata) used lately. An empty scaffold
                // left by an aborted start (github/copilot-cli#2836) isn't a session.
                let yaml = dir.appendingPathComponent("workspace.yaml")
                if let m = (try? yaml.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m >= cutoff,
                   CopilotCLI.isCLIClient(workspace(dir).client) {
                    unknown += 1
                }
                continue
            }
            let ws = workspace(dir)
            guard CopilotCLI.isCLIClient(ws.client) else { continue }
            anyLog = true
            guard mtime >= cutoff else { continue }
            var offset = tail.offsets[events.path] ?? 0
            if size < offset { offset = 0 }   // rewritten: totals are cumulative, so reading again books only growth
            if size > offset {
                let recent = mtime >= recentCutoff
                offset = tail.read(events, from: offset) { json in
                    self.ingest(json, session: session, cwd: ws.cwd, recent: recent)
                }
                dirty = true
            }
            live[events.path] = offset
        }
        tail.offsets = live
        found = anyLog
        book.prune(now: now)
        let oldest = UsageBook.dayKey.string(from: cutoff)
        premiumByDay = premiumByDay.filter { $0.key >= oldest }
        var out = CopilotUsage(unknownSessions: unknown)
        guard found else { return out }
        out.summary = book.summary(found: true)
        out.summary.warning = unreadableRun >= 2 ? CopilotCLI.formatWarning : nil
        out.premiumByDay = premiumByDay
        return out
    }

    func save() {
        guard dirty, let cache else { return }
        cache.save(State(root: root.path, offsets: tail.offsets, booked: booked, bookedPremium: bookedPremium, book: book,
                         premiumByDay: premiumByDay))
        dirty = false
    }

    private func workspace(_ dir: URL) -> CopilotCLI.Workspace {
        let id = dir.lastPathComponent
        if let w = workspaces[id] { return w }
        let w = CopilotCLI.readWorkspace(dir) ?? CopilotCLI.Workspace()
        workspaces[id] = w
        return w
    }

    /// One line containing the needle. Only a `session.shutdown` envelope counts, for or against the format.
    private func ingest(_ json: [String: Any]?, session: String, cwd: String?, recent: Bool) {
        guard let json else { record(false, recent: recent); return }
        guard json["type"] as? String == "session.shutdown" else { return }
        guard let data = json["data"] as? [String: Any], let metrics = CopilotUsageScanner.metrics(data) else {
            record(false, recent: recent)
            return
        }
        record(true, recent: recent)
        let date = (json["timestamp"] as? String).flatMap(Date.fromISO) ?? Date()
        let project = cwd.map(project(for:)) ?? CopilotCLI.shortName
        let delta = CopilotUsageScanner.growth(from: booked[session] ?? [:], to: metrics.models)
        booked[session] = metrics.models
        for (model, d) in delta.sorted(by: { $0.key < $1.key }) {
            // Billed by the Copilot plan, not by token: no cost is set, and the card explains why.
            book.add(d.tokens, at: date, model: model, project: project, session: session, cost: nil)
        }
        let premium = metrics.premium
        let old = bookedPremium[session] ?? 0
        let added = premium >= old ? premium - old : premium
        bookedPremium[session] = premium
        if added > 0 { premiumByDay[UsageBook.dayKey.string(from: date), default: 0] += added }
    }

    private func record(_ readable: Bool, recent: Bool) {
        guard recent else { return }
        unreadableRun = readable ? 0 : unreadableRun + 1
    }

    private func project(for cwd: String) -> String {
        if let p = projects[cwd] { return p }
        let p = Fmt.project(fromCwd: Fmt.root(fromCwd: cwd))
        projects[cwd] = p
        return p
    }

    /// The figures from a shutdown event's `data`. Nil when `modelMetrics` is missing or isn't shaped as documented.
    ///
    /// `inputTokens` includes the prompt tokens read from cache (Copilot's exit summary prints "453.0k in, 405.7k cached"
    /// and every observed reading has cache reads below input), so only the rest counts as fresh input here.
    /// `outputTokens` is taken to include reasoning, as OpenAI's API counts it; `reasoningTokens` isn't added again.
    static func metrics(_ data: [String: Any]) -> (models: [String: CopilotModelMetric], premium: Double)? {
        guard let raw = data["modelMetrics"] as? [String: Any] else { return nil }
        var models: [String: CopilotModelMetric] = [:]
        for (name, value) in raw {
            guard let m = value as? [String: Any], let usage = m["usage"] as? [String: Any] else { return nil }
            func int(_ o: [String: Any]?, _ k: String) -> Int { max(0, (o?[k] as? NSNumber)?.intValue ?? 0) }
            let requests = m["requests"] as? [String: Any]
            let input = int(usage, "inputTokens"), read = int(usage, "cacheReadTokens")
            guard usage["inputTokens"] is NSNumber || usage["outputTokens"] is NSNumber else { return nil }
            models[name] = CopilotModelMetric(
                tokens: TokenTotals(input: max(0, input - read), output: int(usage, "outputTokens"), cacheRead: read,
                                    cacheWrite: int(usage, "cacheWriteTokens"), messages: int(requests, "count")),
                premium: max(0, (requests?["cost"] as? NSNumber)?.doubleValue ?? 0))
        }
        let total = (data["totalPremiumRequests"] as? NSNumber)?.doubleValue
        return (models, max(0, total ?? models.values.reduce(0) { $0 + $1.premium }))
    }

    /// What each model grew by since `old`. A model whose figures went down started again from zero (a run whose totals
    /// weren't carried over), so all of its new figures count.
    static func growth(from old: [String: CopilotModelMetric], to new: [String: CopilotModelMetric]) -> [String: CopilotModelMetric] {
        var out: [String: CopilotModelMetric] = [:]
        for (model, n) in new {
            let o = old[model] ?? CopilotModelMetric()
            let reset = n.tokens.total < o.tokens.total
            let t = reset ? n.tokens : n.tokens.growth(since: o.tokens)
            if t.total > 0 || t.messages > 0 { out[model] = CopilotModelMetric(tokens: t, premium: 0) }
        }
        return out
    }
}

// MARK: - Look

extension UI {
    /// Copilot's goggles, as near as SF Symbols get. Neutral grey (`UI.neutralTool`) like every tool after the first four.
    static let copilotSymbol = "eyeglasses"
    /// Copilot's series where it stacks beside OpenCode's (History): the same grey, lighter, so the two stay apart
    /// without a new hue.
    static let copilotHistory = Color(light: .init(hex: 0xA3A9B1), dark: .init(hex: 0x6E747D))
}
