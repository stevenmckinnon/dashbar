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
        // Plan limits and usage. Still `.agents` underneath, so saved tabs, DASHBAR_TAB=agents and ⌘2 keep working.
        case .agents: return "Usage"
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

    /// Usage has nothing the filter narrows (its workspace list lives on Overview), so the field isn't offered there.
    var hasFilter: Bool { self != .agents }
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

    /// The panel fits the current tab: its scroll area is as tall as the cards, up to a cap that follows the screen,
    /// past which the tab scrolls (`PanelSizing`, applied by `PanelScrollFit` and `PanelWindowFitter`). The first try
    /// (a `ScrollView` with only a `maxHeight`) lagged behind tab switches and reopened at a stale size with unpainted
    /// space, because MenuBarExtra grows its window to fit but never shrinks it. Now the height comes out of the same
    /// layout pass that lays out the cards (no measuring into state and laying out again), and the window is set to
    /// it in that pass, without animation. It changes only when the cards change size: a tab switch, a row coming or
    /// going, never a collector tick that leaves them as they were. Hidden, the window still follows, so it reopens
    /// at the right size.
    private var scrollCap: CGFloat { PanelSizing.maxScroll(screenHeight: NSScreen.main?.visibleFrame.height ?? 900) }

    var body: some View {
        VStack(spacing: 0) {
            Header()
            TabBar(selection: Binding(get: { forcedTab ?? tab }, set: { tab = $0 }))
            if scrolls {
                PanelScrollFit(cap: scrollCap) {
                    ScrollView {
                        cards
                            .frame(maxWidth: .infinity, alignment: .top)
                            .id(forcedTab ?? tab)   // each tab opens scrolled to the top
                    }
                }
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
            BottomBar(query: $query, prompt: (forcedTab ?? tab).filterPrompt, focused: $searchFocused,
                      showsFilter: (forcedTab ?? tab).hasFilter)
        }
        .frame(width: UI.panelWidth)
        // On a touch Mac: row actions always shown, 30-point hit areas. Off, nothing changes.
        .environment(\.touchFriendly, TouchDisplay.present)
        // With Keyboard navigation on, a waiting prompt on Overview is where focus starts (see `PermissionPrompt`).
        .focusScope(focusScope)
        .environment(\.promptFocusScope, (forcedTab ?? tab) == .overview ? focusScope : nil)
        .background {
            // Invisible carriers for the shortcuts: kept out of the Tab order and away from VoiceOver, which would
            // otherwise land on six empty buttons. The tabs and the filter field say their shortcut themselves.
            Group {
                // On Usage, which has no filter, ⌘K goes to Overview's workspaces filter.
                Button("") {
                    if !tab.hasFilter { tab = .overview }
                    searchFocused = true
                }.keyboardShortcut("k").opacity(0)
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
        .background { if scrolls { PanelWindowFitter() } }
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
                // In order: does anything need me, what is working, will I run out. No summary tiles: the header's pills
                // already say what is working or waiting, and the tabs above lead to the rest.
                // Every prompt the Now card won't show, so each one waiting is in view without opening a row.
                let nowCard = settings.showNow && query.isEmpty ? store.nowWorkspace : nil
                PermissionPromptList(requests: store.permissionRequests.filter { r in
                    !(nowCard?.sessions.contains { $0.id == r.sessionId } ?? false)
                })
                if let nowCard { NowCard(workspace: nowCard) }
                WorkspacesCard(query: query, clearQuery: { query = "" }, excluding: nowCard?.id)
                if (settings.showServers && OverviewRules.showsServersCard(looseServers: store.looseServers)) || !query.isEmpty {
                    ServersCard(query: query)
                }
                if query.isEmpty {
                    PlanStripCard { tab = .agents }
                    if OverviewRules.showsCleanupLine(scanned: store.cleanupScanned, total: store.cleanupTotal) {
                        CleanupLine(total: store.cleanupTotal) { tab = .cleanup }
                    }
                }
            case .agents:
                // Usage: one card per tool, the one closest to running out first. The workspaces live on Overview,
                // which also shows every waiting permission prompt.
                UsageTab()
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

/// The panel's scroll area height. Pure, so the clamp and rounding are tested.
enum PanelSizing {
    /// Short tabs (an empty Servers list) still get a panel that reads as one, not a strip.
    static let minScroll: CGFloat = 120
    /// The cap: the old fixed height, which leaves room for the menu bar, the header and the bottom bar.
    static func maxScroll(screenHeight: CGFloat) -> CGFloat { max(420, min(680, screenHeight - 160)) }

    /// Whole points, rounded up so the last line is never cut by a fraction.
    static func quantise(_ height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 0 }
        return (height - 0.01).rounded(.up)
    }

    /// The content's height in whole points, at least `minScroll`, at most `cap`.
    static func scrollHeight(content: CGFloat, cap: CGFloat) -> CGFloat {
        min(cap, max(minScroll, quantise(content)))
    }
}

/// Sizes the panel's scroll view to its content's height, clamped by `PanelSizing`, inside one layout pass: it asks
/// the scroll view for its ideal height (the cards' full height) and takes the clamped value as its own.
struct PanelScrollFit: Layout {
    var cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroll = subviews.first else { return .zero }
        let ideal = scroll.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: PanelSizing.scrollHeight(content: ideal.height, cap: cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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

/// Keeps the menu bar window as tall as the panel. MenuBarExtra grows its window when the panel gets taller but never
/// shrinks it: a shorter tab would sit centred in the old frame with unpainted space above and below. This view fills
/// the panel's background, so its own height is the panel's, and it sets the window to that height (top edge pinned
/// under the menu bar, no animation) in the same AppKit layout pass, and again whenever the window comes on screen.
struct PanelWindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> FitterView { FitterView() }
    func updateNSView(_ view: FitterView, context: Context) {}

    final class FitterView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.fit() } }
            fit()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fit()
        }

        private func fit() {
            guard let window, bounds.height > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let height = bounds.height.rounded()
            guard abs(content.height - height) >= 1 else { return }
            let target = NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
            window.setFrame(window.frameRect(forContentRect: target), display: true, animate: false)
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
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
                .help("An agent has stopped to ask for permission or an answer")
            }
            if !store.paused, store.busyCount > 0 {
                HStack(spacing: 5) {
                    StatusDot(active: true, size: 6)
                    Text("\(store.busyCount) working")
                }
                .font(.system(size: UI.Size.caption, weight: .medium))
                .foregroundStyle(UI.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(UI.working.opacity(0.12)))
                .fixedSize()   // with two status pills, the title gives way rather than a pill wrapping
            }
            if buttons { LiveButtons() }
        }
    }
}

/// Pause or resume live updates, and refresh now.
struct LiveButtons: View {
    @EnvironmentObject var store: Store
    @Environment(\.touchFriendly) private var touch
    var body: some View {
        // On a touch Mac each button's 30-point hit area already holds the gap, so they sit edge to edge.
        HStack(spacing: touch ? 0 : 7) {
            IconButton(symbol: store.paused ? "play.fill" : "pause.fill",
                       help: store.paused ? "Resume live updates" : "Pause live updates") {
                store.paused.toggle()
                if !store.paused { store.refreshNow() }
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { store.refreshNow() }
        }
    }
}

struct Header: View {
    @EnvironmentObject var store: Store
    @Environment(\.touchFriendly) private var touch
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
            .padding(.leading, touch ? -7 : 0)   // as in LiveButtons: its hit area holds the gap
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
    var showsFilter = true
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
                        .touchTarget()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .modifier(SearchFieldSurface())
            // On a tab with nothing to filter the field steps aside but keeps its room, so the bar (and the panel) stay
            // the same height on every tab.
            .opacity(showsFilter ? 1 : 0)
            .disabled(!showsFilter)
            .accessibilityHidden(!showsFilter)

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
            .touchTarget()
            .foregroundStyle(UI.textSecondary)
        }
        .padding(.horizontal, UI.gutter)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}
