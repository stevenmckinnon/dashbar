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
    var working: Color { pick(0x1A7F37, 0x3FD06A) }
    var attention: Color { pick(0xBF8700, 0xE3B341) }
    var danger: Color { pick(0xC4320A, 0xFF6B5E) }
    var track: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }

    func provider(_ id: String) -> Color {
        switch id {
        case "claude": return claude
        case "codex": return codex
        case "antigravity", "google": return google
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

// MARK: - Small: Claude plan limits

/// Claude's 5-hour and weekly limits with their reset times.
public struct LimitsWidgetView: View {
    let entry: DashbarWidgetEntry
    @Environment(\.colorScheme) private var scheme

    public init(entry: DashbarWidgetEntry) { self.entry = entry }

    public var body: some View {
        let model = WidgetModel(entry: entry)
        let row = model.claude
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ProviderDot(provider: "claude")
                Text(row?.name ?? "Claude").font(.system(size: WidgetType.title, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let plan = row?.plan {
                    Text(plan).font(.system(size: WidgetType.micro)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if model.availability == .noData {
                NoDataView(text: "Open Dashbar to see your Claude plan limits here.")
            } else if let row, let problem = row.problem {
                NoDataView(text: problem)
            } else if let row, !row.limits.isEmpty {
                ForEach(Array(row.limits.prefix(2).enumerated()), id: \.offset) { _, limit in
                    LimitBlock(limit: limit, provider: "claude", now: entry.date)
                }
            } else {
                NoDataView(text: "No Claude plan limits. Dashbar shows them once they're set up in its Settings.")
            }
            Spacer(minLength: 0)
            StatusFooter(model: model, now: entry.date)
        }
        .opacity(Self.dimmed(model) ? 0.6 : 1)
    }

    static func dimmed(_ model: WidgetModel) -> Bool {
        if case .notRunning = model.availability { return true }
        return false
    }
}

/// One limit in the small widget: its window and figure, the meter, and when it resets.
struct LimitBlock: View {
    let limit: StatusSnapshot.Limit
    let provider: String
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = WidgetPalette(scheme)
        let reset = limit.hasReset(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(WidgetModel.title(limit)).font(.system(size: WidgetType.caption, weight: .medium))
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
        .accessibilityLabel("\(WidgetModel.title(limit)) limit, " + (reset ? "reset since the last reading" : "\(WidgetModel.percent(limit)) used"))
    }
}

// MARK: - Medium: every tool's limits and the agents

/// Plan limits for each tool that reports them, and how many agents are working or waiting for you.
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
                Text("Dashbar").font(.system(size: WidgetType.title, weight: .semibold))
                Spacer(minLength: 4)
                if let agents = model.agents { AgentCountsView(agents: agents) }
            }
            if model.availability == .noData {
                NoDataView(text: "Open Dashbar to see plan limits and your agents here.")
            } else if model.rows.isEmpty {
                NoDataView(text: "No plan limits from Claude Code, Codex or Antigravity yet.")
            } else {
                ForEach(model.rows.prefix(Self.maxRows)) { row in
                    OverviewRow(row: row, now: entry.date)
                }
                if model.rows.count > Self.maxRows {
                    Text("\(model.rows.count - Self.maxRows) more in Dashbar")
                        .font(.system(size: WidgetType.micro)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
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
        HStack(spacing: 10) {
            if agents.working == 0 && agents.needsYou == 0 {
                Text(agents.idle > 0 ? "No agents working" : "No agents")
                    .font(.system(size: WidgetType.caption)).foregroundStyle(.secondary)
            } else {
                if agents.working > 0 { count(agents.working, "working", palette.working) }
                if agents.needsYou > 0 { count(agents.needsYou, agents.needsYou == 1 ? "needs you" : "need you", palette.attention) }
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
                ForEach(Array(row.limits.enumerated()), id: \.offset) { _, limit in
                    CompactLimit(limit: limit, provider: row.provider, now: now)
                }
                if row.limits.count == 1 { Spacer(minLength: 0).frame(maxWidth: .infinity) }
            }
        }
    }
}

/// A limit in the medium widget: "5h 14:20  55%" over its meter (the short window name `dashbar line` prints).
struct CompactLimit: View {
    let limit: StatusSnapshot.Limit
    let provider: String
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = WidgetPalette(scheme)
        let reset = limit.hasReset(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(StatusFormat.shortWindow(limit)).font(.system(size: WidgetType.micro, weight: .medium)).lineLimit(1)
                if let r = limit.resetsAt {
                    Text(WidgetModel.resetText(r, now: now)).font(.system(size: WidgetType.micro)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(reset ? "–" : WidgetModel.percent(limit))
                    .font(.system(size: WidgetType.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(!reset && WidgetModel.fill(limit) == .problem ? palette.danger : Color.primary)
            }
            LimitMeter(limit: reset ? StatusSnapshot.Limit(label: limit.label, usedPercent: 0) : limit,
                       color: palette.fill(limit, provider: provider))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(WidgetModel.title(limit)) limit, " + (reset ? "reset since the last reading" : "\(WidgetModel.percent(limit)) used"))
    }
}

// MARK: - Sizes, for the app's offline renders

public enum DashbarWidgetSize: String, CaseIterable, Sendable {
    case small, medium

    /// The desktop widget's size in points on macOS.
    public var points: CGSize {
        switch self {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 364, height: 170)
        }
    }

    @MainActor @ViewBuilder
    public func view(_ entry: DashbarWidgetEntry) -> some View {
        switch self {
        case .small: LimitsWidgetView(entry: entry)
        case .medium: OverviewWidgetView(entry: entry)
        }
    }
}
