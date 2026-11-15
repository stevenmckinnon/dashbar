import CoreGraphics
import Testing
@testable import Dashbar

// MARK: - The panel fits its tab, between a floor and the screen's cap

struct PanelSizingTests {
    @Test func shortContentGetsTheFloorLongContentTheCap() {
        #expect(PanelSizing.scrollHeight(content: 40, cap: 600) == PanelSizing.minScroll)
        #expect(PanelSizing.scrollHeight(content: 2_000, cap: 600) == 600)
        #expect(PanelSizing.scrollHeight(content: 345, cap: 600) == 345)
    }

    @Test func heightsRoundUpToWholePointsIgnoringFloatNoise() {
        #expect(PanelSizing.quantise(344.2) == 345)
        #expect(PanelSizing.quantise(345.004) == 345)
        #expect(PanelSizing.quantise(345) == 345)
        #expect(PanelSizing.quantise(0) == 0)
        #expect(PanelSizing.quantise(.infinity) == 0)
        #expect(PanelSizing.quantise(.nan) == 0)
    }

    @Test func theCapFollowsTheScreenWithinTheOldFixedRange() {
        #expect(PanelSizing.maxScroll(screenHeight: 400) == 420)    // tiny screen: still usable
        #expect(PanelSizing.maxScroll(screenHeight: 750) == 590)
        #expect(PanelSizing.maxScroll(screenHeight: 1_400) == 680)  // big screen: no taller than before
    }

    @Test func nothingMeasuredMeansTheFloorNotZero() {
        #expect(PanelSizing.scrollHeight(content: 0, cap: 600) == PanelSizing.minScroll)
    }
}
