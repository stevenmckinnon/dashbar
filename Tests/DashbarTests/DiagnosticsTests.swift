import Foundation
import Testing
@testable import Dashbar

/// Settings → About → Copy Diagnostics: what the copied text says, and that nothing private gets into it.
@Suite struct DiagnosticsTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let app = Diagnostics.App(version: "0.11.0", build: "412", isLocal: false,
                                     macOS: "27.2 (Build 26C5049a)", appleSilicon: true)

    static func context(hidden: Set<HideableTool> = [], claudeAccounts: Int = 1, codexAccounts: Int = 1,
                        statusLineOn: Bool = false, requestOn: Bool = false,
                        appGroup: Bool = true) -> Diagnostics.Context {
        .init(app: app, present: [.codex, .copilot], geminiPresent: false, antigravityPresent: false,
              visibility: ToolVisibility(hidden: hidden),
              bridges: [
                .init(bridge: .claudeStatusLine, installed: true, accounts: claudeAccounts > 1 ? (1, claudeAccounts) : nil),
                .init(bridge: .claudePermissionHook, installed: false, accounts: claudeAccounts > 1 ? (0, claudeAccounts) : nil),
                .init(bridge: .antigravityStatusLine, installed: nil),
                .init(bridge: .opencodePlugin, installed: nil),
                .init(bridge: .copilotHook, installed: true),
                .init(bridge: .commandLineTool, installed: false),
              ],
              widgets: .init(appGroup: appGroup, lastWritten: appGroup ? now.addingTimeInterval(-150) : nil),
              claudeAccounts: claudeAccounts, codexAccounts: codexAccounts,
              statusLineOn: statusLineOn, requestOn: requestOn)
    }

    /// The demo store, plus every kind of private-looking string the store can hold: project and folder names, session
    /// ids and titles, account labels and folders, an email, a permission prompt's command.
    @MainActor static func privateStore() -> (Store, [String]) {
        let store = Store(demo: true)
        let secrets = [
            "acme-secret-merger", "/Users/jane.doe/Clients/acme-secret-merger", "jane.doe", "Jane Doe",
            "jane@acme-corp.example", "Acme Work Account", "/Users/jane.doe/.claude-acme",
            "session-7f3a9c1e-private", "Refactor the payroll export for Acme", "sk-ant-oat01-SECRET", "jane-mbp.local",
        ]
        store.sessions.append(LiveSession(
            id: "session-7f3a9c1e-private", pid: 4242, name: "Refactor the payroll export for Acme",
            cwd: "/Users/jane.doe/Clients/acme-secret-merger/src", status: "busy", since: now, entrypoint: "cli",
            root: "/Users/jane.doe/Clients/acme-secret-merger", account: "Acme Work Account",
            configDir: "/Users/jane.doe/.claude-acme"))
        store.claudeDefaultLabel = "jane@acme-corp.example"
        store.claudeAccountLimits = [AccountLimits(label: "Acme Work Account", path: "/Users/jane.doe/.claude-acme",
                                                   limits: [RateLimit(label: "5-hour", usedPercent: 10, resetsAt: nil)])]
        store.permissionRequests = [PermissionRequest(
            id: String(repeating: "e", count: 32), sessionId: "session-7f3a9c1e-private",
            cwd: "/Users/jane.doe/Clients/acme-secret-merger", tool: "Bash",
            input: ["command": "cat ~/.ssh/id_rsa # jane-mbp.local sk-ant-oat01-SECRET"], agentType: nil,
            created: now, expires: now.addingTimeInterval(60), pid: 4242)]
        // Real warnings, as the UI shows them.
        store.sessionsWarning = ClaudeSessions.formatWarning
        store.codex.warning = FormatHealth(source: "Codex").warningForTest
        store.googleWarning = AntigravityApp.formatWarning
        return (store, secrets + store.sessions.flatMap { [$0.id, $0.name, $0.cwd, $0.root, $0.project] })
    }

    @MainActor @Test func nothingPrivateGetsIn() {
        let (store, secrets) = Self.privateStore()
        let text = Diagnostics(store: store, context: Self.context(claudeAccounts: 2)).markdown(now: Self.now)
        for secret in Set(secrets) where !secret.isEmpty {
            #expect(!text.contains(secret), "leaked: \(secret)")
        }
        // No path, home folder, email or user name of any kind.
        #expect(!text.contains("/"))
        #expect(!text.contains("~"))
        #expect(!text.contains("@"))
        #expect(!text.contains(NSUserName()))
        #expect(!text.contains(String(repeating: "e", count: 32)))
        for account in store.claudeAccountLimits { #expect(!text.contains(account.label)) }
        // The warnings do come through, in their own words, under their tools.
        #expect(text.contains("- Claude Code: \(ClaudeSessions.formatWarning)"))
        #expect(text.contains("- Codex: Couldn't read Codex usage."))
        #expect(text.contains("- Antigravity: \(AntigravityApp.formatWarning)"))
        #expect(text.contains("- Extra Claude Code accounts: 1"))
    }

    /// A later change that let a path or an email into a warning, a version or the macOS line would still not leak it.
    @Test func unsafeFreeTextIsDropped() {
        #expect(Diagnostics.safe("Couldn't read Codex usage. Check for an update.") != nil)
        #expect(Diagnostics.safe("Couldn't read /Users/jane/project") == nil)
        #expect(Diagnostics.safe("Couldn't read ~/project") == nil)
        #expect(Diagnostics.safe("jane@example.com") == nil)
        #expect(Diagnostics.safe("two\nlines") == nil)
        #expect(Diagnostics.safe("   ") == nil)

        var d = Self.fixed()
        d.warnings = [.init(tool: .claude, text: "Couldn't read /Users/jane.doe/secret/session.jsonl")]
        d.tools[0].version = "2.1.0 (/opt/homebrew/bin/claude)"
        d.app.macOS = "27.2 on jane@host"
        let text = d.markdown(now: Self.now)
        #expect(!text.contains("jane"))
        #expect(text.contains("**Warnings**\n- None"))
        #expect(text.contains("- macOS: unknown"))
    }

    static func fixed() -> Diagnostics {
        Diagnostics(
            app: app,
            tools: [
                .init(tool: .claude, found: true, shown: true),
                .init(tool: .codex, found: true, shown: true),
                .init(tool: .geminiCLI, found: false, shown: true),
                .init(tool: .antigravity, found: false, shown: true),
                .init(tool: .opencode, found: true, shown: false),
                .init(tool: .copilot, found: true, shown: true),
            ],
            warnings: [.init(tool: .copilot, text: CopilotCLI.formatWarning)],
            bridges: context(claudeAccounts: 2).bridges,
            widgets: .init(appGroup: true, lastWritten: now.addingTimeInterval(-150)),
            extraClaudeAccounts: 1, extraCodexAccounts: 0,
            claudeLimits: .init(source: .statusLine, hasReading: true, stale: true))
    }

    @Test func shape() {
        let expected = """
        ### Dashbar diagnostics

        - Dashbar: 0.11.0 (build 412), release
        - macOS: 27.2 (Build 26C5049a)
        - Mac: Apple silicon

        **Tools**
        - Claude Code: found
        - Codex: found
        - Gemini CLI: not found
        - Antigravity: not found
        - OpenCode: found, switched off in Show in Dashbar
        - GitHub Copilot: found

        **Warnings**
        - GitHub Copilot: Couldn't read GitHub Copilot's usage. Its session log format may have changed, so check for a Dashbar update.

        **Integrations**
        - Claude Code status line: yes (in 1 of 2 accounts)
        - Claude Code permission hook: no (in 0 of 2 accounts)
        - Antigravity CLI status line: not applicable
        - OpenCode plugin: not applicable
        - GitHub Copilot hook: yes
        - dashbar command on PATH: no

        **Widgets**
        - App Group: available
        - Widget data last written: 2 min ago

        **Accounts**
        - Extra Claude Code accounts: 1
        - Extra Codex accounts: 0

        **Claude plan limits**
        - Source: status line
        - Last reading: stale

        """
        #expect(Self.fixed().markdown(now: Self.now) == expected)
    }

    @MainActor @Test func fromTheStore() {
        let store = Store(demo: true)
        store.claudePlan = nil
        store.codex.warning = nil
        let d = Diagnostics(store: store, context: Self.context(hidden: [.google, .copilot], requestOn: true, appGroup: false))
        #expect(d.tools.first { $0.tool == .antigravity }?.shown == false)
        #expect(d.tools.first { $0.tool == .geminiCLI }?.shown == false)
        #expect(d.tools.first { $0.tool == .copilot }?.shown == false)
        #expect(d.tools.first { $0.tool == .claude }?.found == true)
        #expect(d.tools.first { $0.tool == .codex }?.found == true)
        #expect(d.extraClaudeAccounts == 0)
        // No reading yet: the source is what's switched on.
        #expect(d.claudeLimits == .init(source: .request, hasReading: false, stale: false))
        let text = d.markdown(now: Self.now)
        #expect(text.contains("- App Group: none (ad-hoc build)"))
        #expect(!text.contains("Widget data last written"))
        #expect(text.contains("- Last reading: none yet"))

        store.claudePlan = ClaudePlanLimits.Result(limits: [], fetchedAt: Self.now, source: .statusLine)
        let none = Diagnostics(store: store, context: Self.context())
        #expect(none.claudeLimits.source == .statusLine)
        let off = Diagnostics(store: { let s = Store(demo: true); s.claudePlan = nil; return s }(), context: Self.context())
        #expect(off.claudeLimits.source == .none)
        #expect(!off.markdown(now: Self.now).contains("Last reading"))
    }

    @Test func relativeTimes() {
        #expect(Diagnostics.ago(Self.now.addingTimeInterval(-5), now: Self.now) == "just now")
        #expect(Diagnostics.ago(Self.now.addingTimeInterval(-150), now: Self.now) == "2 min ago")
        #expect(Diagnostics.ago(Self.now.addingTimeInterval(-3 * 3600), now: Self.now) == "3 h ago")
        #expect(Diagnostics.ago(Self.now.addingTimeInterval(-86400), now: Self.now) == "1 day ago")
        #expect(Diagnostics.ago(Self.now.addingTimeInterval(-3 * 86400), now: Self.now) == "3 days ago")
        #expect(Diagnostics.ago(Self.now.addingTimeInterval(30), now: Self.now) == "just now")
    }
}

private extension FormatHealth {
    /// The warning a run of unreadable records gives.
    var warningForTest: String? {
        var h = self
        for _ in 0..<FormatHealth.threshold { h.record(false) }
        return h.warning
    }
}
