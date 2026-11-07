import Foundation
import AppKit
import UserNotifications

// MARK: - Workspaces: agents + servers grouped by repo

struct Workspace: Identifiable {
    var id: String { root }
    let root: String
    var sessions: [LiveSession] = []
    var servers: [Listener] = []

    var name: String { URL(fileURLWithPath: root).lastPathComponent }
    var isBusy: Bool { sessions.contains(where: \.isBusy) }
    var isWaiting: Bool { sessions.contains(where: \.isWaiting) }
    /// Same order as sessions: waiting, then working, then the rest.
    var urgency: Int { sessions.map(\.urgency).min() ?? 2 }
    var ports: [Int] { Array(Set(servers.map(\.port))).sorted() }
    /// Counted once per process, since one process can listen on several ports.
    var memory: UInt64 { Dictionary(grouping: servers, by: \.pid).values.reduce(0) { $0 + ($1.first?.memory ?? 0) } }

    func matches(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        let port = q.hasPrefix(":") ? String(q.dropFirst()) : q
        return name.lowercased().contains(q)
            || sessions.contains { $0.name.lowercased().contains(q) }
            || servers.contains { String($0.port).hasPrefix(port) || $0.hint.lowercased().contains(q) }
    }

    static func build(sessions: [LiveSession], servers: [Listener]) -> [Workspace] {
        var map: [String: Workspace] = [:]
        for s in sessions { map[s.root, default: Workspace(root: s.root)].sessions.append(s) }
        for l in servers { if let r = l.root { map[r, default: Workspace(root: r)].servers.append(l) } }
        return map.values.sorted {
            ($0.urgency, $0.sessions.isEmpty ? 1 : 0, $0.name.lowercased())
                < ($1.urgency, $1.sessions.isEmpty ? 1 : 0, $1.name.lowercased())
        }
    }
}

// MARK: - Context window fill per live session

struct ContextInfo {
    let used: Int
    let window: Int
    var fraction: Double { min(1, Double(used) / Double(max(window, 1))) }

    /// Context window for a model ID. Every current Claude model has 1M tokens; Haiku 4.5 and models
    /// before the 4.6 generation have 200K unless Claude Code reports the 1M variant ("[1m]").
    /// Usage already past the window proves the larger one.
    static func window(model: String, used: Int) -> Int {
        let large = 1_000_000, standard = 200_000
        if model.contains("[1m]") || used > standard { return large }
        // claude-<family>-<major>[-<minor>][-<date>]
        let parts = model.lowercased().split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 3 else { return large }
        if Int(parts[1]) != nil { return standard }      // old "claude-3-7-sonnet" naming: pre-4.6
        guard let major = Int(parts[2]) else { return large }
        let minor = parts.count > 3 && parts[3].count <= 2 ? Int(parts[3]) ?? 0 : 0
        let family = parts[1]
        if family == "haiku" { return major >= 5 ? large : standard }
        return (major > 4 || (major == 4 && minor >= 6)) ? large : standard
    }
}

/// Reads the last assistant turn of each live session's transcript to measure context fill,
/// against the window of the model that turn used (see `ContextInfo.window`).
final class ContextReader {
    private var paths: [String: URL] = [:]
    private let projects: URL
    /// Last result per transcript, reused while the file's size and mtime are unchanged.
    private var cached: [String: (size: UInt64, mtime: Date, info: ContextInfo?)] = [:]

    init(projects: URL = ClaudeUsageScanner.defaultRoot) { self.projects = projects }
    private let needle = Data("\"usage\"".utf8)

    func read(_ sessions: [LiveSession]) -> [String: ContextInfo] {
        var out: [String: ContextInfo] = [:]
        for s in sessions {
            guard let url = path(for: s.id) else { continue }
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(rv?.fileSize ?? 0), mtime = rv?.contentModificationDate ?? .distantPast
            if let hit = cached[s.id], hit.size == size, hit.mtime == mtime {
                if let info = hit.info { out[s.id] = info }
                continue
            }
            let info = lastContext(url)
            cached[s.id] = (size, mtime, info)
            if let info { out[s.id] = info }
        }
        let live = Set(sessions.map(\.id))
        cached = cached.filter { live.contains($0.key) }
        return out
    }

    private func path(for id: String) -> URL? {
        if let u = paths[id] { return u }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let f = dir.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { paths[id] = f; return f }
        }
        return nil
    }

    private func lastContext(_ url: URL) -> ContextInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let tailSize: UInt64 = 512 * 1024
        try? h.seek(toOffset: size > tailSize ? size - tailSize : 0)
        guard let data = try? h.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() where line.range(of: needle) != nil {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["type"] as? String == "assistant", (o["isSidechain"] as? Bool) != true,
                  let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
            let used = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                + (u["cache_creation_input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
            let model = m["model"] as? String ?? ""
            return ContextInfo(used: used, window: ContextInfo.window(model: model, used: used))
        }
        return nil
    }
}

// MARK: - Clean up: build caches and dependency folders

struct CleanupItem: Identifiable {
    var id: String { path }
    let path: String
    let kind: String
    let project: String
    var size: UInt64
}

enum Cleanup {
    static let targets: Set<String> = [
        "node_modules", ".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache", ".build", ".expo", ".angular",
    ]

    /// Folders scanned when the user hasn't chosen any: the usual places people keep code.
    static var defaultRoots: [String] {
        let candidates = ["Development", "Developer", "Projects", "Code", "code", "src", "dev"].map { homeDir.appendingPathComponent($0).path }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0) }
        return existing.isEmpty ? [homeDir.appendingPathComponent("Development").path] : existing
    }

    static func scan(roots: [URL], includeDerivedData: Bool = true) -> [CleanupItem] {
        var found: [CleanupItem] = []
        for root in roots { found += findTargets(in: root) }
        let derived = homeDir.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if includeDerivedData, FileManager.default.fileExists(atPath: derived.path) {
            found.append(CleanupItem(path: derived.path, kind: "DerivedData", project: "Xcode", size: 0))
        }
        return measure(found)
    }

    private static func findTargets(in root: URL) -> [CleanupItem] {
        var found: [CleanupItem] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) {
            for case let url as URL in en {
                guard let rv = try? url.resourceValues(forKeys: Set(keys)), rv.isDirectory == true, rv.isSymbolicLink != true else { continue }
                let name = url.lastPathComponent
                if targets.contains(name) {
                    found.append(CleanupItem(path: url.path, kind: name, project: projectLabel(url.deletingLastPathComponent().path, root: root), size: 0))
                    en.skipDescendants()
                } else if (name.hasPrefix(".") && name != ".claude") || en.level >= 6 {
                    en.skipDescendants()
                }
            }
        }
        return found
    }

    private static func measure(_ found: [CleanupItem]) -> [CleanupItem] {
        guard !found.isEmpty else { return [] }

        var sizes: [String: UInt64] = [:]
        for line in Shell.run("/usr/bin/du", ["-sk"] + found.map(\.path)).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, let kb = UInt64(parts[0]) { sizes[String(parts[1])] = kb * 1024 }
        }
        return found.compactMap { item in
            var item = item
            item.size = sizes[item.path] ?? 0
            return item.size > 1_000_000 ? item : nil
        }.sorted { $0.size > $1.size }
    }

    private static func projectLabel(_ parent: String, root: URL) -> String {
        if let r = parent.range(of: "/.claude/worktrees/") {
            let repo = URL(fileURLWithPath: String(parent[..<r.lowerBound])).lastPathComponent
            let tree = parent[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            return "\(repo) · \(tree)"
        }
        let base = root.standardizedFileURL.path
        if parent == base { return root.lastPathComponent }
        return parent.hasPrefix(base + "/") ? String(parent.dropFirst(base.count + 1)) : URL(fileURLWithPath: parent).lastPathComponent
    }
}

// MARK: - Opening things

enum Launcher {
    struct App { let url: URL; let name: String }

    static let editorCandidates: [(id: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"), ("com.microsoft.VSCode", "VS Code"), ("dev.zed.Zed", "Zed"),
        ("dev.kiro.desktop", "Kiro"), ("com.exafunction.windsurf", "Windsurf"), ("com.jetbrains.WebStorm", "WebStorm"),
        ("com.sublimetext.4", "Sublime Text"), ("com.apple.dt.Xcode", "Xcode"),
    ]
    static let terminalCandidates: [(id: String, name: String)] = [
        ("com.mitchellh.ghostty", "Ghostty"), ("com.googlecode.iterm2", "iTerm"), ("dev.warp.Warp-Stable", "Warp"),
        ("net.kovidgoyal.kitty", "kitty"), ("com.github.wez.wezterm", "WezTerm"), ("com.apple.Terminal", "Terminal"),
    ]

    /// The user's chosen editor, else the first installed candidate.
    static var editor: App? { resolve(UserDefaults.standard.string(forKey: AppSettings.Key.editorID), editorCandidates) }
    static var terminal: App? { resolve(UserDefaults.standard.string(forKey: AppSettings.Key.terminalID), terminalCandidates) }

    static func installed(_ candidates: [(id: String, name: String)]) -> [(id: String, name: String)] {
        candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    static func open(_ path: String, in app: App) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    static func browse(port: Int) {
        if let url = URL(string: "http://localhost:" + String(port)) { NSWorkspace.shared.open(url) }
    }

    private static func resolve(_ chosen: String?, _ candidates: [(id: String, name: String)]) -> App? {
        if let chosen, !chosen.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) {
            let name = candidates.first { $0.id == chosen }?.name ?? url.deletingPathExtension().lastPathComponent
            return App(url: url, name: name)
        }
        for c in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.id) { return App(url: url, name: c.name) }
        }
        return nil
    }
}

// MARK: - Notifications: agent finished, plan limit running low

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let defaultsKey = "notifyOnFinish"
    static let limitsKey = "notifyOnLimits"
    static let waitingKey = "notifyOnWaiting"
    /// Opens the plan limits (set by the store). Called when a limit notification is clicked.
    var openLimits: (() -> Void)?
    /// UNUserNotificationCenter crashes outside an .app bundle (e.g. `swift run`, snapshots).
    private let available = Bundle.main.bundleURL.pathExtension == "app"

    func setup() {
        guard available else { return }
        UserDefaults.standard.register(defaults: [Self.defaultsKey: true, Self.limitsKey: true, Self.waitingKey: true])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func finished(_ s: LiveSession, after duration: TimeInterval) {
        guard available, UserDefaults.standard.bool(forKey: Self.defaultsKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = s.name
        content.body = "Claude finished in \(s.project) after \(Fmt.ago(Date().addingTimeInterval(-duration)))"
        content.sound = .default
        content.userInfo = ["root": s.root]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + "-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    func waiting(_ s: LiveSession) {
        guard available, UserDefaults.standard.bool(forKey: Self.waitingKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = s.name
        content.body = "\(s.waitingSentence) in \(s.project)."
        content.sound = .default
        content.userInfo = ["root": s.root]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + "-waiting-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    func limit(_ alert: LimitAlert) {
        guard available, UserDefaults.standard.bool(forKey: Self.limitsKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.userInfo = ["limits": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.sentKey, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["limits"] as? Bool == true {
            DispatchQueue.main.async { [weak self] in self?.openLimits?() }
        } else if let root = response.notification.request.content.userInfo["root"] as? String {
            DispatchQueue.main.async {
                if let editor = Launcher.editor { Launcher.open(root, in: editor) } else { Launcher.reveal(root) }
            }
        }
        completionHandler()
    }
}
