import Foundation
import Testing
@testable import Dashbar

// Two throwaway config folders stand in for a personal and a work Claude Code account. Nothing here reads or writes
// the real ~/.claude, ~/.codex or the app's preferences.

@Suite struct AccountModelTests {
    let home = URL(fileURLWithPath: "/Users/x")

    @Test func theDefaultComesFirstAndEachFolderOnce() {
        let saved = [
            AgentAccount(kind: .claude, path: "/Users/x/.claude-work/", label: ""),
            AgentAccount(kind: .claude, path: "/Users/x/.claude-work", label: "Duplicate"),
            AgentAccount(kind: .claude, path: "/Users/x/.claude", label: "Personal"),
            AgentAccount(kind: .codex, path: "/Users/x/.codex-work", label: "Codex work"),
        ]
        let claude = AgentAccounts.resolve(.claude, saved: saved, environment: [:], home: home)
        #expect(claude.map(\.path) == ["/Users/x/.claude", "/Users/x/.claude-work"])
        #expect(claude.map(\.label) == ["Personal", "Work"])   // an empty name comes from the folder
        #expect(claude.map(\.isDefault) == [true, false])
        #expect(claude[0].key == nil)
        #expect(claude[1].key == "74ed04d5")                    // printf '%s' /Users/x/.claude-work | shasum -a 256
        #expect(claude[1].fileName("claude-usage") == "claude-usage-74ed04d5.json")
        #expect(claude[0].fileName("claude-usage") == "claude-usage.json")

        let codex = AgentAccounts.resolve(.codex, saved: saved, environment: [:], home: home)
        #expect(codex.map(\.label) == ["Default", "Codex work"])
    }

    @Test func theEnvironmentVariablePicksTheDefaultFolder() {
        let env = ["CLAUDE_CONFIG_DIR": "/Users/x/.claude-p", "CODEX_HOME": "/tmp/codex"]
        #expect(AgentAccounts.defaultPath(.claude, environment: env, home: home) == "/Users/x/.claude-p")
        #expect(AgentAccounts.defaultPath(.codex, environment: env, home: home) == "/tmp/codex")
        #expect(AgentAccounts.defaultPath(.claude, environment: [:], home: home) == "/Users/x/.claude")
    }

    @Test func keychainEntriesAreNamedByTheFolderHash() {
        let accounts = AgentAccounts.resolve(.claude, saved: [AgentAccount(kind: .claude, path: "/Users/x/.claude-work", label: "Work")],
                                             environment: [:], home: home)
        #expect(accounts[0].keychainService(environment: [:]) == "Claude Code-credentials")
        #expect(accounts[1].keychainService(environment: [:]) == "Claude Code-credentials-74ed04d5")
        // With CLAUDE_CONFIG_DIR set even the default account's entry carries a suffix.
        #expect(accounts[0].keychainService(environment: ["CLAUDE_CONFIG_DIR": "/Users/x/.claude"])?.hasPrefix("Claude Code-credentials-") == true)
    }

    @Test func suggestionsAreTopLevelFoldersWithLogs() throws {
        let fx = try Fixture(); defer { fx.remove() }
        _ = try fx.dir(".claude-work/projects")
        _ = try fx.dir(".claude-old")                      // no logs: not suggested
        _ = try fx.dir(".claude_side/sessions")
        _ = try fx.dir(".claude-added/sessions")
        _ = try fx.dir("Development/.claude-deep/sessions") // deeper than the home folder: never looked at
        _ = try fx.dir(".codex-work/sessions")
        let root = AgentAccounts.normalise(fx.root.path)
        let found = AgentAccounts.suggestions(.claude, known: [root + "/.claude-added"], home: fx.root)
        #expect(found == [root + "/.claude-work", root + "/.claude_side"])
        #expect(AgentAccounts.suggestions(.codex, known: [], home: fx.root) == [root + "/.codex-work"])
        #expect(AgentAccounts.suggestedLabel(forFolder: "/Users/x/.claude_side") == "Side")
    }

    @Test func accountsPersistAndReload() throws {
        try withTestDefaults { defaults in
            #expect(AppSettings.loadAccounts(from: defaults).isEmpty)
            let accounts = [AgentAccount(kind: .claude, path: "/Users/x/.claude-work", label: "Work"),
                            AgentAccount(kind: .codex, path: "/Users/x/.codex-work", label: "")]
            AppSettings.saveAccounts(accounts, to: defaults)
            #expect(AppSettings.loadAccounts(from: defaults) == accounts)
            AppSettings.saveAccounts([], to: defaults)
            #expect(defaults.object(forKey: AppSettings.Key.accounts) == nil)
        }
    }
}

@Suite struct AccountDataTests {
    let me = Int(ProcessInfo.processInfo.processIdentifier)

    func accounts(_ fx: Fixture) throws -> [ResolvedAccount] {
        let personal = try fx.dir("personal"), work = try fx.dir("work")
        return AgentAccounts.resolve(.claude, saved: [AgentAccount(kind: .claude, path: work.path, label: "Work"),
                                                       AgentAccount(kind: .claude, path: personal.path, label: "Personal")],
                                     environment: ["CLAUDE_CONFIG_DIR": personal.path], home: fx.root)
    }

    func session(_ id: String, status: String, in dir: URL, _ file: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "pid": me, "sessionId": id, "cwd": "/Users/x/dev/\(id)", "status": status,
            "statusUpdatedAt": Date().timeIntervalSince1970 * 1000,
        ]).write(to: dir.appendingPathComponent(file))
    }

    @Test func anAccountWhoseFolderIsMissingIsNeitherReadNorCounted() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let personal = try fx.dir("personal")
        let work = AgentAccounts.normalise(fx.root.appendingPathComponent("work").path)   // never created
        let all = AgentAccounts.resolve(.claude, saved: [AgentAccount(kind: .claude, path: work, label: "Work")],
                                        environment: ["CLAUDE_CONFIG_DIR": personal.path], home: fx.root)
        #expect(all.map(\.label) == ["Default", "Work"])

        let missing = AgentAccounts.missingFolders(all)
        #expect(missing == [work])
        let read = AgentAccounts.readable(all, missing: missing)
        #expect(read.map(\.path) == [all[0].path])

        // One account read: its sessions carry no account name, as with only one set up.
        try session("p1", status: "busy", in: all[0].sessionsDir, "1.json")
        #expect(ClaudeSessions.readChecked(accounts: read).sessions.map(\.account) == [nil])

        // A file where the folder should be doesn't count either.
        try Data().write(to: URL(fileURLWithPath: work))
        #expect(AgentAccounts.missingFolders(all) == [work])
        try FileManager.default.removeItem(atPath: work)

        // Once the folder exists the next check reads it, and both accounts are named.
        try session("w1", status: "idle", in: all[1].sessionsDir, "1.json")
        let now = AgentAccounts.readable(all, missing: AgentAccounts.missingFolders(all))
        #expect(now.count == 2)
        #expect(ClaudeSessions.readChecked(accounts: now).sessions.map(\.account) == ["Default", "Work"])
    }

    @Test func theDefaultAccountIsReadEvenWithoutItsFolder() {
        let all = AgentAccounts.resolve(.claude, saved: [], environment: ["CLAUDE_CONFIG_DIR": "/nonexistent/dashbar-tests"],
                                        home: URL(fileURLWithPath: "/nonexistent"))
        #expect(AgentAccounts.missingFolders(all).isEmpty)
        #expect(AgentAccounts.readable(all, missing: []).count == 1)
    }

    @Test func sessionsFromEveryAccountAreMergedAndLabelled() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let all = try accounts(fx)
        try session("p1", status: "idle", in: all[0].sessionsDir, "1.json")
        try session("w1", status: "busy", in: all[1].sessionsDir, "1.json")   // same file name, other account
        let reading = ClaudeSessions.readChecked(accounts: all)
        #expect(reading.sessions.map(\.id) == ["w1", "p1"])                   // working first, across accounts
        #expect(reading.sessions.map(\.account) == ["Work", "Personal"])
        #expect(reading.sessions.first?.configDir == all[1].path)
        #expect(reading.sessions.last?.configDir == nil)                        // the default account

        // One account: no label, so nothing changes for single-account users.
        let single = ClaudeSessions.readChecked(accounts: [all[0]])
        #expect(single.sessions.map(\.account) == [nil])
    }

    @Test func contextIsReadFromTheSessionsOwnAccount() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let all = try accounts(fx)
        try fx.write("work/projects/-p/w1.jsonl", lines: [Fixture.claude(id: "1", input: 1_000, cacheRead: 9_000)])
        try session("w1", status: "busy", in: all[1].sessionsDir, "1.json")
        let sessions = ClaudeSessions.readChecked(accounts: all).sessions
        let ctx = ContextReader(projects: all[0].projectsDir).read(sessions)
        #expect(ctx["w1"]?.used == 10_000)
    }

    @Test func usageIsScannedAndCachedPerAccountThenAddedUp() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let all = try accounts(fx)
        try fx.write("personal/projects/-a/1.jsonl", lines: [Fixture.claude(id: "m1", input: 100, output: 10, session: "a")])
        try fx.write("work/projects/-b/2.jsonl", lines: [Fixture.claude(id: "m2", input: 2_000, output: 20, session: "b")])
        let caches = try fx.dir("support")
        let urls = all.map { caches.appendingPathComponent($0.fileName("claude-usage")) }
        #expect(Set(urls.map(\.lastPathComponent)).count == 2)

        let scanners = zip(all, urls).map { ClaudeUsageScanner(root: $0.0.projectsDir, cache: $0.1) }
        let summaries = scanners.map { $0.scan() }
        #expect(summaries.map(\.today.input) == [100, 2_000])
        let combined = Worker.combined(zip(scanners, summaries).map { ($0.0.currentBook, $0.1) })
        #expect(combined.today.input == 2_100)
        #expect(combined.today.output == 30)
        #expect(combined.sessions24 == 2)
        #expect(Worker.combined([(scanners[0].currentBook, summaries[0])]) == summaries[0])
        for s in scanners { s.save() }

        // Each cache belongs to its folder: reopening one with the other's progress starts from scratch.
        let reopened = ClaudeUsageScanner(root: all[1].projectsDir, cache: urls[1]).scan()
        #expect(reopened.today.input == 2_000)
        let crossed = ClaudeUsageScanner(root: all[0].projectsDir, cache: urls[1])
        #expect(crossed.scan().today.input == 100)   // read from its own logs, not the work account's saved totals
    }
}

@Suite struct AccountStatusLineTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func run(script: URL, args: [String], stdin: String, outDir: URL, home: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + args
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "DASHBAR_STATUSLINE_DIR": outDir.path]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
    }

    func sample(_ session: String, five: Double) -> String {
        let reset = Int(Date().timeIntervalSince1970) + 3_600
        return #"{"session_id":"\#(session)","cost":{"total_api_duration_ms":1},"rate_limits":{"five_hour":{"used_percentage":\#(five),"resets_at":\#(reset)}}}"#
    }

    @Test func eachAccountsBridgeWritesItsOwnReading() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let personal = try fx.dir("personal"), work = try fx.dir("work")
        let all = AgentAccounts.resolve(.claude, saved: [AgentAccount(kind: .claude, path: work.path, label: "Work")],
                                        environment: ["CLAUDE_CONFIG_DIR": personal.path], home: fx.root)
        let readings = try fx.dir("caches"), support = fx.root.appendingPathComponent("support")
        let paths = all.map {
            StatusLineBridge.Paths(settings: $0.settingsFile, support: support, readings: readings, account: $0.key)
        }
        for p in paths { try StatusLineBridge.install(p, now: now) }

        // The default keeps the command it always had; the other account names itself.
        let commands = try paths.map { p -> String in
            let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: p.settings)) as? [String: Any])
            return try #require((obj["statusLine"] as? [String: Any])?["command"] as? String)
        }
        #expect(commands[0] == StatusLineBridge.bridgeCommand(script: paths[0].script, previous: nil))
        #expect(commands[1].hasSuffix("--account=\(all[1].key!)"))
        #expect(StatusLineBridge.status(paths[1]) == .installed(previous: nil))

        // Run each command's arguments the way Claude Code would.
        for (command, five) in zip(commands, [20.0, 70.0]) {
            let args = Array(StatusLineBridge.shellWords(command).dropFirst(2))
            try run(script: paths[0].script, args: args, stdin: sample("s-\(Int(five))", five: five), outDir: readings, home: fx.root)
        }
        #expect(ClaudeStatusLine.read(from: paths[0].reading)?.limits.first?.usedPercent == 20)
        #expect(ClaudeStatusLine.read(from: paths[1].reading)?.limits.first?.usedPercent == 70)
        #expect(paths[1].reading.lastPathComponent == "claude-statusline-\(all[1].key!).json")

        let shown = Store.accountLimits(all, statusLines: [work.path: .installed(previous: nil)], readings: readings)
        #expect(shown.map(\.label) == ["Work"])
        #expect(shown.first?.limits.first?.usedPercent == 70)
        #expect(shown.first?.connected == true)

        // Removing one account's bridge leaves the other working: the shared script stays until the last goes.
        try StatusLineBridge.uninstall(paths[1], now: now)
        #expect(!FileManager.default.fileExists(atPath: paths[1].reading.path))
        #expect(FileManager.default.fileExists(atPath: paths[0].script.path))
        #expect(StatusLineBridge.status(paths[0]).isInstalled)
        try StatusLineBridge.uninstall(paths[0], now: now)
        #expect(!FileManager.default.fileExists(atPath: paths[0].script.path))
    }

    @Test func anAccountCommandWithAPreviousStatusLineSplitsBack() {
        let script = URL(fileURLWithPath: "/x/claude-statusline-bridge.sh")
        let command = StatusLineBridge.bridgeCommand(script: script, previous: "echo hi", account: "1a2b3c4d")
        #expect(command == "/bin/sh '/x/claude-statusline-bridge.sh' --account=1a2b3c4d 'echo hi'")
        #expect(StatusLineBridge.previousCommand(inBridgeCommand: command) == "echo hi")
        #expect(StatusLineBridge.previousCommand(inBridgeCommand: StatusLineBridge.bridgeCommand(script: script, previous: nil, account: "1a2b3c4d")) == nil)
    }
}
