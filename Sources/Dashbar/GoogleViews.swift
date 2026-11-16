import SwiftUI
import AppKit

// MARK: - Usage

enum GoogleUsage {
    /// The usage card's title: whichever of Google's tools the usage came from.
    static func title(_ sources: [SessionAgent]) -> String {
        switch (sources.contains(.geminiCLI), sources.contains(.antigravityCLI)) {
        case (true, true): return "Gemini CLI · Antigravity"
        case (false, true): return "Antigravity CLI"
        default: return "Gemini CLI"
        }
    }

    static func costNote(_ sources: [SessionAgent]) -> String? {
        sources.contains(.antigravityCLI) ? "The Antigravity CLI's sessions use its own cost estimate." : nil
    }
}

// MARK: - Plan limits

/// Antigravity's quota in its Usage card: each model group's windows, from its CLI's status line.
struct AntigravityLimitsBlock: View {
    let limits: AntigravityLimits?
    let connected: Bool
    /// "Antigravity · Google AI Pro" over the rows, when the card's title doesn't already say whose limits they are.
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                LimitsSubheader(text: ["Antigravity", limits?.planTier].compactMap { $0 }.joined(separator: " · "))
            }
            if let problem = limits?.problem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: UI.Size.caption))
            } else if let limits, !limits.isEmpty {
                LimitList(limits: limits.flattened, tint: UI.google)
                if let fetched = limits.fetchedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        if let line = Self.ageLine(writtenAt: fetched, now: ctx.date) {
                            HStack(spacing: 5) {
                                Image(systemName: "clock").accessibilityHidden(true)
                                Text(line).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        }
                    }
                }
            } else if connected {
                Text("Limits appear after your next Antigravity CLI session.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No limits reported yet.").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            }
        }
    }

    /// "Updated 25m ago · refreshes next time you use the Antigravity CLI". Nil while recent.
    static func ageLine(writtenAt: Date, now: Date) -> String? {
        guard now.timeIntervalSince(writtenAt) >= 5 * 60 else { return nil }
        return "Updated \(Fmt.ago(writtenAt, now: now)) ago · refreshes next time you use the Antigravity CLI"
    }
}

// MARK: - Settings

/// Whether Dashbar's bridge is in the Antigravity CLI's status line. Like the Claude one it mirrors the CLI's settings
/// file rather than being a preference, so it's re-read at launch, every few minutes and when Settings opens.
@MainActor
final class AntigravitySettings: ObservableObject {
    static let shared = AntigravitySettings()
    @Published private(set) var status: AntigravityBridge.Status = .absent

    private init() {
        if CommandLine.arguments.contains("--demo"), ProcessInfo.processInfo.environment["DASHBAR_DEMO_GOOGLE"] != nil {
            status = .installed(previous: nil)
        }
    }

    func refresh(paths: AntigravityBridge.Paths = .default()) {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let s = AntigravityBridge.status(paths)
        if s.isInstalled { try? AntigravityBridge.writeScript(paths) }
        if s != status { status = s }
    }

    /// Adds or removes the bridge. Returns what went wrong, phrased for the user.
    func set(_ on: Bool, paths: AntigravityBridge.Paths = .default()) -> String? {
        var problem: String?
        do { on ? try AntigravityBridge.install(paths) : try AntigravityBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refresh(paths: paths)
        return problem
    }
}

/// Integrations → Gemini CLI and Antigravity: whether Google's tools show (one switch for all three, as they share a Usage
/// card), then, for the Antigravity CLI, add or remove the status line bridge. Shown only when one of them is on this Mac,
/// the bridge is in, or they're switched off (so they can be switched back on).
struct AntigravityLabsSection: View {
    @ObservedObject private var settings = AntigravitySettings.shared
    @ObservedObject private var app = AppSettings.shared
    @ObservedObject private var presence = ToolPresence.shared
    @State private var problem: String?

    var body: some View {
        let shown = app.visibility.shows(.google)
        if settings.status != .absent || presence.found.contains(.google) || !shown {
            Section {
                ShowInDashbarToggle(tool: .google)
                if shown && settings.status != .absent {
                    row
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    IntegrationDetails(text: explanation)
                }
            } header: {
                Text(HideableTool.google.title)
            }
        }
    }

    @ViewBuilder private var row: some View {
        switch settings.status {
        case .installed(let previous):
            LabeledContent {
                Button("Remove") { problem = settings.set(false) }
            } label: {
                Text("In the Antigravity CLI's status line")
                Text(previous.map { "Your status line (\(Self.short($0))) still shows." } ?? "Updates as the CLI works.")
            }
        case .notInstalled(let current):
            LabeledContent {
                Button("Add to Status Line") { problem = settings.set(true) }
            } label: {
                Text("Read limits and usage from its status line")
                Text(current.map { "Your status line (\(Self.short($0))) keeps showing." } ?? "Off until you add it. Sends nothing.")
            }
        case .unreadable(let message):
            LabeledContent {
                Button("Check Again") { problem = nil; settings.refresh() }
            } label: {
                Text("Read limits and usage from its status line")
                Text(message)
            }
        case .absent:
            EmptyView()
        }
    }

    static func short(_ command: String) -> String {
        command.count > 48 ? String(command.prefix(47)) + "…" : command
    }

    private var explanation: String {
        let file = Fmt.tilde(AntigravityBridge.Paths.default().settings.path)
        return "The Antigravity CLI passes its quota, token totals and estimated cost to its status line as it works. "
            + "Adding Dashbar changes one setting, statusLine in \(file), to a small script that saves just those numbers, "
            + "the session's folder, model and state to files on this Mac, then runs the status line you had, so it looks the "
            + "same. It never saves your email or conversations. A backup of the file is kept; Remove puts your previous "
            + "status line back exactly."
    }
}
