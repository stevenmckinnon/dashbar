import Foundation
import Testing
@testable import Dashbar

// MARK: - Log format health, judged on what was written lately

@Suite struct FormatHealthTests {
    /// Assistant records whose usage moved somewhere Dashbar doesn't look.
    static func renamed(_ count: Int, from start: Int = 0) -> [[String: Any]] {
        (start..<(start + count)).map { i in
            ["type": "assistant", "timestamp": Fixture.now, "message": ["id": "n\(i)", "tokenUsage": ["outputTokens": 10]]]
        }
    }

    @Test func aFormatChangeWhileRunningRaisesTheWarningAndItClearsOnceRecordsReadAgain() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let file = try fx.write("-p/s1.jsonl", lines: (0..<25).map { Fixture.claude(id: "m\($0)", output: 10) })
        let scanner = ClaudeUsageScanner(root: fx.root)
        #expect(scanner.scan().warning == nil)

        try fx.append(file, lines: Self.renamed(FormatHealth.threshold - 1))
        #expect(scanner.scan().warning == nil)            // not yet a run long enough to call it
        try fx.append(file, lines: Self.renamed(1, from: 100))
        let changed = scanner.scan()
        #expect(changed.warning?.contains("Claude Code") == true)
        #expect(changed.today.output == 250)              // what did read still counts

        try fx.append(file, lines: [Fixture.claude(id: "back", output: 5)])
        #expect(scanner.scan().warning == nil)
    }

    @Test func linesThatAreNoLongerJSONCountAgainstTheFormat() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("-p/s1.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = (0..<25).map { "assistant output_tokens=\($0) \"output_tokens\"" }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(ClaudeUsageScanner(root: fx.root).scan().warning?.contains("Claude Code") == true)
    }

    @Test func otherRecordsThatMentionAssistantDontCount() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let chatter: [[String: Any]] = (0..<30).map { i in
            ["type": "user", "timestamp": Fixture.now, "message": ["role": "user", "content": "ask the assistant \(i)"]]
        }
        try fx.write("-p/s1.jsonl", lines: chatter)
        #expect(ClaudeUsageScanner(root: fx.root).scan().warning == nil)
    }

    @Test func oldFilesDontJudgeTheFormat() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let file = try fx.write("-p/old.jsonl", lines: Self.renamed(30))
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: weekAgo], ofItemAtPath: file.path)
        #expect(ClaudeUsageScanner(root: fx.root).scan().warning == nil)
    }

    @Test func codexSpacedJSONIsRead() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("2026/11/06/rollout-1.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            "{\"timestamp\": \"\(Fixture.now)\", \"type\": \"turn_context\", \"payload\": {\"model\": \"gpt-5-codex\"}}",
            "{\"timestamp\": \"\(Fixture.now)\", \"type\": \"event_msg\", \"payload\": {\"type\": \"token_count\", "
                + "\"info\": {\"total_token_usage\": {\"input_tokens\": 100, \"cached_input_tokens\": 0, \"output_tokens\": 7}}}}",
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let s = CodexUsageScanner(root: fx.root).scan()
        #expect(s.today.output == 7)
        #expect(s.topModels.first?.name == "gpt-5-codex")
    }

    @Test func codexFormatChangeWhileRunningRaisesTheWarning() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let file = try fx.write("2026/11/06/rollout-1.jsonl", lines: [Fixture.codexTokens(input: 100, cached: 0, output: 10)])
        let scanner = CodexUsageScanner(root: fx.root)
        #expect(scanner.scan().warning == nil)
        let changed: [[String: Any]] = (0..<FormatHealth.threshold).map { i in
            ["timestamp": Fixture.now, "type": "event_msg",
             "payload": ["type": "token_count", "info": ["usage_totals": ["in": i]]]]
        }
        try fx.append(file, lines: changed)
        #expect(scanner.scan().warning?.contains("Codex") == true)
    }
}

// MARK: - Reading the tail of a log that is still being written

@Suite struct JSONLTailTests {
    @Test func aPartialLastLineWaitsForItsNewline() throws {
        let fx = try Fixture(); defer { fx.remove() }
        let url = fx.root.appendingPathComponent("-p/s1.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = String(decoding: try JSONSerialization.data(withJSONObject: Fixture.claude(id: "a", output: 10)), as: UTF8.self)
        let second = String(decoding: try JSONSerialization.data(withJSONObject: Fixture.claude(id: "b", output: 20)), as: UTF8.self)
        let cut = second.index(second.startIndex, offsetBy: second.count / 2)
        try (first + "\n" + second[..<cut]).write(to: url, atomically: false, encoding: .utf8)

        let scanner = ClaudeUsageScanner(root: fx.root)
        let partial = scanner.scan()
        #expect(partial.today.output == 10)
        #expect(partial.warning == nil)

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        h.write(Data((second[cut...] + "\n").utf8))
        try h.close()
        #expect(scanner.scan().today.output == 30)   // the finished line counts once
        #expect(scanner.scan().today.output == 30)
    }

    @Test func aFileRewrittenLongerIsReadAgainFromTheTop() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("-p/s1.jsonl", lines: [Fixture.claude(id: "a", output: 10)])
        let scanner = ClaudeUsageScanner(root: fx.root)
        #expect(scanner.scan().today.output == 10)
        // Same file, new content, longer than before: the old offset now lands mid-line.
        try fx.write("-p/s1.jsonl", lines: [
            Fixture.claude(id: "b", cwd: "/Users/x/dev/a-much-longer-project-name-than-before", output: 20),
            Fixture.claude(id: "c", output: 30),
        ])
        #expect(scanner.scan().today.output == 60)
    }

    @Test func aFileRewrittenShorterIsReadAgainFromTheTop() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("-p/s1.jsonl", lines: [Fixture.claude(id: "a", output: 10), Fixture.claude(id: "b", output: 20)])
        let scanner = ClaudeUsageScanner(root: fx.root)
        #expect(scanner.scan().today.output == 30)
        try fx.write("-p/s1.jsonl", lines: [Fixture.claude(id: "c", output: 5)])
        #expect(scanner.scan().today.output == 35)
    }
}
