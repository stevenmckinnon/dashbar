import SwiftUI

// MARK: - Subagents under a session

/// The panel's compact form: "4 subagents running" under a session, opening into a row per subagent.
/// The tooltip lists them too, so a glance needs no click.
struct SubagentSummary: View {
    let agents: [Subagent]
    /// Starts open, for snapshots and the window's pages.
    var startsExpanded = false
    @State private var expanded: Bool?
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool { expanded ?? startsExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded = !isExpanded }
            } label: { header }
                .buttonStyle(PressStyle())
                .help(agents.tooltip())
                .accessibilityLabel(agents.summary)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Hides the subagents" : "Lists the subagents")
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agents) { SubagentRow(agent: $0) }
                }
                .padding(.leading, 15)
                .transition(.opacity)
            }
        }
    }

    private var header: some View {
        let running = !agents.running.isEmpty
        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: UI.Size.micro, weight: .semibold))
                .foregroundStyle(UI.textSecondary)
                .frame(width: 9)
                .accessibilityHidden(true)
            Text(agents.summary)
                .font(.system(size: UI.Size.caption, weight: .medium).monospacedDigit())
                .foregroundStyle(running ? AnyShapeStyle(UI.textSuccess) : AnyShapeStyle(UI.textSecondary))
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: UI.Size.micro - 1, weight: .semibold))
                .foregroundStyle(UI.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 3)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
            .fill(Color.primary.opacity(hover ? UI.rowHover : 0)).padding(.horizontal, -4))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// One subagent: what it was asked to do, its type and model, and how long it has run (or that it's done).
struct SubagentRow: View {
    let agent: Subagent
    /// The window has room for its token count.
    var showsTokens = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                StatusDot(active: agent.isRunning, size: 5)
                    .frame(width: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent.description).font(.system(size: UI.Size.caption, weight: .medium)).lineLimit(1)
                    Text(agent.detail).font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if showsTokens, agent.tokens > 0 {
                    Text(Fmt.tokens(agent.tokens))
                        .font(.system(size: UI.Size.micro).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        .help("Tokens this subagent has used, already counted in the usage totals")
                }
                Text(agent.isRunning ? Fmt.ago(agent.started, now: ctx.date) : "Done")
                    .font(.system(size: UI.Size.caption, weight: .medium).monospacedDigit())
                    .foregroundStyle(agent.isRunning ? AnyShapeStyle(UI.textSuccess) : AnyShapeStyle(UI.textSecondary))
                    .fixedSize()
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(agent.description), \(agent.detail), "
                                + (agent.isRunning ? "running for \(Fmt.ago(agent.started, now: ctx.date))" : "done"))
        }
        .help("\(agent.description)\n\(agent.detail)")
    }
}

/// The window's form: a row per subagent, indented under its session.
struct SubagentList: View {
    let agents: [Subagent]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(agents) { SubagentRow(agent: $0, showsTokens: true) }
        }
        .padding(.leading, 15)
        .padding(.bottom, 4)
    }
}
