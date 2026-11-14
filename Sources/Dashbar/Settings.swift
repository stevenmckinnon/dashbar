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
        static let claudeLimits = "claudeLimitsExperimental"
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
    /// What's left of the Claude plan limit, beside the icon. Needs the Labs plan-limits setting.
    @Published var menuLimit: Bool { didSet { defaults.set(menuLimit, forKey: Key.menuLimit) } }
    /// Experimental: read Claude Code's sign-in to show plan limits. Off by default.
    @Published var claudeLimits: Bool { didSet { defaults.set(claudeLimits, forKey: Key.claudeLimits) } }
    /// Dashbar's bridge is in Claude Code's status line. Not a preference: it mirrors Claude Code's settings file,
    /// re-read at launch, every few minutes and when Settings opens, since the user can change that file any time.
    @Published private(set) var claudeStatusLine = false
    @Published private(set) var claudeStatusLineStatus: StatusLineBridge.Status = .notInstalled(current: nil)

    /// Dashbar's hook is in Claude Code's PermissionRequest hooks, so Dashbar can answer permission prompts. Like the
    /// status line, this mirrors Claude Code's settings file rather than being a preference.
    @Published private(set) var claudePermissions = false
    @Published private(set) var claudePermissionsStatus: PermissionBridge.Status = .notInstalled
    /// How long the hook waits for an answer in Dashbar before Claude Code asks in the terminal.
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
    }

    /// Adds or removes Dashbar's bridge in Claude Code's status line. Returns what went wrong, phrased for the user.
    func setClaudeStatusLine(_ on: Bool, paths: StatusLineBridge.Paths = .default()) -> String? {
        var problem: String?
        do { on ? try StatusLineBridge.install(paths) : try StatusLineBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refreshClaudeStatusLine(paths: paths)
        return problem
    }

    /// Re-reads whether Dashbar's permission hook is in Claude Code's settings, and refreshes its script if it is.
    func refreshClaudePermissions(paths: PermissionBridge.Paths = .default()) {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let status = PermissionBridge.status(paths)
        if status.isInstalled {
            try? PermissionBridge.writeScript(paths)
            try? PermissionBridge.prepareQueue(paths)
        }
        if status != claudePermissionsStatus { claudePermissionsStatus = status }
        if status.isInstalled != claudePermissions { claudePermissions = status.isInstalled }
    }

    /// Adds or removes Dashbar's permission hook. Returns what went wrong, phrased for the user.
    func setClaudePermissions(_ on: Bool, paths: PermissionBridge.Paths = .default()) -> String? {
        var problem: String?
        do { on ? try PermissionBridge.install(paths) : try PermissionBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refreshClaudePermissions(paths: paths)
        return problem
    }

    private init() {
        defaults.register(defaults: [
            Key.refreshSeconds: 3.0, Key.showNow: true, Key.showWidgets: true, Key.showServers: true,
            Notifier.defaultsKey: true, Key.permissionWait: PermissionBridge.defaultWait,
        ])
        permissionWait = defaults.integer(forKey: Key.permissionWait)
        scanRoots = defaults.stringArray(forKey: Key.scanRoots) ?? Cleanup.defaultRoots
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
        // Demo renders show the plan limits without reading the Keychain; assigning here skips `didSet`, so nothing is saved.
        claudeLimits = defaults.bool(forKey: Key.claudeLimits) || CommandLine.arguments.contains("--demo")
        if CommandLine.arguments.contains("--demo") { menuLimit = true }
    }
}

// MARK: - Settings window

/// Settings' tabs. The selected one is saved under `key`, which is how every "Settings…" link opens Settings at a tab.
enum SettingsTab: String {
    static let key = "settingsTab"
    case general, menuBar, folders, labs, about
}

/// The one way to open Settings at a tab. Settings opens through SwiftUI's `openSettings`, which only works from a view
/// inside one of the app's scenes: views pass their own (`SettingsButton`), and the menu bar label hands its over when it
/// appears (`capturesSettingsOpener`), so AppKit windows such as the first run can open Settings too.
@MainActor
enum SettingsOpener {
    static var action: OpenSettingsAction?

    static func open(_ tab: SettingsTab, using openSettings: OpenSettingsAction? = nil) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key)
        NSApp.activate(ignoringOtherApps: true)
        if let open = openSettings ?? action { open() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }
}

extension View {
    /// Hands this scene's `openSettings` to `SettingsOpener`.
    func capturesSettingsOpener() -> some View { modifier(CaptureSettingsOpener()) }
}

private struct CaptureSettingsOpener: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onAppear { SettingsOpener.action = openSettings }
    }
}

/// "Settings…" that opens on the tab where the setting lives, rather than wherever Settings was left.
struct SettingsButton<Label: View>: View {
    let tab: SettingsTab
    @ViewBuilder var label: Label
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { SettingsOpener.open(tab, using: openSettings) } label: { label }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }.tag(SettingsTab.menuBar)
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }.tag(SettingsTab.folders)
            LabsSettings().tabItem { Label("Labs", systemImage: "flask") }.tag(SettingsTab.labs)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 440)
        .onAppear {
            // An accessory app's windows open behind the frontmost app unless we activate.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(Notifier.defaultsKey) private var notify = true
    @AppStorage(Notifier.limitsKey) private var notifyLimits = true
    @AppStorage(Notifier.waitingKey) private var notifyWaiting = true
    @AppStorage(GlobalShortcut.enabledKey) private var shortcut = true
    @AppStorage(CostLine.showKey) private var showCost = true
    @State private var shortcutUnavailable = GlobalShortcut.shared.unavailable
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Overview shows") {
                Toggle("Current workspace", isOn: $settings.showNow)
                Toggle("Today and this week", isOn: $settings.showWidgets)
                Toggle("Servers outside projects", isOn: $settings.showServers)
            }
            Section("Usage") {
                Toggle("Estimated cost at API prices", isOn: $showCost)
                    .help("Works out what your tokens would cost on the pay-as-you-go API at list prices. On a plan you pay the plan's price, not this.")
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
            Section {
                Toggle("Notify when an agent finishes", isOn: $notify)
                Toggle("Notify when an agent needs you", isOn: $notifyWaiting)
                    .help("When Claude stops to ask for permission or an answer.")
                Toggle("Notify when a plan limit runs low", isOn: $notifyLimits)
                    .help("At 80%, when it's on course to run out before it resets, and when it's used up. Once per window.")
                NotificationPermissionNote(wanted: notify || notifyWaiting || notifyLimits)
                Toggle("Open the window with \(GlobalShortcut.display)", isOn: $shortcut)
                    .onChange(of: shortcut) { _, on in
                        GlobalShortcut.shared.setEnabled(on)
                        shortcutUnavailable = GlobalShortcut.shared.unavailable
                    }
                if shortcut && shortcutUnavailable {
                    Text("Another app is using \(GlobalShortcut.display), so it won't open Dashbar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        // Turning a notification on is when macOS is asked, never at launch.
        .onChange(of: [notify, notifyWaiting, notifyLimits]) { old, new in
            if zip(old, new).contains(where: { !$0 && $1 }) { NotificationPermission.shared.request() }
        }
    }
}

private struct MenuBarSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("CPU", isOn: $settings.menuCPU)
                Toggle("Memory", isOn: $settings.menuMemory)
                Toggle("Download speed", isOn: $settings.menuNetwork)
                Toggle("Claude plan left", isOn: $settings.menuLimit)
                    .disabled(!settings.showsClaudeLimits)
            } header: {
                Text("Show beside the icon")
            } footer: {
                Text("The count of working agents always shows."
                     + (settings.showsClaudeLimits ? " Claude plan left shows a warning symbol when you're nearly out or on course to run out."
                                                   : " Claude plan left needs Claude plan limits, in Labs."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LabsSettings: View {
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
                Text(statusLineExplanation).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Also ask Anthropic with Claude Code's sign-in", isOn: $settings.claudeLimits)
            } footer: {
                Text("Experimental, and only needed if you'd rather not change Claude Code's status line. Reads Claude Code's sign-in from your Keychain, the same way Claude Code does, and asks an undocumented endpoint that may change. Never refreshes or saves the sign-in. When both are on, Dashbar shows the newer reading.")
                    .foregroundStyle(.secondary)
            }
            Section {
                permissionsRow
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
                Text(permissionsExplanation).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            settings.refreshClaudeStatusLine()
            settings.refreshClaudePermissions()
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

    private var permissionsExplanation: String {
        let file = Fmt.tilde(PermissionBridge.Paths.default().settings.path)
        return "Adding this puts one hook, PermissionRequest, in \(file), pointing at a small script. When Claude Code is about "
            + "to ask you to allow a tool, Dashbar shows what it wants to do, with Allow once and Deny. Dashbar can only answer "
            + "prompts Claude Code already shows you, never changes your permission rules and never answers by itself. If you "
            + "don't answer in time, or Dashbar isn't running, Claude Code asks in the terminal as usual. While Dashbar waits, "
            + "the terminal's prompt may hold back; Open Session hands it straight back. Requests stay in a folder only you can "
            + "read, and nothing is sent anywhere. A backup of the file is kept, and Remove takes out only Dashbar's hook."
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
            + "Adding Dashbar changes one setting, statusLine in \(file), to a small script that saves just those numbers "
            + "to a file on this Mac, then runs the status line you had, so it looks the same. A backup of the file is kept. "
            + "No network, no Keychain. Remove puts your previous status line back exactly."
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
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
