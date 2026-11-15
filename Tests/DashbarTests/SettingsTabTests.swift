import Foundation
import Testing
@testable import Dashbar

@Suite struct SettingsTabTests {
    @Test func linksOpenTheTabWhereTheSettingLives() {
        #expect(SettingsTab.claudeLimits == .integrations)
        #expect(SettingsTab.permissionPrompts == .integrations)
        #expect(SettingsTab.otherAccounts == .accounts)
        #expect(SettingsTab.cleanupFolders == .folders)
        #expect(SettingsTab.alerts == .notifications)
    }

    @Test func everyTabRoundTripsByName() {
        for tab in SettingsTab.allCases {
            #expect(SettingsTab(name: tab.rawValue) == tab)
            #expect(!tab.title.isEmpty)
        }
    }

    @Test func labsIsNowIntegrations() {
        #expect(SettingsTab(rawValue: "labs") == nil)
        #expect(SettingsTab(name: "labs") == .integrations)
        #expect(SettingsTab(name: "nonsense") == nil)
    }

    @Test func savedOldTabIsMoved() throws {
        try withTestDefaults { defaults in
            defaults.set("labs", forKey: SettingsTab.key)
            SettingsTab.migrateSaved(defaults)
            #expect(defaults.string(forKey: SettingsTab.key) == "integrations")

            defaults.set("gone", forKey: SettingsTab.key)
            SettingsTab.migrateSaved(defaults)
            #expect(defaults.string(forKey: SettingsTab.key) == "general")

            defaults.set("menuBar", forKey: SettingsTab.key)
            SettingsTab.migrateSaved(defaults)
            #expect(defaults.string(forKey: SettingsTab.key) == "menuBar")
        }
    }
}
