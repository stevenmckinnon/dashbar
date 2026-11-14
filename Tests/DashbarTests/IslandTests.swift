import Foundation
import CoreGraphics
import Testing
@testable import Dashbar

// MARK: - Dashbar Island: status, expansion, auto-collapse and placement

@Suite struct IslandTests {
    func session(_ id: String, _ status: String, waitingFor: String? = nil) -> LiveSession {
        LiveSession(id: id, pid: 1, name: "Task \(id)", cwd: "/p/\(id)", status: status, since: Date(timeIntervalSince1970: 0),
                    entrypoint: "cli", root: "/p/\(id)", waitingFor: waitingFor)
    }

    func request(_ id: String, session: String) -> PermissionRequest {
        PermissionRequest(id: id, sessionId: session, cwd: "/p/\(session)", tool: "Bash", input: ["command": "ls"],
                          agentType: nil, created: Date(timeIntervalSince1970: 0), expires: Date(timeIntervalSince1970: 60), pid: 1)
    }

    let t0 = Date(timeIntervalSince1970: 1_000)
    let on = IslandSettings.Values(enabled: true)

    // MARK: Status

    @Test func needsYouOutranksWorkingWhichOutranksIdle() {
        #expect(IslandStatus.of(sessions: [], permissionRequests: []) == .idle)
        #expect(IslandStatus.of(sessions: [session("a", "idle")], permissionRequests: []) == .idle)
        #expect(IslandStatus.of(sessions: [session("a", "busy"), session("b", "busy")], permissionRequests: []) == .working(2))
        #expect(IslandStatus.of(sessions: [session("a", "busy"), session("b", "waiting")], permissionRequests: []) == .needsYou(1))
    }

    @Test func aPromptWithoutAVisibleSessionStillNeedsYou() {
        // A prompt whose session is listed is already counted by that session's waiting state.
        let listed = IslandStatus.of(sessions: [session("a", "waiting")], permissionRequests: [request("r", session: "a")])
        #expect(listed == .needsYou(1))
        let unseen = IslandStatus.of(sessions: [session("a", "busy")], permissionRequests: [request("r", session: "zzz")])
        #expect(unseen == .needsYou(1))
    }

    @Test func labels() {
        #expect(IslandStatus.working(2).label == "2 working")
        #expect(IslandStatus.needsYou(1).label == "1 needs you")
        #expect(IslandStatus.needsYou(3).label == "3 need you")
    }

    // MARK: Expansion rules

    @Test func idleIsHiddenAndABannerShowsOverIt() {
        var p = IslandPresenter()
        #expect(p.mode(status: .idle) == .hidden)
        #expect(p.mode(status: .working(1)) == .collapsed(.working(1)))
        let b = IslandBanner(kind: .finished(after: 60), sessionID: "a", shownAt: t0)
        let posted1 = p.post(b, settings: on, now: t0)
        #expect(posted1)
        #expect(p.mode(status: .idle) == .banner(b))
    }

    @Test func turnedOffKindsNeverExpand() {
        var p = IslandPresenter()
        var settings = on
        settings.expandOnFinish = false
        let posted2 = p.post(IslandBanner(kind: .finished(after: 60), sessionID: "a", shownAt: t0), settings: settings, now: t0)
        #expect(!posted2)
        let posted3 = p.post(IslandBanner(kind: .waiting, sessionID: "a", shownAt: t0), settings: settings, now: t0)
        #expect(posted3)
        settings.expandOnNeedsYou = false
        var q = IslandPresenter()
        let posted4 = q.post(IslandBanner(kind: .permission(requestID: "r"), sessionID: "a", shownAt: t0), settings: settings, now: t0)
        #expect(!posted4)
        var off = IslandPresenter()
        let posted5 = off.post(IslandBanner(kind: .waiting, sessionID: "a", shownAt: t0), settings: IslandSettings.Values(enabled: false), now: t0)
        #expect(!posted5)
    }

    @Test func aMoreImportantMomentIsNotReplacedByALesserOne() {
        var p = IslandPresenter()
        let permission = IslandBanner(kind: .permission(requestID: "r"), sessionID: "a", shownAt: t0)
        p.post(permission, settings: on, now: t0)
        let posted6 = p.post(IslandBanner(kind: .finished(after: 60), sessionID: "b", shownAt: t0 + 1), settings: on, now: t0 + 1)
        #expect(!posted6)
        #expect(p.banner == permission)
        // The same kind replaces it: the newest wins.
        let newer = IslandBanner(kind: .permission(requestID: "s"), sessionID: "b", shownAt: t0 + 2)
        let posted7 = p.post(newer, settings: on, now: t0 + 2)
        #expect(posted7)
        #expect(p.banner == newer)
        // Once it has expired, anything may show.
        let later = t0 + 2 + IslandBanner.Kind.permission(requestID: "s").duration + 1
        let posted8 = p.post(IslandBanner(kind: .finished(after: 60), sessionID: "c", shownAt: later), settings: on, now: later)
        #expect(posted8)
    }

    @Test func bannersThatNoLongerHoldAreDropped() {
        var p = IslandPresenter()
        p.post(IslandBanner(kind: .permission(requestID: "r"), sessionID: "a", shownAt: t0), settings: on, now: t0)
        p.reconcile(sessions: [session("a", "waiting")], permissionRequests: [request("r", session: "a")])
        #expect(p.banner != nil)
        p.reconcile(sessions: [session("a", "busy")], permissionRequests: [])   // answered
        #expect(p.banner == nil)

        p.post(IslandBanner(kind: .waiting, sessionID: "a", shownAt: t0), settings: on, now: t0)
        p.reconcile(sessions: [session("a", "busy")], permissionRequests: [])   // replied in the terminal
        #expect(p.banner == nil)

        p.post(IslandBanner(kind: .finished(after: 60), sessionID: "a", shownAt: t0), settings: on, now: t0)
        p.reconcile(sessions: [session("a", "idle")], permissionRequests: [])
        #expect(p.banner != nil)
        p.reconcile(sessions: [session("a", "busy")], permissionRequests: [])   // already back at work
        #expect(p.banner == nil)
    }

    // MARK: Auto-collapse timing

    @Test func aBannerFoldsAwayAfterItsDuration() {
        var p = IslandPresenter()
        let b = IslandBanner(kind: .finished(after: 60), sessionID: "a", shownAt: t0)
        p.post(b, settings: on, now: t0)
        #expect(p.deadline() == t0 + 5)
        p.expire(now: t0 + 4.9)
        #expect(p.banner != nil)
        p.expire(now: t0 + 5)
        #expect(p.banner == nil)
        #expect(p.deadline() == nil)   // nothing left to wake up for
    }

    @Test func hoverHoldsItOpenAndLeavingGivesAGracePeriod() {
        var p = IslandPresenter()
        p.post(IslandBanner(kind: .finished(after: 60), sessionID: "a", shownAt: t0), settings: on, now: t0)
        p.pointer(inside: true, now: t0 + 2)
        #expect(p.deadline() == nil)
        p.expire(now: t0 + 60)
        #expect(p.banner != nil)
        p.pointer(inside: false, now: t0 + 60)
        #expect(p.deadline() == t0 + 60 + IslandPresenter.hoverGrace)
        // Leaving early keeps the natural end.
        var q = IslandPresenter()
        q.post(IslandBanner(kind: .finished(after: 60), sessionID: "a", shownAt: t0), settings: on, now: t0)
        q.pointer(inside: true, now: t0 + 1)
        q.pointer(inside: false, now: t0 + 1.2)
        #expect(q.deadline() == t0 + 5)
    }

    @Test func theListOpensOnlyWithoutABannerAndCloses() {
        var p = IslandPresenter()
        p.openList()
        #expect(p.mode(status: .idle) == .list)
        p.closeList()
        #expect(p.mode(status: .idle) == .hidden)
        p.post(IslandBanner(kind: .waiting, sessionID: "a", shownAt: t0), settings: on, now: t0)
        p.openList()
        if case .banner = p.mode(status: .needsYou(1)) {} else { Issue.record("banner should win over the list") }
    }

    // MARK: Notifications

    @Test func notificationsAreLeftOutOnlyWhenTheIslandShowsTheMoment() {
        var s = IslandSettings.Values(enabled: true, replacesNotifications: true)
        #expect(s.suppressesNotification(for: .finished(after: 60)))
        #expect(s.suppressesNotification(for: .permission(requestID: "r")))
        s.expandOnFinish = false
        #expect(!s.suppressesNotification(for: .finished(after: 60)))
        s.enabled = false
        #expect(!s.suppressesNotification(for: .waiting))
        #expect(!IslandSettings.Values(enabled: true, replacesNotifications: false).suppressesNotification(for: .waiting))
    }

    @Test func settingsReadDefaultsWhenUnset() throws {
        let defaults = try #require(UserDefaults(suiteName: "IslandTests-\(UUID().uuidString)"))
        let v = IslandSettings.Values.read(defaults)
        #expect(v == IslandSettings.Values(enabled: false, position: .automatic, expandOnFinish: true, expandOnNeedsYou: true,
                                           replacesNotifications: false))
        defaults.set(true, forKey: IslandSettings.enabledKey)
        defaults.set("right", forKey: IslandSettings.positionKey)
        #expect(IslandSettings.Values.read(defaults).enabled)
        #expect(IslandSettings.Values.read(defaults).position == .right)
    }

    // MARK: Placement

    /// A 14-inch MacBook Pro as NSScreen reports it: 1512 × 982, a 185 × 32 notch, a 33-point menu bar.
    let macBook = IslandScreen.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                    topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                    topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32), menuBarHeight: 33)
    let external = IslandScreen.make(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                     topLeft: nil, topRight: nil, menuBarHeight: 25)

    @Test func theNotchIsFoundFromTheSafeAreaAndTheAreasBesideIt() {
        #expect(macBook.notch == CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(external.notch == nil)
        // A safe area without the side areas (or the other way round) is not a notch.
        #expect(IslandScreen.make(frame: CGRect(x: 0, y: 0, width: 100, height: 100), safeAreaTop: 20, topLeft: nil, topRight: nil,
                                  menuBarHeight: 24).notch == nil)
    }

    @Test func onTheNotchItGrowsFromTheTopEdgeCentredOnIt() {
        let p = IslandPlacement.place(on: macBook, position: .automatic)
        #expect(p.style == .notch(width: 185, height: 32))
        let f = p.frame(for: CGSize(width: 400, height: 32))
        #expect(f == CGRect(x: 556, y: 950, width: 400, height: 32))
        #expect(f.midX == macBook.notch!.midX)
        #expect(f.maxY == 982)
    }

    @Test func withoutANotchItFloatsBelowTheMenuBar() {
        let p = IslandPlacement.place(on: external, position: .centre)
        #expect(p.style == .floating)
        let f = p.frame(for: CGSize(width: 120, height: 30))
        #expect(f.midX == 1280)
        #expect(f.maxY == 1440 - 25 - IslandPlacement.floatingGap)
    }

    @Test func besideTheNotchItTouchesItsEdge() {
        let left = IslandPlacement.place(on: macBook, position: .left).frame(for: CGSize(width: 150, height: 32))
        #expect(left.maxX == 663.5 && left.maxY == 982)
        let right = IslandPlacement.place(on: macBook, position: .right).frame(for: CGSize(width: 150, height: 32))
        #expect(right.minX == 848.5 && right.maxY == 982)
        // Without a notch it keeps clear of the middle, where another app's island would be.
        let r = IslandPlacement.place(on: external, position: .right).frame(for: CGSize(width: 150, height: 25))
        #expect(r.minX == 1280 + IslandPlacement.besideClearance / 2)
    }

    @Test func automaticStacksBelowAnotherAppsIsland() {
        // Another island hanging 60 points from the top of the notch.
        let other = CGRect(x: 600, y: 982 - 60, width: 312, height: 60)
        let p = IslandPlacement.place(on: macBook, position: .automatic, obstacles: [other])
        #expect(p.style == .floating)
        #expect(p.topY == 982 - 60 - IslandPlacement.floatingGap)
        #expect(p.frame(for: CGSize(width: 140, height: 30)).midX == 756)
        // A window elsewhere doesn't move it, and a fixed position ignores neighbours.
        #expect(IslandPlacement.place(on: macBook, position: .automatic, obstacles: [CGRect(x: 0, y: 0, width: 50, height: 50)]).style
                == .notch(width: 185, height: 32))
        #expect(IslandPlacement.place(on: macBook, position: .centre, obstacles: [other]).style == .notch(width: 185, height: 32))
    }

    @Test func neighboursAreOtherAppsWindowsAboveTheMenuBarAtTheNotch() {
        func window(_ owner: String, pid: Int, layer: Int, x: Double, y: Double, w: Double, h: Double, alpha: Double = 1) -> [String: Any] {
            [kCGWindowOwnerName as String: owner, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: Any]]
        }
        let band = IslandPlacement.centreBand(macBook)
        let windows = [
            window("T3 Code", pid: 10, layer: 27, x: 600, y: 0, w: 312, h: 60),          // another island: counts
            window("Window Server", pid: 11, layer: 24, x: 0, y: 0, w: 1512, h: 33),     // the menu bar
            window("Control Center", pid: 12, layer: 25, x: 700, y: 0, w: 40, h: 33),    // system
            window("Some App", pid: 13, layer: 0, x: 600, y: 0, w: 400, h: 400),         // an ordinary window
            window("Ghost", pid: 14, layer: 30, x: 600, y: 0, w: 300, h: 40, alpha: 0),  // invisible
            window("Dashbar", pid: 99, layer: 26, x: 600, y: 0, w: 300, h: 32),          // ourselves
            window("Far", pid: 15, layer: 30, x: 1300, y: 0, w: 100, h: 30),             // nowhere near the notch
        ]
        let found = IslandNeighbours.obstacles(in: windows, ownPID: 99, isLocalBuild: false, primaryHeight: 982, band: band)
        #expect(found == [CGRect(x: 600, y: 982 - 60, width: 312, height: 60)])
    }

    @Test func aLocalBuildMakesWayForTheReleaseButNotTheOtherWayRound() {
        let band = IslandPlacement.centreBand(macBook)
        let release: [String: Any] = [kCGWindowOwnerName as String: "Dashbar", kCGWindowOwnerPID as String: 1, kCGWindowLayer as String: 26,
                                      kCGWindowBounds as String: ["X": 600.0, "Y": 0.0, "Width": 300.0, "Height": 32.0] as [String: Any]]
        let local: [String: Any] = [kCGWindowOwnerName as String: "Dashbar Local", kCGWindowOwnerPID as String: 2, kCGWindowLayer as String: 26,
                                    kCGWindowBounds as String: ["X": 600.0, "Y": 0.0, "Width": 300.0, "Height": 32.0] as [String: Any]]
        #expect(IslandNeighbours.obstacles(in: [release], ownPID: 2, isLocalBuild: true, primaryHeight: 982, band: band).count == 1)
        #expect(IslandNeighbours.obstacles(in: [local], ownPID: 1, isLocalBuild: false, primaryHeight: 982, band: band).isEmpty)
    }
}
