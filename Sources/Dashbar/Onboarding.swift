import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Who sees the first run

/// The first-run window: shown once to a new user, and again from "Welcome…" in the gear menus or Settings → About.
enum Onboarding {
    static let seenKey = "onboardingSeen"

    /// Preferences only a copy of Dashbar that has already run would have saved. Sparkle's keys are left out: Sparkle
    /// writes them during a first launch too.
    static let earlierUseKeys: Set<String> = [
        "panelTab", "appPage", "limitAlertsSent", "popoutFloat", "claudeCredentialService",
        Notifier.defaultsKey, Notifier.limitsKey, Notifier.waitingKey, GlobalShortcut.enabledKey,
        AppSettings.Key.scanRoots, AppSettings.Key.editorID, AppSettings.Key.terminalID, AppSettings.Key.refreshSeconds,
        AppSettings.Key.showNow, AppSettings.Key.showWidgets, AppSettings.Key.showServers, AppSettings.Key.menuCPU,
        AppSettings.Key.menuMemory, AppSettings.Key.menuNetwork, AppSettings.Key.menuLimit, AppSettings.Key.claudeLimits,
        IslandSettings.positionKey,
    ]

    /// Show the first run only to someone who has never used Dashbar: it hasn't been shown before, no setting or window
    /// position from an earlier version is saved, and there's no saved scan in Application Support. Someone updating from
    /// a version without onboarding is set up already, so they aren't interrupted; "Welcome…" is there if they want it.
    static func shouldShow(seen: Bool, storedKeys: some Sequence<String>, hasSavedData: Bool) -> Bool {
        if seen || hasSavedData { return false }
        return !storedKeys.contains { key in
            earlierUseKeys.contains(key) || key.hasPrefix("NSWindow Frame ") || key.hasPrefix("com_apple_SwiftUI_Settings")
        }
    }

    /// Decided once, at the very start of launch, before anything this launch writes a preference.
    @MainActor private(set) static var pendingAtLaunch = false

    @MainActor static func decideAtLaunch() {
        let args = CommandLine.arguments
        guard Bundle.main.bundleURL.pathExtension == "app", !args.contains("--snapshot"), !args.contains("--bench") else { return }
        let defaults = UserDefaults.standard
        let seen = defaults.bool(forKey: seenKey)
        let keys = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0)?.keys }.map(Array.init) ?? []
        let saved = ScanCache<Int>.defaultURL("x").deletingLastPathComponent().path
        let show = shouldShow(seen: seen, storedKeys: keys, hasSavedData: FileManager.default.fileExists(atPath: saved))
        // Existing users are marked too, so a later launch never mistakes them for new.
        if !show && !seen { defaults.set(true, forKey: seenKey) }
        // The island is on for a new install only. Someone updating gets nothing new drawn over their notch
        // unasked (it's in Settings → General).
        if show, defaults.object(forKey: IslandSettings.enabledKey) == nil { defaults.set(true, forKey: IslandSettings.enabledKey) }
        pendingAtLaunch = show
    }

    @MainActor static func showAtLaunchIfNeeded(store: Store) {
        guard pendingAtLaunch else { return }
        pendingAtLaunch = false
        // Let the status item settle first, so "Open Dashbar" has an icon to open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OnboardingWindow.shared.show(store: store) }
    }
}

// MARK: - Notification permission

/// Whether macOS lets Dashbar post notifications. Asked only when the user chooses to: from the first run, or by turning
/// a notification toggle on.
@MainActor
final class NotificationPermission: ObservableObject {
    static let shared = NotificationPermission()
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    /// UNUserNotificationCenter crashes outside an .app bundle, and snapshots never ask.
    private let available = Bundle.main.bundleURL.pathExtension == "app" && !CommandLine.arguments.contains("--snapshot")

    var allowed: Bool { status == .authorized || status == .provisional }

    func refresh() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in NotificationPermission.shared.status = status }
        }
    }

    /// Shows macOS's prompt if it hasn't been shown yet; otherwise just reads the current answer.
    func request() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in NotificationPermission.shared.refresh() }
        }
    }

    /// System Settings → Notifications, at Dashbar's entry.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + id) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Under the notification toggles in Settings: what to do when macOS won't deliver them.
struct NotificationPermissionNote: View {
    /// Any notification toggle is on.
    let wanted: Bool
    @ObservedObject private var permission = NotificationPermission.shared

    var body: some View {
        Group {
            if permission.status == .denied {
                note("Notifications are turned off for Dashbar in System Settings.", button: "Open System Settings…") {
                    permission.openSystemSettings()
                }
            } else if permission.status == .notDetermined && wanted {
                note("Dashbar hasn't asked macOS to send notifications yet.", button: "Allow…") { permission.request() }
            }
        }
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permission.refresh() }
    }

    private func note(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private weak var store: Store?

    func show(store: Store?) {
        if let store { self.store = store }
        UserDefaults.standard.set(true, forKey: Onboarding.seenKey)
        if window == nil {
            let window = Self.makeWindow(OnboardingView { [weak self] in self?.finish() })
            window.delegate = self
            window.center()
            self.window = window
        }
        NotificationPermission.shared.refresh()
        window?.collectionBehavior.insert(.moveToActiveSpace)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window, also used offline by `--onboarding` snapshots.
    static func makeWindow(_ view: OnboardingView) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(BuildInfo.appName)"
        window.isReleasedWhenClosed = false
        return window
    }

    /// "Open Dashbar": close, then open the menu bar panel so they see where it lives.
    private func finish() {
        window?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if !Self.clickStatusItem(), let store = self?.store { AppWindow.shared.show(store: store) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = window
        window = nil
        DispatchQueue.main.async { closing?.contentViewController = nil }
    }

    /// Opens the MenuBarExtra's panel by clicking its status item. SwiftUI has no API for it.
    private static func clickStatusItem() -> Bool {
        for window in NSApp.windows where window.className == "NSStatusBarWindow" {
            if let button = findButton(in: window.contentView) {
                button.performClick(nil)
                return true
            }
        }
        return false
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let b = findButton(in: sub) { return b } }
        return nil
    }
}

// MARK: - View

struct OnboardingView: View {
    /// Offline renders: invented folders, and nothing read from or written to the system.
    var snapshot = false
    var onDone: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permission = NotificationPermission.shared
    @State private var launchAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            VStack(spacing: 0) {
                notifications
                Divider().padding(.leading, 46)
                login
                Divider().padding(.leading, 46)
                limits
                Divider().padding(.leading, 46)
                cleanup
            }
            .surface()
            menuBarHint
            HStack {
                Spacer()
                Button(action: done) { Text("Open Dashbar").frame(minWidth: 96) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Dashbar").font(.system(size: 20, weight: .semibold))
                Text("Your Claude Code and Codex sessions, token use, dev servers and caches, in the menu bar. It works from what is already on your Mac and sends none of it anywhere.")
                    .font(.system(size: UI.Size.emphasis))
                    .foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notifications: some View {
        OnboardingRow(symbol: "bell", title: "Notifications",
                      detail: permission.status == .denied
                        ? "Turned off for Dashbar in System Settings."
                        : "When an agent finishes or needs you, and when a plan limit runs low.") {
            switch permission.status {
            case .authorized, .provisional, .ephemeral: Done(text: "Allowed")
            case .denied: Button("Open System Settings…") { permission.openSystemSettings() }
            default: Button("Allow…") { permission.request() }
            }
        }
    }

    private var login: some View {
        OnboardingRow(symbol: "power", title: "Open at login", detail: "Keep Dashbar in the menu bar after you restart.") {
            Toggle("Open at login", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    private var limits: some View {
        OnboardingRow(symbol: "gauge.with.dots.needle.33percent", title: "Claude plan limits",
                      detail: "Your 5-hour and weekly limits. Off until you choose to turn them on.") {
            if settings.showsClaudeLimits && !snapshot { Done(text: "On") }
            else { Button("Set Up…") { SettingsOpener.open(.claudeLimits) } }
        }
    }

    private var cleanup: some View {
        OnboardingRow(symbol: "folder", title: "Clean-up",
                      detail: "Looks for rebuildable caches, like node_modules, in \(folders). Nothing goes to the Trash until you confirm.") {
            Button("Change…") { SettingsOpener.open(.cleanupFolders) }
        }
    }

    /// "~/Development and ~/Code", "~/a, ~/b and 2 more".
    private var folders: String {
        // A word joiner after each slash keeps a path on one line.
        let roots = (snapshot ? ["~/Developer", "~/Code"] : settings.scanRoots.map(Fmt.tilde))
            .map { $0.replacingOccurrences(of: "/", with: "/\u{2060}") }
        switch roots.count {
        case 0: return "no folders yet"
        case 1: return roots[0]
        case 2: return roots[0] + " and " + roots[1]
        default: return roots.prefix(2).joined(separator: ", ") + " and \(roots.count - 2) more"
        }
    }

    private var menuBarHint: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Dashbar lives in the menu bar. Click its icon any time, or press \(GlobalShortcut.display) for the full window.")
                .font(.system(size: UI.Size.body))
                .foregroundStyle(UI.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            MenuBarSketch()
        }
    }

    private func done() {
        if !snapshot {
            let on = SMAppService.mainApp.status == .enabled
            if launchAtLogin != on {
                try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
        }
        onDone()
    }
}

/// One choice: a neutral symbol, what it is, and its control.
private struct OnboardingRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(UI.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: UI.Size.emphasis, weight: .semibold))
                Text(detail)
                    .font(.system(size: UI.Size.body))
                    .foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, UI.cardPadding)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// A finished choice: a quiet checkmark, not a colour.
private struct Done: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark")
            .font(.system(size: UI.Size.body, weight: .medium))
            .foregroundStyle(UI.textSecondary)
    }
}

/// The right-hand end of a menu bar with Dashbar's icon picked out, so the icon is easy to find.
private struct MenuBarSketch: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: BrandMark.menuBarImage(working: false))
                .renderingMode(.template)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.14)))
            Image(systemName: "wifi").font(.system(size: 12, weight: .medium))
            Image(systemName: "switch.2").font(.system(size: 11, weight: .medium))
            Text("9:41").font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.primary.opacity(0.8))
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
        .accessibilityHidden(true)
    }
}
