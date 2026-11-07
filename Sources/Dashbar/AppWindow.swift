import SwiftUI
import AppKit

/// What the Dashbar window shows: one of the panel's pages, or a workspace.
enum AppPage: Hashable {
    case tab(PanelTab)
    case workspace(String)

    /// Saved between launches as "tab:agents" or "workspace:/path/to/project".
    var key: String {
        switch self {
        case .tab(let t): return "tab:" + t.rawValue
        case .workspace(let root): return "workspace:" + root
        }
    }

    init?(key: String) {
        if key.hasPrefix("tab:"), let t = PanelTab(rawValue: String(key.dropFirst(4))) { self = .tab(t); return }
        if key.hasPrefix("workspace:") { self = .workspace(String(key.dropFirst(10))); return }
        return nil
    }
}

/// The window's selection, kept outside the view so the panel, the shortcut and notifications can choose the page.
@MainActor
final class AppWindowModel: ObservableObject {
    static let pageKey = "appPage"
    @Published var page: AppPage {
        didSet { UserDefaults.standard.set(page.key, forKey: Self.pageKey) }
    }

    init(page: AppPage? = nil) {
        self.page = page ?? UserDefaults.standard.string(forKey: Self.pageKey).flatMap(AppPage.init(key:)) ?? .tab(.overview)
    }
}

/// Dashbar as an ordinary app window: a sidebar of pages and workspaces, with the chosen one beside it. Opened from the
/// panel's button, ⌃⌥D or a notification; the menu bar panel stays the quick glance. A plain NSWindow rather than a
/// SwiftUI `Window` scene, which would open by itself at launch on macOS 14.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {
    static let shared = AppWindow()
    /// "Keep on top". The key dates from when this window was the narrow popout.
    static let floatKey = "popoutFloat"
    static let minimumSize = NSSize(width: 860, height: 540)

    let model = AppWindowModel()
    private var window: NSWindow?

    func show(store: Store, page: AppPage? = nil) {
        if let page { model.page = page }
        if window == nil { window = makeWindow(store: store) }
        guard let window else { return }
        // Dashbar has no Dock icon by default; a visible window needs one to be focusable and to show the app menu.
        NSApp.setActivationPolicy(.regular)
        BuildInfo.applyLocalIcon()
        applyLevel()
        window.makeKeyAndOrderFront(nil)
        // AppKit would put the cursor in the sidebar's filter field; it waits for ⌘K or a click instead.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
        NSApp.activate()
    }

    /// The shortcut's action: bring the window up, or close it if it's already in front.
    func toggle(store: Store) {
        if let window, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.performClose(nil)
        } else {
            show(store: store)
        }
    }

    /// Applies the "keep on top" setting to the open window.
    func applyLevel() {
        window?.level = UserDefaults.standard.bool(forKey: Self.floatKey) ? .floating : .normal
    }

    private func makeWindow(store: Store) -> NSWindow {
        let host = NSHostingController(rootView: AppView(model: model).environmentObject(store))
        host.sizingOptions = []   // the window sets the size, not the content
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = BuildInfo.appName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.contentMinSize = Self.minimumSize
        if !window.setFrameAutosaveName("DashbarWindow") { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the view so the store sees it disappear, then go back to menu-bar-only.
        let closing = window
        window = nil
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { closing?.contentViewController = nil }
    }
}
