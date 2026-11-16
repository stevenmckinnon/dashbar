import Foundation
import Testing
@testable import Dashbar
import DashbarStatus
@testable import DashbarWidgetUI

/// The desktop widgets' copy of the status: only limits and counts reach it, it is saved privately and only on change,
/// and what the widgets show from it.
@Suite struct WidgetStatusTests {
    @MainActor func demoSnapshot() -> (StatusSnapshot, Store) {
        let store = Store(demo: true)
        return (CLIStatus.snapshot(of: store, showsClaudeLimits: true), store)
    }

    @MainActor @Test func widgetCopyHoldsOnlyLimitsAndCounts() throws {
        let (full, store) = demoSnapshot()
        let widget = full.forWidget()
        let data = try StatusSnapshot.encoder().encode(widget)
        let text = String(decoding: data, as: UTF8.self)
        let keys = CLIStatusSnapshotTests.keys(try JSONSerialization.jsonObject(with: data))
        #expect(keys.subtracting(CLIStatusSnapshotTests.allowedKeys).isEmpty)
        // Nothing that names a project, a folder, a server or a session.
        for key in ["workspace", "folder", "port", "command", "since", "subagents", "usageToday", "input"] {
            #expect(!keys.contains(key), "\(key) reached the widget's copy")
        }
        for s in store.sessions {
            #expect(!text.contains(s.project), "workspace \(s.project) leaked")
            #expect(!text.contains(s.root))
            #expect(!text.contains(s.name))
        }
        #expect(widget.sessions.isEmpty && widget.servers.isEmpty && widget.usageToday == nil)
        #expect(widget.limits == full.limits)
        let counts = try #require(widget.agents)
        #expect(counts.total == store.sessions.count)
        #expect(counts == full.agentCounts)
        #expect(counts.working > 0)
        // Only how many there are and how many work: no count of agents waiting, which throttled refreshes would leave stale.
        #expect(!text.contains("needsYou") && !text.contains("idle"))
    }

    @Test func countsByState() {
        func session(_ state: StatusSnapshot.State) -> StatusSnapshot.Session {
            .init(tool: "claude", workspace: "w", folder: "/w", state: state, since: Date())
        }
        let s = StatusSnapshot(generatedAt: Date(), app: .init(name: "Dashbar", version: "1", pid: 1),
                               sessions: [session(.working), session(.working), session(.needsYou), session(.permission), session(.idle)])
        #expect(s.agentCounts == .init(working: 2, total: 5))
        // The CLI's own file leaves the counts out; only the widget's copy has them.
        #expect(s.agents == nil)
    }

    @MainActor @Test func bridgeWritesPrivatelyOnlyOnChangeAndThrottlesReloads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dashbar-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = WidgetStatus.fileURL(container: folder)
        var reloads = 0
        let bridge = WidgetBridge(url: url) { reloads += 1 }
        let (full, _) = demoSnapshot()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(bridge.update(full, now: t0))
        #expect(reloads == 1)
        #expect(!bridge.update(full, now: t0.addingTimeInterval(5)), "unchanged: no write")
        var changed = full
        changed.limits[0].limits[0].usedPercent += 7
        #expect(bridge.update(changed, now: t0.addingTimeInterval(10)))
        #expect(reloads == 1, "a second reload within the minute waits")

        let file = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let dir = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(dir == 0o700)
        let saved = try #require(WidgetStatus.load(url))
        #expect(saved.sessions.isEmpty)
        #expect(saved.agents != nil)
        // Dates go through ISO 8601 (whole seconds), so compare the figures.
        #expect(saved.limits.flatMap(\.limits).map(\.usedPercent) == changed.limits.flatMap(\.limits).map(\.usedPercent))
    }

    @Test func loadRefusesNewerSchemaAndJunk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dashbar-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("status.json")
        #expect(WidgetStatus.load(url) == nil)
        try Data("{\"schema\": 99}".utf8).write(to: url)
        #expect(WidgetStatus.load(url) == nil)
        try Data("not json".utf8).write(to: url)
        #expect(WidgetStatus.load(url) == nil)
    }

    // MARK: What the widgets show

    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func snapshot(limits: [StatusSnapshot.LimitGroup], agents: StatusSnapshot.AgentCounts? = .init(working: 1, total: 2)) -> StatusSnapshot {
        StatusSnapshot(generatedAt: now.addingTimeInterval(-300), app: .init(name: "Dashbar", version: "1", pid: 42),
                       limits: limits, agents: agents)
    }

    static func limit(_ label: String, _ used: Double, window: Double = 5 * 3600, resetIn: Double = 3600) -> StatusSnapshot.Limit {
        .init(label: label, window: label, windowSeconds: window, usedPercent: used, resetsAt: now.addingTimeInterval(resetIn))
    }

    @Test func availability() {
        let empty = WidgetModel(entry: .init(date: Self.now, snapshot: nil, running: false))
        #expect(empty.availability == .noData)
        #expect(StatusFooter.text(empty, now: Self.now) == nil)

        let snap = Self.snapshot(limits: [.init(provider: "claude", limits: [Self.limit("5-hour", 40)])])
        let quit = WidgetModel(entry: .init(date: Self.now, snapshot: snap, running: false))
        #expect(quit.availability == .notRunning(lastSeen: snap.generatedAt))
        #expect(quit.agents == nil, "counts from a quit app would be wrong, so they aren't shown")
        #expect(StatusFooter.text(quit, now: Self.now)?.hasPrefix("Dashbar isn't running") == true)

        let live = WidgetModel(entry: .init(date: Self.now, snapshot: snap, running: true))
        #expect(live.availability == .live)
        #expect(live.agents?.working == 1)
        #expect(StatusFooter.text(live, now: Self.now) == nil)
    }

    @Test func rowsNameAccountsOnlyWhenThereAreSeveral() {
        let one = WidgetModel(entry: .init(date: Self.now, snapshot: Self.snapshot(limits: [
            .init(provider: "claude", account: "Personal", limits: [Self.limit("5-hour", 10)]),
            .init(provider: "codex", limits: [Self.limit("5-hour", 10)]),
        ]), running: true))
        #expect(one.rows.map(\.name) == ["Claude", "Codex"])
        let two = WidgetModel(entry: .init(date: Self.now, snapshot: Self.snapshot(limits: [
            .init(provider: "claude", account: "Personal", limits: [Self.limit("5-hour", 10)]),
            .init(provider: "claude", account: "Work", limits: [Self.limit("5-hour", 10)]),
        ]), running: true))
        #expect(two.rows.map(\.name) == ["Claude · Personal", "Claude · Work"])
        #expect(two.claude?.name == "Claude · Personal")
    }

    @Test func aRowKeepsItsTightestLimitsInOrder() {
        let limits = [Self.limit("A", 10), Self.limit("B", 70), Self.limit("C", 5), Self.limit("D", 30)]
        #expect(WidgetModel.shown(limits, now: Self.now, count: 2).map(\.label) == ["B", "D"])
        #expect(WidgetModel.shown(Array(limits.prefix(2)), now: Self.now, count: 2).map(\.label) == ["A", "B"])
        // Claude's extra usage (no window) only when nothing else is reported.
        let extra = StatusSnapshot.Limit(label: "Extra usage", usedPercent: 50)
        #expect(WidgetModel.shown([extra, Self.limit("5-hour", 20)], now: Self.now, count: 2).map(\.label) == ["5-hour"])
        #expect(WidgetModel.shown([extra], now: Self.now, count: 2).map(\.label) == ["Extra usage"])
    }

    @Test func fillFollowsTheAppsRule() {
        #expect(WidgetModel.fill(Self.limit("5-hour", 40).withPace(now: Self.now)) == .provider)
        #expect(WidgetModel.fill(Self.limit("5-hour", 95)) == .problem)
        // 4 of 5 hours gone and 85% used: on course to run out before the reset.
        let fast = Self.limit("5-hour", 85, resetIn: 3600).withPace(now: Self.now)
        #expect(fast.pace == .runsOut)
        #expect(WidgetModel.fill(fast) == .attention)
    }

    @Test func resetTimesAreClockTimes() {
        let tz = TimeZone(identifier: "Europe/London")!
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9))!
        let later = morning.addingTimeInterval(5 * 3600 + 20 * 60)
        #expect(WidgetModel.resetText(later, now: morning, locale: locale, timeZone: tz) == "14:20")
        let thursday = morning.addingTimeInterval(3 * 86400)
        #expect(WidgetModel.resetText(thursday, now: morning, locale: locale, timeZone: tz).hasPrefix("Thu"))
    }

    @Test func limitsSharingAWindowAreNamedByTheirGroup() {
        // Antigravity's weekly limits for two quota groups, as the app flattens them.
        let gemini = StatusSnapshot.Limit(label: "Gemini · Weekly", window: "Weekly", windowSeconds: 7 * 86400, usedPercent: 3)
        let others = StatusSnapshot.Limit(label: "Claude and GPT · Weekly", window: "Weekly", windowSeconds: 7 * 86400, usedPercent: 1)
        #expect(WidgetModel.titles([gemini, others], short: true) == ["Gemini", "Claude and GPT"])
        #expect(WidgetModel.titles([gemini, others], short: false) == ["Gemini · Weekly", "Claude and GPT · Weekly"])
        // Different windows keep their short names, even from different groups.
        let five = StatusSnapshot.Limit(label: "Gemini · 5-hour", window: "5-hour", windowSeconds: 5 * 3600, usedPercent: 3)
        #expect(WidgetModel.titles([five, others], short: true) == ["5h", "wk"])
        #expect(WidgetModel.titles([Self.limit("5-hour", 1), Self.limit("Weekly", 2, window: 7 * 86400)], short: false) == ["5-hour", "Weekly"])
        // Claude's per-model weekly limit is named by its model.
        let opus = StatusSnapshot.Limit(label: "Weekly · Opus", window: "Weekly", windowSeconds: 7 * 86400, usedPercent: 9)
        let weekly = StatusSnapshot.Limit(label: "Weekly", window: "Weekly", windowSeconds: 7 * 86400, usedPercent: 9)
        #expect(WidgetModel.titles([weekly, opus], short: true) == ["Weekly", "Opus"])
        #expect(WidgetModel.qualifier(weekly) == nil)
    }
}

@Suite struct StaleWidgetExtensionTests {
    /// A widget process older than the installed extension is the previous version, left running across an update.
    @Test func olderProcessIsStale() {
        let installed = Date(timeIntervalSince1970: 1_000_000)
        #expect(WidgetBridge.isStale(started: installed.addingTimeInterval(-60), executableModified: installed))
        #expect(!WidgetBridge.isStale(started: installed.addingTimeInterval(5), executableModified: installed))
    }
}
