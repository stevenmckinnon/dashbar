import SwiftUI
import AppKit

// MARK: - Workspaces

struct WorkspacesCard: View {
    @EnvironmentObject var store: Store
    let query: String
    var clearQuery: () -> Void = {}
    /// The workspace already shown in the Now card.
    var excluding: String?
    /// Show a waiting permission prompt under its workspace even while the row is collapsed.
    var showsPrompts = false

    var body: some View {
        let list = store.workspaces.filter { $0.id != excluding && $0.matches(query) }
        if !(list.isEmpty && excluding != nil && AgentChips.items(store.otherAgents, sessions: store.sessions).isEmpty) {
            card(list)
        }
    }

    private func card(_ list: [Workspace]) -> some View {
        Card(title: excluding == nil ? "Workspaces" : "Other workspaces", icon: "square.stack.3d.up", tint: .indigo, count: list.count) {
            if list.isEmpty && !query.isEmpty {
                HStack {
                    EmptyRow(text: "No workspaces match “\(query)”")
                    Button("Clear filter", action: clearQuery)
                        .buttonStyle(PressStyle()).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textInfo)
                }
            } else if list.isEmpty {
                EmptyRow(text: "No agents or dev servers running. Start Claude Code or a dev server and it shows up here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, w in
                        if i > 0 { Divider().opacity(0.5).padding(.leading, 40) }
                        WorkspaceRow(workspace: w, autoExpand: !query.isEmpty, showsPrompts: showsPrompts)
                    }
                }
            }
            let others = AgentChips.items(store.otherAgents, sessions: store.sessions)
            if !others.isEmpty && query.isEmpty {
                AgentChips(items: others).padding(.top, 4)
            }
        }
    }
}

struct WorkspaceRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workspace: Workspace
    var autoExpand = false
    /// Collapsed, it still shows its sessions' permission prompts (expanded, each sits under its session).
    var showsPrompts = false
    @State private var expanded: Bool?
    @State private var hover = false

    private var isExpanded: Bool { expanded ?? autoExpand }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) { header }
                .buttonStyle(PressStyle())
                .help("\(workspace.name) — \(Fmt.tilde(workspace.root))")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Hides its sessions and actions" : "Shows its sessions and actions")
            if isExpanded {
                detail.transition(reduceMotion
                    ? .opacity
                    : .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity))
            } else if showsPrompts {
                ForEach(workspace.sessions.compactMap(store.permissionRequest(for:))) { PermissionPrompt(request: $0) }
                    .padding(.leading, 42)
            }
        }
        .padding(.vertical, 4)
    }

    private func toggle() {
        let opening = !isExpanded
        // Collapsing gets out of the way faster than expanding.
        let anim: Animation? = reduceMotion ? .easeOut(duration: 0.15) : (opening ? .snappy(duration: 0.25) : .easeOut(duration: 0.15))
        withAnimation(anim) { expanded = opening }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Monogram(name: workspace.name, root: workspace.root, active: workspace.isBusy, waiting: workspace.isWaiting, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.system(size: UI.Size.emphasis, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                WorkspaceStatus(workspace: workspace)
            }
            Spacer(minLength: 6)
            if !workspace.servers.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: portsLabel).font(.system(size: UI.Size.caption, weight: .medium).monospacedDigit())
                    if workspace.memory > 0 {
                        // Only its dev servers' memory: the window's workspace figures add up everything else too.
                        Text(Self.serverMemory(workspace)).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                            .help("Memory its dev servers are using. The Dashbar window shows the whole workspace's.")
                    }
                }
            } else if !workspace.sessions.isEmpty {
                // No server to show: say what it has, so the row doesn't end in a gap.
                Text(workspace.sessions.count == 1 ? "1 agent" : "\(workspace.sessions.count) agents")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: UI.Size.micro, weight: .semibold))
                .foregroundStyle(UI.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
            .fill(Color.primary.opacity(hover ? UI.rowHover : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    /// "server 412 MB", "servers 1.2 GB".
    static func serverMemory(_ w: Workspace) -> String {
        (Set(w.servers.map(\.pid)).count > 1 ? "servers " : "server ") + Fmt.bytes(w.memory)
    }

    private var portsLabel: String {
        let p = workspace.ports
        let shown = p.prefix(2).map { ":" + String($0) }.joined(separator: " ")
        return p.count > 2 ? shown + " +\(p.count - 2)" : shown
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(workspace.sessions) { SessionBlock(session: $0) }
            ForEach(workspace.servers) { ServerRow(listener: $0, inWorkspace: true) }
            QuickActions(workspace: workspace).padding(.top, 4)
        }
        .padding(.leading, 42)
        .padding(.bottom, 6)
    }
}

struct WorkspaceStatus: View {
    @EnvironmentObject var store: Store
    let workspace: Workspace
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(text(now: ctx.date))
                .font(.system(size: UI.Size.caption).monospacedDigit())
                .foregroundStyle(workspace.isWaiting ? AnyShapeStyle(UI.textAttention)
                                 : workspace.isBusy || subagentsRunning ? AnyShapeStyle(UI.textSuccess) : AnyShapeStyle(UI.textSecondary))
                .lineLimit(1)
        }
    }

    private var subagentsRunning: Bool {
        workspace.sessions.contains { !store.subagents(for: $0).running.isEmpty }
    }

    private func text(now: Date) -> String {
        let s = workspace.sessions
        let more = s.count > 1 ? " · " + NowSessionLine.moreAgents(s.count - 1) : ""
        if let waiting = s.first(where: \.isWaiting) {
            return "\(waiting.waitingSentence) · \(Fmt.ago(waiting.since, now: now))" + more
        }
        let subagents = s.reduce(0) { $0 + store.subagents(for: $1).running.count }
        let helpers = subagents == 0 ? "" : subagents == 1 ? " · 1 subagent" : " · \(subagents) subagents"
        if let busy = s.first(where: \.isBusy) {
            return "\(busy.agent.name) working · \(Fmt.ago(busy.since, now: now))" + helpers + more
        }
        if subagents > 0 {   // the session waits while its background subagents work
            return (subagents == 1 ? "1 subagent working" : "\(subagents) subagents working") + more
        }
        if let idle = s.first {
            return "\(idle.agent.name) idle · \(Fmt.ago(idle.since, now: now))" + more
        }
        return workspace.servers.map(\.hint).uniqued().prefix(2).joined(separator: " · ")
    }
}

struct SessionLine: View {
    @EnvironmentObject var store: Store
    let session: LiveSession
    let context: ContextInfo?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                StatusDot(active: session.isBusy, waiting: session.isWaiting, size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1)
                        .help("\(session.name)\n\(Fmt.tilde(session.cwd))\n\(OpenSession.hint(session))")
                        .accessibilityLabel(session.spokenTitle)
                    let host = HostApp.info(for: session)?.name ?? session.surface
                    // Google's agents say which they are; Claude's rows don't spend the room.
                    Text((session.agentNote.map { $0 + " · " } ?? "")
                         + "\(session.isWaiting ? session.waitingLabel : session.isBusy ? "Working" : session.status.capitalized) \(Fmt.ago(session.since, now: ctx.date))"
                         + (host == session.agent.name ? "" : " · " + host)
                         + (session.account.map { " · " + $0 } ?? "")
                         + (store.spawned[session.pid]?.portsText.map { " · " + $0 } ?? ""))
                        .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1)
                        .help(store.spawned[session.pid]?.tooltip ?? "")
                }
                Spacer(minLength: 6)
                if let context {
                    HStack(spacing: 6) {
                        ContextLabel(context: context)
                        ContextRing(fraction: context.fraction)
                    }
                    .help(context.explanation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(context.accessibilityText)
                }
            }
            .padding(.vertical, 3)
        }
        .modifier(OpenSession(session: session))
    }
}

/// A session row's actions: a click goes back to the app the session runs in (its terminal, VS Code, T3 Code, the
/// Desktop app); the context menu also opens its folder in the editor or Finder.
struct OpenSession: ViewModifier {
    let session: LiveSession
    @State private var hover = false

    /// "Click to open in Ghostty"
    @MainActor static func hint(_ s: LiveSession) -> String {
        if let host = HostApp.info(for: s) { return "Click to open in \(host.name)" }
        if let editor = Launcher.editor { return "Click to open its folder in \(editor.name)" }
        return "Click to show its folder in Finder"
    }

    func body(content: Content) -> some View {
        let host = HostApp.info(for: session)
        let editor = Launcher.editor
        Button { HostApp.open(host?.bundle, root: session.root) } label: {
            content
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hover ? UI.rowHover : 0))
                    .padding(.horizontal, -4))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .contextMenu {
            if let host { Button("Open in \(host.name)") { HostApp.open(host.bundle, root: session.root) } }
            if let editor { Button("Open folder in \(editor.name)") { Launcher.open(session.root, in: editor) } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.root)]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Self.hint(session))
        .accessibilityAction(named: host.map { "Open in \($0.name)" } ?? "Open") { HostApp.open(host?.bundle, root: session.root) }
        .accessibilityAction(named: "Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.root)])
        }
    }
}

/// "22%" over "context used", so the number explains itself.
struct ContextLabel: View {
    let context: ContextInfo
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(Int((context.fraction * 100).rounded()))%")
                .font(.system(size: UI.Size.caption, weight: .semibold).monospacedDigit())
                .foregroundStyle(ContextRing.textColor(context.fraction))
            Text("context used")
                .font(.system(size: UI.Size.micro))
                .foregroundStyle(UI.textSecondary)
        }
        .fixedSize()
    }
}

extension LiveSession {
    /// "Claude: Fix flaky invoice export test": which agent a row belongs to, for VoiceOver, unless the row already
    /// says it (a Google agent's note, or a title that is the agent's name).
    var spokenTitle: String {
        agentNote != nil || title == agent.name ? title : "\(agent.name): \(title)"
    }
}

extension SpawnedProcesses {
    /// "runs :3000, :5173"
    var portsText: String? {
        ports.isEmpty ? nil : "runs " + ports.prefix(3).map { ":" + String($0) }.joined(separator: ", ")
    }

    var tooltip: String {
        guard count > 0 else { return "" }
        let processes = count == 1 ? "1 process" : "\(count) processes"
        let names = names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
        return "This session started \(processes) using \(Fmt.bytes(memory))\(names)."
    }
}

extension ContextInfo {
    var explanation: String {
        "Context window: \(Fmt.tokens(used)) of \(Fmt.tokens(window)) tokens used.\n"
            + "This is how much of the conversation Claude is holding. When it fills up, Claude Code compacts older messages into a summary."
    }
    var accessibilityText: String { "\(Int((fraction * 100).rounded())) percent of context window used" }
}

struct ContextRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.5
    enum Level: Equatable { case fine, filling, nearlyFull }
    /// Fine (neutral), getting full (amber, from 70%: compaction is coming soon) and nearly full (red, from 85%).
    static func level(_ f: Double) -> Level { f >= 0.85 ? .nearlyFull : f >= 0.70 ? .filling : .fine }
    static func color(_ f: Double) -> Color {
        switch level(f) {
        case .fine: return UI.meterFill
        case .filling: return UI.attention
        case .nearlyFull: return UI.textDanger
        }
    }
    /// The same levels in text ink, for the percentage beside the bar.
    static func textColor(_ f: Double) -> Color {
        switch level(f) {
        case .fine: return .primary
        case .filling: return UI.textAttention
        case .nearlyFull: return UI.textDanger
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(UI.track, lineWidth: lineWidth)
            Circle().trim(from: 0, to: fraction)
                .stroke(Self.color(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fraction)
    }
}

struct ContextBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(UI.track)
                Capsule().fill(ContextRing.color(fraction)).frame(width: Meter.width(fraction, in: g.size.width, minimum: 3))
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fraction)
    }
}

struct QuickActions: View {
    let workspace: Workspace
    /// The detail page itself leaves out the button that opens it.
    var showDetails = true
    /// The Now card names each action under its icon, in the words the window's workspace page uses.
    var labelled = false
    @Environment(\.openWorkspace) private var openWorkspace
    var body: some View {
        HStack(spacing: 6) {
            if showDetails, let openWorkspace {
                ActionTile(symbol: "chart.bar.xaxis", help: "Show in the Dashbar window") { openWorkspace(workspace.root) }
            }
            if let editor = Launcher.editor {
                // "Open in VS Code" is the window's label, but it doesn't fit a quarter of the card; the editor's name
                // does, beside the terminal's, and the tooltip and VoiceOver still say "Open in VS Code".
                ActionTile(symbol: "curlybraces", help: "Open in \(editor.name)", title: labelled ? editor.name : nil) {
                    Launcher.open(workspace.root, in: editor)
                }
            }
            if let term = Launcher.terminal {
                ActionTile(symbol: "terminal", help: "Open in \(term.name)", title: labelled ? term.name : nil) {
                    Launcher.open(workspace.root, in: term)
                }
            }
            ActionTile(symbol: "folder", help: "Reveal in Finder", title: labelled ? "Finder" : nil) { Launcher.reveal(workspace.root) }
            if let port = workspace.ports.first {
                ActionTile(symbol: "safari", help: "Open localhost:" + String(port), title: labelled ? "localhost:" + String(port) : nil) {
                    Launcher.browse(port: port)
                }
            } else {
                ActionTile(symbol: "doc.on.doc", help: "Copy path", title: labelled ? "Copy path" : nil) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspace.root, forType: .string)
                }
            }
        }
    }
}

struct ActionTile: View {
    let symbol: String
    let help: String
    /// A short visible name under the icon; without one the tile is the icon alone, named by its tooltip.
    var title: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: UI.Size.body, weight: .medium))
                    .frame(height: title == nil ? nil : 16)   // labelled tiles stay one height whatever the symbol
                if let title {
                    Text(title).font(.system(size: UI.Size.micro, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, title == nil ? 0 : 4)
            .padding(.vertical, title == nil ? 0 : 6)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                .fill(Color.primary.opacity(hover ? UI.buttonHover : UI.rowHover)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(UI.textSecondary))
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
