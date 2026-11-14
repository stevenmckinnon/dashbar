import Foundation

/// The Claude plan an account is on, from the profile Claude Code keeps in its global config file.
///
/// Claude Code writes the plan into its Keychain sign-in only when you sign in, so after an upgrade (Pro to Max) that
/// field stays wrong. It refreshes the `oauthAccount` object in `.claude.json` instead: `organizationType`
/// ("claude_max") and `organizationRateLimitTier` ("default_claude_max_5x"). The file lives at
/// `$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json` without that variable (Claude Code joins the variable, else
/// the home folder, with ".claude.json"). Only those plan fields are decoded; the file is read again only when its
/// modification date or size changes.
enum ClaudeProfile {
    enum Plan: Equatable, Sendable {
        /// The profile names a plan.
        case name(String)
        /// The file is there but has no `oauthAccount` (an API key user): there is no plan to show.
        case none
        /// No file, or one Dashbar can't read: fall back to the Keychain's plan field.
        case unknown

        /// The plan to show, given what the Keychain sign-in says.
        func resolved(keychain: String?) -> String? {
            switch self {
            case .name(let n): return n
            case .none: return nil
            case .unknown: return keychain
            }
        }

        var name: String? { if case .name(let n) = self { return n } else { return nil } }
    }

    /// The account's `.claude.json`.
    static func file(for account: ResolvedAccount, environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = homeDir) -> URL {
        if account.isDefault && (environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty {
            return home.appendingPathComponent(".claude.json")
        }
        return account.url.appendingPathComponent(".claude.json")
    }

    static func plan(for account: ResolvedAccount) -> Plan { plan(at: file(for: account)) }

    // MARK: Reading, cached by modification date

    private struct Cached { let modified: Date; let size: Int; let plan: Plan }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]

    static func plan(at url: URL) -> Plan {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return .unknown }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        lock.lock()
        let hit = cache[url.path]
        lock.unlock()
        if let hit, hit.modified == modified, hit.size == size { return hit.plan }
        let plan = (try? Data(contentsOf: url)).map(parse) ?? .unknown
        lock.lock()
        cache[url.path] = Cached(modified: modified, size: size, plan: plan)
        lock.unlock()
        return plan
    }

    /// Only these fields are decoded; the rest of the file (projects, history, the email and name) is skipped.
    private struct File: Decodable { let oauthAccount: Account? }
    private struct Account: Decodable {
        let organizationType: String?
        let organizationRateLimitTier: String?
        let userRateLimitTier: String?
    }

    static func parse(_ data: Data) -> Plan {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return .unknown }
        guard let a = file.oauthAccount else { return .none }
        return planName(type: a.organizationType, tiers: [a.organizationRateLimitTier, a.userRateLimitTier])
            .map(Plan.name) ?? .unknown
    }

    /// "claude_max" with "default_claude_max_5x" → "Max 5x"; "claude_pro" → "Pro"; "claude_team" → "Team";
    /// "claude_enterprise" → "Enterprise"; anything else tidied ("claude_new_thing" → "New Thing").
    static func planName(type: String?, tiers: [String?]) -> String? {
        let tiers = tiers.compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        var key = (type ?? "").lowercased()
        if key.isEmpty, let tier = tiers.first {   // no type: the tier names the plan too ("default_claude_max_5x")
            key = tier.hasPrefix("default_") ? String(tier.dropFirst("default_".count)) : tier
        }
        if key.hasPrefix("claude_") { key = String(key.dropFirst("claude_".count)) }
        var words = key.split(separator: "_").map(String.init)
        // A multiplier in the type itself ("max_5x") or in a tier.
        let multiplier = words.last(where: isMultiplier)
            ?? tiers.lazy.compactMap { $0.split(separator: "_").map(String.init).last(where: isMultiplier) }.first
        words.removeAll(where: isMultiplier)
        guard !words.isEmpty else { return nil }
        let known = ["max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise", "free": "Free"]
        let joined = words.joined(separator: "_")
        guard let base = known[joined] else {
            let tidy = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return [tidy, multiplier].compactMap { $0 }.joined(separator: " ")
        }
        // Only Max comes in sizes; a stray tier suffix doesn't belong on Pro or Team.
        return base == "Max" ? [base, multiplier].compactMap { $0 }.joined(separator: " ") : base
    }

    private static func isMultiplier(_ s: String) -> Bool { s.count > 1 && s.hasSuffix("x") && Int(s.dropLast()) != nil }
}
