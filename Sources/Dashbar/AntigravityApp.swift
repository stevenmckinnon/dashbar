import Foundation
import SQLite3

/// The Antigravity app's conversations, from the summary database it keeps (`~/.gemini/antigravity/conversation_summaries.db`).
///
/// Only status columns are read: the conversation's id, run status, when it last changed and the folders it works in
/// (plus, when present, whether it was killed, is not fully idle, and its parent). Never its title, preview, summary or
/// the search index, which hold what was said. The database is opened read-only through the system's SQLite (no new
/// dependency), and only when its files have changed since the last read. Its transcripts are encrypted and not read.
/// If the table no longer has the columns Dashbar relies on, it says so rather than showing nothing.
final class AntigravityApp {
    static let defaultURL = homeDir.appendingPathComponent(".gemini/antigravity/conversation_summaries.db")
    static let formatWarning = "Couldn't read the Antigravity app's conversations. Its format may have changed, so check for a Dashbar update."

    struct Row: Equatable {
        var id: String
        var status: String
        var modified: Date
        var workspaces: [String]
        var notFullyIdle = false
        var killed = false
        var parent: String = ""
    }

    struct Reading: Equatable {
        var sessions: [LiveSession] = []
        var warning: String?
    }

    private let url: URL
    /// The database and its write-ahead log's modification times at the last read, and the rows read then.
    private var stamp: [Date?] = []
    private var rows: [Row] = []
    private var warning: String?

    init(url: URL = AntigravityApp.defaultURL) { self.url = url }

    func read(now: Date = Date()) -> Reading {
        let files = [url, URL(fileURLWithPath: url.path + "-wal")]
        let current = files.map { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if current != stamp {
            stamp = current
            switch Self.query(url) {
            case .rows(let r): rows = r; warning = nil
            case .schemaChanged: rows = []; warning = Self.formatWarning
            case .unavailable: break   // missing or busy: keep the last reading
            }
        }
        return Reading(sessions: Self.live(rows, now: now), warning: warning)
    }

    // MARK: Which conversations are live

    /// Working or waiting conversations changed within six hours, and idle ones changed within 30 minutes: top-level
    /// conversations only (a subagent's work shows under its parent), not killed, with a folder to file them under.
    static func live(_ rows: [Row], now: Date = Date(), root: (String) -> String = Fmt.root(fromCwd:)) -> [LiveSession] {
        var out: [LiveSession] = []
        for r in rows where !r.killed && r.parent.isEmpty {
            guard let folder = r.workspaces.first else { continue }
            let age = now.timeIntervalSince(r.modified)
            var state = Self.state(r.status)
            if state == .idle, r.notFullyIdle, age < 5 * 60 { state = .busy }
            guard age < (state == .idle ? 30 * 60 : 6 * 3600) else { continue }
            let rt = root(folder)
            var s = LiveSession(id: "antigravity-" + r.id, pid: 0, name: Fmt.project(fromCwd: rt), cwd: folder,
                                status: state.rawValue, since: r.modified, entrypoint: "Antigravity", root: rt,
                                waitingFor: state == .waiting ? "input needed" : nil)
            s.agent = .antigravity
            out.append(s)
            if out.count == 8 { break }
        }
        return out
    }

    enum State: String { case busy, idle, waiting }

    /// `CASCADE_RUN_STATUS_IDLE` and the like. Anything that isn't plainly idle, finished or waiting counts as working.
    static func state(_ status: String) -> State {
        let s = status.uppercased()
        if s.isEmpty || ["IDLE", "DONE", "COMPLETE", "FINISH", "CANCEL", "ERROR", "FAIL", "STOP", "UNSPECIFIED"].contains(where: s.contains) {
            return .idle
        }
        if ["WAIT", "USER", "APPROV", "CONFIRM", "INPUT", "PAUSE"].contains(where: s.contains) { return .waiting }
        return .busy
    }

    // MARK: SQLite

    enum QueryResult: Equatable {
        case rows([Row])
        case schemaChanged
        case unavailable
    }

    static let required = ["conversation_id", "status", "last_modified_time", "workspace_uris"]
    static let optional = ["not_fully_idle", "killed", "parent_conversation_id"]

    static func query(_ url: URL, limit: Int = 60) -> QueryResult {
        guard FileManager.default.fileExists(atPath: url.path), let db = open(url) else { return .unavailable }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 200)
        guard let columns = columns(db, table: "conversation_summaries") else { return .unavailable }
        guard Set(required).isSubset(of: columns) else { return .schemaChanged }
        let extra = optional.filter(columns.contains)
        let names = required + extra
        let sql = "SELECT " + names.map { "\"\($0)\"" }.joined(separator: ", ")
            + " FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return .unavailable }
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        var unreadable = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            func flag(_ name: String) -> Bool {
                guard let i = extra.firstIndex(of: name) else { return false }
                let col = Int32(required.count + i)
                return sqlite3_column_type(stmt, col) == SQLITE_TEXT ? ["1", "true"].contains(text(col).lowercased())
                    : sqlite3_column_int64(stmt, col) != 0
            }
            let modified: Date?
            if sqlite3_column_type(stmt, 2) == SQLITE_TEXT { modified = parseTime(text(2)) }
            else { modified = epoch(sqlite3_column_double(stmt, 2)) }
            guard let modified, let workspaces = parseWorkspaces(text(3)) else { unreadable += 1; continue }
            rows.append(Row(id: text(0), status: text(1), modified: modified, workspaces: workspaces,
                            notFullyIdle: flag("not_fully_idle"), killed: flag("killed"),
                            parent: extra.firstIndex(of: "parent_conversation_id").map { text(Int32(required.count + $0)) } ?? ""))
        }
        // Rows whose times or folders no longer parse: the format changed.
        if rows.isEmpty && unreadable > 0 { return .schemaChanged }
        return .rows(rows)
    }

    /// Read-only. Antigravity keeps the database in WAL mode, so a plain read-only open sees its latest writes; if that
    /// can't open (no shared-memory file it may use), it falls back to `immutable`, which reads the main file alone.
    private static func open(_ url: URL) -> OpaquePointer? {
        let base = "file:" + (url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)
        for query in ["?mode=ro", "?mode=ro&immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2(base + query, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
               let db, columns(db, table: "conversation_summaries") != nil || query.contains("immutable") {
                return db
            }
            sqlite3_close_v2(db)
        }
        return nil
    }

    private static func columns(_ db: OpaquePointer, table: String) -> Set<String>? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names.isEmpty ? nil : names
    }

    /// `2025-11-19 19:46:55.197001+00:00`, with or without fractions or a `T`.
    static func parseTime(_ s: String) -> Date? {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        // ISO 8601 parsing takes milliseconds: cut longer fractions to three digits.
        if let dot = t.firstIndex(of: ".") {
            let digits = t[t.index(after: dot)...].prefix { $0.isNumber }
            if digits.count > 3 {
                let start = t.index(after: dot)
                t.replaceSubrange(start..<t.index(start, offsetBy: digits.count), with: digits.prefix(3))
            }
        }
        if !t.hasSuffix("Z"), t.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) == nil { t += "Z" }
        return Date.fromISO(t) ?? Double(s).flatMap(epoch)
    }

    /// Seconds or milliseconds since 1970.
    private static func epoch(_ v: Double) -> Date? {
        guard v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
    }

    /// `["file:///Users/me/app"]` (or a bare comma-separated list): local folder paths. Nil when it isn't either.
    static func parseWorkspaces(_ s: String) -> [String]? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        let items: [String]
        if trimmed.hasPrefix("[") {
            guard let list = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [Any] else { return nil }
            items = list.compactMap { $0 as? String }
        } else {
            items = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return items.compactMap { item in
            if item.hasPrefix("/") { return item }
            guard let u = URL(string: item), u.isFileURL else { return nil }
            return u.path
        }
    }
}
