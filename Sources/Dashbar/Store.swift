import Foundation
import Combine
import Darwin
import AppKit

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [LiveSession] = []
    @Published var otherAgents: [AgentProcess] = []
    @Published var claude = UsageSummary.empty
    @Published var codex = UsageSummary.empty
    @Published var codexLimits: [RateLimit] = []
    @Published var listeners: [Listener] = []
    /// What each agent session started, keyed by the session's process ID.
    @Published var spawned: [Int32: SpawnedProcesses] = [:]
    @Published var contexts: [String: ContextInfo] = [:]
    @Published var system = SystemSnapshot()
    @Published var cpuHistory: [Double] = []
    @Published var cleanup: [CleanupItem] = []
    @Published var cleanupScanned = false
    @Published var lastUpdated = Date()
    @Published var usageLoading = true
    @Published var paused = false
    @Published var topApps: [AppUsage] = []
    @Published var history = SystemHistory()
    @Published var claudePlan: ClaudePlanLimits.Result?
    @Published var claudePlanLoading = false
    /// Claude Code is running to refresh its own sign-in.
    @Published var claudeSigningIn = false
    /// A failed user action, phrased with what to do next. Shown until dismissed.
    @Published var notice: String?

    var busyCount: Int { sessions.filter(\.isBusy).count }
    var devListeners: [Listener] { listeners.filter(\.isDev) }
    var otherListeners: [Listener] { listeners.filter { !$0.isDev } }
    /// Dev servers that belong to a repo appear inside workspaces…
    var workspaces: [Workspace] {
        Workspace.build(sessions: sessions, servers: devListeners.filter { $0.root != nil && !$0.isDocker })
    }
    /// …the rest (Docker, servers started from / or ~) are listed on their own.
    var looseServers: [Listener] { devListeners.filter { $0.root == nil || $0.isDocker } }
    var serverMemory: UInt64 {
        Dictionary(grouping: devListeners, by: \.pid).values.reduce(0) { $0 + ($1.first?.memory ?? 0) }
    }
    var cleanupTotal: UInt64 { cleanup.reduce(0) { $0 + $1.size } }

    /// The workspace worth featuring: one with a working agent, else the one whose agent changed state most recently.
    var featured: Workspace? {
        let ws = workspaces
        if let busy = ws.first(where: \.isBusy) { return busy }
        return ws.filter { !$0.sessions.isEmpty }.max {
            ($0.sessions.map(\.since).max() ?? .distantPast) < ($1.sessions.map(\.since).max() ?? .distantPast)
        }
    }

    private let worker = Worker()
    private let notifier = Notifier()
    private let settings = AppSettings.shared
    private var busySince: [String: Date] = [:]
    private var tick = 0
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var watcher: FileWatcher?
    /// Which windows (the menu bar panel, the popout) are on screen, as reported by their views. Closed until one opens.
    private var visibleSurfaces = Set<String>()
    private var panelVisible: Bool { !visibleSurfaces.isEmpty }
    /// Demo stores hold invented data and never collect anything.
    private var isDemo = false

    /// `demo` fills the store with invented data and starts nothing: no scanning, timers, watchers or
    /// Keychain access. Used for README and website screenshots (`Dashbar --snapshot out.png --demo`).
    init(demo: Bool = false) {
        if demo {
            isDemo = true
            DemoData.apply(to: self)
            return
        }
        notifier.setup()
        refresh(usage: true, servers: true, panel: true)
        scanCleanup()
        startTimer()
        // Agent logs and session files change as agents work: react to that instead of polling.
        watcher = FileWatcher(paths: [ClaudeUsageScanner.defaultRoot.path, ClaudeSessions.defaultDir.path,
                                      CodexUsageScanner.defaultRoot.path],
                              latency: 1.5, queue: .main) { [weak self] in
            Task { @MainActor in self?.filesChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.worker.saveNow() }
        }
        settings.$refreshSeconds.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.startTimer() } }
            .store(in: &subscriptions)
        settings.$claudeLimits.removeDuplicates()
            .sink { [weak self] on in
                Task { @MainActor in
                    if on { self?.refreshClaudePlan(force: true) } else { self?.claudePlan = nil }
                }
            }
            .store(in: &subscriptions)
        settings.$scanRoots.dropFirst().removeDuplicates()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scanCleanup() }
            .store(in: &subscriptions)
    }

    private func startTimer() {
        timer?.invalidate()
        tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    /// While the panel is open: live data every tick and servers about every 6s.
    /// While it's closed only the menu bar badge matters, and the file watcher keeps that current,
    /// so the timer just runs a light safety refresh each minute. Usage also comes from the watcher.
    private func onTick() {
        guard !paused else { return }
        tick += 1
        let base = settings.refreshSeconds
        let every = { (seconds: Double) in max(1, Int((seconds / base).rounded())) }
        let minute = tick % every(60) == 0
        if panelVisible {
            refresh(usage: minute, servers: tick % every(6) == 0, panel: true)
        } else if settings.showsMenuBarStats {
            refresh(usage: minute, servers: false, panel: false, system: true)   // keep menu bar numbers live
        } else if minute {
            refresh(usage: true, servers: false, panel: false)
        }
        if tick % every(300) == 0 { refreshClaudePlan() }   // every 5 minutes
        if minute { watcher?.restart() }            // pick up folders created since launch
        if tick % every(600) == 0 { scanCleanup() }
    }

    private func filesChanged() {
        guard !paused else { return }
        refresh(usage: true, servers: false, panel: panelVisible)
    }

    /// Each window reports on its own, so closing one doesn't pause updates for the other.
    func setPanelVisible(_ visible: Bool, surface: String = "panel") {
        guard !isDemo else { return }
        let wasVisible = panelVisible
        if visible { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
        guard panelVisible != wasVisible else { return }
        if visible && !paused {
            refresh(usage: false, servers: true, panel: true)   // fresh on open
            if let fetched = claudePlan?.fetchedAt, Date().timeIntervalSince(fetched) > 120 { refreshClaudePlan() }
        }
    }

    func refreshNow() {
        guard !isDemo else { return }
        refresh(usage: true, servers: true, panel: true)
        refreshClaudePlan(force: true)
    }

    /// Experimental Claude plan limits, only while the user has opted in.
    /// Has Claude Code refresh its sign-in, then loads the plan limits again.
    func refreshClaudeSignIn() {
        guard !isDemo, settings.claudeLimits, !claudeSigningIn else { return }
        claudeSigningIn = true
        Task.detached(priority: .utility) {
            let problem = await ClaudePlanLimits.refreshSignIn()
            await MainActor.run {
                self.claudeSigningIn = false
                if let problem { self.claudePlan = ClaudePlanLimits.Result(plan: self.claudePlan?.plan, problem: problem) }
                else { self.refreshClaudePlan(force: true) }
            }
        }
    }

    func refreshClaudePlan(force: Bool = false) {
        guard !isDemo else { return }
        guard settings.claudeLimits, !claudePlanLoading else { return }
        if !force, let fetched = claudePlan?.fetchedAt, Date().timeIntervalSince(fetched) < 60 { return }
        claudePlanLoading = true
        Task.detached(priority: .utility) {
            let result = await ClaudePlanLimits.fetch()
            await MainActor.run {
                self.claudePlanLoading = false
                if self.settings.claudeLimits { self.claudePlan = result }
            }
        }
    }

    func stop(_ l: Listener) {
        guard kill(l.pid, SIGTERM) == 0 else {
            let port = String(l.port)
            notice = errno == EPERM
                ? "Couldn't stop :\(port) because it belongs to another user. Stop it from Terminal with sudo kill \(l.pid)."
                : "Couldn't stop :\(port). It may have already exited, so refresh to check."
            return
        }
        listeners.removeAll { $0.pid == l.pid }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(usage: false, servers: true, panel: true) }
    }

    func scanCleanup() {
        guard !isDemo else { return }
        let roots = settings.scanRoots.map { URL(fileURLWithPath: $0) }
        worker.scanCleanup(roots: roots) { [weak self] items in
            self?.cleanup = items
            self?.cleanupScanned = true
        }
    }

    /// Moves to the Trash (recoverable), never deletes outright.
    func trash(_ item: CleanupItem) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            cleanup.removeAll { $0.id == item.id }
        } catch {
            notice = "Couldn't move \(item.kind) in \(item.project) to the Trash. Check you can edit that folder in Finder, then try again."
        }
    }

    private func trackTransitions(_ new: [LiveSession]) {
        let now = Date()
        for s in new {
            if s.isBusy {
                if busySince[s.id] == nil { busySince[s.id] = now }
            } else if let start = busySince.removeValue(forKey: s.id), now.timeIntervalSince(start) >= 20 {
                notifier.finished(s, after: now.timeIntervalSince(start))
            }
        }
        let live = Set(new.map(\.id))
        busySince = busySince.filter { live.contains($0.key) }
    }

    /// `panel` adds what only the open panel shows (other agent processes, busiest apps) and implies `system`.
    /// `system` samples CPU, memory, network, GPU and battery, which the menu bar stats also need.
    private func refresh(usage: Bool, servers: Bool, panel: Bool, system: Bool = false) {
        guard !isDemo else { return }
        worker.collect(usage: usage, servers: servers, panel: panel, system: system || panel) { [weak self] r in
            guard let self else { return }
            self.trackTransitions(r.sessions)
            self.sessions = r.sessions
            self.contexts = r.contexts
            if let a = r.agents { self.otherAgents = a }
            if let sys = r.system {
                self.system = sys
                self.cpuHistory = Array((self.cpuHistory + [sys.cpu]).suffix(40))
                self.history.append(sys)
            }
            if let apps = r.topApps { self.topApps = apps }
            if let l = r.listeners { self.listeners = l }
            if let s = r.spawned { self.spawned = s }
            if let c = r.claude { self.claude = c; self.usageLoading = false }
            if let c = r.codex { self.codex = c; self.codexLimits = r.codexLimits }
            self.lastUpdated = Date()
        }
    }
}

/// Owns all collectors and runs them on background queues.
final class Worker: @unchecked Sendable {
    struct Result {
        var sessions: [LiveSession] = []
        var contexts: [String: ContextInfo] = [:]
        var agents: [AgentProcess]?
        var system: SystemSnapshot?
        var topApps: [AppUsage]?
        var listeners: [Listener]?
        var spawned: [Int32: SpawnedProcesses]?
        var claude: UsageSummary?
        var codex: UsageSummary?
        var codexLimits: [RateLimit] = []
    }

    private let queue = DispatchQueue(label: "dashbar.worker", qos: .utility)
    private let cleanupQueue = DispatchQueue(label: "dashbar.cleanup", qos: .background)
    // Created on the worker queue at first use, so loading saved progress never blocks the main thread.
    private lazy var claudeScanner = ClaudeUsageScanner(cache: ScanCache<ClaudeUsageScanner.State>.defaultURL("claude-usage.json"))
    private lazy var codexScanner = CodexUsageScanner(cache: ScanCache<CodexUsageScanner.State>.defaultURL("codex-usage.json"))
    private let contextReader = ContextReader()
    private let sampler = SystemSampler()
    private let serverActivity = ServerActivity()
    private var lastSave = Date()

    func collect(usage: Bool, servers: Bool, panel: Bool, system: Bool, done: @escaping @MainActor (Result) -> Void) {
        queue.async { [self] in
            var r = Result()
            r.sessions = ClaudeSessions.read()
            r.contexts = contextReader.read(r.sessions)
            if system { r.system = sampler.sample() }
            if panel {
                r.agents = AgentProcesses.read()
                r.topApps = sampler.topApps()
            }
            if servers {
                var listeners = Listeners.read()
                serverActivity.annotate(&listeners)
                r.spawned = ProcessTree.spawned(sessions: r.sessions, listeners: &listeners)
                r.listeners = listeners
            }
            if usage {
                r.claude = claudeScanner.scan()
                r.codex = codexScanner.scan()
                r.codexLimits = codexScanner.limits
                if Date().timeIntervalSince(lastSave) > 30 { save() }
            }
            let result = r
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Saves scan progress immediately; called as the app quits.
    func saveNow() { queue.sync { save() } }

    private func save() {
        claudeScanner.save()
        codexScanner.save()
        lastSave = Date()
    }

    func scanCleanup(roots: [URL], done: @escaping @MainActor ([CleanupItem]) -> Void) {
        cleanupQueue.async {
            let items = Cleanup.scan(roots: roots)
            DispatchQueue.main.async { done(items) }
        }
    }
}
