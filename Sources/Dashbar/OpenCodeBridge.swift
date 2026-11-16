import Foundation
import SwiftUI

/// Whether each opencode session is working, idle or waiting for you, from a small plugin in opencode's plugins folder.
///
/// opencode loads every `.js` file in `~/.config/opencode/plugins/` (`$XDG_CONFIG_HOME` if set), in 1.x
/// (`packages/opencode/src/config/plugin.ts` at v1.19.5 scans `{plugin,plugins}/*.{ts,js}`) and in 2.x
/// (`packages/core/src/plugin/source-directory.ts` on dev). The two load a file differently, so `dashbar.js` speaks both:
///
/// - 1.x reads `default` as `{ id, server }` (`packages/opencode/src/plugin/shared.ts`, `readV1Plugin`). `server(input)`
///   returns hooks; the `event` hook receives every bus event as `{ type, properties }`.
/// - 2.x reads `default` as `{ id, setup }` (`packages/core/src/plugin/module.ts`, extra keys ignored). `setup(ctx)`
///   subscribes through `ctx.event.subscribe` (`packages/plugin/src/promise/event.ts`); events arrive as
///   `{ type, data, location }` (`packages/schema/src/event.ts`).
///
/// The events read are `session.status` (busy, retry, idle), `session.idle`, `permission.asked`/`permission.replied`
/// and, in 1.x, `question.asked`/`question.replied`/`question.rejected`. Of each, only the session id is kept, with the
/// folder (`location.directory`, else the plugin's own directory). The plugin writes one small file per session holding
/// exactly four fields (`session_id`, `directory`, `state`, `written_at`) into a Dashbar-owned folder only you can read
/// (0700, files 0600). It never saves what a permission or question asks, prompts, titles, tool input or file contents,
/// never answers anything, and never stops opencode: everything it does is inside `try`.
enum OpenCodeBridge {
    static let fileName = "dashbar.js"
    /// The first line of every version of the plugin; Remove deletes only a file that starts with it.
    static let marker = "// Dashbar's opencode plugin"

    /// Where the plugin saves states. Shared by every copy of Dashbar (the release and a local build).
    static let statesDir = homeDir.appendingPathComponent("Library/Caches/Dashbar/opencode-sessions")

    /// The state machine, kept free of Node so tests can run it (between the core markers) in JavaScriptCore.
    static let core = #"""
    // dashbar-core-begin
    function dashbarCore(store, now) {
      var pending = {}
      function clean(v) { return typeof v === "string" ? v.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 128) : "" }
      function folder(v) { return typeof v === "string" && v.charAt(0) === "/" && v.length < 4096 ? v : "" }
      function save(id, directory, state) {
        store(id, JSON.stringify({ version: 1, session_id: id, directory: directory, state: state, written_at: now() }))
      }
      function asks(id) { return pending[id] || (pending[id] = {}) }
      function waiting(id) { return Object.keys(asks(id)).length > 0 }
      return function handle(event, fallback) {
        try {
          if (!event || typeof event.type !== "string") return
          var p = event.properties || event.data || {}
          var id = clean(p.sessionID)
          if (!id) return
          var directory = folder(event.location && event.location.directory) || folder(fallback)
          switch (event.type) {
            case "session.status":
              var type = p.status && p.status.type
              if (type === "idle") { delete pending[id]; save(id, directory, "idle") }
              else if (type === "busy" || type === "retry") save(id, directory, waiting(id) ? "needsYou" : "working")
              return
            case "session.idle":
              delete pending[id]
              save(id, directory, "idle")
              return
            case "permission.asked":
            case "permission.updated":
            case "question.asked":
              asks(id)[clean(p.id) || "ask"] = true
              save(id, directory, "needsYou")
              return
            case "permission.replied":
            case "question.replied":
            case "question.rejected":
              var answered = clean(p.requestID || p.permissionID)
              if (answered && asks(id)[answered]) delete asks(id)[answered]
              else delete pending[id]
              save(id, directory, waiting(id) ? "needsYou" : "working")
              return
          }
        } catch (e) {}
      }
    }
    // dashbar-core-end
    """#

    /// The whole file Dashbar writes to opencode's plugins folder.
    static var script: String {
        #"""
        // Dashbar's opencode plugin (version 1). Dashbar added it with your consent, from Settings > Integrations.
        // It tells Dashbar whether each OpenCode session is working, idle or waiting for you, by saving four fields per
        // session (its id, its folder, that state and the time) to files on this Mac that only you can read. It never
        // saves prompts, replies, titles, tool input, file contents or what a permission asks, never answers a prompt,
        // and sends nothing anywhere. Remove it in Dashbar's Settings, which deletes this file.
        import { chmodSync, mkdirSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs"
        import { homedir } from "node:os"
        import { join } from "node:path"

        """# + core + #"""


        var dir = join(homedir(), "Library", "Caches", "Dashbar", "opencode-sessions")

        function store(id, text) {
          try {
            mkdirSync(dir, { recursive: true, mode: 0o700 })
            chmodSync(dir, 0o700)
            var tmp = join(dir, "." + id + "." + process.pid)
            writeFileSync(tmp, text + "\n", { mode: 0o600 })
            renameSync(tmp, join(dir, id + ".json"))
          } catch (e) {}
        }

        function tidy() {
          try {
            for (var name of readdirSync(dir)) {
              var file = join(dir, name)
              if (Date.now() - statSync(file).mtimeMs > 2 * 86400000) unlinkSync(file)
            }
          } catch (e) {}
        }

        var handle = dashbarCore(store, function () { return Date.now() })
        var types = ["session.status", "session.idle", "permission.asked", "permission.updated", "permission.replied",
          "question.asked", "question.replied", "question.rejected"]
        tidy()

        // OpenCode 1.x: hooks, with every event passed to `event`.
        async function server(input) {
          var directory = input && input.directory
          return { event: async function (input) { handle(input && input.event, directory) } }
        }

        // OpenCode 2.x: a subscription to the event stream, stopped when the plugin unloads.
        async function setup(ctx) {
          var stop = new AbortController()
          var directory = ctx && ctx.location && ctx.location.directory
          ;(async function () {
            try {
              for await (var event of ctx.event.subscribe({ types: types, signal: stop.signal })) handle(event, directory)
            } catch (e) {}
          })()
          return function () { try { stop.abort() } catch (e) {} }
        }

        export default { id: "dashbar", server: server, setup: setup }

        """#
    }

    // MARK: Paths

    struct Paths {
        /// opencode's config folder (`~/.config/opencode`).
        var config: URL
        /// opencode's database, whose presence also says opencode is installed.
        var database: URL
        var states: URL = OpenCodeBridge.statesDir

        var plugins: URL { config.appendingPathComponent("plugins") }
        var file: URL { plugins.appendingPathComponent(OpenCodeBridge.fileName) }
        /// opencode also reads the singular folder; a copy there counts, and Remove takes it out too.
        var legacyFile: URL { config.appendingPathComponent("plugin").appendingPathComponent(OpenCodeBridge.fileName) }

        static func `default`() -> Paths { Paths(config: OpenCode.configURL(), database: OpenCode.databaseURL()) }
    }

    // MARK: Status

    enum Status: Equatable {
        /// Neither opencode's config folder nor its database exists: it isn't installed, so Settings shows nothing.
        case absent
        case notInstalled
        case installed
        /// A `dashbar.js` Dashbar didn't write is in the plugins folder. Dashbar leaves it alone.
        case conflict

        var isInstalled: Bool { self == .installed }
    }

    enum Failure: LocalizedError, Equatable {
        case notOurs(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notOurs(let path):
                return "There's already a dashbar.js that Dashbar didn't write (\(Fmt.tilde(path))). Dashbar left it alone. Rename or remove it, then try again."
            case .writeFailed(let why):
                return "Couldn't save the plugin to OpenCode's plugins folder (\(why)). Nothing was changed."
            }
        }
    }

    static func isOurs(_ url: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return false }
        return String(decoding: data.prefix(256), as: UTF8.self).hasPrefix(marker)
    }

    static func status(_ paths: Paths) -> Status {
        let fm = FileManager.default
        switch (isOurs(paths.file), isOurs(paths.legacyFile)) {
        case (true?, _), (nil, true?): return .installed
        case (false?, _): return .conflict
        default: break
        }
        if !fm.fileExists(atPath: paths.config.path) && !fm.fileExists(atPath: paths.database.path) { return .absent }
        return .notInstalled
    }

    // MARK: Install and remove

    /// Writes the plugin into opencode's plugins folder, creating that folder if needed. Refuses to replace a file of the
    /// same name that Dashbar didn't write.
    static func install(_ paths: Paths) throws {
        if isOurs(paths.file) == false { throw Failure.notOurs(paths.file.path) }
        try writeScript(paths)
    }

    /// Deletes Dashbar's plugin file (only if it is Dashbar's) and the states it saved. Nothing else in opencode's
    /// folders is touched.
    static func uninstall(_ paths: Paths) throws {
        let fm = FileManager.default
        for url in [paths.file, paths.legacyFile] where isOurs(url) == true {
            do { try fm.removeItem(at: url) } catch { throw Failure.writeFailed(error.localizedDescription) }
        }
        try? fm.removeItem(at: paths.states)
    }

    /// Writes the plugin if it is missing or from another version of Dashbar. Called at launch while it's added.
    static func writeScript(_ paths: Paths) throws {
        let data = Data(script.utf8)
        if (try? Data(contentsOf: paths.file)) == data { return }
        guard isOurs(paths.file) != false else { throw Failure.notOurs(paths.file.path) }
        do {
            try FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
            try data.write(to: paths.file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.file.path)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Reading what the plugin saved

    /// One session as the plugin last saw it.
    struct SessionState: Equatable {
        var id: String
        var directory: String
        /// "working", "idle" or "needsYou".
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
              let id = o["session_id"] as? String, !id.isEmpty, id.count <= 128,
              let state = o["state"] as? String, ["working", "idle", "needsYou"].contains(state),
              let written = (o["written_at"] as? NSNumber)?.doubleValue, written > 0 else { return nil }
        let directory = (o["directory"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? ""
        return SessionState(id: id, directory: directory, state: state,
                            writtenAt: Date(timeIntervalSince1970: written > 1e11 ? written / 1000 : written))
    }

    /// Every state written within `maxAge`, newest first. A file being replaced right now may not parse; it's skipped.
    static func readStates(dir: URL = statesDir, maxAge: TimeInterval, now: Date = Date()) -> [SessionState] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let mtime = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  now.timeIntervalSince(mtime) <= maxAge,
                  let data = try? Data(contentsOf: url) else { return nil }
            return parseState(data)
        }
        .sorted { $0.writtenAt > $1.writtenAt }
    }
}

// MARK: - Settings

/// Whether Dashbar's plugin is in opencode's plugins folder. It mirrors that folder rather than being a preference, so
/// it's re-read at launch, every few minutes and when Settings opens.
@MainActor
final class OpenCodeSettings: ObservableObject {
    static let shared = OpenCodeSettings()
    @Published private(set) var status: OpenCodeBridge.Status = .absent

    private init() {
        if CommandLine.arguments.contains("--demo"), ProcessInfo.processInfo.environment["DASHBAR_DEMO_OPENCODE"] != nil {
            status = .installed
        }
    }

    func refresh(paths: OpenCodeBridge.Paths = .default()) {
        guard !CommandLine.arguments.contains("--demo") else { return }
        let s = OpenCodeBridge.status(paths)
        if s.isInstalled { try? OpenCodeBridge.writeScript(paths) }
        if s != status { status = s }
    }

    /// Adds or removes the plugin. Returns what went wrong, phrased for the user.
    func set(_ on: Bool, paths: OpenCodeBridge.Paths = .default()) -> String? {
        var problem: String?
        do { on ? try OpenCodeBridge.install(paths) : try OpenCodeBridge.uninstall(paths) }
        catch { problem = error.localizedDescription }
        refresh(paths: paths)
        return problem
    }
}

/// Integrations → opencode: whether it shows, then add or remove the plugin. Shown only when opencode is installed (its
/// config folder or database exists), the plugin is in, or it's switched off.
struct OpenCodeSection: View {
    @ObservedObject private var settings = OpenCodeSettings.shared
    @ObservedObject private var app = AppSettings.shared
    @State private var problem: String?

    var body: some View {
        let shown = app.visibility.shows(.opencode)
        if settings.status != .absent || !shown {
            Section {
                ShowInDashbarToggle(tool: .opencode)
                if shown {
                    row
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    IntegrationDetails(text: explanation)
                }
            } header: {
                Text("OpenCode")
            }
        }
    }

    @ViewBuilder private var row: some View {
        switch settings.status {
        case .installed:
            LabeledContent {
                Button("Remove") { problem = settings.set(false) }
            } label: {
                Text("In OpenCode's plugins")
                Text("Shows when a session needs you. Takes effect next time OpenCode starts.")
            }
        case .notInstalled:
            LabeledContent {
                Button("Add to OpenCode") { problem = settings.set(true) }
            } label: {
                Text("Show when OpenCode needs you")
                Text("Off until you add it. Sends nothing.")
            }
        case .conflict:
            LabeledContent {
                Button("Check Again") { problem = nil; settings.refresh() }
            } label: {
                Text("Show when OpenCode needs you")
                Text("OpenCode's plugins folder already has a dashbar.js that Dashbar didn't write, so Dashbar left it alone.")
            }
        case .absent:
            EmptyView()
        }
    }

    private var explanation: String {
        let folder = Fmt.tilde(OpenCodeBridge.Paths.default().plugins.path)
        return "Without it, Dashbar sees OpenCode working from its session database. Adding Dashbar puts one file, "
            + "dashbar.js, in \(folder). It saves each session's state (working, idle or waiting for you) and folder to files "
            + "on this Mac, for OpenCode 1.x and 2.x. It never saves prompts, titles or what a permission asks, and never "
            + "answers one. Remove deletes the file."
    }
}
