import Foundation

/// Invented data for screenshots, so README and website images never show real projects or sessions.
@MainActor
enum DemoData {
    static func apply(to store: Store) {
        let now = Date()
        func minutes(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        let home = "/Users/demo/Development"

        // Agents
        let sessions = [
            LiveSession(id: "s1", pid: 9001, name: "Add Stripe checkout and webhooks", cwd: "\(home)/storefront-web", status: "busy",
                        since: minutes(4), entrypoint: "cli", root: "\(home)/storefront-web"),
            LiveSession(id: "s2", pid: 9002, name: "Fix flaky invoice export test", cwd: "\(home)/billing-api", status: "idle",
                        since: minutes(38), entrypoint: "cli", root: "\(home)/billing-api"),
            LiveSession(id: "s3", pid: 9003, name: "Write docs for the plugin API", cwd: "\(home)/docs-site", status: "idle",
                        since: minutes(95), entrypoint: "claude-vscode", root: "\(home)/docs-site"),
            LiveSession(id: "s4", pid: 9004, name: "Migrate settings screen to SwiftUI", cwd: "\(home)/notes-ios", status: "idle",
                        since: minutes(170), entrypoint: "claude-desktop", root: "\(home)/notes-ios"),
        ]
        store.sessions = sessions
        store.contexts = [
            "s1": ContextInfo(used: 342_000, window: 1_000_000),
            "s2": ContextInfo(used: 118_000, window: 1_000_000),
            "s3": ContextInfo(used: 61_000, window: 1_000_000),
            "s4": ContextInfo(used: 204_000, window: 1_000_000),
        ].reduce(into: [String: ContextInfo]()) { out, pair in
            if let s = sessions.first(where: { $0.id == pair.key }) { out[s.id] = pair.value }
        }
        store.otherAgents = [AgentProcess(name: "Codex", count: 1)]

        // Servers
        func server(_ pid: Int32, _ port: Int, _ cmd: String, _ root: String?, mb: UInt64, upMinutes: Double,
                    idle: Bool = false, by: Int32? = nil) -> Listener {
            var l = Listener(pid: pid, port: port, command: cmd.split(separator: " ").first.map(String.init) ?? cmd, address: "127.0.0.1")
            l.cmdline = cmd
            l.isDev = true
            l.memory = mb * 1_048_576
            l.root = root
            l.cwd = root ?? ""
            l.started = minutes(upMinutes)
            l.isIdle = idle
            l.startedBy = by
            return l
        }
        store.listeners = [
            server(9101, 3000, "node next dev", "\(home)/storefront-web", mb: 412, upMinutes: 52, by: 9001),
            server(9102, 4000, "node server.js", "\(home)/billing-api", mb: 186, upMinutes: 60 * 20, idle: true),
            server(9103, 5173, "node vite", "\(home)/docs-site", mb: 144, upMinutes: 60 * 3, by: 9003),
            server(9104, 8888, "python jupyter-lab", "\(home)/ml-notebooks", mb: 238, upMinutes: 60 * 27, idle: true),
        ]
        store.spawned = [
            9001: SpawnedProcesses(count: 5, memory: 620 * 1_048_576, ports: [3000], names: ["node", "esbuild", "zsh"]),
            9003: SpawnedProcesses(count: 3, memory: 210 * 1_048_576, ports: [5173], names: ["node", "zsh"]),
        ]

        // Usage
        var today = TokenTotals(); today.input = 1_200_000; today.output = 640_000; today.cacheRead = 148_000_000; today.cacheWrite = 2_900_000; today.messages = 486
        var week = TokenTotals(); week.input = 5_100_000; week.output = 2_800_000; week.cacheRead = 668_000_000; week.cacheWrite = 11_000_000; week.messages = 2_310
        let dayTokens = [38, 91, 64, 120, 87, 15, 6, 102, 133, 96, 148, 119, 141, 152].map { $0 * 1_000_000 }
        let cal = Calendar.current
        let days = dayTokens.enumerated().map { i, t in
            let date = cal.date(byAdding: .day, value: i - 13, to: cal.startOfDay(for: now))!
            return DayPoint(id: "d\(i)", date: date, tokens: t, isToday: i == 13)
        }
        let hourTokens = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 31, 22, 47, 18, 28, 44].map { $0 * 1_000_000 }
        let hourStart = cal.dateInterval(of: .hour, for: now)!.start
        let hours = hourTokens.enumerated().map { i, t in
            HourPoint(id: hourStart.addingTimeInterval(Double(i - 23) * 3600), tokens: t, messages: t / 700_000, isNow: i == 23)
        }
        var claude = UsageSummary()
        claude.found = true
        claude.today = today; claude.week = week
        claude.last14 = days
        claude.last24 = hours
        claude.tokens24 = hourTokens.reduce(0, +)
        claude.sessions24 = 6
        claude.topProjects = [Ranked(name: "storefront-web", value: 92_000_000), Ranked(name: "billing-api", value: 38_000_000),
                              Ranked(name: "docs-site", value: 12_000_000), Ranked(name: "notes-ios", value: 6_000_000)]
        claude.topModels = [Ranked(name: "Opus 5.5", value: 112_000_000), Ranked(name: "Sonnet 5.5", value: 36_000_000)]
        store.claude = claude

        var codex = UsageSummary()
        codex.found = true
        var cToday = TokenTotals(); cToday.input = 410_000; cToday.output = 96_000; cToday.cacheRead = 9_000_000; cToday.messages = 42
        codex.today = cToday; codex.week = cToday
        codex.last14 = days.map { DayPoint(id: $0.id, date: $0.date, tokens: $0.tokens / 14, isToday: $0.isToday) }
        codex.last24 = hours.map { HourPoint(id: $0.id, tokens: $0.tokens / 14, messages: $0.messages / 14, isNow: $0.isNow) }
        codex.tokens24 = codex.last24.reduce(0) { $0 + $1.tokens }
        codex.sessions24 = 2
        codex.topProjects = [Ranked(name: "ml-notebooks", value: 9_000_000)]
        codex.topModels = [Ranked(name: "gpt-5-codex", value: 9_500_000)]
        store.codex = codex
        store.codexLimits = [
            RateLimit(label: "5h window", usedPercent: 21, resetsAt: now.addingTimeInterval(3.4 * 3600), window: 5 * 3600),
            RateLimit(label: "7d window", usedPercent: 34, resetsAt: now.addingTimeInterval(4.1 * 86400), window: 7 * 86400),
        ]
        store.usageLoading = false

        // Claude plan limits (only shown with the Labs setting, which --demo switches on in memory)
        store.claudePlan = ClaudePlanLimits.Result(limits: [
            RateLimit(label: "5-hour", usedPercent: 55, resetsAt: now.addingTimeInterval(2.2 * 3600), window: 5 * 3600),
            RateLimit(label: "Weekly", usedPercent: 38, resetsAt: now.addingTimeInterval(3.5 * 86400), window: 7 * 86400),
        ], plan: "Max 5x")

        // System
        var sys = SystemSnapshot()
        sys.cpu = 0.34; sys.cpuUser = 0.24; sys.cpuSystem = 0.10; sys.load = [3.1, 2.7, 2.4]; sys.cores = 12
        sys.memTotal = 36 * 1_073_741_824
        sys.memApp = 14 * 1_073_741_824; sys.memWired = 4 * 1_073_741_824; sys.memCompressed = 3 * 1_073_741_824
        sys.memUsed = sys.memApp + sys.memWired + sys.memCompressed
        sys.swapUsed = 512 * 1_048_576; sys.pressure = .normal
        sys.netDown = 2_400_000; sys.netUp = 180_000
        sys.gpu = 0.18
        sys.diskTotal = 994 * 1_000_000_000; sys.diskFree = 421 * 1_000_000_000
        sys.battery = 82; sys.charging = false; sys.onAC = false; sys.batteryMinutes = 5 * 60 + 20
        sys.uptime = 3 * 86400 + 4 * 3600
        sys.chip = "Apple M3 Pro"
        store.system = sys
        var history = SystemHistory()
        for i in 0..<SystemHistory.length {
            var s = sys
            let wave = sin(Double(i) / 4.0)
            s.cpu = max(0.04, min(0.9, 0.32 + 0.18 * wave + (i % 7 == 0 ? 0.2 : 0)))
            s.memUsed = UInt64(Double(sys.memUsed) * (0.97 + 0.03 * sin(Double(i) / 9)))
            s.gpu = max(0.02, 0.15 + 0.1 * sin(Double(i) / 5 + 1))
            s.netDown = max(20_000, 1_800_000 + 1_500_000 * sin(Double(i) / 3))
            s.netUp = max(5_000, 150_000 + 120_000 * sin(Double(i) / 6))
            history.append(s)
        }
        store.history = history
        store.cpuHistory = history.cpu
        store.topApps = [
            AppUsage(key: "xcode", name: "Xcode", appPath: "/Applications/Xcode.app", cpu: 0.092),
            AppUsage(key: "chrome", name: "Google Chrome", appPath: "/Applications/Google Chrome.app", cpu: 0.061),
            AppUsage(key: "code", name: "Visual Studio Code", appPath: "/Applications/Visual Studio Code.app", cpu: 0.044),
            AppUsage(key: "terminal", name: "Terminal", appPath: "/System/Applications/Utilities/Terminal.app", cpu: 0.018),
        ]

        // Clean-up
        store.cleanup = [
            CleanupItem(path: "\(home)/storefront-web/node_modules", kind: "node_modules", project: "storefront-web", size: 1_480_000_000),
            CleanupItem(path: "\(home)/billing-api/node_modules", kind: "node_modules", project: "billing-api", size: 920_000_000),
            CleanupItem(path: "\(home)/storefront-web/.next", kind: ".next", project: "storefront-web", size: 610_000_000),
            CleanupItem(path: "\(home)/docs-site/node_modules", kind: "node_modules", project: "docs-site", size: 540_000_000),
            CleanupItem(path: "\(home)/notes-ios/.build", kind: ".build", project: "notes-ios", size: 1_150_000_000),
            CleanupItem(path: "~/Library/Developer/Xcode/DerivedData", kind: "DerivedData", project: "Xcode", size: 2_300_000_000),
        ]
        store.cleanupScanned = true
        store.lastUpdated = now
    }
}
