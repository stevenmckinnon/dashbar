import AppKit
import Foundation
import Testing
@testable import Dashbar

// MARK: - Formatting

@Suite struct FormattingTests {
    @Test func tokenCounts() {
        #expect(Fmt.tokens(999) == "999")
        #expect(Fmt.tokens(1_234) == "1.2K")
        #expect(Fmt.tokens(12_345) == "12K")
        #expect(Fmt.tokens(1_500_000) == "1.5M")
        #expect(Fmt.tokens(25_000_000) == "25M")
        #expect(Fmt.tokens(2_340_000_000) == "2.34B")
    }

    @Test func modelNames() {
        #expect(Fmt.model("claude-opus-5-5") == "Opus 5.5")
        #expect(Fmt.model("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(Fmt.model("claude-haiku-5-5") == "Haiku 5.5")
        #expect(Fmt.model("gpt-5-codex") == "gpt-5-codex")
    }

    @Test func worktreesCollapseToTheirRepo() {
        #expect(Fmt.project(fromCwd: "/Users/x/dev/app/.claude/worktrees/festive-yalow-0d796e") == "app")
        #expect(Fmt.root(fromCwd: "/Users/x/dev/app/.claude/worktrees/festive-yalow-0d796e") == "/Users/x/dev/app")
        #expect(Fmt.project(fromCwd: "/Users/x/dev/app") == "app")
    }

    @Test func rootWalksUpToTheNearestGitFolder() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let repo = try fx.dir("monorepo")
        try fx.dir("monorepo/.git")
        let pkg = try fx.dir("monorepo/apps/web")
        #expect(Fmt.root(fromCwd: pkg.path) == repo.path)
    }

    @Test func bytesSplitIntoValueAndUnit() {
        let (value, unit) = Fmt.bytesSplit(47_100_000_000)
        #expect(value == "47.1")
        #expect(unit == "GB")
    }
}

// MARK: - Claude Code usage

@Suite struct ClaudeUsageTests {
    @Test func streamedLinesCountOnceAtTheirLargestUsage() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("-Users-x-dev-app/s1.jsonl", lines: [
            // One message written per content block, usage growing as it streams.
            Fixture.claude(id: "m1", request: "r1", input: 5, output: 10, cacheRead: 100),
            Fixture.claude(id: "m1", request: "r1", input: 5, output: 50, cacheRead: 100),
            // Synthetic placeholder messages are not real usage.
            Fixture.claude(id: "m2", model: "<synthetic>", output: 999),
            Fixture.claude(id: "m3", request: "r3", input: 1, output: 7, cacheWrite: 20),
            ["type": "user", "timestamp": Fixture.now, "message": ["role": "user", "content": "hi"]],
        ])
        let s = ClaudeUsageScanner(root: fx.root).scan()
        #expect(s.found)
        #expect(s.today.input == 6)
        #expect(s.today.output == 57)
        #expect(s.today.cacheRead == 100)
        #expect(s.today.cacheWrite == 20)
        #expect(s.today.messages == 2)
        #expect(s.topProjects.first?.name == "app")
        #expect(s.topModels.first?.name == "Opus 5.5")
        #expect(s.sessions24 == 1)
        #expect(s.warning == nil)
    }

    @Test func rescansOnlyReadAppendedLines() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let file = try fx.write("-p/s1.jsonl", lines: [Fixture.claude(id: "a", output: 10)])
        let scanner = ClaudeUsageScanner(root: fx.root)
        #expect(scanner.scan().today.output == 10)
        try fx.append(file, lines: [Fixture.claude(id: "b", output: 5)])
        let s = scanner.scan()
        #expect(s.today.output == 15)
        #expect(s.today.messages == 2)
    }

    @Test func subagentTranscriptsCount() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("-p/s1.jsonl", lines: [Fixture.claude(id: "a", output: 10)])
        try fx.write("-p/s1/subagents/agent-1.jsonl", lines: [Fixture.claude(id: "b", output: 4, sidechain: true)])
        #expect(ClaudeUsageScanner(root: fx.root).scan().today.output == 14)
    }

    @Test func missingFolderReportsNotFound() {
        let s = ClaudeUsageScanner(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).scan()
        #expect(!s.found)
        #expect(s.warning == nil)
    }

    @Test func unrecognisedFormatRaisesAWarningInsteadOfZero() throws {
        let fx = try Fixture(); defer { fx.remove() }
        // Lines that mention output_tokens but no longer have the message.usage shape.
        let changed: [[String: Any]] = (0..<25).map { i in
            ["type": "assistant", "timestamp": Fixture.now, "turn": ["id": "t\(i)", "tokens": ["output_tokens": 10]]]
        }
        try fx.write("-p/s1.jsonl", lines: changed)
        let s = ClaudeUsageScanner(root: fx.root).scan()
        #expect(s.today.total == 0)
        #expect(s.warning?.contains("Claude Code") == true)
    }
}

// MARK: - Codex usage

@Suite struct CodexUsageTests {
    @Test func cumulativeEventsBecomeDeltasAndDuplicatesDontDoubleCount() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("2026/11/06/rollout-1.jsonl", lines: [
            ["timestamp": Fixture.now, "type": "session_meta", "payload": ["cwd": "/Users/x/dev/api"]],
            ["timestamp": Fixture.now, "type": "turn_context", "payload": ["model": "gpt-5-codex"]],
            ["timestamp": Fixture.now, "type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]],
            Fixture.codexTokens(input: 1_000, cached: 400, output: 100),
            Fixture.codexTokens(input: 1_000, cached: 400, output: 100), // repeated, unchanged
            Fixture.codexTokens(input: 2_500, cached: 1_400, output: 300, rateUsed: 42),
        ])
        let scanner = CodexUsageScanner(root: fx.root)
        let s = scanner.scan()
        #expect(s.today.input == 1_100)      // 2,500 total input minus 1,400 cached
        #expect(s.today.cacheRead == 1_400)
        #expect(s.today.output == 300)
        #expect(s.today.messages == 2)
        #expect(s.topProjects.first?.name == "api")
        #expect(s.topModels.first?.name == "gpt-5-codex")
        #expect(scanner.limits.first?.usedPercent == 42)
        #expect(scanner.limits.first?.label == "5h window")
        #expect(s.warning == nil)
    }
}

// MARK: - Live sessions and context

@Suite struct SessionTests {
    @Test func onlyLiveProcessesAreListedAndWorkingSortsFirst() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970 * 1000
        try JSONSerialization.data(withJSONObject: [
            "pid": me, "sessionId": "idle", "cwd": "/Users/x/dev/a", "status": "idle", "statusUpdatedAt": now, "name": "Idle one",
        ]).write(to: fx.root.appendingPathComponent("1.json"))
        try JSONSerialization.data(withJSONObject: [
            "pid": me, "sessionId": "busy", "cwd": "/Users/x/dev/b", "status": "busy", "statusUpdatedAt": now - 5_000,
        ]).write(to: fx.root.appendingPathComponent("2.json"))
        try JSONSerialization.data(withJSONObject: [
            "pid": 999_999, "sessionId": "dead", "cwd": "/Users/x/dev/c", "status": "busy",
        ]).write(to: fx.root.appendingPathComponent("3.json"))

        let sessions = ClaudeSessions.read(dir: fx.root)
        #expect(sessions.map(\.id) == ["busy", "idle"])
        #expect(sessions.first?.name == "b")            // falls back to the folder name
        #expect(sessions.last?.name == "Idle one")
    }

    @Test func contextComesFromTheLastMainThreadTurn() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("-p/abc.jsonl", lines: [
            Fixture.claude(id: "1", input: 10, output: 10, cacheRead: 1_000),
            Fixture.claude(id: "2", input: 1_000, output: 500, cacheRead: 150_000),
            Fixture.claude(id: "3", input: 1, output: 1, cacheRead: 5, sidechain: true), // subagent, ignored
        ])
        let ctx = ContextReader(projects: fx.root).read([session(id: "abc")])["abc"]
        #expect(ctx?.used == 151_500)
        #expect(ctx?.window == 1_000_000)               // Opus 5.5 has a 1M window
    }

    @Test func windowSizeFollowsTheModel() {
        for m in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-4-6", "claude-sonnet-4-6"] {
            #expect(ContextInfo.window(model: m, used: 1_000) == 1_000_000, "\(m)")
        }
        for m in ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-5-20251101", "claude-3-7-sonnet-20250219"] {
            #expect(ContextInfo.window(model: m, used: 1_000) == 200_000, "\(m)")
        }
        #expect(ContextInfo.window(model: "claude-sonnet-4-5[1m]", used: 1_000) == 1_000_000)
        #expect(ContextInfo.window(model: "claude-sonnet-4-5", used: 250_000) == 1_000_000)
    }

    @Test func usagePastTwoHundredThousandImpliesTheLargeWindow() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("-p/big.jsonl", lines: [Fixture.claude(id: "1", input: 10, cacheRead: 450_000)])
        let ctx = ContextReader(projects: fx.root).read([session(id: "big")])["big"]
        #expect(ctx?.window == 1_000_000)
        #expect(abs((ctx?.fraction ?? 0) - 0.45) < 0.001)
    }
}

// MARK: - Workspaces

@Suite struct WorkspaceTests {
    @Test func sessionsAndServersGroupByRepoWithWorkingFirst() {
        let sessions = [
            session(id: "1", root: "/dev/zeta", busy: false),
            session(id: "2", root: "/dev/alpha", busy: false),
            session(id: "3", root: "/dev/zeta", busy: true),
        ]
        var server = Listener(pid: 42, port: 3000, command: "node", address: "*")
        server.root = "/dev/alpha"
        var otherPort = Listener(pid: 42, port: 3001, command: "node", address: "*")
        otherPort.root = "/dev/alpha"
        server.memory = 100; otherPort.memory = 100

        let ws = Workspace.build(sessions: sessions, servers: [server, otherPort])
        #expect(ws.map(\.name) == ["zeta", "alpha"])
        #expect(ws[0].isBusy)
        #expect(ws[1].ports == [3000, 3001])
        #expect(ws[1].memory == 100)      // one process, counted once
    }

    @Test func filterMatchesNamesSessionsAndPorts() {
        var server = Listener(pid: 1, port: 5173, command: "node", address: "*")
        server.root = "/dev/site"
        let w = Workspace(root: "/dev/site", sessions: [session(id: "1", root: "/dev/site", name: "Fix the header")], servers: [server])
        #expect(w.matches("site"))
        #expect(w.matches("header"))
        #expect(w.matches(":517"))
        #expect(!w.matches("api"))
    }
}

// MARK: - Clean-up

@Suite struct CleanupTests {
    @Test func findsCachesAndSkipsHiddenFolders() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let modules = try fx.dir("app/node_modules/react")
        try Data(count: 1_500_000).write(to: modules.appendingPathComponent("blob"))
        let hidden = try fx.dir(".cache/node_modules")
        try Data(count: 1_500_000).write(to: hidden.appendingPathComponent("blob"))
        let tiny = try fx.dir("small/.next")
        try Data(count: 10).write(to: tiny.appendingPathComponent("blob"))

        let items = Cleanup.scan(roots: [fx.root], includeDerivedData: false)
        #expect(items.count == 1)                       // hidden skipped, sub-1 MB dropped
        #expect(items.first?.kind == "node_modules")
        #expect(items.first?.project == "app")
        #expect((items.first?.size ?? 0) >= 1_500_000)
    }
}

// MARK: - Helpers

private func session(id: String, root: String = "/dev/app", busy: Bool = false, name: String? = nil) -> LiveSession {
    LiveSession(id: id, pid: 1, name: name ?? id, cwd: root, status: busy ? "busy" : "idle",
                since: Date(), entrypoint: "cli", root: root)
}

// MARK: - Saved scan progress

@Suite struct PersistenceTests {
    @Test func relaunchFromSavedProgressMatchesAndOnlyReadsNewLines() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let logs = try fx.dir("logs")
        let file = try fx.write("logs/-p/s1.jsonl", lines: [Fixture.claude(id: "a", output: 10), Fixture.claude(id: "b", output: 20)])
        let cache = fx.root.appendingPathComponent("cache.json")

        let first = ClaudeUsageScanner(root: logs, cache: cache)
        let before = first.scan()
        first.save()

        let relaunched = ClaudeUsageScanner(root: logs, cache: cache)
        #expect(relaunched.scan().today == before.today)          // nothing re-read, nothing lost
        try fx.append(file, lines: [Fixture.claude(id: "c", output: 5)])
        #expect(relaunched.scan().today.output == 35)
    }

    @Test func restartMidStreamDoesNotDoubleCountTheMessage() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let logs = try fx.dir("logs")
        let file = try fx.write("logs/-p/s1.jsonl", lines: [Fixture.claude(id: "m", request: "r", output: 10)])
        let cache = fx.root.appendingPathComponent("cache.json")
        let first = ClaudeUsageScanner(root: logs, cache: cache)
        _ = first.scan()
        first.save()
        // The same message keeps streaming after the restart.
        try fx.append(file, lines: [Fixture.claude(id: "m", request: "r", output: 40)])
        let s = ClaudeUsageScanner(root: logs, cache: cache).scan()
        #expect(s.today.output == 40)
        #expect(s.today.messages == 1)
    }

    @Test func savedProgressForADifferentFolderIsIgnored() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let a = try fx.dir("a"), b = try fx.dir("b")
        try fx.write("a/-p/s.jsonl", lines: [Fixture.claude(id: "x", output: 10)])
        try fx.write("b/-p/s.jsonl", lines: [Fixture.claude(id: "y", output: 3)])
        let cache = fx.root.appendingPathComponent("cache.json")
        let scanA = ClaudeUsageScanner(root: a, cache: cache)
        _ = scanA.scan(); scanA.save()
        #expect(ClaudeUsageScanner(root: b, cache: cache).scan().today.output == 3)
    }

    @Test func corruptOrOldCacheStartsFresh() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let logs = try fx.dir("logs")
        try fx.write("logs/-p/s.jsonl", lines: [Fixture.claude(id: "x", output: 10)])
        let cache = fx.root.appendingPathComponent("cache.json")
        try Data("{not json".utf8).write(to: cache)
        #expect(ClaudeUsageScanner(root: logs, cache: cache).scan().today.output == 10)
    }

    @Test func codexProgressSurvivesARelaunch() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let logs = try fx.dir("logs")
        let file = try fx.write("logs/r.jsonl", lines: [
            ["timestamp": Fixture.now, "type": "turn_context", "payload": ["model": "gpt-5-codex"]],
            Fixture.codexTokens(input: 1_000, cached: 0, output: 100, rateUsed: 10),
        ])
        let cache = fx.root.appendingPathComponent("codex.json")
        let first = CodexUsageScanner(root: logs, cache: cache)
        _ = first.scan(); first.save()
        try fx.append(file, lines: [Fixture.codexTokens(input: 1_500, cached: 0, output: 160)])
        let again = CodexUsageScanner(root: logs, cache: cache)
        let s = again.scan()
        #expect(s.today.input == 1_500)                  // cumulative carried over: only the +500 is new
        #expect(s.today.output == 160)
        #expect(s.topModels.first?.name == "gpt-5-codex")
        #expect(again.limits.first?.usedPercent == 10)
    }
}

// MARK: - Process inspection (libproc)

@Suite struct ProcTests {
    @Test func seesAListeningSocketWithItsPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // any free port
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))

        let sockets = Proc.listeningSockets(getpid())
        #expect(sockets.contains(Proc.ListeningSocket(port: port, address: "127.0.0.1")))
    }

    @Test func readsThisProcessesDetails() {
        let me = getpid()
        #expect(Proc.allPIDs().contains(me))
        #expect(Proc.path(me) != nil)
        #expect(!Proc.name(me).isEmpty)
        #expect(Proc.residentBytes(me) > 0)
        #expect(Proc.cwd(me) == FileManager.default.currentDirectoryPath)
        #expect(Proc.commandLine(me)?.isEmpty == false)
    }

    @Test func agentToolsAreRecognisedByExecutableName() {
        let found = AgentProcesses.read(executables: ["/usr/local/bin/codex", "/opt/homebrew/bin/codex", "/bin/zsh",
                                                      "/Applications/Cursor.app/Contents/MacOS/Cursor"])
        #expect(found.map(\.name) == ["Codex", "Cursor"])
        #expect(found.first?.count == 2)
    }

    @Test func supersetIsRecognised() {
        let found = AgentProcesses.read(executables: ["/Applications/Superset.app/Contents/MacOS/Superset"])
        #expect(found.map(\.name) == ["Superset"])
    }

    @Test func t3CodeShowsOnceEvenThoughItRunsItsBinaryTwice() {
        let app = "/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)"
        let found = AgentProcesses.read(executables: [app, app,
            "/Applications/T3 Code (Beta).app/Contents/Frameworks/T3 Code (Beta) Helper.app/Contents/MacOS/T3 Code (Beta) Helper"])
        #expect(found.map(\.name) == ["T3 Code"])
        #expect(found.first?.count == 1)
    }
}

// MARK: - Window visibility

@Suite struct SurfaceVisibilityTests {
    /// The store only reacts when "is anything visible" flips, so each report returns whether it did.
    private func report(_ v: inout SurfaceVisibility, _ visible: Bool, _ surface: String) -> Bool {
        v.set(visible, surface: surface)
    }

    @Test func theStoreOnlyReactsWhenTheFirstWindowOpensOrTheLastCloses() {
        var v = SurfaceVisibility()
        let panelOpens = report(&v, true, "panel")        // first window opens: updates start
        let popoutOpens = report(&v, true, "popout")      // a second one changes nothing
        let panelCloses = report(&v, false, "panel")      // closing the panel must not pause the popout
        #expect(panelOpens)
        #expect(!popoutOpens)
        #expect(!panelCloses)
        #expect(v.anyVisible)
        let popoutCloses = report(&v, false, "popout")    // the last one closes: updates can slow down
        #expect(popoutCloses)
        #expect(!v.anyVisible)
    }

    @Test func repeatedReportsAreHarmless() {
        var v = SurfaceVisibility()
        let neverOpened = report(&v, false, "panel")      // closing something that never opened
        let opens = report(&v, true, "panel")
        let again = report(&v, true, "panel")             // onAppear and the occlusion callback both report
        let closes = report(&v, false, "panel")
        #expect(!neverOpened)
        #expect(opens)
        #expect(!again)
        #expect(closes)
    }
}

// MARK: - Plan limits (experimental Claude, parsing only)

@Suite struct PlanLimitTests {
    @Test func parsesUsageWindowsInAStableOrder() {
        let json = """
        {"seven_day": {"utilization": 28.0, "resets_at": "2026-11-10T09:00:00Z"},
         "five_hour": {"utilization": 62, "resets_at": "2026-11-06T22:40:00.000Z"},
         "seven_day_opus": {"utilization": 4.5, "resets_at": null},
         "extra_usage": null}
        """
        let limits = ClaudePlanLimits.parse(Data(json.utf8))
        #expect(limits.map(\.label) == ["5-hour", "Weekly", "Weekly · Opus"])
        #expect(limits[0].usedPercent == 62)
        #expect(limits[0].resetsAt != nil)
        #expect(limits[2].resetsAt == nil)
    }

    @Test func unrecognisedResponsesYieldNothingRatherThanGarbage() {
        #expect(ClaudePlanLimits.parse(Data("[]".utf8)).isEmpty)
        #expect(ClaudePlanLimits.parse(Data("not json".utf8)).isEmpty)
        #expect(ClaudePlanLimits.parse(Data(#"{"five_hour": {"pct": 3}}"#.utf8)).isEmpty)
    }

    @Test func readsTheTokenExpiryAndPlanFromTheSignIn() {
        let json = #"{"claudeAiOauth": {"accessToken": "tok", "refreshToken": "r", "expiresAt": 1793990000000, "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}"#
        let c = ClaudePlanLimits.parseCredentials(Data(json.utf8))
        #expect(c?.token == "tok")
        #expect(c?.plan == "Max 20x")
        #expect(c?.expiresAt == Date(timeIntervalSince1970: 1_793_990_000))
        #expect(ClaudePlanLimits.parseCredentials(Data(#"{"other": {}}"#.utf8)) == nil)
    }

    @Test func planNamesWithoutATier() {
        #expect(ClaudePlanLimits.planName(["subscriptionType": "pro"]) == "Pro")
        #expect(ClaudePlanLimits.planName([:]) == nil)
    }
}

// MARK: - System stats

@Suite struct SystemStatsTests {
    @Test func samplerReportsSaneValues() throws {
        let sampler = SystemSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.4)
        let s = sampler.sample()
        #expect((0...1).contains(s.cpu))
        #expect(abs(s.cpu - (s.cpuUser + s.cpuSystem)) < 0.02)
        #expect(s.memUsed > 0 && s.memUsed <= s.memTotal)
        #expect(s.memApp + s.memWired + s.memCompressed == s.memUsed)
        #expect(s.netDown >= 0 && s.netUp >= 0)
        #expect(s.diskTotal > 0)
        #expect(!s.chip.isEmpty)
        #expect(SystemSampler.interfaceBytes() != nil)
    }

    @Test func historyKeepsTheMostRecentSamples() {
        var h = SystemHistory()
        for i in 0..<(SystemHistory.length + 10) {
            var s = SystemSnapshot(); s.cpu = Double(i) / 100; s.netDown = Double(i)
            h.append(s)
        }
        #expect(h.cpu.count == SystemHistory.length)
        #expect(h.down.last == Double(SystemHistory.length + 9))
    }

    @Test func helperProcessesGroupUnderTheirApp() {
        let me = SystemSampler.group(for: getpid())
        #expect(!me.name.isEmpty)
        #expect(me.appPath == nil || me.appPath!.hasSuffix(".app"))
    }

    @Test func rateFormatting() {
        #expect(Fmt.shortRate(628_000) == "628K")
        #expect(Fmt.shortRate(1_900_000) == "1.9M")
        #expect(Fmt.shortRate(12) == "12B")
        #expect(Fmt.minutes(147) == "2h 27m")
        #expect(Fmt.minutes(45) == "45m")
    }
}

@Suite struct RateFormatTests {
    @Test func zeroIsANumber() {
        #expect(!Fmt.rate(0).lowercased().contains("zero"))
        #expect(Fmt.rate(1_900_000).hasSuffix("/s"))
    }
}

@Suite struct PlanCredentialChoiceTests {
    private func creds(_ token: String, expiresIn: TimeInterval?) -> ClaudePlanLimits.Credentials {
        ClaudePlanLimits.Credentials(token: token, expiresAt: expiresIn.map { Date().addingTimeInterval($0) }, plan: nil)
    }

    @Test func prefersAValidSignInOverAStaleOne() {
        let pick = ClaudePlanLimits.best(of: [creds("old", expiresIn: -86_400 * 20), creds("fresh", expiresIn: 3_600)])
        #expect(pick?.token == "fresh")
    }

    @Test func amongExpiredPicksTheMostRecentSoTheMessageIsAccurate() {
        let pick = ClaudePlanLimits.best(of: [creds("ancient", expiresIn: -86_400 * 90), creds("recent", expiresIn: -60)])
        #expect(pick?.token == "recent")
        #expect(ClaudePlanLimits.best(of: []) == nil)
    }

    @Test func expiredMessageSaysWhenAndHowToFix() {
        let msg = ClaudePlanLimits.expiredMessage(Date().addingTimeInterval(-86_400 * 21))
        #expect(msg.contains("ago"))
        #expect(msg.contains("claude"))
    }
}

@Suite struct PlanLabelTests {
    @Test func unknownWindowsGetSentenceCaseLabels() {
        #expect(ClaudePlanLimits.label(for: "extra_usage") == "Extra usage")
        #expect(ClaudePlanLimits.label(for: "five_hour") == "5-hour")
    }
}

@Suite("Plan limit pace")
struct PaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func limit(used: Double, hoursLeft: Double, window: Double = 5) -> RateLimit {
        RateLimit(label: "5-hour", usedPercent: used, resetsAt: now.addingTimeInterval(hoursLeft * 3600), window: window * 3600)
    }

    @Test func expectedFollowsElapsedTime() {
        #expect(limit(used: 0, hoursLeft: 2.5).expectedPercent(now: now) == 50)
    }

    @Test func projectsRunningOut() {
        // 80% used halfway through: at that rate 100% arrives 37.5 minutes later, before the reset.
        guard case .runsOut(let date)? = limit(used: 80, hoursLeft: 2.5).pace(now: now) else {
            Issue.record("expected runsOut"); return
        }
        #expect(abs(date.timeIntervalSince(now) - 37.5 * 60) < 1)
    }

    @Test func underAndOnPace() {
        #expect(limit(used: 20, hoursLeft: 2.5).pace(now: now) == .under)
        #expect(limit(used: 45, hoursLeft: 2.5).pace(now: now) == .onPace)
        #expect(limit(used: 100, hoursLeft: 2.5).pace(now: now) == .usedUp)
    }

    @Test func tooEarlyOrUnknownWindowHasNoPace() {
        #expect(limit(used: 3, hoursLeft: 4.9).pace(now: now) == nil)
        let unknown = RateLimit(label: "Extra usage", usedPercent: 50, resetsAt: now.addingTimeInterval(3600))
        #expect(unknown.pace(now: now) == nil)
    }

    @Test func claudeWindowsByKey() {
        #expect(ClaudePlanLimits.window(for: "five_hour") == TimeInterval(5 * 3600))
        #expect(ClaudePlanLimits.window(for: "seven_day_opus") == TimeInterval(7 * 86400))
        #expect(ClaudePlanLimits.window(for: "extra_usage") == nil)
    }
}

@Suite("Idle dev servers")
struct IdleServerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func newServersAreNeverIdle() {
        #expect(!ServerActivity.isIdle(uptime: 30 * 60, cpu: 0, watched: [], now: now))
    }

    @Test func fallsBackToLifetimeAverage() {
        #expect(ServerActivity.isIdle(uptime: 86400, cpu: 60, watched: [], now: now))        // 0.07% of a core
        #expect(!ServerActivity.isIdle(uptime: 86400, cpu: 3600, watched: [], now: now))     // 4%
    }

    @Test func recentActivityWins() {
        // Busy all day, then quiet for the last 20 minutes: idle.
        let quiet = [(at: now.addingTimeInterval(-20 * 60), cpu: 5000.0)]
        #expect(ServerActivity.isIdle(uptime: 86400, cpu: 5001, watched: quiet, now: now))
        // Quiet on average, but busy in the last 20 minutes: not idle.
        let busy = [(at: now.addingTimeInterval(-20 * 60), cpu: 10.0)]
        #expect(!ServerActivity.isIdle(uptime: 86400, cpu: 130, watched: busy, now: now))
    }
}

@Suite("Agent process tree")
struct ProcessTreeTests {
    @Test func attributesDescendantsAndServers() {
        // 100 is a Claude session; 101 its shell; 102 a dev server under it; 200 an unrelated server.
        let parents: [Int32: Int32] = [100: 50, 101: 100, 102: 101, 103: 100, 200: 1, 50: 1]
        var listeners = [
            Listener(pid: 102, port: 3000, command: "node", address: "*"),
            Listener(pid: 200, port: 8080, command: "nginx", address: "*"),
        ]
        let spawned = ProcessTree.spawned(roots: [100], parents: parents, listeners: &listeners,
                                          memory: { $0 == 102 ? 300 : 10 }, name: { $0 == 102 ? "node" : "zsh" })
        #expect(spawned[100]?.count == 3)
        #expect(spawned[100]?.memory == 320)
        #expect(spawned[100]?.ports == [3000])
        #expect(spawned[100]?.names.first == "node")
        #expect(listeners[0].startedBy == 100)
        #expect(listeners[1].startedBy == nil)
    }
}

@Suite("Menu bar plan reading")
struct MenuBarReadingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func limit(_ label: String, used: Double, hoursLeft: Double, window: Double) -> RateLimit {
        RateLimit(label: label, usedPercent: used, resetsAt: now.addingTimeInterval(hoursLeft * 3600), window: window * 3600)
    }

    @Test func showsWhatIsLeftOfTheMostUsedWindow() {
        let r = ClaudePlanLimits.menuBarReading([
            limit("5-hour", used: 30, hoursLeft: 2.5, window: 5),
            limit("Weekly", used: 45, hoursLeft: 84, window: 168),
        ], now: now)
        #expect(r == .init(name: "week", leftPercent: 55, atRisk: false))
    }

    @Test func warnsWhenOnCourseToRunOut() {
        let r = ClaudePlanLimits.menuBarReading([limit("5-hour", used: 80, hoursLeft: 2.5, window: 5)], now: now)
        #expect(r == .init(name: "5h", leftPercent: 20, atRisk: true))
    }

    @Test func warnsWhenNearlyUsedUpEvenWithoutPace() {
        let unknown = RateLimit(label: "Weekly", usedPercent: 93, resetsAt: nil)
        #expect(ClaudePlanLimits.menuBarReading([unknown], now: now)?.atRisk == true)
    }

    @Test func ignoresOtherWindowsAndEmptyInput() {
        #expect(ClaudePlanLimits.menuBarReading([], now: now) == nil)
        #expect(ClaudePlanLimits.menuBarReading([RateLimit(label: "Extra usage", usedPercent: 50, resetsAt: nil)], now: now) == nil)
    }
}

// MARK: - Usage periods

@Suite struct UsagePeriodTests {
    @Test func eachPeriodSumsItsOwnDays() {
        var book = UsageBook()
        let now = Date()
        func add(_ daysAgo: Int, _ out: Int, project: String) {
            var t = TokenTotals(); t.output = out; t.messages = 1
            book.add(t, at: now.addingTimeInterval(-Double(daysAgo) * 86_400), model: "m", project: project)
        }
        add(0, 10, project: "a")
        add(3, 20, project: "b")
        add(10, 40, project: "b")

        let s = book.summary(found: true)
        #expect(s.period(.today).totals.output == 10)
        #expect(s.period(.week).totals.output == 30)
        #expect(s.period(.fortnight).totals.output == 70)
        #expect(s.period(.today).projects.map(\.name) == ["a"])
        #expect(s.period(.week).projects.first?.name == "b")
        #expect(s.period(.fortnight).projects.first?.value == 60)
    }
}

// MARK: - Project icons

@Suite struct ProjectIconTests {
    private func writePNG(_ url: URL, side: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    @Test func findsTheProjectsOwnIconAndIgnoresTinyOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writePNG(root.appendingPathComponent("public/favicon.png"), side: 16)   // too small to show crisply
        #expect(ProjectIcon.find(in: root.path) == nil)

        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root2) }
        try writePNG(root2.appendingPathComponent("app/icon.png"), side: 64)
        #expect(ProjectIcon.find(in: root2.path) != nil)
    }

    @Test func findsTheLargestXcodeAppIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let set = root.appendingPathComponent("MyApp/Assets.xcassets/AppIcon.appiconset")
        try writePNG(set.appendingPathComponent("small.png"), side: 40)
        try writePNG(set.appendingPathComponent("big.png"), side: 256)
        let image = try #require(ProjectIcon.find(in: root.path))
        #expect((image.representations.map(\.pixelsWide).max() ?? 0) == 256)
    }
}
