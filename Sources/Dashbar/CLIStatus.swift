import Foundation
import Combine
import DashbarStatus

/// Keeps the command-line tool's status file (`StatusSnapshot`) up to date from what the store already has.
///
/// Always on: it reads nothing new and sends nothing, it holds only what the panel shows (never prompts, session titles,
/// session ids or sign-ins), and the file is readable only by you. It is rebuilt only when a value it is made from
/// changes, at most every few seconds, and written only when the result differs, so a quiet Mac writes nothing.
@MainActor
enum CLIStatus {
    /// Rebuilt at most this often while values keep changing (agents writing logs, say).
    static let interval: RunLoop.SchedulerTimeType.Stride = .seconds(3)

    /// Starts following `store`. Not for demo stores or snapshot runs, which must never replace the real file.
    static func follow(_ store: Store) -> AnyCancellable {
        let writer = StatusSnapshotWriter(url: StatusSnapshot.fileURL(appName: BuildInfo.appName))
        let widgets = WidgetBridge.forThisBuild()
        WidgetBridge.active = widgets
        let changes: [AnyPublisher<Void, Never>] = [
            store.$sessions.map { _ in () }.eraseToAnyPublisher(),
            store.$subagents.map { _ in () }.eraseToAnyPublisher(),
            store.$claudePlan.map { _ in () }.eraseToAnyPublisher(),
            store.$claudeAccountLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$codexLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$codexAccountLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$antigravityLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$planHistory.map { _ in () }.eraseToAnyPublisher(),   // today's share is worked out from it
            store.$claude.map { _ in () }.eraseToAnyPublisher(),
            store.$codex.map { _ in () }.eraseToAnyPublisher(),
            store.$google.map { _ in () }.eraseToAnyPublisher(),
            store.$opencode.map { _ in () }.eraseToAnyPublisher(),
            store.$copilot.map { _ in () }.eraseToAnyPublisher(),
            store.$listeners.map { _ in () }.eraseToAnyPublisher(),
            store.$paused.map { _ in () }.eraseToAnyPublisher(),
            store.$sessionsWarning.map { _ in () }.eraseToAnyPublisher(),
            store.$codexSessionsWarning.map { _ in () }.eraseToAnyPublisher(),
            // A tool switched off or on, even one with nothing showing, so the widgets can say it's off.
            AppSettings.shared.$visibility.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published sends before the value is stored, so the snapshot is built on a later turn of the run loop.
        return Publishers.MergeMany(changes)
            .throttle(for: interval, scheduler: RunLoop.main, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak store] in
                guard let store else { return }
                let status = snapshot(of: store, showsClaudeLimits: AppSettings.shared.showsClaudeLimits)
                writer.write(status)
                widgets?.update(status, showsCost: UserDefaults.standard.object(forKey: CostLine.showKey) as? Bool ?? true)
            }
    }

    /// What the store knows, in the tool's terms. Times are absolute, so the snapshot only changes when the state does.
    /// A tool switched off (`visibility`, Settings' by default) is left out, though the store has already dropped what
    /// it showed, and named in `hidden`.
    static func snapshot(of store: Store, showsClaudeLimits: Bool, visibility: ToolVisibility? = nil,
                         now: Date = Date()) -> StatusSnapshot {
        let v = visibility ?? store.visibility
        return StatusSnapshot(
            generatedAt: now,
            app: .init(name: BuildInfo.appName, version: BuildInfo.version, pid: getpid(), paused: store.paused),
            warning: store.formatWarning,
            sessions: v.filter(store.sessions).map { s in
                StatusSnapshot.Session(tool: toolID(s.agent), account: s.account, workspace: s.project, folder: s.root,
                                       state: state(s), since: s.since, subagents: store.subagents(for: s).running.count)
            },
            limits: limitGroups(store, showsClaudeLimits: showsClaudeLimits, now: now).filter { shows($0.provider, v) },
            usageToday: usage(store, now: now).flatMap { u in
                let tools = u.tools.filter { shows($0.tool, v) }
                return tools.isEmpty ? nil : .init(day: u.day, tools: tools)
            },
            servers: store.devListeners.map {
                StatusSnapshot.Server(workspace: $0.isDocker ? nil : $0.project, folder: $0.isDocker ? nil : $0.root,
                                      port: $0.port, command: $0.command, pid: $0.pid, title: $0.title)
            },
            hidden: v.hidden.isEmpty ? nil : v.ids)
    }

    /// Whether a provider or tool id in the snapshot ("codex", "antigravity", "google", …) belongs to a tool that shows.
    nonisolated static func shows(_ id: String, _ v: ToolVisibility) -> Bool {
        HideableTool(rawValue: StatusSnapshot.switchID(id)).map(v.shows) ?? true
    }

    nonisolated static func toolID(_ agent: SessionAgent) -> String {
        switch agent {
        case .claude: return "claude"
        case .codex: return "codex"
        case .geminiCLI: return "gemini-cli"
        case .antigravityCLI: return "antigravity-cli"
        case .antigravity: return "antigravity"
        case .opencode: return "opencode"
        case .copilot: return "copilot"
        }
    }

    nonisolated static func state(_ s: LiveSession) -> StatusSnapshot.State {
        if s.isWaiting { return s.waitingFor == "permission prompt" ? .permission : .needsYou }
        return s.isBusy ? .working : .idle
    }

    /// `samples` are its weekly series' readings, for today's share; nil for a limit without one.
    nonisolated static func limit(_ l: RateLimit, samples: [PlanHistory.Sample]? = nil, now: Date) -> StatusSnapshot.Limit {
        let share = samples.flatMap { TodayShare.compute(l, samples: $0, now: now) }
        return StatusSnapshot.Limit(label: l.label, window: l.window.map(RateLimit.name(window:)), windowSeconds: l.window,
                                    usedPercent: l.usedPercent, resetsAt: l.resetsAt,
                                    todayShare: share.map { Self.tenth($0.share) }, usedToday: share.map { Self.tenth($0.usedToday) })
            .withPace(now: now)
    }

    /// To a tenth of a percent, so the file doesn't change with every rounding wobble.
    nonisolated static func tenth(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private static func limits(_ list: [RateLimit], _ history: [String: [PlanHistory.Sample]], now: Date) -> [StatusSnapshot.Limit] {
        list.map { limit($0, samples: history[$0.label], now: now) }
    }

    /// The same accounts, in the same order, as the Overview's plan strip: Claude, its other accounts, Codex, Antigravity.
    static func limitGroups(_ store: Store, showsClaudeLimits: Bool, now: Date) -> [StatusSnapshot.LimitGroup] {
        var out: [StatusSnapshot.LimitGroup] = []
        if showsClaudeLimits, let plan = store.claudePlan {
            out.append(.init(provider: "claude", account: store.claudePlanLabel, plan: plan.plan, readAt: plan.fetchedAt,
                             stale: plan.stale != nil, problem: plan.problem,
                             limits: plan.problem == nil ? limits(plan.limits, store.shareHistory(plan.limits, provider: .claude, account: nil), now: now) : []))
        }
        for a in store.claudeAccountLimits where a.problem != nil || !a.limits.isEmpty {
            out.append(.init(provider: "claude", account: a.label, plan: a.plan, readAt: a.fetchedAt, problem: a.problem,
                             limits: a.problem == nil ? limits(a.limits, store.shareHistory(claudeAccount: a), now: now) : []))
        }
        if !store.codexAccountLimits.isEmpty {
            for a in store.codexAccountLimits where !a.limits.isEmpty {
                out.append(.init(provider: "codex", account: a.label, readAt: a.fetchedAt, limits: limits(a.limits, store.shareHistory(codexAccount: a), now: now)))
            }
        } else if store.codex.found, !store.codexLimits.isEmpty {
            out.append(.init(provider: "codex", readAt: store.codexLimitsAt > .distantPast ? store.codexLimitsAt : nil,
                             limits: limits(store.codexLimits, store.shareHistory(store.codexLimits, provider: .codex, account: nil), now: now)))
        }
        if let ag = store.antigravityLimits, ag.problem != nil || !ag.isEmpty {
            out.append(.init(provider: "antigravity", plan: ag.planTier, readAt: ag.fetchedAt, problem: ag.problem,
                             limits: ag.problem == nil ? limits(ag.flattened, store.antigravityShareHistory, now: now) : []))
        }
        return out
    }

    /// Today's tokens for each tool that has logs, with the estimated cost the Usage tab shows (none for Copilot, which
    /// is billed by premium requests: those instead). Nil when no tool has logs.
    static func usage(_ store: Store, now: Date) -> StatusSnapshot.UsageToday? {
        func tokens(_ id: String, _ name: String, _ s: UsageSummary, priced: Bool = true, premium: Double? = nil,
                    model: Bool = false) -> StatusSnapshot.ToolTokens? {
            guard s.found else { return nil }
            let today = s.period(.today)
            let cost = priced && today.cost > 0 ? today.cost : nil
            let top = model ? RankList.shortModels(today.models).max { $0.value < $1.value }.map(\.name) : nil
            return .init(tool: id, name: name, input: s.today.input, output: s.today.output,
                         cacheRead: s.today.cacheRead, cacheWrite: s.today.cacheWrite,
                         cost: cost, premiumRequests: premium, model: top)
        }
        let tools = [tokens("claude", "Claude", store.claude), tokens("codex", "Codex", store.codex),
                     tokens("google", GoogleUsage.title(store.googleSources), store.google),
                     tokens("opencode", "OpenCode", store.opencode, model: true),
                     tokens("copilot", CopilotCLI.displayName, store.copilot.summary, priced: false,
                            premium: store.copilot.premium(.today, now: now))].compactMap { $0 }
        return tools.isEmpty ? nil : .init(day: StatusSnapshot.dayKey(now), tools: tools)
    }
}
