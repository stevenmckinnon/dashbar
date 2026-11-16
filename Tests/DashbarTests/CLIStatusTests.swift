import Foundation
import Testing
@testable import Dashbar
import DashbarStatus

/// The status file the app saves for the `dashbar` command: what goes in it, and nothing else.
@Suite struct CLIStatusSnapshotTests {
    /// Every key the file may hold. A new field is added here on purpose, after checking it carries no prompt, title,
    /// session id, transcript text or sign-in.
    static let allowedKeys: Set<String> = [
        "schema", "generatedAt", "app", "warning", "sessions", "limits", "usageToday", "servers",
        "name", "version", "pid", "paused",
        "tool", "account", "workspace", "folder", "state", "since", "subagents",
        "provider", "plan", "readAt", "stale", "problem",
        "label", "window", "windowSeconds", "usedPercent", "resetsAt", "pace", "runsOutAt",
        "day", "tools", "input", "output", "cacheRead", "cacheWrite", "total",
        "port", "command", "title",
        // The widget's copy (`forWidget()`): counts of agents by state.
        "agents", "working", "needsYou", "idle",
    ]

    static func keys(_ value: Any) -> Set<String> {
        if let dict = value as? [String: Any] {
            return dict.reduce(into: Set(dict.keys)) { $0.formUnion(keys($1.value)) }
        }
        if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
        return []
    }

    @MainActor func demoJSON() throws -> (data: Data, text: String, store: Store) {
        let store = Store(demo: true)
        // A permission prompt with a command in it: the command must not reach the file.
        store.permissionRequests = [PermissionRequest(
            id: String(repeating: "e", count: 32), sessionId: "s2", cwd: "/Users/demo/Development/billing-api", tool: "Bash",
            input: ["command": "rm -rf secret-folder"], agentType: nil, created: Date(), expires: Date().addingTimeInterval(60), pid: 9002)]
        let snapshot = CLIStatus.snapshot(of: store, showsClaudeLimits: true)
        let data = try StatusSnapshot.encoder().encode(snapshot)
        return (data, String(decoding: data, as: UTF8.self), store)
    }

    @MainActor @Test func onlyAllowedFields() throws {
        let (data, _, _) = try demoJSON()
        let keys = Self.keys(try JSONSerialization.jsonObject(with: data))
        #expect(keys.subtracting(Self.allowedKeys).isEmpty, "unexpected keys: \(keys.subtracting(Self.allowedKeys))")
    }

    @MainActor @Test func noSessionIdsTitlesOrPrompts() throws {
        let (_, text, store) = try demoJSON()
        #expect(!store.sessions.isEmpty)
        for s in store.sessions {
            #expect(!text.contains("\"\(s.id)\""), "session id \(s.id) leaked")
            #expect(!text.contains(s.name), "session title \(s.name) leaked")
        }
        for subagent in store.subagents.values.flatMap({ $0 }) {
            #expect(!text.contains(subagent.description), "subagent task leaked")
        }
        #expect(!text.contains("rm -rf"))
        #expect(!text.contains("sessionId"))
        #expect(!text.contains(String(repeating: "e", count: 32)))
    }

    @MainActor @Test func demoStateReadsBack() throws {
        let (data, _, store) = try demoJSON()
        let snapshot = try StatusSnapshot.decoder().decode(StatusSnapshot.self, from: data)
        #expect(snapshot.schema == StatusSnapshot.currentSchema)
        #expect(snapshot.sessions.count == store.sessions.count)
        let working = try #require(snapshot.sessions.first { $0.workspace == "storefront-web" })
        #expect(working.state == .working)
        #expect(working.subagents == 3)
        #expect(working.folder == "/Users/demo/Development/storefront-web")
        #expect(snapshot.limits.contains { $0.provider == "claude" && !$0.limits.isEmpty })
        #expect(snapshot.limits.flatMap(\.limits).allSatisfy { $0.window == nil || $0.windowSeconds != nil })
        #expect(snapshot.usageToday?.tools.contains { $0.tool == "claude" && $0.total > 0 } == true)
        #expect(snapshot.servers.contains { $0.port > 0 })
    }

    @Test func permissionPromptIsItsOwnState() {
        let base = LiveSession(id: "x", pid: 1, name: "n", cwd: "/p", status: "waiting", since: Date(), entrypoint: "cli", root: "/p")
        var permission = base
        permission.waitingFor = "permission prompt"
        #expect(CLIStatus.state(permission) == .permission)
        #expect(CLIStatus.state(base) == .needsYou)
        let busy = LiveSession(id: "x", pid: 1, name: "n", cwd: "/p", status: "busy", since: Date(), entrypoint: "cli", root: "/p")
        #expect(CLIStatus.state(busy) == .working)
    }

    /// The tool works out pace itself (it can't link the app), so its rule must match `RateLimit.pace` everywhere.
    @Test func paceMatchesTheApp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows: [Double] = [5 * 3600, 7 * 86400]
        let shares: [Double] = [0, 1, 3, 10, 20, 35, 50, 65, 80, 95, 99.5, 100, 120]
        for window in windows {
            for elapsed in stride(from: 0.0, through: 1.05, by: 0.05) {
                for used in shares {
                    let resets = now.addingTimeInterval(window * (1 - elapsed))
                    let app = RateLimit(label: "x", usedPercent: used, resetsAt: resets, window: window).pace(now: now)
                    let tool = StatusSnapshot.Limit(label: "x", windowSeconds: window, usedPercent: used, resetsAt: resets).pace(now: now)
                    let expected: (StatusSnapshot.Pace, Date?)? = switch app {
                    case nil: nil
                    case .under?: (.under, nil)
                    case .onPace?: (.onPace, nil)
                    case .runsOut(let at)?: (.runsOut, at)
                    case .usedUp?: (.usedUp, nil)
                    }
                    #expect(tool?.pace == expected?.0 && tool?.runsOutAt == expected?.1,
                            "window \(window) elapsed \(elapsed) used \(used)")
                }
            }
        }
    }
}

/// Writing the file: only on change, atomically, readable only by you.
@Suite struct StatusSnapshotWriterTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dashbar-cli-\(UUID().uuidString)")
    var url: URL { folder.appendingPathComponent("CLI/status.json") }

    func snapshot(_ sessions: Int) -> StatusSnapshot {
        StatusSnapshot(generatedAt: Date(), app: .init(name: "Dashbar", version: "1", pid: 1),
                       sessions: (0..<sessions).map {
                           .init(tool: "claude", workspace: "w\($0)", folder: "/w\($0)", state: .idle,
                                 since: Date(timeIntervalSince1970: 1_800_000_000))
                       })
    }

    @Test func writesOnlyWhenTheContentChanges() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = StatusSnapshotWriter(url: url)
        #expect(writer.write(snapshot(1), now: Date(timeIntervalSince1970: 1)))
        #expect(!writer.write(snapshot(1), now: Date(timeIntervalSince1970: 2)), "only generatedAt differs")
        #expect(writer.write(snapshot(2), now: Date(timeIntervalSince1970: 3)))
        #expect(writer.writeCount == 2)
        let saved = try StatusSnapshot.decoder().decode(StatusSnapshot.self, from: Data(contentsOf: url))
        #expect(saved.sessions.count == 2)
        #expect(saved.generatedAt == Date(timeIntervalSince1970: 3))
        // A cache clean-up removed it: the next reading puts it back, even unchanged.
        try FileManager.default.removeItem(at: url)
        #expect(writer.write(snapshot(2), now: Date(timeIntervalSince1970: 4)))
    }

    @Test func privateFileInPrivateFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        StatusSnapshotWriter(url: url).write(snapshot(1))
        let file = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let dir = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(dir == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["status.json"], "no temporary file left behind")
    }

    @Test func eachCopyHasItsOwnFile() {
        let home = URL(fileURLWithPath: "/Users/demo")
        #expect(StatusSnapshot.fileURL(appName: "Dashbar", home: home).path == "/Users/demo/Library/Caches/Dashbar/CLI/status.json")
        #expect(StatusSnapshot.fileURL(appName: "Dashbar Local", home: home).path
                == "/Users/demo/Library/Caches/Dashbar Local/CLI/status.json")
    }
}

/// The `dashbar` command, run against fixture snapshots with a fixed clock.
@Suite struct DashbarCLITests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("dashbar-cli-home-\(UUID().uuidString)")

    static func minutes(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }

    static let fixture = StatusSnapshot(
        generatedAt: minutes(1),
        app: .init(name: "Dashbar", version: "0.7.1", pid: 4242),
        sessions: [
            .init(tool: "claude", workspace: "billing-api", folder: "/Users/demo/Development/billing-api", state: .permission,
                  since: minutes(2)),
            .init(tool: "claude", workspace: "storefront-web", folder: "/Users/demo/Development/storefront-web", state: .working,
                  since: minutes(4), subagents: 3),
            .init(tool: "gemini-cli", workspace: "docs-site", folder: "/Users/demo/Development/docs-site", state: .working,
                  since: minutes(12)),
            .init(tool: "claude", workspace: "notes-ios", folder: "/Users/demo/Development/notes-ios", state: .idle,
                  since: minutes(95)),
        ],
        limits: [
            .init(provider: "claude", plan: "Max 5x", readAt: minutes(3), limits: [
                .init(label: "5-hour", window: "5-hour", windowSeconds: 5 * 3600, usedPercent: 55,
                      resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60)),
                .init(label: "Weekly", window: "Weekly", windowSeconds: 7 * 86400, usedPercent: 31,
                      resetsAt: now.addingTimeInterval(4 * 86400 + 3600)),
            ]),
            .init(provider: "codex", readAt: minutes(30), limits: [
                .init(label: "5-hour", window: "5-hour", windowSeconds: 5 * 3600, usedPercent: 12,
                      resetsAt: now.addingTimeInterval(-600)),   // reset since: left out of the ranking
                .init(label: "Weekly", window: "Weekly", windowSeconds: 7 * 86400, usedPercent: 20,
                      resetsAt: now.addingTimeInterval(5 * 86400)),
            ]),
        ],
        usageToday: .init(day: "2027-01-15", tools: [
            .init(tool: "claude", name: "Claude", input: 1_000_000, output: 400_000, cacheRead: 11_000_000, cacheWrite: 0),
            .init(tool: "codex", name: "Codex", input: 3_100_000, output: 0, cacheRead: 0, cacheWrite: 0),
        ]),
        servers: [
            .init(workspace: "storefront-web", folder: "/Users/demo/Development/storefront-web", port: 3000, command: "node", pid: 4300),
            .init(workspace: "billing-api", folder: "/Users/demo/Development/billing-api", port: 8080, command: "python3", pid: 4301),
        ])

    func save(_ snapshot: StatusSnapshot, as copy: StatusSnapshot.Copy) throws {
        let url = StatusSnapshot.fileURL(appName: copy.appName, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StatusSnapshot.encoder().encode(snapshot).write(to: url)
    }

    /// Runs the command with `running` as the pids Dashbar copies are running under (4300 is the only live server).
    func run(_ args: [String], running: Set<Int32> = [4242], env: [String: String] = [:]) -> DashbarCLI.Output {
        let reader = StatusReader(home: home, isRunning: { pid, _ in running.contains(pid) })
        let format = StatusFormat(now: Self.now, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_GB"),
                                  isAlive: { $0 == 4300 })
        return DashbarCLI.run(args, context: .init(reader: reader, format: format, environment: env, version: "0.7.1 (Dashbar)"))
    }

    @Test func status() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try save(Self.fixture, as: .release)
        let out = run([])
        #expect(out.code == 0)
        #expect(out.stderr.isEmpty)
        #expect(out.stdout == """
        Needs you
          billing-api  Claude · needs permission · 2m
        Working
          storefront-web  Claude · 4m · 3 subagents
          docs-site       Gemini CLI · 12m
        Idle
          notes-ios  Claude · 1h 35m
        Plan limits
          Claude 5-hour  55% · resets in 2h 10m
          Claude Weekly  31% · resets Tue 09:00
          Codex Weekly   20% · resets Wed 08:00
          Codex 5-hour   reset since the last reading
        Today
          Claude 12.4M tokens · Codex 3.1M tokens
        Servers
          storefront-web  :3000 node

        """)
        #expect(run(["status"]) == out)
    }

    @Test func line() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try save(Self.fixture, as: .release)
        #expect(run(["line"]).stdout == "⚠ 1 needs you · 2 working · Claude 5h 55%\n")
        #expect(run(["line", "--ascii"]).stdout == "! 1 needs you | 2 working | Claude 5h 55%\n")
        let ascii = run(["line", "--ascii"]).stdout.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
    }

    @Test func lineWhenQuietOrAtRisk() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var quiet = Self.fixture
        quiet.sessions = quiet.sessions.map { var s = $0; s.state = .idle; return s }
        quiet.limits = []
        try save(quiet, as: .release)
        #expect(run(["line"]).stdout == "idle\n")
        quiet.sessions = []
        // 90% used 3 hours into 5: on course to run out.
        quiet.limits = [.init(provider: "codex", limits: [.init(label: "5-hour", window: "5-hour", windowSeconds: 5 * 3600,
                                                                 usedPercent: 90, resetsAt: Self.now.addingTimeInterval(2 * 3600))])]
        quiet.app.paused = true
        try save(quiet, as: .release)
        #expect(run(["line"]).stdout == "no agents · Codex 5h 90% ↑ · paused\n")
        #expect(run(["line", "--ascii"]).stdout == "no agents | Codex 5h 90% (!) | paused\n")
        let status = run(["status"]).stdout
        #expect(status.hasPrefix("Updates are paused in Dashbar, so this may be out of date.\nNo agents running.\n"))
        #expect(status.contains(#/\n  Codex 5-hour +90% · resets in 2h · runs out about 08:20\n/#))
    }

    @Test func jsonPassesTheSnapshotThrough() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try save(Self.fixture, as: .release)
        let out = run(["status", "--json"])
        #expect(out.code == 0)
        let decoded = try StatusSnapshot.decoder().decode(StatusSnapshot.self, from: Data(out.stdout.utf8))
        #expect(decoded == Self.fixture.withPaces(now: Self.now))
        #expect(decoded.limits[0].limits[0].pace == .onPace)
    }

    @Test func warningIsShownNotHidden() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var broken = Self.fixture
        broken.warning = "Couldn't read Claude Code's live sessions."
        broken.limits = [.init(provider: "claude", problem: "Open Claude Code to renew its sign-in.")]
        try save(broken, as: .release)
        let status = run([]).stdout
        #expect(status.hasPrefix("Warning: Couldn't read Claude Code's live sessions.\n"))
        #expect(status.contains(#/\n  Claude +Open Claude Code to renew its sign-in\.\n/#))
    }

    /// An account is named only while more than one of the tool's accounts shows up, as with only one set up.
    @Test func accountNamedOnlyWithMoreThanOne() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var one = Self.fixture
        one.sessions = one.sessions.map { var s = $0; if s.tool == "claude" { s.account = "Personal" }; return s }
        one.limits[0].account = "Personal"
        try save(one, as: .release)
        var status = run([]).stdout
        #expect(!status.contains("Personal"))
        #expect(status.contains("  storefront-web  Claude · 4m · 3 subagents\n"))
        #expect(status.contains("  Claude 5-hour  55%"))
        #expect(run(["line"]).stdout == "⚠ 1 needs you · 2 working · Claude 5h 55%\n")

        var two = one
        two.sessions[1].account = "Work"
        try save(two, as: .release)
        status = run([]).stdout
        #expect(status.contains("  storefront-web  Claude · Work · 4m · 3 subagents\n"))
        #expect(status.contains("  billing-api  Claude · Personal · needs permission · 2m\n"))
        #expect(status.contains("  Claude · Personal 5-hour  55%"))
        #expect(run(["line"]).stdout == "⚠ 1 needs you · 2 working · Claude · Personal 5h 55%\n")

        // The second account only in the plan limits counts too.
        var limitsOnly = one
        limitsOnly.limits.append(.init(provider: "claude", account: "Work", limits: [.init(label: "5-hour", usedPercent: 3)]))
        try save(limitsOnly, as: .release)
        #expect(run([]).stdout.contains("  billing-api  Claude · Personal · needs permission · 2m\n"))
    }

    @Test func toolsWithNoTokensTodayAreLeftOut() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var some = Self.fixture
        some.usageToday?.tools.append(.init(tool: "google", name: "Antigravity CLI", input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        some.usageToday?.tools[1] = .init(tool: "codex", name: "Codex", input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        try save(some, as: .release)
        var status = run([]).stdout
        #expect(status.contains("Today\n  Claude 12.4M tokens\nServers"))
        #expect(!status.contains("0 tokens"))

        var none = some
        none.usageToday?.tools[0] = .init(tool: "claude", name: "Claude", input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        try save(none, as: .release)
        status = run([]).stdout
        #expect(!status.contains("Today"))
        #expect(!status.contains("tokens"))
    }

    /// Rows at 0% fold as in the panel: only in a list of more than three, and never the tightest.
    @Test func limitsAtZeroFoldOnlyInALongList() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        func weekly(_ label: String, _ used: Double) -> StatusSnapshot.Limit {
            .init(label: label, window: "Weekly", windowSeconds: 7 * 86400, usedPercent: used,
                  resetsAt: Self.now.addingTimeInterval(6 * 86400))
        }
        var short = Self.fixture
        short.limits = [.init(provider: "antigravity", limits: [weekly("Gemini · Weekly", 0), weekly("Argon · Weekly", 5),
                                                                 weekly("Other models · Weekly", 0)])]
        try save(short, as: .release)
        var status = run([]).stdout
        #expect(status.contains("  Antigravity Gemini · Weekly        0%"))
        #expect(status.contains("  Antigravity Other models · Weekly  0%"))
        #expect(!status.contains("more at 0%"))

        var long = short
        long.limits[0].limits += [weekly("Flash · Weekly", 0), weekly("Image · Weekly", 12)]
        try save(long, as: .release)
        status = run([]).stdout
        #expect(status.contains("""
        Plan limits
          Antigravity Image · Weekly  12% · resets Thu 08:00
          Antigravity Argon · Weekly  5% · resets Thu 08:00
          Antigravity                 3 more at 0%

        """))

        // All at 0%: the first keeps its row.
        var idle = long
        idle.limits[0].limits = idle.limits[0].limits.map { var l = $0; l.usedPercent = 0; return l }
        try save(idle, as: .release)
        status = run([]).stdout
        #expect(status.contains("  Antigravity Gemini · Weekly  0%"))
        #expect(status.contains("  Antigravity                  4 more at 0%"))
        #expect(run(["line"]).stdout.hasSuffix("Antigravity wk 0%\n"))
    }

    /// Servers read as the panel's Servers card: one row per process, Docker named as such, two ports and a count.
    @Test func serversAsThePanelNamesThem() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var fixture = Self.fixture
        fixture.servers = [
            .init(workspace: "storefront-web", folder: "/Users/demo/Development/storefront-web", port: 3000, command: "node",
                  pid: 4300, title: "storefront-web"),
            .init(workspace: nil, folder: nil, port: 55433, command: "com.docker.backend", pid: 4400, title: "Docker container"),
            .init(workspace: nil, folder: nil, port: 55432, command: "com.docker.backend", pid: 4400, title: "Docker container"),
            .init(workspace: nil, folder: nil, port: 5173, command: "vite", pid: 4500, title: "vite"),
            .init(workspace: nil, folder: nil, port: 8000, command: "python3", pid: 4600),
            .init(workspace: nil, folder: nil, port: 8001, command: "python3", pid: 4600),
            .init(workspace: nil, folder: nil, port: 8002, command: "python3", pid: 4600),
            .init(workspace: nil, folder: nil, port: 8003, command: "python3", pid: 4600),
        ]
        try save(fixture, as: .release)
        let reader = StatusReader(home: home, isRunning: { pid, _ in pid == 4242 })
        let format = StatusFormat(now: Self.now, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_GB"),
                                  isAlive: { _ in true })
        let status = DashbarCLI.run([], context: .init(reader: reader, format: format, environment: [:], version: nil)).stdout
        #expect(status.hasSuffix("""
        Servers
          storefront-web    :3000 node
          Docker container  :55432 :55433 com.docker.backend
          vite              :5173
          python3           :8000 :8001 +2

        """))

        // A snapshot from before titles: Docker is still named, never by its process name.
        var old = fixture
        old.servers = old.servers.map { var s = $0; s.title = nil; return s }
        #expect(old.servers[1].name == "Docker container")
        #expect(old.servers[0].name == "storefront-web")
    }

    /// The tool folds limit rows itself (it can't link the app), so its rule must match `RateLimit.fold`.
    @Test func foldMatchesTheApp() {
        let shares: [Double] = [0, 0.4, 0.6, 5, 40]
        for count in 1...6 {
            var combos: [[Double]] = [[]]
            for _ in 0..<count { combos = combos.flatMap { c in shares.map { c + [$0] } } }
            for used in combos {
                let app = RateLimit.fold(used.enumerated().map { RateLimit(label: "\($0.offset)", usedPercent: $0.element, resetsAt: nil) })
                let tool = StatusSnapshot.Limit.folded(used.enumerated().map { .init(label: "\($0.offset)", usedPercent: $0.element) })
                #expect(Set(app.folded.map { Int($0.label)! }) == tool, "\(used)")
            }
        }
        #expect(StatusSnapshot.Limit.foldAbove == RateLimit.foldAbove)
    }

    @Test func tokensFromAnotherDayAreLeftOut() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var old = Self.fixture
        old.usageToday?.day = "2027-01-14"
        try save(old, as: .release)
        #expect(!run([]).stdout.contains("Today"))
    }

    @Test func missingSnapshot() {
        let out = run([])
        #expect(out.code == 2)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr == "dashbar: Dashbar hasn't saved a status yet. Open Dashbar 0.7.1 or later and try again.\n")
        #expect(run(["--local"]).stderr.hasPrefix("dashbar: Dashbar Local hasn't saved a status yet."))
    }

    @Test func appNotRunning() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try save(Self.fixture, as: .release)
        let out = run(["line"], running: [])
        #expect(out.code == 3)
        #expect(out.stdout.isEmpty, "never print old figures as if current")
        #expect(out.stderr == "dashbar: Dashbar isn't running, so there's nothing current to show (last update 1m ago). Open Dashbar and try again.\n")
    }

    @Test func unreadableSnapshot() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let url = StatusSnapshot.fileURL(appName: "Dashbar", home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"schema\": 99}".utf8).write(to: url)
        let newer = run([])
        #expect(newer.code == 4)
        #expect(newer.stderr.contains("a newer Dashbar wrote it"))
        try Data("not json".utf8).write(to: url)
        #expect(run([]).code == 4)
    }

    @Test func choosesTheRunningCopy() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var local = Self.fixture
        local.app = .init(name: "Dashbar Local", version: "0.7.0-3-gabc1234", pid: 5555)
        local.sessions = []
        try save(Self.fixture, as: .release)
        try save(local, as: .local)
        // Both running: the release, unless asked for the local build.
        #expect(run(["line"], running: [4242, 5555]).stdout.hasPrefix("⚠ 1 needs you"))
        #expect(run(["line", "--local"], running: [4242, 5555]).stdout.hasPrefix("no agents"))
        #expect(run(["line"], running: [4242, 5555], env: ["DASHBAR_LOCAL": "1"]).stdout.hasPrefix("no agents"))
        // Only the local build running: it is used.
        #expect(run(["line"], running: [5555]).stdout.hasPrefix("no agents"))
        // Asked for the local build while only the release runs: say so rather than show the release.
        #expect(run(["line", "--local"], running: [4242]).code == 3)
    }

    @Test func statusFileOverride() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("demo.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try StatusSnapshot.encoder().encode(Self.fixture).write(to: file)
        #expect(run(["line"], running: [], env: ["DASHBAR_STATUS_FILE": file.path]).code == 0)
    }

    @Test func arguments() {
        #expect(run(["--help"]).stdout.hasPrefix("Usage: dashbar"))
        #expect(run(["--version"]).stdout == "dashbar 0.7.1 (Dashbar)\n")
        for bad in [["--nope"], ["limits"], ["line", "--json"], ["status", "--ascii"], ["status", "line"]] {
            let out = run(bad)
            #expect(out.code == 64, "\(bad)")
            #expect(out.stderr.contains("dashbar --help"))
        }
    }

    @Test func bundleVersionFollowsTheSymlink() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let contents = home.appendingPathComponent("Dashbar.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleShortVersionString": "0.7.1", "CFBundleName": "Dashbar"]
        plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        let tool = contents.appendingPathComponent("Helpers/dashbar")
        FileManager.default.createFile(atPath: tool.path, contents: Data())
        let link = home.appendingPathComponent("dashbar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        #expect(DashbarCLI.bundleVersion(executable: link) == "0.7.1 (Dashbar)")
        #expect(DashbarCLI.bundleVersion(executable: home.appendingPathComponent("nowhere")) == nil)
    }
}
