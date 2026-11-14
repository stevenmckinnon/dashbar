import SwiftUI
import Charts
import AppKit
import ServiceManagement

let debugConfirm = ProcessInfo.processInfo.environment["DASHBAR_DEBUG_CONFIRM"] != nil

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
    var scrolls = true
    @State private var query = ""
    @AppStorage("panelTab") private var tab: PanelTab = debugConfirm ? .cleanup : .overview
    /// Snapshots pass the tab to render directly.
    var forcedTab: PanelTab? = nil
    @FocusState private var searchFocused: Bool
    @Namespace private var focusScope

    /// One height for every tab. Letting the panel follow each tab's content made the menu bar window
    /// lag behind on tab switches and reopen at a stale size, leaving unpainted space around the panel.
    private var panelHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(420, min(680, visible - 160))
    }

    var body: some View {
        VStack(spacing: 0) {
            Header()
            TabBar(selection: Binding(get: { forcedTab ?? tab }, set: { tab = $0 }))
            if scrolls {
                ScrollView {
                    cards
                        .frame(maxWidth: .infinity, alignment: .top)
                        .id(forcedTab ?? tab)   // each tab opens scrolled to the top
                }
                .frame(height: panelHeight)
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
        // With Keyboard navigation on, a waiting prompt on Overview is where focus starts (see `PermissionPrompt`).
        .focusScope(focusScope)
        .environment(\.promptFocusScope, (forcedTab ?? tab) == .overview ? focusScope : nil)
        .background {
            // Invisible carriers for the shortcuts: kept out of the Tab order and away from VoiceOver, which would
            // otherwise land on six empty buttons. The tabs and the filter field say their shortcut themselves.
            Group {
                Button("") { searchFocused = true }.keyboardShortcut("k").opacity(0)
                // ⌘1…⌘5 switch tabs.
                ForEach(Array(PanelTab.allCases.enumerated()), id: \.offset) { i, t in
                    Button("") { tab = t }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).opacity(0)
                }
            }
            .focusable(false)
            .accessibilityHidden(true)
        }
        // A workspace's page lives in the Dashbar window, which takes over from the panel.
        .environment(\.openWorkspace) { root in
            let panel = NSApp.keyWindow
            AppWindow.shared.show(store: store, page: .workspace(root))
            panel?.orderOut(nil)
        }
        // The window's see-through material turns muddy grey over a white page; a mostly opaque base keeps the panel legible on any backdrop.
        .background { if scrolls { Color(nsColor: .windowBackgroundColor).opacity(0.86) } }
        .background { if scrolls { WindowVisibilityReader { store.setPanelVisible($0, surface: "panel") } } } // not in offline snapshots
        .onAppear { store.setPanelVisible(true, surface: "panel") }
        .onDisappear { store.setPanelVisible(false, surface: "panel") }
    }

    private var cards: some View {
        VStack(spacing: UI.gap) {
            if let notice = store.notice { NoticeBanner(text: notice) { store.notice = nil }.transition(.opacity) }
            if let warning = store.formatWarning, tab == .overview || tab == .agents {
                NoticeBanner(text: warning, dismiss: nil)
            }
            switch forcedTab ?? tab {
            case .overview:
                TileRow { tab = $0 }
                // Prompts the Now card won't show, so every one waiting is in view without opening a row.
                let nowCard = settings.showNow && query.isEmpty ? store.featured : nil
                PermissionPromptList(requests: store.permissionRequests.filter { r in
                    !(nowCard?.sessions.contains { $0.id == r.sessionId } ?? false)
                })
                if let featured = nowCard { NowCard(workspace: featured) }
                WorkspacesCard(query: query, clearQuery: { query = "" },
                               excluding: settings.showNow && query.isEmpty ? store.featured?.id : nil)
                if settings.showServers || !query.isEmpty { ServersCard(query: query) }
                // Live state first, history last: usage can't be acted on, so it sits below what can.
                if settings.showWidgets, query.isEmpty, !store.claude.last24.isEmpty, store.claude.warning == nil { WidgetRow() }
            case .agents:
                PlanLimitsCard()
                // Every waiting prompt answerable here too: under its workspace, or on its own if its session isn't listed.
                PermissionPromptList(requests: store.unmatchedPermissionRequests)
                WorkspacesCard(query: query, clearQuery: { query = "" }, showsPrompts: true)
                UsageCard(title: "Claude Code", icon: "asterisk", tint: UI.claude, summary: store.claude, loading: store.usageLoading,
                          accounts: store.claudeAccountUsage)
                if store.codex.found {
                    UsageCard(title: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: .teal, summary: store.codex, loading: false,
                              accounts: store.codexAccountUsage)
                }
                if store.google.found {
                    UsageCard(title: GoogleUsage.title(store.googleSources), icon: UI.googleSymbol, tint: UI.google, summary: store.google,
                              loading: false, costNote: GoogleUsage.costNote(store.googleSources))
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

/// Opens a workspace's detail page; set by the dashboard for the cards inside it.
struct OpenWorkspaceKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

/// Set by the Dashbar window: it has room, so row actions stay visible instead of waiting for a hover.
struct InWindowKey: EnvironmentKey {
    static let defaultValue = false
}

/// Set by the panel on Overview: the focus scope in which the oldest waiting prompt takes the default focus.
struct PromptFocusScopeKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var promptFocusScope: Namespace.ID? {
        get { self[PromptFocusScopeKey.self] }
        set { self[PromptFocusScopeKey.self] = newValue }
    }
    var openWorkspace: ((String) -> Void)? {
        get { self[OpenWorkspaceKey.self] }
        set { self[OpenWorkspaceKey.self] = newValue }
    }
    var inWindow: Bool {
        get { self[InWindowKey.self] }
        set { self[InWindowKey.self] = newValue }
    }
}

struct TabBar: View {
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
        // Kept solid: on the panel's flat background a glass track only adds a faint rim.
        .background(RoundedRectangle(cornerRadius: UI.innerRadius + 3, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, UI.gutter)
        .padding(.bottom, 8)
    }
}

/// Reports whether the panel's window is actually on screen, using AppKit occlusion state.
/// More reliable than onAppear/onDisappear, which a menu bar window doesn't always send on reopen.
struct WindowVisibilityReader: NSViewRepresentable {
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

/// "1 needs you", "2 working", pause and refresh: shared by the panel's header and the window's.
struct LiveControls: View {
    @EnvironmentObject var store: Store
    /// The window draws pause and refresh itself, grouped with its pin.
    var buttons = true
    var body: some View {
        HStack(spacing: 7) {
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
            if buttons { LiveButtons() }
        }
    }
}

/// Pause or resume live updates, and refresh now.
struct LiveButtons: View {
    @EnvironmentObject var store: Store
    var body: some View {
        IconButton(symbol: store.paused ? "play.fill" : "pause.fill",
                   help: store.paused ? "Resume live updates" : "Pause live updates") {
            store.paused.toggle()
            if !store.paused { store.refreshNow() }
        }
        IconButton(symbol: "arrow.clockwise", help: "Refresh now") { store.refreshNow() }
    }
}

struct Header: View {
    @EnvironmentObject var store: Store
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
            LiveControls()
            IconButton(symbol: "arrow.up.forward.app",
                       help: GlobalShortcut.isEnabled ? "Open the Dashbar window (\(GlobalShortcut.display))" : "Open the Dashbar window") {
                let panel = NSApp.keyWindow   // the menu bar panel this button was clicked in
                AppWindow.shared.show(store: store)
                panel?.orderOut(nil)          // the window takes over from it
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct BottomBar: View {
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
            .modifier(SearchFieldSurface())

            Menu {
                SettingsButton { Text("Settings…") }
                    .keyboardShortcut(",")
                Divider()
                Toggle("Notify when an agent finishes", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { NotificationPermission.shared.request() } }
                Divider()
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                    Divider()
                }
                Button("Rescan for clean-up") { store.scanCleanup() }
                Button("Refresh now") { store.refreshNow() }
                Divider()
                Button("Welcome…") { OnboardingWindow.shared.show(store: store) }
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
