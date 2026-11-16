import SwiftUI
import AppKit

// MARK: - Google's agents: Gemini CLI, Antigravity CLI (agy) and the Antigravity app

/// Which agent a live session belongs to. Claude Code's sessions are the default; the rest come from Google's tools and
/// opencode, each read from what that tool already keeps on this Mac (see `GeminiCLI`, `AntigravityStatusLine`,
/// `AntigravityApp`, `OpenCode`).
enum SessionAgent: String, Equatable, CaseIterable {
    case claude, geminiCLI, antigravityCLI, antigravity, opencode

    /// "Claude", "Gemini CLI", "Antigravity CLI", "Antigravity": the subject of "… is working".
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .geminiCLI: return "Gemini CLI"
        case .antigravityCLI: return "Antigravity CLI"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"   // as its brand page writes it (opencode.ai/brand); the command is `opencode`
        }
    }

    var isGoogle: Bool { [.geminiCLI, .antigravityCLI, .antigravity].contains(self) }

    /// The symbol that names the agent: Claude's asterisk, the one sparkle every Google agent shares, or opencode's.
    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .opencode: return UI.openCodeSymbol
        default: return UI.googleSymbol
        }
    }

    var tint: Color {
        switch self {
        case .claude: return UI.claude
        case .opencode: return UI.neutralTool
        default: return UI.google
        }
    }
}

extension UI {
    /// Google's agents (Gemini CLI, Antigravity), as orange is Claude and teal is Codex: brand only, never status.
    /// Indigo, from the blue-to-violet of Gemini's mark. Plain blue is already the ink for ports and links
    /// (`textInfo`), so indigo keeps "this is Google's" apart from "this is clickable". Each pair keeps 4.5:1 or more
    /// on the card surface as text.
    static let google = Color(light: .init(hex: 0x4F4DD0), dark: .init(hex: 0x9C9AFF))
    static let googleSymbol = "sparkle"
}

/// What the Google collectors found, for the store. Everything is empty for someone who uses none of these tools, so
/// nothing about them shows.
struct GoogleLive: Equatable {
    var sessions: [LiveSession] = []
    /// A format Dashbar no longer reads (Antigravity's conversation database changed shape, say).
    var warning: String?
}

/// Antigravity's plan limits, from its CLI's status line (`AntigravityStatusLine`).
struct AntigravityLimits: Equatable {
    /// The subscription tier the CLI reported ("Pro"), if any.
    var planTier: String?
    /// Each model group's windows, in the order the CLI listed them.
    var groups: [Group] = []
    var fetchedAt: Date?
    /// The reading is in a shape Dashbar doesn't know.
    var problem: String?

    struct Group: Equatable, Identifiable {
        var id: String { key }
        /// The bucket IDs' shared part ("gemini"), which keys this group's plan history.
        let key: String
        /// "Gemini", "Claude and GPT".
        let name: String
        /// "5-hour" and "Weekly" when the bucket says which; the group's name otherwise.
        var limits: [RateLimit]
    }

    var isEmpty: Bool { groups.allSatisfy(\.limits.isEmpty) }

    /// Every window as one list, each labelled with its group while there is more than one ("Gemini · Weekly"). A
    /// window with no length of its own is already labelled with its group's name, so it isn't said twice.
    var flattened: [RateLimit] {
        groups.flatMap { g in
            g.limits.map { l in
                groups.count > 1 && l.label != g.name
                    ? RateLimit(label: "\(g.name) · \(l.label)", usedPercent: l.usedPercent, resetsAt: l.resetsAt, window: l.window, source: l.source)
                    : l
            }
        }
    }

    /// The plan-history account a group's series is saved under: hex, like an account's key, so its file
    /// (`plan-history-<key>.json`) sits beside the others and copies of Dashbar that predate Antigravity skip it.
    static func historyKey(_ group: String) -> String { AgentAccounts.hash("antigravity:" + group) }
}

extension LiveSession {
    /// Whether the session has a title of its own. Google's agents (and an untitled Claude Code session) are named after
    /// their folder, which every row already shows as the workspace or project.
    var hasOwnTitle: Bool { name != project }
    /// What a row calls the session: its own title, or else the agent ("Antigravity CLI"), so the folder isn't repeated.
    var title: String { hasOwnTitle ? name : agent.name }
    /// Where and what, for a line under `title`: the project, and another agent's name unless `title` already is it.
    var identityParts: [String] {
        [project] + (agent != .claude && hasOwnTitle ? [agent.name] : [])
    }
    /// Another agent's name (not Claude's) for a row under a workspace heading, unless `title` already is it.
    var agentNote: String? { agent != .claude && hasOwnTitle ? agent.name : nil }
}
