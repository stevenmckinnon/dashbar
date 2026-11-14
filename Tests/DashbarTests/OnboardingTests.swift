import Testing
@testable import Dashbar

@Suite struct OnboardingTests {
    @Test func newUserSeesIt() {
        #expect(Onboarding.shouldShow(seen: false, storedKeys: [], hasSavedData: false))
    }

    @Test func sparkleKeysAloneDoNotCountAsEarlierUse() {
        // Sparkle writes these during the very first launch.
        #expect(Onboarding.shouldShow(seen: false, storedKeys: ["SUHasLaunchedBefore", "SUEnableAutomaticChecks"], hasSavedData: false))
    }

    @Test func shownOnce() {
        #expect(!Onboarding.shouldShow(seen: true, storedKeys: [], hasSavedData: false))
    }

    @Test func existingUsersAreNotInterrupted() {
        #expect(!Onboarding.shouldShow(seen: false, storedKeys: ["panelTab"], hasSavedData: false))
        #expect(!Onboarding.shouldShow(seen: false, storedKeys: ["claudeLimitsExperimental"], hasSavedData: false))
        #expect(!Onboarding.shouldShow(seen: false, storedKeys: ["limitAlertsSent"], hasSavedData: false))
        #expect(!Onboarding.shouldShow(seen: false, storedKeys: ["NSWindow Frame DashbarWindow"], hasSavedData: false))
        #expect(!Onboarding.shouldShow(seen: false, storedKeys: ["com_apple_SwiftUI_Settings_selectedTabIndex"], hasSavedData: false))
    }

    @Test func savedScanCountsAsEarlierUse() {
        // Someone who never changed a setting still has a saved usage scan in Application Support.
        #expect(!Onboarding.shouldShow(seen: false, storedKeys: [], hasSavedData: true))
    }
}
