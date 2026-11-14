import Foundation
import CryptoKit

/// More than one Claude Code (or Codex) account on one Mac.
///
/// Claude Code keeps each account in its own configuration folder, chosen with `CLAUDE_CONFIG_DIR` (default
/// `~/.claude`): its own `sessions/`, `projects/` logs, `settings.json` and Keychain sign-in
/// (https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts). Codex does the same with
/// `CODEX_HOME` (default `~/.codex`, https://learn.chatgpt.com/docs/config-file/environment-variables). Dashbar reads
/// the default folder plus any the user adds in Settings → Accounts.
enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex

    var name: String { self == .claude ? "Claude Code" : "Codex" }
    /// The environment variable that picks the folder, and the folder used without it.
    var variable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
    var defaultFolder: String { self == .claude ? ".claude" : ".codex" }
}

/// What the user saved for an account: its folder and the name it shows under. Saving the default folder only
/// gives it a name; it is always read.
struct AgentAccount: Codable, Equatable, Hashable, Sendable, Identifiable {
    var kind: AgentKind
    var path: String
    var label: String
    var id: String { kind.rawValue + ":" + path }
}

/// An account Dashbar reads, with the places its data lives.
struct ResolvedAccount: Equatable, Hashable, Sendable, Identifiable {
    let kind: AgentKind
    /// The configuration folder, absolute, without a trailing slash.
    let path: String
    let label: String
    /// `~/.claude` (or the folder `CLAUDE_CONFIG_DIR` named when Dashbar started). It keeps Dashbar's original file names.
    let isDefault: Bool

    var id: String { kind.rawValue + ":" + path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// Short, stable and safe in file names: the first 8 hex digits of SHA-256 of the folder path. Nil for the default
    /// account, whose files keep the names they had before accounts existed.
    var key: String? { isDefault ? nil : AgentAccounts.hash(path) }

    var sessionsDir: URL { url.appendingPathComponent("sessions") }
    var projectsDir: URL { url.appendingPathComponent("projects") }
    var settingsFile: URL { url.appendingPathComponent("settings.json") }

    /// A file name for this account's saved state: "claude-usage.json" for the default, "claude-usage-1a2b3c4d.json" otherwise.
    func fileName(_ base: String, ext: String = "json") -> String {
        key.map { "\(base)-\($0).\(ext)" } ?? "\(base).\(ext)"
    }

    /// The Keychain entry Claude Code keeps this account's sign-in in. With `CLAUDE_CONFIG_DIR` set, Claude Code adds
    /// `-<first 8 hex of SHA-256 of that value>` to "Claude Code-credentials". The docs only say the entry is "keyed to
    /// that directory", so the exact rule comes from what other tools observe: it is used to put a name on a sign-in,
    /// never to find one, and an entry that matches no account stays unlabelled.
    func keychainService(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard kind == .claude else { return nil }
        let base = ClaudePlanLimits.keychainService
        if isDefault && (environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty { return base }
        return base + "-" + AgentAccounts.hash(path)
    }
}

enum AgentAccounts {
    /// The first 8 hex digits of SHA-256 of the path (NFC), the way Claude Code names a config folder's Keychain entry.
    static func hash(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// An absolute path without `~`, `.` segments or a trailing slash, so one folder always gives the same key.
    static func normalise(_ path: String) -> String {
        var p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The folder used without any account added: the environment variable if Dashbar started with it, else ~/.claude.
    static func defaultPath(_ kind: AgentKind, environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = homeDir) -> String {
        if let v = environment[kind.variable], !v.isEmpty { return normalise(v) }
        return normalise(home.appendingPathComponent(kind.defaultFolder).path)
    }

    /// The default account first, then the ones the user added, each folder once. Labels left empty become "Default"
    /// for the default account and a name from the folder ("~/.claude-work" → "Work") for the rest.
    static func resolve(_ kind: AgentKind, saved: [AgentAccount],
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = homeDir) -> [ResolvedAccount] {
        let defaultPath = defaultPath(kind, environment: environment, home: home)
        let mine = saved.filter { $0.kind == kind }
        func label(_ path: String, _ isDefault: Bool) -> String {
            let saved = mine.first { normalise($0.path) == path }?.label.trimmingCharacters(in: .whitespaces) ?? ""
            if !saved.isEmpty { return saved }
            return isDefault ? "Default" : suggestedLabel(forFolder: path)
        }
        var out = [ResolvedAccount(kind: kind, path: defaultPath, label: label(defaultPath, true), isDefault: true)]
        var seen: Set<String> = [defaultPath]
        for a in mine {
            let p = normalise(a.path)
            guard seen.insert(p).inserted else { continue }
            out.append(ResolvedAccount(kind: kind, path: p, label: label(p, false), isDefault: false))
        }
        return out
    }

    /// "~/.claude-work" → "Work", "~/.codex_personal" → "Personal", anything else → its folder name.
    static func suggestedLabel(forFolder path: String) -> String {
        var name = URL(fileURLWithPath: path).lastPathComponent
        for prefix in [".claude-", ".claude_", ".codex-", ".codex_", "."] where name.hasPrefix(prefix) && name.count > prefix.count {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Folders at the top level of the home folder that look like another account: `.claude-*` (or `.codex-*`) with a
    /// `sessions` or `projects` folder inside. Only the home folder itself is listed; nothing deeper is scanned.
    static func suggestions(_ kind: AgentKind, known: [String], home: URL = homeDir) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }
        let base = kind.defaultFolder
        let knownSet = Set(known.map(normalise))
        return names.filter { $0.hasPrefix(base + "-") || $0.hasPrefix(base + "_") }
            .map { normalise(home.appendingPathComponent($0).path) }
            .filter { path in
                !knownSet.contains(path) && ["sessions", "projects"].contains { fm.fileExists(atPath: path + "/" + $0) }
            }
            .sorted()
    }
}

/// One account's usage, shown as a row in the usage card when more than one account is read.
struct AccountUsage: Equatable, Identifiable {
    var id: String { label }
    let label: String
    let summary: UsageSummary
}

/// One account's plan limits, beside the default account's in the plan limits card.
struct AccountLimits: Equatable, Identifiable {
    var id: String { path }
    let label: String
    let path: String
    /// Codex limits, or what this account's status line bridge saved (Claude). Empty when nothing has been read yet.
    var limits: [RateLimit] = []
    /// When the reading was saved, for the age line.
    var fetchedAt: Date?
    /// The reading is in a shape Dashbar doesn't know.
    var problem: String?
    /// Claude: Dashbar's bridge is in this account's status line, so limits will come.
    var connected = true
}

extension UsageBook {
    /// Adds another account's ledger into this one, day by day and hour by hour.
    mutating func merge(_ other: UsageBook) {
        for (key, d) in other.days { days[key, default: DayUsage()].merge(d) }
        for (hour, b) in other.hours {
            var mine = hours[hour] ?? HourBucket()
            mine.tokens += b.tokens
            mine.messages += b.messages
            mine.sessions.formUnion(b.sessions)
            hours[hour] = mine
        }
    }

    static func merged(_ books: [UsageBook]) -> UsageBook {
        var out = UsageBook()
        for b in books { out.merge(b) }
        return out
    }
}

extension DayUsage {
    mutating func merge(_ o: DayUsage) {
        totals.add(o.totals)
        for (k, v) in o.byModel { byModel[k, default: 0] += v }
        for (k, v) in o.byProject { byProject[k, default: 0] += v }
        for (k, v) in o.costByModel { costByModel[k, default: 0] += v }
        for (k, v) in o.costByProject { costByProject[k, default: 0] += v }
        for (k, v) in o.unpricedByModel { unpricedByModel[k, default: 0] += v }
    }
}
