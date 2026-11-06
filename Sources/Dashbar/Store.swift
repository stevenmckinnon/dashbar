import Foundation
import Combine
import Darwin

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [LiveSession] = []
    @Published var otherAgents: [AgentProcess] = []
    @Published var claude = UsageSummary.empty
    @Published var codex = UsageSummary.empty
    @Published var codexLimits: [RateLimit] = []
    @Published var listeners: [Listener] = []
    @Published var system = SystemSnapshot()
    @Published var cpuHistory: [Double] = []
    @Published var lastUpdated = Date()
    @Published var usageLoading = true

    var busyCount: Int { sessions.filter(\.isBusy).count }
    var devListeners: [Listener] { listeners.filter(\.isDev) }
    var otherListeners: [Listener] { listeners.filter { !$0.isDev } }

    private let worker = Worker()
    private var tick = 0
    private var timer: Timer?

    init() {
        refresh(usage: true, servers: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        tick += 1
        refresh(usage: tick % 5 == 0, servers: tick % 2 == 0)   // usage ~15s, servers ~6s, rest ~3s
    }

    func refreshNow() { refresh(usage: true, servers: true) }

    func stop(_ l: Listener) {
        kill(l.pid, SIGTERM)
        listeners.removeAll { $0.pid == l.pid }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(usage: false, servers: true) }
    }

    private func refresh(usage: Bool, servers: Bool) {
        worker.collect(usage: usage, servers: servers) { [weak self] r in
            guard let self else { return }
            self.sessions = r.sessions
            self.otherAgents = r.agents
            self.system = r.system
            self.cpuHistory = Array((self.cpuHistory + [r.system.cpu]).suffix(40))
            if let l = r.listeners { self.listeners = l }
            if let c = r.claude { self.claude = c; self.usageLoading = false }
            if let c = r.codex { self.codex = c; self.codexLimits = r.codexLimits }
            self.lastUpdated = Date()
        }
    }
}

/// Owns all collectors and runs them on one serial background queue.
final class Worker: @unchecked Sendable {
    struct Result {
        var sessions: [LiveSession] = []
        var agents: [AgentProcess] = []
        var system = SystemSnapshot()
        var listeners: [Listener]?
        var claude: UsageSummary?
        var codex: UsageSummary?
        var codexLimits: [RateLimit] = []
    }

    private let queue = DispatchQueue(label: "dashbar.worker", qos: .utility)
    private let claudeScanner = ClaudeUsageScanner()
    private let codexScanner = CodexUsageScanner()
    private let sampler = SystemSampler()
    private var inFlight = false

    func collect(usage: Bool, servers: Bool, done: @escaping @MainActor (Result) -> Void) {
        queue.async { [self] in
            if inFlight { return }
            inFlight = true
            defer { inFlight = false }
            var r = Result()
            r.sessions = ClaudeSessions.read()
            r.agents = AgentProcesses.read(psOutput: Shell.run("/bin/ps", ["-axo", "pid=,comm="]))
            r.system = sampler.sample()
            if servers { r.listeners = Listeners.read() }
            if usage {
                r.claude = claudeScanner.scan()
                r.codex = codexScanner.scan()
                r.codexLimits = codexScanner.limits
            }
            let result = r
            DispatchQueue.main.async { done(result) }
        }
    }
}
