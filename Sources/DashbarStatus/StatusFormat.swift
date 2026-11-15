import Foundation

/// Turns a snapshot into the tool's text: the few-line summary (`dashbar status`) and the one line for prompts and
/// tmux (`dashbar line`). Everything time-relative is worked out against `now`, since the app rewrites the snapshot
/// only when something in it changes.
public struct StatusFormat {
    public var now: Date
    public var timeZone: TimeZone
    public var locale: Locale
    /// Whether a dev server's process is still running, so one that has stopped since the app last looked is left out.
    public var isAlive: (Int32) -> Bool

    public init(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current,
                isAlive: @escaping (Int32) -> Bool = { pid in pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.isAlive = isAlive
    }

    // MARK: Names

    public static func toolName(_ tool: String) -> String {
        switch tool {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini-cli": return "Gemini CLI"
        case "antigravity-cli": return "Antigravity CLI"
        case "antigravity": return "Antigravity"
        case "google": return "Gemini"
        default: return tool
        }
    }

    /// "Claude", or "Claude · Work" while the snapshot shows more than one of the tool's accounts
    /// (`StatusSnapshot.namesAccounts(of:)`).
    static func owner(_ tool: String, account: String?, in snapshot: StatusSnapshot) -> String {
        [toolName(tool), snapshot.namesAccounts(of: tool) ? account : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// "5h", "wk", "day", "mo", "8h", "3d" for the one-line form; the label when the window's length isn't known.
    static func shortWindow(_ limit: StatusSnapshot.Limit) -> String {
        guard let window = limit.window else { return limit.label }
        switch window {
        case "Daily": return "day"
        case "Weekly": return "wk"
        case "Monthly": return "mo"
        default:
            if window.hasSuffix("-hour") { return window.dropLast(5) + "h" }
            if window.hasSuffix("-day") { return window.dropLast(4) + "d" }
            return window
        }
    }

    // MARK: Times and numbers

    /// "45s", "4m", "1h 35m", "2d 3h".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d \(h % 24)h"
    }

    func clock(_ date: Date, withDay: Bool) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate(withDay ? "EEE HH:mm" : "HH:mm")
        return f.string(from: date)
    }

    /// "in 2h 10m" within a day, "Thu 09:00" after that: the app's wording for resets.
    func reset(_ date: Date) -> String {
        let left = date.timeIntervalSince(now)
        return left < 86_400 ? "in " + Self.duration(left) : clock(date, withDay: true)
    }

    /// "12.4M", "830K", "950".
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1e3)
        default: return "\(n)"
        }
    }

    static func percent(_ value: Double) -> String { "\(Int(max(0, value).rounded()))%" }

    // MARK: dashbar line

    /// One short line: who needs you, how many are working, and the tightest plan limit.
    /// `⚠ 1 needs you · 2 working · Claude 5h 55%`, or with `ascii`: `! 1 needs you | 2 working | Claude 5h 55%`.
    public func line(_ snapshot: StatusSnapshot, ascii: Bool = false) -> String {
        var parts: [String] = []
        let needs = snapshot.sessions.filter(\.state.needsYou).count
        let working = snapshot.sessions.filter { $0.state == .working }.count
        if needs > 0 { parts.append((ascii ? "! " : "⚠ ") + "\(needs) needs you") }
        if working > 0 { parts.append("\(working) working") }
        if needs == 0, working == 0 { parts.append(snapshot.sessions.isEmpty ? "no agents" : "idle") }
        if let top = snapshot.rankedLimits(now: now).first {
            var text = "\(Self.owner(top.group.provider, account: top.group.account, in: snapshot)) \(Self.shortWindow(top.limit)) "
                + Self.percent(top.limit.usedPercent)
            if top.limit.pace?.atRisk == true { text += ascii ? " (!)" : " ↑" }
            parts.append(text)
        }
        if snapshot.app.paused { parts.append("paused") }
        return parts.joined(separator: ascii ? " | " : " · ")
    }

    // MARK: dashbar status

    /// A few lines: who needs you, who's working, who's idle, the plan limits tightest first, today's tokens and dev
    /// servers. Sections with nothing in them are left out.
    public func status(_ snapshot: StatusSnapshot) -> String {
        var out: [String] = []
        if snapshot.app.paused { out.append("Updates are paused in \(snapshot.app.name), so this may be out of date.") }
        if let warning = snapshot.warning { out.append("Warning: \(warning)") }

        let needs = snapshot.sessions.filter(\.state.needsYou)
        let working = snapshot.sessions.filter { $0.state == .working }
        let idle = snapshot.sessions.filter { $0.state == .idle }
        if snapshot.sessions.isEmpty { out.append("No agents running.") }
        section("Needs you", needs.map { s in
            let what = s.state == .permission ? "needs permission" : "waiting for you"
            return (s.workspace, "\(Self.owner(s.tool, account: s.account, in: snapshot)) · \(what) · \(Self.duration(now.timeIntervalSince(s.since)))")
        }, into: &out)
        section("Working", working.map { s in
            var text = "\(Self.owner(s.tool, account: s.account, in: snapshot)) · \(Self.duration(now.timeIntervalSince(s.since)))"
            if s.subagents > 0 { text += " · \(s.subagents) subagent\(s.subagents == 1 ? "" : "s")" }
            return (s.workspace, text)
        }, into: &out)
        section("Idle", idle.map { s in
            (s.workspace, "\(Self.owner(s.tool, account: s.account, in: snapshot)) · \(Self.duration(now.timeIntervalSince(s.since)))")
        }, into: &out)

        section("Plan limits", limitRows(snapshot), into: &out)

        // Only tools that used something today: a tool with logs but nothing today is left out, never shown as 0.
        if let usage = snapshot.usageToday, usage.day == StatusSnapshot.dayKey(now, timeZone: timeZone) {
            let used = usage.tools.filter { $0.total > 0 }
            if !used.isEmpty {
                out.append("Today")
                out.append("  " + used.map { "\($0.name) \(Self.tokens($0.total)) tokens" }.joined(separator: " · "))
            }
        }

        section("Servers", serverRows(snapshot), into: &out)
        return out.joined(separator: "\n")
    }

    /// As the panel's Servers card lists them: one row per process, named as the panel names it (the workspace,
    /// "Docker container", or the process name), with its first two ports and how many more (`ServerRow.portChips`).
    private func serverRows(_ snapshot: StatusSnapshot) -> [(String, String)] {
        var order: [Int32] = []
        var byProcess: [Int32: [StatusSnapshot.Server]] = [:]
        for server in snapshot.servers where isAlive(server.pid) {
            if byProcess[server.pid] == nil { order.append(server.pid) }
            byProcess[server.pid, default: []].append(server)
        }
        return order.compactMap { pid in
            guard let group = byProcess[pid]?.sorted(by: { $0.port < $1.port }), let first = group.first else { return nil }
            let ports = group.map { ":\($0.port)" }
            var detail = ports.prefix(2).joined(separator: " ") + (ports.count > 2 ? " +\(ports.count - 2)" : "")
            if first.command != first.name { detail += " " + first.command }
            return (first.name, detail)
        }
    }

    /// The tightest limit first, then the rest; a provider's problem or a window reset since its reading on its own row.
    /// Rows the panel folds (`StatusSnapshot.Limit.folded`) are left out, with a line saying how many.
    private func limitRows(_ snapshot: StatusSnapshot) -> [(String, String)] {
        let folded = snapshot.limits.map { group in Set(StatusSnapshot.Limit.folded(group.limits).map { group.limits[$0].label }) }
        let shown = snapshot.rankedLimits(now: now).filter { ranked in
            guard let g = snapshot.limits.firstIndex(of: ranked.group) else { return true }
            return !folded[g].contains(ranked.limit.label)
        }
        var rows: [(String, String)] = shown.map { ranked in
            let l = ranked.limit
            var parts = [Self.percent(l.usedPercent)]
            if let resets = l.resetsAt { parts.append("resets " + reset(resets)) }
            switch l.pace {
            case .runsOut?: if let at = l.runsOutAt { parts.append("runs out about " + clock(at, withDay: false)) }
            case .usedUp?: parts.append("used up")
            default: break
            }
            if ranked.group.stale, let at = ranked.group.readAt { parts.append("kept from " + clock(at, withDay: true)) }
            return ("\(Self.owner(ranked.group.provider, account: ranked.group.account, in: snapshot)) \(l.label)", parts.joined(separator: " · "))
        }
        for (g, group) in snapshot.limits.enumerated() {
            let name = Self.owner(group.provider, account: group.account, in: snapshot)
            if let problem = group.problem {
                rows.append((name, problem))
                continue
            }
            if !folded[g].isEmpty { rows.append((name, "\(folded[g].count) more at 0%")) }
            for l in group.limits where l.hasReset(now: now) {
                rows.append(("\(name) \(l.label)", "reset since the last reading"))
            }
        }
        return rows
    }

    /// A heading and its rows, the names padded to the widest in this section only.
    private func section(_ title: String, _ rows: [(String, String)], into out: inout [String]) {
        guard !rows.isEmpty else { return }
        let width = rows.map(\.0.count).max() ?? 0
        out.append(title)
        out += rows.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
    }
}
