import Foundation
import Testing
@testable import Dashbar
import DashbarStatus

/// Settings → Integrations → "Show in Dashbar": a tool switched off contributes nothing anywhere, and its collectors
/// don't run.
@Suite struct ToolVisibilityTests {
    func session(_ id: String, _ agent: SessionAgent, root: String = "/Users/x/dev/shop") -> LiveSession {
        var s = LiveSession(id: id, pid: 1, name: "shop", cwd: root, status: "busy", since: Date(), entrypoint: "cli", root: root)
        s.agent = agent
        return s
    }

    func summary(_ tokens: Int) -> UsageSummary {
        var book = UsageBook()
        book.add(TokenTotals(input: tokens, messages: 1), at: Date(), model: "m", project: "shop")
        return book.summary(found: true)
    }

    @Test func claudeCantBeHidden() throws {
        let all = ToolVisibility(hidden: Set(HideableTool.allCases))
        #expect(all.shows(agent: .claude))
        #expect(!all.shows(agent: .copilot) && !all.shows(agent: .geminiCLI) && !all.shows(agent: .antigravity))
        #expect(SessionAgent.claude.hideableTool == nil)
        #expect(!HideableTool.allCases.map(\.rawValue).contains("claude"))
        // A saved "claude" is ignored.
        #expect(ToolVisibility.parse(["claude", "codex", "nonsense"]) == ToolVisibility(hidden: [.codex]))
        #expect(all.filter([session("c", .claude)]).count == 1)
    }

    @Test func savedPerToolAndEverythingShowsByDefault() throws {
        try withTestDefaults { d in
            #expect(ToolVisibility.load(from: d) == ToolVisibility())
            ToolVisibility(hidden: [.copilot, .google]).save(to: d)
            #expect(d.stringArray(forKey: ToolVisibility.key) == ["copilot", "google"])
            #expect(ToolVisibility.load(from: d) == ToolVisibility(hidden: [.copilot, .google]))
            ToolVisibility().save(to: d)
            #expect(d.object(forKey: ToolVisibility.key) == nil)
        }
    }

    @Test func demoRunsNeverReadOrSaveRealPreferences() throws {
        try withTestDefaults { d in
            d.set(["codex"], forKey: ToolVisibility.key)
            let v = ToolVisibility.initial(arguments: ["Dashbar", "--snapshot", "x.png", "--demo"],
                                           environment: [ToolVisibility.demoVariable: "copilot, opencode"], defaults: d)
            #expect(v == ToolVisibility(hidden: [.copilot, .opencode]))
            #expect(ToolVisibility.initial(arguments: ["Dashbar"], environment: [:], defaults: d) == ToolVisibility(hidden: [.codex]))
        }
    }

    @Test func hiddenCollectorsAreNotCalled() {
        var calls: [String] = []
        let google = { () -> GoogleLive in calls.append("google"); return GoogleLive(sessions: [session("g", .geminiCLI)], warning: "w") }
        let opencode = { () -> [LiveSession] in calls.append("opencode"); return [session("o", .opencode)] }
        let copilot = { () -> [LiveSession] in calls.append("copilot"); return [session("p", .copilot)] }

        var v = ToolVisibility(hidden: [.copilot, .google])
        let off = Worker.otherSessions(v, google: google, opencode: opencode, copilot: copilot)
        #expect(calls == ["opencode"])
        #expect(off.sessions.map(\.id) == ["o"])
        #expect(off.googleWarning == nil)

        // Switched back on: read again on the next refresh.
        calls = []
        v.set(.copilot, shown: true)
        v.set(.google, shown: true)
        let on = Worker.otherSessions(v, google: google, opencode: opencode, copilot: copilot)
        #expect(calls == ["google", "opencode", "copilot"])
        #expect(on.sessions.map(\.id) == ["g", "o", "p"])
        #expect(on.googleWarning == "w")
    }

    @Test func hiddenToolsLeaveTheLiveReading() {
        var r = Worker.LiveResult()
        r.sessions = [session("c", .claude), session("p", .copilot, root: "/Users/x/dev/api"), session("a", .antigravity)]
        r.googleWarning = "Antigravity changed"
        r.agents = [AgentProcess(name: "Codex", count: 2), AgentProcess(name: "Codex app", count: 1), AgentProcess(name: "Aider", count: 1)]
        r.workspaceUsage = ["/Users/x/dev/shop": WorkspaceUsage(), "/Users/x/dev/api": WorkspaceUsage()]
        let h = r.hiding(ToolVisibility(hidden: [.copilot, .google, .codex]))
        #expect(h.sessions.map(\.id) == ["c"])
        #expect(h.googleWarning == nil)
        #expect(h.agents?.map(\.name) == ["Aider"])
        #expect(h.workspaceUsage?.keys.sorted() == ["/Users/x/dev/shop"])
        // Nothing hidden: the reading as it was.
        #expect(r.hiding(ToolVisibility()).sessions.count == 3)
    }

    @Test func hiddenToolsLeaveTheUsageReading() {
        var r = Worker.UsageResult(claude: summary(10), codex: summary(20),
                                   codexLimits: [RateLimit(label: "5-hour", usedPercent: 40, resetsAt: nil)])
        r.codexAccountLimits = [AccountLimits(label: "Work", path: "/x", limits: r.codexLimits)]
        r.google = summary(30)
        r.googleSources = [.geminiCLI]
        r.antigravityLimits = AntigravityLimits(groups: [.init(key: "gemini", name: "Gemini", limits: r.codexLimits)])
        r.opencode = summary(40)
        r.copilot = CopilotUsage(summary: summary(50), premiumByDay: ["x": 3], unknownSessions: 1)
        let h = r.hiding(ToolVisibility(hidden: Set(HideableTool.allCases)))
        #expect(h.claude.today.total == 10)   // Claude Code always shows
        #expect(!h.codex.found && h.codexLimits.isEmpty && h.codexAccountLimits.isEmpty)
        #expect(!h.google.found && h.googleSources.isEmpty && h.antigravityLimits == nil)
        #expect(!h.opencode.found)
        #expect(h.copilot == .empty)
        // Back on: everything as read.
        let back = r.hiding(ToolVisibility())
        #expect(back.codexLimits.count == 1 && back.copilot.summary.today.total == 50 && back.google.found)
    }

    /// The status file and the widgets' counts come from the store, so a hidden tool is in neither, and none of its
    /// History.
    @MainActor @Test func hiddenToolIsNotInTheStatusFileWidgetsOrHistory() throws {
        let store = Store(demo: true)
        DemoData.applyCopilot(to: store, now: Date(), waiting: false)
        let before = CLIStatus.snapshot(of: store, showsClaudeLimits: true)
        #expect(before.sessions.contains { $0.tool == "copilot" })
        #expect(before.usageToday?.tools.contains { $0.tool == "copilot" } == true)
        #expect(before.limits.contains { $0.provider == "codex" })
        let total = before.forWidget().agents?.total ?? 0

        store.applyVisibility(ToolVisibility(hidden: [.copilot, .codex]))
        let after = CLIStatus.snapshot(of: store, showsClaudeLimits: true)
        #expect(!after.sessions.contains { $0.tool == "copilot" })
        #expect(after.usageToday?.tools.contains { $0.tool == "copilot" || $0.tool == "codex" } == false)
        #expect(!after.limits.contains { $0.provider == "codex" })
        #expect(after.forWidget().agents?.total == total - 1)
        #expect(!store.copilot.summary.found && store.copilot.summary.history.totals.total == 0)
        #expect(!store.codex.found && store.codexLimits.isEmpty)
        #expect(!store.usageServices(settings: AppSettings.shared, antigravityInstalled: false).contains { $0.service == .copilot })
    }
}
