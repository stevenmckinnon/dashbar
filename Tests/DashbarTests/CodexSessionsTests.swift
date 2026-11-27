import Foundation
import Testing
@testable import Dashbar

/// Live Codex sessions, from rollout logs shaped like Codex's. The text fields hold private words, to show none get out.
struct CodexSessionsTests {
    private static let secret = "SECRET-PROMPT"
    private let now = Date()

    private func stamp(_ ago: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(-ago))
    }

    private func meta(_ id: String, cwd: String = "/Users/demo/Development/shop", extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "session_id": id, "cwd": cwd, "originator": "codex_cli_rs", "source": "cli",
                                      "base_instructions": ["text": Self.secret]]
        payload.merge(extra) { _, new in new }
        return ["type": "session_meta", "timestamp": stamp(600), "payload": payload]
    }

    private func event(_ type: String, ago: TimeInterval, _ extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["type": type, "turn_id": "t1"]
        payload.merge(extra) { _, new in new }
        return ["type": "event_msg", "timestamp": stamp(ago), "payload": payload]
    }

    private func message(_ text: String) -> [String: Any] {
        ["type": "response_item", "timestamp": stamp(10), "payload": ["type": "message", "content": text]]
    }

    private func account(_ fx: Fixture, _ folder: String = ".codex", label: String = "Default") throws -> ResolvedAccount {
        let home = try fx.dir(folder)
        _ = try fx.dir(folder + "/sessions")
        return ResolvedAccount(kind: .codex, path: home.path, label: label, isDefault: folder == ".codex")
    }

    /// The path as the system reports an open file's: symlinks resolved (/var is /private/var).
    private func real(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.path }
        defer { free(p) }
        return String(cString: p)
    }

    private func process(_ urls: URL..., pid: Int32 = 100) -> CodexCollector.Process {
        .init(pid: pid, openFiles: urls.map(real))
    }

    private let log = ".codex/sessions/2026/11/27/rollout-2026-11-27T10-00-00-a.jsonl"

    @Test func aStartedTurnIsWorkingAndItsEndIsIdle() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let url = try fx.write(log, lines: [meta("a"), event("task_started", ago: 90), message(Self.secret)])
        let collector = CodexCollector()

        var reading = collector.read(accounts: [account], processes: [process(url)])
        var s = try #require(reading.sessions.first)
        #expect(s.id == "codex-a" && s.agent == .codex && s.pid == 100 && s.isBusy && s.account == nil)
        #expect(s.cwd == "/Users/demo/Development/shop" && s.entrypoint == "cli")
        #expect(abs(s.since.timeIntervalSince(now) + 90) < 1)
        #expect(reading.warning == nil)
        #expect(!"\(reading)".contains(Self.secret))

        try fx.append(url, lines: [event("task_complete", ago: 5, ["last_agent_message": Self.secret])])
        reading = collector.read(accounts: [account], processes: [process(url)])
        s = try #require(reading.sessions.first)
        #expect(!s.isBusy && !s.isWaiting && abs(s.since.timeIntervalSince(now) + 5) < 1)
    }

    @Test func anInterruptedTurnIsIdleAndTheNewNamesAreRead() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let url = try fx.write(log, lines: [meta("a"), event("turn_started", ago: 30)])
        let collector = CodexCollector()
        #expect(collector.read(accounts: [account], processes: [process(url)]).sessions.first?.isBusy == true)
        try fx.append(url, lines: [event("turn_aborted", ago: 2, ["reason": "interrupted"])])
        #expect(collector.read(accounts: [account], processes: [process(url)]).sessions.first?.isBusy == false)
    }

    @Test func aSessionWithNoTurnYetIsIdleWithoutAWarning() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let url = try fx.write(log, lines: [meta("a")])
        let reading = CodexCollector().read(accounts: [account], processes: [process(url)])
        #expect(reading.sessions.map(\.status) == ["idle"] && reading.warning == nil)
    }

    @Test func aMessageNamingAnEventIsNotOne() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let url = try fx.write(log, lines: [meta("a"), event("task_started", ago: 30), message(#""task_complete""#),
                                            ["type": "response_item", "payload": ["type": "task_complete"]]])
        #expect(CodexCollector().read(accounts: [account], processes: [process(url)]).sessions.first?.isBusy == true)
    }

    @Test func aTurnFarBackIsStillFound() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let filler = String(repeating: "x", count: 60_000)
        let url = try fx.write(log, lines: [meta("a"), event("task_started", ago: 300)] + (0..<12).map { _ in message(filler) })
        #expect(CodexCollector().read(accounts: [account], processes: [process(url)]).sessions.first?.isBusy == true)
    }

    @Test func aHalfWrittenLineWaitsForItsEnd() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let url = try fx.write(log, lines: [meta("a"), event("task_started", ago: 30)])
        let collector = CodexCollector()
        _ = collector.read(accounts: [account], processes: [process(url)])
        let end = String(decoding: try JSONSerialization.data(withJSONObject: event("task_complete", ago: 1)), as: UTF8.self)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        h.write(Data(end.prefix(40).utf8))
        #expect(collector.read(accounts: [account], processes: [process(url)]).sessions.first?.isBusy == true)
        h.write(Data((end.dropFirst(40) + "\n").utf8))
        #expect(collector.read(accounts: [account], processes: [process(url)]).sessions.first?.isBusy == false)
    }

    @Test func subagentsAndClosedOrForeignFilesAreNotSessions() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let spawned = try fx.write(".codex/sessions/rollout-b.jsonl",
                                   lines: [meta("b", extra: ["source": ["subagent": ["thread_spawn": [:]]]])])
        let child = try fx.write(".codex/sessions/rollout-c.jsonl", lines: [meta("c", extra: ["parent_thread_id": "a"])])
        let elsewhere = try fx.write("other/rollout-d.jsonl", lines: [meta("d")])
        _ = try fx.write(".codex/sessions/rollout-e.jsonl", lines: [meta("e")])   // no process has it open
        let reading = CodexCollector().read(accounts: [account], processes: [process(spawned, child, elsewhere)])
        #expect(reading == CodexSessions.Reading())
    }

    @Test func oneAppServerHoldsSeveralSessionsAndAccountsAreNamed() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let personal = try account(fx)
        let work = try account(fx, ".codex-work", label: "Work")
        let a = try fx.write(".codex/sessions/rollout-a.jsonl", lines: [meta("a", extra: ["originator": "codex_vscode"])])
        let b = try fx.write(".codex-work/sessions/rollout-b.jsonl", lines: [meta("b"), event("task_started", ago: 3)])
        let reading = CodexCollector().read(accounts: [personal, work], processes: [process(a, b)])
        #expect(reading.sessions.map(\.id) == ["codex-b", "codex-a"])
        #expect(reading.sessions.map(\.account) == ["Work", "Default"])
        #expect(reading.sessions.last?.entrypoint == "vscode")
    }

    @Test func anUnknownFormatWarns() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let url = try fx.write(log, lines: [["type": "thread_header", "payload": [:]]])
        let reading = CodexCollector().read(accounts: [account], processes: [process(url)])
        #expect(reading.sessions.isEmpty && reading.warning == CodexSessions.formatWarning)

        // Turns run (tokens are reported) but under names Dashbar doesn't know.
        let renamed = try fx.write(".codex/sessions/rollout-f.jsonl",
                                   lines: [meta("f"), event("run_began", ago: 9), event("token_count", ago: 3)])
        #expect(CodexCollector().read(accounts: [account], processes: [process(renamed)]).warning == CodexSessions.formatWarning)
    }

    @Test func aDaemonsSessionTakesTheTerminalInItsFolder() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let account = try account(fx)
        let shop = real(try fx.dir("shop")), docs = real(try fx.dir("docs"))
        let a = try fx.write(".codex/sessions/rollout-a.jsonl", lines: [meta("a", cwd: shop)])
        let b = try fx.write(".codex/sessions/rollout-b.jsonl", lines: [meta("b", cwd: docs)])
        var daemon = process(a, b, pid: 50)
        daemon.isDaemon = true
        let terminal = CodexCollector.Process(pid: 60, openFiles: [], cwd: shop)
        let collector = CodexCollector()
        // Session b has no terminal and nothing running: the daemon still holding its log doesn't count.
        let reading = collector.read(accounts: [account], processes: [daemon, terminal])
        #expect(reading.sessions.map(\.id) == ["codex-a"] && reading.sessions.first?.pid == 60)
        // With no terminal left, only a running turn keeps a session, with no process of its own.
        try fx.append(b, lines: [event("task_started", ago: 1)])
        let closed = collector.read(accounts: [account], processes: [daemon])
        #expect(closed.sessions.map(\.id) == ["codex-b"] && closed.sessions.first?.pid == 0)
    }

    @Test func codexBinariesAreRecognised() {
        #expect(CodexSessions.isCodex(executable: "/opt/homebrew/bin/codex"))
        #expect(CodexSessions.isCodex(executable: "/x/codex-aarch64-apple-darwin"))
        #expect(!CodexSessions.isCodex(executable: "/Applications/Codex.app/Contents/MacOS/Codex"))
        #expect(!CodexSessions.isCodex(executable: "/x/codex-linux-sandbox"))
    }

    /// The real system call, on this test's own open file.
    @Test func openFilesAreListed() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = try fx.write("rollout-open.jsonl", lines: [meta("a")])
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        #expect(Proc.openFiles(getpid()).contains(real(url)))
    }

    @Test func hiddenCodexIsNotRead() {
        var read = false
        let out = Worker.otherSessions(ToolVisibility(hidden: [.codex]), codex: { read = true; return .init() },
                                       google: { GoogleLive() }, opencode: { [] }, copilot: { [] })
        #expect(!read && out.sessions.isEmpty)
    }
}
