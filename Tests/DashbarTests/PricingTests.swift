import Foundation
import Testing
@testable import Dashbar

// MARK: - Estimated cost

@Suite struct PricingTests {
    private func close(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    @Test func modelIdVariantsFindTheirPrice() {
        let opus = Pricing.price(for: "claude-opus-5-5")
        #expect(opus?.rates.input == 4)
        #expect(Pricing.price(for: "claude-opus-5-5[1m]") == opus)
        #expect(Pricing.price(for: "Claude-Opus-5-5") == opus)
        #expect(Pricing.price(for: "us.anthropic.claude-opus-5-5-v1:0") == opus)
        #expect(Pricing.price(for: "anthropic/claude-opus-5-5") == opus)
        #expect(Pricing.price(for: "claude-sonnet-4-5-20250929")?.rates.input == 3)
        #expect(Pricing.price(for: "claude-opus-4-5@20251101")?.rates.output == 25)
        #expect(Pricing.price(for: "gpt-5-codex")?.rates.cacheRead == 0.125)
        #expect(Pricing.price(for: "openai/gpt-6.1-sol")?.rates.input == 2)
        #expect(Pricing.price(for: "gpt-5-2025-08-07")?.rates.input == 1.25)
    }

    @Test func familiesDoNotBorrowEachOthersPrices() {
        // Exact match after normalising: a newer or smaller variant never takes its base model's price.
        #expect(Pricing.price(for: "gpt-5-codex-mini") == nil)
        #expect(Pricing.price(for: "claude-opus-5") != Pricing.price(for: "claude-opus-5-5"))
        #expect(Pricing.price(for: "claude-sonnet-5")?.rates.cacheRead == 0.20)
        #expect(Pricing.price(for: "claude-sonnet-5-5")?.rates.cacheRead == 0.10)
    }

    @Test func unknownModelHasNoEstimateRatherThanZero() {
        let t = TokenTotals(input: 1_000_000, output: 1_000_000)
        #expect(Pricing.cost(t, model: "codex") == nil)
        #expect(Pricing.cost(t, model: "unknown") == nil)
        #expect(Pricing.cost(t, model: "claude-opus-9-9") == nil)
    }

    @Test func costAddsEveryTokenKindAtItsRate() {
        // Opus 5.5: $4 in, $20 out, $5 5-minute write, $8 1-hour write, $0.20 cache read (per million).
        let t = TokenTotals(input: 1_000_000, output: 500_000, cacheRead: 10_000_000, cacheWrite: 2_000_000)
        #expect(close(Pricing.cost(t, model: "claude-opus-5-5"), 4 + 10 + 2 + 10))
        // Half the writes went to the 1-hour cache: 1M at $5 plus 1M at $8.
        #expect(close(Pricing.cost(t, model: "claude-opus-5-5", oneHourShare: 0.5), 4 + 10 + 2 + 13))
        // Fast mode doubles everything on Opus 5.5; US-only inference adds 10%.
        #expect(close(Pricing.cost(t, model: "claude-opus-5-5", fast: true), 52))
        #expect(close(Pricing.cost(t, model: "claude-opus-5-5", usOnly: true), 28.6))
        // A model without fast mode ignores the flag.
        #expect(close(Pricing.cost(t, model: "claude-sonnet-4-6", fast: true), Pricing.cost(t, model: "claude-sonnet-4-6")!))
    }

    @Test func longPromptsPayTheLongContextTier() {
        let t = TokenTotals(input: 1_000_000, output: 1_000_000)
        #expect(close(Pricing.cost(t, model: "claude-haiku-5-5", promptTokens: 100_000), 0.60))
        #expect(close(Pricing.cost(t, model: "claude-haiku-5-5", promptTokens: 100_001), 3.00))
        #expect(close(Pricing.cost(t, model: "gpt-6-sol", promptTokens: 200_000), 12))
        #expect(close(Pricing.cost(t, model: "gpt-6-sol", promptTokens: 300_000), 19))
        // Models priced the same at any length ignore the prompt size.
        #expect(close(Pricing.cost(t, model: "claude-opus-5-5", promptTokens: 900_000), 24))
    }

    @Test func dollarsFormatForTheirSize() {
        #expect(Fmt.usd(0) == "$0")
        #expect(Fmt.usd(0.004) == "<$0.01")
        #expect(Fmt.usd(0.42) == "$0.42")
        #expect(Fmt.usd(12.4) == "$12.40")
        #expect(Fmt.usd(1_240.4) == "$1,240")
    }

    @Test func claudeScanPricesEachMessageAndGroupsByModelAndProject() throws {
        let fx = try Fixture(); defer { fx.remove() }
        var withOneHour = Fixture.claude(id: "b", request: "r2", model: "claude-sonnet-5-5", cwd: "/Users/x/dev/site",
                                         input: 1_000_000, cacheWrite: 1_000_000)
        var message = withOneHour["message"] as! [String: Any]
        var usage = message["usage"] as! [String: Any]
        usage["cache_creation"] = ["ephemeral_1h_input_tokens": 1_000_000, "ephemeral_5m_input_tokens": 0]
        message["usage"] = usage
        withOneHour["message"] = message
        try fx.write("-Users-x-dev-app/s.jsonl", lines: [
            Fixture.claude(id: "a", model: "claude-opus-5-5", input: 1_000_000, output: 100_000),
            Fixture.claude(id: "a", model: "claude-opus-5-5", input: 1_000_000, output: 500_000), // same message, streamed
            withOneHour,
            Fixture.claude(id: "c", request: "r3", model: "claude-mystery-1", input: 7_000),
        ])
        let s = ClaudeUsageScanner(root: fx.root).scan()
        let today = s.period(.today)
        // Opus: 1M in at $4 + 0.5M out at $20 = $14. Sonnet: 1M in at $2 + 1M 1-hour writes at $4 = $6.
        #expect(close(today.cost, 20))
        #expect(close(today.models.first { $0.name == "Opus 5.5" }?.cost, 14))
        #expect(close(today.models.first { $0.name == "Sonnet 5.5" }?.cost, 6))
        #expect(today.models.first { $0.name == "Mystery 1" }?.cost == nil)
        #expect(today.unpriced == ["Mystery 1"])
        #expect(close(today.projects.first { $0.name == "app" }?.cost, 14))
        #expect(close(today.projects.first { $0.name == "site" }?.cost, 6))
        #expect(close(s.period(.week).cost, 20))
    }

    @Test func codexScanPricesCumulativeDeltas() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("2026/11/14/rollout-1.jsonl", lines: [
            ["timestamp": Fixture.now, "type": "session_meta", "payload": ["cwd": "/Users/x/dev/api"]],
            ["timestamp": Fixture.now, "type": "turn_context", "payload": ["model": "gpt-5-codex"]],
            Fixture.codexTokens(input: 1_000_000, cached: 400_000, output: 100_000),
            Fixture.codexTokens(input: 1_000_000, cached: 400_000, output: 100_000), // repeated, unchanged
            Fixture.codexTokens(input: 2_000_000, cached: 1_000_000, output: 200_000),
        ])
        let s = CodexUsageScanner(root: fx.root).scan()
        // 1M uncached at $1.25, 1M cached at $0.125, 0.2M out at $10.
        #expect(close(s.period(.today).cost, 1.25 + 0.125 + 2))
        #expect(close(s.period(.today).projects.first?.cost, 3.375))
        #expect(s.period(.today).unpriced.isEmpty)
    }

    @Test func codexWithoutAKnownModelIsUnpriced() throws {
        let fx = try Fixture(); defer { fx.remove() }
        try fx.write("r.jsonl", lines: [Fixture.codexTokens(input: 1_000, cached: 0, output: 10)])
        let today = CodexUsageScanner(root: fx.root).scan().period(.today)
        #expect(today.cost == 0)
        #expect(today.unpriced == ["codex"])
    }
}
