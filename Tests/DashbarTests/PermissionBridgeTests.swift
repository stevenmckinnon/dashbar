import Foundation
import Testing
@testable import Dashbar

// All of these work on throwaway folders. Nothing here reads or writes the real ~/.claude, and nothing runs Claude Code.

private func paths(_ fx: Fixture) throws -> PermissionBridge.Paths {
    let claude = try fx.dir("claude")
    return PermissionBridge.Paths(settings: claude.appendingPathComponent("settings.json"),
                                  support: fx.root.appendingPathComponent("support"))
}

private func settings(_ p: PermissionBridge.Paths) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: p.settings)) as? [String: Any])
}

private func permissionGroups(_ p: PermissionBridge.Paths) throws -> [[String: Any]] {
    let hooks = try #require(try settings(p)["hooks"] as? [String: Any])
    return try #require(hooks["PermissionRequest"] as? [[String: Any]])
}

// MARK: - Installing the hook

@Suite struct PermissionInstallerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func withNoSettingsFileItAddsTheHookAndRemovingLeavesNoHooks() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        #expect(PermissionBridge.status(p) == .notInstalled)
        try PermissionBridge.install(p, now: now)
        let groups = try permissionGroups(p)
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] as? String == "*")
        let handler = try #require((groups[0]["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command")
        #expect(handler["command"] as? String == PermissionBridge.command(p))
        #expect(handler["timeout"] as? Int == PermissionBridge.hookTimeout)
        #expect(PermissionBridge.status(p) == .installed)
        #expect(FileManager.default.isExecutableFile(atPath: p.script.path))
        let mode = try FileManager.default.attributesOfItem(atPath: p.queue.appendingPathComponent("requests").path)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        try PermissionBridge.uninstall(p, now: now)
        #expect(try settings(p)["hooks"] == nil)
        #expect(!FileManager.default.fileExists(atPath: p.script.path))
        #expect(!FileManager.default.fileExists(atPath: p.queue.path))
        #expect(PermissionBridge.status(p) == .notInstalled)
    }

    @Test func theUsersOwnHooksAreKeptAndTheFileRoundTripsByteForByte() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let original = """
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [{ "type": "command", "command": "~/bin/check.sh" }]
              }
            ],
            "PermissionRequest": [
              {
                "matcher": "Edit",
                "hooks": [
                  { "type": "command", "command": "~/bin/my-approver.sh" }
                ]
              }
            ]
          },
          "permissions": { "allow": ["Bash(ls:*)"] }
        }

        """
        try original.write(to: p.settings, atomically: true, encoding: .utf8)
        try PermissionBridge.install(p, now: now)

        let groups = try permissionGroups(p)
        #expect(groups.count == 2)
        #expect(((groups[0]["hooks"] as? [[String: Any]])?.first?["command"]) as? String == "~/bin/my-approver.sh")
        #expect(((groups[1]["hooks"] as? [[String: Any]])?.first?["command"]) as? String == PermissionBridge.command(p))
        let hooks = try #require(try settings(p)["hooks"] as? [String: Any])
        #expect(hooks["PreToolUse"] != nil)
        #expect(try settings(p)["model"] as? String == "opus")
        let text = try String(contentsOf: p.settings, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"PreToolUse\": ["))
        #expect(text.contains("      },\n      {\n        \"matcher\": \"*\",\n"))   // lined up with the user's group

        try PermissionBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == original)
    }

    @Test func otherHookEventsWithoutPermissionRequestRoundTrip() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let original = "{\n    \"hooks\": {\n        \"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"say done\"}]}]\n    }\n}\n"
        try original.write(to: p.settings, atomically: true, encoding: .utf8)
        try PermissionBridge.install(p, now: now)
        #expect(try permissionGroups(p).count == 1)
        #expect((try settings(p)["hooks"] as? [String: Any])?["Stop"] != nil)
        try PermissionBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == original)
    }

    @Test func anEmptyHooksSettingIsPutBackRatherThanRemoved() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let original = "{\n  \"hooks\": {},\n  \"theme\": \"dark\"\n}\n"
        try original.write(to: p.settings, atomically: true, encoding: .utf8)
        try PermissionBridge.install(p, now: now)
        #expect(try permissionGroups(p).count == 1)
        try PermissionBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == original)
    }

    @Test func installingTwiceAddsOneHook() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        try PermissionBridge.install(p, now: now)
        let once = try String(contentsOf: p.settings, encoding: .utf8)
        try PermissionBridge.install(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == once)
        #expect(PermissionBridge.ourHandlerCount(in: try settings(p)["hooks"]) == 1)
    }

    @Test func aHandlerTheUserMovedIntoTheirOwnGroupIsTakenOutAlone() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let command = PermissionBridge.command(p)
        let mixed: [String: Any] = ["hooks": ["PermissionRequest": [[
            "matcher": "*",
            "hooks": [["type": "command", "command": "~/bin/log.sh"], ["type": "command", "command": command]],
        ]]]]
        try JSONSerialization.data(withJSONObject: mixed).write(to: p.settings)
        #expect(PermissionBridge.status(p) == .installed)
        try PermissionBridge.uninstall(p, now: now)
        let groups = try permissionGroups(p)
        #expect(groups.count == 1)
        #expect((groups[0]["hooks"] as? [[String: Any]])?.map { $0["command"] as? String } == ["~/bin/log.sh"])
    }

    @Test func invalidJSONIsRefusedAndLeftAlone() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let broken = "{ \"hooks\": { \"PermissionRequest\": [ }"
        try broken.write(to: p.settings, atomically: true, encoding: .utf8)
        if case .unreadable = PermissionBridge.status(p) {} else { Issue.record("expected unreadable") }
        #expect(throws: StatusLineBridge.Failure.self) { try PermissionBridge.install(p, now: now) }
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == broken)
    }

    @Test func aBackupIsKeptBeforeTheChange() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        try "{\"theme\": \"dark\"}\n".write(to: p.settings, atomically: true, encoding: .utf8)
        try PermissionBridge.install(p, now: now)
        let backups = try FileManager.default.contentsOfDirectory(atPath: p.support.appendingPathComponent("Backups").path)
        #expect(backups.contains { $0.hasPrefix("claude-settings-") })
    }

    @Test func itSitsBesideTheStatusLineBridgeWithoutDisturbingIt() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let line = StatusLineBridge.Paths(settings: p.settings, support: p.support, readings: try fx.dir("caches"))
        try StatusLineBridge.install(line, now: now)
        try PermissionBridge.install(p, now: now)
        #expect(StatusLineBridge.status(line).isInstalled)
        try PermissionBridge.uninstall(p, now: now)
        #expect(StatusLineBridge.status(line).isInstalled)
        #expect(FileManager.default.fileExists(atPath: line.script.path))
    }

    @Test func claudeConfigDirIsHonoured() {
        let p = PermissionBridge.Paths.default(environment: ["CLAUDE_CONFIG_DIR": "/tmp/alt-claude"])
        #expect(p.settings.path == "/tmp/alt-claude/settings.json")
    }
}

// MARK: - The script, end to end

@Suite struct PermissionScriptTests {
    struct Run { let output: String; let status: Int32; let seconds: TimeInterval }

    func setUp(_ fx: Fixture, wait: Int? = 5) throws -> (PermissionBridge.Paths, PermissionQueue) {
        let p = try paths(fx)
        try PermissionBridge.writeScript(p)
        try PermissionBridge.prepareQueue(p)
        let queue = PermissionQueue(root: p.queue)
        if let wait { queue.heartbeat(wait: wait) }
        return (p, queue)
    }

    /// Runs the script with `stdin`; `whileWaiting` gets each request file's contents once it appears.
    func run(_ p: PermissionBridge.Paths, dir: URL? = nil, stdin: String,
             whileWaiting: ((PermissionRequest) throws -> Void)? = nil) throws -> Run {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [p.script.path]
        proc.environment = ["HOME": p.support.deletingLastPathComponent().path, "PATH": "/usr/bin:/bin",
                            "DASHBAR_PERMISSION_DIR": (dir ?? p.queue).path]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        let start = Date()
        try proc.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        if let whileWaiting {
            let queue = PermissionQueue(root: p.queue)
            var request: PermissionRequest?
            for _ in 0..<100 where request == nil {
                request = queue.read().first
                if request == nil { Thread.sleep(forTimeInterval: 0.05) }
            }
            try whileWaiting(try #require(request))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Run(output: String(decoding: data, as: UTF8.self), status: proc.terminationStatus, seconds: Date().timeIntervalSince(start))
    }

    func sample(tool: String = "Bash", input: String = #"{"command":"rm -rf node_modules","description":"Remove node_modules"}"#,
                event: String = "PermissionRequest") -> String {
        """
        {"session_id":"abc-123","transcript_path":"/Users/x/.claude/projects/p/abc-123.jsonl","cwd":"/Users/x/shop",
         "permission_mode":"default","hook_event_name":"\(event)","tool_name":"\(tool)","tool_input":\(input),
         "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],
         "behavior":"allow","destination":"localSettings"}]}
        """
    }

    func decision(_ output: String) throws -> [String: Any] {
        let o = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let specific = try #require(o["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        return try #require(specific["decision"] as? [String: Any])
    }

    func leftovers(_ p: PermissionBridge.Paths) -> [String] {
        ["requests", "decisions"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: p.queue.appendingPathComponent($0).path)) ?? [] }
    }

    @Test func allowPrintsTheDocumentedAllowAndCleansUp() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx)
        let run = try run(p, stdin: sample()) { request in
            #expect(request.tool == "Bash")
            #expect(request.sessionId == "abc-123")
            #expect(request.cwd == "/Users/x/shop")
            #expect(request.detail() == "rm -rf node_modules")
            #expect(request.why == "Remove node_modules")
            let file = p.queue.appendingPathComponent("requests/\(request.id).json").path
            #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
            try queue.answer(request.id, .allow)
        }
        #expect(run.status == 0)
        let d = try decision(run.output)
        #expect(d["behavior"] as? String == "allow")
        #expect(d.count == 1)   // no updatedInput, no updatedPermissions: allow once, nothing saved
        #expect(leftovers(p).isEmpty)
    }

    @Test func denyPrintsADenyWithAReason() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx)
        let run = try run(p, stdin: sample()) { try queue.answer($0.id, .deny) }
        let d = try decision(run.output)
        #expect(d["behavior"] as? String == "deny")
        #expect(d["message"] as? String == PermissionBridge.denyMessage)
        #expect(d["interrupt"] == nil)
        #expect(leftovers(p).isEmpty)
    }

    @Test func handingItBackToTheTerminalPrintsNothingAtOnce() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx, wait: 60)
        let run = try run(p, stdin: sample()) { try queue.answer($0.id, .terminal) }
        #expect(run.output.isEmpty)
        #expect(run.status == 0)
        #expect(run.seconds < 5)
        #expect(leftovers(p).isEmpty)
    }

    @Test func noAnswerTimesOutWithNoOutput() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, _) = try setUp(fx, wait: 5)
        let run = try run(p, stdin: sample())
        #expect(run.output.isEmpty)
        #expect(run.status == 0)
        #expect(run.seconds >= 4.5 && run.seconds < 12)
        #expect(leftovers(p).isEmpty)
    }

    @Test func dashbarNotRunningPrintsNothingAtOnce() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, _) = try setUp(fx, wait: nil)   // no heartbeat
        let run = try run(p, stdin: sample())
        #expect(run.output.isEmpty)
        #expect(run.status == 0)
        #expect(run.seconds < 2)
        #expect(leftovers(p).isEmpty)
    }

    @Test func aStaleHeartbeatCountsAsNotRunning() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: queue.alive.path)
        let run = try run(p, stdin: sample())
        #expect(run.output.isEmpty)
        #expect(run.seconds < 2)
    }

    @Test func aMissingFolderPrintsNothing() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, _) = try setUp(fx)
        let run = try run(p, dir: fx.root.appendingPathComponent("nowhere"), stdin: sample())
        #expect(run.output.isEmpty)
        #expect(run.status == 0)
    }

    @Test func dashbarQuittingMidWaitStopsTheWait() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx, wait: 60)
        let run = try run(p, stdin: sample()) { _ in queue.goodbye() }
        #expect(run.output.isEmpty)
        #expect(run.seconds < 5)
    }

    @Test func anotherCopysHeartbeatKeepsItWaitingWhenOneQuits() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx, wait: 60)
        // The other copy (release beside a local build) has its own heartbeat.
        let other = p.queue.appendingPathComponent("alive.fun.dashbar.app.other")
        try Data("wait=60\n".utf8).write(to: other)
        let run = try run(p, stdin: sample()) { request in
            queue.goodbye()
            Thread.sleep(forTimeInterval: 2.5)   // past a heartbeat check
            try queue.answer(request.id, .allow)
        }
        #expect(try decision(run.output)["behavior"] as? String == "allow")
    }

    @Test func otherEventsAndInteractiveToolsAreLeftToClaudeCode() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, _) = try setUp(fx)
        for stdin in [sample(event: "PreToolUse"), sample(tool: "AskUserQuestion", input: #"{"questions":[]}"#),
                      sample(tool: "ExitPlanMode", input: #"{"plan":"x"}"#), "not json at all", ""] {
            let run = try run(p, stdin: stdin)
            #expect(run.output.isEmpty)
            #expect(run.seconds < 2)
        }
        #expect(leftovers(p).isEmpty)
    }

    @Test func fileContentsNeverReachTheRequestFile() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx)
        let input = #"{"file_path":"/Users/x/shop/secret.env","content":"API_KEY=hunter2"}"#
        _ = try run(p, stdin: sample(tool: "Write", input: input)) { request in
            let raw = try String(contentsOf: p.queue.appendingPathComponent("requests/\(request.id).json"), encoding: .utf8)
            #expect(!raw.contains("hunter2"))
            #expect(request.action == "Write a file")
            #expect(request.detail() == "/Users/x/shop/secret.env")
            try queue.answer(request.id, .deny)
        }
    }

    @Test func aForgedAnswerForAnotherIdIsIgnored() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let (p, queue) = try setUp(fx, wait: 5)
        let run = try run(p, stdin: sample()) { _ in
            try Data("allow\n".utf8).write(to: queue.decisions.appendingPathComponent(String(repeating: "0", count: 32)))
        }
        #expect(run.output.isEmpty)   // timed out: only its own id's answer counts
    }
}

// MARK: - Reading requests

@Suite struct PermissionRequestTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func json(id: String = String(repeating: "a", count: 32), tool: String = "Bash", input: [String: Any] = ["command": "npm test"],
              created: TimeInterval? = nil, wait: Int = 60, pid: Int32 = 4242) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": 1, "id": id, "pid": pid, "created": created ?? now.timeIntervalSince1970 - 10, "wait": wait,
            "tool_name": tool, "tool_input": input, "session_id": "s1", "cwd": "/Users/x/shop/web", "agent_type": "",
        ] as [String: Any])
    }

    @Test func parsesARequest() throws {
        let r = try #require(PermissionRequest.parse(json()))
        #expect(r.tool == "Bash")
        #expect(r.sessionId == "s1")
        #expect(r.action == "Run a command")
        #expect(r.detail() == "npm test")
        #expect(r.agentType == nil)
        #expect(r.expires == r.created.addingTimeInterval(60))
        #expect(r.oneLine == "Run a command: npm test")
    }

    @Test func rejectsBadIdsAndMissingTools() {
        #expect(PermissionRequest.parse(json(id: "../../etc/passwd")) == nil)
        #expect(PermissionRequest.parse(json(id: String(repeating: "A", count: 32))) == nil)
        #expect(PermissionRequest.parse(json(tool: "")) == nil)
        #expect(PermissionRequest.parse(Data("nope".utf8)) == nil)
    }

    @Test func summarisesEachKindOfTool() throws {
        let edit = try #require(PermissionRequest.parse(json(tool: "Edit", input: ["file_path": "/etc/hosts"])))
        #expect(edit.action == "Edit a file")
        #expect(edit.detail() == "/etc/hosts")
        let fetch = try #require(PermissionRequest.parse(json(tool: "WebFetch", input: ["url": "https://example.com", "prompt": "x"])))
        #expect(fetch.detail() == "https://example.com")
        let mcp = try #require(PermissionRequest.parse(json(tool: "mcp__github__create_issue", input: ["title": "Bug", "labels": ["a"]])))
        #expect(mcp.action == "Use create_issue from github")
        #expect(mcp.detail() == "labels: [\"a\"]\ntitle: Bug")
        let long = try #require(PermissionRequest.parse(json(input: ["command": String(repeating: "x", count: 1000)])))
        #expect(long.detail()!.count == 400)
        let tall = try #require(PermissionRequest.parse(json(input: ["command": (1...20).map(String.init).joined(separator: "\n")])))
        #expect(tall.detail()!.components(separatedBy: "\n").count == 7)
    }

    @Test func expiredOrOrphanedRequestsAreNotLive() throws {
        let r = try #require(PermissionRequest.parse(json(created: now.timeIntervalSince1970 - 10, wait: 60)))
        #expect(r.isLive(now: now, alive: { _ in true }))
        #expect(!r.isLive(now: now.addingTimeInterval(51), alive: { _ in true }))
        #expect(!r.isLive(now: now, alive: { _ in false }))
    }

    @Test func theWaitIsClamped() throws {
        let r = try #require(PermissionRequest.parse(json(wait: 99_999)))
        #expect(r.expires.timeIntervalSince(r.created) == Double(PermissionBridge.maxWait))
    }

    @Test func theQueueDropsAndTidiesDeadRequests() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let queue = PermissionQueue(root: try fx.dir("q"))
        _ = try fx.dir("q/requests"); _ = try fx.dir("q/decisions")
        let live = String(repeating: "1", count: 32), dead = String(repeating: "2", count: 32), old = String(repeating: "3", count: 32)
        try json(id: live, pid: 1001).write(to: queue.requests.appendingPathComponent(live + ".json"))
        try json(id: dead, pid: 1002).write(to: queue.requests.appendingPathComponent(dead + ".json"))
        try json(id: old, created: now.timeIntervalSince1970 - 1000, pid: 1001).write(to: queue.requests.appendingPathComponent(old + ".json"))
        let found = queue.read(now: now, alive: { $0 == 1001 })
        #expect(found.map(\.id) == [live])
        let left = try FileManager.default.contentsOfDirectory(atPath: queue.requests.path)
        #expect(left == [live + ".json"])
    }

    @Test func answeringARequestThatIsGoneSaysSo() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let queue = PermissionQueue(root: try fx.dir("q"))
        _ = try fx.dir("q/requests"); _ = try fx.dir("q/decisions")
        #expect(throws: PermissionQueue.Failure.self) { try queue.answer(String(repeating: "a", count: 32), .allow) }
        #expect(throws: PermissionQueue.Failure.self) { try queue.answer("../x", .allow) }
    }

    @Test func pendingRequestsMarkTheirSessionAsNeedingPermission() {
        let s = LiveSession(id: "s1", pid: 1, name: "n", cwd: "/x", status: "busy", since: now, entrypoint: "cli", root: "/x")
        let other = LiveSession(id: "s2", pid: 2, name: "m", cwd: "/y", status: "idle", since: now, entrypoint: "cli", root: "/y")
        let r = PermissionRequest.parse(json())!
        let marked = PermissionRequest.marking([s, other], with: [r], now: now)
        #expect(marked[0].isWaiting && marked[0].waitingFor == "permission prompt")
        #expect(marked[0].since == r.created)
        #expect(marked[1] == other)
    }
}
