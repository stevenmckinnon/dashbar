import Foundation

/// Invented Google data for screenshots (`DASHBAR_DEMO_GOOGLE=1`): a working Antigravity CLI session, an idle Gemini CLI
/// one, an Antigravity app conversation, their usage and Antigravity's two model groups' limits.
@MainActor
extension DemoData {
    static func applyGoogle(to store: Store, now: Date) {
        func minutes(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        let home = "/Users/demo/Development"
        var agy = LiveSession(id: "g1", pid: 9011, name: "ml-notebooks", cwd: "\(home)/ml-notebooks", status: "busy",
                              since: minutes(3), entrypoint: "cli", root: "\(home)/ml-notebooks")
        agy.agent = .antigravityCLI
        var gemini = LiveSession(id: "g2", pid: 9012, name: "docs-site", cwd: "\(home)/docs-site", status: "idle",
                                 since: minutes(21), entrypoint: "cli", root: "\(home)/docs-site")
        gemini.agent = .geminiCLI
        var app = LiveSession(id: "g3", pid: 0, name: "landing-page", cwd: "\(home)/landing-page", status: "idle",
                              since: minutes(12), entrypoint: "Antigravity", root: "\(home)/landing-page")
        app.agent = .antigravity
        store.sessions = (store.sessions + [agy, gemini, app]).sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        store.workspaceUsage["\(home)/landing-page"] = WorkspaceUsage(cpu: 0.002, memory: 96 * 1_048_576, watts: 0.05,
                                                                      started: minutes(40), processes: [], branch: "main")

        var t = TokenTotals(); t.input = 2_100_000; t.output = 380_000; t.cacheRead = 6_400_000; t.messages = 64
        var g = UsageSummary()
        g.found = true
        g.today = t; g.week = t
        g.last14 = store.claude.last14.map { DayPoint(id: $0.id, date: $0.date, tokens: $0.tokens / 11, isToday: $0.isToday) }
        g.last24 = store.claude.last24.map { HourPoint(id: $0.id, tokens: $0.tokens / 11, messages: $0.messages / 11, isNow: $0.isNow) }
        g.tokens24 = g.last24.reduce(0) { $0 + $1.tokens }
        g.sessions24 = 3
        let flash = Pricing.cost(TokenTotals(input: 1_200_000, output: 210_000, cacheRead: 6_400_000), model: "gemini-3.8-flash") ?? 0
        g.periods = [1.0, 4.2, 7.9].map { f in
            var p = PeriodUsage(totals: TokenTotals(input: Int(Double(t.input) * f), output: Int(Double(t.output) * f),
                                                    cacheRead: Int(Double(t.cacheRead) * f), messages: Int(Double(t.messages) * f)))
            p.models = [Ranked(name: "gemini-3.8-flash", value: Int(7_810_000 * f), cost: flash * f),
                        Ranked(name: "Gemini 4 Argon (Medium)", value: Int(1_070_000 * f), cost: 0.42 * f)]
            p.projects = [Ranked(name: "docs-site", value: Int(7_810_000 * f), cost: flash * f),
                          Ranked(name: "ml-notebooks", value: Int(1_070_000 * f), cost: 0.42 * f)]
            p.cost = (flash + 0.42) * f
            return p
        }
        store.google = g
        store.googleSources = [.geminiCLI, .antigravityCLI]
        store.antigravityLimits = AntigravityLimits(planTier: "Pro", groups: [
            .init(key: "gemini", name: "Gemini", limits: [
                RateLimit(label: "5-hour", usedPercent: 42, resetsAt: now.addingTimeInterval(2.9 * 3600), window: 5 * 3600),
                RateLimit(label: "Weekly", usedPercent: 61, resetsAt: now.addingTimeInterval(2.6 * 86400), window: 7 * 86400),
            ]),
            .init(key: "claude-and-gpt", name: "Claude and GPT", limits: [
                RateLimit(label: "5-hour", usedPercent: 18, resetsAt: now.addingTimeInterval(4.1 * 3600), window: 5 * 3600),
                RateLimit(label: "Weekly", usedPercent: 27, resetsAt: now.addingTimeInterval(2.6 * 86400), window: 7 * 86400),
            ]),
        ], fetchedAt: minutes(1))
        // DASHBAR_DEMO_GOOGLE=quota: the reading as the CLI shapes it, with bucket IDs Dashbar has to name by rule
        // ("3p-5h", a group with an unknown short word) and most windows at 0%, to see the names and the folded rows.
        if ProcessInfo.processInfo.environment["DASHBAR_DEMO_GOOGLE"] == "quota" {
            let reset5 = now.addingTimeInterval(4.6 * 3600).timeIntervalSince1970, resetW = now.addingTimeInterval(5.2 * 86400).timeIntervalSince1970
            let json = """
            {"written_at":\(now.addingTimeInterval(-420).timeIntervalSince1970),"plan_tier":"Google AI Pro","quota":{
             "gemini-5h":{"remaining_fraction":1,"reset_in_seconds":\(reset5 - now.timeIntervalSince1970)},
             "gemini-weekly":{"remaining_fraction":1,"reset_in_seconds":\(resetW - now.timeIntervalSince1970)},
             "gemini-argon-wtu-weekly":{"remaining_fraction":0.97,"reset_in_seconds":\(resetW - now.timeIntervalSince1970)},
             "3p-5h":{"remaining_fraction":1,"reset_in_seconds":\(reset5 - now.timeIntervalSince1970)},
             "3p-weekly":{"remaining_fraction":1,"reset_in_seconds":\(resetW - now.timeIntervalSince1970)}}}
            """
            store.antigravityLimits = AntigravityStatusLine.parseLimits(Data(json.utf8), now: now)
        }
    }
}
