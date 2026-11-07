import SwiftUI
import AppKit

/// The dashboard in an ordinary window, for keeping on a second display. Same width as the menu bar
/// panel; only the height resizes. It is a plain NSWindow rather than a SwiftUI `Window` scene, which
/// would open by itself at launch on macOS 14.
@MainActor
final class Popout: NSObject, NSWindowDelegate {
    static let shared = Popout()
    static let floatKey = "popoutFloat"

    private var window: NSWindow?

    func show(store: Store) {
        if window == nil { window = makeWindow(store: store) }
        guard let window else { return }
        // Dashbar has no Dock icon by default; a visible window needs one to be focusable and to show the app menu.
        NSApp.setActivationPolicy(.regular)
        applyLevel()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Applies the "keep on top" setting to the open window.
    func applyLevel() {
        window?.level = UserDefaults.standard.bool(forKey: Self.floatKey) ? .floating : .normal
    }

    private func makeWindow(store: Store) -> NSWindow {
        let host = NSHostingController(rootView: DashboardView(popout: true).environmentObject(store))
        host.sizingOptions = []   // the window sets the height, not the content
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Dashbar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        let width = DashboardView.width
        window.setContentSize(NSSize(width: width, height: 640))
        window.contentMinSize = NSSize(width: width, height: 420)
        window.contentMaxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if !window.setFrameAutosaveName("DashbarPopout") { window.center() }
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
