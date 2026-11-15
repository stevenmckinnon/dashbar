import Foundation
import Testing
@testable import Dashbar

/// What the panel's Overview shows, and when: the Now card, the Servers card, the clean-up line and the plan strip.
@Suite struct OverviewRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: String, minutesAgo: Double, root: String) -> LiveSession {
        LiveSession(id: id, pid: 1, name: id, cwd: root, status: status, since: now.addingTimeInterval(-minutesAgo * 60),
                    entrypoint: "cli", root: root,
                    waitingFor: status == "waiting" ? "permission prompt" : nil)
    }

    private func workspace(_ name: String, _ status: String, minutesAgo: Double) -> Workspace {
        let root = "/tmp/demo/\(name)"
        return Workspace(root: root, sessions: [session(name, status, minutesAgo: minutesAgo, root: root)])
    }

    // MARK: Now card

    @Test func nowCardFeaturesAWaitingAgentFirstThenAWorkingOne() {
        let ws = [workspace("a", "busy", minutesAgo: 1), workspace("b", "waiting", minutesAgo: 5), workspace("c", "idle", minutesAgo: 0.5)]
        #expect(OverviewRules.nowWorkspace(ws, now: now)?.name == "b")
        let noWait = [workspace("a", "idle", minutesAgo: 0.5), workspace("b", "busy", minutesAgo: 40)]
        #expect(OverviewRules.nowWorkspace(noWait, now: now)?.name == "b")
    }

    @Test func nowCardKeepsAnAgentThatWentIdleInTheLastTenMinutes() {
        let ws = [workspace("old", "idle", minutesAgo: 95), workspace("recent", "idle", minutesAgo: 3)]
        #expect(OverviewRules.nowWorkspace(ws, now: now)?.name == "recent")
        #expect(OverviewRules.nowWorkspace([workspace("edge", "idle", minutesAgo: 9.9)], now: now)?.name == "edge")
    }

    @Test func noNowCardWhenEverythingHasBeenIdleLonger() {
        let ws = [workspace("a", "idle", minutesAgo: 30), workspace("b", "idle", minutesAgo: 10)]
        #expect(OverviewRules.nowWorkspace(ws, now: now) == nil)
        #expect(OverviewRules.nowWorkspace([], now: now) == nil)
        // A workspace with only a dev server has no agent to feature.
        #expect(OverviewRules.nowWorkspace([Workspace(root: "/tmp/demo/server-only")], now: now) == nil)
    }

    @Test func subagentsAtWorkCountAsWorking() {
        let ws = [workspace("recent", "idle", minutesAgo: 1), workspace("helpers", "idle", minutesAgo: 50)]
        let featured = OverviewRules.nowWorkspace(ws, now: now) { $0.isBusy || $0.name == "helpers" }
        #expect(featured?.name == "helpers")
    }

    // MARK: Servers card and clean-up line

    @Test func serversCardOnlyForServersOutsideEveryWorkspace() {
        #expect(!OverviewRules.showsServersCard(looseServers: []))
        var docker = Listener(pid: 2, port: 5432, command: "com.docker.backend", address: "127.0.0.1")
        docker.isDev = true
        #expect(OverviewRules.showsServersCard(looseServers: [docker]))
    }

    @Test func cleanupLineFromOneGigabyteOnceScanned() {
        #expect(!OverviewRules.showsCleanupLine(scanned: false, total: 7_000_000_000))
        #expect(!OverviewRules.showsCleanupLine(scanned: true, total: 999_999_999))
        #expect(OverviewRules.showsCleanupLine(scanned: true, total: 1_000_000_000))
        #expect(CleanupLine.text(7_000_000_000) == "7 GB of rebuildable caches")
    }

    // MARK: Plan strip

    private func limit(_ label: String, _ used: Double, hoursLeft: Double?, windowHours: Double?) -> RateLimit {
        RateLimit(label: label, usedPercent: used, resetsAt: hoursLeft.map { now.addingTimeInterval($0 * 3600) },
                  window: windowHours.map { $0 * 3600 })
    }

    @Test func tightestIsTheHighestShareWhenNothingIsRunningOut() {
        let fiveHour = limit("5-hour", 21, hoursLeft: 3.4, windowHours: 5)
        let weekly = limit("Weekly", 34, hoursLeft: 4.1 * 24, windowHours: 168)
        #expect(PlanStrip.tightest([fiveHour, weekly], now: now)?.label == "Weekly")
        // A tie keeps the provider's order.
        let a = limit("5-hour", 0, hoursLeft: 4.9, windowHours: 5), b = limit("Weekly", 0, hoursLeft: 160, windowHours: 168)
        #expect(PlanStrip.tightest([a, b], now: now)?.label == "5-hour")
        #expect(PlanStrip.tightest([], now: now) == nil)
    }

    @Test func tightestPrefersALimitOnCourseToRunOut() {
        // Half the 5-hour window gone with 60% used: on course to run out. The weekly is fuller but on pace.
        let fiveHour = limit("5-hour", 60, hoursLeft: 2.5, windowHours: 5)
        let weekly = limit("Weekly", 75, hoursLeft: 24, windowHours: 168)
        #expect(PlanStrip.atRisk(fiveHour.pace(now: now)))
        #expect(!PlanStrip.atRisk(weekly.pace(now: now)))
        #expect(PlanStrip.tightest([weekly, fiveHour], now: now)?.label == "5-hour")
        // Used up counts as at risk too, and shows its real figure.
        let usedUp = limit("Weekly", 104, hoursLeft: 24, windowHours: 168)
        #expect(PlanStrip.tightest([fiveHour, usedUp], now: now)?.label == "Weekly")
        #expect(Fmt.usedPercent(usedUp.usedPercent) == "104% used")
    }

    @Test func tightestLeavesOutLimitsWithNoWindowUnlessThereIsNothingElse() {
        // The owner's real quiet day: 5-hour 7%, Weekly 0%, Extra usage 27%. The strip headlines the 5-hour limit.
        let fiveHour = limit("5-hour", 7, hoursLeft: 4.6, windowHours: 5)
        let weekly = limit("Weekly", 0, hoursLeft: 6.9 * 24, windowHours: 168)
        let extra = limit("Extra usage", 27, hoursLeft: nil, windowHours: nil)
        #expect(!PlanStrip.isWindowed(extra))
        #expect(PlanStrip.tightest([fiveHour, weekly, extra], now: now)?.label == "5-hour")
        #expect(PlanStrip.tightest([extra, weekly], now: now)?.label == "Weekly")
        // A reset time alone (a status line reading with no window length) still counts as a window.
        let resetOnly = limit("Weekly", 2, hoursLeft: 30, windowHours: nil)
        #expect(PlanStrip.tightest([extra, resetOnly], now: now)?.label == "Weekly")
        // Extra usage on its own is still shown rather than nothing.
        #expect(PlanStrip.tightest([extra], now: now)?.label == "Extra usage")
    }

    @Test func stripCaptionOnlyWhenRunningOutOrUsedUp() {
        #expect(PlanStrip.showsCaption(.runsOut(now)))
        #expect(PlanStrip.showsCaption(.usedUp))
        #expect(!PlanStrip.showsCaption(.under))
        #expect(!PlanStrip.showsCaption(.onPace))
        #expect(!PlanStrip.showsCaption(nil))
    }

    @Test func stripRowReadsAsOneSentence() {
        let l = limit("5-hour", 55, hoursLeft: 2.2, windowHours: 5)
        #expect(PlanStrip.spoken(provider: "Claude", limit: l, now: now) == "Claude, 5-hour limit, 55 percent used, resets in 2h 12m")
        let out = limit("5-hour", 80, hoursLeft: 2.5, windowHours: 5)
        #expect(PlanStrip.spoken(provider: "Claude", limit: out, now: now).contains("At this rate, runs out"))
    }

    @Test func secondTabIsCalledUsageButKeepsItsKey() {
        #expect(PanelTab.agents.title == "Usage")
        #expect(PanelTab.agents.rawValue == "agents")
        #expect(PanelTab.allCases.firstIndex(of: .agents) == 1)   // still ⌘2
    }
}
