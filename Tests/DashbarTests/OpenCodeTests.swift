import Foundation
import Testing
import SQLite3
import JavaScriptCore
@testable import Dashbar
import DashbarStatus

// All of these work on throwaway folders and databases. Nothing here reads or writes the real ~/.local/share/opencode
// or ~/.config/opencode.

/// Databases shaped like opencode's, with the private columns it really has, filled with stand-ins that must never come back.
enum OpenCodeFixture {
    static let v1Tables = """
    CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, workspace_id text, parent_id text, slug text NOT NULL,
      directory text NOT NULL, path text, title text NOT NULL, version text NOT NULL, share_url text, summary_diffs text,
      metadata text, cost real DEFAULT 0 NOT NULL, tokens_input integer DEFAULT 0 NOT NULL, permission text, agent text,
      model text, time_created integer NOT NULL, time_updated integer NOT NULL, time_compacting integer, time_archived integer);
    CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL,
      time_updated integer NOT NULL, data text NOT NULL);
    CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL,
      time_updated integer NOT NULL, data text NOT NULL);
    """

    static let v2Tables = """
    CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, workspace_id text, parent_id text,
      fork_session_id text, fork_boundary text, slug text NOT NULL, directory text NOT NULL, path text, title text,
      version text NOT NULL, share_url text, summary_diffs text, metadata text, cost real DEFAULT 0 NOT NULL,
      permission text, agent text, model text, time_created integer NOT NULL, time_updated integer NOT NULL,
      time_busy integer, time_idle integer, time_archived integer);
    CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL,
      time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    CREATE TABLE session_part (message_id text NOT NULL, session_id text NOT NULL, ordinal integer NOT NULL, type text NOT NULL,
      time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    """

    static func make(_ url: URL, _ statements: [String]) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in ["PRAGMA journal_mode=WAL;"] + statements {
            var error: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &error)
            if rc != SQLITE_OK { Issue.record("SQL failed: \(error.map { String(cString: $0) } ?? "?") in \(sql)") }
        }
    }

    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    static func json(_ o: [String: Any]) -> String {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func tokens(_ input: Int, _ output: Int, reasoning: Int = 0, read: Int = 0, write: Int = 0) -> [String: Any] {
        ["input": input, "output": output, "reasoning": reasoning, "cache": ["read": read, "write": write]]
    }

    static func v1Session(_ id: String, dir: String, updated: Date, parent: String? = nil, archived: Date? = nil) -> String {
        """
        INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, share_url, summary_diffs, metadata,
          time_created, time_updated, time_archived)
        VALUES ('\(id)', 'prj', \(parent.map { "'\($0)'" } ?? "NULL"), 'secret-slug', '\(dir)', 'SECRET TITLE', '1.19.5',
          'https://SECRET-SHARE', '[{"file":"SECRET-DIFF"}]', '{"note":"SECRET-METADATA"}', \(ms(updated) - 60_000), \(ms(updated)),
          \(archived.map { "\(ms($0))" } ?? "NULL"));
        """
    }

    static func v1Assistant(_ id: String, session: String, at: Date, model: String = "claude-sonnet-5-5", cost: Double? = 0.5,
                            tokens: [String: Any]? = OpenCodeFixture.tokens(1000, 200, reasoning: 50, read: 3000, write: 100),
                            completed: Bool = true, updated: Date? = nil) -> String {
        var data: [String: Any] = ["role": "assistant", "providerID": "anthropic", "modelID": model, "mode": "build",
                                   "path": ["cwd": "/SECRET-PATH", "root": "/SECRET-PATH"],
                                   "time": completed ? ["created": ms(at), "completed": ms(at) + 5000] : ["created": ms(at)]]
        if let cost { data["cost"] = cost }
        if let tokens { data["tokens"] = tokens }
        return "INSERT INTO message VALUES ('\(id)', '\(session)', \(ms(at)), \(ms(updated ?? at)), \(json(data)));"
    }

    static func v1User(_ id: String, session: String, at: Date) -> [String] {
        ["INSERT INTO message VALUES ('\(id)', '\(session)', \(ms(at)), \(ms(at)), \(json(["role": "user", "time": ["created": ms(at)], "summary": ["title": "SECRET SUMMARY"]])));",
         "INSERT INTO part VALUES ('prt_\(id)', '\(id)', '\(session)', \(ms(at)), \(ms(at)), \(json(["type": "text", "text": "SECRET PROMPT TEXT"])));"]
    }

    static func v2Session(_ id: String, dir: String, created: Date, updated: Date, busy: Date? = nil, idle: Date? = nil,
                          fork: String? = nil, parent: String? = nil) -> String {
        func opt(_ d: Date?) -> String { d.map { "\(ms($0))" } ?? "NULL" }
        return """
        INSERT INTO session_v2 (id, project_id, parent_id, fork_session_id, slug, directory, title, version, metadata,
          time_created, time_updated, time_busy, time_idle)
        VALUES ('\(id)', 'prj', \(parent.map { "'\($0)'" } ?? "NULL"), \(fork.map { "'\($0)'" } ?? "NULL"), 'secret-slug', '\(dir)',
          'SECRET TITLE', '2.3.0', '{"note":"SECRET-METADATA"}', \(ms(created)), \(ms(updated)), \(opt(busy)), \(opt(idle)));
        """
    }

    static func v2Assistant(_ id: String, session: String, seq: Int, at: Date, model: String = "gpt-6.1-terra", cost: Double? = 0.25,
                            tokens: [String: Any]? = OpenCodeFixture.tokens(500, 100, read: 2000), completed: Bool = true) -> String {
        var data: [String: Any] = ["agent": "build", "model": ["id": model, "providerID": "openai"],
                                   "content": [["type": "text", "text": "SECRET REPLY"]],
                                   "time": completed ? ["created": ms(at), "completed": ms(at) + 3000] : ["created": ms(at)]]
        if let cost { data["cost"] = cost }
        if let tokens { data["tokens"] = tokens }
        return "INSERT INTO session_message VALUES ('\(id)', '\(session)', 'assistant', \(seq), \(ms(at)), \(ms(at)), \(json(data)));"
    }

    static func v2User(_ id: String, session: String, seq: Int, at: Date) -> [String] {
        ["INSERT INTO session_message VALUES ('\(id)', '\(session)', 'user', \(seq), \(ms(at)), \(ms(at)), \(json(["text": "SECRET PROMPT TEXT", "time": ["created": ms(at)]])));",
         "INSERT INTO session_part VALUES ('\(id)', '\(session)', 0, 'text', \(ms(at)), \(ms(at)), \(json(["text": "SECRET PART"])));"]
    }
}

// MARK: - Reading the database

@Suite struct OpenCodeReaderTests {
    typealias F = OpenCodeFixture
    let now = Date()

    @Test func readsA1xStoreAssistantMessagesOnly() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("opencode.db")
        try F.make(url, [F.v1Tables,
                         F.v1Session("ses_1", dir: "/p/app", updated: now.addingTimeInterval(-60)),
                         F.v1Session("ses_2", dir: "/p/app", updated: now.addingTimeInterval(-30), parent: "ses_1"),
                         F.v1Assistant("msg_a", session: "ses_1", at: now.addingTimeInterval(-120)),
                         F.v1Assistant("msg_b", session: "ses_2", at: now.addingTimeInterval(-40), cost: 0.1,
                                       tokens: F.tokens(10, 20))]
                     + F.v1User("msg_u", session: "ses_1", at: now.addingTimeInterval(-130)))
        guard case .rows(let rows) = OpenCode.usage(url, since: now.addingTimeInterval(-86400)) else { Issue.record("no rows"); return }
        #expect(rows.count == 2)
        let a = try #require(rows.first { $0.session == "ses_1" })
        #expect(a.directory == "/p/app" && !a.subagent && a.model == "claude-sonnet-5-5" && a.provider == "anthropic")
        #expect(a.input == 1000 && a.output == 200 && a.reasoning == 50 && a.cacheRead == 3000 && a.cacheWrite == 100)
        #expect(a.cost == 0.5 && a.completed)
        #expect(rows.first { $0.session == "ses_2" }?.subagent == true)

        let summary = OpenCode.book(rows).summary(found: true)
        // Reasoning is billed as output, as opencode's own cost does.
        #expect(summary.today.input == 1010 && summary.today.output == 270 && summary.today.cacheRead == 3000)
        #expect(abs(summary.period(.today).cost - 0.6) < 1e-9)
        #expect(summary.period(.today).subagentTokens == 30)
    }

    @Test func readsA2xStoreAndSkipsAForksCopiedMessages() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("opencode.db")
        try F.make(url, [F.v2Tables,
                         F.v2Session("ses_a", dir: "/p/two", created: now.addingTimeInterval(-3600), updated: now.addingTimeInterval(-60)),
                         F.v2Session("ses_f", dir: "/p/two", created: now.addingTimeInterval(-100), updated: now.addingTimeInterval(-50),
                                     fork: "ses_a"),
                         F.v2Assistant("m1", session: "ses_a", seq: 1, at: now.addingTimeInterval(-1000)),
                         F.v2Assistant("m1copy", session: "ses_f", seq: 1, at: now.addingTimeInterval(-1000)),   // the fork's copy
                         F.v2Assistant("m2", session: "ses_f", seq: 2, at: now.addingTimeInterval(-50), tokens: F.tokens(7, 3))]
                     + F.v2User("u1", session: "ses_a", seq: 0, at: now.addingTimeInterval(-1100)))
        guard case .rows(let rows) = OpenCode.usage(url, since: now.addingTimeInterval(-86400)) else { Issue.record("no rows"); return }
        #expect(rows.map(\.session).sorted() == ["ses_a", "ses_f"])
        #expect(rows.first { $0.session == "ses_a" }?.model == "gpt-6.1-terra")
        #expect(rows.first { $0.session == "ses_a" }?.provider == "openai")
        let total = rows.reduce(0) { $0 + ($1.input ?? 0) }
        #expect(total == 507)
    }

    @Test func aHalfMigratedStoreCountsEachSessionOnce() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("opencode.db")
        let at = now.addingTimeInterval(-300)
        try F.make(url, [F.v1Tables, F.v2Tables,
                         // Copied across under the same id, with its message in both tables.
                         F.v1Session("ses_m", dir: "/p/mig", updated: at),
                         F.v1Assistant("old_m", session: "ses_m", at: at, tokens: F.tokens(1000, 0)),
                         F.v2Session("ses_m", dir: "/p/mig", created: at.addingTimeInterval(-60), updated: at),
                         F.v2Assistant("new_m", session: "ses_m", seq: 1, at: at, tokens: F.tokens(1000, 0)),
                         // Not copied yet: only in 1.x's tables.
                         F.v1Session("ses_old", dir: "/p/old", updated: at),
                         F.v1Assistant("old_o", session: "ses_old", at: at, tokens: F.tokens(40, 0))])
        guard case .rows(let rows) = OpenCode.usage(url, since: now.addingTimeInterval(-86400)) else { Issue.record("no rows"); return }
        #expect(rows.count == 2)
        #expect(rows.reduce(0) { $0 + ($1.input ?? 0) } == 1040)
        guard case .rows(let sessions) = OpenCode.sessions(url, since: now.addingTimeInterval(-3600)) else { Issue.record("no sessions"); return }
        #expect(sessions.map(\.id).sorted() == ["ses_m", "ses_old"])
    }

    @Test func sessionRowsCarryTimesOnly() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let v2 = fx.root.appendingPathComponent("v2.db")
        try F.make(v2, [F.v2Tables,
                        F.v2Session("ses_busy", dir: "/p/a", created: now.addingTimeInterval(-900), updated: now.addingTimeInterval(-900),
                                    busy: now.addingTimeInterval(-60), idle: now.addingTimeInterval(-600)),
                        F.v2Session("ses_gone", dir: "/p/b", created: now.addingTimeInterval(-90_000), updated: now.addingTimeInterval(-90_000))])
        guard case .rows(let rows) = OpenCode.sessions(v2, since: now.addingTimeInterval(-3600)) else { Issue.record("no rows"); return }
        #expect(rows.map(\.id) == ["ses_busy"])   // the other is older than the window
        let r = try #require(rows.first)
        #expect(r.directory == "/p/a" && r.busyAt != nil && r.idleAt != nil && !r.archived)

        let v1 = fx.root.appendingPathComponent("v1.db")
        try F.make(v1, [F.v1Tables,
                        F.v1Session("ses_w", dir: "/p/w", updated: now.addingTimeInterval(-3000)),
                        F.v1Assistant("open", session: "ses_w", at: now.addingTimeInterval(-40), completed: false,
                                      updated: now.addingTimeInterval(-5))])
        guard case .rows(let rows1) = OpenCode.sessions(v1, since: now.addingTimeInterval(-3600)) else { Issue.record("no rows"); return }
        let w = try #require(rows1.first)
        #expect(w.openMessage != nil && w.busyAt == nil)
        #expect(OpenCode.isBusy(w, now: now))
    }

    @Test func anUnknownSchemaWarnsAndNeverReportsZero() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let changed = fx.root.appendingPathComponent("changed.db")
        try F.make(changed, ["CREATE TABLE session_v2 (id text, folder text, time_created integer, time_updated integer);",
                             "CREATE TABLE session_message (id text, session_id text, type text, time_created integer, time_updated integer, data text);"])
        #expect(OpenCode.usage(changed, since: .distantPast) == .schemaChanged)
        #expect(OpenCode.sessions(changed, since: .distantPast) == .schemaChanged)
        let s = OpenCodeUsage(database: changed).scan(now: now)
        #expect(s.found && s.warning == OpenCode.formatWarning)

        let other = fx.root.appendingPathComponent("other.db")
        try F.make(other, ["CREATE TABLE conversations (id text);"])
        #expect(OpenCode.usage(other, since: .distantPast) == .schemaChanged)

        // Finished replies that all lack token counts: the field moved.
        let moved = fx.root.appendingPathComponent("moved.db")
        try F.make(moved, [F.v2Tables,
                           F.v2Session("ses", dir: "/p", created: now.addingTimeInterval(-60), updated: now),
                           F.v2Assistant("m", session: "ses", seq: 1, at: now.addingTimeInterval(-30), tokens: nil)])
        #expect(OpenCode.usage(moved, since: now.addingTimeInterval(-3600)) == .schemaChanged)
        // …while a reply still being written may lack them.
        let writing = fx.root.appendingPathComponent("writing.db")
        try F.make(writing, [F.v2Tables,
                             F.v2Session("ses", dir: "/p", created: now.addingTimeInterval(-60), updated: now),
                             F.v2Assistant("m", session: "ses", seq: 1, at: now.addingTimeInterval(-30), tokens: nil, completed: false)])
        guard case .rows = OpenCode.usage(writing, since: now.addingTimeInterval(-3600)) else { Issue.record("expected rows"); return }
    }

    @Test func aMissingOrEmptyDatabaseIsQuietAndNeverCreated() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let missing = fx.root.appendingPathComponent("opencode.db")
        #expect(OpenCode.usage(missing, since: .distantPast) == .unavailable)
        #expect(OpenCode.sessions(missing, since: .distantPast) == .unavailable)
        let usage = OpenCodeUsage(database: missing).scan(now: now)
        #expect(!usage.found && usage.warning == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(!FileManager.default.fileExists(atPath: missing.path + "-wal"))

        let empty = fx.root.appendingPathComponent("empty.db")
        try F.make(empty, [])
        #expect(OpenCode.usage(empty, since: .distantPast) == .unavailable)
        let e = OpenCodeUsage(database: empty).scan(now: now)
        #expect(!e.found && e.warning == nil)
    }

    @Test func readingNeverChangesTheDatabase() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("opencode.db")
        try F.make(url, [F.v2Tables, F.v2Session("ses", dir: "/p", created: now, updated: now),
                         F.v2Assistant("m", session: "ses", seq: 1, at: now)])
        let before = try Data(contentsOf: url)
        _ = OpenCode.usage(url, since: .distantPast)
        _ = OpenCode.sessions(url, since: .distantPast)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func costUsesOpencodesFigureAndNeverInventsAPrice() {
        func row(_ model: String, cost: Double?) -> OpenCode.UsageRow {
            OpenCode.UsageRow(session: "s", directory: "/p/app", subagent: false, created: now, provider: "x", model: model,
                              input: 1_000_000, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: cost, completed: true)
        }
        let listed = Pricing.cost(TokenTotals(input: 1_000_000), model: "claude-sonnet-5-5", promptTokens: 1_000_000) ?? -1
        #expect(listed > 0)
        let p = OpenCode.book([row("claude-sonnet-5-5", cost: 0.42),   // opencode's own figure
                               row("qwen3-coder", cost: 0),              // a local model: free
                               row("mystery-model", cost: nil),          // no figure, no list price: unknown
                               row("claude-sonnet-5-5", cost: nil)])     // no figure: list price
            .summary(found: true).period(.today)
        #expect(abs(p.cost - (0.42 + listed)) < 1e-9)
        #expect(p.unpriced == ["mystery-model"])
    }
}

// MARK: - Only status, ids, folders, times and counts are ever selected

@Suite struct OpenCodeColumnGuardTests {
    static func allLayouts() -> [OpenCode.Layout] {
        let v1 = Set(["id", "directory", "time_created", "time_updated", "parent_id", "time_archived", "title", "slug"])
        let v2 = v1.union(["time_busy", "time_idle", "fork_session_id", "summary_diffs", "metadata"])
        return [OpenCode.Layout(v1: true, v1Session: v1), OpenCode.Layout(v2: true, v2Session: v2),
                OpenCode.Layout(v1: true, v2: true, v1Session: v1, v2Session: v2),
                OpenCode.Layout(v1: true, v2: true, v1Session: OpenCode.Layout.sessionRequired, v2Session: OpenCode.Layout.sessionRequired)]
    }

    static let forbidden = ["title", "text", "content", "contents", "part", "parts", "session_part", "summary", "summary_diffs",
                            "slug", "metadata", "permission", "revert", "share_url", "prompt", "snapshot", "native", "error",
                            "path", "agent", "instruction", "inbox", "blob"]
    static let allowedPaths: Set<String> = ["$.role", "$.model.id", "$.model.providerID", "$.modelID", "$.providerID",
                                            "$.tokens.input", "$.tokens.output", "$.tokens.reasoning", "$.tokens.cache.read",
                                            "$.tokens.cache.write", "$.cost", "$.time.completed", "$.time.created"]

    @Test func noStatementReadsTitlesTextOrContent() throws {
        let statements = Self.allLayouts().flatMap { OpenCode.sessionSQL($0) + OpenCode.usageSQL($0) }
        #expect(statements.count >= 8)
        for sql in statements {
            let words = Set(sql.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(["_"]).inverted))
            for word in Self.forbidden { #expect(!words.contains(word), "SQL reads \(word): \(sql)") }
            // Every JSON path is one of the allowed fields…
            let paths = try NSRegularExpression(pattern: #"'(\$[^']*)'"#)
                .matches(in: sql, range: NSRange(sql.startIndex..., in: sql))
                .compactMap { Range($0.range(at: 1), in: sql).map { String(sql[$0]) } }
            for p in paths { #expect(Self.allowedPaths.contains(p), "SQL reads \(p)") }
            // …and the data column is only ever read through json_extract.
            let bare = sql.replacingOccurrences(of: #"json_extract\((m\.)?"data""#, with: "", options: .regularExpression)
            #expect(!bare.contains("\"data\""), "SQL reads the whole data column: \(sql)")
            #expect(!sql.contains("*"), "SQL selects every column: \(sql)")
        }
    }
}

// MARK: - Live state

@Suite struct OpenCodeLiveTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    let proc: [(pid: Int32, cwd: String, started: Date?)] = [(pid: 4242, cwd: "/p/app", started: nil)]

    func row(_ id: String, dir: String = "/p/app", updated: TimeInterval, busy: TimeInterval? = nil, idle: TimeInterval? = nil,
             last: TimeInterval? = nil, open: TimeInterval? = nil, parent: String? = nil, archived: Bool = false) -> OpenCode.SessionRow {
        OpenCode.SessionRow(id: id, directory: dir, parent: parent, updated: ago(updated), busyAt: busy.map(ago), idleAt: idle.map(ago),
                            archived: archived, lastMessage: last.map(ago), openMessage: open.map(ago))
    }

    func live(_ rows: [OpenCode.SessionRow], bridged: [OpenCodeBridge.SessionState] = [],
              processes: [(pid: Int32, cwd: String, started: Date?)]? = nil) -> [LiveSession] {
        OpenCode.live(rows: rows, bridged: bridged, processes: processes ?? proc, now: now, root: { $0 })
    }

    @Test func nothingShowsWithoutAnOpencodeProcess() {
        #expect(live([row("a", updated: 5, busy: 5)], processes: []).isEmpty)
    }

    @Test func the2xRunColumnsSayWorkingOrIdle() {
        let running = live([row("a", updated: 600, busy: 60, idle: 600)])
        #expect(running.first?.isBusy == true && running.first?.since == ago(60))
        let ended = live([row("a", updated: 600, busy: 600, idle: 60)])
        #expect(ended.first?.status == "idle" && ended.first?.since == ago(60))
        // A run that never ended, with nothing written for an hour: opencode stopped, so it isn't working.
        #expect(!OpenCode.isBusy(row("a", updated: 3600, busy: 3600), now: now))
    }

    @Test func without2xColumnsAReplyBeingWrittenOrARecentWriteMeansWorking() {
        #expect(OpenCode.isBusy(row("a", updated: 900, last: 30, open: 30), now: now))
        #expect(OpenCode.isBusy(row("a", updated: 5), now: now))
        #expect(!OpenCode.isBusy(row("a", updated: 900, last: 600, open: 600), now: now))
        #expect(!OpenCode.isBusy(row("a", updated: 300, last: 300), now: now))
    }

    @Test func onlyTopLevelLiveSessionsShowAndTheyNeverCarryATitle() {
        let rows = [row("main", updated: 10), row("child", updated: 5, parent: "main"), row("old", updated: 300, archived: true),
                    row("stale", dir: "/p/other", updated: 7200)]
        let out = live(rows)
        #expect(out.map(\.id) == ["opencode-main"])
        let s = out[0]
        #expect(s.agent == .opencode && s.pid == 4242 && s.name == "app" && s.title == "opencode")
    }

    @Test func theFoldersNewestSessionStaysWhileOpencodeRunsThere() {
        // Idle for an hour, but opencode is open in that folder: it's what the terminal shows.
        let out = live([row("a", updated: 3600)])
        #expect(out.map(\.id) == ["opencode-a"] && out[0].status == "idle")
        // A folder opencode runs in with no session yet still shows, idle.
        let fresh = live([], processes: [(pid: 7, cwd: "/p/new", started: ago(30))])
        #expect(fresh.map(\.id) == ["opencode-pid-7"] && fresh[0].since == ago(30) && fresh[0].root == "/p/new")
        // opencode running from the home folder (a server) anchors nothing, but lets recent sessions show.
        let server = live([row("a", dir: "/p/x", updated: 60)], processes: [(pid: 8, cwd: homeDir.path, started: nil)])
        #expect(server.map(\.id) == ["opencode-a"] && server[0].pid == 0)
    }

    @Test func thePluginsStateWinsAndIsTheOnlyWayToNeedYou() {
        let asks = OpenCodeBridge.SessionState(id: "a", directory: "/p/app", state: "needsYou", writtenAt: ago(20))
        let out = live([row("a", updated: 30, last: 30)], bridged: [asks])
        #expect(out.first?.isWaiting == true)
        #expect(out.first?.waitingSentence == "opencode is waiting for you")
        // A session only the plugin knows about yet.
        let only = OpenCodeBridge.SessionState(id: "b", directory: "/p/app", state: "working", writtenAt: ago(5))
        #expect(live([], bridged: [only]).map(\.id) == ["opencode-b"])
        // An older "idle" doesn't hide newer work in the database.
        let oldIdle = OpenCodeBridge.SessionState(id: "c", directory: "/p/app", state: "idle", writtenAt: ago(600))
        #expect(live([row("c", updated: 600, last: 10, open: 10)], bridged: [oldIdle]).first?.isBusy == true)
    }

    @Test func sessionsGroupIntoWorkspacesByFolder() {
        let rows = [row("a", dir: "/p/app", updated: 10, busy: 10), row("b", dir: "/p/app", updated: 20),
                    row("c", dir: "/p/site", updated: 30, busy: 30)]
        let ws = Workspace.build(sessions: live(rows), servers: [])
        #expect(ws.map(\.root).sorted() == ["/p/app", "/p/site"])
        #expect(ws.first { $0.root == "/p/app" }?.sessions.count == 2)
        #expect(ws.first { $0.root == "/p/app" }?.isBusy == true)
    }

    @Test func recognisesOpencodeProcesses() {
        #expect(OpenCode.isOpenCode(name: "opencode", commandLine: nil))
        #expect(OpenCode.isOpenCode(name: "node", commandLine: "node /usr/local/lib/node_modules/opencode-ai/bin/opencode"))
        #expect(OpenCode.isOpenCode(name: "bun", commandLine: "bun /Users/x/.bun/bin/opencode run"))
        #expect(!OpenCode.isOpenCode(name: "node", commandLine: "node server.js --port 3000"))
        #expect(!OpenCode.isOpenCode(name: "node", commandLine: nil))
        #expect(!OpenCode.isOpenCode(name: "opencoder", commandLine: nil))
    }
}

// MARK: - The plugin

@Suite struct OpenCodeBridgeTests {
    func paths(_ fx: Fixture) -> OpenCodeBridge.Paths {
        OpenCodeBridge.Paths(config: fx.root.appendingPathComponent("config/opencode"),
                             database: fx.root.appendingPathComponent("data/opencode/opencode.db"),
                             states: fx.root.appendingPathComponent("caches/opencode-sessions"))
    }

    @Test func absentUntilOpencodeIsInstalled() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        #expect(OpenCodeBridge.status(p) == .absent)
        _ = try fx.dir("data/opencode")
        FileManager.default.createFile(atPath: p.database.path, contents: Data())
        #expect(OpenCodeBridge.status(p) == .notInstalled)
    }

    @Test func addWritesOnlyDashbarsFileAndRemoveDeletesOnlyIt() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        _ = try fx.dir("config/opencode/plugins")
        let theirs = p.plugins.appendingPathComponent("theirs.js")
        try "export default {}".write(to: theirs, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: p.states, withIntermediateDirectories: true)
        #expect(OpenCodeBridge.status(p) == .notInstalled)

        try OpenCodeBridge.install(p)
        #expect(OpenCodeBridge.status(p) == .installed)
        #expect(try String(contentsOf: p.file, encoding: .utf8) == OpenCodeBridge.script)
        let mode = try FileManager.default.attributesOfItem(atPath: p.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
        try OpenCodeBridge.install(p)   // again: nothing changes

        try OpenCodeBridge.uninstall(p)
        #expect(!FileManager.default.fileExists(atPath: p.file.path))
        #expect(FileManager.default.fileExists(atPath: theirs.path))
        #expect(FileManager.default.fileExists(atPath: p.plugins.path))
        #expect(!FileManager.default.fileExists(atPath: p.states.path))
        #expect(OpenCodeBridge.status(p) == .notInstalled)
    }

    @Test func addCreatesThePluginsFolderWhenOnlyTheDatabaseExists() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        _ = try fx.dir("data/opencode")
        FileManager.default.createFile(atPath: p.database.path, contents: Data())
        try OpenCodeBridge.install(p)
        #expect(OpenCodeBridge.status(p) == .installed)
    }

    @Test func aDashbarJsSomeoneElseWroteIsNeverReplacedOrRemoved() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        _ = try fx.dir("config/opencode/plugins")
        try "// my own plugin\nexport default {}".write(to: p.file, atomically: true, encoding: .utf8)
        #expect(OpenCodeBridge.status(p) == .conflict)
        #expect(throws: OpenCodeBridge.Failure.self) { try OpenCodeBridge.install(p) }
        try OpenCodeBridge.uninstall(p)
        #expect(try String(contentsOf: p.file, encoding: .utf8).hasPrefix("// my own plugin"))
    }

    @Test func aCopyInTheSingularFolderCountsAndIsRemoved() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        _ = try fx.dir("config/opencode/plugin")
        try OpenCodeBridge.script.write(to: p.legacyFile, atomically: true, encoding: .utf8)
        #expect(OpenCodeBridge.status(p) == .installed)
        try OpenCodeBridge.uninstall(p)
        #expect(!FileManager.default.fileExists(atPath: p.legacyFile.path))
    }

    @Test func theScriptSendsNothingAndKeepsItsFilesPrivate() {
        let s = OpenCodeBridge.script
        #expect(s.hasPrefix(OpenCodeBridge.marker))
        for banned in ["fetch(", "http", "child_process", "require(", "node:net", "node:http", "WebSocket", "XMLHttpRequest",
                       "client.", "eval(", ".reply(", "respond"] {
            #expect(!s.contains(banned), "the plugin uses \(banned)")
        }
        #expect(s.contains("mode: 0o700") && s.contains("chmodSync(dir, 0o700)") && s.contains("mode: 0o600"))
        #expect(s.contains("export default { id: \"dashbar\", server: server, setup: setup }"))
        #expect(s.contains("Library\", \"Caches\", \"Dashbar\", \"opencode-sessions\""))
    }

    @Test func parsesOnlyKnownStates() {
        let ok = #"{"version":1,"session_id":"ses_1","directory":"/p/app","state":"needsYou","written_at":1800000000000,"extra":"x"}"#
        let s = OpenCodeBridge.parseState(Data(ok.utf8))
        #expect(s?.liveStatus == "waiting" && s?.directory == "/p/app" && s?.writtenAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(OpenCodeBridge.parseState(Data(#"{"session_id":"a","state":"thinking","written_at":1}"#.utf8)) == nil)
        #expect(OpenCodeBridge.parseState(Data(#"{"session_id":"a","state":"idle","written_at":1,"directory":"relative"}"#.utf8))?.directory == "")
    }
}

// MARK: - The plugin's logic, run in JavaScriptCore

/// The shipped script's state machine (between its core markers), fed sample events from opencode 1.x and 2.x that carry
/// prompts, commands and permission text. Only Node's file calls are left out: JavaScriptCore has no `node:fs`.
@Suite struct OpenCodePluginLogicTests {
    final class Harness {
        let ctx = JSContext()!
        var exception: String?

        init() throws {
            let script = OpenCodeBridge.script
            let start = try #require(script.range(of: "// dashbar-core-begin"))
            let end = try #require(script.range(of: "// dashbar-core-end"))
            ctx.exceptionHandler = { [weak self] _, e in self?.exception = e?.toString() }
            ctx.evaluateScript(String(script[start.lowerBound..<end.upperBound]))
            ctx.evaluateScript("""
            var writes = [];
            var handle = dashbarCore(function (id, text) { writes.push({ id: id, text: text }) }, function () { return 1800000000000 });
            """)
        }

        func send(_ event: String, fallback: String = "'/Users/x/app'") { ctx.evaluateScript("handle(\(event), \(fallback))") }
        var count: Int { Int(ctx.evaluateScript("writes.length").toInt32()) }
        var all: [(id: String, text: String)] {
            (0..<count).map { i in
                (ctx.evaluateScript("writes[\(i)].id").toString(), ctx.evaluateScript("writes[\(i)].text").toString())
            }
        }
        func last() -> [String: Any] {
            let text = ctx.evaluateScript("writes[writes.length - 1].text").toString() ?? ""
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        }
    }

    @Test func v1EventsBecomeStatesAndNothingPrivateIsWritten() throws {
        let h = try Harness()
        h.send(#"{type: "session.status", properties: {sessionID: "ses_1", status: {type: "busy"}}}"#)
        #expect(h.last()["state"] as? String == "working")
        h.send(#"{type: "permission.asked", properties: {id: "per_1", sessionID: "ses_1", permission: "bash", patterns: ["rm -rf /SECRET-PATTERN"], metadata: {command: "cat SECRET-COMMAND"}, always: ["SECRET-ALWAYS"], tool: {messageID: "msg", callID: "call"}}}"#)
        #expect(h.last()["state"] as? String == "needsYou")
        h.send(#"{type: "session.status", properties: {sessionID: "ses_1", status: {type: "busy"}}}"#)
        #expect(h.last()["state"] as? String == "needsYou")   // still asking
        h.send(#"{type: "permission.replied", properties: {sessionID: "ses_1", requestID: "per_1", reply: "once"}}"#)
        #expect(h.last()["state"] as? String == "working")
        h.send(#"{type: "question.asked", properties: {id: "que_1", sessionID: "ses_1", questions: [{question: "SECRET QUESTION?", header: "SECRET", options: [{label: "SECRET-OPTION", description: "x"}]}]}}"#)
        #expect(h.last()["state"] as? String == "needsYou")
        h.send(#"{type: "question.replied", properties: {sessionID: "ses_1", requestID: "que_1", answers: [["SECRET-ANSWER"]]}}"#)
        #expect(h.last()["state"] as? String == "working")
        h.send(#"{type: "session.status", properties: {sessionID: "ses_1", status: {type: "retry", attempt: 1, message: "SECRET-ERROR", next: 5}}}"#)
        #expect(h.last()["state"] as? String == "working")
        h.send(#"{type: "session.idle", properties: {sessionID: "ses_1"}}"#)
        #expect(h.last()["state"] as? String == "idle")
        // Events that carry prompts and replies are not listened to.
        let before = h.count
        h.send(#"{type: "message.updated", properties: {info: {sessionID: "ses_1", role: "user"}, text: "SECRET PROMPT"}}"#)
        h.send(#"{type: "message.part.updated", properties: {part: {sessionID: "ses_1", text: "SECRET REPLY"}}}"#)
        h.send(#"{type: "session.updated", properties: {info: {id: "ses_1", title: "SECRET TITLE"}, sessionID: "ses_1"}}"#)
        #expect(h.count == before)
        check(h)
        #expect(h.last()["directory"] as? String == "/Users/x/app")
    }

    @Test func v2EventsUseTheirLocationAndCarryOnlyTheSessionId() throws {
        let h = try Harness()
        h.send(#"{id: "evt_1", type: "permission.asked", created: 1, location: {directory: "/Users/x/two"}, data: {id: "per_9", sessionID: "ses_2", action: "edit", resources: ["/SECRET/file.swift"], message: "SECRET MESSAGE", metadata: {diff: "SECRET DIFF"}, source: {type: "tool", messageID: "m", id: "t"}}}"#,
               fallback: "undefined")
        #expect(h.last()["state"] as? String == "needsYou")
        #expect(h.last()["directory"] as? String == "/Users/x/two")
        #expect(h.last()["session_id"] as? String == "ses_2")
        h.send(#"{id: "evt_2", type: "permission.replied", created: 2, data: {sessionID: "ses_2", requestID: "per_9", reply: "reject"}}"#)
        #expect(h.last()["state"] as? String == "working")
        h.send(#"{id: "evt_3", type: "session.status", created: 3, data: {sessionID: "ses_2", status: {type: "idle"}}}"#)
        #expect(h.last()["state"] as? String == "idle")
        check(h)
    }

    @Test func oddEventsNeverThrowAndIdsCantEscapeTheFolder() throws {
        let h = try Harness()
        for odd in ["null", "undefined", "{}", "{type: 5}", #"{type: "session.status"}"#, #"{type: "session.status", properties: null}"#,
                    #"{type: "permission.asked", properties: {sessionID: 42}}"#,
                    #"{get type() { throw new Error("boom") }}"#, #"{type: "session.status", properties: {get sessionID() { throw 1 }}}"#] {
            h.send(odd)
        }
        #expect(h.exception == nil)
        #expect(h.count == 0)
        h.send(#"{type: "session.idle", properties: {sessionID: "../../etc/passwd"}}"#, fallback: "'relative/path'")
        #expect(h.all.last?.id == "etcpasswd")
        #expect(h.last()["directory"] as? String == "")
    }

    /// Every write holds exactly the four fields (and the format version), and none of the private text.
    func check(_ h: Harness) {
        #expect(h.exception == nil)
        for w in h.all {
            let o = (try? JSONSerialization.jsonObject(with: Data(w.text.utf8)) as? [String: Any]) ?? [:]
            #expect(Set(o.keys) == ["version", "session_id", "directory", "state", "written_at"])
            #expect(!w.text.contains("SECRET"), "wrote \(w.text)")
            #expect(OpenCodeBridge.parseState(Data(w.text.utf8)) != nil)
        }
    }
}

// MARK: - Where opencode shows

@Suite struct OpenCodePlacementTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func digest(_ s: UsageRules.Service, _ limits: [RateLimit] = [], tokens: Int = 0, notice: Bool = false) -> UsageRules.Digest {
        UsageRules.Digest(service: s, limits: limits, tokens: tokens, cost: 0, hasNotice: notice)
    }

    @Test func opencodeHasNoLimitsSoItFollowsToolsWithThemThenRanksByTokens() {
        let weekly = RateLimit(label: "Weekly", usedPercent: 10, resetsAt: now.addingTimeInterval(3 * 86400), window: 7 * 86400)
        let order = { (d: [UsageRules.Digest]) in UsageRules.order(d, now: self.now).map(\.service) }
        #expect(order([digest(.opencode, tokens: 900_000_000), digest(.claude, [weekly], tokens: 5)]) == [.claude, .opencode])
        #expect(order([digest(.google, tokens: 10), digest(.opencode, tokens: 20)]) == [.opencode, .google])
        #expect(order([digest(.opencode, tokens: 10), digest(.google, tokens: 10)]) == [.google, .opencode])
        // Nothing in the period: it folds, and goes last.
        #expect(UsageRules.isIdle(digest(.opencode)))
        #expect(!UsageRules.isIdle(digest(.opencode, notice: true)))   // a format warning never folds
        #expect(order([digest(.opencode), digest(.codex, tokens: 1)]) == [.codex, .opencode])
    }

    @Test func aWaitingOpencodeSessionTakesTheNowCard() {
        var s = LiveSession(id: "opencode-a", pid: 1, name: "app", cwd: "/p/app", status: "waiting", since: now, entrypoint: "cli", root: "/p/app")
        s.agent = .opencode
        let busy = LiveSession(id: "c", pid: 2, name: "Claude work", cwd: "/p/site", status: "busy", since: now, entrypoint: "cli", root: "/p/site")
        let ws = Workspace.build(sessions: [busy, s], servers: [])
        #expect(OverviewRules.nowWorkspace(ws, now: now)?.root == "/p/app")
    }

    @MainActor @Test func theUsageCardShowsOnlyForOpencodeUsersAndHasNoLimits() {
        let store = Store(demo: true)
        store.opencode = .empty
        #expect(!store.usageServices(settings: AppSettings.shared, antigravityInstalled: false).contains { $0.service == .opencode })
        store.opencode = UsageSummary(found: true)
        let card = store.usageServices(settings: AppSettings.shared, antigravityInstalled: false).first { $0.service == .opencode }
        #expect(card?.title == "opencode" && card?.limits.isEmpty == true && card?.hasNotice == false)
        store.opencode.warning = OpenCode.formatWarning
        #expect(store.formatWarning != nil)
        #expect(store.usageServices(settings: AppSettings.shared, antigravityInstalled: false).first { $0.service == .opencode }?.hasNotice == true)
    }

    @MainActor @Test func theStatusFileNamesOpencodeWithoutIdsOrTitles() throws {
        let store = Store(demo: true)
        var s = LiveSession(id: "opencode-ses_SECRETID", pid: 1, name: "recipe-box", cwd: "/p/recipe-box", status: "busy",
                            since: Date(), entrypoint: "cli", root: "/p/recipe-box")
        s.agent = .opencode
        store.sessions.append(s)
        var usage = UsageSummary(found: true)
        usage.today = TokenTotals(input: 12, output: 3)
        store.opencode = usage
        let data = try StatusSnapshot.encoder().encode(CLIStatus.snapshot(of: store, showsClaudeLimits: true))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SECRETID"))
        #expect(text.contains("\"opencode\""))
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(CLIStatusSnapshotTests.keys(obj).subtracting(CLIStatusSnapshotTests.allowedKeys).isEmpty)
        #expect(CLIStatus.toolID(.opencode) == "opencode")
        #expect(StatusFormat.toolName("opencode") == "opencode")
    }
}
