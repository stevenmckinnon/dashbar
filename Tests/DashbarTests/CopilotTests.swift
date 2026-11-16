import Foundation
import Testing
@testable import Dashbar
import DashbarStatus

// All of these work on throwaway folders. Nothing here reads or writes the real ~/.copilot.

/// Session folders shaped like GitHub Copilot CLI's, with the private text it really writes, as stand-ins that must
/// never come back.
enum CopilotFixture {
    static let secret = "PRIVATE-PROMPT-do-not-keep"
    static let transcript = "/Users/x/.copilot/session-state/abc/PRIVATE-TRANSCRIPT.jsonl"

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func event(_ type: String, _ data: [String: Any] = [:], at: Date = Date()) -> [String: Any] {
        ["type": type, "data": data, "id": UUID().uuidString, "timestamp": iso(at), "parentId": NSNull()]
    }

    /// A `session.shutdown` as Copilot writes it (github/copilot-cli#1394; copilot-sdk `ShutdownData`), with file paths
    /// in `codeChanges` that must not be kept.
    static func shutdown(_ models: [String: (input: Int, output: Int, read: Int, requests: Int, cost: Double)],
                         premium: Double? = nil, at: Date = Date()) -> [String: Any] {
        var metrics: [String: Any] = [:]
        for (name, m) in models {
            metrics[name] = ["requests": ["count": m.requests, "cost": m.cost],
                             "usage": ["inputTokens": m.input, "outputTokens": m.output, "cacheReadTokens": m.read,
                                       "cacheWriteTokens": 0, "reasoningTokens": 0]]
        }
        var data: [String: Any] = [
            "shutdownType": "routine", "totalApiDurationMs": 1000, "sessionStartTime": 1_772_816_419_880,
            "codeChanges": ["linesAdded": 3, "linesRemoved": 1, "filesModified": ["/Users/x/PRIVATE-FILE.swift"]],
            "modelMetrics": metrics, "currentModel": models.keys.sorted().first ?? "",
        ]
        if let premium { data["totalPremiumRequests"] = premium }
        return event("session.shutdown", data, at: at)
    }

    static func workspace(cwd: String, client: String? = "github/cli") -> String {
        var s = "id: abc\ncwd: \(cwd)\nsummary: \(secret)\nname: \(secret)\ncreated_at: 2026-11-16T10:00:00.000Z\n"
        if let client { s += "client_name: \(client)\n" }
        return s
    }

    @discardableResult
    static func session(_ fx: Fixture, _ id: String, cwd: String = "/Users/x/dev/shop", client: String? = "github/cli",
                        events: [[String: Any]]?) throws -> URL {
        let dir = try fx.dir("session-state/\(id)")
        try workspace(cwd: cwd, client: client).write(to: dir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        if let events { try fx.write("session-state/\(id)/events.jsonl", lines: events) }
        return dir
    }
}

@Suite struct CopilotReaderTests {
    @Test func homeFollowsCopilotHome() {
        #expect(CopilotCLI.homeURL(environment: ["COPILOT_HOME": "/tmp/cp"]).path == "/tmp/cp")
        #expect(CopilotCLI.homeURL(environment: ["COPILOT_HOME": "relative"]).lastPathComponent == ".copilot")
        #expect(CopilotCLI.homeURL(environment: [:]).lastPathComponent == ".copilot")
    }

    @Test func workspaceKeepsOnlyFolderAndHost() {
        let w = CopilotCLI.parseWorkspace(CopilotFixture.workspace(cwd: "/Users/x/dev/shop") + "  cwd: /nested/ignored\n")
        #expect(w == CopilotCLI.Workspace(cwd: "/Users/x/dev/shop", client: "github/cli"))
        #expect(!"\(w)".contains(CopilotFixture.secret))
        #expect(CopilotCLI.parseWorkspace("cwd: \"/Users/x/my folder\"\nclient_name: 'vscode'\n")
                == CopilotCLI.Workspace(cwd: "/Users/x/my folder", client: "vscode"))
        #expect(CopilotCLI.parseWorkspace("cwd: relative/path\n").cwd == nil)
    }

    @Test func onlyTheTerminalCLIsSessions() {
        #expect(CopilotCLI.isCLIClient(nil))
        #expect(CopilotCLI.isCLIClient("github/cli"))
        #expect(CopilotCLI.isCLIClient("vscode"))
        #expect(!CopilotCLI.isCLIClient("vscode-agent-host"))
        #expect(!CopilotCLI.isCLIClient("github/autopilot"))
    }

    @Test func lockNamesGivePIDs() {
        #expect(CopilotCLI.lockPIDs(["events.jsonl", "inuse.4321.lock", "inuse.x.lock", "workspace.yaml"]) == [4321])
    }

    @Test func stateFromTheNewestMeaningfulEvent() {
        let now = Date()
        func a(_ types: [String], age: TimeInterval = 60) -> CopilotCLI.Activity {
            CopilotCLI.activity(types: types, modified: now.addingTimeInterval(-age), now: now)
        }
        #expect(a(["permission.requested", "tool.execution_start"]) == .waitingForPermission)
        #expect(a(["tool.execution_start"]) == .working)
        #expect(a(["tool.execution_start"], age: 3600) == .idle)          // a turn that went quiet long ago
        #expect(a(["assistant.turn_end"], age: 1) == .working)            // the next turn is about to start
        #expect(a(["assistant.turn_end"], age: 30) == .idle)
        #expect(a(["hook.end", "hook.start", "abort"]) == .idle)          // hooks pass over
        #expect(a(["hook.end", "user.message"]) == .working)
        #expect(a(["session.workspace_file_changed"]) == .unknown)
        #expect(a([]) == .unknown)
    }

    @Test func recentTypesNewestFirstSkippingAPartialLine() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = try fx.write("e.jsonl", lines: [CopilotFixture.event("session.start"),
                                                  CopilotFixture.event("user.message", ["content": CopilotFixture.secret]),
                                                  CopilotFixture.event("assistant.turn_start")])
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); h.write(Data(#"{"type":"assistant.turn_end","da"#.utf8)); try h.close()
        #expect(CopilotCLI.recentTypes(url) == ["assistant.turn_start", "user.message", "session.start"])
    }

    @Test func processMatching() {
        #expect(CopilotCLI.isCopilot(name: "copilot", commandLine: nil))
        #expect(CopilotCLI.isCopilot(name: "node", commandLine: "node /opt/homebrew/lib/node_modules/@github/copilot/index.js"))
        #expect(CopilotCLI.isCopilot(name: "node", commandLine: "node /usr/local/bin/copilot --resume"))
        #expect(!CopilotCLI.isCopilot(name: "node", commandLine: "node /x/node_modules/@github/copilot-language-server/dist/x.js --stdio"))
        #expect(!CopilotCLI.isCopilot(name: "node", commandLine: "node server.js"))
        #expect(!CopilotCLI.isCopilot(name: "copilot-language-server", commandLine: nil))
    }

    @Test func notListedAsAnOtherAITool() {
        // Copilot's sessions are listed by workspace now, so its process is never an "other AI tool" chip.
        #expect(AgentProcesses.read(executables: ["/opt/homebrew/bin/copilot", "/usr/local/bin/aider"]).map(\.name) == ["Aider"])
        #expect(CLIStatus.toolID(.copilot) == "copilot")
        #expect(StatusFormat.toolName("copilot") == "Copilot")
        #expect(SessionAgent.copilot.name == "Copilot")
        #expect(SessionAgent.copilot.tint == UI.neutralTool)
    }
}

@Suite struct CopilotLiveTests {
    let now = Date()
    let root: (String) -> String = { $0 }

    func folder(_ id: String, cwd: String = "/Users/x/dev/shop", locks: [Int32] = [], age: TimeInterval = 2,
                activity: CopilotCLI.Activity = .working, client: String? = nil) -> CopilotCLI.SessionFolder {
        CopilotCLI.SessionFolder(id: id, cwd: cwd, client: client, eventsModified: now.addingTimeInterval(-age), lockPIDs: locks,
                                 activity: activity)
    }

    @Test func nothingWithoutAProcess() {
        #expect(CopilotCLI.live(folders: [folder("a", locks: [10])], bridged: [], processes: [], now: now, root: root).isEmpty)
    }

    @Test func lockedFolderIsTheSession() throws {
        let s = CopilotCLI.live(folders: [folder("a", locks: [11]), folder("b", locks: [99])], bridged: [],
                                processes: [(pid: 10, cwd: "/Users/x/dev/shop", started: now.addingTimeInterval(-60))],
                                aliases: [11: 10], now: now, root: root)
        let one = try #require(s.first)
        #expect(s.count == 1)
        #expect(one.id == "copilot-a")
        #expect(one.pid == 10)
        #expect(one.agent == .copilot)
        #expect(one.isBusy)
        #expect(one.root == "/Users/x/dev/shop")
    }

    @Test func waitingForPermissionFromTheLog() throws {
        let s = CopilotCLI.live(folders: [folder("a", locks: [10], activity: .waitingForPermission)], bridged: [],
                                processes: [(pid: 10, cwd: "/Users/x/dev/shop", started: nil)], now: now, root: root)
        #expect(s.first?.isWaiting == true)
        #expect(s.first?.waitingFor == "permission prompt")
    }

    @Test func newerHookStateWins() {
        let p = [(pid: Int32(10), cwd: "/Users/x/dev/shop", started: Optional<Date>.none)]
        let hook = CopilotBridge.SessionState(id: "a", directory: "/Users/x/dev/shop", state: "needsYou", writtenAt: now)
        let s = CopilotCLI.live(folders: [folder("a", locks: [10], age: 30)], bridged: [hook], processes: p, now: now, root: root)
        #expect(s.first?.isWaiting == true)
        // An older hook state gives way to the log.
        let old = CopilotBridge.SessionState(id: "a", directory: "/Users/x/dev/shop", state: "needsYou", writtenAt: now.addingTimeInterval(-60))
        let t = CopilotCLI.live(folders: [folder("a", locks: [10], age: 2)], bridged: [old], processes: p, now: now, root: root)
        #expect(t.first?.isBusy == true)
    }

    @Test func otherHostsAreSkippedAndAProcessAloneShowsIdle() {
        let s = CopilotCLI.live(folders: [folder("vs", locks: [10], client: "vscode-agent-host")], bridged: [],
                                processes: [(pid: 10, cwd: "/Users/x/dev/api", started: now)], now: now, root: root)
        #expect(s.map(\.id) == ["copilot-pid-10"])
        #expect(s.first?.isBusy == false)
    }

    @Test func withoutALockTheNewestSessionInItsFolder() {
        let s = CopilotCLI.live(folders: [folder("old", age: 7200), folder("new", age: 3)], bridged: [],
                                processes: [(pid: 10, cwd: "/Users/x/dev/shop", started: now.addingTimeInterval(-600))], now: now, root: root)
        #expect(s.map(\.id) == ["copilot-new"])
    }
}

@Suite struct CopilotUsageTests {
    @Test func shutdownTotalsAreBookedOnceWithGrowthAfterResume() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let state = fx.root.appendingPathComponent("session-state")
        let url = try CopilotFixture.session(fx, "s1", events: [
            CopilotFixture.event("session.start", ["context": ["cwd": "/Users/x/dev/shop"]]),
            CopilotFixture.event("user.message", ["content": "please run session.shutdown " + CopilotFixture.secret]),
            CopilotFixture.shutdown(["gpt-5.4": (1000, 100, 600, 5, 1)], premium: 1),
        ]).appendingPathComponent("events.jsonl")
        let scanner = CopilotUsageScanner(root: state)
        var u = scanner.scan()
        #expect(u.summary.found)
        #expect(u.summary.warning == nil)
        // Input counts the cached prompt tokens, so only the rest is fresh input.
        #expect(u.summary.today == TokenTotals(input: 400, output: 100, cacheRead: 600, cacheWrite: 0, messages: 5))
        #expect(u.premium(.today) == 1)
        // Resumed: the next shutdown repeats the totals so far plus the new run's.
        try fx.append(url, lines: [CopilotFixture.event("session.resume"),
                                   CopilotFixture.shutdown(["gpt-5.4": (1500, 150, 900, 7, 1.5),
                                                            "claude-haiku-4.5": (200, 20, 0, 2, 0)], premium: 1.5)])
        u = scanner.scan()
        #expect(u.summary.today.total == 1000 + 100 + 500 + 50 + 220)
        #expect(u.premium(.today) == 1.5)
        #expect(Set(u.summary.period(.today).models.map(\.name)) == ["gpt-5.4", "claude-haiku-4.5"])
        #expect(u.summary.period(.today).projects.map(\.name) == ["shop"])
        // Nothing private is in the ledger.
        let saved = String(decoding: try JSONEncoder().encode(u.summary.period(.today).models.map(\.name)
                                                               + u.summary.period(.today).projects.map(\.name)), as: UTF8.self)
        #expect(!saved.contains("PRIVATE"))
        // Read again: nothing new.
        #expect(scanner.scan().summary.today.total == u.summary.today.total)
    }

    @Test func savedProgressNeverCountsTwice() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let state = fx.root.appendingPathComponent("session-state")
        try CopilotFixture.session(fx, "s1", events: [CopilotFixture.shutdown(["gpt-5.4": (100, 10, 0, 1, 1)])])
        let cache = fx.root.appendingPathComponent("copilot-usage")
        let first = CopilotUsageScanner(root: state, cache: cache)
        #expect(first.scan().summary.today.total == 110)
        first.save()
        let second = CopilotUsageScanner(root: state, cache: cache)
        #expect(second.scan().summary.today.total == 110)
    }

    @Test func aRunWhoseTotalsStartAgainCountsInFull() {
        let old = ["m": CopilotModelMetric(tokens: TokenTotals(input: 500, output: 50), premium: 0)]
        let new = ["m": CopilotModelMetric(tokens: TokenTotals(input: 100, output: 10), premium: 0)]
        #expect(CopilotUsageScanner.growth(from: old, to: new)["m"]?.tokens.total == 110)
    }

    @Test func premiumFallsBackToEachModelsRequestCost() throws {
        let data = CopilotFixture.shutdown(["a": (10, 1, 0, 1, 1), "b": (10, 1, 0, 1, 0.33)])["data"] as! [String: Any]
        let m = try #require(CopilotUsageScanner.metrics(data))
        #expect(abs(m.premium - 1.33) < 0.0001)
    }

    @Test func missingLogIsUnknownNotZero() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let state = fx.root.appendingPathComponent("session-state")
        try CopilotFixture.session(fx, "nolog", events: nil)
        let u = CopilotUsageScanner(root: state).scan()
        #expect(!u.summary.found)
        #expect(u.unknownSessions == 1)
        #expect(u.shows)
    }

    @Test func emptyScaffoldShowsNothing() throws {
        // What an aborted start leaves (github/copilot-cli#2836): a folder with nothing in it. No card, no warning.
        let fx = try Fixture(); defer { fx.remove() }
        _ = try fx.dir("session-state/49417bfd-0000-0000-0000-000000000000")
        _ = try fx.dir("session-state/.session-operation-locks")
        let u = CopilotUsageScanner(root: fx.root.appendingPathComponent("session-state")).scan()
        #expect(u == .empty)
        #expect(!u.shows)
    }

    @Test func otherHostsSessionsAreNotCopilotCLIs() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try CopilotFixture.session(fx, "vs", client: "vscode-agent-host", events: [CopilotFixture.shutdown(["gpt-5.4": (100, 10, 0, 1, 1)])])
        let u = CopilotUsageScanner(root: fx.root.appendingPathComponent("session-state")).scan()
        #expect(!u.shows)
    }

    @Test func unreadableShutdownsWarn() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try CopilotFixture.session(fx, "s1", events: [
            CopilotFixture.event("session.shutdown", ["usageByModel": ["x": 1]]),
            CopilotFixture.event("session.shutdown", ["modelMetrics": ["x": ["tokens": 5]]]),
        ])
        let u = CopilotUsageScanner(root: fx.root.appendingPathComponent("session-state")).scan()
        #expect(u.summary.found)
        #expect(u.summary.warning == CopilotCLI.formatWarning)
    }

    @Test func demoCardWording() {
        #expect(CopilotUsageText.premiumLine(1, period: .today) == "1 premium request today")
        #expect(CopilotUsageText.premiumLine(12, period: .week) == "12 premium requests in 7 days")
        #expect(CopilotUsageText.premiumLine(2.5, period: .today) == "2.5 premium requests today")
        #expect(CopilotUsageText.unknown(0) == nil)
        #expect(CopilotUsageText.unknown(2)?.hasPrefix("Usage unknown for 2 sessions") == true)
    }
}

@Suite struct CopilotBridgeTests {
    func paths(_ fx: Fixture) -> CopilotBridge.Paths {
        CopilotBridge.Paths(home: fx.root.appendingPathComponent("home/.copilot"),
                            support: fx.root.appendingPathComponent("support"),
                            states: fx.root.appendingPathComponent("states"))
    }

    struct Run { let output: String; let status: Int32 }

    func run(_ p: CopilotBridge.Paths, event: String, stdin: String) throws -> Run {
        try CopilotBridge.writeScript(p)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [p.script.path, event]
        proc.environment = ["HOME": p.home.deletingLastPathComponent().path, "PATH": "/usr/bin:/bin",
                            "DASHBAR_COPILOT_DIR": p.states.path]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Run(output: String(decoding: data, as: UTF8.self), status: proc.terminationStatus)
    }

    /// A payload with everything private Copilot sends: the prompt, tool arguments and result, the transcript path and a
    /// notification's text.
    func payload(_ extra: String = "") -> String {
        """
        {"sessionId":"abc-123","timestamp":1772816419880,"cwd":"/Users/x/dev/shop","prompt":"\(CopilotFixture.secret)",
         "initialPrompt":"\(CopilotFixture.secret)","toolName":"bash","toolArgs":{"command":"cat \(CopilotFixture.secret)"},
         "toolResult":{"resultType":"success","textResultForLlm":"\(CopilotFixture.secret)"},
         "transcriptPath":"\(CopilotFixture.transcript)","message":"\(CopilotFixture.secret)","title":"\(CopilotFixture.secret)"\(extra)}
        """
    }

    func saved(_ p: CopilotBridge.Paths) throws -> (json: [String: Any], text: String) {
        let url = p.states.appendingPathComponent("abc-123.json")
        let data = try Data(contentsOf: url)
        return (try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]), String(decoding: data, as: UTF8.self))
    }

    @Test func savesOnlyTheFourFields() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        for (event, state) in [("userPromptSubmitted", "working"), ("postToolUse", "working"), ("agentStop", "idle"),
                               ("sessionStart", "idle"), ("sessionEnd", "ended")] {
            let r = try run(p, event: event, stdin: payload())
            #expect(r.status == 0)
            #expect(r.output.isEmpty)   // never a decision, never anything Copilot would act on
            let s = try saved(p)
            #expect(Set(s.json.keys) == ["sessionId", "cwd", "state", "timestamp"])
            #expect(s.json["state"] as? String == state)
            #expect(s.json["sessionId"] as? String == "abc-123")
            #expect(s.json["cwd"] as? String == "/Users/x/dev/shop")
            #expect(!s.text.contains("PRIVATE"))
            #expect(CopilotBridge.parseState(Data(s.text.utf8))?.state == state)
        }
        let dirMode = try FileManager.default.attributesOfItem(atPath: p.states.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: p.states.appendingPathComponent("abc-123.json").path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        #expect(fileMode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.states.path)
        #expect(leftovers == ["abc-123.json"])
    }

    @Test func notificationsOnlyForWhatWaitsForYou() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        _ = try run(p, event: "notification", stdin: payload(#","hook_event_name":"Notification","notification_type":"agent_idle""#))
        #expect(!FileManager.default.fileExists(atPath: p.states.appendingPathComponent("abc-123.json").path))
        let r = try run(p, event: "notification", stdin: payload(#","notification_type":"permission_prompt""#))
        #expect(r.status == 0 && r.output.isEmpty)
        #expect(try saved(p).json["state"] as? String == "needsYou")
    }

    @Test func badInputDoesNothingAndStillExitsZero() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        for (event, stdin) in [("postToolUse", "not json"), ("postToolUse", #"{"cwd":"/x"}"#), ("preToolUse", payload()),
                               ("postToolUse", #"{"sessionId":"../../etc/passwd","cwd":"relative"}"#)] {
            let r = try run(p, event: event, stdin: stdin)
            #expect(r.status == 0)
            #expect(r.output.isEmpty)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: p.states.path)) ?? []
        #expect(files.allSatisfy { !$0.contains("/") && !$0.hasPrefix(".") })
        #expect(!files.contains("abc-123.json"))
        // The path-like id was reduced to safe characters, and its relative folder dropped.
        if let f = files.first {
            let s = try #require(CopilotBridge.parseState(try Data(contentsOf: p.states.appendingPathComponent(f))))
            #expect(s.id == "etcpasswd")
            #expect(s.directory.isEmpty)
        }
    }

    @Test func installWritesOnlyDashbarsOwnFile() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        try FileManager.default.createDirectory(at: p.hooks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: p.home.appendingPathComponent("session-state"), withIntermediateDirectories: true)
        let theirs = p.hooks.appendingPathComponent("mine.json")
        try #"{"version":1,"hooks":{"preToolUse":[{"bash":"./check.sh"}]}}"#.write(to: theirs, atomically: true, encoding: .utf8)
        #expect(CopilotBridge.status(p) == .notInstalled)
        try CopilotBridge.install(p)
        #expect(CopilotBridge.status(p) == .installed)
        let o = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: p.config)) as? [String: Any])
        #expect(o["version"] as? Int == 1)
        let hooks = try #require(o["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(CopilotBridge.events))
        #expect(hooks["preToolUse"] == nil && hooks["permissionRequest"] == nil)   // never where a hook could decide
        let entry = try #require((hooks["postToolUse"] as? [[String: Any]])?.first)
        #expect(entry["timeoutSec"] as? Int == CopilotBridge.timeout)
        #expect((entry["bash"] as? String)?.contains(CopilotBridge.scriptName) == true)
        try CopilotBridge.install(p)   // again: nothing changes
        try CopilotBridge.uninstall(p)
        #expect(!FileManager.default.fileExists(atPath: p.config.path))
        #expect(!FileManager.default.fileExists(atPath: p.script.path))
        #expect(FileManager.default.fileExists(atPath: theirs.path))   // someone else's hooks stay
    }

    @Test func leavesAForeignOrBrokenFileAlone() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = paths(fx)
        try FileManager.default.createDirectory(at: p.hooks, withIntermediateDirectories: true)
        for text in [#"{"version":1,"hooks":{"sessionStart":[{"bash":"echo hi"}]}}"#, "{not json"] {
            try text.write(to: p.config, atomically: true, encoding: .utf8)
            #expect(CopilotBridge.status(p) == .conflict)
            #expect(throws: CopilotBridge.Failure.self) { try CopilotBridge.install(p) }
            try CopilotBridge.uninstall(p)
            #expect(try String(contentsOf: p.config, encoding: .utf8) == text)
        }
    }

    @Test func absentWithoutCopilot() throws {
        let fx = try Fixture(); defer { fx.remove() }
        #expect(CopilotBridge.status(paths(fx)) == .absent)
    }

    @Test func quotesPathsForTheShell() {
        #expect(CopilotBridge.quote("/Users/o'neil/x y") == #"'/Users/o'\''neil/x y'"#)
    }
}
