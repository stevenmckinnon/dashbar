import Foundation

/// Invented GitHub Copilot CLI data for screenshots (`DASHBAR_DEMO_COPILOT=1`): a working session in its own workspace and
/// two weeks of usage across three models, with premium requests. `DASHBAR_DEMO_COPILOT=waiting` has the session waiting
/// for permission instead, as its event log records it. Off by default, so published pictures don't change.
@MainActor
extension DemoData {
    static func applyCopilot(to store: Store, now: Date, waiting: Bool) {
        let root = "/Users/demo/Development/invoice-api"
        var s = LiveSession(id: "copilot-demo", pid: 9811, name: "invoice-api", cwd: root, status: waiting ? "waiting" : "busy",
                            since: now.addingTimeInterval(waiting ? -25 : -4 * 60), entrypoint: "cli", root: root,
                            waitingFor: waiting ? "permission prompt" : nil)
        s.agent = .copilot
        store.sessions = (store.sessions + [s]).sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        store.workspaceUsage[root] = WorkspaceUsage(cpu: 0.03, memory: 260 * 1_048_576, watts: 0.3,
                                                    started: now.addingTimeInterval(-35 * 60), processes: [], branch: "main")

        // Shutdown records as the scanner books them: the growth of each model's totals, at the moment a session ended.
        var book = UsageBook()
        var premium: [String: Double] = [:]
        let cal = Calendar.current
        for day in 0..<14 {
            let scale = [0.8, 1.1, 0.0, 0.6, 1.4, 0.0, 0.0, 0.9, 1.2, 0.5, 0.7, 0.0, 1.0, 0.4][day]
            guard scale > 0, let date = cal.date(byAdding: .day, value: -day, to: now) else { continue }
            for end in 0..<3 {
                let at = day == 0 ? now.addingTimeInterval(-Double(end) * 3000 - 900) : date.addingTimeInterval(-Double(end) * 5400)
                func add(_ model: String, _ input: Int, _ output: Int, _ cached: Int, requests: Int) {
                    let t = TokenTotals(input: Int(Double(input) * scale), output: Int(Double(output) * scale),
                                        cacheRead: Int(Double(cached) * scale), messages: requests)
                    book.add(t, at: at, model: model, project: end < 2 ? "invoice-api" : "status-page",
                             session: "demo-\(day)-\(end)", cost: nil)
                }
                add("claude-sonnet-4.5", 120_000, 9_000, 980_000, requests: 18)
                add("gpt-5.4", 70_000, 6_000, 310_000, requests: 9)
                add("claude-haiku-4.5", 30_000, 2_000, 90_000, requests: 6)
                premium[UsageBook.dayKey.string(from: at), default: 0] += (3 * scale).rounded()
            }
        }
        store.copilot = CopilotUsage(summary: book.summary(found: true), premiumByDay: premium)
    }
}
