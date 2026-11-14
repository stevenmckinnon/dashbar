import Foundation

/// Estimated cost of token usage at public API list prices, worked out locally from the token counts in the logs.
/// For someone on a Claude or ChatGPT plan this is what the same tokens would cost on the pay-as-you-go API,
/// not what they pay. A model missing from the table gets no estimate (never $0).
///
/// Sources, read on 14 November 2026:
/// - Anthropic: https://platform.claude.com/docs/en/about-claude/pricing (Model pricing, Fast mode, Data residency,
///   Long context pricing)
/// - OpenAI: https://developers.openai.com/api/docs/pricing (Standard, short and long context) and the model pages
///   under https://developers.openai.com/api/docs/models/ for the Codex models no longer on the pricing page
/// - Google: https://ai.google.dev/gemini-api/docs/pricing (Standard, paid tier; text prices)
enum Pricing {
    static let asOf = "14 Nov 2026"

    /// US dollars per million tokens.
    struct Rates: Equatable {
        var input: Double
        var output: Double
        var cacheWrite5m: Double
        var cacheWrite1h: Double
        var cacheRead: Double
    }

    struct ModelPrice: Equatable {
        var rates: Rates
        /// Requests whose prompt is longer than this many tokens pay `longRates` for the whole request.
        var longAbove: Int? = nil
        var longRates: Rates? = nil
        /// Fast mode price as a multiple of the standard one (caching multipliers apply on top).
        var fastMultiplier: Double? = nil

        func rates(promptTokens: Int?) -> Rates {
            if let longAbove, let longRates, let promptTokens, promptTokens > longAbove { return longRates }
            return rates
        }
    }

    // MARK: Anthropic (cache writes are 1.25x input for 5 minutes, 2x for 1 hour; hits vary by model)

    private static func claude(_ i: Double, _ o: Double, _ w5: Double, _ w1: Double, _ r: Double,
                               fast: Double? = nil) -> ModelPrice {
        ModelPrice(rates: Rates(input: i, output: o, cacheWrite5m: w5, cacheWrite1h: w1, cacheRead: r), fastMultiplier: fast)
    }

    private static let anthropic: [String: ModelPrice] = [
        "claude-fable-5-2": claude(8, 40, 10, 16, 0.20, fast: 2),       // fast mode $16 / $80
        "claude-mythos-5-2": claude(8, 40, 10, 16, 0.20, fast: 2),
        "claude-fable-5-1": claude(10, 50, 12.50, 20, 0.25),
        "claude-mythos-5-1": claude(10, 50, 12.50, 20, 0.25),
        "claude-fable-5": claude(10, 50, 12.50, 20, 1),
        "claude-mythos-5": claude(10, 50, 12.50, 20, 1),
        "claude-opus-5-5": claude(4, 20, 5, 8, 0.20, fast: 2),          // fast mode $8 / $40
        "claude-opus-5": claude(5, 25, 6.25, 10, 0.50, fast: 2),        // fast mode $10 / $50
        "claude-opus-4-8": claude(5, 25, 6.25, 10, 0.50, fast: 2),
        "claude-opus-4-7": claude(5, 25, 6.25, 10, 0.50),
        "claude-opus-4-6": claude(5, 25, 6.25, 10, 0.50),
        "claude-opus-4-5": claude(5, 25, 6.25, 10, 0.50),
        "claude-opus-4-1": claude(15, 75, 18.75, 30, 1.50),
        "claude-opus-4": claude(15, 75, 18.75, 30, 1.50),
        "claude-sonnet-5-5": claude(2, 10, 2.50, 4, 0.10),
        "claude-sonnet-5": claude(2, 10, 2.50, 4, 0.20),
        "claude-sonnet-4-6": claude(3, 15, 3.75, 6, 0.30),
        "claude-sonnet-4-5": claude(3, 15, 3.75, 6, 0.30),
        "claude-sonnet-4": claude(3, 15, 3.75, 6, 0.30),
        // Haiku 5.5 is priced by prompt length: over 100,000 tokens (input, cache reads and writes) pays more.
        "claude-haiku-5-5": ModelPrice(rates: Rates(input: 0.10, output: 0.50, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01),
                                       longAbove: 100_000,
                                       longRates: Rates(input: 0.50, output: 2.50, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05)),
        "claude-haiku-4-5": claude(1, 5, 1.25, 2, 0.10),
    ]

    // MARK: OpenAI (Codex logs report input, cached input and output; no cache writes)

    private static func openai(_ i: Double, _ o: Double, _ cached: Double, long: (Double, Double, Double)? = nil) -> ModelPrice {
        let rates = Rates(input: i, output: o, cacheWrite5m: i, cacheWrite1h: i, cacheRead: cached)
        guard let long else { return ModelPrice(rates: rates) }
        // Long context: more than 272K input tokens in the request.
        return ModelPrice(rates: rates, longAbove: 272_000,
                          longRates: Rates(input: long.0, output: long.1, cacheWrite5m: long.0, cacheWrite1h: long.0, cacheRead: long.2))
    }

    private static let openAI: [String: ModelPrice] = [
        "gpt-6-astra": openai(10, 50, 1, long: (20, 75, 2)),
        "gpt-6.1-sol": openai(2, 10, 0.10, long: (4, 15, 0.20)),
        "gpt-6.1-terra": openai(1, 5, 0.05, long: (2, 7.50, 0.10)),
        "gpt-6-sol": openai(2, 10, 0.20, long: (4, 15, 0.40)),
        "gpt-6-luna": openai(0.10, 0.50, 0.01, long: (0.20, 0.75, 0.02)),
        "gpt-5.6-sol": openai(4, 20, 0.40, long: (8, 30, 0.80)),        // promotional until 30 Nov 2026
        "gpt-5.6-terra": openai(2, 12, 0.20, long: (4, 18, 0.40)),
        "gpt-5.6-luna": openai(0.20, 1.20, 0.02, long: (0.40, 1.80, 0.04)),
        "gpt-5.5": openai(5, 30, 0.50, long: (10, 45, 1)),
        "gpt-5.4": openai(2.50, 15, 0.25, long: (5, 22.50, 0.50)),
        "gpt-5.4-mini": openai(0.75, 4.50, 0.075),
        "gpt-5.4-nano": openai(0.20, 1.25, 0.02),
        "gpt-5.3-codex": openai(1.75, 14, 0.175),
        "gpt-5.2": openai(1.75, 14, 0.175),
        "gpt-5.2-codex": openai(1.75, 14, 0.175),
        "gpt-5.1": openai(1.25, 10, 0.125),
        "gpt-5.1-codex": openai(1.25, 10, 0.125),
        "gpt-5.1-codex-max": openai(1.25, 10, 0.125),
        "gpt-5.1-codex-mini": openai(0.25, 2, 0.025),
        "gpt-5": openai(1.25, 10, 0.125),
        "gpt-5-codex": openai(1.25, 10, 0.125),
        "gpt-5-mini": openai(0.25, 2, 0.025),
        "gpt-5-nano": openai(0.05, 0.40, 0.005),
        "codex-mini-latest": openai(1.50, 6, 0.375),
        "gpt-4.1": openai(2, 8, 0.50),
        "o3": openai(2, 8, 0.50),
    ]

    // MARK: Google (Gemini CLI logs report input, cached input, output and thinking; output prices include thinking)

    private static func gemini(_ i: Double, _ o: Double, _ cached: Double, long: (Double, Double, Double)? = nil) -> ModelPrice {
        let rates = Rates(input: i, output: o, cacheWrite5m: i, cacheWrite1h: i, cacheRead: cached)
        guard let long else { return ModelPrice(rates: rates) }
        // Long context: prompts over 200K tokens.
        return ModelPrice(rates: rates, longAbove: 200_000,
                          longRates: Rates(input: long.0, output: long.1, cacheWrite5m: long.0, cacheWrite1h: long.0, cacheRead: long.2))
    }

    private static let google: [String: ModelPrice] = [
        "gemini-4-carbon": gemini(2, 10, 0.10),            // promotional until 30 Nov 2026, then $4 / $20 / $0.20
        "gemini-4-argon": gemini(2, 10, 0.10),             // promotional until 30 Nov 2026, then $4 / $20 / $0.20
        "gemini-4-hydrogen": gemini(1.50, 7.50, 0.075),
        "gemini-3.8-flash": gemini(0.75, 3.75, 0.075),     // until 31 Dec 2026, then $1.50 / $7.50 / $0.15
        "gemini-3.6-flash": gemini(0.75, 3.75, 0.075),     // until 31 Dec 2026, then $1.50 / $7.50 / $0.15
        "gemini-3.5-flash-lite": gemini(0.30, 2.50, 0.03),
        "gemini-3.1-pro-preview": gemini(2, 12, 0.20, long: (4, 18, 0.40)),
        "gemini-3.1-flash-lite": gemini(0.25, 1.50, 0.025),
        "gemini-3-flash-preview": gemini(0.50, 3, 0.05),
        "gemini-2.5-pro": gemini(1.25, 10, 0.125, long: (2.50, 15, 0.25)),
        "gemini-2.5-flash": gemini(0.30, 2.50, 0.03),
        "gemini-2.5-flash-lite": gemini(0.10, 0.40, 0.01),
    ]

    /// Reduces a logged model id to its table key: lower case, no provider prefix ("us.anthropic.", "openai/"),
    /// no "[1m]"-style tag, no date or Bedrock version suffix. Matching is exact after this, so
    /// "gpt-5-codex-mini" never borrows the price of "gpt-5-codex".
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }                         // Vertex "claude-opus-4-5@20251101"
        for prefix in ["global.", "us.", "eu.", "apac.", "jp.", "au."] where s.hasPrefix(prefix + "anthropic.") {
            s.removeFirst(prefix.count)
        }
        if s.hasPrefix("anthropic.") { s.removeFirst("anthropic.".count) }
        s = s.replacingOccurrences(of: #"-v\d+(:\d+)?$"#, with: "", options: .regularExpression)  // Bedrock "-v1:0"
        s = s.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)        // "-20250929"
        s = s.replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression) // "-2025-08-07"
        return s
    }

    static func price(for model: String) -> ModelPrice? {
        let key = normalize(model)
        return anthropic[key] ?? openAI[key] ?? google[key]
    }

    /// The Antigravity CLI names models for people ("Gemini 4 Argon (Medium)", "Claude Sonnet 5.5 (Thinking)"):
    /// the id they most likely stand for ("gemini-4-argon", "claude-sonnet-5-5"), for pricing when the CLI gave no cost.
    static func normalize(displayName: String) -> String {
        var s = displayName
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == " " }).joined(separator: "-")
        if s.hasPrefix("claude-") { s = s.replacingOccurrences(of: ".", with: "-") }
        return s
    }

    /// Cost in US dollars of `t` on `model`, or nil when the model has no known price.
    /// - promptTokens: the whole request's prompt, to pick a long-context tier (Claude: input + cache reads + cache
    ///   writes; Codex: input including cached). Nil prices at the standard tier.
    /// - oneHourShare: the part of the cache writes that used the 1-hour cache (0...1).
    static func cost(_ t: TokenTotals, model: String, promptTokens: Int? = nil, oneHourShare: Double = 0,
                     fast: Bool = false, usOnly: Bool = false) -> Double? {
        guard let price = price(for: model) else { return nil }
        let r = price.rates(promptTokens: promptTokens)
        let share = min(1, max(0, oneHourShare))
        var usd = Double(t.input) * r.input
            + Double(t.output) * r.output
            + Double(t.cacheRead) * r.cacheRead
            + Double(t.cacheWrite) * ((1 - share) * r.cacheWrite5m + share * r.cacheWrite1h)
        usd /= 1_000_000
        if fast, let m = price.fastMultiplier { usd *= m }
        if usOnly { usd *= 1.1 } // US-only inference (Claude 4.6 and later)
        return usd
    }
}

extension Fmt {
    /// "$0.42", "$12.40", "$1,240". Anything above zero but under a cent shows as "<$0.01".
    static func usd(_ d: Double) -> String {
        if d <= 0 { return "$0" }
        if d < 0.01 { return "<$0.01" }
        if d < 100 { return String(format: "$%.2f", d) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: d.rounded())) ?? String(Int(d.rounded())))
    }
}
