import Foundation
import Testing
@testable import Dashbar

// All of these work on throwaway folders. Nothing here reads or writes the real ~/.claude.

// MARK: - Installing into Claude Code's settings

@Suite struct StatusLineInstallerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func paths(_ fx: Fixture) throws -> StatusLineBridge.Paths {
        let claude = try fx.dir("claude")
        return StatusLineBridge.Paths(settings: claude.appendingPathComponent("settings.json"),
                                      support: fx.root.appendingPathComponent("support"),
                                      readings: try fx.dir("caches"))
    }

    func settings(_ p: StatusLineBridge.Paths) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: p.settings)) as? [String: Any])
    }

    @Test func withNoSettingsFileItCreatesOneAndRemovingLeavesNoStatusLine() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        #expect(StatusLineBridge.status(p) == .notInstalled(current: nil))
        try StatusLineBridge.install(p, now: now)
        let line = try #require(try settings(p)["statusLine"] as? [String: Any])
        #expect(line["type"] as? String == "command")
        #expect((line["command"] as? String) == StatusLineBridge.bridgeCommand(script: p.script, previous: nil))
        #expect(StatusLineBridge.status(p) == .installed(previous: nil))
        #expect(FileManager.default.isExecutableFile(atPath: p.script.path))

        try StatusLineBridge.uninstall(p, now: now)
        #expect(try settings(p)["statusLine"] == nil)
        #expect(!FileManager.default.fileExists(atPath: p.script.path))
        #expect(StatusLineBridge.status(p) == .notInstalled(current: nil))
    }

    @Test func anExistingStatusLineIsKeptRunAndPutBackByteForByte() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let original = """
        {
          "model": "opus",
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh --theme 'dark'",
            "padding": 2
          },
          "permissions": { "allow": ["Bash(ls:*)"] }
        }

        """
        try original.write(to: p.settings, atomically: true, encoding: .utf8)
        #expect(StatusLineBridge.status(p) == .notInstalled(current: "~/.claude/statusline.sh --theme 'dark'"))

        try StatusLineBridge.install(p, now: now)
        let after = try settings(p)
        let line = try #require(after["statusLine"] as? [String: Any])
        let command = try #require(line["command"] as? String)
        #expect(line["padding"] as? Int == 2)   // the user's other status line settings stay
        #expect(StatusLineBridge.previousCommand(inBridgeCommand: command) == "~/.claude/statusline.sh --theme 'dark'")
        #expect(after["model"] as? String == "opus")
        #expect((after["permissions"] as? [String: Any]) != nil)
        #expect(StatusLineBridge.status(p) == .installed(previous: "~/.claude/statusline.sh --theme 'dark'"))
        // The rest of the file is untouched: the key stays where it was.
        let text = try String(contentsOf: p.settings, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"model\": \"opus\",\n  \"statusLine\": {\n    \"type\": \"command\",\n"))
        #expect(text.hasSuffix("  },\n  \"permissions\": { \"allow\": [\"Bash(ls:*)\"] }\n}\n"))

        try StatusLineBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == original)
    }

    @Test func aFileWithoutAStatusLineRoundTripsExactly() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let original = "{\n    \"theme\": \"dark\",\n    \"env\": {\"A\": \"1\"}\n}\n"
        try original.write(to: p.settings, atomically: true, encoding: .utf8)
        try StatusLineBridge.install(p, now: now)
        let text = try String(contentsOf: p.settings, encoding: .utf8)
        #expect(text.contains(",\n    \"statusLine\": {\n      \"type\": \"command\""))   // indented like its neighbours
        try StatusLineBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == original)
    }

    @Test func invalidJSONIsRefusedAndLeftAlone() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let broken = "{ \"model\": \"opus\", }}"
        try broken.write(to: p.settings, atomically: true, encoding: .utf8)
        if case .unreadable = StatusLineBridge.status(p) {} else { Issue.record("expected unreadable") }
        #expect(throws: StatusLineBridge.Failure.self) { try StatusLineBridge.install(p, now: now) }
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == broken)
        try "[1, 2]".write(to: p.settings, atomically: true, encoding: .utf8)
        #expect(throws: StatusLineBridge.Failure.self) { try StatusLineBridge.install(p, now: now) }
    }

    @Test func installingTwiceChangesNothingAndNeverWrapsItself() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        try #"{"statusLine": {"type": "command", "command": "echo hi"}}"#.write(to: p.settings, atomically: true, encoding: .utf8)
        try StatusLineBridge.install(p, now: now)
        let once = try String(contentsOf: p.settings, encoding: .utf8)
        try StatusLineBridge.install(p, now: now.addingTimeInterval(60))
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == once)
        #expect(StatusLineBridge.status(p) == .installed(previous: "echo hi"))
        try StatusLineBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == #"{"statusLine": {"type": "command", "command": "echo hi"}}"#)
    }

    @Test func withoutTheRecordRemovingRebuildsTheStatusLineFromTheCommand() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        try #"{"statusLine": {"type": "command", "command": "printf 'it''s'", "padding": 1}}"#.write(to: p.settings, atomically: true, encoding: .utf8)
        try StatusLineBridge.install(p, now: now)
        try FileManager.default.removeItem(at: p.record)
        #expect(StatusLineBridge.status(p) == .installed(previous: "printf 'it''s'"))
        try StatusLineBridge.uninstall(p, now: now)
        let line = try #require(try settings(p)["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == "printf 'it''s'")
        #expect(line["padding"] as? Int == 1)
    }

    @Test func aStatusLineTheUserChangedSinceIsNotTouched() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        try StatusLineBridge.install(p, now: now)
        let mine = #"{"statusLine": {"type": "command", "command": "my-new-line"}}"#
        try mine.write(to: p.settings, atomically: true, encoding: .utf8)
        #expect(StatusLineBridge.status(p) == .notInstalled(current: "my-new-line"))
        try StatusLineBridge.uninstall(p, now: now)
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == mine)
    }

    @Test func aBackupIsKeptBeforeEachChange() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        try #"{"a": 1}"#.write(to: p.settings, atomically: true, encoding: .utf8)
        try StatusLineBridge.install(p, now: now)
        let backups = try FileManager.default.contentsOfDirectory(atPath: p.backups.path)
        #expect(backups.count == 1)
        let saved = try String(contentsOf: p.backups.appendingPathComponent(try #require(backups.first)), encoding: .utf8)
        #expect(saved == #"{"a": 1}"#)
    }

    @Test func aSymlinkedSettingsFileStaysASymlink() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = try paths(fx)
        let real = fx.root.appendingPathComponent("dotfiles-settings.json")
        try #"{"a": 1}"#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: p.settings, withDestinationURL: real)
        try StatusLineBridge.install(p, now: now)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: p.settings.path)) != nil)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("statusLine"))
    }

    @Test func noClaudeFolderIsExplained() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let p = StatusLineBridge.Paths(settings: fx.root.appendingPathComponent("missing/settings.json"),
                                       support: fx.root.appendingPathComponent("support"))
        #expect(throws: StatusLineBridge.Failure.self) { try StatusLineBridge.install(p, now: now) }
    }

    @Test func claudeConfigDirIsHonoured() {
        let p = StatusLineBridge.Paths.default(environment: ["CLAUDE_CONFIG_DIR": "/tmp/other-claude"])
        #expect(p.settings.path == "/tmp/other-claude/settings.json")
        #expect(StatusLineBridge.Paths.default(environment: [:]).settings.path.hasSuffix("/.claude/settings.json"))
    }

    @Test func commandsQuoteAndSplitBack() {
        let script = URL(fileURLWithPath: "/Users/x/Library/Application Support/Dashbar/claude-statusline-bridge.sh")
        let previous = #"bash -c 'echo "$HOME" it'"'"'s'"#
        let command = StatusLineBridge.bridgeCommand(script: script, previous: previous)
        #expect(command.hasPrefix("/bin/sh '/Users/x/Library/Application Support/Dashbar/claude-statusline-bridge.sh' '"))
        #expect(StatusLineBridge.previousCommand(inBridgeCommand: command) == previous)
        #expect(StatusLineBridge.previousCommand(inBridgeCommand: StatusLineBridge.bridgeCommand(script: script, previous: nil)) == nil)
    }
}

// MARK: - The bridge script itself

@Suite struct StatusLineScriptTests {
    struct Run { let output: String; let status: Int32 }

    func run(_ fx: Fixture, stdin: String, previous: String? = nil, outDir: URL? = nil) throws -> Run {
        let script = fx.root.appendingPathComponent("bridge.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            try StatusLineBridge.script.write(to: script, atomically: true, encoding: .utf8)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + (previous.map { [$0] } ?? [])
        p.environment = ["HOME": fx.root.path, "PATH": "/usr/bin:/bin",
                         "DASHBAR_STATUSLINE_DIR": (outDir ?? fx.root.appendingPathComponent("caches")).path]
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

    func sample(session: String = "abc-123", apiMs: Int = 2300) -> String {
        """
        {"cwd":"/Users/x/secret-project","session_id":"\(session)","transcript_path":"/Users/x/.claude/projects/t.jsonl",
         "model":{"id":"claude-opus-5-5","display_name":"Opus"},"cost":{"total_cost_usd":0.01,"total_api_duration_ms":\(apiMs)},
         "context_window":{"current_usage":null,"used_percentage":null},
         "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                        "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
        """
    }

    @Test func savesOnlyTheLimitsAndPrintsNothingWithoutAPreviousStatusLine() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let r = try run(fx, stdin: sample())
        #expect(r.status == 0)
        #expect(r.output.isEmpty)
        let file = fx.root.appendingPathComponent("caches/claude-statusline.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("secret-project"))
        #expect(!text.contains("abc-123"))
        #expect(!text.contains("transcript"))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(obj.keys) == ["version", "written_at", "rate_limits"])
        let written = try #require((obj["written_at"] as? NSNumber)?.doubleValue)
        #expect(abs(written - Date().timeIntervalSince1970) < 60)
        let parsed = try #require(ClaudeStatusLine.parse(Data(text.utf8)))
        #expect(parsed.limits.map(\.label) == ["5-hour", "Weekly"])
        #expect(parsed.limits.first?.usedPercent == 23.5)
    }

    @Test func runsThePreviousStatusLineWithTheSameInputAndKeepsItsOutputAndStatus() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let input = sample()
        let echoed = try run(fx, stdin: input, previous: "cat")
        #expect(echoed.output == input + "\n")
        let styled = try run(fx, stdin: input, previous: #"printf '\033[32mline one\033[0m\nline two\n'"#)
        #expect(styled.output == "\u{1B}[32mline one\u{1B}[0m\nline two\n")
        let failing = try run(fx, stdin: input, previous: "echo nope; exit 3")
        #expect(failing.output == "nope\n")
        #expect(failing.status == 3)
    }

    @Test func aFolderItCantWriteNeverBreaksTheStatusLine() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let blocker = fx.root.appendingPathComponent("not-a-folder")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let r = try run(fx, stdin: sample(), previous: "echo mine", outDir: blocker)
        #expect(r.output == "mine\n")
        #expect(r.status == 0)
    }

    @Test func withoutRateLimitsTheLastReadingIsKept() throws {
        let fx = try Fixture(); defer { fx.remove() }
        _ = try run(fx, stdin: sample())
        let file = fx.root.appendingPathComponent("caches/claude-statusline.json")
        let before = try Data(contentsOf: file)
        let r = try run(fx, stdin: #"{"session_id":"new","model":{"display_name":"Opus"}}"#, previous: "echo ok")
        #expect(r.output == "ok\n")
        #expect(try Data(contentsOf: file) == before)
        let garbage = try run(fx, stdin: "not json at all")
        #expect(garbage.status == 0)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func reRunsWithoutANewReplyDontRefreshTheTime() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let file = fx.root.appendingPathComponent("caches/claude-statusline.json")
        _ = try run(fx, stdin: sample(apiMs: 100))
        try FileManager.default.removeItem(at: file)
        _ = try run(fx, stdin: sample(apiMs: 100))   // same session, no new API time: an idle rerun
        #expect(!FileManager.default.fileExists(atPath: file.path))
        _ = try run(fx, stdin: sample(apiMs: 900))   // a new reply
        #expect(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        _ = try run(fx, stdin: sample(session: "other", apiMs: 100))   // another session's reply
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func sessionMarkersNeverNameTheSession() throws {
        let fx = try Fixture(); defer { fx.remove() }
        _ = try run(fx, stdin: sample(session: "4f1c2a9e-7b3d-4e55-9a10-c0ffee123456", apiMs: 100))
        _ = try run(fx, stdin: sample(session: "other-session", apiMs: 100))
        let seen = fx.root.appendingPathComponent("caches/claude-statusline-sessions")
        let names = try FileManager.default.contentsOfDirectory(atPath: seen.path).sorted()
        #expect(names.count == 2)
        for name in names {
            #expect(name.count == 16 && name.allSatisfy(\.isHexDigit))
            #expect(!name.contains("4f1c2a9e") && !name.contains("other"))
            #expect(try String(contentsOf: seen.appendingPathComponent(name), encoding: .utf8) == "100")
        }
        // The same session always maps to the same marker, so an idle rerun is still recognised.
        _ = try run(fx, stdin: sample(session: "other-session", apiMs: 100))
        #expect(try FileManager.default.contentsOfDirectory(atPath: seen.path).count == 2)
    }

    @Test func neverRunsItselfAsThePreviousStatusLine() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let r = try run(fx, stdin: sample(), previous: "/bin/sh '/x/claude-statusline-bridge.sh'")
        #expect(r.output.isEmpty)
        #expect(r.status == 0)
    }
}

// MARK: - Reading what the bridge saved

@Suite struct StatusLineReaderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func data(_ windows: String, written: TimeInterval = 1_799_999_000) -> Data {
        Data(#"{"version":1,"written_at":\#(Int(written)),"rate_limits":\#(windows)}"#.utf8)
    }

    @Test func readsBothWindowsWithTheirLengths() throws {
        let r = try #require(ClaudeStatusLine.parse(data(#"{"seven_day":{"used_percentage":41.2,"resets_at":1800300000},"five_hour":{"used_percentage":23.5,"resets_at":1800010000}}"#)))
        #expect(r.writtenAt == Date(timeIntervalSince1970: 1_799_999_000))
        #expect(r.limits.map(\.label) == ["5-hour", "Weekly"])
        #expect(r.limits[0].window == TimeInterval(5 * 3600))
        #expect(r.limits[1].window == TimeInterval(7 * 86400))
        #expect(r.limits[0].resetsAt == Date(timeIntervalSince1970: 1_800_010_000))
        #expect(!r.unrecognised)
    }

    @Test func anAbsentWindowIsSimplyLeftOut() throws {
        let r = try #require(ClaudeStatusLine.parse(data(#"{"seven_day":{"used_percentage":12,"resets_at":1800300000}}"#)))
        #expect(r.limits.map(\.label) == ["Weekly"])
        let empty = try #require(ClaudeStatusLine.parse(data("{}")))
        #expect(empty.limits.isEmpty)
        #expect(!empty.unrecognised)
    }

    @Test func windowsThatHaveResetAreDropped() throws {
        let r = try #require(ClaudeStatusLine.parse(data(#"{"five_hour":{"used_percentage":90,"resets_at":1799990000},"seven_day":{"used_percentage":41,"resets_at":1800300000}}"#)))
        #expect(r.limits.count == 2)
        #expect(r.current(now: now).map(\.label) == ["Weekly"])
    }

    @Test func aSpendLimitUsesItsPeriod() throws {
        let r = try #require(ClaudeStatusLine.parse(data(#"{"spend_limit":{"used_percentage":62.8,"resets_at":1800300000,"used_usd":314.12,"limit_usd":500,"period":"monthly"}}"#)))
        #expect(r.limits.first?.label == "Spend limit")
        #expect(r.limits.first?.window == TimeInterval(30 * 86400))
    }

    @Test func aShapeItDoesntKnowIsAWarningNotZero() throws {
        let r = try #require(ClaudeStatusLine.parse(data(#"{"five_hour":{"pct":3}}"#)))
        #expect(r.unrecognised)
        #expect(ClaudeStatusLine.parse(Data("garbage".utf8))?.unrecognised == true)
        #expect(ClaudeStatusLine.parse(Data()) == nil)
    }

    @Test func theAgeShowsOnceTheReadingIsAWhileOld() {
        #expect(ClaudeStatusLine.ageLine(writtenAt: now.addingTimeInterval(-120), now: now) == nil)
        #expect(ClaudeStatusLine.ageLine(writtenAt: now.addingTimeInterval(-25 * 60), now: now)
                == "Updated 25m ago · refreshes after your next Claude Code reply")
    }
}

// MARK: - Choosing and refreshing the reading

final class FakeEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ClaudePlanLimits.Result] = []
    private(set) var calls = 0

    func enqueue(_ r: ClaudePlanLimits.Result) { lock.lock(); queue.append(r); lock.unlock() }

    func next() -> ClaudePlanLimits.Result {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return queue.isEmpty ? ClaudePlanLimits.Result(problem: "nothing queued") : queue.removeFirst()
    }
}

@MainActor
final class MonitorHarness {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var shared: ClaudePlanLimits.Shared?
    var statusLine: ClaudeStatusLine.Reading?
    var scheduled: [TimeInterval] = []
    let endpoint = FakeEndpoint()
    lazy var monitor = ClaudePlanMonitor(dependencies: .init(
        fetch: { [endpoint] in endpoint.next() },
        refreshSignIn: { nil },
        now: { [unowned self] in self.now },
        loadShared: { [unowned self] in self.shared },
        saveShared: { [unowned self] in self.shared = $0 },
        readStatusLine: { [unowned self] in self.statusLine },
        after: { [unowned self] delay, _ in self.scheduled.append(delay) }))

    func limits(_ used: Double, resetsIn: TimeInterval = 3600) -> [RateLimit] {
        [RateLimit(label: "5-hour", usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn), window: 5 * 3600)]
    }

    func good(_ used: Double, at: Date? = nil) -> ClaudePlanLimits.Result {
        ClaudePlanLimits.Result(limits: limits(used), plan: "Pro", fetchedAt: at ?? now)
    }
}

@MainActor
@Suite struct ClaudePlanMonitorTests {
    @Test func aFreshStatusLineReadingIsShownAndTheEndpointIsntAsked() async {
        let h = MonitorHarness()
        h.statusLine = ClaudeStatusLine.Reading(writtenAt: h.now.addingTimeInterval(-60), limits: h.limits(30))
        h.monitor.setStatusLineEnabled(true)
        await h.monitor.setEndpointEnabled(true)?.value
        #expect(h.endpoint.calls == 0)
        #expect(h.monitor.result?.source == .statusLine)
        #expect(h.monitor.result?.limits.first?.usedPercent == 30)
    }

    @Test func anOldStatusLineReadingLosesToANewerEndpointReading() async {
        let h = MonitorHarness()
        h.statusLine = ClaudeStatusLine.Reading(writtenAt: h.now.addingTimeInterval(-600), limits: h.limits(30))
        h.endpoint.enqueue(h.good(45))
        h.monitor.setStatusLineEnabled(true)
        await h.monitor.setEndpointEnabled(true)?.value
        #expect(h.endpoint.calls == 1)
        #expect(h.monitor.result?.source == .endpoint)
        #expect(h.monitor.result?.limits.first?.usedPercent == 45)
        // A reply arrives: the status line is newer again and wins.
        h.now = h.now.addingTimeInterval(30)
        h.statusLine = ClaudeStatusLine.Reading(writtenAt: h.now, limits: h.limits(47))
        h.monitor.statusLineChanged()
        #expect(h.monitor.result?.source == .statusLine)
        #expect(h.monitor.result?.plan == "Pro")   // the plan name, which only the endpoint knows, carries over
    }

    @Test func anEndpointProblemDoesntHideAStatusLineReading() async {
        let h = MonitorHarness()
        h.statusLine = ClaudeStatusLine.Reading(writtenAt: h.now.addingTimeInterval(-900), limits: h.limits(30))
        h.endpoint.enqueue(ClaudePlanLimits.Result(problem: "Claude didn't accept the sign-in.", needsSignIn: true))
        h.monitor.setStatusLineEnabled(true)
        await h.monitor.setEndpointEnabled(true)?.value
        #expect(h.monitor.result?.source == .statusLine)
        #expect(h.monitor.result?.problem == nil)
    }

    @Test func statusLineOnlyWithEveryWindowResetShowsNothingUntilTheNextReply() {
        let h = MonitorHarness()
        h.statusLine = ClaudeStatusLine.Reading(writtenAt: h.now.addingTimeInterval(-7200), limits: h.limits(80, resetsIn: -60))
        h.monitor.setStatusLineEnabled(true)
        #expect(h.monitor.result == nil)
        #expect(h.endpoint.calls == 0)
    }

    @Test func anUnrecognisedStatusLineFileWarns() {
        let h = MonitorHarness()
        h.statusLine = ClaudeStatusLine.Reading(writtenAt: h.now, limits: [], unrecognised: true)
        h.monitor.setStatusLineEnabled(true)
        #expect(h.monitor.result?.problem == ClaudeStatusLine.unrecognisedMessage)
    }

    @Test func aTemporaryFailureBacksOffAndRetryWaits() async {
        let h = MonitorHarness()
        h.endpoint.enqueue(ClaudePlanLimits.Result(problem: ClaudePlanLimits.rateLimitedMessage, transient: true))
        await h.monitor.setEndpointEnabled(true)?.value
        #expect(h.monitor.retryAt == h.now.addingTimeInterval(120))
        #expect(h.shared?.retryAt == h.now.addingTimeInterval(120))   // the other copy waits too
        #expect(h.scheduled == [121])
        #expect(h.monitor.refresh(force: true) == nil)                 // Retry during the wait doesn't ask
        #expect(h.endpoint.calls == 1)
        // The second failure in a row waits longer.
        h.now = h.now.addingTimeInterval(130)
        h.endpoint.enqueue(ClaudePlanLimits.Result(problem: "Anthropic's usage service had a problem (HTTP 503).", transient: true))
        await h.monitor.refresh(force: true)?.value
        #expect(h.monitor.retryAt == h.now.addingTimeInterval(240))
        // Success clears the wait.
        h.now = h.now.addingTimeInterval(250)
        h.endpoint.enqueue(h.good(50))
        await h.monitor.refresh(force: true)?.value
        #expect(h.monitor.retryAt == nil)
        #expect(h.monitor.result?.limits.first?.usedPercent == 50)
        #expect(h.shared?.limits.first?.usedPercent == 50)
    }

    @Test func aFailureKeepsTheLastGoodReadingMarkedStale() async {
        let h = MonitorHarness()
        h.endpoint.enqueue(h.good(40))
        await h.monitor.setEndpointEnabled(true)?.value
        h.now = h.now.addingTimeInterval(400)
        h.endpoint.enqueue(ClaudePlanLimits.Result(problem: ClaudePlanLimits.rateLimitedMessage, transient: true))
        await h.monitor.refresh()?.value
        #expect(h.monitor.result?.limits.first?.usedPercent == 40)
        #expect(h.monitor.result?.stale == .rateLimited)
    }

    @Test func theOtherCopysRecentReadingIsUsedInsteadOfAsking() async {
        let h = MonitorHarness()
        h.shared = ClaudePlanLimits.Shared(fetchedAt: h.now.addingTimeInterval(-30), plan: "Max 5x", limits: h.limits(61))
        await h.monitor.setEndpointEnabled(true)?.value
        #expect(h.endpoint.calls == 0)
        #expect(h.monitor.result?.plan == "Max 5x")
        #expect(h.monitor.result?.limits.first?.usedPercent == 61)
    }

    @Test func theOtherCopysBackoffIsWaitedOut() async {
        let h = MonitorHarness()
        h.shared = ClaudePlanLimits.Shared(fetchedAt: h.now.addingTimeInterval(-900), limits: h.limits(20),
                                           retryAt: h.now.addingTimeInterval(200))
        await h.monitor.setEndpointEnabled(true)?.value
        #expect(h.endpoint.calls == 0)
        #expect(h.monitor.result?.stale == .rateLimited)
        #expect(h.monitor.retryAt == h.now.addingTimeInterval(200))
    }

    @Test func aForcedRefreshAsksWhenTheReadingIsOverAMinuteOld() async {
        let h = MonitorHarness()
        h.endpoint.enqueue(h.good(10))
        await h.monitor.setEndpointEnabled(true)?.value
        h.now = h.now.addingTimeInterval(30)
        #expect(h.monitor.refresh() == nil)              // the regular check skips a reading this young
        #expect(h.monitor.refresh(force: true) == nil)   // so does Refresh: the shared reading is under a minute old
        h.now = h.now.addingTimeInterval(60)
        h.endpoint.enqueue(h.good(12))
        await h.monitor.refresh(force: true)?.value
        #expect(h.endpoint.calls == 2)
        #expect(h.monitor.result?.limits.first?.usedPercent == 12)
    }

    @Test func turningItOffMidRequestDiscardsTheAnswer() async {
        let h = MonitorHarness()
        h.endpoint.enqueue(h.good(70))
        let task = h.monitor.setEndpointEnabled(true)
        #expect(h.monitor.loading)
        h.monitor.setEndpointEnabled(false)
        await task?.value
        #expect(h.endpoint.calls == 1)
        #expect(h.monitor.result == nil)
        #expect(!h.monitor.loading)
        #expect(h.shared == nil)
    }

    @Test func preferringTheFresherReading() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = ClaudePlanLimits.Result(limits: [RateLimit(label: "5-hour", usedPercent: 1, resetsAt: nil)], fetchedAt: now.addingTimeInterval(-60), source: .statusLine)
        let newer = ClaudePlanLimits.Result(limits: [RateLimit(label: "5-hour", usedPercent: 2, resetsAt: nil)], fetchedAt: now)
        #expect(ClaudePlanMonitor.preferred(statusLine: older, endpoint: newer)?.source == .endpoint)
        #expect(ClaudePlanMonitor.preferred(statusLine: nil, endpoint: nil) == nil)
        let problem = ClaudePlanLimits.Result(problem: "x")
        #expect(ClaudePlanMonitor.preferred(statusLine: nil, endpoint: problem)?.problem == "x")
        #expect(ClaudePlanMonitor.preferred(statusLine: older, endpoint: problem)?.source == .statusLine)
    }
}
