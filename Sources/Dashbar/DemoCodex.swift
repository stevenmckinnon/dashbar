import Foundation

/// Invented Codex sessions for screenshots (`DASHBAR_DEMO_CODEX=1`): one working in its own workspace and one idle
/// beside Claude's. Off by default, so published pictures don't change.
@MainActor
extension DemoData {
    static func applyCodex(to store: Store, now: Date) {
        func session(_ id: String, _ folder: String, _ status: String, _ ago: TimeInterval, _ pid: Int32) -> LiveSession {
            let root = "/Users/demo/Development/" + folder
            var s = LiveSession(id: "codex-demo-" + id, pid: pid, name: folder, cwd: root, status: status,
                                since: now.addingTimeInterval(-ago), entrypoint: "cli", root: root)
            s.agent = .codex
            return s
        }
        let added = [session("a", "mobile-app", "busy", 3 * 60, 9801), session("b", "storefront-web", "idle", 12 * 60, 9802)]
        store.sessions = (store.sessions + added).sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        store.workspaceUsage["/Users/demo/Development/mobile-app"] =
            WorkspaceUsage(cpu: 0.11, memory: 420 * 1_048_576, watts: 0.9, started: now.addingTimeInterval(-25 * 60),
                           processes: [], branch: "main")
        store.otherAgents.removeAll { $0.name == "Codex" }
    }
}
