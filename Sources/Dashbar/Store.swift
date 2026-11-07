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
    /// After a temporary failure, no plan request goes out before this, not even from Retry or Refresh:
    /// asking again while rate limited only keeps the limit tripped.
    @Published var claudePlanRetryAt: Date?
    private var claudePlanFailures = 0
    /// Claude Code is running to refresh its own sign-in.
    @Published var claudeSigningIn = false
    /// A failed user action, phrased with what to do next. Shown until dismissed.
    @Published var notice: String?

    var busyCount: Int { sessions.filter(\.isBusy).count }
    var waitingCount: Int { sessions.filter(\.isWaiting).count }
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

    /// The workspace worth featuring: one whose agent is waiting for you, then one with a working agent, else the one
    /// whose agent changed state most recently.
    var featured: Workspace? {
        let ws = workspaces
        if let waiting = ws.first(where: \.isWaiting) { return waiting }
        if let busy = ws.first(where: \.isBusy) { return busy }
        return ws.filter { !$0.sessions.isEmpty }.max {
            ($0.sessions.map(\.since).max() ?? .distantPast) < ($1.sessions.map(\.since).max() ?? .distantPast)
        }
    }

    private let worker = Worker()
    private let notifier = Notifier()
    private let settings = AppSettings.shared
    private var transitions = SessionTransitions()
    private var tick = 0
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var watcher: FileWatcher?
    /// Which windows (the menu bar panel, the popout) are on screen, as reported by their views. Closed until one opens.
    private var surfaces = SurfaceVisibility()
    /// Limit alerts already sent, so each fires once per window even across relaunches.
    private var sentLimitAlerts = LimitAlerts.prune(Set(UserDefaults.standard.stringArray(forKey: "limitAlertsSent") ?? []))
    private var panelVisible: Bool { surfaces.anyVisible }
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
        GlobalShortcut.shared.action = { [weak self] in
            guard let self else { return }
            Popout.shared.toggle(store: self)
        }
        GlobalShortcut.shared.setEnabled(GlobalShortcut.isEnabled)
        notifier.openLimits = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(PanelTab.agents.rawValue, forKey: "panelTab")   // the plan limits live there
            Popout.shared.show(store: self)
        }
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

    /// Notifies when a plan limit is nearly used, on course to run out, or used up (once per window).
    private func checkLimits() {
        guard !isDemo, !paused else { return }
        var alerts = LimitAlerts.check(provider: "Codex", limits: codexLimits, sent: sentLimitAlerts)
        if settings.claudeLimits, let plan = claudePlan, plan.problem == nil {
            alerts += LimitAlerts.check(provider: "Claude", limits: plan.limits, sent: sentLimitAlerts)
        }
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            notifier.limit(alert)
            sentLimitAlerts.insert(alert.sentKey)
        }
        sentLimitAlerts = LimitAlerts.prune(sentLimitAlerts)
        UserDefaults.standard.set(Array(sentLimitAlerts), forKey: "limitAlertsSent")
    }

    /// Each window reports on its own, so closing one doesn't pause updates for the other.
    func setPanelVisible(_ visible: Bool, surface: String = "panel") {
        guard !isDemo else { return }
        guard surfaces.set(visible, surface: surface) else { return }
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
        if let retryAt = claudePlanRetryAt, Date() < retryAt { return }
        if !force, let fetched = claudePlan?.fetchedAt, claudePlan?.stale == nil,
           Date().timeIntervalSince(fetched) < 60 { return }

        // Another copy of Dashbar (the release beside a local build) may have just asked, or be waiting out a limit.
        let shared = ClaudePlanLimits.Shared.load()
        switch shared?.decide(force: force) {
        case .useShared?:
            if let shared, (claudePlan?.fetchedAt ?? .distantPast) < (shared.fetchedAt ?? .distantPast) || claudePlan?.stale != nil {
                claudePlan = shared.result()
                claudePlanFailures = 0
                claudePlanRetryAt = nil
                checkLimits()
            }
            return
        case .wait(let until)?:
            if let shared, !shared.limits.isEmpty {
                claudePlan = shared.result(stale: .rateLimited)
            } else if claudePlan?.limits.isEmpty ?? true {
                claudePlan = ClaudePlanLimits.Result(plan: claudePlan?.plan, problem: ClaudePlanLimits.rateLimitedMessage, transient: true)
            }
            scheduleClaudeRetry(at: until)
            return
        default:
            break
        }

        claudePlanLoading = true
        Task.detached(priority: .utility) {
            let result = await ClaudePlanLimits.fetch()
            await MainActor.run {
                self.claudePlanLoading = false
                guard self.settings.claudeLimits else { return }
                var record = ClaudePlanLimits.Shared.load() ?? ClaudePlanLimits.Shared()
                if result.transient {
                    self.claudePlanFailures += 1
                    let wait = ClaudePlanLimits.backoff(failures: self.claudePlanFailures, retryAfter: result.retryAfter)
                    let retryAt = Date().addingTimeInterval(wait)
                    self.scheduleClaudeRetry(at: retryAt)
                    record.retryAt = retryAt
                    record.save()
                } else {
                    self.claudePlanFailures = 0
                    self.claudePlanRetryAt = nil
                    if result.problem == nil {
                        record = ClaudePlanLimits.Shared(fetchedAt: result.fetchedAt, plan: result.plan, limits: result.limits)
                        record.save()
                    }
                }
                self.claudePlan = ClaudePlanLimits.keepingLastGood(self.claudePlan, result)
                self.checkLimits()
            }
        }
    }

    /// Waits until `retryAt`, then tries again, so the countdown means what it says (the regular check is 5 minutes).
    private func scheduleClaudeRetry(at retryAt: Date) {
        claudePlanRetryAt = retryAt
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, retryAt.timeIntervalSinceNow) + 1) { [weak self] in
            guard let self, self.claudePlanRetryAt == retryAt, !self.paused else { return }
            self.refreshClaudePlan(force: true)
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
        for event in transitions.update(new, now: Date()) {
            switch event {
            case .finished(let id, let after):
                if let s = new.first(where: { $0.id == id }) { notifier.finished(s, after: after) }
            case .waiting(let id):
                if let s = new.first(where: { $0.id == id }) { notifier.waiting(s) }
            }
        }
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
            if let c = r.codex { self.codex = c; self.codexLimits = r.codexLimits; self.checkLimits() }
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

/// Which of Dashbar's windows (the menu bar panel, the popout) are on screen. Updates run while any is, so closing
/// one never pauses them for the other.
struct SurfaceVisibility {
    private var visible = Set<String>()
    var anyVisible: Bool { !visible.isEmpty }

    /// Records one window's state. Returns whether "is anything visible" changed, which is when the store reacts.
    mutating func set(_ isVisible: Bool, surface: String) -> Bool {
        let before = anyVisible
        if isVisible { visible.insert(surface) } else { visible.remove(surface) }
        return anyVisible != before
    }
}

/// Turns successive session readings into the moments worth a notification: an agent finishing a stretch of work,
/// or stopping to ask for permission or input.
struct SessionTransitions {
    enum Event: Equatable {
        case finished(id: String, after: TimeInterval)
        case waiting(id: String)
    }

    /// Short turns aren't worth interrupting anyone for.
    static let minimumWork: TimeInterval = 20

    private var busySince: [String: Date] = [:]
    private var waiting = Set<String>()
    private var primed = false

    mutating func update(_ sessions: [LiveSession], now: Date) -> [Event] {
        var events: [Event] = []
        for s in sessions {
            if s.isWaiting {
                // Asking isn't finishing: the work it started carries on once someone replies.
                if waiting.insert(s.id).inserted, primed { events.append(.waiting(id: s.id)) }
                continue
            }
            waiting.remove(s.id)
            if s.isBusy {
                if busySince[s.id] == nil { busySince[s.id] = now }
            } else if let start = busySince.removeValue(forKey: s.id), now.timeIntervalSince(start) >= Self.minimumWork {
                events.append(.finished(id: s.id, after: now.timeIntervalSince(start)))
            }
        }
        let live = Set(sessions.map(\.id))
        busySince = busySince.filter { live.contains($0.key) }
        waiting = waiting.filter { live.contains($0) }
        primed = true   // the first reading is a baseline: sessions already waiting at launch don't notify
        return events
    }
}
