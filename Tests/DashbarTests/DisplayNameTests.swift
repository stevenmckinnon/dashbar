import Testing
import Foundation
@testable import Dashbar

struct DisplayNameTests {
    private func session(name: String, agent: SessionAgent) -> LiveSession {
        var s = LiveSession(id: "x", pid: 1, name: name, cwd: "/dev/ml-notebooks", status: "busy", since: Date(),
                            entrypoint: "cli", root: "/dev/ml-notebooks")
        s.agent = agent
        return s
    }

    @Test func aSessionNamedAfterItsFolderIsCalledByItsAgent() {
        let s = session(name: "ml-notebooks", agent: .antigravityCLI)
        #expect(s.title == "Antigravity CLI")
        #expect(s.identityParts == ["ml-notebooks"])
        #expect(s.agentNote == nil)
    }

    @Test func aTitledSessionKeepsItsTitleAndNamesItsGoogleAgent() {
        let google = session(name: "Fix the loader", agent: .geminiCLI)
        #expect(google.title == "Fix the loader")
        #expect(google.identityParts == ["ml-notebooks", "Gemini CLI"])
        let claude = session(name: "Add Stripe checkout", agent: .claude)
        #expect(claude.identityParts == ["ml-notebooks"])
        #expect(claude.agentNote == nil)
    }

    @Test func shortModelNamesDropQualifiersAndDates() {
        #expect(Fmt.shortModel("Gemini 4 Argon (Medium)") == "Gemini 4 Argon")
        #expect(Fmt.shortModel("Claude Sonnet 5.5 (Thinking)") == "Claude Sonnet 5.5")
        #expect(Fmt.shortModel("gpt-5-2025-08-07") == "gpt-5")
        #expect(Fmt.shortModel("gemini-3.8-flash-20260101") == "gemini-3.8-flash")
        #expect(Fmt.shortModel("Opus 5.5") == "Opus 5.5")
        #expect(Fmt.shortModel("gpt-5-codex") == "gpt-5-codex")
        #expect(Fmt.shortModel("(unknown)") == "(unknown)")
    }

    @Test func modelsThatShareAShortNameAreAddedTogether() {
        let merged = RankList.shortModels([
            Ranked(name: "Claude Sonnet 5.5 (Thinking)", value: 10, cost: 1),
            Ranked(name: "Gemini 4 Argon (Medium)", value: 30, cost: nil),
            Ranked(name: "Claude Sonnet 5.5", value: 25, cost: 2),
        ])
        #expect(merged.map(\.name) == ["Claude Sonnet 5.5", "Gemini 4 Argon"])
        #expect(merged[0].value == 35 && merged[0].cost == 3)
        #expect(merged[1].cost == nil)
    }
}
