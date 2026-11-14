import Foundation
import Combine

/// Keeps the Claude plan limits current from up to two sources and decides which reading to show.
///
/// - The status line bridge (recommended): a file Claude Code's status line writes after each reply. Reading it is
///   free, so it is read whenever agent logs change and on every regular refresh.
/// - Anthropic's usage endpoint (experimental, off by default): asked at most every 5 minutes, sharing readings and
///   backoffs with any other copy of Dashbar so only one asks, and waiting out rate limits and failures.
///
/// When both have something, the fresher reading wins; a fresh status line reading means the endpoint isn't asked.
/// Everything outside (the request, the clock, the shared file, timers) comes in through `Dependencies`, so tests can
/// drive every state.
@MainActor
final class ClaudePlanMonitor: ObservableObject {
    @Published private(set) var result: ClaudePlanLimits.Result?
    @Published private(set) var loading = false
    /// After a temporary failure, no request goes out before this, not even from Retry or Refresh: asking again while
    /// rate limited only keeps the limit tripped.
    @Published private(set) var retryAt: Date?
    /// Claude Code is running to refresh its own sign-in.
    @Published private(set) var signingIn = false

    struct Dependencies {
        var fetch: @Sendable () async -> ClaudePlanLimits.Result
        var refreshSignIn: @Sendable () async -> String?
        var now: () -> Date
        var loadShared: () -> ClaudePlanLimits.Shared?
        var saveShared: (ClaudePlanLimits.Shared) -> Void
        var readStatusLine: () -> ClaudeStatusLine.Reading?
        /// Calls back after the given number of seconds, on the main actor.
        var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void

        static var live: Dependencies {
            Dependencies(
                fetch: { await ClaudePlanLimits.fetch() },
                refreshSignIn: { await ClaudePlanLimits.refreshSignIn() },
                now: { Date() },
                loadShared: { ClaudePlanLimits.Shared.load() },
                saveShared: { $0.save() },
                readStatusLine: { ClaudeStatusLine.read() },
                after: { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { MainActor.assumeIsolated { work() } }
                })
        }
    }

    /// The status line bridge is added to Claude Code's settings.
    private(set) var statusLineEnabled = false
    /// The experimental endpoint setting is on.
    private(set) var endpointEnabled = false
    var anyEnabled: Bool { statusLineEnabled || endpointEnabled }
    /// Called after the shown reading changes (the store checks limit alerts).
    var onUpdate: (() -> Void)?
    /// A reading this young from the status line is current: the endpoint isn't asked.
    static let freshStatusLine: TimeInterval = 240

    private let deps: Dependencies
    private var failures = 0
    private var endpointResult: ClaudePlanLimits.Result?
    private var statusLineReading: ClaudeStatusLine.Reading?

    init(dependencies: Dependencies = .live) {
        deps = dependencies
    }

    // MARK: Settings

    @discardableResult
    func setStatusLineEnabled(_ on: Bool) -> Task<Void, Never>? {
        guard on != statusLineEnabled else { return nil }
        statusLineEnabled = on
        if !on { statusLineReading = nil }
        return refresh(force: true)
    }

    @discardableResult
    func setEndpointEnabled(_ on: Bool) -> Task<Void, Never>? {
        guard on != endpointEnabled else { return nil }
        endpointEnabled = on
        if on {
            return refresh(force: true)
        } else {
            // A request already on its way is ignored when it lands (see `finish`).
            endpointResult = nil
            failures = 0
            retryAt = nil
            publish()
            return nil
        }
    }

    // MARK: Refreshing

    /// Re-reads the status line file. Cheap: call it whenever Claude Code may have replied.
    func statusLineChanged() {
        guard statusLineEnabled else { return }
        readStatusLine()
        publish()
    }

    /// Reads the status line, then asks the endpoint if it's on and nothing current is at hand. Returns the request's
    /// task when one starts (tests await it).
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never>? {
        readStatusLine()
        defer { publish() }
        guard endpointEnabled, !loading else { return nil }
        let now = deps.now()
        if let reading = statusLineReading, !reading.current(now: now).isEmpty,
           now.timeIntervalSince(reading.writtenAt) < Self.freshStatusLine { return nil }
        if let retryAt, now < retryAt { return nil }
        if !force, let fetched = endpointResult?.fetchedAt, endpointResult?.stale == nil,
           now.timeIntervalSince(fetched) < 60 { return nil }

        // Another copy of Dashbar (the release beside a local build) may have just asked, or be waiting out a limit.
        let shared = deps.loadShared()
        switch shared?.decide(now: now, force: force) {
        case .useShared?:
            if let shared, (endpointResult?.fetchedAt ?? .distantPast) < (shared.fetchedAt ?? .distantPast) || endpointResult?.stale != nil {
                endpointResult = shared.result()
                failures = 0
                retryAt = nil
            }
            return nil
        case .wait(let until)?:
            if let shared, !shared.limits.isEmpty {
                endpointResult = shared.result(stale: .rateLimited)
            } else if endpointResult?.limits.isEmpty ?? true {
                endpointResult = ClaudePlanLimits.Result(plan: endpointResult?.plan, problem: ClaudePlanLimits.rateLimitedMessage, transient: true)
            }
            scheduleRetry(at: until)
            return nil
        default:
            break
        }

        loading = true
        let fetch = deps.fetch
        return Task { @MainActor in
            let result = await fetch()
            self.finish(result)
        }
    }

    private func finish(_ result: ClaudePlanLimits.Result) {
        loading = false
        guard endpointEnabled else { return }   // turned off while the request was out
        var record = deps.loadShared() ?? ClaudePlanLimits.Shared()
        if result.transient {
            failures += 1
            let until = deps.now().addingTimeInterval(ClaudePlanLimits.backoff(failures: failures, retryAfter: result.retryAfter))
            scheduleRetry(at: until)
            record.retryAt = until
            deps.saveShared(record)
        } else {
            failures = 0
            retryAt = nil
            if result.problem == nil {
                deps.saveShared(ClaudePlanLimits.Shared(fetchedAt: result.fetchedAt, plan: result.plan, limits: result.limits))
            }
        }
        endpointResult = ClaudePlanLimits.keepingLastGood(endpointResult, result)
        publish()
    }

    /// Waits until `until`, then tries again, so the countdown means what it says (the regular check is 5 minutes).
    private func scheduleRetry(at until: Date) {
        retryAt = until
        deps.after(until.timeIntervalSince(deps.now()) + 1) { [weak self] in
            guard let self, self.retryAt == until else { return }
            self.refresh(force: true)
        }
    }

    /// Has Claude Code refresh its own sign-in, then asks again.
    @discardableResult
    func refreshSignIn() -> Task<Void, Never>? {
        guard endpointEnabled, !signingIn else { return nil }
        signingIn = true
        let run = deps.refreshSignIn
        return Task { @MainActor in
            let problem = await run()
            self.signingIn = false
            if let problem {
                self.endpointResult = ClaudePlanLimits.Result(plan: self.endpointResult?.plan, problem: problem)
                self.publish()
            } else {
                self.refresh(force: true)
            }
        }
    }

    // MARK: Choosing what to show

    private func readStatusLine() {
        statusLineReading = statusLineEnabled ? deps.readStatusLine() : nil
    }

    private var statusLineResult: ClaudePlanLimits.Result? {
        guard let reading = statusLineReading else { return nil }
        if reading.unrecognised {
            return ClaudePlanLimits.Result(problem: ClaudeStatusLine.unrecognisedMessage, fetchedAt: reading.writtenAt, source: .statusLine)
        }
        let limits = reading.current(now: deps.now())
        guard !limits.isEmpty else { return nil }   // every window has reset since: wait for the next reply
        return ClaudePlanLimits.Result(limits: limits, plan: endpointResult?.plan, fetchedAt: reading.writtenAt, source: .statusLine)
    }

    private func publish() {
        let shown = Self.preferred(statusLine: statusLineResult, endpoint: endpointEnabled ? endpointResult : nil)
        result = shown
        onUpdate?()
    }

    /// The fresher of two good readings; a good reading over a problem; otherwise the endpoint's problem (it has an
    /// action), else the status line's.
    static func preferred(statusLine: ClaudePlanLimits.Result?, endpoint: ClaudePlanLimits.Result?) -> ClaudePlanLimits.Result? {
        func good(_ r: ClaudePlanLimits.Result?) -> ClaudePlanLimits.Result? {
            guard let r, r.problem == nil, !r.limits.isEmpty else { return nil }
            return r
        }
        switch (good(statusLine), good(endpoint)) {
        case let (s?, e?): return s.fetchedAt >= e.fetchedAt ? s : e
        case let (s?, nil): return s
        case let (nil, e?): return e
        case (nil, nil): return endpoint ?? statusLine
        }
    }
}
