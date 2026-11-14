import SwiftUI
import AppKit
import ServiceManagement

/// User preferences, persisted in UserDefaults. Read on the main actor by views and the store;
/// background code reads plain values passed to it, or UserDefaults directly (Launcher).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key {
        static let scanRoots = "scanRoots"
        static let editorID = "editorID"
        static let terminalID = "terminalID"
        static let refreshSeconds = "refreshSeconds"
        static let showNow = "showNow"
        static let showWidgets = "showWidgets"
        static let showServers = "showServers"
        static let menuCPU = "menuCPU"
        static let menuMemory = "menuMemory"
        static let menuNetwork = "menuNetwork"
        static let menuLimit = "menuClaudeLimit"
        static let menuLimitWindow = "menuClaudeLimitWindow"
        static let menuCodexLimit = "menuCodexLimit"
        static let menuAntigravityLimit = "menuAntigravityLimit"
        static let menuAnimate = "menuAnimate"
        static let menuDone = "menuDone"
        static let menuText = "menuText"
        static let claudeLimits = "claudeLimitsExperimental"
        static let accounts = "agentAccounts"
        static let permissionWait = "permissionWaitSeconds"
    }

    private let defaults = UserDefaults.standard

    /// Folders the clean-up scan walks (absolute paths).
    @Published var scanRoots: [String] { didSet { defaults.set(scanRoots, forKey: Key.scanRoots) } }
    /// Bundle identifiers; empty means "pick automatically".
    @Published var editorID: String { didSet { defaults.set(editorID, forKey: Key.editorID) } }
    @Published var terminalID: String { didSet { defaults.set(terminalID, forKey: Key.terminalID) } }
    /// Base refresh cadence for live data (sessions, CPU). Servers and usage run at multiples of it.
    @Published var refreshSeconds: Double { didSet { defaults.set(refreshSeconds, forKey: Key.refreshSeconds) } }
    @Published var showNow: Bool { didSet { defaults.set(showNow, forKey: Key.showNow) } }
    @Published var showWidgets: Bool { didSet { defaults.set(showWidgets, forKey: Key.showWidgets) } }
    @Published var showServers: Bool { didSet { defaults.set(showServers, forKey: Key.showServers) } }
    /// Live stats shown beside the menu bar icon.
    @Published var menuCPU: Bool { didSet { defaults.set(menuCPU, forKey: Key.menuCPU) } }
    @Published var menuMemory: Bool { didSet { defaults.set(menuMemory, forKey: Key.menuMemory) } }
    @Published var menuNetwork: Bool { didSet { defaults.set(menuNetwork, forKey: Key.menuNetwork) } }
    /// What's left of the Claude plan limit, beside the icon. Needs the plan-limits setting in Integrations.
    @Published var menuLimit: Bool { didSet { defaults.set(menuLimit, forKey: Key.menuLimit) } }
    /// The same for Codex and Antigravity.
    @Published var menuCodexLimit: Bool { didSet { defaults.set(menuCodexLimit, forKey: Key.menuCodexLimit) } }
    @Published var menuAntigravityLimit: Bool { didSet { defaults.set(menuAntigravityLimit, forKey: Key.menuAntigravityLimit) } }
    /// Which plan window they show: 5-hour by default.
    @Published var menuLimitWindow: ClaudePlanLimits.MenuWindow {
        didSet { defaults.set(menuLimitWindow.rawValue, forKey: Key.menuLimitWindow) }
    }
    /// The menu bar mark's bar sweeps while agents work (never with Reduce Motion on).
    @Published var menuAnimate: Bool { didSet { defaults.set(menuAnimate, forKey: Key.menuAnimate) } }
    /// A green "Done · project" beside the icon for a few seconds after an agent finishes.
    @Published var menuDone: Bool { didSet { defaults.set(menuDone, forKey: Key.menuDone) } }
    /// What the text beside the icon says about working agents.
    @Published var menuText: MenuBarStatus.TextMode { didSet { defaults.set(menuText.rawValue, forKey: Key.menuText) } }
    /// Experimental: read Claude Code's sign-in to show plan limits. Off by default.
    @Published var claudeLimits: Bool { didSet { defaults.set(claudeLimits, forKey: Key.claudeLimits) } }
    /// Dashbar's bridge is in Claude Code's status line. Not a preference: it mirrors Claude Code's settings file,
    /// re-read at launch, every few minutes and when Settings opens, since the user can change that file any time.
    @Published private(set) var claudeStatusLine = false
    @Published private(set) var claudeStatusLineStatus: StatusLineBridge.Status = .notInstalled(current: nil)

    /// Claude Code and Codex folders the user added (other accounts), and names given to any account, default included.
    @Published var accounts: [AgentAccount] { didSet { Self.saveAccounts(accounts, to: defaults) } }
    /// Whether Dashbar's bridge is in each added Claude account's status line, by folder. The default account's is
    /// `claudeStatusLineStatus`.
    @Published private(set) var accountStatusLines: [String: StatusLineBridge.Status] = [:]

    /// Every Claude Code account Dashbar reads: the default first.
    var claudeAccounts: [ResolvedAccount] { AgentAccounts.resolve(.claude, saved: accounts) }
    var codexAccounts: [ResolvedAccount] { AgentAccounts.resolve(.codex, saved: accounts) }

    nonisolated static func loadAccounts(from defaults: UserDefaults) -> [AgentAccount] {
        guard let data = defaults.data(forKey: Key.accounts) else { return [] }
        return (try? JSONDecoder().decode([AgentAccount].self, from: data)) ?? []
    }

    nonisolated static func saveAccounts(_ accounts: [AgentAccount], to defaults: UserDefaults) {
        if accounts.isEmpty { defaults.removeObject(forKey: Key.accounts); return }
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: Key.accounts) }
    }

    /// Adds a folder as an account, or renames one. An empty name falls back to one made from the folder.
    func setAccount(_ kind: AgentKind, path: String, label: String) {
        let p = AgentAccounts.normalise(path)
        if let i = accounts.firstIndex(where: { $0.kind == kind && AgentAccounts.normalise($0.path) == p }) {
            accounts[i].label = label
        } else {
            accounts.append(AgentAccount(kind: kind, path: p, label: label))
        }
    }

    /// Stops reading an added account. Its status line bridge and permission hook, if any, are taken out first, so
    /// nothing is left behind.
    func removeAccount(_ account: ResolvedAccount) -> String? {
        if account.kind == .claude, accountStatusLines[account.path]?.isInstalled == true {
            if let problem = setStatusLine(false, account: account) { return problem }
        }
        if account.kind == .claude, accountPermissions[account.path]?.isInstalled == true {
            if let problem = setPermissions(false, account: account) { return problem }
        }
        accounts.removeAll { $0.kind == account.kind && AgentAccounts.normalise($0.path) == account.path }
        accountStatusLines[account.path] = nil
        accountPermissions[account.path] = nil
        return nil
    }

    /// Re-reads whether the bridge is in each added Claude account's settings.json.
    func refreshAccountStatusLines() {
        guard !CommandLine.arguments.contains("--demo") else { return }
        var out: [String: StatusLineBridge.Status] = [:]
        for account in claudeAccounts where !account.isDefault {
            let paths = StatusLineBridge.Paths.forAccount(account)
            let status = StatusLineBridge.status(paths)
            if status.isInstalled { try? StatusLineBridge.writeScript(paths) }
            out[account.path] = status
        }
        if out != accountStatusLines { accountStatusLines = out }
    }

    /// Adds or removes the bridge in one account's status line: the Integrations setting for the default, Accounts for the rest.
    func setStatusLine(_ on: Bool, account: ResolvedAccount) -> String? {
        if account.isDefault { return setClaudeStatusLine(on) }
        let paths = StatusLineBridge.Paths.forAccount(account)
        var problem: String?
        do { on ? try StatusLineBridge.install(paths) : try StatusLineBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refreshAccountStatusLines()
        return problem
    }
    /// Dashbar's hook is in Claude Code's PermissionRequest hooks, so Dashbar can answer permission prompts. Like the
    /// status line, this mirrors Claude Code's settings file rather than being a preference.
    /// True while any account has the hook.
    @Published private(set) var claudePermissions = false
    /// The default account's hook.
    @Published private(set) var claudePermissionsStatus: PermissionBridge.Status = .notInstalled
    /// Each added Claude account's hook, by folder.
    @Published private(set) var accountPermissions: [String: PermissionBridge.Status] = [:]
    /// How long Dashbar offers an answer. The terminal's own prompt is up the whole time.
    @Published var permissionWait: Int { didSet { defaults.set(permissionWait, forKey: Key.permissionWait) } }

    var showsMenuBarStats: Bool { menuCPU || menuMemory || menuNetwork }
    /// Either way of reading Claude plan limits is on.
    var showsClaudeLimits: Bool { claudeLimits || claudeStatusLine }

    /// Re-reads whether the bridge is in Claude Code's settings, and refreshes its script if it is.
    func refreshClaudeStatusLine(paths: StatusLineBridge.Paths = .default()) {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let status = StatusLineBridge.status(paths)
        if status.isInstalled { try? StatusLineBridge.writeScript(paths) }
        if status != claudeStatusLineStatus { claudeStatusLineStatus = status }
        if status.isInstalled != claudeStatusLine { claudeStatusLine = status.isInstalled }
        refreshAccountStatusLines()
    }

    /// Adds or removes Dashbar's bridge in Claude Code's status line. Returns what went wrong, phrased for the user.
    func setClaudeStatusLine(_ on: Bool, paths: StatusLineBridge.Paths = .default()) -> String? {
        var problem: String?
        do { on ? try StatusLineBridge.install(paths) : try StatusLineBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refreshClaudeStatusLine(paths: paths)
        return problem
    }

    /// Re-reads whether Dashbar's permission hook is in each account's Claude Code settings, and refreshes the shared
    /// script and queue while any account has it.
    func refreshClaudePermissions(paths: PermissionBridge.Paths = .default()) {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let status = PermissionBridge.status(paths)
        var others: [String: PermissionBridge.Status] = [:]
        for account in claudeAccounts where !account.isDefault {
            others[account.path] = PermissionBridge.status(.forAccount(account))
        }
        let any = status.isInstalled || others.values.contains(where: \.isInstalled)
        if any {
            try? PermissionBridge.writeScript(paths)
            try? PermissionBridge.prepareQueue(paths)
        }
        if status != claudePermissionsStatus { claudePermissionsStatus = status }
        if others != accountPermissions { accountPermissions = others }
        if any != claudePermissions { claudePermissions = any }
    }

    /// Adds or removes Dashbar's permission hook in the default account. Returns what went wrong, phrased for the user.
    func setClaudePermissions(_ on: Bool, paths: PermissionBridge.Paths = .default()) -> String? {
        var problem: String?
        do { on ? try PermissionBridge.install(paths) : try PermissionBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refreshClaudePermissions(paths: paths)
        return problem
    }

    /// One account's permission hook status.
    func permissionStatus(_ account: ResolvedAccount) -> PermissionBridge.Status {
        account.isDefault ? claudePermissionsStatus : accountPermissions[account.path] ?? .notInstalled
    }

    /// Adds or removes Dashbar's permission hook in one account's settings.json.
    func setPermissions(_ on: Bool, account: ResolvedAccount) -> String? {
        if account.isDefault { return setClaudePermissions(on) }
        var problem: String?
        let paths = PermissionBridge.Paths.forAccount(account)
        do { on ? try PermissionBridge.install(paths) : try PermissionBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refreshClaudePermissions()
        return problem
    }

    private init() {
        defaults.register(defaults: [
            Key.refreshSeconds: 3.0, Key.showNow: true, Key.showWidgets: true, Key.showServers: true,
            Notifier.defaultsKey: true, Key.permissionWait: PermissionBridge.defaultWait,
            Key.menuAnimate: true, Key.menuDone: true,
        ])
        permissionWait = defaults.integer(forKey: Key.permissionWait)
        scanRoots = defaults.stringArray(forKey: Key.scanRoots) ?? Cleanup.defaultRoots
        accounts = Self.loadAccounts(from: defaults)
        editorID = defaults.string(forKey: Key.editorID) ?? ""
        terminalID = defaults.string(forKey: Key.terminalID) ?? ""
        refreshSeconds = defaults.double(forKey: Key.refreshSeconds)
        showNow = defaults.bool(forKey: Key.showNow)
        showWidgets = defaults.bool(forKey: Key.showWidgets)
        showServers = defaults.bool(forKey: Key.showServers)
        menuCPU = defaults.bool(forKey: Key.menuCPU)
        menuMemory = defaults.bool(forKey: Key.menuMemory)
        menuNetwork = defaults.bool(forKey: Key.menuNetwork)
        menuLimit = defaults.bool(forKey: Key.menuLimit)
        menuCodexLimit = defaults.bool(forKey: Key.menuCodexLimit)
        menuAntigravityLimit = defaults.bool(forKey: Key.menuAntigravityLimit)
        menuLimitWindow = defaults.string(forKey: Key.menuLimitWindow).flatMap(ClaudePlanLimits.MenuWindow.init(rawValue:)) ?? .fiveHour
        menuAnimate = defaults.bool(forKey: Key.menuAnimate)
        menuDone = defaults.bool(forKey: Key.menuDone)
        menuText = defaults.string(forKey: Key.menuText).flatMap(MenuBarStatus.TextMode.init(rawValue:)) ?? .count
        // Demo renders show the plan limits without reading the Keychain; assigning here skips `didSet`, so nothing is saved.
        claudeLimits = defaults.bool(forKey: Key.claudeLimits) || CommandLine.arguments.contains("--demo")
        if CommandLine.arguments.contains("--demo") {
            menuLimit = true
            // For `--settings` renders, in memory only: two Claude accounts, and the permission hook in the first.
            let env = ProcessInfo.processInfo.environment
            if env["DASHBAR_DEMO_ACCOUNTS"].flatMap(Int.init).map({ $0 >= 2 }) == true {
                accounts = [AgentAccount(kind: .claude, path: AgentAccounts.defaultPath(.claude), label: "Personal"),
                            AgentAccount(kind: .claude, path: homeDir.appendingPathComponent(".claude-work").path, label: "Work")]
            }
            if env["DASHBAR_DEMO_PERMISSION"] != nil {
                claudePermissions = true
                claudePermissionsStatus = .installed
            }
        }
    }
}

// MARK: - Settings window

/// Settings' tabs. The selected one is saved under `key`, which is how every "Settings…" link opens Settings at a tab.
enum SettingsTab: String, CaseIterable {
    static let key = "settingsTab"
    case general, notifications, menuBar, folders, accounts, integrations, about

    /// A tab by a saved or typed name, including names from before the tabs were rearranged ("labs" became Integrations).
    init?(name: String) {
        if name == "labs" { self = .integrations } else { self.init(rawValue: name) }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .menuBar: "Menu Bar"
        case .folders: "Folders"
        case .accounts: "Accounts"
        case .integrations: "Integrations"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .menuBar: "menubar.rectangle"
        case .folders: "folder"
        case .accounts: "person.2"
        case .integrations: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }

    // Where the settings other screens link to live, so every link follows a setting if it moves tab.
    /// Claude plan limits: the status line, and the experimental endpoint.
    static let claudeLimits = SettingsTab.integrations
    /// Answering Claude Code's permission prompts in Dashbar.
    static let permissionPrompts = SettingsTab.integrations
    /// Other Claude Code and Codex accounts.
    static let otherAccounts = SettingsTab.accounts
    /// The folders the clean-up scans.
    static let cleanupFolders = SettingsTab.folders
    /// Notifications and the island.
    static let alerts = SettingsTab.notifications

    /// A saved tab whose name is gone, moved to where it went (a saved "labs" would otherwise open General).
    static func migrateSaved(_ defaults: UserDefaults = .standard) {
        guard let saved = defaults.string(forKey: key), SettingsTab(rawValue: saved) == nil else { return }
        defaults.set((SettingsTab(name: saved) ?? .general).rawValue, forKey: key)
    }
}

/// The one way to open Settings at a tab. Settings opens through SwiftUI's `openSettings`, which only works from a view
/// inside one of the app's scenes: views pass their own (`SettingsButton`), and the menu bar label hands its over when it
/// appears (`capturesSettingsOpener`), so AppKit windows such as the first run can open Settings too.
@MainActor
enum SettingsOpener {
    static var action: OpenSettingsAction?

    /// - Parameter tab: the tab to show; nil keeps the one Settings was left on.
    static func open(_ tab: SettingsTab?, using openSettings: OpenSettingsAction? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key) }
        NSApp.activate(ignoringOtherApps: true)
        if let open = openSettings ?? action { open() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        // SwiftUI creates or reuses the window after this returns, and closing the panel or its menu hands focus back
        // to the app that had it a moment later, so try again after that.
        for delay in [0, 0.15, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { bringForward() }
        }
    }

    /// Whether Settings is on screen (the Dashbar window keeps the Dock icon while it is).
    static var isVisible: Bool { window?.isVisible == true }
    private static var closeObserver: NSObjectProtocol?

    /// SwiftUI's Settings window, once it exists.
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true || $0.frameAutosaveName.contains("Settings") }
    }

    /// Keeps the window at the content's width (only its height drags; a frame saved by an older build could be any
    /// shape) and puts it in front of everything, the Dashbar window included. An accessory app's windows otherwise
    /// open behind the frontmost app, and SwiftUI only orders the window front the first time.
    static func bringForward() {
        guard let window else { return }
        let width = SettingsView.width
        window.contentMinSize = NSSize(width: width, height: SettingsView.minHeight)
        window.contentMaxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        let content = window.contentRect(forFrameRect: window.frame)
        if abs(content.width - width) > 1 || content.height < SettingsView.minHeight {
            let height = content.height < SettingsView.minHeight || content.height < content.width * 0.6
                ? SettingsView.idealHeight : content.height
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
        }
        // Above the Dashbar window when that one is kept on top.
        window.level = UserDefaults.standard.bool(forKey: AppWindow.floatKey) ? .floating : .normal
        // A menu-bar-only app can't reliably take focus from the frontmost app; with a Dock icon it can, and the
        // window then also shows in ⌘-Tab. Back to menu-bar-only when Settings closes (unless the Dashbar window is open).
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            BuildInfo.applyLocalIcon()
        }
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
                    closeObserver = nil
                    if !AppWindow.shared.isVisible { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)   // the plain call is only a request, often refused for an accessory app
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

extension View {
    /// Hands this scene's `openSettings` to `SettingsOpener`.
    func capturesSettingsOpener() -> some View { modifier(CaptureSettingsOpener()) }

    /// A section footer: secondary, and ragged right from the leading edge (grouped forms otherwise set long footers
    /// flush right, which reads as broken). A size smaller than the rows, as in System Settings.
    func settingsFooter() -> some View {
        font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CaptureSettingsOpener: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onAppear { SettingsOpener.action = openSettings }
    }
}

/// "Settings…" that opens on the tab where the setting lives (or, with no tab, wherever Settings was left), and brings
/// an already open Settings window to the front, which SwiftUI's `SettingsLink` doesn't.
struct SettingsButton<Label: View>: View {
    var tab: SettingsTab? = nil
    @ViewBuilder var label: Label
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { SettingsOpener.open(tab, using: openSettings) } label: { label }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab: SettingsTab = .general

    /// Every tab shares one size, so switching tabs never resizes the window. Taller content scrolls inside its grouped
    /// form, and the window's bottom edge drags to make it taller or shorter (down to `minHeight`).
    static let width: CGFloat = 500
    static let minHeight: CGFloat = 340
    /// The opening height: room for the longest tab without scrolling, but never taller than the screen it opens on.
    @MainActor static var idealHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(minHeight, min(640, visible - 80))
    }

    init() { SettingsTab.migrateSaved() }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Self.content(tab).tabItem { Label(tab.title, systemImage: tab.symbol) }.tag(tab)
            }
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: .infinity)
        .onAppear {
            // An accessory app's windows open behind the frontmost app unless we activate.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { SettingsOpener.bringForward() }
        }
    }

    @ViewBuilder private static func content(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings()
        case .notifications: NotificationSettings()
        case .menuBar: MenuBarSettings()
        case .folders: FolderSettings()
        case .accounts: AccountSettings()
        case .integrations: IntegrationSettings()
        case .about: AboutSettings()
        }
    }

    /// One tab's page on its own, at the window's opening size, for `--snapshot … --settings <tab>` (offline renders of
    /// the TabView only ever draw its first tab). `height` overrides the opening height.
    @MainActor static func page(_ tab: SettingsTab, height: CGFloat? = nil) -> some View {
        content(tab).frame(width: width, height: height ?? idealHeight)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(GlobalShortcut.enabledKey) private var shortcut = true
    @AppStorage(CostLine.showKey) private var showCost = true
    @State private var shortcutUnavailable = GlobalShortcut.shared.unavailable
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Toggle("Open the window with \(GlobalShortcut.display)", isOn: $shortcut)
                    .onChange(of: shortcut) { _, on in
                        GlobalShortcut.shared.setEnabled(on)
                        shortcutUnavailable = GlobalShortcut.shared.unavailable
                    }
                if shortcut && shortcutUnavailable {
                    Text("Another app is using \(GlobalShortcut.display), so it won't open Dashbar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                AppPicker(title: "Editor", selection: $settings.editorID, candidates: Launcher.editorCandidates)
                AppPicker(title: "Terminal", selection: $settings.terminalID, candidates: Launcher.terminalCandidates)
                Picker("Refresh every", selection: $settings.refreshSeconds) {
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
            }
            Section("Overview shows") {
                Toggle("Current workspace", isOn: $settings.showNow)
                Toggle("Today and this week", isOn: $settings.showWidgets)
                Toggle("Servers outside projects", isOn: $settings.showServers)
            }
            Section("Usage") {
                Toggle("Estimated cost at API prices", isOn: $showCost)
                    .help("Works out what your tokens would cost on the pay-as-you-go API at list prices. On a plan you pay the plan's price, not this.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Notifications, and the island, which can stand in for some of them.
private struct NotificationSettings: View {
    @AppStorage(Notifier.defaultsKey) private var notify = true
    @AppStorage(Notifier.limitsKey) private var notifyLimits = true
    @AppStorage(Notifier.waitingKey) private var notifyWaiting = true
    @AppStorage(IslandSettings.enabledKey) private var island = false
    @AppStorage(IslandSettings.positionKey) private var islandPosition = IslandPosition.automatic.rawValue
    @AppStorage(IslandSettings.expandOnFinishKey) private var islandFinish = true
    @AppStorage(IslandSettings.expandOnNeedsYouKey) private var islandNeedsYou = true
    @AppStorage(IslandSettings.replacesNotificationsKey) private var islandInstead = false
    @AppStorage(IslandSettings.showsPillKey) private var islandPill = false

    var body: some View {
        Form {
            Section {
                Toggle("When an agent finishes", isOn: $notify)
                Toggle("When an agent needs you", isOn: $notifyWaiting)
                    .help("When Claude stops to ask for permission or an answer.")
                Toggle("When a plan limit runs low", isOn: $notifyLimits)
                    .help("At 80%, when it's on course to run out before it resets, and when it's used up. Once per window.")
                NotificationPermissionNote(wanted: notify || notifyWaiting || notifyLimits)
            } header: {
                Text("Notify")
            }
            Section {
                Toggle("Show the island when something happens", isOn: $island)
                    .help("A small black pill on the notch (or below the menu bar) with your agents' status. It opens briefly when something happens, and on hover lists your sessions.")
                if island {
                    Picker("Position", selection: $islandPosition) {
                        Text("Automatic").tag(IslandPosition.automatic.rawValue)
                        Text("On the notch").tag(IslandPosition.centre.rawValue)
                        Text("Left of the notch").tag(IslandPosition.left.rawValue)
                        Text("Right of the notch").tag(IslandPosition.right.rawValue)
                    }
                    .help("Automatic sits on the notch, or just below another app's island when one is already there.")
                    Toggle("Open when an agent finishes", isOn: $islandFinish)
                    Toggle("Open when an agent needs you", isOn: $islandNeedsYou)
                        .help("With answering permission prompts on (Integrations), you can Allow once or Deny right in the island.")
                    Toggle("Use the island instead of notifications", isOn: $islandInstead)
                        .help("Leaves out the notification for anything the island opens for. The others still notify.")
                    Toggle("Keep a small status beside the notch", isOn: $islandPill)
                        .help("While agents work or wait, the mark and a count stay either side of the notch, and hovering lists your sessions.")
                    if islandPill {
                        Text("In apps with many menus it can cover the last few, since macOS carries menus on past the notch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Island")
            } footer: {
                Text("A banner grows out of the notch (or below the menu bar) when an agent finishes or needs you, then folds away. Between moments nothing is drawn, unless you keep the small status beside the notch.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        // Turning a notification on is when macOS is asked, never at launch.
        .onChange(of: [notify, notifyWaiting, notifyLimits]) { old, new in
            if zip(old, new).contains(where: { !$0 && $1 }) { NotificationPermission.shared.request() }
        }
    }
}

private struct MenuBarSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var antigravity = AntigravitySettings.shared
    /// Codex is only offered to someone who uses it.
    private let usesCodex = FileManager.default.fileExists(atPath: AgentAccounts.defaultPath(.codex))

    var body: some View {
        Form {
            Section {
                Picker("Text beside the icon", selection: $settings.menuText) {
                    ForEach(MenuBarStatus.TextMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Animate while agents work", isOn: $settings.menuAnimate)
                Toggle("Show “Done” when an agent finishes", isOn: $settings.menuDone)
            } header: {
                Text("Agents")
            } footer: {
                Text("An agent that needs you always shows, in amber. Count and time adds how long the longest-running agent has been working. The icon holds still when Reduce Motion is on.")
                    .settingsFooter()
            }
            Section {
                Toggle("CPU", isOn: $settings.menuCPU)
                Toggle("Memory", isOn: $settings.menuMemory)
                Toggle("Download speed", isOn: $settings.menuNetwork)
                Toggle("Claude plan left", isOn: $settings.menuLimit)
                    .disabled(!settings.showsClaudeLimits)
                if usesCodex { Toggle("Codex plan left", isOn: $settings.menuCodexLimit) }
                if antigravity.status.isInstalled { Toggle("Antigravity plan left", isOn: $settings.menuAntigravityLimit) }
                if settings.menuLimit && settings.showsClaudeLimits || settings.menuCodexLimit && usesCodex
                    || settings.menuAntigravityLimit && antigravity.status.isInstalled {
                    Picker("Limit", selection: $settings.menuLimitWindow) {
                        ForEach(ClaudePlanLimits.MenuWindow.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Also beside the icon")
            } footer: {
                Text("These follow the agents' status. Plan left shows the limit you pick; if the other one is nearly out or on course to run out, it shows that one instead, with a warning symbol. With more than one tool on, each is named."
                     + (settings.showsClaudeLimits ? "" : " Claude plan left needs Claude plan limits, in Integrations."))
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }
}

/// Changes Dashbar can make to other tools' settings: each is off until you add it, and Remove undoes it exactly.
private struct IntegrationSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var problem: String?
    @State private var permissionProblem: String?

    var body: some View {
        Form {
            Section {
                statusLineRow
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Claude plan limits")
            } footer: {
                Text(statusLineExplanation).settingsFooter()
            }
            Section {
                if settings.claudeAccounts.count > 1 {
                    ForEach(settings.claudeAccounts) { accountPermissionsRow($0) }
                } else {
                    permissionsRow
                }
                if settings.claudePermissions {
                    Picker("Wait for an answer", selection: $settings.permissionWait) {
                        ForEach(PermissionBridge.waitChoices, id: \.self) { seconds in
                            Text(seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes").tag(seconds)
                        }
                    }
                }
                if let permissionProblem {
                    Label(permissionProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Claude Code permission prompts")
            } footer: {
                Text(permissionsExplanation).settingsFooter()
            }
            AntigravityLabsSection()
            // Last, and labelled: the one setting here that leans on something undocumented.
            Section {
                Toggle("Also ask Anthropic with Claude Code's sign-in", isOn: $settings.claudeLimits)
            } header: {
                Text("Experimental")
            } footer: {
                Text("Another way to get Claude plan limits, only needed if you'd rather not change Claude Code's status line. Reads Claude Code's sign-in from your Keychain, the same way Claude Code does, and asks an undocumented endpoint that may change. Never refreshes or saves the sign-in. When both are on, Dashbar shows the newer reading.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            settings.refreshClaudeStatusLine()
            settings.refreshClaudePermissions()
            AntigravitySettings.shared.refresh()
        }
    }

    @ViewBuilder private var permissionsRow: some View {
        switch settings.claudePermissionsStatus {
        case .installed:
            LabeledContent {
                Button("Remove") { permissionProblem = settings.setClaudePermissions(false) }
            } label: {
                Text("Answering in Dashbar")
                Text("Allow once or Deny from the panel, the window or the notification.")
            }
        case .notInstalled:
            LabeledContent {
                Button("Add to Claude Code") { permissionProblem = settings.setClaudePermissions(true) }
            } label: {
                Text("Answer permission prompts in Dashbar")
                Text("Off until you add it. Never answers by itself.")
            }
        case .unreadable(let message):
            LabeledContent {
                Button("Check Again") { permissionProblem = nil; settings.refreshClaudePermissions() }
            } label: {
                Text("Answer permission prompts in Dashbar")
                Text(message)
            }
        }
    }

    /// With more than one account: a row per account, each added or removed in that account's own settings.json.
    @ViewBuilder private func accountPermissionsRow(_ account: ResolvedAccount) -> some View {
        LabeledContent {
            switch settings.permissionStatus(account) {
            case .installed:
                Button("Remove") { permissionProblem = settings.setPermissions(false, account: account) }
            case .notInstalled:
                Button("Add") { permissionProblem = settings.setPermissions(true, account: account) }
                    .help("Adds the hook to \(Fmt.tilde(account.settingsFile.path)), after a backup.")
            case .unreadable(let message):
                Button("Check Again") { permissionProblem = nil; settings.refreshClaudePermissions() }
                    .help(message)
            }
        } label: {
            Text(account.label)
            switch settings.permissionStatus(account) {
            case .installed: Text("Answering in Dashbar")
            case .notInstalled: Text("Asks in the terminal")
            case .unreadable(let message): Text(message)
            }
        }
    }

    private var permissionsExplanation: String {
        let file = settings.claudeAccounts.count > 1 ? "that account's settings.json"
            : Fmt.tilde(PermissionBridge.Paths.default().settings.path)
        return "Adds one PermissionRequest hook to \(file). When Claude Code asks to use a tool, Dashbar shows Allow once "
            + "and Deny while the terminal asks too, so you can answer in either place. Dashbar never answers by itself or "
            + "changes your permission rules. Requests stay in a folder only you can read, and nothing is sent. The file is "
            + "backed up first; Remove takes out only Dashbar's hook."
    }

    @ViewBuilder private var statusLineRow: some View {
        switch settings.claudeStatusLineStatus {
        case .installed(let previous):
            LabeledContent {
                Button("Remove") { problem = settings.setClaudeStatusLine(false) }
            } label: {
                Text("In Claude Code's status line")
                Text(previous.map { "Updates after each Claude Code reply. Your status line (\(Self.short($0))) still shows." }
                     ?? "Updates after each Claude Code reply.")
            }
        case .notInstalled(let current):
            LabeledContent {
                Button("Add to Status Line") { problem = settings.setClaudeStatusLine(true) }
            } label: {
                Text("Read limits from Claude Code's status line")
                Text(current.map { "Recommended. Your status line (\(Self.short($0))) keeps showing." } ?? "Recommended. Sends nothing.")
            }
        case .unreadable(let message):
            LabeledContent {
                Button("Check Again") { problem = nil; settings.refreshClaudeStatusLine() }
            } label: {
                Text("Read limits from Claude Code's status line")
                Text(message)
            }
        }
    }

    /// A long inline command, cut to fit a settings row.
    static func short(_ command: String) -> String {
        command.count > 48 ? String(command.prefix(47)) + "…" : command
    }

    private var statusLineExplanation: String {
        let file = Fmt.tilde(StatusLineBridge.Paths.default().settings.path)
        return "Claude Code passes your 5-hour and weekly usage to its status line after each reply (Pro, Max and Ultra plans). "
            + "Adding Dashbar points statusLine in \(file) at a small script that saves just those numbers on this Mac, "
            + "then runs the status line you had, so it looks the same. The file is backed up first. No network, no "
            + "Keychain. Remove puts your previous status line back exactly."
            + (settings.claudeAccounts.count > 1
                ? " This is \(settings.claudeAccounts[0].label)'s; add other accounts' in Accounts." : "")
    }
}

private struct AppPicker: View {
    let title: String
    @Binding var selection: String
    let candidates: [(id: String, name: String)]

    var body: some View {
        let installed = Launcher.installed(candidates)
        let automatic = installed.first?.name
        Picker(title, selection: $selection) {
            Text(automatic.map { "Automatic (\($0))" } ?? "Automatic (none found)").tag("")
            if !installed.isEmpty { Divider() }
            ForEach(installed, id: \.id) { app in
                Text(app.name).tag(app.id)
            }
        }
    }
}

private struct FolderSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.scanRoots, id: \.self) { root in
                        Label(Fmt.tilde(root), systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle)
                            .help(root)
                    }
                }
                .frame(minHeight: 120)
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Button("Remove") {
                        settings.scanRoots.removeAll { $0 == selection }
                        selection = nil
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Button("Reset to Defaults") { settings.scanRoots = Cleanup.defaultRoots }
                }
            } header: {
                Text("Clean-up scans these folders")
            } footer: {
                Text("Dashbar looks for node_modules, .next, .turbo, .build and similar caches. Xcode's DerivedData is always included.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.directoryURL = homeDir
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.scanRoots.contains(url.path) {
            settings.scanRoots.append(url.path)
        }
    }
}

/// Other Claude Code and Codex accounts: the folders `CLAUDE_CONFIG_DIR` or `CODEX_HOME` point at.
private struct AccountSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var problem: String?
    @State private var suggestions: [AgentKind: [String]] = [:]

    var body: some View {
        Form {
            section(.claude)
            section(.codex)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            settings.refreshClaudeStatusLine()
            findSuggestions()
        }
    }

    private func accounts(_ kind: AgentKind) -> [ResolvedAccount] {
        kind == .claude ? settings.claudeAccounts : settings.codexAccounts
    }

    @ViewBuilder private func section(_ kind: AgentKind) -> some View {
        Section {
            ForEach(accounts(kind)) { row($0) }
            ForEach(suggestions[kind] ?? [], id: \.self) { path in
                LabeledContent {
                    Button("Add") { add(kind, path) }
                } label: {
                    Text("Found \(Fmt.tilde(path))")
                    Text("It has \(kind.name) logs.")
                }
            }
            Button("Add Folder…") { addFolder(kind) }
        } header: {
            Text("\(kind.name) accounts")
        } footer: {
            Text(kind == .claude
                 ? "Each account is a folder you run Claude Code with, set by CLAUDE_CONFIG_DIR (for example ~/.claude-work). Dashbar reads its sessions and usage, and names them by account once there's more than one. Plan limits come from each account's own status line."
                 : "Each account is a folder you run Codex with, set by CODEX_HOME. Dashbar reads its sessions for usage and limits.")
                .settingsFooter()
        }
    }

    @ViewBuilder private func row(_ account: ResolvedAccount) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: Binding(
                    get: { settings.accounts.first { $0.kind == account.kind && AgentAccounts.normalise($0.path) == account.path }?.label ?? "" },
                    set: { settings.setAccount(account.kind, path: account.path, label: $0) }),
                          prompt: Text(account.label))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Text(Fmt.tilde(account.path) + (account.isDefault ? " · default" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(account.path)
            }
            Spacer(minLength: 8)
            if account.kind == .claude { statusLineButton(account) }
            if !account.isDefault {
                Button {
                    problem = settings.removeAccount(account)
                    findSuggestions()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop reading this account. Its files are left alone.")
                .accessibilityLabel("Remove \(account.label)")
            }
        }
    }

    @ViewBuilder private func statusLineButton(_ account: ResolvedAccount) -> some View {
        let status = account.isDefault ? settings.claudeStatusLineStatus : settings.accountStatusLines[account.path]
        switch status {
        case .installed?:
            Button("Remove from Status Line") { problem = settings.setStatusLine(false, account: account) }
                .help("Puts this account's previous status line back exactly.")
        case .unreadable(let message)?:
            Button("Check Again") { problem = nil; settings.refreshClaudeStatusLine() }
                .help(message)
        default:
            Button("Add to Status Line") { problem = settings.setStatusLine(true, account: account) }
                .help("Reads this account's plan limits after each Claude Code reply. Changes statusLine in \(Fmt.tilde(account.settingsFile.path)), after a backup.")
        }
    }

    private func add(_ kind: AgentKind, _ path: String) {
        settings.setAccount(kind, path: path, label: "")
        findSuggestions()
    }

    private func addFolder(_ kind: AgentKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Add"
        panel.message = "Choose the folder \(kind.variable) points at"
        panel.directoryURL = homeDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(kind, url.path)
    }

    /// `.claude-*` and `.codex-*` folders at the top of the home folder that have logs and aren't added yet.
    private func findSuggestions() {
        var found: [AgentKind: [String]] = [:]
        for kind in AgentKind.allCases {
            found[kind] = AgentAccounts.suggestions(kind, known: accounts(kind).map(\.path))
        }
        suggestions = found
    }
}

private struct AboutSettings: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text(BuildInfo.appName).font(.title2.weight(.semibold))
            Text("Version \(BuildInfo.version)" + (BuildInfo.isLocal ? " (local build)" : ""))
                .foregroundStyle(.secondary)
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
            Text("Everything stays on your Mac. Dashbar reads Claude Code and Codex logs, lists listening ports and measures cache folders. It sends nothing anywhere.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Text("Not affiliated with Anthropic or OpenAI.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Welcome…") { OnboardingWindow.shared.show(store: nil) }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
