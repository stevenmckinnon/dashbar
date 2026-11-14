import SwiftUI
import AppKit
import Combine

// MARK: - Dashbar Island: the window

/// What the island's view shows, owned by the controller.
@MainActor
final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .hidden
    @Published var placement = IslandPlacement(style: .floating, anchorX: 0, topY: 0)
    /// The shape's size and its centre's distance from the anchor: what springs.
    @Published var size = CGSize.zero
    @Published var offsetX: CGFloat = 0
    /// Where the anchor (the notch's middle, or edge) is inside the panel. Changes only with the panel's frame, never
    /// animated, so resizing the panel never moves the island on screen.
    @Published var anchorInPanel: CGFloat = 0
    @Published var visible = false
    @Published var ears: IslandEars?
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
        // The frontmost app's menus and the menu bar items change with it too.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard let self, self.panel?.isVisible == true else { return }
                        self.menuItems = nil
                        self.update(relayout: true)
                    }
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
        apply(mode, animated: false)
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
        // The collapsed ears follow the menu bar: Dashbar's own item changes width with its stats.
        let ears = earsFor(mode, placement: model.placement)
        guard mode != model.mode || relayout || ears != model.ears else { return }
        apply(mode, animated: true)
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
        host.sizingOptions = []   // the controller sizes the panel; SwiftUI must never resize it mid-animation
        host.layerContentsRedrawPolicy = .duringViewResize
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
        model.visible = false
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
        guard settings.position == .automatic, !pinned,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return IslandNeighbours.obstacles(in: info, ownPID: getpid(), isLocalBuild: BuildInfo.isLocal,
                                          primaryHeight: primaryHeight, band: IslandPlacement.centreBand(screen))
    }

    // MARK: Ears

    /// Other apps' menu bar items, when macOS lists them (it often doesn't). Read again when the frontmost app or the
    /// screens change, or after half a minute, and only while the island is showing.
    private var menuItems: [CGRect]?
    private var menuItemsRead = Date.distantPast

    private func otherMenuItems(_ screen: IslandScreen) -> [CGRect] {
        if let menuItems, Date().timeIntervalSince(menuItemsRead) < 30 { return menuItems }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let items = IslandEars.statusItems(in: info, ownPID: getpid(), primaryHeight: NSScreen.screens.first?.frame.height ?? 0,
                                           menuBarHeight: screen.menuBarHeight)
        menuItems = items
        menuItemsRead = Date()
        return items
    }

    /// Dashbar's own menu bar item (its window is in this process, so its frame is always known).
    private func ownMenuItems() -> [CGRect] {
        NSApp.windows.filter { $0 !== panel && $0.isVisible && String(describing: type(of: $0)).contains("StatusBarWindow") }
            .map(\.frame)
    }

    /// The ears for a collapsed island on the notch, fitted to the menu bar beside it; nil otherwise.
    private func earsFor(_ mode: IslandMode, placement: IslandPlacement) -> IslandEars? {
        guard case .collapsed(let status) = mode, case .notch = placement.style,
              let screen = currentScreen(), let notch = screen.notch else { return nil }
        let widths = IslandMetrics.earWidths(for: status)
        if pinned { return IslandEars.fit(leftGap: IslandEars.assumedLeft, rightGap: IslandEars.assumedRight, widths: widths, allowFull: false) }
        let others = otherMenuItems(screen)
        let gaps = IslandEars.gaps(notch: notch, screen: screen.frame, items: others + ownMenuItems(), itemsAreComplete: !others.isEmpty)
        return IslandEars.fit(leftGap: gaps.left, rightGap: gaps.right, widths: widths, allowFull: gaps.measuredRight)
    }

    // MARK: Animating

    static let animation: TimeInterval = 0.5

    /// Where the island starts from and folds back into: the notch itself, or a sliver at the top edge.
    private func resting(_ placement: IslandPlacement, target: CGSize) -> CGSize {
        switch placement.style {
        case .notch(let w, let h): return CGSize(width: w, height: h)
        case .beside(_, let h): return CGSize(width: 0, height: h)
        case .floating: return CGSize(width: target.width * 0.7, height: 0)
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, changes)
    }

    /// Geometry springs (or, with Reduce Motion, jumps while the content cross-fades).
    private func animate(_ animated: Bool, geometry: () -> Void, content: () -> Void) {
        guard animated else { withoutAnimation { geometry(); content() }; return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withoutAnimation(geometry)
            withAnimation(.easeInOut(duration: 0.2), content)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { geometry(); content() }
        }
    }

    /// Sets the panel's frame and, in the same breath, where the anchor sits in it, so the island stays put on screen.
    private func setPanelFrame(_ frame: CGRect, placement: IslandPlacement) {
        guard let panel, panel.frame != frame else { return }
        withoutAnimation { model.anchorInPanel = placement.anchorX - frame.minX }
        host?.frame = CGRect(origin: .zero, size: frame.size)
        host?.layoutSubtreeIfNeeded()
        host?.displayIfNeeded()
        panel.setFrame(frame, display: true)
        CATransaction.flush()
    }

    /// Moves to a mode. The panel first grows (if it must) to hold both the old and the new island, with its top on
    /// the screen edge; then the shape springs from the top: down and out of the notch to open, back up into it to
    /// close; once it has settled, the panel tightens around it so the menu bar beside it stays clickable.
    private func apply(_ mode: IslandMode, animated: Bool) {
        guard let screen = currentScreen() else { return }
        let panel = ensurePanel()
        settleWork?.cancel()

        if mode == .hidden {
            guard panel.isVisible, model.visible else {
                withoutAnimation { model.mode = .hidden; model.visible = false }
                panel.orderOut(nil)
                return
            }
            let rest = resting(model.placement, target: model.size)
            let restOffset = model.placement.centreOffset(for: rest)
            let fades = model.placement.style != .notch(width: rest.width, height: rest.height)
            animate(animated, geometry: { model.size = rest; model.offsetX = restOffset },
                    content: { model.mode = .hidden; if fades { model.visible = false } })
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.mode == .hidden else { return }
                self.model.visible = false
                self.panel?.orderOut(nil)
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? Self.animation : 0), execute: work)
            return
        }

        let placement = IslandPlacement.place(on: screen, position: settings.position, obstacles: neighbours(on: screen))
        let ears = earsFor(mode, placement: placement)
        let size = measure(mode, style: placement.style, ears: ears)
        let earWidths = ears.map { (left: $0.leftWidth, right: $0.rightWidth) }
        let offset = placement.centreOffset(for: size, ears: earWidths)
        let target = placement.frame(for: size, ears: earWidths)

        let showing = panel.isVisible && model.visible && placement == model.placement
        if !showing {
            // Start from the notch (or a sliver at the top edge), already on screen, then grow out of it.
            let rest = resting(placement, target: size)
            withoutAnimation {
                model.placement = placement
                model.mode = .hidden
                model.ears = nil
                model.size = rest
                model.offsetX = placement.centreOffset(for: rest)
                model.visible = placement.style == .notch(width: rest.width, height: rest.height)
            }
        }
        let current = CGRect(x: placement.anchorX + model.offsetX - model.size.width / 2, y: placement.topY - model.size.height,
                             width: model.size.width, height: model.size.height)
        let canvas = current.union(target)
        setPanelFrame(CGRect(x: IslandPlacement.px(canvas.minX), y: IslandPlacement.px(canvas.minY),
                             width: IslandPlacement.px(canvas.width), height: IslandPlacement.px(canvas.height)), placement: placement)
        if !panel.isVisible { panel.orderFrontRegardless() }

        let run = { [weak self] in
            guard let self else { return }
            self.animate(animated, geometry: {
                self.model.size = size
                self.model.offsetX = offset
            }, content: {
                self.model.ears = ears
                self.model.mode = mode
                self.model.visible = true
            })
            guard animated else { self.setPanelFrame(target, placement: placement); return }
            let work = DispatchWorkItem { [weak self] in self?.setPanelFrame(target, placement: placement) }
            self.settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animation, execute: work)
        }
        // Let the resized panel draw once before the spring starts, so the resize itself is never animated.
        if animated { DispatchQueue.main.async(execute: run) } else { run() }
    }

    /// The island's size for a mode, laid out off screen with the same view.
    private func measure(_ mode: IslandMode, style: IslandStyle, ears: IslandEars?) -> CGSize {
        let content = AnyView(IslandContent(mode: mode, style: style, ears: ears)
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
