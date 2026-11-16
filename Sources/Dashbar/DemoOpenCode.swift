import Foundation

/// Invented opencode data for screenshots (`DASHBAR_DEMO_OPENCODE=1`): a working session in its own workspace and two
/// weeks of usage across three models, one of them local and free. `DASHBAR_DEMO_OPENCODE=waiting` has the session
/// waiting for you instead, as the plugin reports it. Off by default, so published pictures don't change.
@MainActor
extension DemoData {
    static func applyOpenCode(to store: Store, now: Date, waiting: Bool) {
        let root = "/Users/demo/Development/recipe-box"
        var s = LiveSession(id: "opencode-demo", pid: 9701, name: "recipe-box", cwd: root, status: waiting ? "waiting" : "busy",
                            since: now.addingTimeInterval(waiting ? -40 : -6 * 60), entrypoint: "cli", root: root)
        s.agent = .opencode
        store.sessions = (store.sessions + [s]).sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        store.workspaceUsage[root] = WorkspaceUsage(cpu: 0.04, memory: 310 * 1_048_576, watts: 0.4,
                                                    started: now.addingTimeInterval(-50 * 60), processes: [], branch: "main")

        // Assistant messages as the reader sees them, through the same ledger code (`OpenCode.book`).
        var rows: [OpenCode.UsageRow] = []
        let cal = Calendar.current
        for day in 0..<14 {
            let scale = [1.0, 0.0, 0.7, 1.3, 0.4, 0.0, 0.9, 1.1, 0.5, 0.8, 0.0, 0.6, 1.2, 0.3][day]
            guard scale > 0, let date = cal.date(byAdding: .day, value: -day, to: now) else { continue }
            for hour in stride(from: 0.0, to: 4, by: 1) {
                let at = day == 0 ? now.addingTimeInterval(-hour * 2400 - 300) : date.addingTimeInterval(-hour * 3600)
                func row(_ model: String, _ provider: String, _ input: Int, _ output: Int, _ cache: Int, cost: Double?) -> OpenCode.UsageRow {
                    OpenCode.UsageRow(session: "demo-\(day)", directory: hour < 3 ? root : "/Users/demo/Development/docs-site",
                                      subagent: false, created: at, provider: provider, model: model,
                                      input: Int(Double(input) * scale), output: Int(Double(output) * scale), reasoning: 0,
                                      cacheRead: Int(Double(cache) * scale), cacheWrite: 0, cost: cost.map { $0 * scale }, completed: true)
                }
                rows.append(row("claude-sonnet-5-5", "anthropic", 90_000, 14_000, 1_100_000, cost: nil))
                rows.append(row("gpt-6.1-terra", "openai", 60_000, 9_000, 400_000, cost: 0.11))
                rows.append(row("qwen3-coder", "ollama", 40_000, 6_000, 0, cost: 0))
            }
        }
        store.opencode = OpenCode.book(rows).summary(found: true)
    }
}
