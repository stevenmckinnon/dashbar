import Foundation

/// What the running app knows, saved for the `dashbar` command-line tool. The app writes it when its state changes
/// (`StatusSnapshotWriter` in the app); the tool only reads it, so it never scans logs itself.
///
/// It holds no prompts, session titles, transcript text, permission request details, session ids, tokens or sign-ins:
/// only states, counts, times, workspace folders, plan percentages and dev server ports. Fields are only ever added;
/// a change that would break a reader raises `schema`.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var generatedAt: Date
    public var app: App
    /// A log or session format the app can no longer read, in its own words. Nil when everything reads.
    public var warning: String?
    public var sessions: [Session]
    public var limits: [LimitGroup]
    public var usageToday: UsageToday?
    public var servers: [Server]
    /// How many agents are in each state. Only in the widget's copy (`forWidget()`), which has no sessions.
    public var agents: AgentCounts?

    public init(schema: Int = StatusSnapshot.currentSchema, generatedAt: Date, app: App, warning: String? = nil,
                sessions: [Session] = [], limits: [LimitGroup] = [], usageToday: UsageToday? = nil, servers: [Server] = [],
                agents: AgentCounts? = nil) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.app = app
        self.warning = warning
        self.sessions = sessions
        self.limits = limits
        self.usageToday = usageToday
        self.servers = servers
        self.agents = agents
    }

    public struct App: Codable, Equatable, Sendable {
        /// "Dashbar" or "Dashbar Local": also the process name the tool checks `pid` against.
        public var name: String
        public var version: String
        public var pid: Int32
        /// Updates are paused from the panel, so the figures may be old.
        public var paused: Bool

        public init(name: String, version: String, pid: Int32, paused: Bool = false) {
            self.name = name
            self.version = version
            self.pid = pid
            self.paused = paused
        }
    }

    public enum State: String, Codable, Sendable {
        case working, idle
        /// Stopped for an answer (or for a reason other than a permission prompt).
        case needsYou = "needs-you"
        /// Stopped at a permission prompt.
        case permission

        public var needsYou: Bool { self == .needsYou || self == .permission }
    }

    public struct Session: Codable, Equatable, Sendable {
        /// "claude", "gemini-cli", "antigravity-cli" or "antigravity".
        public var tool: String
        /// The account's name, only while the app reads more than one account of this tool.
        public var account: String?
        public var workspace: String
        public var folder: String
        public var state: State
        /// When the session entered its current state.
        public var since: Date
        /// Subagents running for it now.
        public var subagents: Int

        public init(tool: String, account: String? = nil, workspace: String, folder: String, state: State, since: Date,
                    subagents: Int = 0) {
            self.tool = tool
            self.account = account
            self.workspace = workspace
            self.folder = folder
            self.state = state
            self.since = since
            self.subagents = subagents
        }
    }

    /// One account's plan limits from one provider.
    public struct LimitGroup: Codable, Equatable, Sendable {
        /// "claude", "codex" or "antigravity".
        public var provider: String
        public var account: String?
        public var plan: String?
        /// When the reading was taken.
        public var readAt: Date?
        /// The limits were kept from an earlier reading because the latest one failed.
        public var stale: Bool
        /// Why there are no limits to show, in the app's words (a sign-in to renew, an unknown format).
        public var problem: String?
        public var limits: [Limit]

        public init(provider: String, account: String? = nil, plan: String? = nil, readAt: Date? = nil, stale: Bool = false,
                    problem: String? = nil, limits: [Limit] = []) {
            self.provider = provider
            self.account = account
            self.plan = plan
            self.readAt = readAt
            self.stale = stale
            self.problem = problem
            self.limits = limits
        }
    }

    public enum Pace: String, Codable, Sendable {
        /// Using well under the even rate.
        case under
        /// Close to the even rate: it should last until the reset.
        case onPace = "on-pace"
        /// At the current rate it runs out before the reset (`runsOutAt`).
        case runsOut = "runs-out"
        case usedUp = "used-up"

        public var atRisk: Bool { self == .runsOut || self == .usedUp }
    }

    public struct Limit: Codable, Equatable, Sendable {
        /// The app's name for the row: "5-hour", "Weekly", "Weekly · Opus", "Gemini · Weekly".
        public var label: String
        /// The window's name from its length ("5-hour", "Weekly", "3-day"), when the length is known.
        public var window: String?
        public var windowSeconds: Double?
        public var usedPercent: Double
        public var resetsAt: Date?
        /// As of `generatedAt`. The tool works it out again when it prints, since the pace moves with the clock.
        public var pace: Pace?
        public var runsOutAt: Date?

        public init(label: String, window: String? = nil, windowSeconds: Double? = nil, usedPercent: Double,
                    resetsAt: Date? = nil, pace: Pace? = nil, runsOutAt: Date? = nil) {
            self.label = label
            self.window = window
            self.windowSeconds = windowSeconds
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.pace = pace
            self.runsOutAt = runsOutAt
        }
    }

    /// Tokens since local midnight on `day`.
    public struct UsageToday: Codable, Equatable, Sendable {
        /// "2026-11-15", the app's local calendar day when it counted.
        public var day: String
        public var tools: [ToolTokens]

        public init(day: String, tools: [ToolTokens]) {
            self.day = day
            self.tools = tools
        }
    }

    public struct ToolTokens: Codable, Equatable, Sendable {
        /// "claude", "codex" or "google" (Gemini CLI and the Antigravity CLI together).
        public var tool: String
        /// "Claude", "Codex", "Gemini CLI and Antigravity CLI".
        public var name: String
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var total: Int

        public init(tool: String, name: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
            self.tool = tool
            self.name = name
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.total = input + output + cacheRead + cacheWrite
        }
    }

    /// A dev server, as of the last time the app read ports (it does while its panel or window is open).
    public struct Server: Codable, Equatable, Sendable {
        /// The workspace it runs in; nil for one started outside every project folder.
        public var workspace: String?
        public var folder: String?
        public var port: Int
        /// The process name ("node").
        public var command: String
        /// So a reader can leave out a server that has stopped since.
        public var pid: Int32
        /// The panel's name for its row: the workspace, "Docker container", or the process name for one outside every
        /// project. Nil in snapshots from before it was added.
        public var title: String?

        public init(workspace: String?, folder: String?, port: Int, command: String, pid: Int32, title: String? = nil) {
            self.workspace = workspace
            self.folder = folder
            self.port = port
            self.command = command
            self.pid = pid
            self.title = title
        }

        /// `title`, or for an older snapshot the same name worked out from what it has.
        public var name: String {
            if let title { return title }
            if workspace == nil, command.hasPrefix("com.docke") { return "Docker container" }
            return workspace ?? command
        }
    }
}

// MARK: - Encoding

extension StatusSnapshot {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The day key `UsageToday.day` uses, in the given time zone.
    public static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Where each copy writes it

extension StatusSnapshot {
    /// The two copies that can run side by side: the release and a local build (`build.sh`).
    public enum Copy: String, CaseIterable, Sendable {
        case release, local

        /// The app's name, which is also its process name and its folder's name.
        public var appName: String { self == .release ? "Dashbar" : "Dashbar Local" }

        public init?(appName: String) {
            guard let copy = Self.allCases.first(where: { $0.appName == appName }) else { return nil }
            self = copy
        }
    }

    /// `~/Library/Caches/<app name>/CLI/status.json`: each copy its own file, in a folder only the user can open.
    public static func fileURL(appName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("CLI", isDirectory: true)
            .appendingPathComponent("status.json")
    }
}

// MARK: - Pace and the tightest limit

extension StatusSnapshot.Limit {
    /// The window has reset since this reading, so its share used is no longer known.
    public func hasReset(now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }

    /// A limit that resets: it has a window length or a reset time.
    public var isWindowed: Bool { windowSeconds != nil || resetsAt != nil }

    /// The same rule as the app's `RateLimit.pace(now:)` (a test keeps them in step): nil when too little of the
    /// window has passed to tell.
    public func pace(now: Date) -> (pace: StatusSnapshot.Pace, runsOutAt: Date?)? {
        if usedPercent >= 100 { return (.usedUp, nil) }
        guard let window = windowSeconds, window > 0, let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= window * 1.02 else { return nil }
        let expected = min(100, max(0, (1 - remaining / window) * 100))
        guard expected >= 5 else { return nil }
        let elapsed = window * expected / 100
        let perSecond = usedPercent / elapsed
        if perSecond > 0 {
            let runsOut = now.addingTimeInterval((100 - usedPercent) / perSecond)
            if runsOut < resetsAt {
                return expected >= 25 ? (.runsOut, runsOut) : nil
            }
        }
        return (usedPercent < expected - 10 ? .under : .onPace, nil)
    }

    /// This limit with its pace worked out at `now`.
    public func withPace(now: Date) -> Self {
        var copy = self
        let p = pace(now: now)
        copy.pace = p?.pace
        copy.runsOutAt = p?.runsOutAt
        return copy
    }
}

extension StatusSnapshot {
    /// A limit together with whose it is.
    public struct RankedLimit: Equatable, Sendable {
        public let group: LimitGroup
        public let limit: Limit
    }

    /// Every current limit, the most at risk first: on course to run out (or used up) before the rest, then the highest
    /// share used. Ties keep the snapshot's order. Limits whose window has reset since the reading are left out, and one
    /// with no window (Claude's extra usage) counts only when its provider reports nothing else, as in the app's strip.
    public func rankedLimits(now: Date) -> [RankedLimit] {
        var all: [(RankedLimit, risk: Bool, index: Int)] = []
        for group in limits where group.problem == nil {
            let current = group.limits.filter { !$0.hasReset(now: now) }
            let windowed = current.filter(\.isWindowed)
            for limit in windowed.isEmpty ? current : windowed {
                let paced = limit.withPace(now: now)
                all.append((RankedLimit(group: group, limit: paced), paced.pace?.atRisk ?? false, all.count))
            }
        }
        return all.sorted {
            if $0.risk != $1.risk { return $0.risk }
            if $0.0.limit.usedPercent != $1.0.limit.usedPercent { return $0.0.limit.usedPercent > $1.0.limit.usedPercent }
            return $0.index < $1.index
        }.map(\.0)
    }

    /// The snapshot with every limit's pace worked out at `now`, for printing as JSON.
    public func withPaces(now: Date) -> StatusSnapshot {
        var copy = self
        copy.limits = limits.map { g in
            var g = g
            g.limits = g.limits.map { $0.withPace(now: now) }
            return g
        }
        return copy
    }
}

// MARK: - Which rows the panel shows

extension StatusSnapshot.Limit {
    /// Lists longer than this can fold their rows at 0% (the app's `RateLimit.foldAbove`).
    public static let foldAbove = 3

    /// The same rule as the app's `RateLimit.fold` (a test keeps them in step): in a list of more than three, two or more
    /// at 0% used fold away, except the tightest (the most used, or the first when all are at 0%), which always shows.
    /// Returns the folded rows' positions in `limits`.
    public static func folded(_ limits: [Self]) -> Set<Int> {
        guard limits.count > foldAbove else { return [] }
        func isZero(_ l: Self) -> Bool { Int(max(0, l.usedPercent).rounded()) == 0 }
        guard limits.filter(isZero).count >= 2 else { return [] }
        let tightest = limits.indices.max {
            limits[$0].usedPercent < limits[$1].usedPercent || (limits[$0].usedPercent == limits[$1].usedPercent && $0 > $1)
        }
        let folded = Set(limits.indices.filter { isZero(limits[$0]) && $0 != tightest })
        return folded.count >= 2 ? folded : []
    }
}

extension StatusSnapshot {
    /// Whether to name `tool`'s accounts: only while more than one of its accounts shows up, in its sessions or its plan
    /// limits. The app names accounts once more than one is set up; this also leaves the name out when the others have
    /// nothing to show, so one account in use reads "Claude", as it would with only one set up.
    public func namesAccounts(of tool: String) -> Bool {
        let accounts = Set(sessions.filter { $0.tool == tool }.compactMap(\.account)
                           + limits.filter { $0.provider == tool }.compactMap(\.account))
        return accounts.count > 1
    }
}
