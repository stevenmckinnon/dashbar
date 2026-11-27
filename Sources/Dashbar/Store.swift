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
    /// Gemini CLI's and the Antigravity CLI's usage together (`Google.swift`). Not found for someone using neither.
    @Published var google = UsageSummary.empty
    /// Which of Google's tools that usage came from, for the card's title.
    @Published var googleSources: [SessionAgent] = []
    /// Antigravity's plan limits from its CLI's status line. Nil until the bridge has saved a reading.
    @Published var antigravityLimits: AntigravityLimits?
    /// A Google format Dashbar no longer reads (the Antigravity app's conversations).
    @Published var googleWarning: String?
    /// Codex's live sessions couldn't be read (`CodexSessions`).
    @Published var codexSessionsWarning: String?
    /// opencode's usage from its session database (`OpenCode.swift`). Not found for someone who doesn't use it.
    @Published var opencode = UsageSummary.empty
    /// GitHub Copilot CLI's usage from its session logs' shutdown records (`CopilotCLI.swift`), with premium requests.
    /// Not found for someone who doesn't use it.
    @Published var copilot = CopilotUsage.empty
    /// Each account's usage, only while more than one Claude Code (or Codex) account is read; empty otherwise, so a
    /// single account looks exactly as before.
    @Published var claudeAccountUsage: [AccountUsage] = []
    @Published var codexAccountUsage: [AccountUsage] = []
    /// Plan limits of the Claude accounts beyond the default, from each one's status line bridge.
    @Published var claudeAccountLimits: [AccountLimits] = []
    /// Every Codex account's limits, only while there is more than one.
    @Published var codexAccountLimits: [AccountLimits] = []
    /// The default Claude account's name, only while there is more than one account.
    @Published var claudeDefaultLabel: String?
    /// When Codex reported `codexLimits`.
    var codexLimitsAt = Date.distantPast
    /// Readings of the plan windows over time, for the History page. Republished only when a reading adds to it.
    @Published var planHistory = PlanHistory()
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
    /// Mirrors of `plan`'s state, so views (and demo data) read them from the store.
    @Published var claudePlan: ClaudePlanLimits.Result?
    @Published var claudePlanLoading = false
    @Published var claudePlanRetryAt: Date?
    @Published var claudeSigningIn = false
    /// Claude plan limits: the status line bridge and the experimental endpoint.
    let plan = ClaudePlanMonitor()
    /// A failed user action, phrased with what to do next. Shown until dismissed.
    @Published var notice: String?
    /// Set when Claude Code's session files exist but can't be read (see `ClaudeSessions.readChecked`).
    @Published var sessionsWarning: String?
    /// Each live session's subagents (running, and finished in the last minute or so), keyed by session ID.
    @Published var subagents: [String: [Subagent]] = [:]
    /// Set when subagent files exist but can't be read (see `SubagentReader`).
    @Published var subagentsWarning: String?
    /// Claude Code permission prompts waiting for an answer in Dashbar (only while the permission hook is added).
    @Published var permissionRequests: [PermissionRequest] = []
    /// Moments the island may open for: an agent finishing, stopping for you, or a new permission prompt.
    let islandEvents = PassthroughSubject<IslandEvent, Never>()

    func permissionRequest(for session: LiveSession) -> PermissionRequest? {
        permissionRequests.first { $0.sessionId == session.id }
    }

    /// An account beyond the default with its own plan history: its name, its key (the series' account) and its limits now.
    struct HistoryAccount: Identifiable {
        var id: String { key }
        let label: String
        let key: String
        let limits: [RateLimit]
    }

    /// The accounts beyond the default whose plan history the History page shows, each as its own card.
    func historyAccounts(_ provider: PlanHistory.Provider) -> [HistoryAccount] {
        switch provider {
        case .claude:
            // Only added accounts are in `claudeAccountLimits`; their key is the hash of the folder.
            return claudeAccountLimits.map {
                HistoryAccount(label: $0.label, key: AgentAccounts.hash($0.path), limits: $0.problem == nil ? $0.limits : [])
            }
        case .codex:
            return codexAccountLimits.compactMap { a in
                guard let key = codexAccounts.first(where: { $0.path == a.path })?.key else { return nil }   // nil: the default
                return HistoryAccount(label: a.label, key: key, limits: a.limits)
            }
        case .antigravity:
            // One card per model group, each its own series. A group with history but missing from today's reading
            // keeps its card until its history ages out.
            let current = antigravityLimits?.groups ?? []
            var out = current.map { HistoryAccount(label: $0.name, key: AntigravityLimits.historyKey($0.key), limits: $0.limits) }
            for key in planHistory.accounts(.antigravity).compactMap({ $0 }).sorted() where !out.contains(where: { $0.key == key }) {
                out.append(HistoryAccount(label: "Earlier model group", key: key, limits: []))
            }
            return out
        }
    }

    /// The default account's name on the History page, only while there is more than one account of that kind.
    func defaultAccountLabel(_ provider: PlanHistory.Provider) -> String? {
        switch provider {
        case .claude: return claudeDefaultLabel
        case .codex: return codexAccounts.count > 1 ? codexAccounts.first?.label : nil
        case .antigravity: return nil
        }
    }

    /// Which account a permission request came from, only while more than one Claude Code account is read.
    func accountLabel(for request: PermissionRequest) -> String? {
        if let label = sessions.first(where: { $0.id == request.sessionId })?.account { return label }
        return request.accountLabel(in: claudeAccounts)
    }

    /// Requests whose session Dashbar can't see (no session file), shown on their own so none goes unanswered.
    var unmatchedPermissionRequests: [PermissionRequest] {
        let ids = Set(sessions.map(\.id))
        return permissionRequests.filter { !ids.contains($0.sessionId) }
    }

    /// Which account the Claude plan limits shown first belong to, only while there is more than one: the default
    /// account's name, or for the experimental endpoint the account whose Keychain entry was used ("Unlabelled sign-in"
    /// when the entry matches none).
    var claudePlanLabel: String? {
        guard let fallback = claudeDefaultLabel else { return nil }
        guard claudePlan?.source == .endpoint, let service = claudePlan?.keychainService, !claudeAccounts.isEmpty else { return fallback }
        return claudeAccounts.first { $0.keychainService() == service }?.label ?? "Unlabelled sign-in"
    }

    /// A log or session format Dashbar can no longer read. Shown instead of quietly reporting nothing.
    var formatWarning: String? {
        claude.warning ?? codex.warning ?? sessionsWarning ?? codexSessionsWarning ?? subagentsWarning ?? google.warning ?? googleWarning ?? opencode.warning
            ?? copilot.summary.warning
    }

    /// Which tools show (Settings → Integrations → Show in Dashbar). Hidden tools' readings never reach the store.
    var visibility: ToolVisibility { settings.visibility }

    func subagents(for session: LiveSession) -> [Subagent] { subagents[session.id] ?? [] }

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

    /// The workspace the Now card features (`OverviewRules.nowWorkspace`): waiting, then working (its agent, or its
    /// subagents while the agent waits for them), then one whose agent went idle in the last 10 minutes. Nil otherwise.
    var nowWorkspace: Workspace? {
        OverviewRules.nowWorkspace(workspaces, now: Date()) { [subagents] w in
            w.isBusy || w.sessions.contains { s in !(subagents[s.id] ?? []).running.isEmpty }
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
    /// The accounts being read, as of the last change in Settings.
    private var claudeAccounts: [ResolvedAccount] = []
    private var codexAccounts: [ResolvedAccount] = []
    private var watchedPaths: [String] = []
    /// Which windows (the menu bar panel, the popout) are on screen, as reported by their views. Closed until one opens.
    private var surfaces = SurfaceVisibility()
    /// Limit alerts already sent, so each fires once per window even across relaunches.
    private var sentLimitAlerts = LimitAlerts.prune(Set(UserDefaults.standard.stringArray(forKey: "limitAlertsSent") ?? []))
    /// Today's share alerts already sent today ("Claude|Weekly|2026-11-21"), so each fires once per limit per day.
    private var sentTodayShares = Set(UserDefaults.standard.stringArray(forKey: "todayShareSent") ?? [])
    /// Used-up windows waiting for their reset, kept across relaunches ("Claude|5-hour@<reset time>", nothing else).
    private var followedLimitResets = Set(UserDefaults.standard.stringArray(forKey: "limitResetsFollowed") ?? [])
    private var panelVisible: Bool { surfaces.anyVisible }
    /// Whether the menu bar panel itself is on screen (not the popout), as its view last reported.
    var menuBarPanelVisible: Bool { surfaces.isVisible("panel") }
    /// Demo stores hold invented data and never collect anything.
    private var isDemo = false
    private let planRecorder = PlanHistoryRecorder()
    /// Sessions as Claude Code's files describe them, before pending permission requests mark theirs as waiting.
    private var rawSessions: [LiveSession] = []
    private let permissionQueue = PermissionQueue.default
    private var permissionWatcher: FileWatcher?
    private var heartbeat: Timer?
    /// Requests already notified about, so each gets one notification.
    private var notifiedRequests = Set<String>()
    /// Requests whose session Claude Code's own file has shown at its permission prompt (see `answeredInTerminal`).
    private var promptsSeen = Set<String>()
    /// Per pending request, the transcript size last looked at (`settledElsewhere`), so an unchanged one isn't read again.
    private var transcriptChecked: [String: UInt64] = [:]
    /// Session transcripts found for pending requests. Main thread only (the live queue has its own, in `ContextReader`).
    private var transcriptPaths: [String: URL] = [:]

    /// `demo` fills the store with invented data and starts nothing: no scanning, timers, watchers or
    /// Keychain access. Used for README and website screenshots (`Dashbar --snapshot out.png --demo`).
    init(demo: Bool = false) {
        if demo {
            isDemo = true
            DemoData.apply(to: self)
            applyVisibility(settings.visibility)   // `DASHBAR_DEMO_HIDDEN`, in memory only
            return
        }
        notifier.setup()
        GlobalShortcut.shared.action = { [weak self] in
            guard let self else { return }
            AppWindow.shared.toggle(store: self)
        }
        GlobalShortcut.shared.setEnabled(GlobalShortcut.isEnabled)
        JumpShortcut.shared.action = { [weak self] in self?.jumpToAgent() }
        JumpShortcut.shared.apply()
        notifier.openLimits = { [weak self] in
            guard let self else { return }
            AppWindow.shared.show(store: self, page: .tab(.agents))   // the plan limits live there
        }
        worker.start(live: { [weak self] in self?.apply($0) }, usage: { [weak self] in self?.apply($0) })
        worker.setVisibility(settings.visibility)
        followAccounts()
        refresh(usage: true, servers: true, panel: true)
        scanCleanup()
        startTimer()
        // The `dashbar` command's status file. A snapshot run never writes it: it would replace the running app's.
        if !CommandLine.arguments.contains("--snapshot") { CLIStatus.follow(self).store(in: &subscriptions) }
        settings.$accounts.dropFirst().removeDuplicates()
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settings.refreshAccountFolders()
                self.followAccounts()
                self.settings.refreshClaudePermissions()
                self.refresh(usage: true, servers: false, panel: self.panelVisible)
            }
            .store(in: &subscriptions)
        // A folder found or lost (checked each minute and when Settings → Accounts opens) starts or stops its account.
        // The new set is passed in: `@Published` sends before the property changes.
        settings.$missingAccountFolders.dropFirst().removeDuplicates()
            .sink { [weak self] missing in
                guard let self else { return }
                guard self.followAccounts(missing: missing) else { return }
                self.refresh(usage: true, servers: false, panel: self.panelVisible)
            }
            .store(in: &subscriptions)
        settings.$accountStatusLines.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.refreshAccountLimits() } }
            .store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.worker.saveNow()
                self?.planRecorder.save()
                // Waiting hooks stop at once (unless another copy is running), so the terminal prompts straight away.
                if self?.heartbeat != nil { self?.permissionQueue.goodbye() }
            }
        }
        notifier.answerPermission = { [weak self] id, answer in self?.answer(id, answer, fromNotification: true) }
        // VoiceOver hears the moments the island shows (`Announcer.swift`).
        islandEvents.sink { [weak self] in self?.announce($0) }.store(in: &subscriptions)
        settings.refreshClaudePermissions()
        settings.$claudePermissions.removeDuplicates()
            .sink { [weak self] on in Task { @MainActor in self?.setPermissionsEnabled(on) } }
            .store(in: &subscriptions)
        settings.$permissionWait.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.beat() } }
            .store(in: &subscriptions)
        settings.$refreshSeconds.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.startTimer() } }
            .store(in: &subscriptions)
        // Like `update(_:_:)`: pass on only changes, so an unchanged reading never redraws the views.
        plan.$result.removeDuplicates().assign(to: &$claudePlan)
        plan.$loading.removeDuplicates().assign(to: &$claudePlanLoading)
        plan.$retryAt.removeDuplicates().assign(to: &$claudePlanRetryAt)
        plan.$signingIn.removeDuplicates().assign(to: &$claudeSigningIn)
        plan.onUpdate = { [weak self] in self?.checkLimits() }
        settings.refreshClaudeStatusLine()
        AntigravitySettings.shared.refresh()
        OpenCodeSettings.shared.refresh()
        CopilotSettings.shared.refresh()
        // A tool switched off stops at once (its collectors skip, what it showed goes); switched on, the next refresh
        // brings everything back. The new value is passed in: `@Published` sends before the property changes.
        settings.$visibility.dropFirst().removeDuplicates()
            .sink { [weak self] v in self?.setVisibility(v) }
            .store(in: &subscriptions)
        settings.$claudeLimits.removeDuplicates()
            .sink { [weak self] on in Task { @MainActor in self?.plan.setEndpointEnabled(on) } }
            .store(in: &subscriptions)
        settings.$claudeStatusLine.removeDuplicates()
            .sink { [weak self] on in Task { @MainActor in self?.plan.setStatusLineEnabled(on) } }
            .store(in: &subscriptions)
        settings.$scanRoots.dropFirst().removeDuplicates()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scanCleanup() }
            .store(in: &subscriptions)
    }

    /// Reads the accounts in Settings whose folders exist (`missing`, or Settings' last check). Returns whether that
    /// changed which accounts are read.
    @discardableResult
    private func followAccounts(missing: Set<String>? = nil) -> Bool {
        let missing = missing ?? settings.missingAccountFolders
        return setAccounts(claude: AgentAccounts.readable(settings.claudeAccounts, missing: missing),
                           codex: AgentAccounts.readable(settings.codexAccounts, missing: missing))
    }

    /// Points the collectors and the file watcher at these accounts' folders. One watcher covers every folder, so more
    /// accounts add paths to one FSEvents stream, not more streams or timers.
    @discardableResult
    private func setAccounts(claude: [ResolvedAccount], codex: [ResolvedAccount]) -> Bool {
        guard claude != claudeAccounts || codex != codexAccounts else { return false }
        claudeAccounts = claude
        codexAccounts = codex
        plan.accounts = claude
        worker.setAccounts(claude: claude, codex: codex)
        update(\.claudeDefaultLabel, claude.count > 1 ? claude.first?.label : nil)
        watchFiles()
        refreshAccountLimits()
        return true
    }

    /// Agent logs and session files change as agents work: react to that instead of polling. A tool switched off isn't
    /// watched, so its writes cost nothing.
    private func watchFiles() {
        let v = settings.visibility
        var paths = claudeAccounts.flatMap { [$0.projectsDir.path, $0.sessionsDir.path] }
        if v.shows(.codex) { paths += codexAccounts.map(\.sessionsDir.path) }
        // Each skipped while missing.
        if v.shows(.google) { paths += [GeminiUsageScanner.defaultRoot.path, AntigravityStatusLine.sessionsDir.path] }
        if v.shows(.opencode) { paths.append(OpenCodeBridge.statesDir.path) }
        if v.shows(.copilot) { paths += [CopilotCLI.sessionStateURL().path, CopilotBridge.statesDir.path] }
        guard paths != watchedPaths else { return }   // renaming an account changes nothing on disk
        watchedPaths = paths
        watcher = FileWatcher(paths: paths, latency: 1.5, queue: .main) { [weak self] in
            Task { @MainActor in self?.filesChanged() }
        }
    }

    /// Switches tools on or off: the collectors follow, what a hidden tool showed goes now, and a refresh reads the rest.
    private func setVisibility(_ v: ToolVisibility) {
        worker.setVisibility(v)
        applyVisibility(v)
        watchFiles()
        refresh(usage: true, servers: false, panel: panelVisible)
    }

    /// Drops what hidden tools put in the store, as `Worker.LiveResult.hiding` and `UsageResult.hiding` do for readings.
    func applyVisibility(_ v: ToolVisibility) {
        guard !v.hidden.isEmpty else { return }
        rawSessions = v.filter(rawSessions)
        update(\.sessions, v.filter(sessions))
        update(\.otherAgents, v.filter(otherAgents))
        if !v.shows(.codex) {
            update(\.codexSessionsWarning, nil)
            update(\.codex, .empty)
            update(\.codexLimits, [])
            update(\.codexAccountUsage, [])
            update(\.codexAccountLimits, [])
            codexLimitsAt = .distantPast
        }
        if !v.shows(.google) {
            update(\.google, .empty)
            update(\.googleSources, [])
            update(\.antigravityLimits, nil)
            update(\.googleWarning, nil)
        }
        if !v.shows(.opencode) { update(\.opencode, .empty) }
        if !v.shows(.copilot) { update(\.copilot, .empty) }
    }

    /// Reads what each added Claude account's status line bridge saved. A few small files: cheap enough for every refresh.
    private func refreshAccountLimits() {
        guard !isDemo else { return }
        let limits = Self.accountLimits(claudeAccounts, statusLines: settings.accountStatusLines)
        update(\.claudeAccountLimits, limits)
    }

    /// The added (not default) Claude accounts' readings from their own status line files.
    nonisolated static func accountLimits(_ accounts: [ResolvedAccount], statusLines: [String: StatusLineBridge.Status],
                              readings: URL = ClaudeStatusLine.defaultURL.deletingLastPathComponent(),
                              now: Date = Date()) -> [AccountLimits] {
        accounts.filter { !$0.isDefault }.map { account in
            var out = AccountLimits(label: account.label, path: account.path,
                                    connected: statusLines[account.path]?.isInstalled ?? false)
            out.plan = ClaudeProfile.plan(for: account).name
            let file = readings.appendingPathComponent(ClaudeStatusLine.fileName(account: account.key))
            if let reading = ClaudeStatusLine.read(from: file) {
                out.limits = reading.current(now: now)
                out.fetchedAt = reading.writtenAt
                if reading.unrecognised { out.problem = ClaudeStatusLine.unrecognisedMessage }
            }
            return out
        }
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
        if !permissionRequests.isEmpty { refreshPermissions() }   // drop requests that timed out, even while paused
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
        if tick % every(300) == 0 {   // every 5 minutes
            settings.refreshClaudeStatusLine()   // notices the status line being changed outside Dashbar
            settings.refreshClaudePermissions()  // …and the permission hook
            AntigravitySettings.shared.refresh() // …and the Antigravity CLI's status line
            OpenCodeSettings.shared.refresh()    // …and opencode's plugin
            CopilotSettings.shared.refresh()     // …and Copilot's hook
            ToolPresence.shared.refresh()        // …and which tools are installed
            refreshClaudePlan()
        } else if minute {
            plan.statusLineChanged()
        }
        if minute { settings.refreshAccountFolders() }   // an added account's folder created or removed since
        if minute { refreshAccountLimits() }
        if minute { watcher?.restart() }            // pick up folders created since launch
        if panelVisible, tick % every(Self.cleanupInterval) == 0 { scanCleanup() }   // nothing shows it while closed
    }

    private func filesChanged() {
        guard !paused else { return }
        refresh(usage: true, servers: false, panel: panelVisible)
        plan.statusLineChanged()   // a reply in the logs means the status line has just run
        if claudeAccounts.count > 1 { refreshAccountLimits() }
    }

    /// Notifies when a plan limit is nearly used, on course to run out, or used up (once per window), and when a limit
    /// that was used up resets. Each notification is posted by one running copy of Dashbar only.
    private func checkLimits() {
        guard !isDemo, !paused else { return }
        recordPlanHistory()
        var readings: [(provider: String, limits: [RateLimit], history: [String: [PlanHistory.Sample]])] =
            [("Codex", codexLimits, shareHistory(codexLimits, provider: .codex, account: nil))]
        for other in codexAccountLimits.dropFirst() {   // the first is the default account's, `codexLimits`
            readings.append(("Codex (\(other.label))", other.limits, shareHistory(codexAccount: other)))
        }
        if settings.showsClaudeLimits, let plan = claudePlan, plan.problem == nil {
            readings.append(("Claude", plan.limits, shareHistory(plan.limits, provider: .claude, account: nil)))
        }
        for other in claudeAccountLimits where other.problem == nil {
            readings.append(("Claude (\(other.label))", other.limits, shareHistory(claudeAccount: other)))
        }
        if let ag = antigravityLimits, ag.problem == nil {
            readings.append(("Antigravity", ag.flattened, antigravityShareHistory))
        }

        // A copy with these notifications off doesn't claim them, so it never silences one that has them on.
        let notifies = UserDefaults.standard.bool(forKey: Notifier.limitsKey)
        let alerts = readings.flatMap { LimitAlerts.check(provider: $0.provider, limits: $0.limits, sent: sentLimitAlerts) }
        if !alerts.isEmpty {
            let claims = AnnouncementClaims.default
            for alert in alerts {
                if notifies, claims.claim(LimitAlerts.claimKey(alert.sentKey), window: LimitAlerts.claimWindow) {
                    notifier.limit(alert)
                }
                sentLimitAlerts.insert(alert.sentKey)
            }
            sentLimitAlerts = LimitAlerts.prune(sentLimitAlerts)
            UserDefaults.standard.set(Array(sentLimitAlerts), forKey: "limitAlertsSent")
        }

        checkTodayShares(readings)

        var resets: [LimitReset] = []
        var followed = followedLimitResets
        for reading in readings {
            let result = LimitResets.check(provider: reading.provider, limits: reading.limits, followed: followed)
            resets += result.resets
            followed = result.followed
        }
        followed = LimitResets.prune(followed)   // a source that stopped reporting, or an account since removed
        if notifies { LimitResets.deliver(resets, claims: .default) { notifier.limitReset($0) } }
        if followed != followedLimitResets {
            followedLimitResets = followed
            UserDefaults.standard.set(followed.sorted(), forKey: "limitResetsFollowed")
        }
    }

    /// "You've used today's share" of a weekly limit, once per limit per day, off unless turned on in Settings.
    private func checkTodayShares(_ readings: [(provider: String, limits: [RateLimit], history: [String: [PlanHistory.Sample]])]) {
        let now = Date()
        let alerts = readings.flatMap { r in
            TodayShareAlerts.check(provider: r.provider, limits: todayShares(r.limits, history: r.history, now: now),
                                   sent: sentTodayShares, limitAlertsSent: sentLimitAlerts, now: now)
        }
        let pruned = TodayShareAlerts.prune(sentTodayShares, now: now)
        guard !alerts.isEmpty || pruned != sentTodayShares else { return }
        // As with the limit alerts, a copy with this off doesn't claim it, so it never silences one that has it on.
        if UserDefaults.standard.bool(forKey: TodayShareAlerts.settingKey) {
            TodayShareAlerts.deliver(alerts, claims: .default, now: now) { notifier.todayShare($0) }
        }
        sentTodayShares = pruned.union(alerts.map(\.key))
        UserDefaults.standard.set(sentTodayShares.sorted(), forKey: "todayShareSent")
    }

    // MARK: Today's share

    /// The plan-history readings behind each weekly limit that has a series of its own, by label: what its today's
    /// share is worked out from. Limits without a series (Claude's per-model "Weekly · Opus") aren't in it, so they
    /// keep their pace line.
    func shareHistory(_ limits: [RateLimit], provider: PlanHistory.Provider, account: String?) -> [String: [PlanHistory.Sample]] {
        var out: [String: [PlanHistory.Sample]] = [:]
        for l in limits where PlanHistory.kind(of: l) == .weekly && TodayShare.applies(to: l) {
            out[l.label] = planHistory.samples(of: PlanHistory.Series(provider, .weekly, account: account))
        }
        return out
    }

    /// Another Claude Code account's, keyed as its history is (`historyAccounts`).
    func shareHistory(claudeAccount a: AccountLimits) -> [String: [PlanHistory.Sample]] {
        shareHistory(a.limits, provider: .claude, account: AgentAccounts.hash(a.path))
    }

    /// A Codex account's. The default account (no key) is `codexLimits`' series.
    func shareHistory(codexAccount a: AccountLimits) -> [String: [PlanHistory.Sample]] {
        shareHistory(a.limits, provider: .codex, account: codexAccounts.first(where: { $0.path == a.path })?.key)
    }

    /// Antigravity's, by the labels its rows show (`AntigravityLimits.flattened`), each group its own series.
    var antigravityShareHistory: [String: [PlanHistory.Sample]] {
        guard let ag = antigravityLimits else { return [:] }
        var out: [String: [PlanHistory.Sample]] = [:]
        for group in ag.groups {
            for l in group.limits where PlanHistory.kind(of: l) == .weekly && TodayShare.applies(to: l) {
                out[ag.shownLabel(l, in: group)] = planHistory.samples(of: PlanHistory.Series(.antigravity, .weekly, account: AntigravityLimits.historyKey(group.key)))
            }
        }
        return out
    }

    /// Every weekly row a tool's Usage card shows with a today's share, by label (accounts together), so the tab
    /// knows which keys to show.
    func shareHistory(for service: UsageRules.Service) -> [String: [PlanHistory.Sample]] {
        switch service {
        case .claude:
            var out = claudePlan.map { shareHistory($0.limits, provider: .claude, account: nil) } ?? [:]
            for a in claudeAccountLimits { out.merge(shareHistory(claudeAccount: a)) { a, _ in a } }
            return out
        case .codex:
            var out = shareHistory(codexLimits, provider: .codex, account: nil)
            for a in codexAccountLimits { out.merge(shareHistory(codexAccount: a)) { a, _ in a } }
            return out
        case .google: return antigravityShareHistory
        case .opencode, .copilot: return [:]
        }
    }

    /// Each limit with its today's share, where it has a series.
    func todayShares(_ limits: [RateLimit], history: [String: [PlanHistory.Sample]], now: Date) -> [(limit: RateLimit, share: TodayShare?)] {
        limits.map { l in (l, history[l.label].flatMap { TodayShare.compute(l, samples: $0, now: now) }) }
    }

    /// Adds the latest readings to the plan history, as of when each source took them. Kept limits from an earlier
    /// reading (stale) are recorded at their own time, so a wait never invents a flat line.
    private func recordPlanHistory() {
        var changed = false
        if !codexLimits.isEmpty, codexLimitsAt > .distantPast {
            changed = planRecorder.record(codexLimits, provider: .codex, at: codexLimitsAt) || changed
        }
        if let plan = claudePlan, plan.problem == nil, !plan.limits.isEmpty {
            changed = planRecorder.record(plan.limits, provider: .claude, at: plan.fetchedAt) || changed
        }
        // Every other account as its own series, keyed by its folder (`ResolvedAccount.key`).
        for other in claudeAccountLimits where other.problem == nil && !other.limits.isEmpty {
            guard let at = other.fetchedAt, let key = claudeAccounts.first(where: { $0.path == other.path })?.key else { continue }
            changed = planRecorder.record(other.limits, provider: .claude, account: key, at: at) || changed
        }
        for other in codexAccountLimits where !other.limits.isEmpty {
            // The default account's limits are `codexLimits`, recorded above.
            guard let at = other.fetchedAt, let key = codexAccounts.first(where: { $0.path == other.path })?.key else { continue }
            changed = planRecorder.record(other.limits, provider: .codex, account: key, at: at) || changed
        }
        // Antigravity: each model group as its own series, never in the default file (see `AntigravityLimits.historyKey`).
        if let ag = antigravityLimits, ag.problem == nil, let at = ag.fetchedAt {
            for group in ag.groups where !group.limits.isEmpty {
                changed = planRecorder.record(group.limits, provider: .antigravity, account: AntigravityLimits.historyKey(group.key),
                                              at: at) || changed
            }
        }
        if changed || planHistory.isEmpty && !planRecorder.history.isEmpty { planHistory = planRecorder.history }
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

    /// Has Claude Code refresh its sign-in, then loads the plan limits again (the experimental endpoint only).
    func refreshClaudeSignIn() {
        guard !isDemo else { return }
        plan.refreshSignIn()
    }

    func refreshClaudePlan(force: Bool = false) {
        guard !isDemo else { return }
        plan.refresh(force: force)
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

    /// Asks a workspace's processes to quit (SIGTERM, as `kill` does), after the window's confirm. Each pid is checked
    /// again here, so one reused since the last sample, a system process or Dashbar itself is left alone.
    func quit(_ group: WorkspaceUsage.ProcessGroup) {
        guard !isDemo else { return }
        let pids = group.pids.filter {
            QuitPolicy.allows($0) && WorkspaceSampler.displayName(Proc.name($0), path: Proc.path($0)) == group.name
        }
        let failed = pids.filter { kill($0, SIGTERM) != 0 }
        if pids.isEmpty || failed.count == pids.count {
            notice = "Couldn't quit \(group.name). It may have already exited, so refresh to check."
        }
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
                islandEvents.send(IslandEvent(kind: .finished(after: after), sessionID: id))
                if after >= SessionTransitions.notifyAfter, let s = new.first(where: { $0.id == id }) { notifier.finished(s, after: after) }
            case .waiting(let id):
                guard let s = new.first(where: { $0.id == id }) else { continue }
                if permissionRequests.contains(where: { $0.sessionId == id }) { continue }   // its own notification, with answers
                islandEvents.send(IslandEvent(kind: .waiting, sessionID: id))
                if heartbeat != nil, s.waitingFor == "permission prompt" {
                    // The hook's request may be a moment behind Claude Code's session file: give it a second to arrive.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, !self.permissionRequests.contains(where: { $0.sessionId == id }),
                              let still = self.sessions.first(where: { $0.id == id }), still.isWaiting else { return }
                        self.notifier.waiting(still)
                    }
                    continue
                }
                notifier.waiting(s)
            }
        }
    }

    // MARK: Permission prompts

    /// Starts or stops answering permission prompts, following whether the hook is in Claude Code's settings.
    private func setPermissionsEnabled(_ on: Bool) {
        guard !isDemo else { return }
        heartbeat?.invalidate()
        heartbeat = nil
        permissionWatcher = nil
        guard on else {
            permissionQueue.goodbye()
            applyPermissions([])
            return
        }
        beat()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        permissionWatcher = FileWatcher(paths: [permissionQueue.requests.path], latency: 0.2, queue: .main) { [weak self] in
            Task { @MainActor in self?.refreshPermissions() }
        }
        refreshPermissions()
    }

    /// Tells waiting hooks this copy of Dashbar is here, and how long to wait.
    private func beat() {
        guard !isDemo, settings.claudePermissions else { return }
        permissionQueue.heartbeat(wait: settings.permissionWait)
        permissionWatcher?.restart()   // the folder may have been recreated
    }

    private func refreshPermissions() {
        guard !isDemo, settings.claudePermissions else { return }
        applyPermissions(permissionQueue.read())
    }

    /// Requests whose tool call already has a result in the session's transcript (`PermissionRequest.settledInTranscript`).
    private func settledElsewhere(_ requests: [PermissionRequest]) -> [String] {
        let pending = Set(requests.map(\.id))
        transcriptChecked = transcriptChecked.filter { pending.contains($0.key) }
        transcriptPaths = transcriptPaths.filter { id, _ in requests.contains { $0.sessionId == id } }
        var settled: [String] = []
        for r in requests {
            guard let url = transcriptURL(for: r) else { continue }
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard transcriptChecked[r.id] != size else { continue }
            transcriptChecked[r.id] = size
            if PermissionRequest.settledInTranscript(r, tail: Self.tail(of: url, bytes: 256 * 1024)) { settled.append(r.id) }
        }
        return settled
    }

    /// `<projects>/<project>/<sessionId>.jsonl` in the request's account (or its session's own folder).
    private func transcriptURL(for r: PermissionRequest) -> URL? {
        let id = r.sessionId
        guard !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else { return nil }
        if let known = transcriptPaths[id] { return known }
        let projects = rawSessions.first { $0.id == id }?.configDir.map { URL(fileURLWithPath: $0).appendingPathComponent("projects") }
            ?? (claudeAccounts.first { $0.key == r.account } ?? claudeAccounts.first { $0.isDefault })?.projectsDir
        guard let projects else { return nil }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let f = dir.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { transcriptPaths[id] = f; return f }
        }
        return nil
    }

    private nonisolated static func tail(of url: URL, bytes: UInt64) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        return (try? h.readToEnd()) ?? Data()
    }

    private func applyPermissions(_ requests: [PermissionRequest]) {
        // Answered in the terminal: stop the waiting hook and drop the prompt here.
        var answered = PermissionRequest.answeredInTerminal(requests, sessions: rawSessions, seen: &promptsSeen)
        // Settled by the host or an automatic denial, which the session file doesn't show: see the transcript.
        answered += settledElsewhere(requests.filter { !answered.contains($0.id) })
        for id in answered { try? permissionQueue.answer(id, .terminal) }
        let requests = requests.filter { !answered.contains($0.id) }
        let live = Set(requests.map(\.id))
        for id in notifiedRequests.subtracting(live) { notifier.removePermission(id) }
        notifiedRequests.formIntersection(live)
        update(\.permissionRequests, requests)
        let marked = PermissionRequest.marking(rawSessions, with: requests)
        for r in requests where notifiedRequests.insert(r.id).inserted {
            let session = marked.first { $0.id == r.sessionId }
            islandEvents.send(IslandEvent(kind: .permission(requestID: r.id), sessionID: r.sessionId))
            notifier.permission(r, session: session, account: session?.account ?? r.accountLabel(in: claudeAccounts))
        }
        // Sessions first: the island checks a moment against them as it arrives, and would drop "finished" for a
        // session it still saw working.
        update(\.sessions, marked)
        trackTransitions(marked)
    }

    /// Allow once, Deny, or hand the prompt back to Claude Code's terminal. A request that has gone (answered in the
    /// terminal, timed out) is explained, except when it was only being handed back.
    func answer(_ request: PermissionRequest, _ answer: PermissionRequest.Answer) {
        self.answer(request.id, answer, fromNotification: false)
    }

    private func answer(_ id: String, _ answer: PermissionRequest.Answer, fromNotification: Bool) {
        guard !isDemo else { return }
        do {
            try permissionQueue.answer(id, answer)
        } catch {
            if answer != .terminal { notice = error.localizedDescription }
        }
        notifier.removePermission(id)
        applyPermissions(permissionRequests.filter { $0.id != id })   // at once; the watcher confirms
    }

    /// Hands the prompt back to the terminal and goes to the session, so it can be answered there with every option.
    func openSession(for request: PermissionRequest) {
        let session = sessions.first { $0.id == request.sessionId }
        answer(request, .terminal)
        let root = session?.root ?? (request.cwd.isEmpty ? homeDir.path : Fmt.root(fromCwd: request.cwd))
        if let session { HostApp.open(session) } else { HostApp.open(nil, root: root) }
    }

    /// The jump shortcut: brings forward the app of the agent that has waited longest for you, else the one that finished
    /// last (`JumpTarget`). With neither it does nothing on screen and makes no sound; VoiceOver hears why.
    func jumpToAgent() {
        guard let choice = JumpTarget.choose(sessions: sessions, waitingSince: transitions.waitingSince,
                                             finishedAt: transitions.finishedAt, visibility: settings.visibility) else {
            Announcement.post("No agent needs you.", high: false)
            return
        }
        HostApp.open(choice.session)
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
        // A reading taken just before a tool was switched off still carries it.
        let r = r.hiding(settings.visibility)
        rawSessions = r.sessions
        if permissionRequests.isEmpty {
            update(\.sessions, r.sessions)
            trackTransitions(r.sessions)
        } else {
            applyPermissions(permissionRequests)   // marks their sessions, and drops prompts answered in the terminal
        }
        update(\.sessionsWarning, r.sessionsWarning)
        update(\.subagents, r.subagents.bySession)
        update(\.subagentsWarning, r.subagents.warning)
        update(\.googleWarning, r.googleWarning)
        update(\.codexSessionsWarning, r.codexSessionsWarning)
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
        let r = r.hiding(settings.visibility)
        update(\.claude, r.claude)
        update(\.usageLoading, false)
        update(\.codex, r.codex)
        update(\.codexLimits, r.codexLimits)
        update(\.claudeAccountUsage, r.claudeAccounts)
        update(\.codexAccountUsage, r.codexAccounts)
        update(\.codexAccountLimits, r.codexAccountLimits)
        update(\.google, r.google)
        update(\.googleSources, r.googleSources)
        update(\.antigravityLimits, r.antigravityLimits)
        update(\.opencode, r.opencode)
        update(\.copilot, r.copilot)
        codexLimitsAt = r.codexLimitsAt
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
        var subagents = SubagentReader.Reading()
        var googleWarning: String?
        var codexSessionsWarning: String?
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
        /// Per account, only with more than one.
        var claudeAccounts: [AccountUsage] = []
        var codexAccounts: [AccountUsage] = []
        var codexAccountLimits: [AccountLimits] = []
        /// When Codex reported `codexLimits` (the default account's).
        var codexLimitsAt = Date.distantPast
        var google = UsageSummary.empty
        var googleSources: [SessionAgent] = []
        var antigravityLimits: AntigravityLimits?
        var opencode = UsageSummary.empty
        var copilot = CopilotUsage.empty
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
    /// The accounts to read. Set from the main thread, read on the live and usage queues.
    private let accountsLock = NSLock()
    private var claudeAccounts: [ResolvedAccount] = AgentAccounts.resolve(.claude, saved: [])
    private var codexAccounts: [ResolvedAccount] = AgentAccounts.resolve(.codex, saved: [])
    /// One scanner per account folder, each with its own saved progress (keyed by folder). Created on the usage queue
    /// at first use, so loading saved progress never blocks the main thread. Usage queue only.
    private var claudeScanners: [String: ClaudeUsageScanner] = [:]
    private var codexScanners: [String: CodexUsageScanner] = [:]
    private let contextReader = ContextReader()
    /// Codex's live sessions (live queue only).
    private let codexCollector = CodexCollector()
    private let subagentReader = SubagentReader()
    /// Google's agents' live sessions (live queue only), and their usage (usage queue only, created at first use).
    private let googleCollector = GoogleCollector()
    private var geminiScanner: GeminiUsageScanner?
    private var antigravityUsage: AntigravityUsageTracker?
    /// opencode's live sessions (live queue only) and usage (usage queue only).
    private let openCodeCollector = OpenCodeCollector()
    private let openCodeUsage = OpenCodeUsage()
    /// GitHub Copilot CLI's live sessions (live queue only) and usage (usage queue only, created at first use).
    private let copilotCollector = CopilotCollector()
    private var copilotScanner: CopilotUsageScanner?
    /// Which tools to read at all. Set from the main thread, read on the live and usage queues.
    private var visibility = ToolVisibility()
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

    func setAccounts(claude: [ResolvedAccount], codex: [ResolvedAccount]) {
        accountsLock.withLock {
            claudeAccounts = claude
            codexAccounts = codex
        }
    }

    private var accounts: (claude: [ResolvedAccount], codex: [ResolvedAccount]) {
        accountsLock.withLock { (claudeAccounts, codexAccounts) }
    }

    func setVisibility(_ v: ToolVisibility) { accountsLock.withLock { visibility = v } }
    private var currentVisibility: ToolVisibility { accountsLock.withLock { visibility } }

    /// Every tool's live sessions beyond Claude Code's. A hidden tool's collector isn't called, so none of its files are read.
    static func otherSessions(_ v: ToolVisibility, codex: () -> CodexSessions.Reading = { .init() }, google: () -> GoogleLive,
                              opencode: () -> [LiveSession], copilot: () -> [LiveSession])
        -> (sessions: [LiveSession], googleWarning: String?, codexWarning: String?) {
        let c = v.shows(.codex) ? codex() : .init()
        let g = v.shows(.google) ? google() : GoogleLive()
        var out = c.sessions + g.sessions
        if v.shows(.opencode) { out += opencode() }
        if v.shows(.copilot) { out += copilot() }
        return (out, g.warning, c.warning)
    }

    private func collectLive(_ req: LiveRequest) {
        guard !isStopped else { return }
        var r = LiveResult()
        let reading = ClaudeSessions.readChecked(accounts: accounts.claude)
        r.sessionsWarning = reading.warning
        r.contexts = contextReader.read(reading.sessions)
        // Closed, only which subagents run (a folder listing and changed metadata); open, their transcripts' new lines too.
        // Claude Code sessions only: Google's agents and opencode have no subagent transcripts.
        r.subagents = subagentReader.read(reading.sessions, transcript: { self.contextReader.transcript(for: $0) }, detail: req.panel)
        let v = currentVisibility
        let codexAccounts = accounts.codex
        let others = Self.otherSessions(v, codex: { codexCollector.read(accounts: codexAccounts) }, google: { googleCollector.read() }, opencode: { openCodeCollector.read() },
                                        copilot: { copilotCollector.read() })
        r.sessions = others.sessions.isEmpty ? reading.sessions
            : (reading.sessions + others.sessions).sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        r.googleWarning = others.googleWarning
        r.codexSessionsWarning = others.codexWarning
        if req.system { r.system = sampler.sample() }
        if req.servers {
            var listeners = Listeners.read()
            serverActivity.annotate(&listeners)
            r.spawned = ProcessTree.spawned(sessions: r.sessions.filter { $0.pid > 0 }, listeners: &listeners)
            r.listeners = listeners
            lastListeners = listeners
        }
        if req.panel {
            // Codex's chip gives way to its sessions once they're listed, so it never shows twice.
            let listed = r.sessions.contains { $0.agent == .codex }
            r.agents = v.filter(AgentProcesses.read()).filter { !(listed && $0.name == "Codex") }
            r.topApps = sampler.topApps()
            let workspaces = Workspace.build(sessions: r.sessions,
                                             servers: lastListeners.filter { $0.isDev && $0.root != nil && !$0.isDocker })
            var anchors: [pid_t: String] = [:]
            for w in workspaces {
                for s in w.sessions where s.pid > 0 { anchors[s.pid] = w.root }   // the Antigravity app's have none
                for l in w.servers { anchors[l.pid] = w.root }
            }
            r.workspaceUsage = workspaceSampler.sample(roots: workspaces.map(\.root), anchors: anchors)
        }
        let result = r, done = onLive
        DispatchQueue.main.async { done?(result) }
    }

    private func scanUsage() {
        guard !isStopped else { return }
        let v = currentVisibility
        let claude = accounts.claude
        // Codex switched off: no account is read (its saved progress stays for when it's back).
        let codex = v.shows(.codex) ? accounts.codex : []
        // Accounts removed in Settings stop being read; their saved progress stays for if they come back.
        claudeScanners = claudeScanners.filter { path, _ in claude.contains { $0.path == path } }
        codexScanners = codexScanners.filter { path, _ in codex.contains { $0.path == path } }
        let claudeRuns = claude.map { account -> (account: ResolvedAccount, book: UsageBook, summary: UsageSummary) in
            let scanner = claudeScanners[account.path] ?? ClaudeUsageScanner(
                root: account.projectsDir, cache: ScanCache<ClaudeUsageScanner.State>.defaultURL(account.fileName("claude-usage")))
            claudeScanners[account.path] = scanner
            let summary = scanner.scan()
            return (account, scanner.currentBook, summary)
        }
        let codexRuns = codex.map { account -> (account: ResolvedAccount, scanner: CodexUsageScanner, summary: UsageSummary) in
            let scanner = codexScanners[account.path] ?? CodexUsageScanner(
                root: account.sessionsDir, cache: ScanCache<CodexUsageScanner.State>.defaultURL(account.fileName("codex-usage")))
            codexScanners[account.path] = scanner
            return (account, scanner, scanner.scan())
        }
        var result = UsageResult(claude: Self.combined(claudeRuns.map { ($0.book, $0.summary) }),
                                 codex: Self.combined(codexRuns.map { ($0.scanner.currentBook, $0.summary) }),
                                 codexLimits: codexRuns.first?.scanner.limits ?? [],
                                 codexLimitsAt: codexRuns.first?.scanner.limitsStamp ?? .distantPast)
        if claudeRuns.count > 1 {
            result.claudeAccounts = claudeRuns.map { AccountUsage(label: $0.account.label, summary: $0.summary) }
        }
        let codexFound = codexRuns.filter(\.summary.found)
        if codexRuns.count > 1, codexFound.count > 1 {
            result.codexAccounts = codexFound.map { AccountUsage(label: $0.account.label, summary: $0.summary) }
            result.codexAccountLimits = codexFound.map {
                AccountLimits(label: $0.account.label, path: $0.account.path, limits: $0.scanner.limits,
                              fetchedAt: $0.scanner.limitsStamp > .distantPast ? $0.scanner.limitsStamp : nil)
            }
        }
        if v.shows(.google) {
            (result.google, result.googleSources) = scanGoogle()
            result.antigravityLimits = AntigravityStatusLine.readLimits()
        }
        if v.shows(.opencode) { result.opencode = openCodeUsage.scan() }
        if v.shows(.copilot) {
            let scanner = copilotScanner ?? CopilotUsageScanner(cache: ScanCache<CopilotUsageScanner.State>.defaultURL("copilot-usage"))
            copilotScanner = scanner
            result.copilot = scanner.scan()
        }
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

    /// Gemini CLI's logs and the Antigravity CLI's session totals, as one summary. Empty for someone using neither.
    private func scanGoogle() -> (UsageSummary, [SessionAgent]) {
        let gemini = geminiScanner ?? GeminiUsageScanner(cache: ScanCache<GeminiUsageScanner.State>.defaultURL("gemini-usage"))
        geminiScanner = gemini
        let geminiSummary = gemini.scan()
        let agy = antigravityUsage
            ?? AntigravityUsageTracker(cache: ScanCache<AntigravityUsageTracker.State>.defaultURL("antigravity-usage"))
        antigravityUsage = agy
        agy.scan()
        var books: [UsageBook] = [], sources: [SessionAgent] = []
        if geminiSummary.found { books.append(gemini.currentBook); sources.append(.geminiCLI) }
        if agy.found { books.append(agy.book); sources.append(.antigravityCLI) }
        guard !books.isEmpty else { return (.empty, []) }
        var summary = (books.count == 1 ? books[0] : UsageBook.merged(books)).summary(found: true)
        summary.warning = geminiSummary.warning
        return (summary, sources)
    }

    private func save() {
        for scanner in claudeScanners.values { scanner.save() }
        for scanner in codexScanners.values { scanner.save() }
        geminiScanner?.save()
        antigravityUsage?.save()
        copilotScanner?.save()
        lastSave = Date()
    }

    /// One account's summary as it is; several added together from their ledgers, with the first format warning.
    static func combined(_ runs: [(book: UsageBook, summary: UsageSummary)]) -> UsageSummary {
        let found = runs.filter { $0.summary.found }
        if found.count <= 1 { return found.first?.summary ?? .empty }
        var s = UsageBook.merged(found.map(\.book)).summary(found: true)
        s.warning = found.compactMap(\.summary.warning).first
        return s
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
    func isVisible(_ surface: String) -> Bool { visible.contains(surface) }

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

    /// Shorter than this is a quick answer: nothing to show. The island and the menu bar's "Done" are quiet enough for
    /// anything longer.
    static let minimumWork: TimeInterval = 5
    /// A notification interrupts, so it waits for a turn worth coming back for.
    static let notifyAfter: TimeInterval = 20

    private var busySince: [String: Date] = [:]
    /// When each waiting session started waiting (as first seen), so the jump shortcut picks the longest wait.
    private(set) var waitingSince: [String: Date] = [:]
    /// When each live session last finished a stretch of work: the jump shortcut's fallback. Kept while the session
    /// lives, even once it starts again (`JumpTarget` skips a busy one).
    private(set) var finishedAt: [String: Date] = [:]
    private var primed = false

    mutating func update(_ sessions: [LiveSession], now: Date) -> [Event] {
        var events: [Event] = []
        for s in sessions {
            if s.isWaiting {
                // Asking isn't finishing: the work it started carries on once someone replies.
                if waitingSince[s.id] == nil {
                    waitingSince[s.id] = now
                    if primed { events.append(.waiting(id: s.id)) }
                }
                continue
            }
            waitingSince[s.id] = nil
            if s.isBusy {
                if busySince[s.id] == nil { busySince[s.id] = now }
            } else if let start = busySince.removeValue(forKey: s.id), now.timeIntervalSince(start) >= Self.minimumWork {
                events.append(.finished(id: s.id, after: now.timeIntervalSince(start)))
                finishedAt[s.id] = now
            }
        }
        let live = Set(sessions.map(\.id))
        busySince = busySince.filter { live.contains($0.key) }
        waitingSince = waitingSince.filter { live.contains($0.key) }
        finishedAt = finishedAt.filter { live.contains($0.key) }
        primed = true   // the first reading is a baseline: sessions already waiting at launch don't notify
        return events
    }
}
