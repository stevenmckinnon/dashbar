import Foundation
import SwiftUI

// MARK: - "Show in Dashbar", per tool

/// The tools that can be switched off in Settings → Integrations. Claude Code is not one of them: Dashbar is built
/// around it, so it always shows (there is deliberately no `claude` case, and a saved "claude" is ignored).
///
/// Google's tools (Gemini CLI, the Antigravity CLI and the Antigravity app) share one switch, as they share one Usage card,
/// one colour and one Integrations section.
enum HideableTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, google, opencode, copilot
    var id: String { rawValue }

    /// The heading people read in Settings.
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .google: return "Gemini CLI and Antigravity"
        case .opencode: return "OpenCode"
        case .copilot: return CopilotCLI.integrationsTitle
        }
    }
}

extension SessionAgent {
    /// Which switch hides this agent's sessions. Nil for Claude Code, which can't be hidden.
    var hideableTool: HideableTool? {
        switch self {
        case .claude: return nil
        case .geminiCLI, .antigravityCLI, .antigravity: return .google
        case .opencode: return .opencode
        case .copilot: return .copilot
        }
    }
}

/// Which tools are switched off. Everything shows by default.
///
/// Off means hidden everywhere (workspaces, the Now card, Usage, History, notifications, the island, the menu bar, the
/// widgets' counts and the `dashbar` status file) and that tool's collectors don't run at all, so Dashbar reads none of
/// its files. Its plugin, hook or status line stays installed and may keep writing its small files; Dashbar ignores them
/// until the tool is switched back on, and the next refresh restores everything.
struct ToolVisibility: Equatable, Sendable {
    private(set) var hidden: Set<HideableTool> = []

    static let all = ToolVisibility()

    init(hidden: Set<HideableTool> = []) { self.hidden = hidden }

    func shows(_ tool: HideableTool) -> Bool { !hidden.contains(tool) }
    /// Claude Code always shows.
    func shows(agent: SessionAgent) -> Bool { agent.hideableTool.map(shows) ?? true }

    mutating func set(_ tool: HideableTool, shown: Bool) {
        if shown { hidden.remove(tool) } else { hidden.insert(tool) }
    }

    /// Only the sessions of tools that show.
    func filter(_ sessions: [LiveSession]) -> [LiveSession] {
        hidden.isEmpty ? sessions : sessions.filter { shows(agent: $0.agent) }
    }

    /// The "other AI tools" chips: Codex's are dropped while Codex is off (its CLI and its app).
    func filter(_ agents: [AgentProcess]) -> [AgentProcess] {
        shows(.codex) ? agents : agents.filter { !["Codex", "Codex app"].contains($0.name) }
    }

    // MARK: Saving

    /// UserDefaults key: the ids of the tools switched off, as strings.
    static let key = "hiddenTools"
    /// `--demo` runs read this instead, in memory only: "codex,copilot".
    static let demoVariable = "DASHBAR_DEMO_HIDDEN"

    /// Unknown ids, and "claude", are ignored.
    static func parse(_ ids: [String]) -> ToolVisibility {
        ToolVisibility(hidden: Set(ids.compactMap { HideableTool(rawValue: $0.trimmingCharacters(in: .whitespaces)) }))
    }

    var ids: [String] { hidden.map(\.rawValue).sorted() }

    static func load(from defaults: UserDefaults) -> ToolVisibility {
        parse(defaults.stringArray(forKey: key) ?? [])
    }

    func save(to defaults: UserDefaults) {
        if hidden.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(ids, forKey: Self.key) }
    }

    /// What a run starts with: the saved choice, or for `--demo` the demo variable (never the real preferences).
    static func initial(arguments: [String] = CommandLine.arguments,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard) -> ToolVisibility {
        if arguments.contains("--demo") {
            return parse((environment[demoVariable] ?? "").split(separator: ",").map(String.init))
        }
        return load(from: defaults)
    }
}

// MARK: - Applying it to readings

extension Worker.LiveResult {
    /// The reading without hidden tools: their sessions, Google's warning and the Codex chips go.
    func hiding(_ v: ToolVisibility) -> Worker.LiveResult {
        guard !v.hidden.isEmpty else { return self }
        var r = self
        r.sessions = v.filter(sessions)
        if !v.shows(.google) { r.googleWarning = nil }
        r.agents = agents.map { v.filter($0) }
        if let usage = workspaceUsage {
            // Workspaces only a hidden tool had are gone; so is what was sampled for them.
            let roots = Set(r.sessions.map(\.root))
            let hiddenRoots = Set(sessions.filter { !v.shows(agent: $0.agent) }.map(\.root)).subtracting(roots)
            r.workspaceUsage = usage.filter { !hiddenRoots.contains($0.key) }
        }
        return r
    }
}

extension Worker.UsageResult {
    /// The reading without hidden tools: their usage, limits and accounts are empty.
    func hiding(_ v: ToolVisibility) -> Worker.UsageResult {
        guard !v.hidden.isEmpty else { return self }
        var r = self
        if !v.shows(.codex) {
            r.codex = .empty
            r.codexLimits = []
            r.codexAccounts = []
            r.codexAccountLimits = []
            r.codexLimitsAt = .distantPast
        }
        if !v.shows(.google) {
            r.google = .empty
            r.googleSources = []
            r.antigravityLimits = nil
        }
        if !v.shows(.opencode) { r.opencode = .empty }
        if !v.shows(.copilot) { r.copilot = CopilotUsage.empty }
        return r
    }
}

// MARK: - Whether a tool is on this Mac

/// Whether each switchable tool looks installed, from a few folder checks (never by reading its files), so its
/// Integrations section can show even while it's switched off and its collectors aren't running.
@MainActor
final class ToolPresence: ObservableObject {
    static let shared = ToolPresence()
    @Published private(set) var found: Set<HideableTool> = []

    private init() {
        if CommandLine.arguments.contains("--demo") {
            let env = ProcessInfo.processInfo.environment
            var f: Set<HideableTool> = [.codex]   // the demo always has Codex
            if env["DASHBAR_DEMO_GOOGLE"] != nil { f.insert(.google) }
            if env["DASHBAR_DEMO_OPENCODE"] != nil { f.insert(.opencode) }
            if env["DASHBAR_DEMO_COPILOT"] != nil { f.insert(.copilot) }
            found = f
        } else {
            refresh()
        }
    }

    func refresh() {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let f = Self.detect()
        if f != found { found = f }
    }

    nonisolated static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<HideableTool> {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        var out = Set<HideableTool>()
        if AgentAccounts.resolve(.codex, saved: []).contains(where: { exists($0.sessionsDir) || exists(URL(fileURLWithPath: $0.path)) }) {
            out.insert(.codex)
        }
        if exists(homeDir.appendingPathComponent(".gemini")) || exists(URL(fileURLWithPath: "/Applications/Antigravity.app")) {
            out.insert(.google)
        }
        if OpenCodeBridge.status(.default()) != .absent { out.insert(.opencode) }
        if CopilotCLI.isPresent(home: CopilotCLI.homeURL(environment: environment)) { out.insert(.copilot) }
        return out
    }
}

/// The first row of a switchable tool's Integrations section. Off collapses the section to this row alone.
struct ShowInDashbarToggle: View {
    let tool: HideableTool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: Binding(get: { settings.visibility.shows(tool) }, set: { settings.setShown(tool, $0) })) {
            Text("Show in Dashbar")
            Text(settings.visibility.shows(tool)
                 ? ([.codex, .google].contains(tool) ? "Its sessions, usage and plan limits show across Dashbar."
                                                     : "Its sessions and usage show across Dashbar.")
                 : "Hidden everywhere, and none of its files are read. Anything you added to it stays installed.")
        }
    }
}
