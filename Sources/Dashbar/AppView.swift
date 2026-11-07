import SwiftUI
import AppKit

/// The Dashbar window: the panel's pages and every running workspace in a sidebar, the chosen one beside it.
struct AppView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: AppWindowModel
    /// Snapshots render without a window to report visibility.
    var snapshot = false
    /// Filters the sidebar's workspaces and the open page, like the panel's filter.
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $model.page, query: $query, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 300)
        } detail: {
            AppDetail(page: model.page, query: query.trimmingCharacters(in: .whitespaces)) { model.page = $0 }
        }
        .environment(\.openWorkspace) { root in model.page = .workspace(root) }
        .frame(minWidth: AppWindow.minimumSize.width, minHeight: AppWindow.minimumSize.height)
        .background { if !snapshot { WindowVisibilityReader { store.setPanelVisible($0, surface: "window") } } }
        .onAppear { store.setPanelVisible(true, surface: "window") }
        .onDisappear { store.setPanelVisible(false, surface: "window") }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("k").opacity(0)
            // ⌘1…⌘5 open the pages, as they switch tabs in the panel.
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.offset) { i, t in
                Button("") { model.page = .tab(t) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).opacity(0)
            }
        }
    }
}

// MARK: - Sidebar

private struct AppSidebar: View {
    @EnvironmentObject var store: Store
    @Binding var selection: AppPage
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding

    private var workspaces: [Workspace] { store.workspaces.filter { $0.matches(query) } }

    var body: some View {
        List(selection: Binding<AppPage?>(get: { selection }, set: { if let page = $0 { selection = page } })) {
            Section {
                ForEach(PanelTab.allCases) { t in
                    Label(t.title, systemImage: t.symbol)
                        .badge(badge(t))
                        .tag(AppPage.tab(t))
                }
            }
            Section("Workspaces") {
                ForEach(workspaces) { w in
                    WorkspaceSidebarRow(workspace: w).tag(AppPage.workspace(w.root))
                }
                if workspaces.isEmpty {
                    Text(store.workspaces.isEmpty ? "None running" : "None match")
                        .font(.system(size: UI.Size.body)).foregroundStyle(UI.textSecondary)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { SidebarSearch(query: $query, focused: searchFocused) }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }

    private func badge(_ t: PanelTab) -> Text? {
        switch t {
        case .overview: return nil
        case .agents: return store.sessions.isEmpty ? nil : Text("\(store.sessions.count)")
        case .servers:
            let n = Set(store.devListeners.map(\.pid)).count
            return n == 0 ? nil : Text("\(n)")
        case .system: return Text("\(Int((store.system.cpu * 100).rounded()))%")
        case .cleanup: return store.cleanupScanned && store.cleanupTotal > 0 ? Text(Fmt.bytes(store.cleanupTotal)) : nil
        }
    }
}

private struct WorkspaceSidebarRow: View {
    let workspace: Workspace
    var body: some View {
        HStack(spacing: 8) {
            Monogram(name: workspace.name, root: workspace.root, active: false, size: 18)
            Text(workspace.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if workspace.isWaiting || workspace.isBusy {
                StatusDot(active: !workspace.isWaiting && workspace.isBusy, waiting: workspace.isWaiting, size: 6)
                    .frame(width: 12, height: 12)
            } else if let port = workspace.ports.first {
                Text(verbatim: ":" + String(port)).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
            }
        }
        .help(Fmt.tilde(workspace.root))
        .accessibilityElement(children: .combine)
        .accessibilityValue(workspace.isWaiting ? "Needs you" : workspace.isBusy ? "Working" : "")
    }
}

/// The panel's filter field, at the head of the sidebar.
private struct SidebarSearch: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: UI.Size.body)).foregroundStyle(UI.textSecondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: UI.Size.emphasis))
                .focused(focused)
                .onExitCommand { query = "" }
            if query.isEmpty {
                Text("⌘K").font(.system(size: UI.Size.micro, weight: .medium, design: .rounded)).foregroundStyle(UI.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            } else {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(UI.textSecondary) }
                    .buttonStyle(PressStyle())
                    .help("Clear filter")
                    .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(SearchFieldSurface())
        .padding(.horizontal, 10)
        .padding(.top, 8).padding(.bottom, 10)
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 7) {
            BrandMarkView(size: 16)
            Text("Dashbar").font(.system(size: UI.Size.body, weight: .semibold))
            if BuildInfo.isLocal {
                Text("Local").font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            Spacer()
            Menu {
                SettingsLink { Text("Settings…") }
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
                Divider()
                Button("Rescan for clean-up") { store.scanCleanup() }
                Button("Refresh now") { store.refreshNow() }
                Divider()
                Button("Quit Dashbar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: UI.Size.emphasis))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(UI.textSecondary)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Detail

private struct AppDetail: View {
    @EnvironmentObject var store: Store
    let page: AppPage
    let query: String
    let select: (AppPage) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UI.gap) {
                if let notice = store.notice {
                    NoticeBanner(text: notice) { store.notice = nil }.padding(.bottom, 4)
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: maxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .id(page)   // each page opens scrolled to the top
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var maxWidth: CGFloat {
        switch page {
        case .tab(.overview), .tab(.agents), .workspace: return 1080
        case .tab: return 760
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            switch page {
            case .tab(let t):
                Text(t.title).font(.system(size: 20, weight: .semibold))
            case .workspace(let root):
                if let w = store.workspaces.first(where: { $0.root == root }) {
                    WorkspaceIdentity(workspace: w, usage: store.workspaceUsage[root])
                } else {
                    Text(URL(fileURLWithPath: root).lastPathComponent).font(.system(size: 20, weight: .semibold))
                }
            }
            Spacer(minLength: 12)
            LiveControls(buttons: false)
            HeaderButtons()
        }
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 14)
        .frame(maxWidth: maxWidth)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .tab(.overview): OverviewPage(query: query, select: select)
        case .tab(.agents): AgentsPage(query: query)
        case .tab(.servers): ServersCard(query: query, includeProjects: true)
        case .tab(.system): SystemPage(query: query)
        case .tab(.cleanup): CleanupCard(query: query)
        case .workspace(let root):
            if let w = store.workspaces.first(where: { $0.root == root }) {
                WorkspacePage(workspace: w)
            } else {
                GoneWorkspace(name: URL(fileURLWithPath: root).lastPathComponent) { select(.tab(.overview)) }
            }
        }
    }
}

/// Pause, refresh and pin as one group: a glass capsule on macOS 26 and later, like a toolbar's buttons there.
private struct HeaderButtons: View {
    var body: some View {
        HStack(spacing: 4) {
            LiveButtons()
            PinButton()
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .modifier(GlassCapsule())
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
        }
    }
}

private struct PinButton: View {
    @AppStorage(AppWindow.floatKey) private var floating = false
    var body: some View {
        IconButton(symbol: floating ? "pin.fill" : "pin", help: floating ? "Stop keeping on top" : "Keep on top of other windows") {
            floating.toggle()
            AppWindow.shared.applyLevel()
        }
    }
}

// MARK: - Pages

private struct OverviewPage: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared
    let query: String
    let select: (AppPage) -> Void

    var body: some View {
        let workspaces = store.workspaces.filter { $0.matches(query) }
        if let warning = store.claude.warning ?? store.codex.warning { NoticeBanner(text: warning, dismiss: nil) }
        TileRow { select(.tab($0)) }
        SectionTitle(text: "Workspaces", count: workspaces.count).padding(.top, 10)
        if workspaces.isEmpty {
            EmptyRow(text: store.workspaces.isEmpty
                     ? "No agents or dev servers running. Start Claude Code or a dev server and it shows up here."
                     : "No workspaces match “\(query)”")
                .padding(UI.cardPadding).surface()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: UI.gap, alignment: .top)], spacing: UI.gap) {
                ForEach(workspaces) { w in
                    WorkspaceCard(workspace: w, usage: store.workspaceUsage[w.root]) { select(.workspace(w.root)) }
                }
            }
        }
        if !store.otherAgents.isEmpty, query.isEmpty {
            AgentChips(items: store.otherAgents.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }).padding(.horizontal, 4)
        }
        if !store.looseServers.isEmpty { ServersCard(query: query).padding(.top, 10) }
        if settings.showWidgets, query.isEmpty, !store.claude.last24.isEmpty, store.claude.warning == nil { WidgetRow().padding(.top, 10) }
    }
}

private struct SectionTitle: View {
    let text: String
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: UI.Size.emphasis, weight: .semibold))
            if let count, count > 0 {
                Text("\(count)").font(.system(size: UI.Size.emphasis).monospacedDigit()).foregroundStyle(UI.textSecondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A workspace on the overview: who is working in it and what it costs. Opens its page.
private struct WorkspaceCard: View {
    let workspace: Workspace
    let usage: WorkspaceUsage?
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Monogram(name: workspace.name, root: workspace.root, active: workspace.isBusy, waiting: workspace.isWaiting, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.name).font(.system(size: UI.Size.emphasis, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        WorkspaceStatus(workspace: workspace)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: UI.Size.micro, weight: .semibold)).foregroundStyle(UI.textSecondary)
                }
                HStack(spacing: 14) {
                    figure("CPU", usage.map { UsageText.percent($0.cpu) + "%" })
                    figure("Memory", usage.map { Fmt.bytes($0.memory) })
                    figure("Energy", usage?.watts.map { UsageText.watts($0) + " W" })
                    Spacer(minLength: 0)
                    ForEach(workspace.ports.prefix(2), id: \.self) { port in
                        Text(verbatim: ":" + String(port))
                            .font(.system(size: UI.Size.caption, weight: .semibold, design: .rounded).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(UI.textInfo.opacity(0.12)))
                            .foregroundStyle(UI.textInfo)
                    }
                }
            }
            .padding(UI.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(selected: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("Show \(workspace.name)")
    }

    private func figure(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
            Text(value ?? "–").font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
    }
}

private struct AgentsPage: View {
    @EnvironmentObject var store: Store
    let query: String

    var body: some View {
        if let warning = store.claude.warning ?? store.codex.warning { NoticeBanner(text: warning, dismiss: nil) }
        // Two columns when there's room for the cards at their panel width or more, one otherwise.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UI.gap) {
                VStack(spacing: UI.gap) { left }.frame(minWidth: 400)
                VStack(spacing: UI.gap) { right }.frame(minWidth: 400)
            }
            VStack(spacing: UI.gap) { left; right }
        }
    }

    @ViewBuilder private var left: some View {
        PlanLimitsCard()
        WorkspacesCard(query: query)
    }

    @ViewBuilder private var right: some View {
        UsageCard(title: "Claude Code", icon: "asterisk", tint: UI.claude, summary: store.claude, loading: store.usageLoading)
        if store.codex.found {
            UsageCard(title: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: .teal, summary: store.codex, loading: false)
        }
    }
}

private struct GoneWorkspace: View {
    let name: String
    let back: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name) isn't running now").font(.system(size: UI.Size.emphasis, weight: .semibold))
            Text("Its agents have ended and its dev servers have stopped. It comes back here when either starts again.")
                .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            Button("Back to Overview", action: back)
                .buttonStyle(PressStyle())
                .font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textInfo)
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

// MARK: - Workspace page

/// The page header for a workspace: its icon, name, state and where it lives.
private struct WorkspaceIdentity: View {
    let workspace: Workspace
    let usage: WorkspaceUsage?

    var body: some View {
        HStack(spacing: 12) {
            Monogram(name: workspace.name, root: workspace.root, active: workspace.isBusy, waiting: workspace.isWaiting, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(workspace.name).font(.system(size: 20, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if !workspace.sessions.isEmpty { StatusPill(workspace: workspace).fixedSize() }
                }
                Text(subtitle).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// "~/Development/storefront-web · checkout-flow"
    private var subtitle: String {
        ([Fmt.tilde(workspace.root)] + [usage?.branch].compactMap { $0 }).joined(separator: " · ")
    }
}

/// One workspace on its own: what it costs right now and everything running in it.
private struct WorkspacePage: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared
    let workspace: Workspace

    var body: some View {
        let usage = store.workspaceUsage[workspace.root]
        let history = store.workspaceHistory[workspace.root] ?? WorkspaceHistory()
        WorkspaceActions(workspace: workspace).padding(.bottom, 6)
        HStack(alignment: .top, spacing: UI.gap) { metrics(usage, history) }
        HStack(alignment: .top, spacing: UI.gap) {
            if !workspace.servers.isEmpty {
                Card(title: "Dev servers", icon: "server.rack", count: Set(workspace.servers.map(\.pid)).count) {
                    VStack(spacing: 2) {
                        ForEach(byProcess(workspace.servers), id: \.first!.id) { group in
                            ServerRow(listener: group[0], inWorkspace: true, extraPorts: group.dropFirst().map(\.port))
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            if !workspace.sessions.isEmpty {
                Card(title: "Agents", icon: "sparkles", count: workspace.sessions.count) {
                    VStack(spacing: 0) {
                        ForEach(workspace.sessions) { SessionLine(session: $0, context: store.contexts[$0.id]) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // both cards take the taller one's height
        if let usage, !usage.processes.isEmpty {
            ProcessList(groups: usage.processes, shown: 10)
        }
        Text("Counts its agents, its dev servers, everything they started (MCP servers too) and anything else running inside this folder.")
            .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    @ViewBuilder private func metrics(_ usage: WorkspaceUsage?, _ history: WorkspaceHistory) -> some View {
        let measuring = history.cpu.count < 2
        let window = Fmt.minutes(max(1, Int((Double(history.cpu.count) * settings.refreshSeconds / 60).rounded())))
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            UsageTile(title: "Uptime", value: usage?.started.map { Fmt.ago($0, now: ctx.date) } ?? "–", unit: "",
                      values: [], style: .none,
                      caption: usage?.started.map { "Since " + Self.clock($0, now: ctx.date) } ?? "Not known",
                      help: "How long its oldest dev server or agent has been running.")
        }
        UsageTile(title: "CPU", value: measuring ? "–" : UsageText.percent(usage?.cpu ?? 0), unit: measuring ? "" : "%",
                  values: history.cpu,
                  caption: measuring ? "Measuring…" : "Peak \(UsageText.percent(history.cpu.max() ?? 0))% · \(window)",
                  help: "Share of your Mac's total CPU. Peak is the highest in the last \(window).")
        let (mem, memUnit) = Fmt.bytesSplit(usage?.memory ?? 0)
        let count = usage?.processes.reduce(0) { $0 + $1.count } ?? 0
        UsageTile(title: "Memory", value: usage == nil ? "–" : mem, unit: usage == nil ? "" : memUnit,
                  values: history.memory, style: .line,
                  caption: count == 1 ? "1 process" : "\(count) processes",
                  help: "Memory its processes are holding, added up.")
        let watts = usage?.watts
        UsageTile(title: "Energy", value: watts.map(UsageText.watts) ?? "–", unit: watts == nil ? "" : "W",
                  values: history.watts,
                  caption: watts.map { w in
                      let avg = history.watts.reduce(0, +) / Double(max(history.watts.count, 1))
                      return WorkspaceUsage.energyWord(w) + " · avg " + UsageText.watts(avg) + " W"
                  } ?? (measuring ? "Measuring…" : "Not reported"),
                  help: "Power its processes are drawing, as macOS estimates it. Average is over the last \(window).")
    }

    /// "10:14", or "Thu 10:14" when it started on another day.
    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func byProcess(_ ls: [Listener]) -> [[Listener]] {
        var order: [Int32] = []
        var groups: [Int32: [Listener]] = [:]
        for l in ls {
            if groups[l.pid] == nil { order.append(l.pid) }
            groups[l.pid, default: []].append(l)
        }
        return order.compactMap { groups[$0]?.sorted { $0.port < $1.port } }
    }
}

/// Open the project in the editor, a terminal, Finder or the browser, with words, since the window has room for them.
private struct WorkspaceActions: View {
    let workspace: Workspace
    var body: some View {
        GlassGroup {
        HStack(spacing: 6) {
            if let editor = Launcher.editor {
                ActionButton(symbol: "chevron.left.forwardslash.chevron.right", title: "Open in \(editor.name)") {
                    Launcher.open(workspace.root, in: editor)
                }
            }
            if let term = Launcher.terminal {
                ActionButton(symbol: "terminal", title: term.name) { Launcher.open(workspace.root, in: term) }
            }
            ActionButton(symbol: "folder", title: "Finder") { Launcher.reveal(workspace.root) }
            ForEach(workspace.ports.prefix(2), id: \.self) { port in
                ActionButton(symbol: "safari", title: "localhost:" + String(port)) { Launcher.browse(port: port) }
            }
            ActionButton(symbol: "doc.on.doc", title: "Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.root, forType: .string)
            }
            Spacer(minLength: 0)
        }
        }
    }
}

private struct ActionButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        if #available(macOS 26.0, *) {
            // The system's glass button: its own hover and press response, in a capsule.
            Button(action: action) {
                Label(title, systemImage: symbol).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        } else {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .font(.system(size: UI.Size.body, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                        .fill(Color.primary.opacity(hover ? UI.buttonHover : UI.rowHover)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(UI.textSecondary))
            .onHover { hover = $0 }
        }
    }
}

/// How the usage figures are written.
enum UsageText {
    /// Whole percent, or one decimal under 1% so light use doesn't read as nothing.
    static func percent(_ share: Double) -> String {
        let p = share * 100
        if p > 0, p < 1 { return String(format: "%.1f", p) }
        return "\(Int(p.rounded()))"
    }

    /// "3.1", "0.35", "<0.01": an idle workspace still draws a little, and "0.00" would read as no reading.
    static func watts(_ w: Double) -> String {
        w < 0.01 ? "<0.01" : String(format: w < 1 ? "%.2f" : w < 10 ? "%.1f" : "%.0f", w)
    }
}
