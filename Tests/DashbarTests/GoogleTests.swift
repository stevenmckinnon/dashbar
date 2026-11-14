import Foundation
import Testing
import SQLite3
@testable import Dashbar

// All of these work on throwaway folders. Nothing here reads or writes the real ~/.gemini.

// MARK: - The Antigravity CLI status line bridge, end to end

@Suite struct AntigravityBridgeScriptTests {
    struct Run { let output: String; let status: Int32 }

    func run(_ fx: Fixture, stdin: String, previous: String? = nil) throws -> Run {
        let script = fx.root.appendingPathComponent("agy-bridge.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            try AntigravityBridge.script.write(to: script, atomically: true, encoding: .utf8)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + (previous.map { [$0] } ?? [])
        p.environment = ["HOME": fx.root.path, "PATH": "/usr/bin:/bin",
                         "DASHBAR_STATUSLINE_DIR": fx.root.appendingPathComponent("caches").path]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(output: String(decoding: data, as: UTF8.self), status: p.terminationStatus)
    }

    /// Shaped like the documented payload, with the private fields that must never be saved.
    func sample(state: String = "working", pending: Bool = false, quota: Bool = true) -> String {
        """
        {"cwd":"/Users/x/dev/my \\"app\\"","session_id":"12345678-abcd","conversation_id":"12345678-abcd",
         "conversation_title":"SECRET TITLE","transcript_path":"/Users/x/.gemini/antigravity/brain/t.jsonl",
         "model":{"id":"Gemini 4 Argon (Medium)","display_name":"Gemini 4 Argon (Medium)","effort":"medium"},
         "workspace":{"current_dir":"/Users/x/dev/app/src","project_dir":"/Users/x/dev/app"},
         "context_window":{"total_input_tokens":88244,"total_output_tokens":61074,"context_window_size":1048576},
         \(quota ? #""quota":{"gemini-weekly":{"remaining_fraction":0.9378,"reset_time":"2099-07-06T07:50:32Z","reset_in_seconds":560580}},"# : "")
         "agent_state":"\(state)","plan_tier":"Pro","email":"someone@example.com",
         \(pending ? #""tool_confirmation_pending":true,"# : "")
         "cost":{"total_usd":0.4213,"subagent_usd":0,"estimated":false}}
        """
    }

    @Test func savesOnlyTheAllowedFieldsAndNothingPrivate() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let r = try run(fx, stdin: sample(pending: true))
        #expect(r.status == 0 && r.output.isEmpty)
        let caches = fx.root.appendingPathComponent("caches")
        let quotaText = try String(contentsOf: caches.appendingPathComponent("antigravity-statusline.json"), encoding: .utf8)
        let sessionURL = caches.appendingPathComponent("antigravity-sessions/12345678-abcd.json")
        let sessionText = try String(contentsOf: sessionURL, encoding: .utf8)
        for text in [quotaText, sessionText] {
            #expect(!text.contains("someone@example.com"))
            #expect(!text.contains("SECRET TITLE"))
            #expect(!text.contains("transcript"))
            #expect(!text.contains("brain"))
        }
        let limits = try #require(AntigravityStatusLine.parseLimits(Data(quotaText.utf8)))
        #expect(limits.planTier == "Pro")
        #expect(limits.groups.map(\.name) == ["Gemini"])
        let weekly = try #require(limits.groups.first?.limits.first)
        #expect(weekly.label == "Weekly" && abs(weekly.usedPercent - 6.22) < 0.01 && weekly.window == 7 * 86400)

        let s = try #require(AntigravityStatusLine.parseSession(Data(sessionText.utf8)))
        #expect(s.id == "12345678-abcd")
        #expect(s.cwd == #"/Users/x/dev/my "app""#)   // escaped, then read back exactly
        #expect(s.folder == "/Users/x/dev/app")
        #expect(s.model == "Gemini 4 Argon (Medium)")
        #expect(s.inputTokens == 88244 && s.outputTokens == 61074)
        #expect(s.costUSD == 0.4213 && s.costEstimated == false)
        #expect(s.state == "working" && s.confirmationPending)
    }

    @Test func runsThePreviousStatusLineWithTheSameInputAndKeepsItsOutputAndStatus() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let input = sample()
        #expect(try run(fx, stdin: input, previous: "cat").output == input + "\n")
        let failing = try run(fx, stdin: input, previous: "echo nope; exit 3")
        #expect(failing.output == "nope\n" && failing.status == 3)
        // Never runs itself again, even if it was given as the previous command.
        #expect(try run(fx, stdin: input, previous: "/bin/sh antigravity-statusline-bridge.sh").output.isEmpty)
    }

    @Test func noQuotaOrNoConversationSavesWhatThereIs() throws {
        let fx = try Fixture(); defer { fx.remove() }
        _ = try run(fx, stdin: sample(quota: false))
        let caches = fx.root.appendingPathComponent("caches")
        #expect(!FileManager.default.fileExists(atPath: caches.appendingPathComponent("antigravity-statusline.json").path))
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("antigravity-sessions/12345678-abcd.json").path))
        _ = try run(fx, stdin: #"{"session_id":"","quota":{"gemini-5h":{"remaining_fraction":0.5}}}"#)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("antigravity-statusline.json").path))
        // Not JSON at all: nothing breaks, nothing new is written.
        #expect(try run(fx, stdin: "not json", previous: "echo still here").output == "still here\n")
    }
}

// MARK: - Installing into the Antigravity CLI's settings

@Suite struct AntigravityInstallerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func paths(_ fx: Fixture) throws -> AntigravityBridge.Paths {
        AntigravityBridge.Paths(settings: try fx.dir("agy").appendingPathComponent("settings.json"),
                                support: fx.root.appendingPathComponent("support"), readings: try fx.dir("caches"))
    }

    @Test func roundTripPutsTheOriginalBackByteForByte() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let original = """
        {
            "theme": "dark",
            "statusLine": {
                "type": "command",
                "command": "~/.gemini/antigravity-cli/statusline.sh",
                "stack_with_default": true
            }
        }

        """
        try original.write(to: p.settings, atomically: true, encoding: .utf8)
        #expect(AntigravityBridge.status(p) == .notInstalled(current: "~/.gemini/antigravity-cli/statusline.sh"))
        try AntigravityBridge.install(p, now: now)
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: p.settings)) as? [String: Any])
        let line = try #require(after["statusLine"] as? [String: Any])
        #expect(line["stack_with_default"] as? Bool == true)
        #expect(AntigravityBridge.previousCommand(inBridgeCommand: line["command"] as? String ?? "") == "~/.gemini/antigravity-cli/statusline.sh")
        #expect(AntigravityBridge.status(p) == .installed(previous: "~/.gemini/antigravity-cli/statusline.sh"))
        #expect(FileManager.default.isExecutableFile(atPath: p.script.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: p.support.appendingPathComponent("Backups").path)
        #expect(backups.contains { $0.hasPrefix("antigravity-settings-") })

        try AntigravityBridge.install(p, now: now)   // a second Add changes nothing
        try AntigravityBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: p.script.path))
    }

    @Test func noFolderMeansAbsentAndInvalidJSONIsRefused() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let missing = AntigravityBridge.Paths(settings: fx.root.appendingPathComponent("nope/settings.json"), support: fx.root)
        #expect(AntigravityBridge.status(missing) == .absent)
        #expect(throws: AntigravityBridge.Failure.self) { try AntigravityBridge.install(missing) }

        let p = try paths(fx)
        #expect(AntigravityBridge.status(p) == .notInstalled(current: nil))
        try "{ broken".write(to: p.settings, atomically: true, encoding: .utf8)
        #expect(throws: AntigravityBridge.Failure.invalidSettings) { try AntigravityBridge.install(p, now: now) }
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == "{ broken")
    }

    @Test func noSettingsFileCreatesOneAndRemoveLeavesNoStatusLine() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        try AntigravityBridge.install(p, now: now)
        #expect(AntigravityBridge.status(p) == .installed(previous: nil))
        try AntigravityBridge.uninstall(p, now: now)
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: p.settings)) as? [String: Any])
        #expect(after["statusLine"] == nil)
    }
}

// MARK: - Reading the status line

@Suite struct AntigravityStatusLineTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func bucketIDsSplitIntoGroupAndWindow() {
        #expect(AntigravityStatusLine.bucket("gemini-weekly") == .init(group: "gemini", groupName: "Gemini", label: "Weekly", window: 7 * 86400))
        #expect(AntigravityStatusLine.bucket("claude-and-gpt-5h") == .init(group: "claude-and-gpt", groupName: "Claude and GPT", label: "5-hour", window: 5 * 3600))
        #expect(AntigravityStatusLine.bucket("five_hour") == .init(group: "all", groupName: "All models", label: "5-hour", window: 5 * 3600))
        #expect(AntigravityStatusLine.bucket("gemini-pro-burst").window == nil)
        #expect(AntigravityStatusLine.bucket("gemini-pro-burst").label == "Gemini pro burst")
    }

    @Test func absentDisabledAndAmountBucketsAreLeftOutWithoutAWarning() throws {
        let json = """
        {"version":1,"written_at":\(now.timeIntervalSince1970),"plan_tier":null,"quota":{
          "gemini-5h":{"remaining_fraction":0.25,"reset_in_seconds":3600},
          "gemini-weekly":{"remaining_fraction":0.5,"reset_time":"2027-01-20T08:00:00Z"},
          "claude-and-gpt-weekly":{"disabled":true},
          "credits":{"remaining_amount":12},
          "old-5h":{"remaining_fraction":0.1,"reset_in_seconds":-10}}}
        """
        let r = try #require(AntigravityStatusLine.parseLimits(Data(json.utf8), now: now))
        #expect(r.problem == nil && r.planTier == nil)
        #expect(r.groups.map(\.key) == ["gemini"])
        #expect(r.groups[0].limits.map(\.label) == ["5-hour", "Weekly"])
        #expect(r.groups[0].limits[0].usedPercent == 75)
        #expect(r.groups[0].limits[0].resetsAt == now.addingTimeInterval(3600))
        #expect(r.flattened.map(\.label) == ["5-hour", "Weekly"])   // one group: no group names
    }

    @Test func unknownShapesWarnRatherThanShowNothing() throws {
        #expect(AntigravityStatusLine.parseLimits(Data(#"{"quota":{"x":{"left":1}}}"#.utf8))?.problem != nil)
        #expect(AntigravityStatusLine.parseLimits(Data(#"{"version":1}"#.utf8))?.problem != nil)
        #expect(AntigravityStatusLine.parseLimits(Data("nope".utf8))?.problem != nil)
        #expect(AntigravityStatusLine.parseLimits(Data())  == nil)
        #expect(AntigravityStatusLine.parseLimits(Data(#"{"quota":{}}"#.utf8))?.problem == nil)
    }

    func session(_ id: String, folder: String, state: String, pending: Bool = false, at: Date) -> AntigravityStatusLine.Session {
        .init(id: id, writtenAt: at, cwd: folder, projectDir: folder, model: nil, inputTokens: 0, outputTokens: 0, costUSD: nil,
              costEstimated: true, state: state, confirmationPending: pending)
    }

    @Test func liveSessionsPairWithProcessesAndSayWhenTheyNeedYou() {
        let sessions = [
            session("a", folder: "/p/one", state: "idle", pending: true, at: now.addingTimeInterval(-10)),
            session("b", folder: "/p/one", state: "working", at: now.addingTimeInterval(-3000)),   // older, same folder
            session("c", folder: "/p/two", state: "working", at: now.addingTimeInterval(-30)),     // no process, but working now
            session("d", folder: "/p/three", state: "idle", at: now.addingTimeInterval(-30)),      // no process, idle: gone
        ]
        let live = AntigravityStatusLine.live(sessions, processes: [(pid: 42, root: "/p/one")], now: now, root: { $0 })
        #expect(live.map(\.id) == ["agy-a", "agy-c"])
        #expect(live[0].isWaiting && live[0].waitingSentence == "Antigravity CLI needs permission" && live[0].pid == 42)
        #expect(live[1].isBusy && live[1].pid == 0 && live[1].agent == .antigravityCLI)
    }

    @Test func usageAddsEachSessionsGrowthWithTheCLIsCost() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = try fx.dir("sessions")
        func write(_ input: Int, _ output: Int, _ cost: Double) throws {
            let o: [String: Any] = ["version": 1, "written_at": Date().timeIntervalSince1970, "session_id": "s1", "cwd": "/p/app",
                                    "model": "Gemini 4 Argon (Medium)", "input_tokens": input, "output_tokens": output,
                                    "cost_usd": cost, "agent_state": "idle"]
            try JSONSerialization.data(withJSONObject: o).write(to: dir.appendingPathComponent("s1.json"))
        }
        let tracker = AntigravityUsageTracker(dir: dir, cache: fx.root.appendingPathComponent("agy-usage.json"))
        try write(1000, 200, 0.10)
        tracker.scan()
        try write(1500, 260, 0.16)
        tracker.scan()
        tracker.scan()   // unchanged: adds nothing
        let today = tracker.book.summary(found: true).period(.today)
        #expect(today.totals.input == 1500 && today.totals.output == 260)
        #expect(abs(today.cost - 0.16) < 1e-9)
        #expect(today.models.first?.name == "Gemini 4 Argon (Medium)")
        tracker.save()
        let reloaded = AntigravityUsageTracker(dir: dir, cache: fx.root.appendingPathComponent("agy-usage.json"))
        reloaded.scan()
        #expect(reloaded.book.summary(found: true).period(.today).totals.input == 1500)   // progress kept: not counted twice
    }
}

// MARK: - Gemini CLI

@Suite struct GeminiCLITests {
    func gemini(_ id: String, model: String = "gemini-3.8-flash", tokens: [String: Int]?) -> [String: Any] {
        var o: [String: Any] = ["id": id, "timestamp": Fixture.now, "type": "gemini", "content": "hello"]
        if let tokens { o["tokens"] = tokens; o["model"] = model }
        return o
    }

    @Test func rewrittenMessagesCountOnceAndTokensMapToTheLedger() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let root = try fx.dir("tmp")
        try "/Users/x/dev/site\n".write(to: try fx.dir("tmp/site").appendingPathComponent(".project_root"), atomically: true, encoding: .utf8)
        let file = try fx.write("tmp/site/chats/session-2026-11-14T11-46-abcd.jsonl", lines: [
            ["sessionId": "abcd", "projectHash": "h", "startTime": Fixture.now, "lastUpdated": Fixture.now, "kind": "main"],
            ["id": "u1", "timestamp": Fixture.now, "type": "user", "content": [["text": "hi"]]],
            gemini("m1", tokens: nil),   // written before its counts arrive
            ["$set": ["lastUpdated": Fixture.now]],
            gemini("m1", tokens: ["input": 1000, "output": 50, "cached": 400, "thoughts": 30, "tool": 20, "total": 1100]),
        ])
        let scanner = GeminiUsageScanner(root: root)
        var s = scanner.scan()
        #expect(s.found && s.warning == nil)
        var t = s.period(.today).totals
        #expect(t.input == 620 && t.cacheRead == 400 && t.output == 80 && t.messages == 1)
        #expect(s.period(.today).projects.first?.name == "site")
        #expect(s.period(.today).models.first?.name == "gemini-3.8-flash")
        // 620 × $0.75 + 80 × $3.75 + 400 × $0.075 per million
        #expect(abs(s.period(.today).cost - (620 * 0.75 + 80 * 3.75 + 400 * 0.075) / 1_000_000) < 1e-12)

        // The same message written again with the same counts, and again with more: only the growth is added.
        try fx.append(file, lines: [gemini("m1", tokens: ["input": 1000, "output": 50, "cached": 400, "thoughts": 30, "tool": 20]),
                                    gemini("m1", tokens: ["input": 1000, "output": 90, "cached": 400, "thoughts": 30, "tool": 20])])
        s = scanner.scan()
        t = s.period(.today).totals
        #expect(t.output == 120 && t.input == 620 && t.messages == 1)
    }

    @Test func repliesWhoseCountsNeverComeWarn() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let root = try fx.dir("tmp")
        try fx.write("tmp/p/chats/session-a.jsonl", lines: (0..<25).map { gemini("m\($0)", tokens: nil) })
        let scanner = GeminiUsageScanner(root: root)
        #expect(scanner.scan().warning == nil)   // still waiting for their counts
        let later = scanner.scan(now: Date().addingTimeInterval(GeminiUsageScanner.tokenGrace + 60))
        #expect(later.warning?.contains("Gemini CLI") == true)
    }

    @Test func noGeminiFolderIsNotFound() {
        #expect(GeminiUsageScanner(root: URL(fileURLWithPath: "/nonexistent/gemini/tmp")).scan().found == false)
    }

    @Test func processesAreRecognisedByTheirArguments() {
        #expect(GeminiCLI.isGemini(name: "node", commandLine: "node /Users/x/.nvm/versions/node/v26.7.0/bin/gemini"))
        #expect(GeminiCLI.isGemini(name: "node", commandLine: "node /usr/local/lib/node_modules/@google/gemini-cli/dist/index.js --yolo"))
        #expect(GeminiCLI.isGemini(name: "gemini", commandLine: nil))
        #expect(!GeminiCLI.isGemini(name: "node", commandLine: "node /Users/x/dev/gemini-notes/server.js"))
        #expect(!GeminiCLI.isGemini(name: "node", commandLine: "node next dev"))
        #expect(!GeminiCLI.isGemini(name: "python3", commandLine: "python3 gemini"))
    }

    @Test func liveSessionsAreWorkingWhileTheLogIsBeingWritten() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var since: [Int32: Date] = [:]
        let procs: [(pid: Int32, cwd: String, started: Date?)] = [(7, "/p/site", now.addingTimeInterval(-600)), (8, "/p/other", nil)]
        let activity: (String) -> Date? = { $0 == "/p/site" ? now.addingTimeInterval(-5) : now.addingTimeInterval(-900) }
        let live = GeminiCLI.live(processes: procs, activity: activity, busySince: &since, now: now, root: { $0 })
        #expect(live.map(\.status) == ["busy", "idle"])
        #expect(live[0].agent == .geminiCLI && live[0].name == "site")
        #expect(live[1].since == now.addingTimeInterval(-900))
        // Still busy a moment later: it keeps the time it started working.
        let again = GeminiCLI.live(processes: procs, activity: { _ in now.addingTimeInterval(4) }, busySince: &since,
                                   now: now.addingTimeInterval(9), root: { $0 })
        #expect(again[0].since == now.addingTimeInterval(-5))
    }
}

// MARK: - The Antigravity app's conversations

@Suite struct AntigravityAppTests {
    /// A database shaped like the app's, with the content columns it really has, filled with stand-ins.
    func makeDB(_ url: URL, columns: String? = nil, rows: [String]) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = columns ?? """
        conversation_id text, title text NOT NULL DEFAULT "", preview text NOT NULL DEFAULT "", step_count integer NOT NULL DEFAULT 0,
        last_modified_time datetime NOT NULL, workspace_uris text NOT NULL, status text NOT NULL DEFAULT "",
        parent_conversation_id text NOT NULL DEFAULT "", not_fully_idle numeric NOT NULL DEFAULT false,
        killed numeric NOT NULL DEFAULT false, PRIMARY KEY (conversation_id)
        """
        #expect(sqlite3_exec(db, "CREATE TABLE conversation_summaries (\(schema)); PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        for row in rows { #expect(sqlite3_exec(db, row, nil, nil, nil) == SQLITE_OK) }
    }

    static let f: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS'+00:00'"
        return f
    }()

    func insert(_ id: String, status: String, ago: TimeInterval, folder: String = "/p/app", parent: String = "", killed: Int = 0,
                notIdle: Int = 0, now: Date) -> String {
        """
        INSERT INTO conversation_summaries (conversation_id, title, preview, last_modified_time, workspace_uris, status,
          parent_conversation_id, killed, not_fully_idle)
        VALUES ('\(id)', 'private title', 'private preview', '\(Self.f.string(from: now.addingTimeInterval(-ago)))',
          '["file://\(folder)"]', '\(status)', '\(parent)', \(killed), \(notIdle));
        """
    }

    @Test func readsStatusOnlyAndListsLiveTopLevelConversations() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("conversation_summaries.db")
        let now = Date()
        try makeDB(url, rows: [
            insert("busy", status: "CASCADE_RUN_STATUS_RUNNING", ago: 120, now: now),
            insert("idle", status: "CASCADE_RUN_STATUS_IDLE", ago: 600, folder: "/p/other", now: now),
            insert("stale", status: "CASCADE_RUN_STATUS_IDLE", ago: 7200, now: now),
            insert("child", status: "CASCADE_RUN_STATUS_RUNNING", ago: 60, parent: "busy", now: now),
            insert("dead", status: "CASCADE_RUN_STATUS_RUNNING", ago: 60, killed: 1, now: now),
            insert("asks", status: "CASCADE_RUN_STATUS_WAITING_FOR_USER", ago: 30, now: now),
        ])
        guard case .rows(let rows) = AntigravityApp.query(url) else { Issue.record("no rows"); return }
        #expect(rows.count == 6)
        #expect(rows.first { $0.id == "busy" }?.workspaces == ["/p/app"])
        let live = AntigravityApp.live(rows, now: now, root: { $0 })
        #expect(Set(live.map(\.id)) == ["antigravity-busy", "antigravity-idle", "antigravity-asks"])
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        #expect(byID["antigravity-busy"]?.isBusy == true)
        #expect(byID["antigravity-idle"]?.status == "idle")
        #expect(byID["antigravity-asks"]?.waitingSentence == "Antigravity needs input")
        #expect(live.allSatisfy { $0.agent == .antigravity && $0.pid == 0 && $0.name != "private title" })

        let app = AntigravityApp(url: url)
        #expect(app.read(now: now).sessions.count == 3)
        #expect(app.read(now: now).warning == nil)
    }

    @Test func aChangedSchemaWarnsAndAMissingFileIsQuiet() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("changed.db")
        try makeDB(url, columns: "id text, state text", rows: ["INSERT INTO conversation_summaries VALUES ('a', 'x');"])
        #expect(AntigravityApp.query(url) == .schemaChanged)
        #expect(AntigravityApp(url: url).read().warning == AntigravityApp.formatWarning)
        #expect(AntigravityApp.query(fx.root.appendingPathComponent("missing.db")) == .unavailable)
        #expect(AntigravityApp(url: fx.root.appendingPathComponent("missing.db")).read() == .init())
    }

    @Test func timesAndFoldersParse() {
        #expect(AntigravityApp.parseTime("2025-11-19 19:46:55.197001+00:00") == Date(timeIntervalSince1970: 1763581615.197))
        #expect(AntigravityApp.parseTime("2025-11-19 19:46:55") == Date(timeIntervalSince1970: 1763581615))
        #expect(AntigravityApp.parseWorkspaces(#"["file:///Users/x/my%20app"]"#) == ["/Users/x/my app"])
        #expect(AntigravityApp.parseWorkspaces("") == [])
        #expect(AntigravityApp.parseWorkspaces("[broken") == nil)
        #expect(AntigravityApp.state("CASCADE_RUN_STATUS_IDLE") == .idle)
        #expect(AntigravityApp.state("CASCADE_RUN_STATUS_RUNNING") == .busy)
    }
}

// MARK: - Prices and plan history

@Suite struct GooglePricingTests {
    @Test func geminiModelsHavePricesAndLongPromptsPayMore() throws {
        let t = TokenTotals(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
        #expect(Pricing.cost(t, model: "gemini-3.8-flash") == 0.75 + 3.75 + 0.075)
        #expect(Pricing.cost(t, model: "models/gemini-2.5-pro", promptTokens: 100_000) == 1.25 + 10 + 0.125)
        #expect(Pricing.cost(t, model: "gemini-2.5-pro", promptTokens: 300_000) == 2.50 + 15 + 0.25)
        #expect(Pricing.cost(t, model: "gemini-9-unknown") == nil)
    }

    @Test func antigravityDisplayNamesMapToModelIDs() {
        #expect(Pricing.normalize(displayName: "Gemini 4 Argon (Medium)") == "gemini-4-argon")
        #expect(Pricing.normalize(displayName: "Claude Sonnet 5.5 (Thinking)") == "claude-sonnet-5-5")
        #expect(Pricing.price(for: Pricing.normalize(displayName: "Gemini 4 Argon (Medium)")) != nil)
    }

    @Test func antigravityHistoryIsKeptOutOfTheDefaultFile() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let now = Date()
        let limits = [RateLimit(label: "5-hour", usedPercent: 40, resetsAt: now.addingTimeInterval(3600), window: 5 * 3600)]
        var h = PlanHistory()
        let none = h.record(limits, provider: .antigravity, at: now)
        #expect(!none)   // never without a group key
        let key = AntigravityLimits.historyKey("gemini")
        #expect(key.allSatisfy { $0.isHexDigit } && key.count == 8)
        let added = h.record(limits, provider: .antigravity, account: key, at: now)
        #expect(added)
        let claude = h.record(limits, provider: .claude, at: now)
        #expect(claude)
        let base = fx.root.appendingPathComponent("plan-history.json")
        h.save(to: base)
        let defaultFile = try String(contentsOf: base, encoding: .utf8)
        #expect(!defaultFile.contains("\"a5\""))
        let loaded = try #require(PlanHistory.load(from: base))
        #expect(loaded.accounts(.antigravity) == [key])
        #expect(loaded.current(PlanHistory.Series(.antigravity, .fiveHour, account: key), now: now).count == 1)
    }
}
