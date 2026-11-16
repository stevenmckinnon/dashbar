import Foundation

/// What the desktop widgets read: the command-line tool's `StatusSnapshot` with everything that names a project left
/// out. No sessions (so no workspaces, folders or session states one by one), no servers, no token counts; only the app's
/// name, version and pid, the plan limits (percentages, reset times, plan names, account labels) and how many agents
/// are working, waiting for you or idle.
///
/// The widget runs in a sandbox and can't read the app's caches, so the app saves this copy in its App Group container
/// (`~/Library/Group Containers/<team>.fun.dashbar.app[.local]/Widget/status.json`). The release and a local build
/// have different groups, so neither reads the other's file.
public enum WidgetStatus {
    /// The widgets' kinds, which the app names when it asks WidgetKit to reload them.
    public enum Kind {
        public static let limits = "fun.dashbar.widget.limits"
        public static let overview = "fun.dashbar.widget.overview"
        public static let all = [limits, overview]
    }

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
    /// How many agents are in each state, for the widget (which never sees the sessions themselves).
    public struct AgentCounts: Codable, Equatable, Sendable {
        public var working: Int
        /// Stopped for an answer or at a permission prompt.
        public var needsYou: Int
        public var idle: Int

        public init(working: Int = 0, needsYou: Int = 0, idle: Int = 0) {
            self.working = working
            self.needsYou = needsYou
            self.idle = idle
        }

        public var total: Int { working + needsYou + idle }
    }

    /// The counts of `sessions`, by state.
    public var agentCounts: AgentCounts {
        sessions.reduce(into: AgentCounts()) { c, s in
            switch s.state {
            case .working: c.working += 1
            case .idle: c.idle += 1
            case .needsYou, .permission: c.needsYou += 1
            }
        }
    }

    /// The copy the widget reads: sessions folded into `agents`, servers and token counts left out.
    public func forWidget() -> StatusSnapshot {
        var copy = self
        copy.agents = agentCounts
        copy.sessions = []
        copy.servers = []
        copy.usageToday = nil
        return copy
    }
}
