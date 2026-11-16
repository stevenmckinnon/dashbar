import Foundation
import SwiftUI

/// Whether each GitHub Copilot CLI session is working, idle, waiting for you or ended, from Copilot's official hooks.
///
/// Copilot CLI loads every `*.json` in `~/.copilot/hooks/` (`$COPILOT_HOME/hooks/` if set): `{"version": 1, "hooks":
/// {<event>: [{"type": "command", "bash": …, "timeoutSec": …}]}}` (docs.github.com/en/copilot/reference/hooks-reference,
/// checked 16 Nov 2026; changelog: "Load personal hooks from ~/.copilot/hooks"). Every payload carries `sessionId` and
/// `cwd`. So Dashbar adds a file of its own, `dashbar.json`, rather than editing anyone else's: Remove deletes that file
/// only if every command in it is Dashbar's, and an existing `dashbar.json` Dashbar didn't write (or that isn't valid JSON)
/// is left alone and reported.
///
/// The events used, all fire-and-forget or fail-open per the reference: `sessionStart` (idle), `userPromptSubmitted` and
/// `postToolUse` (working), `notification` with `notification_type` `permission_prompt` or `elicitation_dialog` (needs
/// you), `agentStop` (idle) and `sessionEnd` (ended). Deliberately not `preToolUse` (a failing hook there denies the tool)
/// or `permissionRequest` (whose output decides a permission): the script never answers anything.
///
/// The script reads the payload, keeps only the session id and folder, and writes exactly four fields (`sessionId`, `cwd`,
/// `state`, `timestamp`) to `~/Library/Caches/Dashbar/copilot-sessions/<id>.json` (folder 0700, file 0600). It drops
/// `prompt`, `initialPrompt`, `toolArgs`, `toolResult`, `transcriptPath` and the notification's `message` and `title` by
/// never reading them. It prints nothing, exits 0 whatever happens, and has a short timeout, so it can't hold Copilot up.
enum CopilotBridge {
    static let configName = "dashbar.json"
    static let scriptName = "dashbar-copilot-hook.sh"
    static let timeout = 5
    /// Event → the state it writes. `notification` writes only for the two kinds that wait for you.
    static let events = ["sessionStart", "userPromptSubmitted", "postToolUse", "notification", "agentStop", "sessionEnd"]

    /// Where the hook saves states. Shared by every copy of Dashbar (the release and a local build).
    static let statesDir = homeDir.appendingPathComponent("Library/Caches/Dashbar/copilot-sessions")

    /// `$DASHBAR_COPILOT_DIR` overrides the folder (tests use it). Everything it runs is an absolute path to a tool every
    /// Mac has; `plutil` reads the payload and writes the file, so text is always escaped properly.
    static let script = #"""
    #!/bin/sh
    # Dashbar's GitHub Copilot CLI hook (version 1). Dashbar added it with your consent, from Settings > Integrations.
    # Copilot CLI runs it at a few moments in each session. It saves four things (the session's id, its folder, whether
    # it is working, idle, waiting for you or ended, and the time) to a file on this Mac that only you can read, so
    # Dashbar can show it. It never saves prompts, tool input or results, transcripts or notification text, never answers
    # a permission, prints nothing, always exits 0 and sends nothing anywhere. Remove it in Dashbar's Settings.
    dir="${DASHBAR_COPILOT_DIR:-$HOME/Library/Caches/Dashbar/copilot-sessions}"
    umask 077

    field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

    main() {
      input=$(/bin/cat)   # read it all, so Copilot never writes to a closed pipe
      case $1 in
        sessionStart|agentStop) state=idle ;;
        userPromptSubmitted|postToolUse) state=working ;;
        sessionEnd) state=ended ;;
        notification)
          case $(field notification_type) in
            permission_prompt|elicitation_dialog) state=needsYou ;;
            *) return 0 ;;
          esac ;;
        *) return 0 ;;
      esac
      id=$(field sessionId)
      [ -n "$id" ] || id=$(field session_id)
      id=$(printf '%s' "$id" | LC_ALL=C /usr/bin/tr -cd 'A-Za-z0-9_-' | /usr/bin/cut -c1-128)
      [ -n "$id" ] || return 0
      cwd=$(field cwd)
      case $cwd in /*) ;; *) cwd= ;; esac
      [ ${#cwd} -lt 4096 ] || cwd=
      /bin/mkdir -p "$dir" && /bin/chmod 700 "$dir" || return 0
      tmp="$dir/.$id.$$"
      # Starts as JSON with one key: plutil reads a bare {} as an old-style plist and won't write it.
      printf '{"state":"%s"}' "$state" >"$tmp" || return 0
      /usr/bin/plutil -insert sessionId -string "$id" "$tmp" &&
        /usr/bin/plutil -insert cwd -string "$cwd" "$tmp" &&
        /usr/bin/plutil -insert timestamp -integer "$(/bin/date +%s)" "$tmp" &&
        /bin/chmod 600 "$tmp" &&
        /bin/mv -f "$tmp" "$dir/$id.json" || /bin/rm -f "$tmp"
    }

    main "$1" >/dev/null 2>&1
    exit 0
    """#

    // MARK: Paths

    struct Paths {
        /// Copilot's folder (`~/.copilot`).
        var home: URL
        /// Dashbar's own folder for scripts (`~/Library/Application Support/Dashbar`), shared with the other bridges.
        var support: URL
        var states: URL = CopilotBridge.statesDir

        var hooks: URL { home.appendingPathComponent("hooks") }
        var config: URL { hooks.appendingPathComponent(CopilotBridge.configName) }
        var script: URL { support.appendingPathComponent(CopilotBridge.scriptName) }

        static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
            Paths(home: CopilotCLI.homeURL(environment: environment),
                  support: homeDir.appendingPathComponent("Library/Application Support/Dashbar"))
        }
    }

    // MARK: The hooks file

    /// `'…'` for the shell, with any `'` in the path closed, escaped and reopened.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func command(_ paths: Paths, event: String) -> String { "/bin/sh \(quote(paths.script.path)) \(event)" }

    /// The whole `dashbar.json`.
    static func config(_ paths: Paths) -> Data {
        var hooks: [String: Any] = [:]
        for e in events {
            hooks[e] = [["type": "command", "bash": command(paths, event: e), "timeoutSec": timeout] as [String: Any]]
        }
        let o: [String: Any] = ["version": 1, "hooks": hooks]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Whether a hooks file is Dashbar's: valid JSON whose every command runs Dashbar's script. Nil when it doesn't exist.
    static func isOurs(_ url: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .uncached), data.count < 256 * 1024,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = o["hooks"] as? [String: Any], !hooks.isEmpty else { return false }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]], !entries.isEmpty else { return false }
            for entry in entries {
                let commands = ["bash", "command", "powershell"].compactMap { entry[$0] as? String }
                guard !commands.isEmpty, commands.allSatisfy({ $0.contains(scriptName) }) else { return false }
            }
        }
        return true
    }

    // MARK: Status

    enum Status: Equatable {
        /// Copilot CLI isn't on this Mac and the hook isn't in: Settings shows nothing.
        case absent
        case notInstalled
        case installed
        /// A `dashbar.json` Dashbar didn't write (or that isn't valid JSON) is in Copilot's hooks folder. Left alone.
        case conflict

        var isInstalled: Bool { self == .installed }
    }

    enum Failure: LocalizedError, Equatable {
        case notOurs(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notOurs(let path):
                return "There's already a dashbar.json that Dashbar didn't write (\(Fmt.tilde(path))). Dashbar left it alone. Rename or remove it, then try again."
            case .writeFailed(let why):
                return "Couldn't save the hook to Copilot's hooks folder (\(why)). Nothing was changed."
            }
        }
    }

    static func status(_ paths: Paths) -> Status {
        switch isOurs(paths.config) {
        case true?: return .installed
        case false?: return .conflict
        case nil: return CopilotCLI.isPresent(home: paths.home) ? .notInstalled : .absent
        }
    }

    // MARK: Install and remove

    /// Writes the script, then `dashbar.json`. The hooks file is checked again just before it's written, so a file of the
    /// same name that appeared meanwhile is never replaced.
    static func install(_ paths: Paths) throws {
        if isOurs(paths.config) == false { throw Failure.notOurs(paths.config.path) }
        try writeScript(paths)
        let data = config(paths)
        if (try? Data(contentsOf: paths.config)) == data { return }
        do {
            try FileManager.default.createDirectory(at: paths.hooks, withIntermediateDirectories: true)
            guard isOurs(paths.config) != false else { throw Failure.notOurs(paths.config.path) }   // re-read before writing
            try data.write(to: paths.config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.config.path)
        } catch let f as Failure {
            throw f
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Deletes `dashbar.json` (only if it's Dashbar's), the script and the states it saved. Nothing else in Copilot's
    /// folders is touched.
    static func uninstall(_ paths: Paths) throws {
        let fm = FileManager.default
        if isOurs(paths.config) == true {
            do { try fm.removeItem(at: paths.config) } catch { throw Failure.writeFailed(error.localizedDescription) }
        }
        try? fm.removeItem(at: paths.script)
        try? fm.removeItem(at: paths.states)
    }

    /// Writes the script if it is missing or from another version of Dashbar. Called at launch while the hook is in.
    static func writeScript(_ paths: Paths) throws {
        let data = Data(script.utf8)
        if (try? Data(contentsOf: paths.script)) == data { return }
        do {
            try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try data.write(to: paths.script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.script.path)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Reading what the hook saved

    /// One session as the hook last saw it.
    struct SessionState: Equatable {
        var id: String
        var directory: String
        /// "working", "idle", "needsYou" or "ended".
        var state: String
        var writtenAt: Date

        /// `LiveSession.status`: busy, idle or waiting.
        var liveStatus: String {
            switch state {
            case "working": return "busy"
            case "needsYou": return "waiting"
            default: return "idle"
            }
        }
    }

    static func parseState(_ data: Data) -> SessionState? {
        guard data.count < 8192, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["sessionId"] as? String, !id.isEmpty, id.count <= 128,
              let state = o["state"] as? String, ["working", "idle", "needsYou", "ended"].contains(state),
              let written = (o["timestamp"] as? NSNumber)?.doubleValue, written > 0 else { return nil }
        let directory = (o["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? ""
        return SessionState(id: id, directory: directory, state: state,
                            writtenAt: Date(timeIntervalSince1970: written > 1e11 ? written / 1000 : written))
    }

    /// Every state written within `maxAge`, newest first. Files older than two days are deleted.
    static func readStates(dir: URL = statesDir, maxAge: TimeInterval, now: Date = Date()) -> [SessionState] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let mtime = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { return nil }
            if now.timeIntervalSince(mtime) > 2 * 86400 { try? FileManager.default.removeItem(at: url); return nil }
            guard now.timeIntervalSince(mtime) <= maxAge, let data = try? Data(contentsOf: url) else { return nil }
            return parseState(data)
        }
        .sorted { $0.writtenAt > $1.writtenAt }
    }
}

// MARK: - Settings

/// Whether Dashbar's hook is in Copilot's hooks folder. It mirrors that folder rather than being a preference, so it's
/// re-read at launch, every few minutes and when Settings opens.
@MainActor
final class CopilotSettings: ObservableObject {
    static let shared = CopilotSettings()
    @Published private(set) var status: CopilotBridge.Status = .absent

    private init() {
        if CommandLine.arguments.contains("--demo"), ProcessInfo.processInfo.environment["DASHBAR_DEMO_COPILOT"] != nil {
            status = .notInstalled
        }
    }

    func refresh(paths: CopilotBridge.Paths = .default()) {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let s = CopilotBridge.status(paths)
        if s.isInstalled { try? CopilotBridge.writeScript(paths) }
        if s != status { status = s }
    }

    /// Adds or removes the hook. Returns what went wrong, phrased for the user.
    func set(_ on: Bool, paths: CopilotBridge.Paths = .default()) -> String? {
        var problem: String?
        do { on ? try CopilotBridge.install(paths) : try CopilotBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refresh(paths: paths)
        return problem
    }
}

/// Integrations → GitHub Copilot CLI: show it or not, and add or remove the hook. Shown only when Copilot CLI is on this
/// Mac, the hook is in, or it's switched off (so it can be switched back on).
struct CopilotSection: View {
    @ObservedObject private var settings = CopilotSettings.shared
    @ObservedObject private var app = AppSettings.shared
    @ObservedObject private var presence = ToolPresence.shared
    @State private var problem: String?

    var body: some View {
        if settings.status != .absent || presence.found.contains(.copilot) || !app.visibility.shows(.copilot) {
            Section {
                ShowInDashbarToggle(tool: .copilot)
                if app.visibility.shows(.copilot) {
                    row
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    IntegrationDetails(text: explanation)
                }
            } header: {
                Text(CopilotCLI.displayName)
            }
        }
    }

    @ViewBuilder private var row: some View {
        switch settings.status {
        case .installed:
            LabeledContent {
                Button("Remove") { problem = settings.set(false) }
            } label: {
                Text("In Copilot's hooks")
                Text("Shows when a session needs you. Takes effect in new Copilot sessions.")
            }
        case .notInstalled, .absent:
            LabeledContent {
                Button("Add to Copilot") { problem = settings.set(true) }
            } label: {
                Text("Show when Copilot needs you, sooner")
                Text("Off until you add it. Never answers a prompt. Sends nothing.")
            }
        case .conflict:
            LabeledContent {
                Button("Check Again") { problem = nil; settings.refresh() }
            } label: {
                Text("Show when Copilot needs you, sooner")
                Text("Copilot's hooks folder already has a dashbar.json that Dashbar didn't write, so Dashbar left it alone.")
            }
        }
    }

    private var explanation: String {
        let paths = CopilotBridge.Paths.default()
        return "Without it, Dashbar sees Copilot working, idle or asking permission from each session's event log, and "
            + "reads token use when a session ends. Adding Dashbar puts one file, \(CopilotBridge.configName), in "
            + "\(Fmt.tilde(paths.hooks.path)), using Copilot's own hooks. It saves each session's state and folder to files "
            + "on this Mac the moment it changes. It never saves prompts, tool input or results, or what a notification "
            + "says, and never answers a permission. Remove deletes the file."
    }
}
