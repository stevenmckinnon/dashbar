import Foundation

/// What the desktop widgets read: the command-line tool's `StatusSnapshot` with everything that names a project left
/// out. No sessions (so no workspaces, folders or session states one by one), no servers, no split of tokens by kind,
/// workspace or session; only the app's name, version and pid, the plan limits (percentages, reset times, plan names,
/// account labels), how many agents there are and how many of them are working, which tools are switched off, and
/// today's totals per tool (tokens, estimated cost, Copilot's premium requests, OpenCode's top model). (Not how many wait for you: WidgetKit throttles refreshes, so that count
/// would be stale when it matters most. The island and notifications carry it.)
///
/// The widget runs in a sandbox and can't read the app's caches, so the app saves this copy in its App Group container
/// (`~/Library/Group Containers/<team>.fun.dashbar.app[.local]/Widget/status.json`). The release and a local build
/// have different groups, so neither reads the other's file.
public enum WidgetStatus {
    /// The widgets' kinds, which the app names when it asks WidgetKit to reload them.
    public enum Kind {
        public static let limits = "fun.dashbar.widget.limits"
        public static let overview = "fun.dashbar.widget.overview"
        public static let codex = "fun.dashbar.widget.codex"
        public static let antigravity = "fun.dashbar.widget.antigravity"
        public static let opencode = "fun.dashbar.widget.opencode"
        public static let copilot = "fun.dashbar.widget.copilot"
        public static let usage = "fun.dashbar.widget.usage"
        public static let all = [limits, overview, codex, antigravity, opencode, copilot, usage]
    }

    /// The Info.plist key build.sh sets to true in a local build's extension (as in its app), so its widgets say "Local".
    public static let localInfoKey = "DashbarLocalBuild"

    /// The Info.plist key build.sh sets to the App Group (`<team>.<bundle id of the app>`) in both the app and the
    /// widget. Absent from an ad-hoc signed build, which has no team to prefix a group with: it then writes nothing.
    public static let groupInfoKey = "DashbarAppGroup"

    /// `<container>/Widget/status.json`. The writer keeps the folder 0700 and the file 0600.
    public static func fileURL(container: URL) -> URL {
        container.appendingPathComponent("Widget", isDirectory: true).appendingPathComponent("status.json")
    }

    /// The snapshot at `url`, or nil when there is none or it isn't one this build can read.
    public static func load(_ url: URL) -> StatusSnapshot? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        struct Header: Decodable { let schema: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              header.schema <= StatusSnapshot.currentSchema else { return nil }
        return try? StatusSnapshot.decoder().decode(StatusSnapshot.self, from: data)
    }
}

extension StatusSnapshot {
    /// How many agents there are and how many are working, for the widget (which never sees the sessions themselves).
    public struct AgentCounts: Codable, Equatable, Sendable {
        public var working: Int
        /// Every agent session, working or not.
        public var total: Int

        public init(working: Int = 0, total: Int = 0) {
            self.working = working
            self.total = total
        }
    }

    /// The counts of `sessions`.
    public var agentCounts: AgentCounts {
        AgentCounts(working: sessions.filter { $0.state == .working }.count, total: sessions.count)
    }

    /// The copy the widget reads: sessions folded into `agents`, servers left out, and today's tokens cut down to each
    /// tool's totals (`usageTotals`). `showsCost` false (the Usage tab's cost is switched off) leaves the cost out too.
    /// A tool switched off is left out again here, whatever the snapshot was built from.
    public func forWidget(showsCost: Bool = true) -> StatusSnapshot {
        var copy = self
        copy.sessions = sessions.filter { !hides($0.tool) }
        copy.agents = copy.agentCounts
        copy.sessions = []
        copy.servers = []
        copy.limits = limits.filter { !hides($0.provider) }
        copy.usageTotals = usageToday.map { u in
            UsageTotals(day: u.day, tools: u.tools.filter { !hides($0.tool) }.map {
                ToolTotal(tool: $0.tool, name: $0.name, total: $0.total, cost: showsCost ? $0.cost : nil,
                          premiumRequests: $0.premiumRequests, model: $0.model)
            })
        }
        copy.usageToday = nil
        return copy
    }
}
