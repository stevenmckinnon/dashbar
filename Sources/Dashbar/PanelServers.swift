import SwiftUI
import AppKit

// MARK: - Servers not tied to a repo

struct ServersCard: View {
    @EnvironmentObject var store: Store
    let query: String
    /// The Servers tab lists every dev server; Overview only those outside a project (projects show theirs).
    var includeProjects = false
    @State private var showOthers = false

    var body: some View {
        let loose = (includeProjects ? store.devListeners : store.looseServers).filter { matches($0) }
        let others = store.otherListeners.filter { matches($0) }
        if !loose.isEmpty || !others.isEmpty || includeProjects {
            Card(title: includeProjects ? "Dev servers" : "Servers", icon: "server.rack", tint: .blue, count: Set(loose.map(\.pid)).count) {
                if loose.isEmpty {
                    EmptyRow(text: query.isEmpty ? "No dev servers running" : "No servers match “\(query)”")
                }
                VStack(spacing: 2) {
                    ForEach(groupedByProcess(loose), id: \.first!.id) { group in
                        ServerRow(listener: group[0], extraPorts: group.dropFirst().map(\.port))
                    }
                }
                if !others.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { showOthers || !query.isEmpty }, set: { showOthers = $0 })) {
                        VStack(spacing: 2) { ForEach(others) { ServerRow(listener: $0, compact: true) } }.padding(.top, 4)
                    } label: {
                        Text("Other apps listening (\(others.count))").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    }
                    .padding(.top, loose.isEmpty ? 0 : 4)
                }
            }
        }
    }

    private func groupedByProcess(_ ls: [Listener]) -> [[Listener]] {
        var order: [Int32] = []
        var groups: [Int32: [Listener]] = [:]
        for l in ls {
            if groups[l.pid] == nil { order.append(l.pid) }
            groups[l.pid, default: []].append(l)
        }
        return order.compactMap { groups[$0]?.sorted { $0.port < $1.port } }
    }

    private func matches(_ l: Listener) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        return q.isEmpty || String(l.port).hasPrefix(q) || l.title.lowercased().contains(q) || l.hint.lowercased().contains(q)
    }
}

struct ServerRow: View {
    @EnvironmentObject var store: Store
    let listener: Listener
    var compact = false
    var inWorkspace = false
    var extraPorts: [Int] = []
    @State private var hover = false
    @State private var confirmStop = false
    @FocusState private var focusedAction: Int?
    @Environment(\.inWindow) private var inWindow

    private var starter: LiveSession? {
        listener.startedBy.flatMap { pid in store.sessions.first { $0.pid == pid } }
    }

    /// "Barely used · started by Claude · up 3d · node next dev": status first, so truncation only eats the command.
    private var details: Text {
        var words: [String] = []
        if listener.isIdle { words.append("barely used") }
        if listener.startedBy != nil { words.append("started by Claude") }
        if let started = listener.started { words.append("up " + Fmt.ago(started)) }
        if let first = words.first { words[0] = first.prefix(1).uppercased() + first.dropFirst() }
        var parts = words.map { Text($0) }
        if listener.isIdle { parts[0] = Text("\(Image(systemName: "moon.zzz")) ") + parts[0] }
        if !inWorkspace { parts.append(Text(listener.hint).font(.system(size: UI.Size.caption, design: .monospaced))) }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() { line = line + Text(" · ") + part }
        return line
    }

    /// Actions show on hover, and also whenever one of them holds keyboard focus. The window always shows them.
    private var revealed: Bool { inWindow || hover || confirmStop || focusedAction != nil }

    private var memoryText: some View {
        Text(Fmt.bytes(listener.memory)).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
            .help("Memory this server is using")
    }

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 4) {
                ForEach([listener.port] + extraPorts, id: \.self) { port in
                    Text(verbatim: ":" + String(port))
                        .font(.system(size: UI.Size.caption, weight: .semibold, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((compact ? Color.secondary : UI.textInfo).opacity(compact ? 0.14 : 0.12)))
                        .foregroundStyle(compact ? UI.textSecondary : UI.textInfo)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(inWorkspace ? listener.hint : listener.title)
                    .font(.system(size: UI.Size.body, weight: .medium, design: inWorkspace ? .monospaced : .default))
                    .lineLimit(1)
                if !compact && (!inWorkspace || listener.isIdle || listener.startedBy != nil) {
                    details.font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if inWindow && listener.memory > 0 && !compact && !confirmStop {
                memoryText.padding(.trailing, 4)
            }
            ZStack(alignment: .trailing) {
                if listener.memory > 0 && !compact && !inWindow {
                    memoryText.opacity(revealed ? 0 : 1)
                }
                HStack(spacing: 2) {
                    if !compact {
                        IconButton(symbol: "arrow.up.right.square", help: "Open localhost:" + String(listener.port)) {
                            Launcher.browse(port: listener.port)
                        }
                        .focused($focusedAction, equals: 0)
                    }
                    if confirmStop {
                        ConfirmButton(title: "Stop process") { store.stop(listener); confirmStop = false }
                            .focused($focusedAction, equals: 2)
                        IconButton(symbol: "xmark", help: "Cancel") { confirmStop = false }
                    } else {
                        IconButton(symbol: "stop.circle", help: "Stop process \(listener.pid) on port " + String(listener.port)) { confirmStop = true }
                            .focused($focusedAction, equals: 1)
                    }
                }
                .opacity(revealed ? 1 : 0)
                .allowsHitTesting(revealed)
            }
        }
        .padding(.vertical, compact ? 2 : 4).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
            .fill(Color.primary.opacity(hover ? UI.rowHover : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0; if !$0 && focusedAction == nil { confirmStop = false } }
        .help("\(listener.cmdline)\n\(listener.cwd)\nPID \(listener.pid) · \(listener.address)"
              + (starter.map { "\nStarted by Claude Code: \($0.name)" } ?? "")
              + (listener.isIdle ? "\nUp over an hour and barely using any CPU, so it's probably safe to stop." : ""))
        .contextMenu {
            Button("Open localhost:" + String(listener.port)) { Launcher.browse(port: listener.port) }
            Divider()
            Button("Stop process…", role: .destructive) { confirmStop = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open in browser") { Launcher.browse(port: listener.port) }
        .accessibilityAction(named: "Stop process") { confirmStop = true }
    }
}
