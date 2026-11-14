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

struct ContextInfo: Equatable {
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

    /// When a session's transcript wasn't found, so the projects folder isn't listed again on every refresh.
    private var misses: [String: Date] = [:]
    private let missRetry: TimeInterval

    init(projects: URL = ClaudeUsageScanner.defaultRoot, missRetry: TimeInterval = 15) {
        self.projects = projects
        self.missRetry = missRetry
    }
    private let needle = Data("\"usage\"".utf8)

    func read(_ sessions: [LiveSession], now: Date = Date()) -> [String: ContextInfo] {
        var out: [String: ContextInfo] = [:]
        for s in sessions {
            let projects = s.configDir.map { URL(fileURLWithPath: $0).appendingPathComponent("projects") } ?? self.projects
            guard let url = path(for: s.id, in: projects, now: now) else { continue }
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
        misses = misses.filter { live.contains($0.key) }
        return out
    }

    /// The session's transcript, `<projects>/<project>/<sessionId>.jsonl`, when it has been found.
    func transcript(for s: LiveSession, now: Date = Date()) -> URL? {
        let projects = s.configDir.map { URL(fileURLWithPath: $0).appendingPathComponent("projects") } ?? self.projects
        return path(for: s.id, in: projects, now: now)
    }

    private func path(for id: String, in projects: URL, now: Date) -> URL? {
        if let u = paths[id] { return u }
        if let missed = misses[id], now.timeIntervalSince(missed) < missRetry { return nil }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let f = dir.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { paths[id] = f; misses[id] = nil; return f }
        }
        misses[id] = now
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
        return sorted(found.compactMap { item in
            var item = item
            item.size = sizes[item.path] ?? 0
            return item.size > 1_000_000 ? item : nil
        })
    }

    /// Largest first, so the folders worth clearing lead; ties in path order so the list holds still.
    static func sorted(_ items: [CleanupItem]) -> [CleanupItem] {
        items.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    /// The rebuildable folders inside one workspace (its worktrees included), largest first.
    static func items(in root: String, from items: [CleanupItem]) -> [CleanupItem] {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard !base.isEmpty else { return [] }
        return sorted(items.filter { $0.path.hasPrefix(base + "/") })
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

// MARK: - The app a session runs in

/// Which app a Claude session lives in (T3 Code, a terminal, VS Code, the Desktop app), so clicking its notification
/// goes back there instead of to the default editor. Found by walking up the session's parent processes to the nearest
/// app bundle's own executable; helpers nested inside another app (Electron's "… Helper.app") are skipped.
enum HostApp {
    /// The bundle of the nearest app above `pid`, or nil (e.g. under tmux, whose server has no app). The session's own
    /// process is never its host: the Desktop app runs Claude Code from a `claude.app` of its own.
    static func find(for pid: pid_t) -> String? {
        var chain: [String] = []
        var seen: Set<pid_t> = [pid]
        var current = parent(of: pid)
        while let p = current, p > 1, seen.insert(p).inserted {
            if let path = Proc.path(p) { chain.append(path) }
            current = parent(of: p)
        }
        return nearest(in: chain)
    }

    /// The short BSD info works for other users' processes too, such as the root-owned `login` between a terminal and
    /// its shell, where the full info is refused.
    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbsi_ppid)
    }

    /// The first app bundle in executable paths ordered from the process up to its oldest parent.
    static func nearest(in chain: [String]) -> String? {
        chain.lazy.compactMap(mainBundle(of:)).first
    }

    /// "/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)" → "/Applications/T3 Code (Beta).app". Nil for
    /// anything that isn't an app's own executable, including a helper app inside another app's Contents.
    static func mainBundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/Contents/MacOS/") else { return nil }
        let bundle = String(path[..<r.lowerBound]) + ".app"
        return bundle.contains(".app/Contents/") ? nil : bundle
    }

    /// Brings the session back: an editor opens the project (which picks out its window), any other app comes forward.
    /// Without a host app, falls back to the chosen editor, then Finder.
    static func open(_ bundle: String?, root: String) {
        if let bundle, FileManager.default.fileExists(atPath: bundle) {
            let url = URL(fileURLWithPath: bundle)
            let id = Bundle(url: url)?.bundleIdentifier
            if let id, Launcher.editorCandidates.contains(where: { $0.id == id }) {
                Launcher.open(root, in: Launcher.App(url: url, name: url.deletingPathExtension().lastPathComponent))
            } else {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        } else if let editor = Launcher.editor {
            Launcher.open(root, in: editor)
        } else {
            Launcher.reveal(root)
        }
    }
}

extension HostApp {
    struct Info: Equatable {
        /// Nil in demo renders, where the name is invented and clicking falls back to the editor.
        let bundle: String?
        let name: String
    }

    /// "/Applications/T3 Code (Beta).app" → "T3 Code (Beta)".
    static func name(ofBundle bundle: String) -> String {
        let last = URL(fileURLWithPath: bundle).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Demo renders never look at real processes (their invented pids could belong to anything): a plausible host
    /// from the session's entrypoint instead.
    static func demoInfo(entrypoint: String) -> Info? {
        switch entrypoint {
        case "claude-desktop": return Info(bundle: nil, name: "Claude")
        case let e where e.contains("vscode"): return Info(bundle: nil, name: "VS Code")
        case "cli", "": return Info(bundle: nil, name: "Terminal")
        default: return nil
        }
    }

    @MainActor private static var cache: [String: Info?] = [:]
    @MainActor private static let antigravityApp: Info? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.google.antigravity").map { Info(bundle: $0.path, name: "Antigravity") }
    private static let isDemo = CommandLine.arguments.contains("--demo")

    /// The host app for a live session, looked up once per session and process (rows redraw every second).
    @MainActor static func info(for session: LiveSession) -> Info? {
        if isDemo { return demoInfo(entrypoint: session.entrypoint) }
        // The Antigravity app's conversations have no process of their own: they open in the app.
        if session.agent == .antigravity { return antigravityApp }
        let key = session.id + ":" + String(session.pid)
        if let hit = cache[key] { return hit }
        let info = find(for: session.pid).map { Info(bundle: $0, name: name(ofBundle: $0)) }
        if cache.count > 200 { cache.removeAll() }   // ended sessions; cheap to look up again
        cache[key] = info
        return info
    }
}

// MARK: - Quitting a workspace process

/// Which processes the window may offer to quit. Only the user's own, never the system's, and never Dashbar (either
/// copy: the release or a local build), since quitting it from itself would only close the window it was asked in.
enum QuitPolicy {
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    static func allows(pid: pid_t, path: String?, uid: uid_t?, ownPID: pid_t, ownUID: uid_t) -> Bool {
        guard pid > 1, pid != ownPID, let uid, uid == ownUID, uid != 0 else { return false }
        guard let path, !path.isEmpty else { return false }
        if systemPrefixes.contains(where: path.hasPrefix) { return false }
        if path.contains("/Dashbar.app/") || path.contains("/Dashbar Local.app/") { return false }
        return true
    }

    /// For the live system: reads the process's owner and executable now, so a pid that has since been reused by
    /// something else is judged as what it is today.
    static func allows(_ pid: pid_t) -> Bool {
        allows(pid: pid, path: Proc.path(pid), uid: Proc.uid(pid), ownPID: getpid(), ownUID: getuid())
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
        // Permission is asked for from the first run or when a notification toggle is turned on, never at launch.
        // A permission prompt's notification can be answered in place. Allow asks for the Mac to be unlocked.
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow Once", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.permissionCategory, actions: [allow, deny],
                                                                 intentIdentifiers: [], options: [])])
    }

    static let permissionCategory = "dashbar.permission"
    static let allowAction = "dashbar.permission.allow"
    static let denyAction = "dashbar.permission.deny"
    /// Answers a permission request by id (set by the store). `.terminal` hands it back to Claude Code's own prompt.
    var answerPermission: ((String, PermissionRequest.Answer) -> Void)?

    /// "Claude needs permission in shop" with what it wants to do, and Allow Once / Deny on the notification itself.
    func permission(_ r: PermissionRequest, session: LiveSession?, account: String? = nil) {
        guard available, UserDefaults.standard.bool(forKey: Self.waitingKey),
              !Self.islandShows(.permission(requestID: r.id)) else { return }
        let content = UNMutableNotificationContent()
        content.title = session?.name ?? (r.project.isEmpty ? "Claude Code" : r.project)
        content.subtitle = "Claude needs permission" + (r.project.isEmpty ? "" : " in \(r.project)") + (account.map { " (\($0))" } ?? "")
        content.body = r.oneLine
        content.sound = .default
        content.categoryIdentifier = Self.permissionCategory
        var info: [String: Any] = session.map(userInfo(for:)) ?? ["root": r.cwd.isEmpty ? homeDir.path : Fmt.root(fromCwd: r.cwd)]
        info["permission"] = r.id
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.permissionID(r.id), content: content, trigger: nil))
    }

    /// Takes a request's notification away once it's answered, handed back or timed out.
    func removePermission(_ id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.permissionID(id)])
    }

    private static func permissionID(_ id: String) -> String { "permission-" + id }

    func finished(_ s: LiveSession, after duration: TimeInterval) {
        guard available, UserDefaults.standard.bool(forKey: Self.defaultsKey), !Self.islandShows(.finished(after: duration)) else { return }
        let content = UNMutableNotificationContent()
        content.title = s.name
        content.body = "\(s.agent.name) finished in \(s.project) after \(Fmt.ago(Date().addingTimeInterval(-duration)))"
            + (s.account.map { " · \($0)" } ?? "")
        content.sound = .default
        content.userInfo = userInfo(for: s)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + "-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    func waiting(_ s: LiveSession) {
        guard available, UserDefaults.standard.bool(forKey: Self.waitingKey), !Self.islandShows(.waiting) else { return }
        let content = UNMutableNotificationContent()
        content.title = s.name
        content.body = "\(s.waitingSentence) in \(s.project)." + (s.account.map { " (\($0))" } ?? "")
        content.sound = .default
        content.userInfo = userInfo(for: s)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + "-waiting-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    /// "Use the island instead of notifications": the island shows this moment, so the banner would only repeat it.
    private static func islandShows(_ kind: IslandBanner.Kind) -> Bool {
        IslandSettings.Values.read().suppressesNotification(for: kind)
    }

    /// The project, and the app the session runs in, found now while its process is still there.
    private func userInfo(for s: LiveSession) -> [String: Any] {
        var info: [String: Any] = ["root": s.root]
        if let host = HostApp.find(for: s.pid) { info["hostApp"] = host }
        return info
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
        let info = response.notification.request.content.userInfo
        if let id = info["permission"] as? String {
            switch response.actionIdentifier {
            case Self.allowAction:
                DispatchQueue.main.async { [weak self] in self?.answerPermission?(id, .allow) }
                completionHandler()
                return
            case Self.denyAction:
                DispatchQueue.main.async { [weak self] in self?.answerPermission?(id, .deny) }
                completionHandler()
                return
            case UNNotificationDefaultActionIdentifier:
                // Clicked rather than answered: hand the prompt back to Claude Code and open the session, as for any
                // "needs you" notification.
                DispatchQueue.main.async { [weak self] in self?.answerPermission?(id, .terminal) }
            default:
                completionHandler()   // dismissed: the request keeps waiting in Dashbar
                return
            }
        }
        if info["limits"] as? Bool == true {
            DispatchQueue.main.async { [weak self] in self?.openLimits?() }
        } else if let root = response.notification.request.content.userInfo["root"] as? String {
            let host = response.notification.request.content.userInfo["hostApp"] as? String
            DispatchQueue.main.async { HostApp.open(host, root: root) }
        }
        completionHandler()
    }
}
