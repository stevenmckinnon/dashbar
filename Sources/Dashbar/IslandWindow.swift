import SwiftUI
import AppKit
import Combine

// MARK: - Dashbar Island: the window

/// What the island's view shows, owned by the controller.
@MainActor
final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .hidden
    @Published var placement = IslandPlacement(style: .floating, anchorX: 0, topY: 0)
    var openSession: (LiveSession) -> Void = { _ in }
    var openDashbar: () -> Void = {}
    var expand: () -> Void = {}
}

/// A borderless panel that never takes focus from the app you're in, sits above the menu bar on every Space (and
/// beside full-screen apps), and has no shadow, so on the notch it reads as part of the hardware.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)   // above the menu bar, below its menus
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        title = "Dashbar Island"
    }
    override var canBecomeKey: Bool { true }   // so the permission buttons take a click without activating Dashbar
    override var canBecomeMain: Bool { false }
}

/// Takes the first click (the panel is never key beforehand) and reports the pointer coming and going, even while
/// another app is active, which SwiftUI's hover alone doesn't promise.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onPointer: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onPointer?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onPointer?(false) }
}

/// Runs the island: listens to the store, decides what to show, places the panel against the notch and resizes it to
/// the island so everything around it stays clickable. Nothing runs on a timer: work happens when the store changes,
/// the pointer moves on or off the island, the screens change, or a banner's one-shot deadline arrives.
@MainActor
final class IslandController {
    static let shared = IslandController()

    private let model = IslandModel()
    private var presenter = IslandPresenter()
    private var settings = IslandSettings.Values.read()
    private weak var store: Store?
    private var panel: IslandPanel?
    private var host: IslandHostingView<AnyView>?
    private var measurer: NSHostingController<AnyView>?
    private var subscriptions = Set<AnyCancellable>()
    private var deadlineWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    /// Snapshot runs pin the island in one mode: no deadlines, no pointer.
    private var pinned = false

    static let animation: TimeInterval = 0.45

    func start(store: Store) {
        guard self.store == nil else { return }
        self.store = store
        model.openSession = { [weak self] s in self?.open(s) }
        model.openDashbar = { [weak self] in
            guard let self, let store = self.store else { return }
            self.presenter.closeList()
            AppWindow.shared.show(store: store)
            self.update()
        }
        model.expand = { [weak self] in self?.hoverWork?.cancel(); self?.presenter.openList(); self?.update() }

        store.$sessions.combineLatest(store.$permissionRequests)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)
        store.islandEvents
            .sink { [weak self] event in self?.post(event) }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update(relayout: true) }
            .store(in: &subscriptions)
        // Another notch app may come or go: look again when apps launch or quit (while the island is showing).
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.update(relayout: true) }
                }
                .store(in: &subscriptions)
        }
        update(relayout: true)
    }

    /// For `--snapshot x --demo --island <state> --onscreen`: the real panel, held in one mode.
    func showPinned(store: Store, mode: IslandMode) {
        pinned = true
        settings.enabled = true
        self.store = store
        model.mode = mode
        layout(animated: false)
    }

    var panelWindowNumber: Int { panel?.windowNumber ?? 0 }

    /// For `--snapshot x --demo --island live --onscreen`: the real controller on demo data, on whatever the saved
    /// settings say, with an agent finishing a second in, so the open, the auto-collapse and the resizing can be watched.
    func startDemo(store: Store) {
        demo = true
        settings = IslandSettings.Values(enabled: true, position: settings.position)
        start(store: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            store.islandEvents.send(IslandEvent(kind: .finished(after: 12 * 60), sessionID: "s3"))
        }
    }
    private var demo = false

    private func settingsChanged() {
        guard !demo else { return }
        let new = IslandSettings.Values.read()
        guard new != settings else { return }
        let moved = new.position != settings.position
        settings = new
        if !new.enabled { presenter = IslandPresenter() }
        update(relayout: moved)
    }

    private func post(_ event: IslandEvent) {
        guard settings.enabled, !pinned else { return }
        let banner = IslandBanner(kind: event.kind, sessionID: event.sessionID, shownAt: Date())
        if presenter.post(banner, settings: settings, now: Date()) { update() }
    }

    private func open(_ session: LiveSession) {
        presenter.dismiss()
        presenter.closeList()
        update()
        HostApp.open(HostApp.info(for: session)?.bundle, root: session.root)
    }

    /// Recomputes the mode from the store and the presenter, then re-places the panel if anything changed.
    private func update(relayout: Bool = false) {
        guard !pinned, let store else { return }
        guard settings.enabled else {
            if panel != nil { teardown() }
            return
        }
        presenter.expire(now: Date())
        presenter.reconcile(sessions: store.sessions, permissionRequests: store.permissionRequests)
        let status = IslandStatus.of(sessions: store.sessions, permissionRequests: store.permissionRequests)
        let mode = presenter.mode(status: status)
        scheduleDeadline()
        guard mode != model.mode || relayout else { return }
        model.mode = mode
        layout(animated: true)
    }

    private func scheduleDeadline() {
        deadlineWork?.cancel()
        deadlineWork = nil
        guard let deadline = presenter.deadline() else { return }
        let work = DispatchWorkItem { [weak self] in self?.update() }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, deadline.timeIntervalSinceNow), execute: work)
    }

    private func pointer(_ inside: Bool) {
        guard !pinned else { return }
        presenter.pointer(inside: inside, now: Date())
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if inside { self.presenter.openList() } else { self.presenter.closeList() }
            self.update()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? IslandPresenter.hoverIntent : IslandPresenter.listGrace), execute: work)
        update()
    }

    // MARK: Window

    private func ensurePanel() -> IslandPanel {
        if let panel { return panel }
        let panel = IslandPanel()
        let root = AnyView(IslandRoot(model: model).environmentObject(store ?? Store(demo: true)))
        let host = IslandHostingView(rootView: root)
        host.onPointer = { [weak self] inside in self?.pointer(inside) }
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    private func teardown() {
        deadlineWork?.cancel(); hoverWork?.cancel(); settleWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        host = nil
        measurer = nil
        model.mode = .hidden
    }

    /// The screen with the menu bar.
    private func currentScreen() -> IslandScreen? {
        guard let screen = NSScreen.screens.first else { return nil }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return IslandScreen.make(frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                 topLeft: screen.auxiliaryTopLeftArea, topRight: screen.auxiliaryTopRightArea,
                                 menuBarHeight: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
    }

    /// Other apps' windows where a centred island would be, looked at only when the island is about to show.
    private func neighbours(on screen: IslandScreen) -> [CGRect] {
        guard settings.position == .automatic,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return IslandNeighbours.obstacles(in: info, ownPID: getpid(), isLocalBuild: BuildInfo.isLocal,
                                          primaryHeight: primaryHeight, band: IslandPlacement.centreBand(screen))
    }

    /// Places the panel for the current mode. Growing, it takes the larger frame at once so the spring has room;
    /// shrinking, it waits for the spring to finish before tightening around the island, so nothing is clipped and
    /// the menu bar around the island stays clickable.
    private func layout(animated: Bool) {
        guard let screen = currentScreen() else { return }
        let panel = ensurePanel()
        if model.mode == .hidden {
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.mode == .hidden else { return }
                self.panel?.orderOut(nil)
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? Self.animation : 0), execute: work)
            return
        }
        let placement = IslandPlacement.place(on: screen, position: settings.position,
                                              obstacles: pinned ? [] : neighbours(on: screen))
        if placement != model.placement { model.placement = placement }
        let target = placement.frame(for: measure(placement: placement))
        let wasVisible = panel.isVisible
        let current = panel.frame
        settleWork?.cancel()
        if wasVisible, animated, !current.isEmpty, current != target {
            let union = current.union(target)
            if union != current { panel.setFrame(union, display: true) }
            if union != target {
                let work = DispatchWorkItem { [weak self] in self?.panel?.setFrame(target, display: true) }
                settleWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.animation, execute: work)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        if !wasVisible { panel.orderFrontRegardless() }
    }

    /// The island's size for the current mode, laid out off screen with the same view.
    private func measure(placement: IslandPlacement) -> CGSize {
        let content = AnyView(IslandContent(mode: model.mode, style: placement.style)
            .environmentObject(store ?? Store(demo: true)))
        if let measurer { measurer.rootView = content } else { measurer = NSHostingController(rootView: content) }
        let size = measurer!.sizeThatFits(in: CGSize(width: 2000, height: 2000))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}

/// A moment the store saw that the island may open for.
struct IslandEvent: Equatable {
    let kind: IslandBanner.Kind
    let sessionID: String
}
