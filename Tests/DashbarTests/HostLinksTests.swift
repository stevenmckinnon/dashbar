import Foundation
import Testing
import SQLite3
@testable import Dashbar

// Throwaway folders only: never the real ~/.t3 or ~/Library/Application Support/Claude.

@Suite struct HostLinksTests {
    let session = "15940bad-0c1d-4e2f-9a3b-5c6d7e8f9a0b"

    func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hostlinks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func onlySessionIDsAreLookedFor() {
        #expect(HostLinks.isSessionID(session))
        #expect(!HostLinks.isSessionID("x' OR 1=1 --"))
        #expect(!HostLinks.isSessionID("local_abc"))
        #expect(!HostLinks.isSessionID("short"))
        #expect(HostLinks.url(bundleID: HostLinks.t3BundleID, session: "../../etc", home: "/nonexistent") == nil)
    }

    @Test func linksAreBuiltSafely() {
        #expect(HostLinks.t3URL(environment: "36ebbf00-1111-2222-3333-444455556666", thread: "import:claude:abc")?.absoluteString
                == "t3code://threads/36ebbf00-1111-2222-3333-444455556666/import%3Aclaude%3Aabc")
        #expect(HostLinks.t3URL(environment: "a/b", thread: "t") == nil)
        #expect(HostLinks.t3URL(environment: "env", thread: "") == nil)
        #expect(HostLinks.desktopURL(localID: "local_ca3668-12ab")?.absoluteString == "claude://code/continue?session=local_ca3668-12ab")
        #expect(HostLinks.desktopURL(localID: "local_x&session=other") == nil)
        #expect(HostLinks.desktopURL(localID: "cse_123") == nil)
    }

    @Test func theT3QuerySelectsOnlyTheThreadID() {
        #expect(HostLinks.t3Query.hasPrefix("SELECT thread_id FROM provider_session_runtime WHERE"))
        for column in ["title", "text", "payload", "runtime_payload_json"] { #expect(!HostLinks.t3Query.contains(column)) }
    }

    func makeT3(_ home: URL, env: String = "36ebbf00-1111-2222-3333-444455556666", rows: [String]) throws {
        let data = home.appendingPathComponent(".t3/userdata")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try (env + "\n").write(to: data.appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        var db: OpaquePointer?
        #expect(sqlite3_open(data.appendingPathComponent("statev2.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
            CREATE TABLE provider_session_runtime (thread_id TEXT PRIMARY KEY, provider_name TEXT, adapter_key TEXT,
              runtime_mode TEXT, status TEXT, last_seen_at TEXT, resume_cursor_json TEXT, runtime_payload_json TEXT,
              provider_instance_id TEXT); PRAGMA journal_mode=WAL;
            """, nil, nil, nil) == SQLITE_OK)
        for row in rows { #expect(sqlite3_exec(db, row, nil, nil, nil) == SQLITE_OK) }
    }

    @Test func t3OpensTheNewestClaudeThreadForTheSession() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func row(_ thread: String, _ provider: String, _ seen: String, _ resume: String) -> String {
            "INSERT INTO provider_session_runtime VALUES ('\(thread)', '\(provider)', '', '', '', '\(seen)', '{\"threadId\":\"x\",\"resume\":\"\(resume)\"}', '{\"prompt\":\"private text\"}', '')"
        }
        try makeT3(home, rows: [
            row("import:claude:old", "claudeAgent", "2026-11-01T00:00:00Z", session),
            row("import:claude:new", "claudeAgent", "2026-11-03T00:00:00Z", session),
            row("codex-thread", "codex", "2026-11-04T00:00:00Z", session),
            row("someone-else", "claudeAgent", "2026-11-05T00:00:00Z", "00000000-0000-0000-0000-000000000000"),
        ])
        #expect(HostLinks.url(bundleID: HostLinks.t3BundleID, session: session, home: home.path)?.absoluteString
                == "t3code://threads/36ebbf00-1111-2222-3333-444455556666/import%3Aclaude%3Anew")
        #expect(HostLinks.url(bundleID: HostLinks.t3BundleID, session: "aaaaaaaa-0000-0000-0000-000000000000", home: home.path) == nil)
    }

    @Test func t3WithoutItsFilesOrAnUnknownSchemaGivesNoLink() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HostLinks.url(bundleID: HostLinks.t3BundleID, session: session, home: home.path) == nil)
        let data = home.appendingPathComponent(".t3/userdata")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try "env".write(to: data.appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        var db: OpaquePointer?
        sqlite3_open(data.appendingPathComponent("statev2.sqlite").path, &db)
        sqlite3_exec(db, "CREATE TABLE threads (id TEXT)", nil, nil, nil)
        sqlite3_close(db)
        #expect(HostLinks.url(bundleID: HostLinks.t3BundleID, session: session, home: home.path) == nil)
    }

    @Test func desktopFindsTheSessionFileByItsClaudeCodeID() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/acct/org")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ body: String, age: TimeInterval) throws {
            let url = folder.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("local_other1.json", "{\"sessionId\":\"local_other1\",\"cliSessionId\":\"aaaaaaaa-0000-0000-0000-000000000000\",\"promptSuggestion\":\"private\"}", age: 0)
        try write("local_mine22.json", "{\"sessionId\":\"local_mine22\",\"cliSessionId\":\"\(session)\",\"promptSuggestion\":\"private\"}", age: 60)
        try write("notes.json", "{\"cliSessionId\":\"\(session)\"}", age: 0)   // not a session file
        #expect(HostLinks.url(bundleID: HostLinks.desktopBundleID, session: session, home: home.path)?.absoluteString
                == "claude://code/continue?session=local_mine22")
        // pretty-printed JSON too
        try write("local_mine22.json", "{\n  \"cliSessionId\": \"\(session)\"\n}", age: 60)
        #expect(HostLinks.desktopLocalID(sessions: folder.deletingLastPathComponent().deletingLastPathComponent().path, session: session) == "local_mine22")
        #expect(HostLinks.url(bundleID: HostLinks.desktopBundleID, session: "bbbbbbbb-0000-0000-0000-000000000000", home: home.path) == nil)
        // a Desktop session whose Claude Code id has changed since it began
        try write("local_later3.json", "{\"cliSessionId\":\"cccccccc-0000-0000-0000-000000000000\",\"lastAssistantCliSessionId\":\"dddddddd-0000-0000-0000-000000000000\"}", age: 0)
        #expect(HostLinks.url(bundleID: HostLinks.desktopBundleID, session: "dddddddd-0000-0000-0000-000000000000", home: home.path)?.absoluteString
                == "claude://code/continue?session=local_later3")
    }

    @Test func otherAppsGetNoLink() {
        #expect(!HostLinks.handles(bundleID: "com.mitchellh.ghostty"))
        #expect(HostLinks.url(bundleID: "com.mitchellh.ghostty", session: session, home: "/nonexistent") == nil)
    }
}
