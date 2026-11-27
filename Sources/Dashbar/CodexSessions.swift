import Foundation
import Darwin

// MARK: - Live Codex sessions

/// Codex's live sessions, from the logs Dashbar already reads for usage. Checked against openai/codex's source
/// (27 Nov 2026):
///
/// - A session is live while a `codex` process holds its `sessions/**/rollout-*.jsonl` open (`codex-rs/rollout`'s
///   writer keeps the file for as long as the thread is loaded). One app server (VS Code, T3 Code, the Codex app) holds
///   one per thread. Dashbar only lists the process's open files: it never opens or locks Codex's `thread-writer-locks`,
///   which could make Codex think another process is writing.
/// - The terminal UI doesn't hold the file itself: it talks to a background app server (`--managed-daemon`) that
///   outlives it and, seen on 0.163.0, still held a quit session's log four minutes later. So a daemon's open file
///   alone means nothing: its session shows while a turn runs, or while a `codex` with no log of its own (the terminal)
///   is running in its folder, whose process it takes. Each terminal vouches for one session, the latest.
/// - Every history mode saves `task_started`, `task_complete` and `turn_aborted` (`rollout/src/policy.rs`; v2 names
///   `turn_started` and `turn_complete` are accepted too). Approval requests and questions are never saved, so a session
///   waiting for you reads as working.
///
/// Read, and kept: from the first line (`session_meta`) only `id`, `cwd`, `originator`, `source` and `parent_thread_id`;
/// from the rest, only the `type` and `timestamp` of turn events. Never message text, prompts or tool input or output.
enum CodexSessions {
    static let formatWarning = "Couldn't read Codex's live sessions. Its session log format may have changed, so check for a Dashbar update."

    struct Reading: Equatable {
        var sessions: [LiveSession] = []
        var warning: String?
    }

    struct Meta: Equatable {
        var id: String
        var cwd: String
        var originator: String
        /// Started by another thread (a spawned or review subagent), or by Codex itself: not a session of yours.
        var isSubagent: Bool
    }

    struct Turn: Equatable {
        var working: Bool
        var at: Date?
    }

    /// A Codex binary: `codex` (Homebrew, npm's native binary, the apps' bundled copy) or a release download's
    /// `codex-aarch64-apple-darwin`.
    static func isCodex(executable: String) -> Bool {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return name == "codex" || name.hasPrefix("codex-aarch64") || name.hasPrefix("codex-x86_64")
    }

    static func isRollout(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// The session's metadata from the log's first line. Nil when that line isn't a `session_meta` Dashbar understands.
    static func meta(firstLine: Data) -> Meta? {
        guard let o = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              o["type"] as? String == "session_meta", let p = o["payload"] as? [String: Any],
              let id = (p["id"] ?? p["session_id"]) as? String, let cwd = p["cwd"] as? String else { return nil }
        let source = p["source"] as? [String: Any]
        return Meta(id: id, cwd: cwd, originator: p["originator"] as? String ?? "",
                    isSubagent: p["parent_thread_id"] is String || source?["subagent"] != nil || source?["internal"] != nil)
    }

    private static let starts: Set<String> = ["task_started", "turn_started"]
    private static let ends: Set<String> = ["task_complete", "turn_complete", "turn_aborted"]
    private static let needles = ["\"task_", "\"turn_"].map { Data($0.utf8) }

    /// The turn boundary a log line marks, if it is one. Lines are parsed only when they mention one by name, and a
    /// mention inside a message doesn't count: the line itself has to be the event.
    static func turn(line: Data) -> Turn? {
        guard needles.contains(where: { line.range(of: $0) != nil }),
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              o["type"] as? String == "event_msg", let type = (o["payload"] as? [String: Any])?["type"] as? String,
              starts.contains(type) || ends.contains(type) else { return nil }
        return Turn(working: starts.contains(type), at: (o["timestamp"] as? String).flatMap(Date.fromISO))
    }

    /// Where a session was started from, as `LiveSession.entrypoint`.
    static func entrypoint(originator: String) -> String {
        let o = originator.lowercased()
        if o.contains("vscode") { return "vscode" }
        if o.contains("codex desktop") { return "Codex app" }
        return "cli"
    }
}

// MARK: - Following one log

/// One open rollout: its metadata, read once, and its latest turn boundary, followed as the file grows.
struct CodexRollout {
    private(set) var meta: CodexSessions.Meta?
    private(set) var turn: CodexSessions.Turn?
    /// The first line is complete and isn't metadata Dashbar understands.
    private(set) var unreadable = false
    /// The whole log has been read, it reports tokens (so turns have run), and none of its turns could be found.
    private(set) var missingTurns = false
    /// Where the next read starts: just after the last complete line seen.
    private var offset: UInt64?
    private var sawTokens = false

    /// A first line can be long (it carries the base instructions).
    static let metaLimit = 4 * 1024 * 1024
    /// How far back a first read looks for the latest turn boundary, in growing steps.
    static let lookBack: [UInt64] = [256 * 1024, 2 * 1024 * 1024, 16 * 1024 * 1024]

    mutating func update(_ url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        if meta == nil, !unreadable { readMeta(h) }
        guard meta?.isSubagent == false, let size = try? h.seekToEnd() else { return }
        if let offset, offset <= size {
            read(h, from: offset, to: size, skipFirst: false)
        } else {
            // First sight (or the file was replaced): look back from the end until a turn boundary turns up.
            turn = nil
            for window in Self.lookBack {
                let start = size > window ? size - window : 0
                read(h, from: start, to: size, skipFirst: start > 0)
                if turn != nil || start == 0 {
                    missingTurns = turn == nil && start == 0 && sawTokens
                    break
                }
            }
        }
        if turn != nil { missingTurns = false }
    }

    private mutating func readMeta(_ h: FileHandle) {
        var data = Data()
        guard (try? h.seek(toOffset: 0)) != nil else { return }
        while data.count < Self.metaLimit {
            guard let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty else { return }   // still being written
            data.append(chunk)
            if let end = data.firstIndex(of: 0x0A) {
                meta = CodexSessions.meta(firstLine: data[data.startIndex..<end])
                unreadable = meta == nil
                return
            }
        }
        unreadable = true
    }

    private mutating func read(_ h: FileHandle, from start: UInt64, to size: UInt64, skipFirst: Bool) {
        offset = start
        guard size > start, (try? h.seek(toOffset: start)) != nil,
              let data = try? h.read(upToCount: Int(size - start)), let last = data.lastIndex(of: 0x0A) else { return }
        offset = start + UInt64(last - data.startIndex) + 1
        var lines = data[data.startIndex..<last].split(separator: 0x0A)
        if skipFirst, !lines.isEmpty { lines.removeFirst() }   // cut mid-line
        let tokens = Data("\"token_count\"".utf8)
        for line in lines {
            if let t = CodexSessions.turn(line: line) { turn = t }
            else if turn == nil, !sawTokens, line.range(of: tokens) != nil { sawTokens = true }
        }
    }
}

// MARK: - Collecting

/// Live queue only. Keeps each open log's state, so a refresh reads only what was added.
final class CodexCollector {
    struct Process: Equatable {
        var pid: Int32
        var openFiles: [String]
        /// Only filled in for the daemon and for a client with no log open, which are paired by folder.
        var cwd: String? = nil
        var isDaemon = false
    }

    private var rollouts: [String: CodexRollout] = [:]

    private struct Found {
        var meta: CodexSessions.Meta
        var turn: CodexSessions.Turn?
        var modified: Date
        var account: ResolvedAccount
        var process: Process
    }

    static func processes() -> [Process] {
        Proc.allPIDs().compactMap { pid in
            guard let path = Proc.path(pid), CodexSessions.isCodex(executable: path) else { return nil }
            let files = Proc.openFiles(pid).filter(CodexSessions.isRollout)
            let isDaemon = Proc.commandLine(pid)?.contains(" --managed-daemon") ?? false
            return Process(pid: pid, openFiles: files, cwd: !isDaemon && files.isEmpty ? Proc.cwd(pid) : nil, isDaemon: isDaemon)
        }
    }

    private static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    func read(accounts: [ResolvedAccount], processes: [Process] = CodexCollector.processes(), now: Date = Date()) -> CodexSessions.Reading {
        // Open files are reported by their real paths, so compare against each account's real sessions folder.
        let dirs: [(prefix: String, account: ResolvedAccount)] = accounts.map { account in
            (Self.realPath(account.sessionsDir.path) + "/", account)
        }
        var out = CodexSessions.Reading()
        var seen = Set<String>(), ids = Set<String>()
        var found: [Found] = []
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            for path in process.openFiles {
                guard let account = dirs.first(where: { path.hasPrefix($0.prefix) })?.account, seen.insert(path).inserted else { continue }
                var rollout = rollouts[path] ?? CodexRollout()
                rollout.update(URL(fileURLWithPath: path))
                rollouts[path] = rollout
                if rollout.unreadable || rollout.missingTurns { out.warning = CodexSessions.formatWarning }
                guard let meta = rollout.meta, !meta.isSubagent, ids.insert(meta.id).inserted else { continue }
                let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? now
                found.append(Found(meta: meta, turn: rollout.turn, modified: modified, account: account, process: process))
            }
        }
        // Terminals attached to a daemon: running `codex` with no log of their own. Each is paired with one session,
        // working ones first, then the most recently written.
        var terminals = processes.filter { !$0.isDaemon && $0.openFiles.isEmpty }.sorted { $0.pid < $1.pid }
        found.sort { a, b in
            let aw = a.turn?.working ?? false, bw = b.turn?.working ?? false
            return aw != bw ? aw : a.modified > b.modified
        }
        for f in found {
            let working = f.turn?.working ?? false
            var pid = f.process.pid
            if f.process.isDaemon {
                let cwd = Self.realPath(f.meta.cwd)
                let terminal = terminals.firstIndex { $0.cwd.map(Self.realPath) == cwd }.map { terminals.remove(at: $0).pid }
                guard working || terminal != nil else { continue }
                // 0: no process of its own, so nothing is walked, quit or measured through the shared daemon.
                pid = terminal ?? 0
            }
            let root = f.meta.cwd.isEmpty ? homeDir.path : Fmt.root(fromCwd: f.meta.cwd)
            var s = LiveSession(id: "codex-" + f.meta.id, pid: pid, name: Fmt.project(fromCwd: root), cwd: f.meta.cwd,
                                status: working ? "busy" : "idle", since: f.turn?.at ?? f.modified,
                                entrypoint: CodexSessions.entrypoint(originator: f.meta.originator), root: root)
            s.agent = .codex
            s.account = accounts.count > 1 ? f.account.label : nil
            out.sessions.append(s)
        }
        rollouts = rollouts.filter { seen.contains($0.key) }
        out.sessions.sort { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        return out
    }
}
