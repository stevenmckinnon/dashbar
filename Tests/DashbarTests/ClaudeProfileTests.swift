import Foundation
import Testing
@testable import Dashbar

/// The plan name from Claude Code's `.claude.json` profile, read from throwaway folders.
@Suite struct ClaudeProfileTests {
    /// A `.claude.json` with other keys around the profile, as the real file has.
    @discardableResult
    func writeProfile(_ fx: Fixture, _ folder: String, account: [String: Any]?) throws -> URL {
        var obj: [String: Any] = ["numStartups": 12, "projects": ["/Users/x/dev/app": ["allowedTools": []]]]
        if let account { obj["oauthAccount"] = account }
        let dir = try fx.dir(folder)
        let url = dir.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    func plan(_ account: [String: Any]?) throws -> ClaudeProfile.Plan {
        let fx = try Fixture()
        defer { fx.remove() }
        return ClaudeProfile.plan(at: try writeProfile(fx, "home", account: account))
    }

    @Test func maxPlansCarryTheirSize() throws {
        #expect(try plan(["organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_5x",
                          "billingType": "stripe_subscription"]) == .name("Max 5x"))
        #expect(try plan(["organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x"]) == .name("Max 20x"))
        #expect(try plan(["organizationType": "claude_max", "userRateLimitTier": "default_claude_max_20x"]) == .name("Max 20x"))
        #expect(try plan(["organizationType": "claude_max"]) == .name("Max"))
    }

    @Test func otherKnownPlans() throws {
        #expect(try plan(["organizationType": "claude_pro", "organizationRateLimitTier": "default_claude_ai"]) == .name("Pro"))
        #expect(try plan(["organizationType": "claude_team", "organizationRateLimitTier": "default_claude_max_5x"]) == .name("Team"))
        #expect(try plan(["organizationType": "claude_enterprise"]) == .name("Enterprise"))
    }

    @Test func unknownPlansAreTidiedNotDropped() throws {
        #expect(try plan(["organizationType": "claude_super_duper"]) == .name("Super Duper"))
        #expect(try plan(["organizationType": "claude_mega", "organizationRateLimitTier": "default_claude_mega_50x"]) == .name("Mega 50x"))
        // No type: the tier still names it.
        #expect(try plan(["organizationRateLimitTier": "default_claude_max_20x"]) == .name("Max 20x"))
        // A profile that names nothing falls back to the Keychain.
        #expect(try plan(["billingType": "stripe_subscription"]) == .unknown)
    }

    @Test func noProfileMeansNoPlanNeverAStalePro() throws {
        let p = try plan(nil)   // an API key user: the file exists without `oauthAccount`
        #expect(p == .none)
        #expect(p.resolved(keychain: "Pro") == nil)
        #expect(ClaudeProfile.Plan.unknown.resolved(keychain: "Pro") == "Pro")
        #expect(ClaudeProfile.Plan.name("Max 5x").resolved(keychain: "Pro") == "Max 5x")
        let fx = try Fixture()
        defer { fx.remove() }
        #expect(ClaudeProfile.plan(at: fx.root.appendingPathComponent("missing.json")) == .unknown)
        let broken = fx.root.appendingPathComponent("broken.json")
        try Data("{ not json".utf8).write(to: broken)
        #expect(ClaudeProfile.plan(at: broken) == .unknown)
    }

    @Test func eachAccountReadsItsOwnFolder() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let home = try fx.dir("home")
        try writeProfile(fx, "home", account: ["organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_5x"])
        try writeProfile(fx, "home/.claude-work", account: ["organizationType": "claude_team"])
        let accounts = AgentAccounts.resolve(.claude, saved: [AgentAccount(kind: .claude, path: home.path + "/.claude-work", label: "")],
                                             environment: [:], home: home)
        #expect(ClaudeProfile.file(for: accounts[0], environment: [:], home: home).path == home.path + "/.claude.json")
        #expect(ClaudeProfile.file(for: accounts[1], environment: [:], home: home).path == home.path + "/.claude-work/.claude.json")
        #expect(ClaudeProfile.plan(at: ClaudeProfile.file(for: accounts[0], environment: [:], home: home)) == .name("Max 5x"))
        #expect(ClaudeProfile.plan(at: ClaudeProfile.file(for: accounts[1], environment: [:], home: home)) == .name("Team"))

        // Started with CLAUDE_CONFIG_DIR: the default account's file is inside that folder.
        let env = ["CLAUDE_CONFIG_DIR": home.path + "/.claude-work"]
        let custom = AgentAccounts.resolve(.claude, saved: [], environment: env, home: home)[0]
        #expect(ClaudeProfile.file(for: custom, environment: env, home: home).path == home.path + "/.claude-work/.claude.json")
    }

    @Test func aChangedFileIsReadAgain() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let url = try writeProfile(fx, "home", account: ["organizationType": "claude_pro"])
        #expect(ClaudeProfile.plan(at: url) == .name("Pro"))
        try writeProfile(fx, "home", account: ["organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(ClaudeProfile.plan(at: url) == .name("Max 20x"))
    }
}

@MainActor
@Suite struct ClaudePlanMonitorProfileTests {
    func harness(_ profile: ClaudeProfile.Plan) -> (MonitorHarness, ClaudePlanMonitor) {
        let h = MonitorHarness()
        let monitor = ClaudePlanMonitor(dependencies: .init(
            fetch: { [endpoint = h.endpoint] in endpoint.next() },
            refreshSignIn: { nil },
            now: { [unowned h] in h.now },
            loadShared: { [unowned h] in h.shared },
            saveShared: { [unowned h] in h.shared = $0 },
            readStatusLine: { [unowned h] in h.statusLine },
            after: { _, _ in },
            profilePlan: { _ in profile }))
        monitor.accounts = AgentAccounts.resolve(.claude, saved: [], environment: [:], home: URL(fileURLWithPath: "/Users/demo"))
        return (h, monitor)
    }

    @Test func theStatusLineShowsTheProfilesPlan() {
        let (h, monitor) = harness(.name("Max 5x"))
        h.statusLine = ClaudeStatusLine.Reading(writtenAt: h.now.addingTimeInterval(-30), limits: h.limits(20))
        monitor.setStatusLineEnabled(true)
        #expect(monitor.result?.plan == "Max 5x")
    }

    @Test func theProfileReplacesAStaleKeychainOrSharedPro() async {
        let (h, monitor) = harness(.name("Max 5x"))
        h.endpoint.enqueue(h.good(40))   // the Keychain still says "Pro"
        await monitor.setEndpointEnabled(true)?.value
        #expect(monitor.result?.plan == "Max 5x")
        #expect(h.shared?.plan == "Max 5x")   // and the shared file gets the right name

        let (h2, monitor2) = harness(.name("Max 5x"))
        h2.shared = ClaudePlanLimits.Shared(fetchedAt: h2.now.addingTimeInterval(-30), plan: "Pro", limits: h2.limits(61))
        await monitor2.setEndpointEnabled(true)?.value
        #expect(h2.endpoint.calls == 0)
        #expect(monitor2.result?.plan == "Max 5x")
    }

    @Test func noProfileShowsNoPlanAndAnUnreadableOneKeepsTheKeychains() async {
        let (h, monitor) = harness(.none)
        h.endpoint.enqueue(h.good(40))
        await monitor.setEndpointEnabled(true)?.value
        #expect(monitor.result?.plan == nil)

        let (h2, monitor2) = harness(.unknown)
        h2.endpoint.enqueue(h2.good(40))
        await monitor2.setEndpointEnabled(true)?.value
        #expect(monitor2.result?.plan == "Pro")
    }
}
