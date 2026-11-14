import Foundation

/// Invented data for screenshots, so README and website images never show real projects or sessions.
@MainActor
enum DemoData {
    /// DASHBAR_DEMO_SUBAGENTS_OPEN=1 renders the panel's subagent line opened into its list.
    nonisolated static var subagentsOpen: Bool { ProcessInfo.processInfo.environment["DASHBAR_DEMO_SUBAGENTS_OPEN"] != nil }

    static func apply(to store: Store) {
        let now = Date()
        func minutes(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        let home = "/Users/demo/Development"

        // Agents
        // DASHBAR_DEMO_WAITING=1 makes billing-api's session stop for permission, to render the "needs you" state.
        // DASHBAR_DEMO_PERMISSION=1 does the same with the request answerable from Dashbar (the permission hook).
        let permission = ProcessInfo.processInfo.environment["DASHBAR_DEMO_PERMISSION"] != nil
        let waiting = permission || ProcessInfo.processInfo.environment["DASHBAR_DEMO_WAITING"] != nil
        let sessions = [
            LiveSession(id: "s1", pid: 9001, name: "Add Stripe checkout and webhooks", cwd: "\(home)/storefront-web", status: "busy",
                        since: minutes(4), entrypoint: "cli", root: "\(home)/storefront-web"),
            LiveSession(id: "s2", pid: 9002, name: "Fix flaky invoice export test", cwd: "\(home)/billing-api",
                        status: waiting ? "waiting" : "idle", since: minutes(permission ? 0.4 : waiting ? 2 : 38), entrypoint: "cli",
                        root: "\(home)/billing-api", waitingFor: waiting ? "permission prompt" : nil),
            LiveSession(id: "s3", pid: 9003, name: "Write docs for the plugin API", cwd: "\(home)/docs-site", status: "idle",
                        since: minutes(95), entrypoint: "claude-vscode", root: "\(home)/docs-site"),
            LiveSession(id: "s4", pid: 9004, name: "Migrate settings screen to SwiftUI", cwd: "\(home)/notes-ios", status: "idle",
                        since: minutes(170), entrypoint: "claude-desktop", root: "\(home)/notes-ios"),
        ]
        store.sessions = sessions
        if permission {
            store.permissionRequests = [PermissionRequest(
                id: String(repeating: "d", count: 32), sessionId: "s2", cwd: "\(home)/billing-api", tool: "Bash",
                input: ["command": "npm test -- --runInBand src/invoices/export.test.ts",
                        "description": "Run the invoice export tests"],
                agentType: nil, created: minutes(0.4), expires: minutes(0.4).addingTimeInterval(60), pid: 9002)]
        }
        store.contexts = [
            "s1": ContextInfo(used: 342_000, window: 1_000_000),
            "s2": ContextInfo(used: 118_000, window: 1_000_000),
            "s3": ContextInfo(used: 61_000, window: 1_000_000),
            "s4": ContextInfo(used: 204_000, window: 1_000_000),
        ].reduce(into: [String: ContextInfo]()) { out, pair in
            if let s = sessions.first(where: { $0.id == pair.key }) { out[s.id] = pair.value }
        }
        store.otherAgents = [AgentProcess(name: "Codex", count: 1)]
        // storefront-web's session has handed work to subagents: three running (one in the background), one just done.
        store.subagents = ["s1": [
            Subagent(id: "a1", description: "Write webhook signature tests", type: "general-purpose", model: "Opus 5.5",
                     background: false, started: minutes(3.2), lastActivity: now, finished: false, tokens: 1_840_000),
            Subagent(id: "a2", description: "Find every place prices are rounded", type: "Explore", model: "Sonnet 5.5",
                     background: false, started: minutes(2.1), lastActivity: now, finished: false, tokens: 620_000),
            Subagent(id: "a3", description: "Review the checkout diff", type: "code-reviewer", model: "Opus 5.5",
                     background: true, started: minutes(1.4), lastActivity: now, finished: false, tokens: 410_000),
            Subagent(id: "a4", description: "Look up Stripe's retry rules", type: "general-purpose", model: "Sonnet 5.5",
                     background: false, started: minutes(3.9), lastActivity: minutes(0.5), finished: true,
                     finishedAt: minutes(0.5), tokens: 280_000),
        ]].filter { id, _ in sessions.contains { $0.id == id } }

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

        // What each workspace uses (its detail page)
        func usage(cpu: Double, mb: Double, watts: Double, upMinutes: Double, branch: String,
                   _ processes: [(String, Int, Double, Double)]) -> WorkspaceUsage {
            WorkspaceUsage(cpu: cpu, memory: UInt64(mb * 1_048_576), watts: watts, started: minutes(upMinutes),
                           processes: processes.map { .init(name: $0.0, count: $0.1, cpu: $0.2, memory: UInt64($0.3 * 1_048_576)) },
                           branch: branch)
        }
        store.workspaceUsage = [
            "\(home)/storefront-web": usage(cpu: 0.12, mb: 1_136, watts: 3.1, upMinutes: 52, branch: "checkout-flow", [
                ("node", 3, 0.071, 498), ("claude", 1, 0.029, 344), ("esbuild", 1, 0.014, 86), ("next-server", 1, 0.004, 182),
                ("git", 1, 0.002, 17), ("zsh", 2, 0, 9)]),
            "\(home)/billing-api": usage(cpu: 0.003, mb: 512, watts: 0.2, upMinutes: 60 * 20, branch: "main", [
                ("node", 1, 0.002, 186), ("claude", 1, 0.001, 318), ("zsh", 1, 0, 8)]),
            "\(home)/docs-site": usage(cpu: 0.02, mb: 610, watts: 0.6, upMinutes: 60 * 3, branch: "plugin-api-docs", [
                ("node", 2, 0.015, 290), ("claude", 1, 0.005, 300), ("zsh", 1, 0, 9)]),
            "\(home)/notes-ios": usage(cpu: 0.001, mb: 296, watts: 0.05, upMinutes: 60 * 4, branch: "swiftui-settings", [
                ("claude", 1, 0.001, 288), ("zsh", 1, 0, 8)]),
            "\(home)/ml-notebooks": usage(cpu: 0.002, mb: 262, watts: 0.04, upMinutes: 60 * 27, branch: "main", [
                ("python3.12", 2, 0.002, 238), ("zsh", 1, 0, 9)]),
        ]
        store.workspaceHistory = store.workspaceUsage.mapValues { u in
            var h = WorkspaceHistory()
            for i in 0..<WorkspaceHistory.length {
                var s = u
                let wave = 0.75 + 0.35 * sin(Double(i) / 3.0) + (i % 9 == 4 ? 0.9 : 0)
                s.cpu = u.cpu * (i == WorkspaceHistory.length - 1 ? 1 : wave)
                s.memory = UInt64(Double(u.memory) * (0.9 + 0.1 * Double(i) / Double(WorkspaceHistory.length)))
                s.watts = (u.watts ?? 0) * (i == WorkspaceHistory.length - 1 ? 1 : 0.8 + 0.3 * sin(Double(i) / 3.0 + 0.5))
                h.append(s)
            }
            return h
        }

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
        // Costs come from the real price table: each model's share of the period's tokens, priced as that model.
        let demoModelIDs = ["Opus 5.5": "claude-opus-5-5", "Sonnet 5.5": "claude-sonnet-5-5", "gpt-5-codex": "gpt-5-codex"]
        func priced(_ t: TokenTotals, _ models: [Ranked], _ projects: [Ranked], _ f: Double) -> PeriodUsage {
            let modelSum = Double(models.reduce(0) { $0 + $1.value })
            let projectSum = Double(projects.reduce(0) { $0 + $1.value })
            var usage = PeriodUsage(totals: t)
            usage.models = models.map { m in
                let share = Double(m.value) / max(modelSum, 1)
                let part = TokenTotals(input: Int(Double(t.input) * share), output: Int(Double(t.output) * share),
                                       cacheRead: Int(Double(t.cacheRead) * share), cacheWrite: Int(Double(t.cacheWrite) * share))
                let cost = Pricing.cost(part, model: demoModelIDs[m.name] ?? m.name, oneHourShare: 0.3)
                usage.cost += cost ?? 0
                return Ranked(name: m.name, value: Int(Double(m.value) * f), cost: cost)
            }
            usage.projects = projects.map { Ranked(name: $0.name, value: Int(Double($0.value) * f), cost: usage.cost * Double($0.value) / max(projectSum, 1)) }
            return usage
        }
        func period(_ t: TokenTotals, _ f: Double) -> PeriodUsage { priced(t, claude.topModels, claude.topProjects, f) }
        var fortnight = TokenTotals(); fortnight.input = 9_800_000; fortnight.output = 5_400_000; fortnight.cacheRead = 1_240_000_000; fortnight.cacheWrite = 21_000_000; fortnight.messages = 4_700
        claude.periods = [period(today, 1), period(week, 4.5), period(fortnight, 8.5)]
        for i in claude.periods.indices {   // about a quarter of it from subagents
            claude.periods[i].subagentTokens = claude.periods[i].totals.total * 27 / 100
            claude.periods[i].subagentCost = claude.periods[i].cost * 0.24
        }
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
        codex.periods = [1.0, 4.5, 8.5].map { f in
            var t = cToday; t.input = Int(Double(t.input) * f); t.output = Int(Double(t.output) * f); t.cacheRead = Int(Double(t.cacheRead) * f)
            return priced(t, codex.topModels, codex.topProjects, f)
        }
        store.codex = codex
        store.codexLimits = [
            RateLimit(label: "5h window", usedPercent: 21, resetsAt: now.addingTimeInterval(3.4 * 3600), window: 5 * 3600),
            RateLimit(label: "7d window", usedPercent: 34, resetsAt: now.addingTimeInterval(4.1 * 86400), window: 7 * 86400),
        ]
        store.usageLoading = false

        // Claude plan limits (only shown with the plan limits setting, which --demo switches on in memory)
        store.claudePlan = ClaudePlanLimits.Result(limits: [
            RateLimit(label: "5-hour", usedPercent: 55, resetsAt: now.addingTimeInterval(2.2 * 3600), window: 5 * 3600),
            RateLimit(label: "Weekly", usedPercent: 38, resetsAt: now.addingTimeInterval(3.5 * 86400), window: 7 * 86400),
        ], plan: "Max 5x")
        // DASHBAR_DEMO_RATE_LIMITED=1 shows the rate-limited wait with nothing to show; =stale shows earlier limits
        // kept through it (with a 5-hour limit on course to run out, to see that forecast too).
        switch ProcessInfo.processInfo.environment["DASHBAR_DEMO_RATE_LIMITED"] {
        case "stale"?:
            var kept = ClaudePlanLimits.Result(limits: [
                RateLimit(label: "5-hour", usedPercent: 80, resetsAt: now.addingTimeInterval(2.5 * 3600), window: 5 * 3600),
                RateLimit(label: "Weekly", usedPercent: 38, resetsAt: now.addingTimeInterval(3.5 * 86400), window: 7 * 86400),
            ], plan: "Pro", fetchedAt: now.addingTimeInterval(-125))
            kept.stale = .rateLimited
            store.claudePlan = kept
            store.claudePlanRetryAt = now.addingTimeInterval(190)
        case _?:
            store.claudePlan = ClaudePlanLimits.Result(plan: "Pro", problem: ClaudePlanLimits.rateLimitedMessage, transient: true)
            store.claudePlanRetryAt = now.addingTimeInterval(45)
        case nil: break
        }
        // DASHBAR_DEMO_STATUSLINE=1 shows limits read from Claude Code's status line (no plan name: only the endpoint
        // knows it); =old makes that reading 25 minutes old, to see the age line.
        if let mode = ProcessInfo.processInfo.environment["DASHBAR_DEMO_STATUSLINE"] {
            store.claudePlan = ClaudePlanLimits.Result(limits: store.claudePlan?.limits ?? [],
                                                       fetchedAt: now.addingTimeInterval(mode == "old" ? -25 * 60 : -40),
                                                       source: .statusLine)
        }

        // DASHBAR_DEMO_ACCOUNTS=2 reads two Claude Code accounts, "Personal" and "Work": sessions and usage say which,
        // and the Work account's limits sit under the Personal ones.
        if ProcessInfo.processInfo.environment["DASHBAR_DEMO_ACCOUNTS"].flatMap(Int.init).map({ $0 >= 2 }) == true {
            let work: Set<String> = ["s1", "s2"]
            store.sessions = store.sessions.map { s in
                var s = s
                s.account = work.contains(s.id) ? "Work" : "Personal"
                return s
            }
            store.claudeDefaultLabel = "Personal"
            func share(_ f: Double) -> UsageSummary {
                var s = claude
                s.periods = claude.periods.map { p in
                    var p = p
                    p.totals = TokenTotals(input: Int(Double(p.totals.input) * f), output: Int(Double(p.totals.output) * f),
                                           cacheRead: Int(Double(p.totals.cacheRead) * f), cacheWrite: Int(Double(p.totals.cacheWrite) * f),
                                           messages: Int(Double(p.totals.messages) * f))
                    p.cost *= f
                    return p
                }
                return s
            }
            store.claudeAccountUsage = [AccountUsage(label: "Work", summary: share(0.68)), AccountUsage(label: "Personal", summary: share(0.32))]
            store.claudeAccountLimits = [AccountLimits(label: "Work", path: "/Users/demo/.claude-work", limits: [
                RateLimit(label: "5-hour", usedPercent: 72, resetsAt: now.addingTimeInterval(1.4 * 3600), window: 5 * 3600),
                RateLimit(label: "Weekly", usedPercent: 51, resetsAt: now.addingTimeInterval(2.2 * 86400), window: 7 * 86400),
            ], fetchedAt: now.addingTimeInterval(-90))]
        }

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
        if ProcessInfo.processInfo.environment["DASHBAR_DEMO_GOOGLE"] != nil { applyGoogle(to: store, now: now) }
        applyHistory(to: store, now: now)
        store.lastUpdated = now
    }
}
