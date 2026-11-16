import Foundation
import Testing
@testable import Dashbar
import DashbarStatus
@testable import DashbarWidgetUI

/// A tool switched off in Show in Dashbar is in none of the widgets' data, and each tool's own widget says why it has
/// nothing to show rather than showing a blank or a zero.
@Suite struct WidgetToolTests {
    /// The demo with every tool in it: Claude Code, Codex, Google's (with Antigravity's two quota groups), OpenCode and
    /// GitHub Copilot.
    @MainActor static func everyTool() -> Store {
        let store = Store(demo: true)
        let now = Date()
        DemoData.applyGoogle(to: store, now: now)
        DemoData.applyOpenCode(to: store, now: now, waiting: false)
        DemoData.applyCopilot(to: store, now: now, waiting: false)
        return store
    }

    @MainActor static func widgetCopy(_ store: Store, hiding: Set<HideableTool>) -> StatusSnapshot {
        CLIStatus.snapshot(of: store, showsClaudeLimits: true, visibility: ToolVisibility(hidden: hiding)).forWidget()
    }

    @MainActor @Test func everyToolReachesTheWidgetsWhenShown() throws {
        let w = Self.widgetCopy(Self.everyTool(), hiding: [])
        #expect(Set(w.limits.map(\.provider)) == ["claude", "codex", "antigravity"])
        let tools = try #require(w.usageTotals).tools
        #expect(tools.map(\.tool) == ["claude", "codex", "google", "opencode", "copilot"])
        #expect(w.hidden == nil)
        // Copilot is billed by premium requests: no cost, but its count. Only OpenCode names a model.
        let copilot = try #require(tools.first { $0.tool == "copilot" })
        #expect(copilot.cost == nil && (copilot.premiumRequests ?? 0) > 0)
        #expect((tools.first { $0.tool == "claude" }?.cost ?? 0) > 0)
        #expect(tools.filter { $0.model != nil }.map(\.tool) == ["opencode"])
    }

    @MainActor @Test func googleHiddenLeavesNoAntigravityGroup() {
        let store = Self.everyTool()
        let w = Self.widgetCopy(store, hiding: [.google])
        #expect(!w.limits.contains { $0.provider == "antigravity" })
        #expect(w.usageTotals?.tools.contains { $0.tool == "google" } == false)
        #expect(w.hidden == ["google"])
        // Its agents aren't counted either.
        let shown = Self.widgetCopy(store, hiding: [])
        let google = store.sessions.filter { $0.agent.hideableTool == .google }.count
        #expect(google > 0)
        #expect(w.agents?.total == (shown.agents?.total ?? 0) - google)
    }

    @MainActor @Test func codexHiddenLeavesNoCodexGroup() {
        let w = Self.widgetCopy(Self.everyTool(), hiding: [.codex])
        #expect(!w.limits.contains { $0.provider == "codex" })
        #expect(w.usageTotals?.tools.contains { $0.tool == "codex" } == false)
        #expect(w.hidden == ["codex"])
    }

    @MainActor @Test func openCodeAndCopilotHiddenLeaveNoUsage() {
        let store = Self.everyTool()
        let shown = Self.widgetCopy(store, hiding: [])
        let w = Self.widgetCopy(store, hiding: [.opencode, .copilot])
        #expect(w.usageTotals?.tools.contains { $0.tool == "opencode" || $0.tool == "copilot" } == false)
        #expect(w.hidden == ["copilot", "opencode"])
        let theirs = store.sessions.filter { [.opencode, .copilot].contains($0.agent) }.count
        #expect(theirs > 0)
        #expect(w.agents?.total == (shown.agents?.total ?? 0) - theirs)
        // Every tool off at once: only Claude Code is left.
        let all = Self.widgetCopy(store, hiding: Set(HideableTool.allCases))
        #expect(Set(all.limits.map(\.provider)) == ["claude"])
        #expect(all.usageTotals?.tools.map(\.tool) == ["claude"])
    }

    /// The store drops a hidden tool's readings as soon as it's switched off (`applyVisibility`): the widget copy follows.
    @MainActor @Test func storeSwitchedOffLeavesNothingBehind() {
        let store = Self.everyTool()
        store.applyVisibility(ToolVisibility(hidden: [.google, .codex, .opencode, .copilot]))
        let w = CLIStatus.snapshot(of: store, showsClaudeLimits: true, visibility: .all).forWidget()
        #expect(Set(w.limits.map(\.provider)) == ["claude"])
        #expect(w.usageTotals?.tools.map(\.tool) == ["claude"])
    }

    /// A snapshot that still carries a hidden tool (built before the switch, say) loses it in the widget copy.
    @Test func widgetCopyDropsHiddenToolsItself() {
        let now = Date()
        let s = StatusSnapshot(generatedAt: now, app: .init(name: "Dashbar", version: "1", pid: 1),
                               sessions: [.init(tool: "antigravity-cli", workspace: "w", folder: "/w", state: .working, since: now),
                                          .init(tool: "claude", workspace: "w", folder: "/w", state: .working, since: now)],
                               limits: [.init(provider: "antigravity", limits: [WidgetStatusTests.limit("5-hour", 4)]),
                                        .init(provider: "claude", limits: [WidgetStatusTests.limit("5-hour", 4)])],
                               usageToday: .init(day: "2026-11-16", tools: [
                                   .init(tool: "google", name: "Gemini CLI", input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: 1),
                                   .init(tool: "claude", name: "Claude", input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: 2)]),
                               hidden: ["google"])
        let w = s.forWidget()
        #expect(w.limits.map(\.provider) == ["claude"])
        #expect(w.usageTotals?.tools.map(\.tool) == ["claude"])
        #expect(w.agents == .init(working: 1, total: 1))
        // The Usage tab's cost switched off: no cost in the widgets either.
        #expect(s.forWidget(showsCost: false).usageTotals?.tools.allSatisfy { $0.cost == nil } == true)
    }

    /// The widget's copy keeps today's totals but nothing finer: no split by token kind, no workspace.
    @MainActor @Test func usageTotalsHoldOnlyTotals() throws {
        let store = Self.everyTool()
        let w = Self.widgetCopy(store, hiding: [])
        let data = try StatusSnapshot.encoder().encode(w)
        let keys = CLIStatusSnapshotTests.keys(try JSONSerialization.jsonObject(with: data))
        #expect(keys.subtracting(CLIStatusSnapshotTests.allowedKeys).isEmpty, "\(keys.subtracting(CLIStatusSnapshotTests.allowedKeys))")
        for key in ["input", "output", "cacheRead", "cacheWrite", "usageToday", "workspace", "folder"] {
            #expect(!keys.contains(key), "\(key) reached the widget's copy")
        }
        let text = String(decoding: data, as: UTF8.self)
        for s in store.sessions { #expect(!text.contains(s.project), "workspace \(s.project) leaked") }
    }

    // MARK: What each tool's widget says

    static let now = WidgetStatusTests.now

    static func entry(limits: [StatusSnapshot.LimitGroup] = [], usage: [StatusSnapshot.ToolTotal]? = nil, day: String? = nil,
                      hidden: [String]? = nil, running: Bool = true, local: Bool = false) -> DashbarWidgetEntry {
        var s = WidgetStatusTests.snapshot(limits: limits)
        s.hidden = hidden
        s.usageTotals = usage.map { .init(day: day ?? StatusSnapshot.dayKey(now), tools: $0) }
        return .init(date: now, snapshot: s, running: running, local: local)
    }

    @Test func messagesAreHonest() {
        let none = WidgetModel(entry: .init(date: Self.now, snapshot: nil, running: false))
        #expect(none.message(.codex) == "Open Dashbar to see your Codex plan limits here.")
        #expect(none.message(.claude) == "Open Dashbar to see your Claude plan limits here.")
        #expect(none.message(.opencode) == "Open Dashbar to see OpenCode's usage here.")

        let hidden = WidgetModel(entry: Self.entry(hidden: ["codex", "google", "opencode", "copilot"]))
        #expect(hidden.message(.codex) == "Codex is switched off in Dashbar.")
        #expect(hidden.message(.antigravity) == "Antigravity is switched off in Dashbar.")
        #expect(hidden.message(.opencode) == "OpenCode is switched off in Dashbar.")
        #expect(hidden.message(.copilot) == "GitHub Copilot is switched off in Dashbar.")

        let unused = WidgetModel(entry: Self.entry(usage: [.init(tool: "claude", name: "Claude", total: 5)]))
        #expect(unused.message(.codex) == "No Codex usage yet.")
        #expect(unused.message(.opencode) == "No OpenCode usage yet.")
        #expect(unused.message(.copilot) == "No GitHub Copilot usage yet.")
        #expect(unused.message(.antigravity)?.hasPrefix("No Antigravity plan limits yet.") == true)

        // Used before, nothing today: says so, rather than a 0 that looks like a reading.
        let quiet = WidgetModel(entry: Self.entry(limits: [.init(provider: "codex", limits: [WidgetStatusTests.limit("5-hour", 12)])],
                                                  usage: [.init(tool: "opencode", name: "OpenCode", total: 0),
                                                          .init(tool: "codex", name: "Codex", total: 0)]))
        #expect(quiet.message(.opencode) == "No OpenCode usage today.")
        #expect(quiet.message(.codex) == nil)
        #expect(quiet.row(.codex)?.limits.count == 1)
        #expect(quiet.usageRows.isEmpty)
    }

    @Test func yesterdaysTotalsAreNeverToday() {
        let old = WidgetModel(entry: Self.entry(usage: [.init(tool: "opencode", name: "OpenCode", total: 900)], day: "2001-01-01"))
        #expect(old.today == nil && old.usageRows.isEmpty)
        #expect(old.message(.opencode) == "No OpenCode usage today.")
        let today = WidgetModel(entry: Self.entry(usage: [.init(tool: "opencode", name: "OpenCode", total: 900, model: "qwen3-coder")]))
        #expect(today.message(.opencode) == nil)
        #expect(today.today(.opencode)?.model == "qwen3-coder")
    }

    @Test func usageRowsAndWording() {
        let m = WidgetModel(entry: Self.entry(usage: [
            .init(tool: "claude", name: "Claude", total: 12_400_000, cost: 8.2),
            .init(tool: "codex", name: "Codex", total: 0),
            .init(tool: "copilot", name: "GitHub Copilot", total: 830_000, premiumRequests: 0),
        ]))
        #expect(m.usageRows.map(\.tool) == ["claude", "copilot"])
        #expect(m.usageRows.map(WidgetModel.usageName) == ["Claude Code", "GitHub Copilot"])
        #expect(WidgetModel.tokens(12_400_000) == "12M")
        #expect(WidgetModel.tokens(830_000) == "830K")
        #expect(WidgetModel.tokens(1_400_000) == "1.4M")
        #expect(WidgetModel.usd(8.2) == "$8.20")
        #expect(WidgetModel.usd(0.004) == "<$0.01")
        // Copilot's premium line hides at zero, as the app's does.
        #expect(WidgetModel.premiumLine(0) == nil)
        #expect(WidgetModel.premiumLine(nil) == nil)
        #expect(WidgetModel.premiumLine(1) == "1 premium request today")
        #expect(WidgetModel.premiumLine(12) == "12 premium requests today")
    }

    @Test func antigravityLimitsAreNamedByGroup() {
        let gemini = StatusSnapshot.Limit(label: "Gemini · Weekly", window: "Weekly", windowSeconds: 7 * 86400, usedPercent: 30)
        let others = StatusSnapshot.Limit(label: "Claude and GPT · 5-hour", window: "5-hour", windowSeconds: 5 * 3600, usedPercent: 10)
        #expect(WidgetModel.groupTitles([gemini, others]) == ["Gemini", "Claude and GPT"])
        // One group's two windows: the whole labels, so they still read apart.
        let gemini5 = StatusSnapshot.Limit(label: "Gemini · 5-hour", window: "5-hour", windowSeconds: 5 * 3600, usedPercent: 10)
        #expect(WidgetModel.groupTitles([gemini5, gemini]) == ["Gemini · 5-hour", "Gemini · Weekly"])
        // A single group's limits have no group in their labels: named by window.
        #expect(WidgetModel.groupTitles([WidgetStatusTests.limit("5-hour", 1)]) == ["5-hour"])
    }

    @Test func localComesFromTheEntry() {
        #expect(WidgetModel(entry: Self.entry(local: true)).local)
        #expect(!WidgetModel(entry: Self.entry()).local)
        #expect(WidgetModel(entry: .init(date: Self.now, snapshot: nil, running: false, local: true)).local)
    }

    @Test func everyKindIsReloaded() {
        #expect(WidgetStatus.Kind.all.count == 7)
        #expect(Set(WidgetStatus.Kind.all).count == 7)
    }
}
