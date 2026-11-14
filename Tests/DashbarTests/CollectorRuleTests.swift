import Foundation
import Testing
@testable import Dashbar

// MARK: - Live session files changing shape

@Suite struct SessionFormatTests {
    let me = Int(ProcessInfo.processInfo.processIdentifier)

    func write(_ object: [String: Any], _ name: String, in fx: Fixture) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: fx.root.appendingPathComponent(name))
    }

    @Test func todaysShapeReadsWithoutAWarning() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try write(["pid": me, "sessionId": "a", "cwd": "/Users/x/dev/a", "status": "busy"], "1.json", in: fx)
        let reading = ClaudeSessions.readChecked(dir: fx.root)
        #expect(reading.sessions.map(\.id) == ["a"])
        #expect(reading.warning == nil)
    }

    @Test func aRenamedProcessIDRaisesTheWarningInsteadOfNoAgents() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try write(["processId": me, "sessionId": "a", "cwd": "/Users/x/dev/a", "status": "busy"], "1.json", in: fx)
        let reading = ClaudeSessions.readChecked(dir: fx.root)
        #expect(reading.sessions.isEmpty)
        #expect(reading.warning == ClaudeSessions.formatWarning)
    }

    @Test func aRenamedStatusRaisesTheWarning() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try write(["pid": me, "sessionId": "a", "cwd": "/Users/x/dev/a", "state": "busy"], "1.json", in: fx)
        #expect(ClaudeSessions.readChecked(dir: fx.root).warning == ClaudeSessions.formatWarning)
    }

    @Test func endedSessionsAndHalfWrittenFilesAreNotAFormatChange() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try write(["pid": 999_999, "sessionId": "gone", "cwd": "/Users/x/dev/a", "status": "idle"], "1.json", in: fx)
        try Data("{\"pid\": 12".utf8).write(to: fx.root.appendingPathComponent("2.json"))
        let reading = ClaudeSessions.readChecked(dir: fx.root)
        #expect(reading.sessions.isEmpty)
        #expect(reading.warning == nil)
    }

    @Test func noSessionFolderIsNoWarning() {
        let reading = ClaudeSessions.readChecked(dir: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(reading == ClaudeSessions.Reading())
    }
}

// MARK: - Which listening processes are dev servers

@Suite struct DevServerRuleTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let command: String
        let cmdline: String
        var cwd = "/Users/x/dev/app"
        let isDev: Bool
        var testDescription: String { "\(command): \(cmdline)" }
    }

    static let cases: [Case] = [
        Case(command: "node", cmdline: "/opt/homebrew/bin/node /Users/x/dev/app/node_modules/.bin/next dev", isDev: true),
        Case(command: "bun", cmdline: "bun run dev", isDev: true),
        Case(command: "python3.12", cmdline: "/usr/local/bin/python3.12 -m http.server", isDev: true),
        Case(command: "Python", cmdline: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3 -m http.server", isDev: true),
        Case(command: "Python", cmdline: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3 app.py", isDev: true),
        Case(command: "postgres", cmdline: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16", isDev: true),
        Case(command: "com.docker.backend", cmdline: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", isDev: true),
        Case(command: "com.docke", cmdline: "", isDev: true),
        // The process name is a dev tool and the command line still says so.
        Case(command: "node", cmdline: "node server.js", isDev: true),
        // Helpers bundled inside Mac apps aren't dev servers.
        Case(command: "node", cmdline: "/Applications/Raycast.app/Contents/Resources/node/bin/node index.js", isDev: false),
        Case(command: "node", cmdline: "/Users/x/Library/Application Support/Code/node server.js", isDev: false),
        Case(command: "node", cmdline: "node helper.js", cwd: "/Users/x/Library/Application Support/Sync", isDev: false),
        // Renamed itself: the process name says node, the command line doesn't.
        Case(command: "node", cmdline: "Raycast Backend", isDev: false),
        Case(command: "rapportd", cmdline: "/usr/libexec/rapportd", isDev: false),
        Case(command: "ControlCenter", cmdline: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", isDev: false),
    ]

    @Test(arguments: cases) func classifies(_ c: Case) {
        #expect(Listeners.isDevServer(command: c.command, cmdline: c.cmdline, cwd: c.cwd) == c.isDev)
    }
}

// MARK: - Context reader doesn't relist the projects folder for a missing transcript

@Suite struct ContextMissTests {
    @Test func aMissingTranscriptIsLookedForAgainOnlyAfterAWhile() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let s = LiveSession(id: "late", pid: 1, name: "late", cwd: "/dev/late", status: "busy", since: Date(),
                            entrypoint: "cli", root: "/dev/late")
        let reader = ContextReader(projects: fx.root, missRetry: 60)
        let start = Date()
        #expect(reader.read([s], now: start).isEmpty)
        try fx.write("-p/late.jsonl", lines: [Fixture.claude(id: "1", input: 10, output: 10)])
        #expect(reader.read([s], now: start.addingTimeInterval(5)).isEmpty)          // still remembered as missing
        #expect(reader.read([s], now: start.addingTimeInterval(61))["late"]?.used == 20)
    }
}
