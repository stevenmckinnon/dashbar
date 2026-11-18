import Foundation
import Darwin
import SwiftUI
import AppKit

/// What Settings → About → Copy Diagnostics puts on the pasteboard, for a GitHub issue: versions, which tools and
/// integrations Dashbar found, any format warnings, the widgets' state, how many extra accounts and where Claude's plan
/// limits come from.
///
/// The value deliberately holds no free text from the user's Mac: only booleans, counts, dates, Dashbar's and macOS's
/// version strings and the warnings Dashbar itself writes (fixed sentences, checked again by `safe(_:)`). So it can't
/// carry a project or workspace name, a folder, a session id, a prompt or title, an account label or email, a token,
/// a hostname or a user name. `DiagnosticsTests` feeds it private-looking demo data and checks none of it comes out.
struct Diagnostics: Equatable, Sendable {
    struct App: Equatable, Sendable {
        var version: String
        var build: String
        var isLocal: Bool
        /// "27.2 (Build 26C5049a)".
        var macOS: String
        var appleSilicon: Bool
    }

    /// The tools Dashbar reads, in the order Settings lists them.
    enum Tool: String, CaseIterable, Sendable {
        case claude, codex, geminiCLI, antigravity, opencode, copilot

        var title: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .geminiCLI: return "Gemini CLI"
            case .antigravity: return "Antigravity"
            case .opencode: return "OpenCode"
            case .copilot: return CopilotCLI.displayName
            }
        }

        /// Its Show in Dashbar switch. Nil for Claude Code, which always shows.
        var hideable: HideableTool? {
            switch self {
            case .claude: return nil
            case .codex: return .codex
            case .geminiCLI, .antigravity: return .google
            case .opencode: return .opencode
            case .copilot: return .copilot
            }
        }
    }

    struct ToolState: Equatable, Sendable {
        var tool: Tool
        var found: Bool
        /// False when switched off in Show in Dashbar.
        var shown: Bool
        /// The tool's own version, only where Dashbar already reads one. None does today, so this stays nil.
        var version: String? = nil
    }

    struct Warning: Equatable, Sendable {
        var tool: Tool
        var text: String
    }

    /// The opt-in pieces Dashbar can add, in the order Settings → Integrations lists them.
    enum Bridge: String, CaseIterable, Sendable {
        case claudeStatusLine, claudePermissionHook, antigravityStatusLine, opencodePlugin, copilotHook, commandLineTool

        var title: String {
            switch self {
            case .claudeStatusLine: return "Claude Code status line"
            case .claudePermissionHook: return "Claude Code permission hook"
            case .antigravityStatusLine: return "Antigravity CLI status line"
            case .opencodePlugin: return "OpenCode plugin"
            case .copilotHook: return "GitHub Copilot hook"
            case .commandLineTool: return "dashbar command on PATH"
            }
        }
    }

    struct BridgeState: Equatable, Sendable {
        var bridge: Bridge
        /// Nil when it can't apply: its tool isn't on this Mac, or a development build has no command-line tool.
        var installed: Bool?
        /// For the Claude Code ones while more than one account is read: in how many of how many.
        var accounts: (installed: Int, total: Int)? = nil

        static func == (a: BridgeState, b: BridgeState) -> Bool {
            a.bridge == b.bridge && a.installed == b.installed
                && a.accounts?.installed == b.accounts?.installed && a.accounts?.total == b.accounts?.total
        }
    }

    struct Widgets: Equatable, Sendable {
        var appGroup: Bool
        /// When this run of Dashbar last wrote the widgets' file. Nil if it hasn't yet.
        var lastWritten: Date?
    }

    enum LimitsSource: Equatable, Sendable {
        case statusLine, request, none

        var title: String {
            switch self {
            case .statusLine: return "status line"
            case .request: return "experimental request"
            case .none: return "none"
            }
        }
    }

    struct ClaudeLimits: Equatable, Sendable {
        var source: LimitsSource
        var hasReading: Bool
        var stale: Bool
    }

    var app: App
    var tools: [ToolState]
    var warnings: [Warning]
    var bridges: [BridgeState]
    var widgets: Widgets
    var extraClaudeAccounts: Int
    var extraCodexAccounts: Int
    var claudeLimits: ClaudeLimits

    // MARK: The text

    /// Free text that may go out: only if it can't be a path, an email or a user name. Warnings and versions are
    /// Dashbar's own strings, so this never drops one today; it's here so a later change can't quietly leak one.
    static func safe(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 300, !t.contains("/"), !t.contains("~"), !t.contains("@"), !t.contains("\\"),
              !t.contains("\n") else { return nil }
        return t
    }

    /// "just now", "4 min ago", "3 h ago", "2 days ago". Fixed English, so the text reads the same in any issue.
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        let d = s / 86400
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }

    /// The Markdown that's copied.
    func markdown(now: Date = Date()) -> String {
        var lines: [String] = ["### Dashbar diagnostics", ""]
        func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

        let version = Self.safe(app.version) ?? "unknown"
        let build = Self.safe(app.build).map { " (build \($0))" } ?? ""
        lines.append("- Dashbar: \(version)\(build), \(app.isLocal ? "local build" : "release")")
        lines.append("- macOS: \(Self.safe(app.macOS) ?? "unknown")")
        lines.append("- Mac: \(app.appleSilicon ? "Apple silicon" : "Intel")")

        lines += ["", "**Tools**"]
        for t in tools {
            var parts = [t.found ? "found" : "not found"]
            if !t.shown { parts.append("switched off in Show in Dashbar") }
            if let v = t.version.flatMap(Self.safe) { parts.append("version \(v)") }
            lines.append("- \(t.tool.title): " + parts.joined(separator: ", "))
        }

        lines += ["", "**Warnings**"]
        let shown = warnings.compactMap { w in Self.safe(w.text).map { "- \(w.tool.title): \($0)" } }
        lines += shown.isEmpty ? ["- None"] : shown

        lines += ["", "**Integrations**"]
        for b in bridges {
            var value = b.installed.map(yesNo) ?? "not applicable"
            if let a = b.accounts, b.installed != nil { value += " (in \(a.installed) of \(a.total) accounts)" }
            lines.append("- \(b.bridge.title): \(value)")
        }

        lines += ["", "**Widgets**"]
        lines.append("- App Group: \(widgets.appGroup ? "available" : "none (ad-hoc build)")")
        if widgets.appGroup {
            lines.append("- Widget data last written: " + (widgets.lastWritten.map { Self.ago($0, now: now) } ?? "not yet"))
        }

        lines += ["", "**Accounts**"]
        lines.append("- Extra Claude Code accounts: \(extraClaudeAccounts)")
        lines.append("- Extra Codex accounts: \(extraCodexAccounts)")

        lines += ["", "**Claude plan limits**"]
        lines.append("- Source: \(claudeLimits.source.title)")
        if claudeLimits.source != .none {
            lines.append("- Last reading: " + (!claudeLimits.hasReading ? "none yet" : claudeLimits.stale ? "stale" : "current"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Building it

extension Diagnostics {
    /// What isn't in the store: settings, folder checks and bridge states. `live()` reads this Mac; tests make their own,
    /// so nothing here needs the real file system.
    struct Context: Sendable {
        var app: App
        /// Switchable tools whose folders exist (`ToolPresence`).
        var present: Set<HideableTool>
        /// Gemini CLI's and Antigravity's own folder checks, since they share one switch and one presence flag.
        var geminiPresent: Bool
        var antigravityPresent: Bool
        var visibility: ToolVisibility
        var bridges: [BridgeState]
        var widgets: Widgets
        var claudeAccounts: Int
        var codexAccounts: Int
        var statusLineOn: Bool
        var requestOn: Bool
    }

    @MainActor init(store: Store, context c: Context) {
        let sessions = Set(store.sessions.map(\.agent))
        let google = Set(store.googleSources).union(sessions)
        func found(_ tool: Tool) -> Bool {
            switch tool {
            case .claude: return store.claude.found || sessions.contains(.claude)
            case .codex: return c.present.contains(.codex) || store.codex.found
            case .geminiCLI: return c.geminiPresent || google.contains(.geminiCLI)
            case .antigravity: return c.antigravityPresent || !google.isDisjoint(with: [.antigravityCLI, .antigravity])
            case .opencode: return c.present.contains(.opencode) || store.opencode.found || sessions.contains(.opencode)
            case .copilot: return c.present.contains(.copilot) || store.copilot.summary.found || sessions.contains(.copilot)
            }
        }
        tools = Tool.allCases.map { t in
            ToolState(tool: t, found: found(t), shown: t.hideable.map(c.visibility.shows) ?? true)
        }

        // The same warnings the banner shows (`Store.formatWarning`), each with its tool.
        var w: [Warning] = []
        func add(_ tool: Tool, _ text: String?) {
            if let text, !w.contains(where: { $0.tool == tool && $0.text == text }) { w.append(Warning(tool: tool, text: text)) }
        }
        add(.claude, store.claude.warning)
        add(.claude, store.sessionsWarning)
        add(.claude, store.subagentsWarning)
        add(.codex, store.codex.warning)
        add(.geminiCLI, store.google.warning)
        add(store.googleWarning == AntigravityApp.formatWarning ? .antigravity : .geminiCLI, store.googleWarning)
        add(.opencode, store.opencode.warning)
        add(.copilot, store.copilot.summary.warning)
        warnings = w

        app = c.app
        bridges = c.bridges
        widgets = c.widgets
        extraClaudeAccounts = max(0, c.claudeAccounts - 1)
        extraCodexAccounts = max(0, c.codexAccounts - 1)

        let reading = store.claudePlan
        let source: LimitsSource
        switch reading?.source {
        case .statusLine?: source = .statusLine
        case .endpoint?: source = .request
        case nil: source = c.statusLineOn ? .statusLine : c.requestOn ? .request : .none
        }
        let has = reading.map { $0.problem == nil || !$0.limits.isEmpty } ?? false
        claudeLimits = ClaudeLimits(source: source, hasReading: has, stale: reading?.stale != nil)
    }

    /// The text for the store as it is now.
    @MainActor static func text(for store: Store, now: Date = Date()) -> String {
        let context = CommandLine.arguments.contains("--demo") ? Context.demo() : Context.live()
        return Diagnostics(store: store, context: context).markdown(now: now)
    }
}

extension Diagnostics.App {
    static var current: Diagnostics.App {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return .init(version: BuildInfo.version, build: info["CFBundleVersion"] as? String ?? "dev",
                     isLocal: BuildInfo.isLocal,
                     macOS: os.hasPrefix("Version ") ? String(os.dropFirst("Version ".count)) : os,
                     appleSilicon: appleSiliconHardware)
    }

    /// The Mac's chip, not the process's: true under Rosetta too.
    static var appleSiliconHardware: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

extension Diagnostics.Context {
    /// This Mac, from what Settings already mirrors (bridge states, accounts, Show in Dashbar) plus a few folder checks
    /// that read no files. Called when About opens and when Copy Diagnostics is pressed, never in the background.
    @MainActor static func live() -> Diagnostics.Context {
        let settings = AppSettings.shared
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        let claudeAccounts = settings.claudeAccounts
        func claude(_ bridge: Diagnostics.Bridge, _ installed: (ResolvedAccount) -> Bool) -> Diagnostics.BridgeState {
            let count = claudeAccounts.filter(installed).count
            return .init(bridge: bridge, installed: count > 0,
                         accounts: claudeAccounts.count > 1 ? (count, claudeAccounts.count) : nil)
        }
        let antigravity = AntigravitySettings.shared.status
        let opencode = OpenCodeSettings.shared.status
        let copilot = CopilotSettings.shared.status
        let tool = CommandLineToolSection.bundledTool
        let bridges: [Diagnostics.BridgeState] = [
            claude(.claudeStatusLine) { a in
                a.isDefault ? settings.claudeStatusLineStatus.isInstalled : settings.accountStatusLines[a.path]?.isInstalled == true
            },
            claude(.claudePermissionHook) { a in
                a.isDefault ? settings.claudePermissionsStatus.isInstalled : settings.accountPermissions[a.path]?.isInstalled == true
            },
            .init(bridge: .antigravityStatusLine, installed: antigravity == .absent ? nil : antigravity.isInstalled),
            .init(bridge: .opencodePlugin, installed: opencode == .absent ? nil : opencode.isInstalled),
            .init(bridge: .copilotHook, installed: copilot == .absent ? nil : copilot.isInstalled),
            .init(bridge: .commandLineTool, installed: tool.map { CommandLineToolSection.linked(to: $0) != nil }),
        ]
        let gemini = homeDir.appendingPathComponent(".gemini")
        return .init(
            app: .current,
            present: ToolPresence.shared.found,
            geminiPresent: exists(GeminiUsageScanner.defaultRoot),
            antigravityPresent: exists(URL(fileURLWithPath: "/Applications/Antigravity.app"))
                || exists(gemini.appendingPathComponent("antigravity")) || exists(gemini.appendingPathComponent("antigravity-cli")),
            visibility: settings.visibility,
            bridges: bridges,
            widgets: .init(appGroup: WidgetBridge.active != nil, lastWritten: WidgetBridge.active?.lastWritten),
            claudeAccounts: claudeAccounts.count,
            codexAccounts: settings.codexAccounts.count,
            statusLineOn: settings.claudeStatusLine,
            requestOn: settings.claudeLimits)
    }

    /// For `--demo` renders: the demo's tools and settings (already in memory only), and no real folders or files.
    @MainActor static func demo(now: Date = Date()) -> Diagnostics.Context {
        let env = ProcessInfo.processInfo.environment
        let settings = AppSettings.shared
        let present = ToolPresence.shared.found
        let accounts = settings.claudeAccounts.count
        let google = present.contains(.google)
        return .init(
            app: .current,
            present: present,
            geminiPresent: google,
            antigravityPresent: google,
            visibility: settings.visibility,
            bridges: [
                .init(bridge: .claudeStatusLine, installed: env["DASHBAR_DEMO_STATUSLINE"] != nil,
                      accounts: accounts > 1 ? (env["DASHBAR_DEMO_STATUSLINE"] != nil ? 1 : 0, accounts) : nil),
                .init(bridge: .claudePermissionHook, installed: env["DASHBAR_DEMO_PERMISSION"] != nil,
                      accounts: accounts > 1 ? (env["DASHBAR_DEMO_PERMISSION"] != nil ? 1 : 0, accounts) : nil),
                .init(bridge: .antigravityStatusLine, installed: google ? true : nil),
                .init(bridge: .opencodePlugin, installed: present.contains(.opencode) ? true : nil),
                .init(bridge: .copilotHook, installed: present.contains(.copilot) ? false : nil),
                .init(bridge: .commandLineTool, installed: true),
            ],
            widgets: .init(appGroup: true, lastWritten: now.addingTimeInterval(-40)),
            claudeAccounts: accounts,
            codexAccounts: settings.codexAccounts.count,
            statusLineOn: env["DASHBAR_DEMO_STATUSLINE"] != nil,
            requestOn: settings.claudeLimits)
    }
}

// MARK: - Settings → About

/// Copy Diagnostics, with the exact text readable before it's copied. Built when About opens, again when the text is
/// shown and again on Copy, so what's copied is what the Mac looks like at that moment.
struct DiagnosticsSection: View {
    /// Not observed: the text is built on demand, so About needn't redraw on every refresh.
    let store: Store
    @State private var text = ""
    @State private var copied = false
    @State private var resetCopied: DispatchWorkItem?
    /// `DASHBAR_SETTINGS_EXPANDED=1` opens the text in a demo snapshot.
    @State private var showing = CommandLine.arguments.contains("--demo")
        && ProcessInfo.processInfo.environment["DASHBAR_SETTINGS_EXPANDED"] != nil

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Diagnostics", action: copy)
                    .accessibilityLabel(copied ? "Diagnostics copied" : "Copy diagnostics")
                    .accessibilityHint("Copies a summary for a bug report to the clipboard")
                Button(showing ? "Hide Diagnostics" : "Show Diagnostics") {
                    if !showing { refresh() }
                    showing.toggle()
                }
                .accessibilityHint(showing ? "Hides the text" : "Shows the exact text that Copy Diagnostics copies")
            }
            Text("Versions, tools found, integrations and warnings, for a bug report. No names or folders. Nothing is sent.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showing {
                ScrollView {
                    Text(text)
                        .font(.system(size: UI.Size.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(UI.gap)
                }
                .frame(height: 300)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: UI.innerRadius))
                .overlay(RoundedRectangle(cornerRadius: UI.innerRadius).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Diagnostics text")
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() { text = Diagnostics.text(for: store) }

    private func copy() {
        refresh()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        resetCopied?.cancel()
        let reset = DispatchWorkItem { copied = false }
        resetCopied = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }
}
