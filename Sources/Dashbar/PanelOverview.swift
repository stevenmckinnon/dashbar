import SwiftUI
import AppKit

// MARK: - Now: the workspace that matters right now

struct NowCard: View {
    @EnvironmentObject var store: Store
    let workspace: Workspace

    @Environment(\.openWorkspace) private var openWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { openWorkspace?(workspace.root) } label: { title }
                    .buttonStyle(PressStyle())
                    .help("Show \(workspace.name) in the Dashbar window")
                Spacer(minLength: 6)
                StatusPill(workspace: workspace)
            }
            VStack(spacing: 6) {
                ForEach(workspace.sessions.prefix(2)) { s in
                    NowSessionLine(session: s, context: store.contexts[s.id],
                                   extra: s.id == workspace.sessions.first?.id ? max(0, workspace.sessions.count - 2) : 0)
                    let agents = store.subagents(for: s)
                    if !agents.isEmpty {
                        SubagentSummary(agents: agents, startsExpanded: DemoData.subagentsOpen)
                            .padding(.leading, 33)   // under the session's name, past its tile
                    }
                }
            }
            ForEach(workspace.sessions.compactMap(store.permissionRequest(for:))) { PermissionPrompt(request: $0) }
            QuickActions(workspace: workspace)
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    private var title: some View {
            HStack(spacing: 10) {
                Monogram(name: workspace.name, root: workspace.root, active: workspace.isBusy, waiting: workspace.isWaiting, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name).font(.system(size: UI.Size.title, weight: .semibold)).lineLimit(1)
                        .help("\(workspace.name) — \(Fmt.tilde(workspace.root))")
                    Text(subtitle).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1)
                        .help(workspace.memory > 0 ? "Its dev servers and the memory they use. The Dashbar window shows the whole workspace's." : "")
                }
                Image(systemName: "chevron.right").font(.system(size: UI.Size.micro, weight: .semibold)).foregroundStyle(UI.textSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
    }

    private var subtitle: String {
        let servers = workspace.servers.prefix(2).map { l -> String in
            let name = l.hint.split(separator: " ").first.map(String.init) ?? l.command
            return "\(name) :" + String(l.port)
        }
        var parts = servers
        // Straight after the server's name, so it reads as that server's memory (the tooltip says so too).
        if workspace.memory > 0 { parts.append(Fmt.bytes(workspace.memory)) }
        return parts.isEmpty ? Fmt.tilde(workspace.root) : parts.joined(separator: " · ")
    }
}

struct StatusPill: View {
    let workspace: Workspace
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let waiting = workspace.sessions.first(where: \.isWaiting)
            let busy = workspace.sessions.first(where: \.isBusy)
            let s = waiting ?? busy ?? workspace.sessions.first
            HStack(spacing: 5) {
                StatusDot(active: waiting == nil && busy != nil, waiting: waiting != nil, size: 6)
                Text(waiting.map(\.waitingLabel) ?? (busy != nil ? "Working" : "Idle"))
                    .foregroundStyle(waiting != nil ? AnyShapeStyle(UI.textAttention) : AnyShapeStyle(.primary))
                if let s { Text(Fmt.ago(s.since, now: ctx.date)).foregroundStyle(UI.textSecondary) }
            }
            .font(.system(size: UI.Size.caption, weight: .medium).monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(waiting != nil ? UI.attention.opacity(0.14)
                                       : (busy != nil ? Color.green : Color.primary).opacity(busy != nil ? 0.12 : 0.06)))
            .accessibilityElement(children: .combine)   // "Working, 4m" as one, not a bare time
        }
    }
}

struct NowSessionLine: View {
    @EnvironmentObject var store: Store
    let session: LiveSession
    let context: ContextInfo?
    let extra: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.agent.symbol)
                .font(.system(size: UI.Size.caption, weight: .semibold))
                .foregroundStyle(session.agent.tint)
                .accessibilityLabel(session.agent.name)   // the tile is what names the agent; VoiceOver hears it too
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(session.agent.tint.opacity(0.12)))
                .help(session.agent.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("\(session.name)\n\(OpenSession.hint(session))")
                Text(subtitle)
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).lineLimit(1)
                    .help(store.spawned[session.pid]?.tooltip ?? "")
            }
            Spacer(minLength: 6)
            if let context {
                HStack(spacing: 8) {
                    ContextBar(fraction: context.fraction).frame(width: 56)
                    ContextLabel(context: context)
                }
                .help(context.explanation)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(context.accessibilityText)
            }
        }
        .modifier(OpenSession(session: session))
    }

    /// "1 more agent", "2 more agents".
    static func moreAgents(_ n: Int) -> String { n == 1 ? "1 more agent" : "\(n) more agents" }

    /// "Work · Terminal · runs :3000 · 1 more agent". The account leads, so it survives a narrow panel; the Claude tile
    /// already says which agent it is, so the line doesn't spend room on "Claude Code".
    private var subtitle: String {
        let host = HostApp.info(for: session)?.name ?? session.surface
        let agent = session.agentNote.flatMap { $0 == host ? nil : $0 }
        return ([session.account, agent, host, store.spawned[session.pid]?.portsText, extra > 0 ? Self.moreAgents(extra) : nil] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Widgets: context, last 5 hours, today

struct WidgetRow: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let days = store.claude.last14
        let recent = days.suffix(7).reduce(0) { $0 + $1.tokens }
        let before = days.prefix(7).reduce(0) { $0 + $1.tokens }
        HStack(spacing: UI.gap) {
            // Claude Code's usage only: the title says so, as the plan limits card's "Claude · Max 5x" does.
            Widget(title: "Claude · today") {
                BigNumber(Fmt.tokens(store.claude.today.total), unit: "tokens")
                Spacer(minLength: 4)
                DayBars(points: Array(days.suffix(7)), tint: UI.claudeFill)
                Spacer(minLength: 4)
                Footnote(Self.sessionsText(store.claude.sessionsToday))
                    .help(Self.messagesHelp(store.claude.today.messages))
            }
            Widget(title: "Claude · last 7 days") {
                BigNumber(Fmt.tokens(recent), unit: "tokens")
                Spacer(minLength: 4)
                WeekCompare(this: recent, last: before)
                Spacer(minLength: 4)
                Footnote(Self.changeText(this: recent, last: before))
            }
        }
    }

    static func sessionsText(_ n: Int) -> String { n == 1 ? "1 session today" : "\(n) sessions today" }

    /// The message count counts each of Claude's replies and tool steps, not what you typed, so it lives in the tooltip.
    static func messagesHelp(_ n: Int) -> String {
        "Claude Code tokens since midnight. Claude sent \(n.formatted()) \(n == 1 ? "message" : "messages") today, "
            + "counting each step of its tool use."
    }

    /// Direction in words, so the change never rests on colour. The span is a rolling 7 days, not a calendar week.
    static func changeText(this: Int, last: Int) -> String {
        guard last > 0 else { return "No usage the 7 days before" }
        let pct = Int((Double(this - last) / Double(last) * 100).rounded())
        if pct == 0 { return "Same as the 7 days before" }
        return "\(pct > 0 ? "Up" : "Down") \(abs(pct))% on the 7 days before"
    }
}

struct WeekCompare: View {
    let this: Int
    let last: Int

    var body: some View {
        let maxV = Double(max(this, last, 1))
        VStack(alignment: .leading, spacing: 5) {
            bar("Last 7", value: this, maxV: maxV, fill: UI.claudeFill)
            bar("Prior 7", value: last, maxV: maxV, fill: UI.dataPast)
        }
        .accessibilityElement()
        .accessibilityLabel("Last 7 days \(Fmt.tokens(this)) tokens, the 7 days before \(Fmt.tokens(last))")
    }

    private func bar(_ label: String, value: Int, maxV: Double, fill: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary).fixedSize()
                .frame(minWidth: 34, alignment: .leading)
            GeometryReader { g in
                // Nothing drawn for nothing used; a tiny week still shows as a sliver.
                Capsule().fill(fill).frame(width: Meter.width(Double(value) / maxV, in: g.size.width, minimum: 3))
            }
            .frame(height: 5)
            // Sized to its text, so "12.4B" or "1.20T" never truncates; the bar takes what is left.
            Text(Fmt.tokens(value)).font(.system(size: UI.Size.micro).monospacedDigit()).foregroundStyle(UI.textSecondary)
                .fixedSize().frame(minWidth: 34, alignment: .trailing)
        }
    }
}

struct Widget<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "asterisk").font(.system(size: UI.Size.micro, weight: .bold)).foregroundStyle(UI.claude)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
            }
            .padding(.bottom, 8)
            content
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130, alignment: .topLeading)
        .surface()
    }
}

/// Claude's tokens for each of the last seven days, today last and in Claude's colour, each bar over its weekday's
/// initial in the user's language. Bars keep a bar's width however wide the widget is.
struct DayBars: View {
    let points: [DayPoint]
    let tint: Color
    static let height: CGFloat = 20

    var body: some View {
        let maxV = Double(points.map(\.tokens).max() ?? 0)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(points) { p in
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        // A hairline baseline, so a day with nothing still has its place.
                        Capsule().fill(Color.primary.opacity(0.12)).frame(height: 1)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(p.isToday ? tint : UI.dataPast)
                            .frame(height: maxV > 0 ? Meter.width(Double(p.tokens) / maxV, in: Self.height, minimum: 2) : 0)
                    }
                    .frame(width: 10, height: Self.height, alignment: .bottom)
                    Text(Self.initial(p.date)).font(.system(size: UI.Size.micro, weight: p.isToday ? .semibold : .regular))
                        .foregroundStyle(p.isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(UI.textSecondary))
                        .fixedSize()
                }
                .frame(minWidth: 12)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Claude tokens by day, last 7 days")
        .accessibilityValue(points.map { "\($0.isToday ? "today" : Self.dayName($0.date)) \(Fmt.tokens($0.tokens))" }.joined(separator: ", "))
    }

    /// The weekday's narrow form in the user's language: "M", "T"… in English, "L", "M"… in French.
    static func initial(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.narrow))
    }

    static func dayName(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide)) }
}

/// A widget's figure, with its unit small and secondary beside it, as the Clean-up tile sets "GB".
struct BigNumber: View {
    let text: String
    var unit: String? = nil
    init(_ text: String, unit: String? = nil) { self.text = text; self.unit = unit }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text).font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1)
            if let unit {
                Text(unit).font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary).fixedSize()
            }
        }
    }
}

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1).truncationMode(.tail)
    }
}
