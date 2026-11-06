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
        static let claudeLimits = "claudeLimitsExperimental"
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
    /// Experimental: read Claude Code's sign-in to show plan limits. Off by default.
    @Published var claudeLimits: Bool { didSet { defaults.set(claudeLimits, forKey: Key.claudeLimits) } }

    var showsMenuBarStats: Bool { menuCPU || menuMemory || menuNetwork }

    private init() {
        defaults.register(defaults: [
            Key.refreshSeconds: 3.0, Key.showNow: true, Key.showWidgets: true, Key.showServers: true,
            Notifier.defaultsKey: true,
        ])
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
        claudeLimits = defaults.bool(forKey: Key.claudeLimits)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
            LabsSettings().tabItem { Label("Labs", systemImage: "flask") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Overview shows") {
                Toggle("Current workspace", isOn: $settings.showNow)
                Toggle("Today and this week", isOn: $settings.showWidgets)
                Toggle("Servers outside projects", isOn: $settings.showServers)
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
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
            } header: {
                Text("Show beside the icon")
            } footer: {
                Text("The count of working agents always shows.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LabsSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show Claude plan limits", isOn: $settings.claudeLimits)
            } footer: {
                Text("Reads Claude Code's sign-in from your Keychain (macOS asks first) to show your 5-hour and weekly limits. Uses an undocumented endpoint that may change. Never refreshes or saves the sign-in.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("Dashbar").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Everything stays on your Mac. Dashbar reads Claude Code and Codex logs, lists listening ports and measures cache folders. It sends nothing anywhere.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Text("Not affiliated with Anthropic or OpenAI.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
