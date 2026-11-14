import Foundation
import CoreGraphics
import Testing
@testable import Dashbar

// MARK: - Menu bar item: which state wins, and what the text says

@Suite struct MenuBarStatusTests {
    let now = Date(timeIntervalSince1970: 100_000)
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    typealias S = MenuBarStatus

    func make(busy: [Date] = [], waiting: Int = 0, finished: String? = nil, mode: S.TextMode = .count,
              animate: Bool = true, extras: [S.Group] = []) -> S {
        S.make(busySince: busy, waiting: waiting, finished: finished, mode: mode, animate: animate, extras: extras, now: now)
    }

    @Test func idleShowsJustTheMark() {
        let s = make()
        #expect(s.state == .idle)
        #expect(s.groups.isEmpty)
        #expect(!s.animates && !s.busy && !s.isColoured)
    }

    @Test func workingShowsTheCountAndAnimates() {
        let s = make(busy: [ago(60), ago(30)])
        #expect(s.state == .working(2))
        #expect(s.groups == [[.text("2")]])
        #expect(s.animates && s.busy)
        #expect(!s.isColoured)   // a template image: the system tints it like any menu bar item
    }

    @Test func animationOffOrReduceMotionHoldsStill() {
        let s = make(busy: [ago(60)], animate: false)
        #expect(!s.animates)
        #expect(s.busy)   // the full bar still says "working"
    }

    @Test func needsYouOutranksWorkingAndDone() {
        let s = make(busy: [ago(60), ago(30)], waiting: 1, finished: "storefront-web")
        #expect(s.state == .needsYou(1))
        #expect(s.groups == [[.symbol("hand.raised.fill", .attention), .text("1", .attention)]])
        #expect(s.isColoured)
        #expect(!s.animates)   // amber is the one thing that draws the eye
    }

    @Test func needsYouShowsEvenWithNoText() {
        let s = make(waiting: 2, mode: .none)
        #expect(s.groups == [[.symbol("hand.raised.fill", .attention), .text("2", .attention)]])
    }

    @Test func doneReplacesTheCountAndKeepsAnimatingWhileOthersWork() {
        let s = make(busy: [ago(60)], finished: "storefront-web")
        #expect(s.state == .done(project: "storefront-web"))
        #expect(s.groups == [[.text("Done", .success), .text(" · storefront-web", .secondary)]])
        #expect(s.isColoured)
        #expect(s.animates)
    }

    @Test func doneCutsLongProjectNamesShort() {
        let s = make(finished: "a-very-long-project-name-indeed")
        #expect(s.groups.first?.last == .text(" · a-very-long-pro…", .secondary))
        #expect(S.shortProject("docs") == "docs")
    }

    @Test func textModes() {
        let busy = [ago(14 * 60 + 5), ago(90)]
        #expect(make(busy: busy, mode: .none).groups.isEmpty)
        #expect(make(busy: busy, mode: .count).groups == [[.text("2")]])
        // The longest-running agent's time.
        #expect(make(busy: busy, mode: .countTime).groups == [[.text("2"), .text(" · 14m", .secondary)]])
    }

    @Test func extrasFollowTheAgentText() {
        let plan: S.Group = [.symbol("gauge.with.needle"), .text("5h 51% left")]
        #expect(make(extras: [plan]).groups == [plan])
        #expect(make(busy: [ago(5)], extras: [plan]).groups == [[.text("1")], plan])
        #expect(make(waiting: 1, extras: [plan]).groups.last == plan)
    }

    @Test func elapsedIsShort() {
        #expect(S.elapsed(20) == "<1m")
        #expect(S.elapsed(14 * 60 + 59) == "14m")
        #expect(S.elapsed(3600) == "1h")
        #expect(S.elapsed(3600 + 5 * 60) == "1h 5m")
        #expect(S.elapsed(2 * 86400 + 3 * 3600 + 60) == "2d 3h")
        #expect(S.elapsed(-5) == "<1m")
    }

    @Test func sweepFillsThenRestsFull() {
        let cycle = S.sweepFrames + S.holdFrames
        #expect(abs(S.sweep(tick: 0) - 0.3) < 0.001)
        #expect(S.sweep(tick: S.sweepFrames - 1) == 1)
        // Rising through the sweep, then full until the next one.
        for t in 1..<S.sweepFrames { #expect(S.sweep(tick: t) > S.sweep(tick: t - 1)) }
        for t in S.sweepFrames..<cycle { #expect(S.sweep(tick: t) == 1) }
        #expect(S.sweep(tick: cycle) == S.sweep(tick: 0))
        // Few changes per cycle: each one costs the menu bar a redraw.
        let distinct = Set((0..<cycle).map { S.sweep(tick: $0) })
        #expect(distinct.count == S.sweepFrames)
    }

    @Test func accessibilityText() {
        #expect(make(busy: [ago(5)]).accessibilityText.hasSuffix("1 agent working"))
        #expect(make(waiting: 2).accessibilityText.hasSuffix("2 agents need you"))
        #expect(make(finished: "docs").accessibilityText.hasSuffix("agent done in docs"))
    }
}
