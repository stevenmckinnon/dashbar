import Foundation
import SwiftUI
import SQLite3

// MARK: - opencode (github.com/anomalyco/opencode)

/// opencode keeps every session in one SQLite database, `~/.local/share/opencode/opencode.db` (`$XDG_DATA_HOME` if set).
/// Dashbar reads it read-only, through the system's SQLite, only when its files have changed, and only these columns:
///
/// - sessions: `id`, `directory`, `parent_id` and the `time_*` columns. Never `title`, `slug`, `summary_*`, `metadata`,
///   `permission`, `revert` or `share_url`.
/// - messages: `session_id`, `type`, `time_created`, `time_updated`, and from the `data` JSON only the role, the model,
///   the token counts, the cost and the times, picked out by SQLite's `json_extract`. Never the message text, its
///   content or the `part`/`session_part` tables, which hold what was said and what tools did.
///
/// Two layouts exist, confirmed from opencode's source:
/// - 1.x (`packages/core/src/session/sql.ts` at v1.19.5): `session` and `message`. An assistant message's `data` has
///   `role: "assistant"`, `providerID`, `modelID`, `cost`, `tokens.{input,output,reasoning,cache.read,cache.write}`
///   and `time.{created,completed}` (`packages/schema/src/v1/session.ts`, `Assistant`).
/// - 2.x (`packages/core/src/session/sql.ts` on dev, Nov 2026): `session_v2` and `session_message`, whose `type` column
///   says `'assistant'` and whose `data` has `model.{id,providerID}`, `cost` and the same `tokens` object
///   (`packages/schema/src/session-message.ts`, `Assistant`; `token-usage.ts`). opencode's own statistics read exactly
///   these paths (`packages/core/src/session/stats.ts`), skipping a fork's copies of its parent's messages
///   (`fork_session_id` set and the message older than the session). `time_busy` and `time_idle` on `session_v2` say
///   when a run started and ended (`packages/core/src/session/projector.ts`).
///
/// A store being upgraded holds both (`packages/core/src/database/migration/20260804233008_loose_psylocke.ts` creates the
/// 2.x tables beside the 1.x ones; `packages/core/src/database/v1-migration.bun.ts` copies each session across under
/// the same id). A session in `session_v2` is read from there only, so nothing is counted twice.
enum OpenCode {
    static let formatWarning = "Couldn't read opencode's sessions. Its database format may have changed, so check for a Dashbar update."

    /// `$XDG_DATA_HOME/opencode/opencode.db`, else `~/.local/share/opencode/opencode.db`.
    static func databaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/opencode.db")
        }
        return homeDir.appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// `$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`: where opencode looks for plugins.
    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        }
        return homeDir.appendingPathComponent(".config/opencode")
    }

    // MARK: Rows

    /// A session that changed recently: only ids, its folder and times.
    struct SessionRow: Equatable {
        var id: String
        var directory: String
        var parent: String?
        var updated: Date
        /// 2.x: when its latest run started and ended. Nil in 1.x and older 2.x stores.
        var busyAt: Date?
        var idleAt: Date?
        var archived = false
        /// When any of its messages last changed.
        var lastMessage: Date?
        /// When an assistant message that hasn't completed yet last changed (one is being written).
        var openMessage: Date?

        var activity: Date { [updated, busyAt, idleAt, lastMessage].compactMap { $0 }.max() ?? updated }
    }

    /// One assistant message's usage: no text, only who, where and how much.
    struct UsageRow: Equatable {
        var session: String
        var directory: String
        var subagent: Bool
        var created: Date
        var provider: String?
        var model: String?
        var input: Int?
        var output: Int
        var reasoning: Int
        var cacheRead: Int
        var cacheWrite: Int
        var cost: Double?
        var completed: Bool
    }

    enum QueryResult<Row: Equatable>: Equatable {
        case rows([Row])
        case schemaChanged
        case unavailable
    }

    // MARK: Layout

    /// Which tables a store has, and the optional columns Dashbar may use.
    struct Layout: Equatable {
        var v1 = false
        var v2 = false
        var v1Session: Set<String> = []
        var v2Session: Set<String> = []

        static let sessionRequired: Set<String> = ["id", "directory", "time_created", "time_updated"]
        static let v1MessageRequired: Set<String> = ["session_id", "time_created", "time_updated", "data"]
        static let v2MessageRequired: Set<String> = ["session_id", "type", "time_created", "time_updated", "data"]
    }

    enum LayoutResult: Equatable {
        case layout(Layout)
        case schemaChanged
        case unavailable
    }

    static func layout(_ db: OpaquePointer) -> LayoutResult {
        let tables = tableNames(db)
        guard !tables.isEmpty else { return .unavailable }   // brand new, or still being created
        var out = Layout()
        if tables.contains("session_v2") || tables.contains("session_message") && !tables.contains("message") {
            let s = columns(db, "session_v2"), m = columns(db, "session_message")
            guard Layout.sessionRequired.isSubset(of: s), Layout.v2MessageRequired.isSubset(of: m) else { return .schemaChanged }
            out.v2 = true
            out.v2Session = s
        }
        if tables.contains("session") || tables.contains("message") {
            let s = columns(db, "session"), m = columns(db, "message")
            if Layout.sessionRequired.isSubset(of: s), Layout.v1MessageRequired.isSubset(of: m) {
                out.v1 = true
                out.v1Session = s
            } else if !out.v2 {
                return .schemaChanged
            }
        }
        return out.v1 || out.v2 ? .layout(out) : .schemaChanged
    }

    // MARK: SQL

    /// `"t"."c"` when the table has the column, else NULL, so older stores read the same way.
    private static func optional(_ alias: String, _ column: String, in columns: Set<String>) -> String {
        columns.contains(column) ? "\(alias).\"\(column)\"" : "NULL"
    }

    /// Every statement the live reading may run for this layout (`?1` is the oldest time to read, in milliseconds).
    static func sessionSQL(_ layout: Layout) -> [String] {
        var out: [String] = []
        if layout.v2 {
            let c = layout.v2Session
            let busy = optional("s", "time_busy", in: c), idle = optional("s", "time_idle", in: c)
            out.append("""
            SELECT s."id", s."directory", \(optional("s", "parent_id", in: c)), s."time_updated", \(busy), \(idle), \
            \(optional("s", "time_archived", in: c)), m.last, m.open
            FROM "session_v2" s
            LEFT JOIN (SELECT "session_id" AS sid, MAX("time_updated") AS last,
              MAX(CASE WHEN "type" = 'assistant' AND json_extract("data", '$.time.completed') IS NULL THEN "time_updated" END) AS open
              FROM "session_message" WHERE "time_created" >= ?1 GROUP BY "session_id") m ON m.sid = s."id"
            WHERE s."time_updated" >= ?1 OR m.last IS NOT NULL\(c.contains("time_busy") ? " OR \(busy) >= ?1" : "")\
            \(c.contains("time_idle") ? " OR \(idle) >= ?1" : "")
            ORDER BY COALESCE(m.last, s."time_updated") DESC LIMIT 40
            """)
        }
        if layout.v1 {
            let c = layout.v1Session
            out.append("""
            SELECT s."id", s."directory", \(optional("s", "parent_id", in: c)), s."time_updated", NULL, NULL, \
            \(optional("s", "time_archived", in: c)), m.last, m.open
            FROM "session" s
            LEFT JOIN (SELECT "session_id" AS sid, MAX("time_updated") AS last,
              MAX(CASE WHEN json_extract("data", '$.role') = 'assistant' AND json_extract("data", '$.time.completed') IS NULL
                  THEN "time_updated" END) AS open
              FROM "message" WHERE "time_created" >= ?1 GROUP BY "session_id") m ON m.sid = s."id"
            WHERE (s."time_updated" >= ?1 OR m.last IS NOT NULL)\(layout.v2 ? " AND s.\"id\" NOT IN (SELECT \"id\" FROM \"session_v2\")" : "")
            ORDER BY COALESCE(m.last, s."time_updated") DESC LIMIT 40
            """)
        }
        return out
    }

    /// Every statement the usage reading may run for this layout (`?1` is the oldest message to read, in milliseconds).
    static func usageSQL(_ layout: Layout) -> [String] {
        var out: [String] = []
        let tokens = ["input", "output", "reasoning", "cache.read", "cache.write"]
            .map { "json_extract(m.\"data\", '$.tokens.\($0)')" }.joined(separator: ", ")
        if layout.v2 {
            let c = layout.v2Session
            let fork = c.contains("fork_session_id") ? " AND (s.\"fork_session_id\" IS NULL OR m.\"time_created\" >= s.\"time_created\")" : ""
            out.append("""
            SELECT m."session_id", s."directory", \(optional("s", "parent_id", in: c)), m."time_created",
              json_extract(m."data", '$.model.providerID'), json_extract(m."data", '$.model.id'), \(tokens),
              json_extract(m."data", '$.cost'), json_extract(m."data", '$.time.completed')
            FROM "session_message" m JOIN "session_v2" s ON s."id" = m."session_id"
            WHERE m."type" = 'assistant' AND m."time_created" >= ?1\(fork)
            """)
        }
        if layout.v1 {
            let c = layout.v1Session
            out.append("""
            SELECT m."session_id", s."directory", \(optional("s", "parent_id", in: c)), m."time_created",
              json_extract(m."data", '$.providerID'), json_extract(m."data", '$.modelID'), \(tokens),
              json_extract(m."data", '$.cost'), json_extract(m."data", '$.time.completed')
            FROM "message" m JOIN "session" s ON s."id" = m."session_id"
            WHERE json_extract(m."data", '$.role') = 'assistant' AND m."time_created" >= ?1\
            \(layout.v2 ? " AND m.\"session_id\" NOT IN (SELECT \"id\" FROM \"session_v2\")" : "")
            """)
        }
        return out
    }

    // MARK: Queries

    static func sessions(_ url: URL, since: Date) -> QueryResult<SessionRow> {
        withDatabase(url) { db, layout in
            var rows: [SessionRow] = []
            for sql in sessionSQL(layout) {
                guard let batch = run(db, sql, since: since, { stmt -> SessionRow? in
                    guard let id = text(stmt, 0), let updated = date(stmt, 3) else { return nil }
                    return SessionRow(id: id, directory: text(stmt, 1) ?? "", parent: text(stmt, 2).flatMap { $0.isEmpty ? nil : $0 },
                                      updated: updated, busyAt: date(stmt, 4), idleAt: date(stmt, 5),
                                      archived: sqlite3_column_type(stmt, 6) != SQLITE_NULL,
                                      lastMessage: date(stmt, 7), openMessage: date(stmt, 8))
                }) else { return .unavailable }
                rows += batch
            }
            return .rows(rows)
        }
    }

    static func usage(_ url: URL, since: Date) -> QueryResult<UsageRow> {
        withDatabase(url) { db, layout in
            var rows: [UsageRow] = []
            for sql in usageSQL(layout) {
                guard let batch = run(db, sql, since: since, { stmt -> UsageRow? in
                    guard let session = text(stmt, 0), let created = date(stmt, 3) else { return nil }
                    return UsageRow(session: session, directory: text(stmt, 1) ?? "", subagent: text(stmt, 2).map { !$0.isEmpty } ?? false,
                                    created: created, provider: text(stmt, 4), model: text(stmt, 5),
                                    input: int(stmt, 6), output: int(stmt, 7) ?? 0, reasoning: int(stmt, 8) ?? 0,
                                    cacheRead: int(stmt, 9) ?? 0, cacheWrite: int(stmt, 10) ?? 0,
                                    cost: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 11),
                                    completed: sqlite3_column_type(stmt, 12) != SQLITE_NULL)
                }) else { return .unavailable }
                rows += batch
            }
            // Finished replies that all lack token counts: the field moved.
            let finished = rows.filter(\.completed)
            if !finished.isEmpty && finished.allSatisfy({ $0.input == nil }) { return .schemaChanged }
            return .rows(rows)
        }
    }

    private static func withDatabase<Row>(_ url: URL, _ body: (OpaquePointer, Layout) -> QueryResult<Row>) -> QueryResult<Row> {
        guard FileManager.default.fileExists(atPath: url.path), let db = open(url) else { return .unavailable }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 200)
        switch layout(db) {
        case .layout(let l): return body(db, l)
        case .schemaChanged: return .schemaChanged
        case .unavailable: return .unavailable
        }
    }

    private static func run<Row>(_ db: OpaquePointer, _ sql: String, since: Date, _ row: (OpaquePointer) -> Row?) -> [Row]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        var out: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return nil }
            if let r = row(stmt) { out.append(r) }
        }
        return out
    }

    /// Read-only, never creating anything: `mode=ro`, which sees the latest writes through opencode's write-ahead log,
    /// falling back to `immutable` (the main file alone) when that can't open, as `AntigravityApp` does.
    private static func open(_ url: URL) -> OpaquePointer? {
        let base = "file:" + (url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)
        for query in ["?mode=ro", "?mode=ro&immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2(base + query, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
               let db, !tableNames(db).isEmpty || query.contains("immutable") {
                return db
            }
            sqlite3_close_v2(db)
        }
        return nil
    }

    private static func tableNames(_ db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { if let n = text(stmt, 0) { names.insert(n) } }
        return names
    }

    private static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\"\(table)\")", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { if let n = text(stmt, 1) { names.insert(n) } }
        return names
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }

    private static func int(_ stmt: OpaquePointer, _ i: Int32) -> Int? {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL: return nil
        case SQLITE_INTEGER: return max(0, Int(sqlite3_column_int64(stmt, i)))
        default:
            let d = sqlite3_column_double(stmt, i)
            return d.isFinite ? max(0, Int(d)) : nil
        }
    }

    /// Milliseconds since 1970 (seconds also accepted). Nil for null or zero.
    private static func date(_ stmt: OpaquePointer, _ i: Int32) -> Date? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        let v = sqlite3_column_double(stmt, i)
        guard v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
    }

    // MARK: Usage

    /// The day ledger from assistant messages. opencode's own cost is used where it recorded one: a positive figure as
    /// it is, and a zero (a free or local model) as zero unless Dashbar knows the model's list price. A message with no
    /// cost is priced from Dashbar's table, and left unpriced (never guessed) for a model it doesn't know.
    static func book(_ rows: [UsageRow]) -> UsageBook {
        var book = UsageBook()
        for r in rows {
            let t = TokenTotals(input: r.input ?? 0, output: r.output + r.reasoning, cacheRead: r.cacheRead, cacheWrite: r.cacheWrite,
                                messages: 1)
            guard t.total > 0 else { continue }
            let model = r.model.flatMap { $0.isEmpty ? nil : $0 } ?? "opencode"
            let listed = Pricing.cost(t, model: model, promptTokens: t.input + t.cacheRead + t.cacheWrite)
            let cost: Double?
            switch r.cost {
            case let c? where c > 0 && c.isFinite: cost = c
            case let c? where c == 0: cost = listed ?? 0
            default: cost = listed
            }
            let project = r.directory.isEmpty ? "opencode" : Fmt.project(fromCwd: Fmt.root(fromCwd: r.directory))
            book.add(t, at: r.created, model: model, project: project, session: r.session, cost: cost, subagent: r.subagent)
        }
        return book
    }

    // MARK: Live state without the plugin

    /// Seconds since the last write after which a session counts as idle (as Gemini CLI's).
    static let activeWindow: TimeInterval = 20
    /// How long a reply still being written keeps a session working with no further write.
    static let openWindow: TimeInterval = 120
    /// A run opencode says started (2.x `time_busy`) with no write for this long is taken to have stopped.
    static let staleRun: TimeInterval = 30 * 60
    /// Idle sessions stay listed this long after their last change, while opencode runs.
    static let idleShown: TimeInterval = 30 * 60
    /// Rows read for the live state: sessions changed within this long.
    static let liveWindow: TimeInterval = 6 * 3600

    /// Whether the database says the session is working: 2.x records when each run starts and ends; otherwise a reply
    /// still being written, or any write in the last few seconds.
    static func isBusy(_ r: SessionRow, now: Date) -> Bool {
        if let busy = r.busyAt {
            guard busy > (r.idleAt ?? .distantPast) else { return false }   // the run has ended
            return now.timeIntervalSince(r.activity) < staleRun
        }
        if let open = r.openMessage, now.timeIntervalSince(open) < openWindow { return true }
        return now.timeIntervalSince(r.activity) < activeWindow
    }

    /// The live sessions, while opencode is running: each top-level session that is working, waiting, changed in the
    /// last half hour, or is its folder's newest while opencode runs there. The plugin's state wins where it has one
    /// (only it can tell that a session is waiting for you). A folder where opencode runs with no session yet still shows,
    /// idle. Nothing shows when no opencode process runs.
    static func live(rows: [SessionRow], bridged: [OpenCodeBridge.SessionState],
                     processes: [(pid: Int32, cwd: String, started: Date?)], now: Date = Date(),
                     root: (String) -> String = Fmt.root(fromCwd:)) -> [LiveSession] {
        guard !processes.isEmpty else { return [] }
        let home = homeDir.path
        var byRoot: [String: (pid: Int32, started: Date?)] = [:]
        for p in processes {
            let r = root(p.cwd.isEmpty ? home : p.cwd)
            if r != home && r != "/" && byRoot[r] == nil { byRoot[r] = (p.pid, p.started) }
        }
        let states = Dictionary(bridged.map { ($0.id, $0) }, uniquingKeysWith: { $0.writtenAt > $1.writtenAt ? $0 : $1 })
        var out: [LiveSession] = []
        var rootsShown = Set<String>(), idsShown = Set<String>()

        for r in rows.sorted(by: { $0.activity > $1.activity }) where r.parent == nil && !r.archived && !r.directory.isEmpty {
            guard !idsShown.contains(r.id) else { continue }
            let rt = root(r.directory)
            let status: String, since: Date
            // The plugin hears every start, stop and question, so its word stands while it is the newer news, or while
            // it says a run is going (it writes "idle" the moment the run ends).
            if let b = states[r.id], b.writtenAt >= r.activity.addingTimeInterval(-5) || b.state != "idle" {
                status = b.liveStatus
                since = b.writtenAt
            } else if isBusy(r, now: now) {
                status = "busy"
                since = r.busyAt ?? r.openMessage ?? r.activity
            } else {
                status = "idle"
                since = r.idleAt ?? r.activity
            }
            let newestHere = byRoot[rt] != nil && !rootsShown.contains(rt)
            guard status != "idle" || now.timeIntervalSince(r.activity) < idleShown || newestHere else { continue }
            out.append(session(id: r.id, cwd: r.directory, root: rt, status: status, since: since, pid: byRoot[rt]?.pid ?? 0))
            rootsShown.insert(rt)
            idsShown.insert(r.id)
            if out.count == 8 { break }
        }
        // Sessions only the plugin knows about yet (the database not readable, or not yet written).
        for b in states.values.sorted(by: { $0.writtenAt > $1.writtenAt })
        where !idsShown.contains(b.id) && !b.directory.isEmpty && now.timeIntervalSince(b.writtenAt) < idleShown && out.count < 8 {
            let rt = root(b.directory)
            out.append(session(id: b.id, cwd: b.directory, root: rt, status: b.liveStatus, since: b.writtenAt, pid: byRoot[rt]?.pid ?? 0))
            rootsShown.insert(rt)
            idsShown.insert(b.id)
        }
        // Folders where opencode runs with nothing in the database yet.
        for (rt, p) in byRoot.sorted(by: { $0.key < $1.key }) where !rootsShown.contains(rt) {
            out.append(session(id: "pid-\(p.pid)", cwd: rt, root: rt, status: "idle", since: p.started ?? now, pid: p.pid))
        }
        return out
    }

    private static func session(id: String, cwd: String, root: String, status: String, since: Date, pid: Int32) -> LiveSession {
        var s = LiveSession(id: "opencode-" + id, pid: pid, name: Fmt.project(fromCwd: root), cwd: cwd, status: status,
                            since: since, entrypoint: "cli", root: root)
        s.agent = .opencode
        return s
    }

    // MARK: Processes

    /// An opencode process: its own binary (also what the npm package runs), or Node or Bun running its script.
    static func isOpenCode(name: String, commandLine: String?) -> Bool {
        if name == "opencode" { return true }
        guard ["node", "bun"].contains(name), let commandLine else { return false }
        return commandLine.split(separator: " ").dropFirst().prefix(3).contains { arg in
            arg == "opencode" || arg.hasSuffix("/opencode") || arg.hasSuffix("/bin/opencode.js") || arg.contains("/opencode-ai/")
        }
    }
}

// MARK: - Collecting

/// Finds opencode among running processes: the outermost of each (the npm wrapper starts the binary as its child).
/// Command lines are read only for Node and Bun processes, once per process.
final class OpenCodeProcesses {
    private var known: [Int32: (started: Date?, match: Bool)] = [:]

    func scan() -> [(pid: Int32, cwd: String, started: Date?)] {
        var seen = Set<Int32>()
        var found: [Int32: (cwd: String, started: Date?, parent: Int32)] = [:]
        for pid in Proc.allPIDs() {
            let name = Proc.name(pid)
            guard ["opencode", "node", "bun"].contains(name) else { continue }
            seen.insert(pid)
            let info = Proc.bsdInfo(pid)
            let match: Bool
            if let hit = known[pid], hit.started == info?.started { match = hit.match }
            else {
                match = OpenCode.isOpenCode(name: name, commandLine: name == "opencode" ? nil : Proc.commandLine(pid))
                known[pid] = (info?.started, match)
            }
            if match { found[pid] = (Proc.cwd(pid) ?? "", info?.started, info?.parent ?? 0) }
        }
        known = known.filter { seen.contains($0.key) }
        return found.filter { found[$0.value.parent] == nil }.map { ($0.key, $0.value.cwd, $0.value.started) }.sorted { $0.pid < $1.pid }
    }
}

/// opencode's live sessions for the store's live refresh. Cheap for someone who doesn't use it: one pass over process
/// names, and nothing else unless opencode is running.
final class OpenCodeCollector {
    private let processes = OpenCodeProcesses()
    let database: URL
    let bridgeDir: URL
    private var stamp: [FileStamp?] = []
    private var rows: [OpenCode.SessionRow] = []
    private var readAt = Date.distantPast

    init(database: URL = OpenCode.databaseURL(), bridgeDir: URL = OpenCodeBridge.statesDir) {
        self.database = database
        self.bridgeDir = bridgeDir
    }

    func read(now: Date = Date()) -> [LiveSession] {
        let found = processes.scan()
        guard !found.isEmpty else { return [] }
        let current = FileStamp.of([database, URL(fileURLWithPath: database.path + "-wal")])
        // The window slides, so read again at least every minute even with no change.
        if current != stamp || now.timeIntervalSince(readAt) > 60 {
            stamp = current
            readAt = now
            switch OpenCode.sessions(database, since: now.addingTimeInterval(-OpenCode.liveWindow)) {
            case .rows(let r): rows = r
            case .schemaChanged: rows = []   // the usage reading says so
            case .unavailable: break         // missing or busy: keep the last reading
            }
        }
        let states = FileManager.default.fileExists(atPath: bridgeDir.path)
            ? OpenCodeBridge.readStates(dir: bridgeDir, maxAge: 12 * 3600, now: now) : []
        return OpenCode.live(rows: rows, bridged: states, processes: found, now: now)
    }
}

/// opencode's usage for the Usage tab, read again only when its database changes (and at most every 15 seconds).
final class OpenCodeUsage {
    let database: URL
    private var stamp: [FileStamp?] = []
    private var book = UsageBook()
    private var warning: String?
    private var found = false
    private var readAt = Date.distantPast

    init(database: URL = OpenCode.databaseURL()) { self.database = database }

    func scan(now: Date = Date()) -> UsageSummary {
        guard FileManager.default.fileExists(atPath: database.path) else { found = false; return .empty }
        let current = FileStamp.of([database, URL(fileURLWithPath: database.path + "-wal")])
        if (current != stamp || !found) && now.timeIntervalSince(readAt) >= 15 {
            stamp = current
            readAt = now
            switch OpenCode.usage(database, since: now.addingTimeInterval(-31 * 86400)) {
            case .rows(let rows): book = OpenCode.book(rows); warning = nil; found = true
            case .schemaChanged: book = UsageBook(); warning = OpenCode.formatWarning; found = true
            case .unavailable: break
            }
        }
        guard found else { return .empty }
        var s = book.summary(found: true)
        s.warning = warning
        return s
    }
}

/// A file's modification time and size, to tell whether it changed since the last read.
struct FileStamp: Equatable {
    var modified: Date?
    var size: Int?

    static func of(_ urls: [URL]) -> [FileStamp?] {
        urls.map { url in
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return FileStamp(modified: v.contentModificationDate, size: v.fileSize)
        }
    }
}

// MARK: - Look

extension UI {
    /// opencode, and tools after it, that have no brand colour of their own here: a neutral grey, so colour keeps
    /// meaning state (green working, amber needs you) and the four brand hues stay Claude's, Codex's and Google's.
    /// Opaque, so it reads the same on every surface: 6.0:1 on white and 7.4:1 on the dark card as text.
    static let neutralTool = Color(light: .init(hex: 0x5F6670), dark: .init(hex: 0xA9AFB8))
    static let openCodeSymbol = "square.dashed.inset.filled"
}
