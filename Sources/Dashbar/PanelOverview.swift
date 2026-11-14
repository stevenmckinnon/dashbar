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
                .accessibilityHidden(true)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(session.agent.tint.opacity(0.12)))
                .help(session.agent.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1)
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

    /// "Work · Terminal · runs :3000 · 1 more". The account leads, so it survives a narrow panel; the Claude tile
    /// already says which agent it is, so the line doesn't spend room on "Claude Code".
    private var subtitle: String {
        let host = HostApp.info(for: session)?.name ?? session.surface
        let agent = session.agent.isGoogle && host != session.agent.name ? session.agent.name : nil
        return ([session.account, agent, host, store.spawned[session.pid]?.portsText, extra > 0 ? "\(extra) more" : nil] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Widgets: context, last 5 hours, today

struct WidgetRow: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let days = store.claude.last14
        let thisWeek = days.suffix(7).reduce(0) { $0 + $1.tokens }
        let lastWeek = days.prefix(7).reduce(0) { $0 + $1.tokens }
        HStack(spacing: UI.gap) {
            Widget(title: "Today") {
                BigNumber(Fmt.tokens(store.claude.today.total))
                Spacer(minLength: 4)
                DayBars(points: Array(days.suffix(7)), tint: UI.textInfo)
                Spacer(minLength: 4)
                Footnote("\(store.claude.today.messages) msgs · \(store.claude.sessions24) sessions in 24h")
            }
            Widget(title: "This week") {
                BigNumber(Fmt.tokens(thisWeek))
                Spacer(minLength: 4)
                WeekCompare(this: thisWeek, last: lastWeek)
                Spacer(minLength: 4)
                Footnote(changeText(this: thisWeek, last: lastWeek))
            }
        }
    }

    /// Direction in words, so the change never rests on colour.
    private func changeText(this: Int, last: Int) -> String {
        guard last > 0 else { return "No usage the week before" }
        let pct = Int((Double(this - last) / Double(last) * 100).rounded())
        if pct == 0 { return "Same as the week before" }
        return "\(pct > 0 ? "Up" : "Down") \(abs(pct))% on the week before"
    }
}

struct WeekCompare: View {
    let this: Int
    let last: Int

    var body: some View {
        let maxV = Double(max(this, last, 1))
        VStack(alignment: .leading, spacing: 5) {
            bar("This", value: this, maxV: maxV, fill: UI.textInfo)
            bar("Prev", value: last, maxV: maxV, fill: Color.secondary.opacity(0.45))
        }
        .accessibilityElement()
        .accessibilityLabel("This week \(Fmt.tokens(this)) tokens, the week before \(Fmt.tokens(last))")
    }

    private func bar(_ label: String, value: Int, maxV: Double, fill: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary).frame(width: 28, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(fill).frame(width: max(3, g.size.width * Double(value) / maxV))
            }
            .frame(height: 5)
            Text(Fmt.tokens(value)).font(.system(size: UI.Size.micro).monospacedDigit()).foregroundStyle(UI.textSecondary)
                .frame(width: 34, alignment: .trailing)
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
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .topLeading)
        .surface()
    }
}

struct DayBars: View {
    let points: [DayPoint]
    let tint: Color
    var body: some View {
        let maxV = Double(points.map(\.tokens).max() ?? 0)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(points) { p in
                RoundedRectangle(cornerRadius: 2)
                    .fill(p.isToday ? tint : Color.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: maxV > 0 ? max(3, 22 * Double(p.tokens) / maxV) : 3)
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

struct BigNumber: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1)
    }
}

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1).truncationMode(.tail)
    }
}
