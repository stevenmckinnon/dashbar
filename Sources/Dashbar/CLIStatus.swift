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
        let changes: [AnyPublisher<Void, Never>] = [
            store.$sessions.map { _ in () }.eraseToAnyPublisher(),
            store.$subagents.map { _ in () }.eraseToAnyPublisher(),
            store.$claudePlan.map { _ in () }.eraseToAnyPublisher(),
            store.$claudeAccountLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$codexLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$codexAccountLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$antigravityLimits.map { _ in () }.eraseToAnyPublisher(),
            store.$claude.map { _ in () }.eraseToAnyPublisher(),
            store.$codex.map { _ in () }.eraseToAnyPublisher(),
            store.$google.map { _ in () }.eraseToAnyPublisher(),
            store.$opencode.map { _ in () }.eraseToAnyPublisher(),
            store.$listeners.map { _ in () }.eraseToAnyPublisher(),
            store.$paused.map { _ in () }.eraseToAnyPublisher(),
            store.$sessionsWarning.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published sends before the value is stored, so the snapshot is built on a later turn of the run loop.
        return Publishers.MergeMany(changes)
            .throttle(for: interval, scheduler: RunLoop.main, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak store] in
                guard let store else { return }
                let status = snapshot(of: store, showsClaudeLimits: AppSettings.shared.showsClaudeLimits)
                writer.write(status)
                widgets?.update(status)
            }
    }

    /// What the store knows, in the tool's terms. Times are absolute, so the snapshot only changes when the state does.
    static func snapshot(of store: Store, showsClaudeLimits: Bool, now: Date = Date()) -> StatusSnapshot {
        StatusSnapshot(
            generatedAt: now,
            app: .init(name: BuildInfo.appName, version: BuildInfo.version, pid: getpid(), paused: store.paused),
            warning: store.formatWarning,
            sessions: store.sessions.map { s in
                StatusSnapshot.Session(tool: toolID(s.agent), account: s.account, workspace: s.project, folder: s.root,
                                       state: state(s), since: s.since, subagents: store.subagents(for: s).running.count)
            },
            limits: limitGroups(store, showsClaudeLimits: showsClaudeLimits, now: now),
            usageToday: usage(store, now: now),
            servers: store.devListeners.map {
                StatusSnapshot.Server(workspace: $0.isDocker ? nil : $0.project, folder: $0.isDocker ? nil : $0.root,
                                      port: $0.port, command: $0.command, pid: $0.pid, title: $0.title)
            })
    }

    nonisolated static func toolID(_ agent: SessionAgent) -> String {
        switch agent {
        case .claude: return "claude"
        case .geminiCLI: return "gemini-cli"
        case .antigravityCLI: return "antigravity-cli"
        case .antigravity: return "antigravity"
        case .opencode: return "opencode"
        }
    }

    nonisolated static func state(_ s: LiveSession) -> StatusSnapshot.State {
        if s.isWaiting { return s.waitingFor == "permission prompt" ? .permission : .needsYou }
        return s.isBusy ? .working : .idle
    }

    nonisolated static func limit(_ l: RateLimit, now: Date) -> StatusSnapshot.Limit {
        StatusSnapshot.Limit(label: l.label, window: l.window.map(RateLimit.name(window:)), windowSeconds: l.window,
                             usedPercent: l.usedPercent, resetsAt: l.resetsAt).withPace(now: now)
    }

    /// The same accounts, in the same order, as the Overview's plan strip: Claude, its other accounts, Codex, Antigravity.
    static func limitGroups(_ store: Store, showsClaudeLimits: Bool, now: Date) -> [StatusSnapshot.LimitGroup] {
        var out: [StatusSnapshot.LimitGroup] = []
        if showsClaudeLimits, let plan = store.claudePlan {
            out.append(.init(provider: "claude", account: store.claudePlanLabel, plan: plan.plan, readAt: plan.fetchedAt,
                             stale: plan.stale != nil, problem: plan.problem,
                             limits: plan.problem == nil ? plan.limits.map { limit($0, now: now) } : []))
        }
        for a in store.claudeAccountLimits where a.problem != nil || !a.limits.isEmpty {
            out.append(.init(provider: "claude", account: a.label, plan: a.plan, readAt: a.fetchedAt, problem: a.problem,
                             limits: a.problem == nil ? a.limits.map { limit($0, now: now) } : []))
        }
        if !store.codexAccountLimits.isEmpty {
            for a in store.codexAccountLimits where !a.limits.isEmpty {
                out.append(.init(provider: "codex", account: a.label, readAt: a.fetchedAt, limits: a.limits.map { limit($0, now: now) }))
            }
        } else if store.codex.found, !store.codexLimits.isEmpty {
            out.append(.init(provider: "codex", readAt: store.codexLimitsAt > .distantPast ? store.codexLimitsAt : nil,
                             limits: store.codexLimits.map { limit($0, now: now) }))
        }
        if let ag = store.antigravityLimits, ag.problem != nil || !ag.isEmpty {
            out.append(.init(provider: "antigravity", plan: ag.planTier, readAt: ag.fetchedAt, problem: ag.problem,
                             limits: ag.problem == nil ? ag.flattened.map { limit($0, now: now) } : []))
        }
        return out
    }

    /// Today's tokens for each tool that has logs. Nil when none has.
    static func usage(_ store: Store, now: Date) -> StatusSnapshot.UsageToday? {
        func tokens(_ id: String, _ name: String, _ s: UsageSummary) -> StatusSnapshot.ToolTokens? {
            guard s.found else { return nil }
            return .init(tool: id, name: name, input: s.today.input, output: s.today.output,
                         cacheRead: s.today.cacheRead, cacheWrite: s.today.cacheWrite)
        }
        let tools = [tokens("claude", "Claude", store.claude), tokens("codex", "Codex", store.codex),
                     tokens("google", GoogleUsage.title(store.googleSources), store.google),
                     tokens("opencode", "OpenCode", store.opencode)].compactMap { $0 }
        return tools.isEmpty ? nil : .init(day: StatusSnapshot.dayKey(now), tools: tools)
    }
}
