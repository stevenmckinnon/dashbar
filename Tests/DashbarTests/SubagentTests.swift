import Foundation
import Testing
@testable import Dashbar

/// Subagent folders shaped like Claude Code's: `<project>/<sessionId>/subagents/agent-<id>.jsonl` plus `.meta.json`.
@Suite struct SubagentTests {
    let now = Date()

    private func meta(_ fx: Fixture, _ dir: String, _ id: String, description: String = "Do a thing", type: String = "general-purpose",
                      background: Bool = false, finished: Bool = false, extra: [String: Any] = [:]) throws -> URL {
        var o: [String: Any] = ["agentType": type, "description": description, "model": "sonnet",
                                "requestShape": background ? "background" : "foreground", "toolUseId": "toolu_x", "spawnDepth": 1]
        if finished { o["finished"] = true }
        o.merge(extra) { $1 }
        let url = fx.root.appendingPathComponent("\(dir)/agent-\(id).meta.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return url
    }

    private func reply(_ msg: String, output: Int, input: Int = 0, model: String = "claude-sonnet-5-5") -> [String: Any] {
        var r = Fixture.claude(id: msg, model: model, input: input, output: output, sidechain: true)
        r["agentId"] = "x"
        return r
    }

    private func age(_ url: URL, modified: TimeInterval, created: TimeInterval? = nil) throws {
        var attrs: [FileAttributeKey: Any] = [.modificationDate: now.addingTimeInterval(-modified)]
        if let created { attrs[.creationDate] = now.addingTimeInterval(-created) }
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    private func read(_ reader: SubagentReader, _ fx: Fixture, _ dir: String, started: Date? = nil,
                      detail: Bool = true) -> (agents: [Subagent], unreadable: Bool) {
        var seen = Set<String>()
        return reader.read(dir: fx.root.appendingPathComponent(dir), sessionStarted: started, detail: detail, now: now, seen: &seen)
    }

    @Test func listsRunningAndJustFinishedSubagentsWithTheirKind() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = "-p/s1/subagents"
        try fx.write("\(dir)/agent-a.jsonl", lines: [reply("m1", output: 5)])
        try meta(fx, dir, "a", description: "Review the diff", type: "code-reviewer", background: true)
        try fx.write("\(dir)/agent-b.jsonl", lines: [reply("m2", output: 5)])
        try meta(fx, dir, "b", description: "Search the repo", type: "Explore")
        try fx.write("\(dir)/agent-c.jsonl", lines: [reply("m3", output: 5)])
        try meta(fx, dir, "c", description: "Just done", finished: true)
        // Finished long ago: no longer listed.
        let old = try fx.write("\(dir)/agent-d.jsonl", lines: [reply("m4", output: 5)])
        let oldMeta = try meta(fx, dir, "d", finished: true)
        try age(old, modified: 600); try age(oldMeta, modified: 600)

        let r = read(SubagentReader(), fx, dir)
        #expect(!r.unreadable)
        #expect(r.agents.map(\.id).sorted() == ["a", "b", "c"])
        #expect(r.agents.running.count == 2)
        #expect(r.agents.last?.id == "c")   // running ones first
        let a = try #require(r.agents.first { $0.id == "a" })
        #expect(a.background && a.type == "code-reviewer" && a.description == "Review the diff")
        #expect(r.agents.first { $0.id == "b" }?.background == false)
        #expect(a.model == "Sonnet 5.5")   // from its last reply, not the alias
        #expect(r.agents.summary == "2 subagents running · 1 done")
    }

    @Test func aQuietSubagentThatNeverSaidItFinishedIsNotRunning() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = "-p/s1/subagents"
        let t = try fx.write("\(dir)/agent-a.jsonl", lines: [reply("m1", output: 5)])
        let m = try meta(fx, dir, "a")
        try age(t, modified: SubagentReader.quiet + 60); try age(m, modified: SubagentReader.quiet + 60)
        #expect(read(SubagentReader(), fx, dir).agents.isEmpty)
    }

    @Test func subagentsFromAnEarlierRunOfAResumedSessionAreLeftOut() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = "-p/s1/subagents"
        let t = try fx.write("\(dir)/agent-a.jsonl", lines: [reply("m1", output: 5)])
        let m = try meta(fx, dir, "a")
        try age(t, modified: 120); try age(m, modified: 120)
        #expect(read(SubagentReader(), fx, dir, started: now.addingTimeInterval(-30)).agents.isEmpty)
        #expect(read(SubagentReader(), fx, dir, started: now.addingTimeInterval(-600)).agents.count == 1)
    }

    @Test func aFinishedSubagentThatWasResumedRunsAgain() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = "-p/s1/subagents"
        try fx.write("\(dir)/agent-a.jsonl", lines: [reply("m1", output: 5)])
        let m = try meta(fx, dir, "a", finished: true)
        try age(m, modified: 60)
        #expect(read(SubagentReader(), fx, dir).agents.first?.isRunning == true)
    }

    @Test func tokensAreReadIncrementallyAndEachMessageCountsOnce() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = "-p/s1/subagents"
        // The same message written once per content block, with growing usage.
        let t = try fx.write("\(dir)/agent-a.jsonl", lines: [reply("m1", output: 5, input: 100), reply("m1", output: 9, input: 100)])
        try meta(fx, dir, "a")
        let reader = SubagentReader()
        #expect(read(reader, fx, dir).agents.first?.tokens == 109)
        try fx.append(t, lines: [reply("m2", output: 1, input: 10)])
        #expect(read(reader, fx, dir).agents.first?.tokens == 120)
        // With the panel closed only the count is kept current; tokens wait for the next open.
        #expect(read(reader, fx, dir, detail: false).agents.first?.tokens == 0)
        #expect(read(reader, fx, dir).agents.first?.tokens == 120)
    }

    @Test func recentSubagentFilesThatDontReadRaiseTheWarning() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = "-p/s1/subagents"
        let t = try fx.write("\(dir)/agent-a.jsonl", lines: [reply("m1", output: 5)])
        let url = fx.root.appendingPathComponent("\(dir)/agent-a.meta.json")
        try JSONSerialization.data(withJSONObject: ["kind": "worker", "summary": "renamed keys"]).write(to: url)
        try age(t, modified: 5, created: 120)
        let r = read(SubagentReader(), fx, dir)
        #expect(r.unreadable)
        #expect(r.agents.isEmpty)
    }

    @Test func transcriptsWithoutMetadataRaiseTheWarningOnceTheyAreNotBrandNew() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let dir = "-p/s1/subagents"
        let t = try fx.write("\(dir)/agent-a.jsonl", lines: [reply("m1", output: 5)])
        try age(t, modified: 0, created: 0)
        #expect(!read(SubagentReader(), fx, dir).unreadable)   // its metadata may not be written yet
        try age(t, modified: 5, created: 120)
        #expect(read(SubagentReader(), fx, dir).unreadable)
        // Old leftovers don't judge the format.
        try age(t, modified: SubagentReader.quiet + 60, created: SubagentReader.quiet + 120)
        #expect(!read(SubagentReader(), fx, dir).unreadable)
    }

    @Test func liveSessionsFindTheirSubagentsBesideTheirTranscript() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let transcript = try fx.write("-p/s1.jsonl", lines: [Fixture.claude(id: "a", output: 1)])
        try fx.write("-p/s1/subagents/agent-a.jsonl", lines: [reply("m1", output: 5)])
        try meta(fx, "-p/s1/subagents", "a")
        let s1 = LiveSession(id: "s1", pid: 1, name: "x", cwd: "/x", status: "busy", since: now, entrypoint: "cli", root: "/x")
        let s2 = LiveSession(id: "s2", pid: 2, name: "y", cwd: "/y", status: "busy", since: now, entrypoint: "cli", root: "/y")
        let r = SubagentReader().read([s1, s2], transcript: { $0.id == "s1" ? transcript : nil }, detail: false, now: now)
        #expect(r.bySession.keys.sorted() == ["s1"])
        #expect(r.runningCount == 1)
        #expect(r.warning == nil)
    }

    @Test func subagentTokensAreCountedOnceInTheirOwnProjectAndReportedAsAShare() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("-p/s1.jsonl", lines: [Fixture.claude(id: "a", cwd: "/Users/x/dev/app", output: 10)])
        // A subagent in a worktree of the same repo, and one working in another folder.
        try fx.write("-p/s1/subagents/agent-1.jsonl", lines: [
            Fixture.claude(id: "b", cwd: "/Users/x/dev/app/.claude/worktrees/agent-1", output: 4, sidechain: true),
            Fixture.claude(id: "b", cwd: "/Users/x/dev/app/.claude/worktrees/agent-1", output: 4, sidechain: true),
        ])
        try fx.write("-p/s1/subagents/agent-2.jsonl", lines: [
            Fixture.claude(id: "c", cwd: "/Users/x/dev/other", output: 6, sidechain: true),
        ])
        let s = ClaudeUsageScanner(root: fx.root).scan()
        let today = s.period(.today)
        #expect(today.totals.output == 20)
        #expect(today.subagentTokens == 10)
        #expect(today.projects.first { $0.name == "app" }?.value == 14)
        #expect(today.projects.first { $0.name == "other" }?.value == 6)
    }
}
