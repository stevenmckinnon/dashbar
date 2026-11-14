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
    /// When live data last arrived. Deliberately not published: setting it on every refresh would redraw every view
    /// that observes the store.
    var lastUpdated = Date()
    @Published var usageLoading = true
    @Published var paused = false
    @Published var topApps: [AppUsage] = []
    @Published var history = SystemHistory()
    /// What each workspace's processes use, keyed by workspace root. Sampled only while a window is open.
    @Published var workspaceUsage: [String: WorkspaceUsage] = [:]
    @Published var workspaceHistory: [String: WorkspaceHistory] = [:]
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
    /// Set when Claude Code's session files exist but can't be read (see `ClaudeSessions.readChecked`).
    @Published var sessionsWarning: String?

    /// A log or session format Dashbar can no longer read. Shown instead of quietly reporting nothing.
    var formatWarning: String? { claude.warning ?? codex.warning ?? sessionsWarning }

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
    /// When the last clean-up scan started. It runs again only while a window is open, or on opening once stale.
    private var lastCleanupScan: Date?
    private static let cleanupInterval: TimeInterval = 600
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
            AppWindow.shared.toggle(store: self)
        }
        GlobalShortcut.shared.setEnabled(GlobalShortcut.isEnabled)
        notifier.openLimits = { [weak self] in
            guard let self else { return }
            AppWindow.shared.show(store: self, page: .tab(.agents))   // the plan limits live there
        }
        worker.start(live: { [weak self] in self?.apply($0) }, usage: { [weak self] in self?.apply($0) })
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
        if panelVisible, tick % every(Self.cleanupInterval) == 0 { scanCleanup() }   // nothing shows it while closed
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
            if let last = lastCleanupScan, Date().timeIntervalSince(last) > Self.cleanupInterval { scanCleanup() }
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
        lastCleanupScan = Date()
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
    /// Live data and the usage scan run separately, so a long scan never holds up sessions and servers.
    private func refresh(usage: Bool, servers: Bool, panel: Bool, system: Bool = false) {
        guard !isDemo else { return }
        worker.requestLive(.init(servers: servers, panel: panel, system: system || panel))
        if usage { worker.requestUsage() }
    }

    /// Assigns only what changed, so views that observe the store redraw when there is something new to show.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Store, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func apply(_ r: Worker.LiveResult) {
        trackTransitions(r.sessions)
        update(\.sessions, r.sessions)
        update(\.sessionsWarning, r.sessionsWarning)
        update(\.contexts, r.contexts)
        if let a = r.agents { update(\.otherAgents, a) }
        if let sys = r.system {
            update(\.system, sys)
            cpuHistory = Array((cpuHistory + [sys.cpu]).suffix(40))
            history.append(sys)
        }
        if let apps = r.topApps { update(\.topApps, apps) }
        if let usage = r.workspaceUsage {
            update(\.workspaceUsage, usage)
            var history = workspaceHistory.filter { usage[$0.key] != nil }
            for (root, u) in usage { history[root, default: WorkspaceHistory()].append(u) }
            update(\.workspaceHistory, history)
        }
        if let l = r.listeners { update(\.listeners, l) }
        if let s = r.spawned { update(\.spawned, s) }
        lastUpdated = Date()
    }

    private func apply(_ r: Worker.UsageResult) {
        update(\.claude, r.claude)
        update(\.usageLoading, false)
        update(\.codex, r.codex)
        update(\.codexLimits, r.codexLimits)
        checkLimits()
    }
}

/// Owns all collectors and runs them on background queues: live data (sessions, servers, system) on one,
/// the usage scan on another, so the first scan of a large log folder never holds up the rest.
final class Worker: @unchecked Sendable {
    /// What a live refresh should read beyond the sessions, which it always reads.
    struct LiveRequest: Equatable {
        var servers = false
        var panel = false
        var system = false

        func merged(with other: LiveRequest) -> LiveRequest {
            LiveRequest(servers: servers || other.servers, panel: panel || other.panel, system: system || other.system)
        }
    }

    struct LiveResult {
        var sessions: [LiveSession] = []
        var sessionsWarning: String?
        var contexts: [String: ContextInfo] = [:]
        var agents: [AgentProcess]?
        var system: SystemSnapshot?
        var topApps: [AppUsage]?
        var listeners: [Listener]?
        var spawned: [Int32: SpawnedProcesses]?
        var workspaceUsage: [String: WorkspaceUsage]?
    }

    struct UsageResult {
        var claude: UsageSummary
        var codex: UsageSummary
        var codexLimits: [RateLimit]
    }

    private let liveQueue = DispatchQueue(label: "dashbar.live", qos: .utility)
    private let usageQueue = DispatchQueue(label: "dashbar.usage", qos: .utility)
    private let cleanupQueue = DispatchQueue(label: "dashbar.cleanup", qos: .background)
    private lazy var live = Coalescer<LiveRequest>(queue: liveQueue, merge: { $0.merged(with: $1) }) { [unowned self] in
        self.collectLive($0)
    }
    private lazy var usage = Coalescer<Void>(queue: usageQueue, merge: { _, _ in () }) { [unowned self] in
        self.scanUsage()
    }
    // Created on the usage queue at first use, so loading saved progress never blocks the main thread.
    private lazy var claudeScanner = ClaudeUsageScanner(cache: ScanCache<ClaudeUsageScanner.State>.defaultURL("claude-usage.json"))
    private lazy var codexScanner = CodexUsageScanner(cache: ScanCache<CodexUsageScanner.State>.defaultURL("codex-usage.json"))
    private let contextReader = ContextReader()
    private let sampler = SystemSampler()
    private let serverActivity = ServerActivity()
    private let workspaceSampler = WorkspaceSampler()
    /// Servers are read every few ticks; workspace sampling uses the latest reading in between. Live queue only.
    private var lastListeners: [Listener] = []
    /// Usage queue only. Nil until the first scan, which is saved straight away: it is the expensive one.
    private var lastSave: Date?
    private let stopLock = NSLock()
    private var stopped = false
    private var onLive: (@MainActor (LiveResult) -> Void)?
    private var onUsage: (@MainActor (UsageResult) -> Void)?

    /// Sets where results go. Call once, on the main thread, before the first request.
    func start(live: @escaping @MainActor (LiveResult) -> Void, usage: @escaping @MainActor (UsageResult) -> Void) {
        onLive = live
        onUsage = usage
    }

    /// Requests that arrive while one is already waiting merge into it, so ticks and file events never pile up.
    func requestLive(_ request: LiveRequest) { live.submit(request) }
    func requestUsage() { usage.submit(()) }

    private var isStopped: Bool { stopLock.withLock { stopped } }

    private func collectLive(_ req: LiveRequest) {
        guard !isStopped else { return }
        var r = LiveResult()
        let reading = ClaudeSessions.readChecked()
        r.sessions = reading.sessions
        r.sessionsWarning = reading.warning
        r.contexts = contextReader.read(r.sessions)
        if req.system { r.system = sampler.sample() }
        if req.servers {
            var listeners = Listeners.read()
            serverActivity.annotate(&listeners)
            r.spawned = ProcessTree.spawned(sessions: r.sessions, listeners: &listeners)
            r.listeners = listeners
            lastListeners = listeners
        }
        if req.panel {
            r.agents = AgentProcesses.read()
            r.topApps = sampler.topApps()
            let workspaces = Workspace.build(sessions: r.sessions,
                                             servers: lastListeners.filter { $0.isDev && $0.root != nil && !$0.isDocker })
            var anchors: [pid_t: String] = [:]
            for w in workspaces {
                for s in w.sessions { anchors[s.pid] = w.root }
                for l in w.servers { anchors[l.pid] = w.root }
            }
            r.workspaceUsage = workspaceSampler.sample(roots: workspaces.map(\.root), anchors: anchors)
        }
        let result = r, done = onLive
        DispatchQueue.main.async { done?(result) }
    }

    private func scanUsage() {
        guard !isStopped else { return }
        let result = UsageResult(claude: claudeScanner.scan(), codex: codexScanner.scan(), codexLimits: codexScanner.limits)
        if lastSave.map({ Date().timeIntervalSince($0) > 30 }) ?? true { save() }
        let done = onUsage
        DispatchQueue.main.async { done?(result) }
    }

    /// Saves scan progress as the app quits. Waits at most `timeout` for a scan in progress, so quitting never hangs:
    /// if the scan runs longer, the last save (made after the first scan, then every 30 s) stays, and the next launch
    /// reads on from there. Saves are written atomically, so an interrupted one never leaves a broken file.
    func saveNow(timeout: TimeInterval = 2) {
        stopLock.withLock { stopped = true }   // queued refreshes are skipped from here on
        let saved = DispatchSemaphore(value: 0)
        usageQueue.async { [self] in
            save()
            saved.signal()
        }
        _ = saved.wait(timeout: .now() + timeout)
    }

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

/// Runs jobs on a serial queue with at most one waiting. A request that arrives while one is waiting merges into it,
/// so a burst of timer ticks and file events becomes a single job, and one more after the job that is running.
final class Coalescer<Request>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Request?
    private let queue: DispatchQueue
    private let merge: (Request, Request) -> Request
    private let run: (Request) -> Void

    init(queue: DispatchQueue, merge: @escaping (Request, Request) -> Request, run: @escaping (Request) -> Void) {
        self.queue = queue
        self.merge = merge
        self.run = run
    }

    func submit(_ request: Request) {
        let schedule: Bool = lock.withLock {
            if let waiting = pending {
                pending = merge(waiting, request)
                return false
            }
            pending = request
            return true
        }
        guard schedule else { return }
        queue.async { [self] in
            let next: Request? = lock.withLock {
                defer { pending = nil }
                return pending
            }
            if let next { run(next) }
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
