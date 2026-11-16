import SwiftUI
import WidgetKit
import DashbarStatus

/// The widgets' colours: the app's tokens (`UI` in DesignTokens.swift), picked by colour scheme here because a dynamic
/// NSColor doesn't always follow a widget's appearance. Colour carries meaning, as in the app: each provider's colour for
/// its own bars, green for working, amber for attention, red for a problem. Nothing decorative.
struct WidgetPalette {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    private func pick(_ light: UInt32, _ dark: UInt32) -> Color { Color(hex: self.dark ? dark : light) }

    var claude: Color { pick(0xC2603F, 0xD97857) }
    var codex: Color { pick(0x0F8296, 0x40C8E0) }
    var google: Color { pick(0x4F4DD0, 0x9C9AFF) }
    /// OpenCode and GitHub Copilot (`UI.neutralTool`): they run on other providers' models, so no colour of their own.
    var neutralTool: Color { pick(0x5F6670, 0xA9AFB8) }
    var working: Color { pick(0x1A7F37, 0x3FD06A) }
    var attention: Color { pick(0xBF8700, 0xE3B341) }
    var danger: Color { pick(0xC4320A, 0xFF6B5E) }
    var track: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }

    func provider(_ id: String) -> Color {
        switch id {
        case "claude": return claude
        case "codex": return codex
        case "antigravity", "google", "gemini-cli", "antigravity-cli": return google
        case "opencode", "copilot": return neutralTool
        default: return dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45)
        }
    }

    func fill(_ limit: StatusSnapshot.Limit, provider: String) -> Color {
        switch WidgetModel.fill(limit) {
        case .problem: return danger
        case .attention: return attention
        case .provider: return self.provider(provider)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Type sizes from the app's scale (`UI.Size`).
enum WidgetType {
    static let micro: CGFloat = 10
    static let caption: CGFloat = 11
    static let body: CGFloat = 12
    static let title: CGFloat = 13
    static let figure: CGFloat = 15
    /// A widget's one big figure (`UI.Size.numeral`).
    static let numeral: CGFloat = 22
}

/// "Local" beside a widget's name in a local build's widgets, as the panel's header shows it. Never in offline renders.
struct LocalPill: View {
    var body: some View {
        Text("Local").font(.system(size: WidgetType.micro, weight: .medium)).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .accessibilityLabel("Local build")
    }
}

/// A small widget's first line: the tool's dot and name, "Local" in a local build, and its plan on the right.
struct ToolHeader: View {
    let tool: WidgetTool
    var name: String? = nil
    var plan: String? = nil
    let local: Bool

    var body: some View {
        if local {
            // "Local" takes the room the plan would: the plan shows only when both fit whole.
            ViewThatFits(in: .horizontal) {
                line(plan: plan)
                line(plan: nil)
            }
        } else {
            line(plan: plan)
        }
    }

    private func line(plan: String?) -> some View {
        HStack(spacing: 5) {
            ProviderDot(provider: tool.provider)
            Text(name ?? tool.name).font(.system(size: WidgetType.title, weight: .semibold)).lineLimit(1)
            if local { LocalPill() }
            Spacer(minLength: 4)
            if let plan {
                Text(plan).font(.system(size: WidgetType.micro)).foregroundStyle(.secondary).lineLimit(1)
                    .fixedSize(horizontal: local, vertical: false)
            }
        }
    }
}

/// A plan limit's meter. In the tinted and vibrant renderings the fill joins the accent group and the track stays faint.
struct LimitMeter: View {
    let limit: StatusSnapshot.Limit
    let color: Color
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let fraction = Double(Int(min(max(limit.usedPercent, 0), 100).rounded())) / 100
        let palette = WidgetPalette(scheme)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(mode == .fullColor ? palette.track : Color.primary.opacity(0.2))
                Capsule().fill(mode == .fullColor ? color : Color.primary)
                    .frame(width: fraction > 0 ? max(3, g.size.width * fraction) : 0)
                    .widgetAccentable()
            }
        }
        .frame(height: 6)
    }
}

/// The provider's mark: a small dot in its colour.
struct ProviderDot: View {
    let provider: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Circle().fill(WidgetPalette(scheme).provider(provider)).frame(width: 7, height: 7).widgetAccentable()
    }
}

/// The line under a widget's figures when they need a caveat: the app has quit, updates are paused, or a reading was
/// kept from before.
struct StatusFooter: View {
    let model: WidgetModel
    let now: Date
    var body: some View {
        if let text = Self.text(model, now: now) {
            Text(text)
                .font(.system(size: WidgetType.micro))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    static func text(_ model: WidgetModel, now: Date) -> String? {
        switch model.availability {
        case .noData: return nil
        case .notRunning(let lastSeen):
            return "Dashbar isn't running · from \(WidgetModel.resetText(lastSeen, now: now))"
        case .live:
            if model.paused { return "Updates paused in Dashbar" }
            if model.rows.contains(where: \.stale) { return "Kept from an earlier reading" }
            return nil
        }
    }
}

/// What a widget says before the app has saved anything for it.
struct NoDataView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: WidgetType.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Small: one tool's plan limits

/// Claude's 5-hour and weekly limits with their reset times.
public struct LimitsWidgetView: View {
    let entry: DashbarWidgetEntry
    public init(entry: DashbarWidgetEntry) { self.entry = entry }
    public var body: some View { ToolLimitsWidgetView(entry: entry, tool: .claude) }

    static func dimmed(_ model: WidgetModel) -> Bool {
        if case .notRunning = model.availability { return true }
        return false
    }
}

/// One tool's two tightest plan limits with their reset times: Claude, Codex or Antigravity (whose limits are named by
/// quota group). A tool switched off, never used or with no limits says so in words.
public struct ToolLimitsWidgetView: View {
    let entry: DashbarWidgetEntry
    let tool: WidgetTool

    public init(entry: DashbarWidgetEntry, tool: WidgetTool) {
        self.entry = entry
        self.tool = tool
    }

    public var body: some View {
        let model = WidgetModel(entry: entry)
        let row = model.hides(tool) ? nil : model.row(tool)
        VStack(alignment: .leading, spacing: 8) {
            ToolHeader(tool: tool, name: row?.name, plan: row?.plan, local: model.local)
            if let message = model.message(tool) {
                NoDataView(text: message)
            } else if let row {
                let shown = Array(row.limits.prefix(2))
                let titles = tool == .antigravity ? WidgetModel.groupTitles(shown) : WidgetModel.titles(shown, short: false)
                ForEach(Array(shown.enumerated()), id: \.offset) { i, limit in
                    LimitBlock(limit: limit, title: titles[i], provider: tool.provider, now: entry.date)
                }
            }
            Spacer(minLength: 0)
            StatusFooter(model: model, now: entry.date)
        }
        .opacity(LimitsWidgetView.dimmed(model) ? 0.6 : 1)
    }
}

// MARK: - Small: one tool's usage today

/// OpenCode's or GitHub Copilot's tokens today, with OpenCode's estimated cost and top model, or Copilot's premium
/// requests. Neither has plan limits Dashbar can read.
public struct ToolUsageWidgetView: View {
    let entry: DashbarWidgetEntry
    let tool: WidgetTool

    public init(entry: DashbarWidgetEntry, tool: WidgetTool) {
        self.entry = entry
        self.tool = tool
    }

    public var body: some View {
        let model = WidgetModel(entry: entry)
        VStack(alignment: .leading, spacing: 8) {
            ToolHeader(tool: tool, local: model.local)
            if let message = model.message(tool) {
                NoDataView(text: message)
            } else if let total = model.today(tool) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(WidgetModel.tokens(total.total))
                        .font(.system(size: WidgetType.numeral, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                    Text("tokens today").font(.system(size: WidgetType.caption, weight: .medium)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 3) {
                    if let cost = total.cost, cost > 0 {
                        Text("\u{2248} \(WidgetModel.usd(cost)) at API prices")
                            .font(.system(size: WidgetType.micro)).foregroundStyle(.secondary).lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    if let line = WidgetModel.premiumLine(total.premiumRequests) {
                        Text(line).font(.system(size: WidgetType.micro)).foregroundStyle(.secondary).lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    if let top = total.model {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Top model").font(.system(size: WidgetType.micro)).foregroundStyle(.secondary)
                            Text(top).font(.system(size: WidgetType.caption, weight: .medium)).lineLimit(1)
                                .minimumScaleFactor(0.85).truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Spacer(minLength: 0)
            StatusFooter(model: model, now: entry.date)
        }
        .opacity(LimitsWidgetView.dimmed(model) ? 0.6 : 1)
    }
}

/// One limit in the small widget: its window and figure, the meter, and when it resets.
struct LimitBlock: View {
    let limit: StatusSnapshot.Limit
    let title: String
    let provider: String
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = WidgetPalette(scheme)
        let reset = limit.hasReset(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: WidgetType.caption, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(reset ? "–" : WidgetModel.percent(limit))
                    .font(.system(size: WidgetType.figure, weight: .semibold).monospacedDigit())
                    .foregroundStyle(!reset && WidgetModel.fill(limit) == .problem ? palette.danger : Color.primary)
            }
            LimitMeter(limit: reset ? StatusSnapshot.Limit(label: limit.label, usedPercent: 0) : limit,
                       color: palette.fill(limit, provider: provider))
            if let resetsAt = limit.resetsAt {
                Text((reset ? "Reset at " : "Resets ") + WidgetModel.resetText(resetsAt, now: now))
                    .font(.system(size: WidgetType.micro))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.label) limit, " + (reset ? "reset since the last reading" : "\(WidgetModel.percent(limit)) used"))
    }
}

// MARK: - Medium: every tool's limits and the agents

/// Plan limits for each tool that reports them, and how many agents are working.
public struct OverviewWidgetView: View {
    let entry: DashbarWidgetEntry
    @Environment(\.colorScheme) private var scheme

    public init(entry: DashbarWidgetEntry) { self.entry = entry }

    /// Rows that fit beside the header at this size.
    static let maxRows = 3

    public var body: some View {
        let model = WidgetModel(entry: entry)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text("Dashbar").font(.system(size: WidgetType.title, weight: .semibold))
                    if model.local { LocalPill() }
                }
                Spacer(minLength: 4)
                if let agents = model.agents { AgentCountsView(agents: agents) }
            }
            if model.availability == .noData {
                NoDataView(text: "Open Dashbar to see plan limits and your agents here.")
            } else if model.rows.isEmpty {
                NoDataView(text: "No plan limits from Claude Code, Codex or Antigravity yet.")
            } else {
                // The rows share the height below the header equally, each centred in its band, so one, two or three
                // tools fill the widget the same way (three sit as close as they did when stacked from the top).
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows.prefix(Self.maxRows)) { row in
                        OverviewRow(row: row, now: entry.date)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                if model.rows.count > Self.maxRows {
                    Text("\(model.rows.count - Self.maxRows) more in Dashbar")
                        .font(.system(size: WidgetType.micro)).foregroundStyle(.secondary)
                }
            }
            if model.availability == .noData || model.rows.isEmpty { Spacer(minLength: 0) }
            StatusFooter(model: model, now: entry.date)
        }
        .opacity(LimitsWidgetView.dimmed(model) ? 0.6 : 1)
    }
}

struct AgentCountsView: View {
    let agents: StatusSnapshot.AgentCounts
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = WidgetPalette(scheme)
        Group {
            if agents.working == 0 {
                Text(agents.total > 0 ? "No agents working" : "No agents")
                    .font(.system(size: WidgetType.caption)).foregroundStyle(.secondary)
            } else {
                count(agents.working, "working", palette.working)
            }
        }
        .lineLimit(1)
    }

    private func count(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7).widgetAccentable()
            Text("\(n) \(label)").font(.system(size: WidgetType.caption, weight: .medium).monospacedDigit())
        }
    }
}

/// One account in the medium widget: its name, then up to two limits side by side.
struct OverviewRow: View {
    let row: WidgetModel.Row
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                ProviderDot(provider: row.provider)
                Text(row.name).font(.system(size: WidgetType.body, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 84, alignment: .leading)
            if let problem = row.problem {
                Text(problem).font(.system(size: WidgetType.micro)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            } else if row.limits.isEmpty {
                Text("No limits reported").font(.system(size: WidgetType.micro)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                let titles = WidgetModel.titles(row.limits, short: true)
                // Named by group ("Claude and GPT"), a title needs the line to itself: the reset time goes under the meter.
                let named = titles != row.limits.map(StatusFormat.shortWindow)
                ForEach(Array(row.limits.enumerated()), id: \.offset) { i, limit in
                    CompactLimit(limit: limit, title: titles[i], resetBelow: named, provider: row.provider, now: now)
                }
                if row.limits.count == 1 { Spacer(minLength: 0).frame(maxWidth: .infinity) }
            }
        }
    }
}

/// A limit in the medium widget: "5h 14:20  55%" over its meter. Where the window alone wouldn't tell two limits apart
/// (`WidgetModel.titles`), "Gemini  58%" over the meter, with the reset time under it (`resetBelow`).
struct CompactLimit: View {
    let limit: StatusSnapshot.Limit
    let title: String
    var resetBelow = false
    let provider: String
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = WidgetPalette(scheme)
        let reset = limit.hasReset(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: WidgetType.micro, weight: .medium)).lineLimit(1)
                    .minimumScaleFactor(0.8).truncationMode(.tail).layoutPriority(-1)
                if !resetBelow, let r = limit.resetsAt { resetText(r) }
                Spacer(minLength: 2)
                Text(reset ? "–" : WidgetModel.percent(limit))
                    .font(.system(size: WidgetType.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(!reset && WidgetModel.fill(limit) == .problem ? palette.danger : Color.primary)
            }
            LimitMeter(limit: reset ? StatusSnapshot.Limit(label: limit.label, usedPercent: 0) : limit,
                       color: palette.fill(limit, provider: provider))
            if resetBelow, let r = limit.resetsAt { resetText(r) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.label) limit, " + (reset ? "reset since the last reading" : "\(WidgetModel.percent(limit)) used"))
    }

    private func resetText(_ date: Date) -> some View {
        Text(WidgetModel.resetText(date, now: now)).font(.system(size: WidgetType.micro)).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }
}

// MARK: - Medium: tokens today, per tool

/// Today's tokens for each tool that shows and has used some, with the estimated cost where the app shows one (none for
/// GitHub Copilot, which is billed by premium requests).
public struct UsageWidgetView: View {
    let entry: DashbarWidgetEntry

    public init(entry: DashbarWidgetEntry) { self.entry = entry }

    /// Rows that fit below the header.
    static let maxRows = 5

    public var body: some View {
        let model = WidgetModel(entry: entry)
        let rows = model.usageRows
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text("Tokens today").font(.system(size: WidgetType.title, weight: .semibold))
                    if model.local { LocalPill() }
                }
                Spacer(minLength: 4)
                if rows.count > 1 {
                    Text(WidgetModel.tokens(rows.map(\.total).reduce(0, +)) + " in all")
                        .font(.system(size: WidgetType.caption, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if model.availability == .noData {
                NoDataView(text: "Open Dashbar to see today's tokens for each tool here.")
            } else if rows.isEmpty {
                NoDataView(text: model.usageTools.isEmpty ? "No usage yet from Claude Code or your other tools."
                                                          : "No tokens used today yet.")
            } else {
                let costs = rows.contains { ($0.cost ?? 0) > 0 }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.prefix(Self.maxRows), id: \.tool) { total in
                        UsageRow(total: total, costColumn: costs)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if model.availability == .noData || rows.isEmpty { Spacer(minLength: 0) }
            StatusFooter(model: model, now: entry.date)
        }
        .opacity(LimitsWidgetView.dimmed(model) ? 0.6 : 1)
    }
}

/// One tool in the usage widget: its dot and name, today's tokens, and the estimated cost in a column of its own.
struct UsageRow: View {
    let total: StatusSnapshot.ToolTotal
    let costColumn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 5) {
                ProviderDot(provider: total.tool)
                Text(WidgetModel.usageName(total)).font(.system(size: WidgetType.body, weight: .medium)).lineLimit(1)
                    .minimumScaleFactor(0.8).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(WidgetModel.tokens(total.total))
                .font(.system(size: WidgetType.title, weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
            if costColumn {
                Text((total.cost ?? 0) > 0 ? "\u{2248} " + WidgetModel.usd(total.cost ?? 0) : "")
                    .font(.system(size: WidgetType.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sizes, for the app's offline renders

/// Each widget `--snapshot --widget` can draw: `small` is Claude's plan limits, `medium` the overview, `usage` tokens today.
public enum DashbarWidgetSize: String, CaseIterable, Sendable {
    case small, medium, codex, antigravity, opencode, copilot, usage

    public var isMedium: Bool { self == .medium || self == .usage }

    /// The tool a small widget is about; nil for the medium ones.
    public var tool: WidgetTool? {
        switch self {
        case .small: return .claude
        case .codex: return .codex
        case .antigravity: return .antigravity
        case .opencode: return .opencode
        case .copilot: return .copilot
        case .medium, .usage: return nil
        }
    }

    /// The desktop widget's size in points on macOS, as chronod reports it (macOS 27, default display).
    public var points: CGSize {
        isMedium ? CGSize(width: 344, height: 164) : CGSize(width: 164, height: 164)
    }

    @MainActor @ViewBuilder
    public func view(_ entry: DashbarWidgetEntry) -> some View {
        switch self {
        case .small: LimitsWidgetView(entry: entry)
        case .medium: OverviewWidgetView(entry: entry)
        case .codex: ToolLimitsWidgetView(entry: entry, tool: .codex)
        case .antigravity: ToolLimitsWidgetView(entry: entry, tool: .antigravity)
        case .opencode: ToolUsageWidgetView(entry: entry, tool: .opencode)
        case .copilot: ToolUsageWidgetView(entry: entry, tool: .copilot)
        case .usage: UsageWidgetView(entry: entry)
        }
    }
}
