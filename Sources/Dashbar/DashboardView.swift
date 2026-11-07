import SwiftUI
import Charts
import AppKit
import ServiceManagement

private let debugConfirm = ProcessInfo.processInfo.environment["DASHBAR_DEBUG_CONFIRM"] != nil

// MARK: - Design tokens

private enum UI {
    static let panelWidth: CGFloat = 420
    static let gutter: CGFloat = 12
    static let gap: CGFloat = 8
    static let cardPadding: CGFloat = 12
    /// Inner surfaces (rows, buttons, mini stats). Cards are concentric: inner + padding.
    static let innerRadius: CGFloat = 6
    static let cardRadius: CGFloat = innerRadius + cardPadding
    /// Search field sits `gutter` inside the panel edge.
    static let fieldRadius: CGFloat = 8
    static let rowHover = 0.06
    static let buttonHover = 0.10
    /// Three equal columns across the panel.
    static let column: CGFloat = (panelWidth - 2 * gutter - 2 * gap) / 3
    /// Two equal columns across the panel.
    static let half: CGFloat = (panelWidth - 2 * gutter - gap) / 2

    /// Claude brand only (icons, the "now" bar). Never used for status.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let accent = Color(red: 0.98, green: 0.55, blue: 0.24)

    // Text roles. Each light/dark pair measures ≥ 4.5:1 on the card surface.
    static let textSecondary = Color(light: .init(white: 0, alpha: 0.58), dark: .init(white: 1, alpha: 0.55)) // 5.3 / 5.4
    static let textSuccess = Color(light: .init(hex: 0x1A7F37), dark: .init(hex: 0x3FD06A))   // 5.1 / 7.1 — "working"
    static let textInfo = Color(light: .init(hex: 0x0B5CD5), dark: .init(hex: 0x80BBFF))      // 5.0 / 5.2 — ports, context OK
    static let textDanger = Color(light: .init(hex: 0xC4320A), dark: .init(hex: 0xFF6B5E))    // 5.5 / 5.1 — context nearly full, errors
    static let textAttention = Color(light: .init(hex: 0x8A5C00), dark: .init(hex: 0xE3B341)) // 5.2 / 7.4 — waiting for you
    /// Fills and dots for "waiting for you": amber, kept apart from Claude's coral and the problem red.
    static let attention = Color(light: .init(hex: 0xBF8700), dark: .init(hex: 0xE3B341))

    /// Type scale: six sizes, each with one job.
    enum Size {
        static let micro: CGFloat = 10    // axis labels, overlines, key caps
        static let caption: CGFloat = 11  // metadata, footnotes, badges
        static let body: CGFloat = 12     // row titles, card titles
        static let emphasis: CGFloat = 13 // workspace names, search
        static let title: CGFloat = 14    // panel title, Now card name
        static let numeral: CGFloat = 22  // tile and widget figures
    }
}

extension Color {
    /// A colour that follows the appearance it is rendered in.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The panel's pages. Overview is what you glance at; the rest is detail, one tab each.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview, agents, servers, system, cleanup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .agents: return "Agents"
        case .servers: return "Servers"
        case .system: return "System"
        case .cleanup: return "Clean-up"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .agents: return "sparkles"
        case .servers: return "server.rack"
        case .system: return "cpu"
        case .cleanup: return "shippingbox"
        }
    }

    var filterPrompt: String {
        switch self {
        case .overview, .agents: return "Filter workspaces…"
        case .servers: return "Filter by name or port…"
        case .system: return "Filter apps…"
        case .cleanup: return "Filter folders…"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scrolls = true
    /// The detached window: same width, but its height follows the window.
    var popout = false
    @State private var query = ""
    @AppStorage("panelTab") private var tab: PanelTab = debugConfirm ? .cleanup : .overview
    /// Snapshots pass the tab to render directly.
    var forcedTab: PanelTab? = nil
    @FocusState private var searchFocused: Bool

    /// One height for every tab. Letting the panel follow each tab's content made the menu bar window
    /// lag behind on tab switches and reopen at a stale size, leaving unpainted space around the panel.
    private var panelHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(420, min(680, visible - 160))
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(popout: popout)
            TabBar(selection: Binding(get: { forcedTab ?? tab }, set: { tab = $0 }))
            if scrolls {
                ScrollView {
                    cards
                        .frame(maxWidth: .infinity, alignment: .top)
                        .id(forcedTab ?? tab)   // each tab opens scrolled to the top
                }
                .frame(height: popout ? nil : panelHeight)
                .frame(maxHeight: popout ? .infinity : nil)
                .mask {
                    // Content fades out as it scrolls under the filter bar.
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    }
                }
            } else {
                cards
            }
            BottomBar(query: $query, prompt: tab.filterPrompt, focused: $searchFocused)
        }
        .frame(width: UI.panelWidth)
        .frame(maxHeight: popout ? .infinity : nil, alignment: .top)
        .ignoresSafeArea(.container, edges: popout ? .top : [])   // popout content runs under its transparent title bar
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("k").opacity(0)
            // ⌘1…⌘5 switch tabs.
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.offset) { i, t in
                Button("") { tab = t }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).opacity(0)
            }
        }
        // The window's see-through material turns muddy grey over a white page; a mostly opaque base keeps the panel legible on any backdrop.
        .background { if scrolls { Color(nsColor: .windowBackgroundColor).opacity(0.86) } }
        .background { if popout { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() } }
        .background { if scrolls { WindowVisibilityReader { store.setPanelVisible($0, surface: surface) } } } // not in offline snapshots
        .onAppear { store.setPanelVisible(true, surface: surface) }
        .onDisappear { store.setPanelVisible(false, surface: surface) }
    }

    private var surface: String { popout ? "popout" : "panel" }

    /// The panel's width, for the popout window to match.
    static let width = UI.panelWidth

    private var cards: some View {
        VStack(spacing: UI.gap) {
            if let notice = store.notice { NoticeBanner(text: notice) { store.notice = nil }.transition(.opacity) }
            if let warning = store.claude.warning ?? store.codex.warning, tab == .overview || tab == .agents {
                NoticeBanner(text: warning, dismiss: nil)
            }
            switch forcedTab ?? tab {
            case .overview:
                TileRow { tab = $0 }
                if settings.showNow, query.isEmpty, let featured = store.featured { NowCard(workspace: featured) }
                WorkspacesCard(query: query, clearQuery: { query = "" },
                               excluding: settings.showNow && query.isEmpty ? store.featured?.id : nil)
                if settings.showServers || !query.isEmpty { ServersCard(query: query) }
                // Live state first, history last: usage can't be acted on, so it sits below what can.
                if settings.showWidgets, query.isEmpty, !store.claude.last24.isEmpty, store.claude.warning == nil { WidgetRow() }
            case .agents:
                PlanLimitsCard()
                WorkspacesCard(query: query, clearQuery: { query = "" })
                UsageCard(title: "Claude Code", icon: "asterisk", tint: UI.claude, summary: store.claude, loading: store.usageLoading)
                if store.codex.found {
                    UsageCard(title: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: .teal, summary: store.codex, loading: false)
                }
            case .servers:
                ServersCard(query: query, includeProjects: true)
            case .system:
                SystemPage(query: query)
            case .cleanup:
                CleanupCard(query: query)
            }
        }
        .padding(.horizontal, UI.gutter)
        .padding(.top, 2)
        .padding(.bottom, 20)
    }
}

private struct TabBar: View {
    @Binding var selection: PanelTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { t in
                let selected = t == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = t }
                } label: {
                    // Words rather than icons: five labelled tabs fit the panel, five icon+label pairs don't.
                    Text(t.title).font(.system(size: UI.Size.caption, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : UI.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("\(t.title) (⌘\((PanelTab.allCases.firstIndex(of: t) ?? 0) + 1))")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius + 3, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, UI.gutter)
        .padding(.bottom, 8)
    }
}

/// Reports whether the panel's window is actually on screen, using AppKit occlusion state.
/// More reliable than onAppear/onDisappear, which a menu bar window doesn't always send on reopen.
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] note in
                guard let w = note.object as? NSWindow else { return }
                self?.onChange(w.occlusionState.contains(.visible))
            }
            onChange(window.occlusionState.contains(.visible))
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

// MARK: - Chrome

private struct Header: View {
    @EnvironmentObject var store: Store
    var popout = false
    @AppStorage(Popout.floatKey) private var floating = false
    var body: some View {
        HStack(spacing: 7) {
            BrandMarkView(size: 18)
            Text("Dashbar").font(.system(size: UI.Size.title, weight: .semibold)).lineLimit(1)
            if BuildInfo.isLocal {
                Text("Local").font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .help("A local build, not the installed release")
            }
            Spacer()
            if store.paused {
                Text("Paused").font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
            }
            if !store.paused, store.waitingCount > 0 {
                HStack(spacing: 5) {
                    StatusDot(active: false, waiting: true, size: 6)
                    Text("\(store.waitingCount) \(store.waitingCount == 1 ? "needs" : "need") you")
                }
                .font(.system(size: UI.Size.caption, weight: .medium))
                .foregroundStyle(UI.textAttention)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(UI.attention.opacity(0.14)))
                .fixedSize()
                .help("Claude has stopped to ask for permission or an answer")
            }
            if !store.paused, store.busyCount > 0 {
                HStack(spacing: 5) {
                    StatusDot(active: true, size: 6)
                    Text("\(store.busyCount) working")
                }
                .font(.system(size: UI.Size.caption, weight: .medium))
                .foregroundStyle(UI.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.12)))
                .fixedSize()   // with two status pills, the title gives way rather than a pill wrapping
            }
            IconButton(symbol: store.paused ? "play.fill" : "pause.fill",
                       help: store.paused ? "Resume live updates" : "Pause live updates") {
                store.paused.toggle()
                if !store.paused { store.refreshNow() }
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { store.refreshNow() }
            if popout {
                IconButton(symbol: floating ? "pin.fill" : "pin", help: floating ? "Stop keeping on top" : "Keep on top of other windows") {
                    floating.toggle()
                    Popout.shared.applyLevel()
                }
            } else {
                IconButton(symbol: "arrow.up.forward.app",
                           help: GlobalShortcut.isEnabled ? "Open in a window (\(GlobalShortcut.display))" : "Open in a window") {
                    let panel = NSApp.keyWindow   // the menu bar panel this button was clicked in
                    Popout.shared.show(store: store)
                    panel?.orderOut(nil)          // the popout replaces it
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, popout ? 30 : 12)   // the popout's content runs under its title bar; clear the window buttons
        .padding(.bottom, 10)
    }
}

private struct BottomBar: View {
    @EnvironmentObject var store: Store
    @Binding var query: String
    var prompt: String
    var focused: FocusState<Bool>.Binding
    @AppStorage(Notifier.defaultsKey) private var notify = true
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: UI.Size.body)).foregroundStyle(UI.textSecondary)
                TextField(prompt, text: $query)
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
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: UI.fieldRadius, style: .continuous).fill(Color.primary.opacity(0.06)))

            Menu {
                SettingsLink { Text("Settings…") }
                    .keyboardShortcut(",")
                Divider()
                Toggle("Notify when an agent finishes", isOn: $notify)
                Divider()
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                    Divider()
                }
                Button("Rescan for clean-up") { store.scanCleanup() }
                Button("Refresh now") { store.refreshNow() }
                Divider()
                Button("Quit Dashbar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape").font(.system(size: UI.Size.emphasis))
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(UI.textSecondary)
        }
        .padding(.horizontal, UI.gutter)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - Tiles

private struct TileRow: View {
    @EnvironmentObject var store: Store
    let open: (PanelTab) -> Void

    var body: some View {
        HStack(spacing: UI.gap) {
            Button { open(.agents) } label: {
                Tile(title: "Agents", badge: store.busyCount > 0 ? "\(store.busyCount) working" : nil,
                     value: "\(store.sessions.count)", unit: nil, selected: false) {
                    HourBars(points: Array(store.claude.last24.suffix(12)), tint: UI.accent, height: 16)
                }
            }
            .buttonStyle(PressStyle())
            .help("Show agents (⌘2)")
            Button { open(.servers) } label: {
                Tile(title: "Servers", badge: store.devListeners.isEmpty ? nil : "Live",
                     value: "\(Set(store.devListeners.map(\.pid)).count)", unit: nil, selected: false) {
                    Text(store.serverMemory > 0 ? Fmt.bytes(store.serverMemory) : "—")
                        .font(.system(size: UI.Size.caption, weight: .medium).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        .lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(PressStyle())
            .help("Show servers (⌘3)")
            Button { open(.cleanup) } label: {
                let (v, u) = store.cleanupScanned ? Fmt.bytesSplit(store.cleanupTotal) : ("…", "")
                Tile(title: "Clean-up", badge: nil, value: v, unit: u, selected: false) {
                    CleanupMeter(items: store.cleanup)
                }
            }
            .buttonStyle(PressStyle())
            .help("Show clean-up (⌘5)")
            .accessibilityLabel(store.cleanupScanned ? "Clean-up, \(Fmt.bytes(store.cleanupTotal)) reclaimable" : "Clean-up, measuring")
        }
    }
}

private struct Tile<Accessory: View>: View {
    let title: String
    let badge: String?
    let value: String
    let unit: String?
    let selected: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 2)
                if let badge { Text(badge).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSuccess).lineLimit(1) }
            }
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).fixedSize()
                if let unit, !unit.isEmpty {
                    Text(unit).font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary).fixedSize()
                }
                Spacer(minLength: 6)
                accessory.frame(maxWidth: 44, maxHeight: 16, alignment: .bottomTrailing)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(width: UI.column, height: 66, alignment: .topLeading)
        .surface(selected: selected)
        .contentShape(Rectangle())
    }
}

/// Hourly activity: a 1pt baseline, with bars only where something happened.
private struct HourBars: View {
    let points: [HourPoint]
    let tint: Color
    var height: CGFloat = 16
    var barWidth: CGFloat = 2.5

    var body: some View {
        let maxV = Double(points.map(\.messages).max() ?? 0)
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.primary.opacity(0.14)).frame(height: 1)
            HStack(alignment: .bottom, spacing: barWidth * 0.6) {
                ForEach(points) { p in
                    let h = maxV > 0 ? height * Double(p.messages) / maxV : 0
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(p.isNow ? tint : Color.secondary.opacity(0.55))
                        .frame(width: barWidth, height: p.messages == 0 ? 0 : max(3, h))
                }
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Activity, last \(points.count) hours")
        .accessibilityValue("\(points.last?.messages ?? 0) messages this hour, \(points.reduce(0) { $0 + $1.messages }) in total")
    }
}

/// Reclaimable space by kind. Categories under 8% are dropped rather than drawn as dots.
private struct CleanupMeter: View {
    let items: [CleanupItem]
    var body: some View {
        let total = Double(items.reduce(0) { $0 + $1.size })
        let groups = Dictionary(grouping: items, by: \.kind)
            .map { ($0.key, Double($0.value.reduce(0) { $0 + $1.size })) }
            .filter { total > 0 && $0.1 / total >= 0.08 }
            .sorted { $0.1 > $1.1 }.prefix(3)
        let shown = groups.reduce(0) { $0 + $1.1 }
        let colors: [Color] = [.blue, .purple, .orange]
        // Shrinks to whatever room the value leaves, so a wide figure never pushes it out of the tile.
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                    Capsule().fill(colors[i].opacity(0.8))
                        .frame(width: max(2, (geo.size.width - 2 * CGFloat(groups.count - 1)) * g.1 / max(shown, 1)), height: 3)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(minWidth: 10, maxWidth: 32)
        .frame(height: 16, alignment: .bottom)
        .help(legend(groups.map { ($0.0, $0.1) }, colored: true))
        .accessibilityElement()
        .accessibilityLabel(legend(groups.map { ($0.0, $0.1) }, colored: false))
    }

    private func legend(_ groups: [(String, Double)], colored: Bool) -> String {
        let names = ["blue", "purple", "orange"]
        return groups.enumerated().map { i, g in
            (colored ? names[i] + ": " : "") + g.0 + " " + Fmt.bytes(UInt64(g.1))
        }.joined(separator: "\n")
    }
}

// MARK: - Now: the workspace that matters right now

private struct NowCard: View {
    @EnvironmentObject var store: Store
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Monogram(name: workspace.name, root: workspace.root, active: workspace.isBusy, waiting: workspace.isWaiting, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name).font(.system(size: UI.Size.title, weight: .semibold)).lineLimit(1)
                        .help("\(workspace.name) — \(Fmt.tilde(workspace.root))")
                    Text(subtitle).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                StatusPill(workspace: workspace)
            }
            VStack(spacing: 6) {
                ForEach(workspace.sessions.prefix(2)) { s in
                    NowSessionLine(session: s, context: store.contexts[s.id],
                                   extra: s.id == workspace.sessions.first?.id ? max(0, workspace.sessions.count - 2) : 0)
                }
            }
            QuickActions(workspace: workspace)
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    private var subtitle: String {
        let servers = workspace.servers.prefix(2).map { l -> String in
            let name = l.hint.split(separator: " ").first.map(String.init) ?? l.command
            return "\(name) :" + String(l.port)
        }
        var parts = servers
        if workspace.memory > 0 { parts.append(Fmt.bytes(workspace.memory)) }
        return parts.isEmpty ? Fmt.tilde(workspace.root) : parts.joined(separator: " · ")
    }
}

private struct StatusPill: View {
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

private struct NowSessionLine: View {
    @EnvironmentObject var store: Store
    let session: LiveSession
    let context: ContextInfo?
    let extra: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "asterisk")
                .font(.system(size: UI.Size.caption, weight: .semibold))
                .foregroundStyle(UI.claude)
                .accessibilityHidden(true)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(UI.claude.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1)
                    .help(session.name)
                Text("Claude Code · \(session.surface)"
                     + (store.spawned[session.pid]?.portsText.map { " · " + $0 } ?? "")
                     + (extra > 0 ? " · \(extra) more" : ""))
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
    }
}

// MARK: - Widgets: context, last 5 hours, today

private struct WidgetRow: View {
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

private struct WeekCompare: View {
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

private struct Widget<Content: View>: View {
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
        .frame(width: UI.half, height: 118, alignment: .topLeading)
        .surface()
    }
}

private struct DayBars: View {
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

private struct BigNumber: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1)
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1).truncationMode(.tail)
    }
}

// MARK: - Workspaces

private struct WorkspacesCard: View {
    @EnvironmentObject var store: Store
    let query: String
    var clearQuery: () -> Void = {}
    /// The workspace already shown in the Now card.
    var excluding: String?

    var body: some View {
        let list = store.workspaces.filter { $0.id != excluding && $0.matches(query) }
        if !(list.isEmpty && excluding != nil && store.otherAgents.isEmpty) {
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
                        WorkspaceRow(workspace: w, autoExpand: !query.isEmpty)
                    }
                }
            }
            if !store.otherAgents.isEmpty && query.isEmpty {
                AgentChips(items: store.otherAgents.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name })
                    .padding(.top, 4)
            }
        }
    }
}

private struct WorkspaceRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workspace: Workspace
    var autoExpand = false
    @State private var expanded: Bool?
    @State private var hover = false

    private var isExpanded: Bool { expanded ?? autoExpand }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) { header }
                .buttonStyle(PressStyle())
                .help("\(workspace.name) — \(Fmt.tilde(workspace.root))")
            if isExpanded {
                detail.transition(reduceMotion
                    ? .opacity
                    : .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity))
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
                        Text(Fmt.bytes(workspace.memory)).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: UI.Size.micro, weight: .semibold))
                .foregroundStyle(UI.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
            .fill(Color.primary.opacity(hover ? UI.rowHover : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var portsLabel: String {
        let p = workspace.ports
        let shown = p.prefix(2).map { ":" + String($0) }.joined(separator: " ")
        return p.count > 2 ? shown + " +\(p.count - 2)" : shown
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(workspace.sessions) { SessionLine(session: $0, context: store.contexts[$0.id]) }
            ForEach(workspace.servers) { ServerRow(listener: $0, inWorkspace: true) }
            QuickActions(workspace: workspace).padding(.top, 4)
        }
        .padding(.leading, 42)
        .padding(.bottom, 6)
    }
}

private struct WorkspaceStatus: View {
    let workspace: Workspace
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(text(now: ctx.date))
                .font(.system(size: UI.Size.caption).monospacedDigit())
                .foregroundStyle(workspace.isWaiting ? AnyShapeStyle(UI.textAttention)
                                 : workspace.isBusy ? AnyShapeStyle(UI.textSuccess) : AnyShapeStyle(UI.textSecondary))
                .lineLimit(1)
        }
    }

    private func text(now: Date) -> String {
        let s = workspace.sessions
        let more = s.count > 1 ? " · \(s.count - 1) more" : ""
        if let waiting = s.first(where: \.isWaiting) {
            return "\(waiting.waitingSentence) · \(Fmt.ago(waiting.since, now: now))" + more
        }
        if let busy = s.first(where: \.isBusy) {
            return "Claude is working · \(Fmt.ago(busy.since, now: now))" + more
        }
        if let idle = s.first {
            return "Claude idle for \(Fmt.ago(idle.since, now: now))" + more
        }
        return workspace.servers.map(\.hint).uniqued().prefix(2).joined(separator: " · ")
    }
}

private struct SessionLine: View {
    @EnvironmentObject var store: Store
    let session: LiveSession
    let context: ContextInfo?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                StatusDot(active: session.isBusy, waiting: session.isWaiting, size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1)
                        .help("\(session.name)\n\(Fmt.tilde(session.cwd))")
                    Text("\(session.isWaiting ? session.waitingLabel : session.isBusy ? "Working" : session.status.capitalized) \(Fmt.ago(session.since, now: ctx.date)) · \(session.surface)"
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
    }
}

/// "22%" over "context", so the number explains itself.
private struct ContextLabel: View {
    let context: ContextInfo
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(Int((context.fraction * 100).rounded()))%")
                .font(.system(size: UI.Size.caption, weight: .semibold).monospacedDigit())
                .foregroundStyle(ContextRing.color(context.fraction))
            Text("context")
                .font(.system(size: UI.Size.micro))
                .foregroundStyle(UI.textSecondary)
        }
        .fixedSize()
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

private struct ContextRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.5
    /// Two states only: fine, or nearly full. Orange stays reserved for the Claude brand.
    static func color(_ f: Double) -> Color { f < 0.85 ? UI.textInfo : UI.textDanger }

    var body: some View {
        ZStack {
            Circle().stroke(Self.color(fraction).opacity(0.15), lineWidth: lineWidth)
            Circle().trim(from: 0, to: fraction)
                .stroke(Self.color(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fraction)
    }
}

private struct ContextBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(ContextRing.color(fraction).opacity(0.15))
                Capsule().fill(ContextRing.color(fraction)).frame(width: max(4, g.size.width * fraction))
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fraction)
    }
}

private struct QuickActions: View {
    let workspace: Workspace
    var body: some View {
        HStack(spacing: 6) {
            if let editor = Launcher.editor {
                ActionTile(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in \(editor.name)") {
                    Launcher.open(workspace.root, in: editor)
                }
            }
            if let term = Launcher.terminal {
                ActionTile(symbol: "terminal", help: "Open in \(term.name)") { Launcher.open(workspace.root, in: term) }
            }
            ActionTile(symbol: "folder", help: "Reveal in Finder") { Launcher.reveal(workspace.root) }
            if let port = workspace.ports.first {
                ActionTile(symbol: "safari", help: "Open localhost:" + String(port)) { Launcher.browse(port: port) }
            } else {
                ActionTile(symbol: "doc.on.doc", help: "Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspace.root, forType: .string)
                }
            }
        }
    }
}

private struct ActionTile: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: UI.Size.body, weight: .medium))
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

// MARK: - Servers not tied to a repo

private struct ServersCard: View {
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

private struct ServerRow: View {
    @EnvironmentObject var store: Store
    let listener: Listener
    var compact = false
    var inWorkspace = false
    var extraPorts: [Int] = []
    @State private var hover = false
    @State private var confirmStop = false
    @FocusState private var focusedAction: Int?

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

    /// Actions show on hover, and also whenever one of them holds keyboard focus.
    private var revealed: Bool { hover || confirmStop || focusedAction != nil }

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
            ZStack(alignment: .trailing) {
                if listener.memory > 0 && !compact {
                    Text(Fmt.bytes(listener.memory)).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        .opacity(revealed ? 0 : 1)
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

// MARK: - Clean up

private struct CleanupCard: View {
    @EnvironmentObject var store: Store
    var query = ""
    @State private var showAll = false

    private var matching: [CleanupItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.cleanup : store.cleanup.filter { $0.project.lowercased().contains(q) || $0.kind.lowercased().contains(q) }
    }

    var body: some View {
        Card(title: "Clean-up", icon: "shippingbox", tint: .orange, count: nil,
             trailing: store.cleanupScanned ? Fmt.bytes(store.cleanupTotal) : nil) {
            if !store.cleanupScanned {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring cache folders…").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                }
            } else if store.cleanup.isEmpty {
                EmptyRow(text: "Nothing worth cleaning")
            } else if matching.isEmpty {
                EmptyRow(text: "No folders match “\(query)”")
            } else {
                let items = showAll || !query.isEmpty ? matching : Array(matching.prefix(8))
                VStack(spacing: 1) { ForEach(items) { CleanupRow(item: $0) } }
                HStack {
                    Text("Moves to the Trash. Reinstall deps to get them back.")
                        .font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
                    Spacer()
                    if query.isEmpty && store.cleanup.count > 8 {
                        Button(showAll ? "Show less" : "Show all \(store.cleanup.count)") { showAll.toggle() }
                            .buttonStyle(PressStyle()).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textInfo)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct CleanupRow: View {
    @EnvironmentObject var store: Store
    let item: CleanupItem
    @State private var hover = false
    @State private var confirm = debugConfirm
    @FocusState private var focusedAction: Int?

    private var revealed: Bool { hover || confirm || focusedAction != nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.project).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(item.path)
                Text(item.kind).font(.system(size: UI.Size.micro, design: .monospaced)).foregroundStyle(UI.textSecondary)
            }
            Spacer(minLength: 6)
            if confirm {
                ConfirmButton(title: "Move to Trash") { store.trash(item); confirm = false }
                    .focused($focusedAction, equals: 1)
                IconButton(symbol: "xmark", help: "Cancel") { confirm = false }
            } else {
                Text(Fmt.bytes(item.size)).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                IconButton(symbol: "trash", help: "Move \(item.kind) in \(item.project) to the Trash") { confirm = true }
                    .focused($focusedAction, equals: 0)
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
            .fill(Color.primary.opacity(hover ? UI.rowHover : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0; if !$0 && focusedAction == nil { confirm = false } }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Divider()
            Button("Move to Trash…", role: .destructive) { confirm = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move to Trash") { confirm = true }
    }

    private var icon: String {
        switch item.kind {
        case "node_modules": return "shippingbox"
        case "DerivedData", ".build": return "hammer"
        default: return "archivebox"
        }
    }
}

// MARK: - Usage

private struct UsageCard: View {
    let title: String
    var icon: String? = nil
    let tint: Color
    let summary: UsageSummary
    let loading: Bool
    var limits: [RateLimit] = []
    @State private var period = UsagePeriod.today

    var body: some View {
        let usage = summary.period(period)
        Card(title: title, icon: icon, tint: tint, count: nil, trailing: "\(period.short) \(Fmt.tokens(usage.totals.total))") {
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Scanning transcripts…").font(.caption).foregroundStyle(UI.textSecondary) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !summary.found {
                EmptyRow(text: "No transcripts found")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Period", selection: $period) {
                        ForEach(UsagePeriod.allCases) { Text($0.short).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        MiniStat(label: "In", value: usage.totals.input)
                        MiniStat(label: "Out", value: usage.totals.output)
                        MiniStat(label: "Cache read", value: usage.totals.cacheRead)
                        MiniStat(label: "Cache write", value: usage.totals.cacheWrite)
                    }
                    HStack {
                        Text(period == .today ? "By hour, last 24 hours" : "By day, last \(period.days) days")
                            .font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
                        if period == .today {
                            Text("· \(summary.sessions24) sessions").font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        }
                        Spacer()
                    }
                    if period == .today { hourly } else { daily(Array(summary.last14.suffix(period.days))) }
                    if !usage.projects.isEmpty {
                        HStack(alignment: .top, spacing: 14) {
                            RankList(title: "Projects", items: usage.projects, tint: tint)
                            RankList(title: "Models", items: usage.models, tint: tint)
                        }
                    }
                    if !limits.isEmpty {
                        VStack(spacing: 6) { ForEach(limits) { LimitBar(limit: $0, tint: tint) } }
                    }
                }
            }
        }
    }

    private var hourly: some View {
        let peak = Double(summary.last24.map(\.tokens).max() ?? 0)
        return Chart(summary.last24) { p in
            BarMark(x: .value("Hour", p.date, unit: .hour),
                    yStart: .value("Base", 0),
                    yEnd: .value("Tokens", max(Double(p.tokens), peak * 0.035)))
                .foregroundStyle(p.tokens == 0 ? Color.primary.opacity(0.1) : (p.isNow ? tint : tint.opacity(0.45)))
                .cornerRadius(2)
        }
        .chartYScale(domain: 0...max(peak, 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated))).font(.system(size: UI.Size.micro))
            }
        }
        .frame(height: 64)
    }

    private func daily(_ points: [DayPoint]) -> some View {
        Chart(points) { p in
            BarMark(x: .value("Day", p.date, unit: .day), y: .value("Tokens", p.tokens))
                .foregroundStyle(p.isToday ? tint : tint.opacity(0.4))
                .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)).font(.system(size: UI.Size.micro)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: points.count > 7 ? 3 : 1)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: UI.Size.micro))
            }
        }
        .frame(height: 78)
    }
}

private struct MiniStat: View {
    let label: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
            Text(Fmt.tokens(value)).font(.system(size: UI.Size.body, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct RankList: View {
    let title: String
    let items: [Ranked]
    let tint: Color
    var body: some View {
        let maxV = Double(items.first?.value ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).textCase(.uppercase).tracking(0.5).font(.system(size: UI.Size.micro, weight: .semibold)).foregroundStyle(UI.textSecondary)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name).font(.system(size: UI.Size.caption)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.tokens(item.value)).font(.system(size: UI.Size.micro).monospacedDigit()).foregroundStyle(UI.textSecondary)
                    }
                    GeometryReader { g in
                        Capsule().fill(tint.opacity(0.6))
                            .frame(width: max(3, g.size.width * Double(item.value) / max(maxV, 1)))
                    }
                    .frame(height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LimitBar: View {
    let limit: RateLimit
    let tint: Color
    var body: some View {
        let used = min(max(limit.usedPercent, 0), 100)
        let expected = limit.expectedPercent()
        let pace = limit.pace()
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.system(size: UI.Size.caption, weight: .medium))
                if let r = limit.resetsAt {
                    Text("resets \(r.formatted(.relative(presentation: .named)))")
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                }
                Spacer()
                Text("\(Int(used.rounded()))% used")
                    .font(.system(size: UI.Size.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(used >= 90 ? UI.textDanger : Color.primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.16)).frame(height: 6)
                    Capsule().fill(used >= 90 ? UI.textDanger : tint).frame(width: max(4, g.size.width * used / 100), height: 6)
                    // Where usage would be if spread evenly over the window.
                    if let expected {
                        Capsule().fill(Color.primary.opacity(0.55))
                            .frame(width: 2, height: 10)
                            .offset(x: min(g.size.width - 2, max(0, g.size.width * expected / 100 - 1)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            if let pace {
                Text(Self.text(pace))
                    .font(.system(size: UI.Size.caption))
                    .foregroundStyle(Self.isWarning(pace) ? UI.textDanger : UI.textSecondary)
            }
        }
        .help(expected.map { "The mark shows where an even pace would be by now: \(Int($0.rounded()))% used." } ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.label) limit, \(Int(used.rounded())) percent used" + (pace.map { ". " + Self.text($0) } ?? ""))
    }

    static func isWarning(_ pace: RateLimit.Pace) -> Bool {
        switch pace {
        case .runsOut, .usedUp: return true
        case .under, .onPace: return false
        }
    }

    static func text(_ pace: RateLimit.Pace) -> String {
        switch pace {
        case .under: return "Well under pace"
        case .onPace: return "On pace to last until it resets"
        case .usedUp: return "Used up until it resets"
        case .runsOut(let date):
            let when = Calendar.current.isDateInToday(date)
                ? "at " + date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "At this rate, runs out \(when)"
        }
    }
}

// MARK: - Plan limits (Agents tab)

private struct PlanLimitsCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Card(title: "Plan limits", icon: "gauge.with.needle", tint: .green, count: nil) {
            VStack(alignment: .leading, spacing: 12) {
                claude
                if store.codex.found { codex }
            }
        }
    }

    @ViewBuilder private var claude: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: UI.Size.caption, weight: .bold)).foregroundStyle(UI.claude)
                    .accessibilityHidden(true)
                Text(["Claude", store.claudePlan?.plan].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: UI.Size.body, weight: .medium))
                if settings.claudeLimits {
                    Text("Experimental").font(.system(size: UI.Size.micro, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(UI.textSecondary)
                }
                Spacer()
                if settings.claudeLimits, store.claudePlanLoading { ProgressView().controlSize(.mini) }
            }
            if !settings.claudeLimits {
                HStack(alignment: .firstTextBaseline) {
                    Text("Claude doesn't save plan limits on your Mac. An experimental setting can read them through Claude Code's sign-in.")
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsLink { Text("Settings…") }
                        .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
                }
            } else if let problem = store.claudePlan?.problem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
                    Text(problem).font(.system(size: UI.Size.caption)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if store.claudeSigningIn {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Refreshing…").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary) }
                    } else if store.claudePlan?.needsSignIn == true {
                        Button("Refresh") { store.refreshClaudeSignIn() }
                            .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
                            .help("Runs Claude Code once in the background, which refreshes its sign-in. Uses a few tokens.")
                    } else if let retryAt = store.claudePlanRetryAt, retryAt > Date() {
                        // Waiting out a rate limit: a Retry button would only ask too soon again.
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(retryAt > ctx.date ? "Retrying in \(Fmt.duration(retryAt.timeIntervalSince(ctx.date)))" : "Retrying…")
                                .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        }
                        .fixedSize()
                    } else {
                        Button("Retry") { store.refreshClaudePlan(force: true) }
                            .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
                    }
                }
            } else if let limits = store.claudePlan?.limits, !limits.isEmpty {
                ForEach(limits) { LimitBar(limit: $0, tint: UI.claude) }
                if let note = store.claudePlan?.staleNote {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "clock").accessibilityHidden(true)
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                }
            } else {
                Text("Loading plan limits…").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            }
        }
    }

    @ViewBuilder private var codex: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: UI.Size.caption, weight: .bold))
                    .foregroundStyle(.teal).accessibilityHidden(true)
                Text("Codex").font(.system(size: UI.Size.body, weight: .medium))
            }
            if store.codexLimits.isEmpty {
                Text("Codex hasn't reported limits yet. They appear after your next Codex session.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            } else {
                ForEach(store.codexLimits) { LimitBar(limit: $0, tint: .teal) }
            }
        }
    }
}

// MARK: - System tab

private struct SystemPage: View {
    @EnvironmentObject var store: Store
    let query: String

    var body: some View {
        let s = store.system
        let h = store.history
        VStack(spacing: UI.gap) {
            // CPU
            MetricCard(title: "CPU", icon: "cpu", tint: .blue, trailing: "up \(Fmt.ago(Date().addingTimeInterval(-s.uptime)))",
                       caption: "\(s.cores) cores · \(s.chip)",
                       value: "\(Int((s.cpu * 100).rounded()))", unit: "%") {
                StatRow([("User", "\(Int((s.cpuUser * 100).rounded()))%"),
                         ("System", "\(Int((s.cpuSystem * 100).rounded()))%"),
                         ("Load", String(format: "%.2f", s.load[0]))])
                BarHistory(values: h.cpu, tint: .blue, maxValue: 1, label: "CPU, last \(h.cpu.count) samples")
            }
            // Memory
            MetricCard(title: "Memory", icon: "memorychip", tint: .purple, trailing: nil,
                       caption: "In use of \(Fmt.bytes(s.memTotal))",
                       value: Fmt.bytesSplit(s.memUsed).0, unit: Fmt.bytesSplit(s.memUsed).1,
                       badge: PressureBadge(pressure: s.pressure)) {
                StatRow([("App", Fmt.bytes(s.memApp)), ("Wired", Fmt.bytes(s.memWired)),
                         ("Compressed", Fmt.bytes(s.memCompressed))] + (s.swapUsed > 0 ? [("Swap", Fmt.bytes(s.swapUsed))] : []))
                BarHistory(values: h.memory, tint: .purple, maxValue: 1, label: "Memory, last \(h.memory.count) samples")
            }
            // Network
            MetricCard(title: "Network", icon: "network", tint: .teal, trailing: nil,
                       caption: "Download", value: Fmt.rate(s.netDown).split(separator: " ").first.map(String.init) ?? "0",
                       unit: Fmt.rate(s.netDown).split(separator: " ").dropFirst().joined(separator: " ")) {
                StatRow([("Upload", Fmt.rate(s.netUp)),
                         ("Peak download", Fmt.rate(h.down.max() ?? 0))])
                BarHistory(values: h.down, tint: .teal, maxValue: nil, label: "Download, last \(h.down.count) samples")
            }
            // GPU
            if let gpu = s.gpu {
                MetricCard(title: "GPU", icon: "square.stack.3d.up.fill", tint: .pink, trailing: nil,
                           caption: s.chip, value: "\(Int((gpu * 100).rounded()))", unit: "%") {
                    StatRow([("Average", "\(Int(((h.gpu.reduce(0, +) / Double(max(h.gpu.count, 1))) * 100).rounded()))%"),
                             ("Peak", "\(Int(((h.gpu.max() ?? 0) * 100).rounded()))%")])
                    BarHistory(values: h.gpu, tint: .pink, maxValue: 1, label: "GPU, last \(h.gpu.count) samples")
                }
            }
            // Disk and battery
            HStack(spacing: UI.gap) {
                if s.diskTotal > 0 {
                    MiniMetric(title: "Disk", icon: "internaldrive", tint: .orange,
                               value: Fmt.bytesSplit(s.diskFree).0, unit: Fmt.bytesSplit(s.diskFree).1 + " free",
                               fraction: 1 - Double(s.diskFree) / Double(s.diskTotal), detail: "of \(Fmt.bytes(s.diskTotal))")
                }
                if let b = s.battery {
                    MiniMetric(title: s.charging ? "Battery · charging" : "Battery", icon: s.charging ? "battery.100.bolt" : "battery.75",
                               tint: b < 20 && !s.charging ? UI.textDanger : .green,
                               value: "\(b)", unit: "%", fraction: Double(b) / 100,
                               detail: s.batteryMinutes.map { Fmt.minutes($0) + (s.charging ? " to full" : " left") }
                                   ?? (s.onAC ? "On power" : "Estimating…"))
                }
            }
            BusiestApps(apps: store.topApps, query: query)
        }
    }
}

private struct MetricCard<Badge: View, Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let trailing: String?
    let caption: String
    let value: String
    let unit: String
    var badge: Badge
    @ViewBuilder var content: Content

    init(title: String, icon: String, tint: Color, trailing: String?, caption: String, value: String, unit: String,
         badge: Badge = EmptyView(), @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.tint = tint; self.trailing = trailing
        self.caption = caption; self.value = value; self.unit = unit; self.badge = badge; self.content = content()
    }

    var body: some View {
        Card(title: title, icon: icon, tint: tint, count: nil, trailing: trailing) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).lineLimit(1)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(value).font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(unit).font(.system(size: UI.Size.emphasis, weight: .semibold)).foregroundStyle(UI.textSecondary)
                        Spacer()
                        badge
                    }
                }
                content
            }
        }
    }
}

/// Memory pressure with an icon and a word, so it never relies on colour alone.
private struct PressureBadge: View {
    let pressure: MemoryPressure
    var body: some View {
        let (symbol, color): (String, Color) = {
            switch pressure {
            case .normal: return ("checkmark", UI.textSuccess)
            case .warning: return ("exclamationmark", .orange)
            case .critical: return ("exclamationmark.triangle.fill", UI.textDanger)
            }
        }()
        Label(pressure.label, systemImage: symbol)
            .font(.system(size: UI.Size.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .help("Memory pressure: how hard macOS is working to find free memory. Normal is fine even when usage looks high.")
    }
}

private struct StatRow: View {
    let items: [(String, String)]
    init(_ items: [(String, String)]) { self.items = items }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    Text(item.1).font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit()).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Recent samples as small vertical bars, newest on the right; empty slots show as faint stubs.
private struct BarHistory: View {
    let values: [Double]
    let tint: Color
    /// Fixed scale (e.g. 1 for percentages); nil scales to the largest value shown.
    let maxValue: Double?
    let label: String
    var height: CGFloat = 32

    var body: some View {
        let n = SystemHistory.length
        let peak = maxValue ?? max(values.max() ?? 0, 1)
        GeometryReader { g in
            let spacing: CGFloat = 2
            let w = max(1, (g.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<n, id: \.self) { i in
                    let index = i - (n - values.count)
                    let v = index >= 0 ? values[index] : 0
                    RoundedRectangle(cornerRadius: min(1.5, w / 2))
                        .fill(index >= 0 ? tint.opacity(i == n - 1 ? 1 : 0.7) : tint.opacity(0.14))
                        .frame(width: w, height: index >= 0 ? max(2, height * min(v / peak, 1)) : 2)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .frame(height: height)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(tint.opacity(0.08)))
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

private struct MiniMetric: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    let fraction: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconChip(symbol: icon, tint: tint)
                Text(title).font(.system(size: UI.Size.body, weight: .semibold)).lineLimit(1)
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit())
                Text(unit).font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary).lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.16))
                    Capsule().fill(tint).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 5)
            Text(detail).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1)
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

private struct BusiestApps: View {
    let apps: [AppUsage]
    let query: String

    var body: some View {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) }
        let peak = max(shown.first?.cpu ?? 0, 0.01)
        Card(title: "Busiest right now", icon: "flame", tint: .orange, count: nil, trailing: "share of all CPU") {
            if apps.isEmpty {
                EmptyRow(text: "Measuring… this fills in after a few seconds.")
            } else if shown.isEmpty {
                EmptyRow(text: "No busy apps match “\(query)”")
            } else {
                VStack(spacing: 6) {
                    ForEach(shown) { app in
                        HStack(spacing: 9) {
                            AppIcon(path: app.appPath)
                            Text(app.name).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.blue.opacity(0.14))
                                    Capsule().fill(Color.blue).frame(width: max(3, g.size.width * app.cpu / peak))
                                }
                            }
                            .frame(width: 70, height: 5)
                            Text(String(format: "%.1f%%", app.cpu * 100))
                                .font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(format: "%@, %.1f percent of CPU", app.name, app.cpu * 100))
                    }
                }
            }
        }
    }
}

/// The app's own icon when it lives in a bundle, a terminal glyph for command-line tools.
private struct AppIcon: View {
    let path: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let path {
                Image(nsImage: Self.icon(for: path)).resizable()
            } else {
                Image(systemName: "terminal").font(.system(size: UI.Size.caption, weight: .semibold))
                    .foregroundStyle(UI.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

// MARK: - Building blocks

/// Card and tile surface. Depth comes from fill (and a soft shadow in light mode), not a border;
/// only the selected state draws an outline.
private struct Surface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var selected = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
        let light = scheme == .light
        content
            .background(shape.fill(light ? Color.white.opacity(selected ? 0.95 : 0.62)
                                         : Color.white.opacity(selected ? 0.10 : 0.055)))
            .overlay { if selected { shape.strokeBorder(Color.primary.opacity(0.14)) } }
            .shadow(color: .black.opacity(light ? 0.05 : 0), radius: 1, y: 0.5)
            .shadow(color: .black.opacity(light ? (selected ? 0.08 : 0.04) : 0), radius: 8, y: 3)
    }
}

extension View {
    fileprivate func surface(selected: Bool = false) -> some View { modifier(Surface(selected: selected)) }
}

/// Presses scale to 0.96 over 150ms; under Reduce Motion they dim instead. Disabled buttons never react.
private struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(pressed && reduceMotion ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: pressed)
    }
}

private struct Card<Content: View>: View {
    let title: String
    var icon: String? = nil
    var tint: Color = .secondary
    var count: Int?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let icon { IconChip(symbol: icon, tint: tint) }
                Text(title).font(.system(size: UI.Size.body, weight: .semibold))
                if let count, count > 0 { Text("\(count)").font(.system(size: UI.Size.body).monospacedDigit()).foregroundStyle(UI.textSecondary) }
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                }
            }
            content
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// The symbol leading a card's title. Plain, in secondary ink; only Claude's asterisk and Codex's brackets
/// keep their colour, because there it names the agent.
private struct IconChip: View {
    let symbol: String
    let tint: Color
    private var namesAnAgent: Bool { symbol == "asterisk" || symbol.hasPrefix("chevron.left.forwardslash") }
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: UI.Size.body, weight: .semibold))
            .foregroundStyle(namesAnAgent ? tint : UI.textSecondary)
            // Flush with the card's content edge, so it lines up with the icons and text below it. A fixed
            // width keeps every card's title starting at the same place whatever the symbol's width.
            .frame(width: 16, height: 22, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A project's tile: its own icon when one is found in the folder, otherwise its first letter on a quiet
/// neutral tile. Colour is left for state, so the only thing that lights up is a working agent's dot.
private struct Monogram: View {
    let name: String
    var root: String? = nil
    let active: Bool
    /// An agent here is waiting for you: the dot turns amber.
    var waiting = false
    var size: CGFloat = 28
    @State private var icon: NSImage?

    var body: some View {
        let dot = size * 0.3
        let radius = size * 0.26
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).scaledToFill()
                        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.09))
                        .overlay(Text(String(name.first.map { String($0).uppercased() } ?? "?"))
                            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(UI.textSecondary))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            if active || waiting {
                // Punch a ring out of the tile so the dot reads cleanly on any surface.
                Circle().frame(width: dot + 3, height: dot + 3).offset(x: 2.5, y: 2.5).blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .overlay(alignment: .bottomTrailing) {
            if active || waiting {
                Circle().fill(waiting ? UI.attention : Color.green).frame(width: dot, height: dot).offset(x: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: root) {
            guard let root else { return }
            if let hit = ProjectIcon.cached(for: root) { icon = hit; return }
            icon = await Task.detached(priority: .utility) { ProjectIcon.find(in: root) }.value
        }
    }
}

private struct StatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    /// Waiting for you: a steady amber dot. Working pulses green; waiting holds still until someone acts.
    var waiting = false
    var size: CGFloat = 7
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                if reduceMotion {
                    // Static halo: same cue, no motion.
                    Circle().fill(Color.green.opacity(0.25)).frame(width: size * 1.8, height: size * 1.8)
                } else {
                    // Scoped animation: only scale and opacity loop, so the halo can never drift with
                    // layout (the bug with a plain repeatForever), and it renders without re-laying out
                    // the panel each frame (the cost of a TimelineView clock).
                    Circle().fill(Color.green.opacity(0.35))
                        .frame(width: size * 2, height: size * 2)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { content in
                            content
                                .scaleEffect(pulse ? 1 : 0.4)
                                .opacity(pulse ? 0 : 1)
                        }
                }
            }
            if waiting {
                Circle().fill(UI.attention.opacity(0.25)).frame(width: size * 1.8, height: size * 1.8)
            }
            Circle().fill(waiting ? UI.attention : active ? Color.green : Color.secondary.opacity(0.5)).frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .accessibilityHidden(true)
        .onAppear { pulse = true }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: UI.Size.body, weight: .medium))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hover ? UI.buttonHover : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(UI.textSecondary)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Inline confirmation for a destructive action: a tinted pill in the danger colour,
/// matching the panel's own buttons rather than a stock AppKit push button.
private struct ConfirmButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: UI.Size.caption, weight: .semibold))
                .foregroundStyle(UI.textDanger)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                    .fill(UI.textDanger.opacity(hover ? 0.2 : 0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .fixedSize()
    }
}

private struct NoticeBanner: View {
    let text: String
    let dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
            Text(text).font(.system(size: UI.Size.caption)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let dismiss { IconButton(symbol: "xmark", help: "Dismiss message", action: dismiss) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .accessibilityElement(children: .contain)
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentChips: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 5) {
            Text("Also running").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text(item).font(.system(size: UI.Size.caption))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
