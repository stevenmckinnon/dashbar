import Foundation
import Darwin

// MARK: - Live Claude Code sessions (~/.claude/sessions/<pid>.json)

struct LiveSession: Identifiable, Equatable {
    let id: String
    let pid: Int32
    let name: String
    let cwd: String
    let status: String
    let since: Date
    let entrypoint: String
    let root: String
    /// Why Claude stopped to ask, while `status` is "waiting": "permission prompt", "input needed" or a dialog's own reason.
    var waitingFor: String? = nil
    /// The account's name, set only while Dashbar reads more than one Claude Code account.
    var account: String? = nil
    /// The account's configuration folder, where its transcripts are. Nil means the default.
    var configDir: String? = nil
    /// When this Claude Code process started, so subagents left from an earlier run of a resumed session aren't shown.
    var startedAt: Date? = nil
    /// Claude Code, or one of Google's agents (`Google.swift`).
    var agent: SessionAgent = .claude

    var project: String { URL(fileURLWithPath: root).lastPathComponent }
    var isBusy: Bool { status == "busy" }
    /// Claude has stopped to ask for permission or an answer, and is blocked until someone replies.
    var isWaiting: Bool { status == "waiting" }
    /// Short form for status lines: "Needs permission".
    var waitingLabel: String {
        switch waitingFor {
        case "permission prompt": return "Needs permission"
        case "input needed": return "Needs input"
        default: return "Waiting for you"
        }
    }
    /// Sentence form for rows and notifications: "Claude needs permission".
    var waitingSentence: String {
        switch waitingFor {
        case "permission prompt": return "\(agent.name) needs permission"
        case "input needed": return "\(agent.name) needs input"
        default: return "\(agent.name) is waiting for you"
        }
    }
    /// Waiting first (someone has to act), then working, then idle.
    var urgency: Int { isWaiting ? 0 : isBusy ? 1 : 2 }
    var surface: String {
        switch entrypoint {
        case "claude-desktop": return "Desktop"
        case "cli": return "CLI"
        case let e where e.contains("vscode"): return "VS Code"
        case let e where e.contains("jetbrains"): return "JetBrains"
        default: return entrypoint.isEmpty ? "CLI" : entrypoint
        }
    }
}

enum ClaudeSessions {
    static let defaultDir = homeDir.appendingPathComponent(".claude/sessions")

    /// Live sessions, plus a warning when session files exist but none can be read.
    struct Reading: Equatable {
        var sessions: [LiveSession] = []
        var warning: String?
    }

    static let formatWarning = "Couldn't read Claude Code's live sessions. Its session file format may have changed, so check for a Dashbar update."

    static func read(dir: URL = ClaudeSessions.defaultDir) -> [LiveSession] { readChecked(dir: dir).sessions }

    /// Every session file that parses is checked for the keys Dashbar relies on, live process or not. If some parse
    /// but none has them (or no live one says what it's doing), Claude Code changed the format: say so rather than
    /// showing "no agents".
    static func readChecked(dir: URL = ClaudeSessions.defaultDir) -> Reading {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return Reading() }
        var parsed = 0, recognised = 0, withStatus = 0
        let sessions: [LiveSession] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            // A file being written right now may not parse yet; it isn't evidence either way.
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            parsed += 1
            guard let pid = (o["pid"] as? Int).map(Int32.init) else { return nil }
            recognised += 1
            guard isAlive(pid) else { return nil }
            if o["status"] is String { withStatus += 1 }
            let cwd = o["cwd"] as? String ?? ""
            let ms = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? (o["startedAt"] as? Double) ?? 0
            return LiveSession(
                id: o["sessionId"] as? String ?? url.lastPathComponent,
                pid: pid,
                name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Fmt.project(fromCwd: cwd),
                cwd: cwd,
                status: o["status"] as? String ?? "unknown",
                since: Date(timeIntervalSince1970: ms / 1000),
                entrypoint: o["entrypoint"] as? String ?? "",
                root: cwd.isEmpty ? homeDir.path : Fmt.root(fromCwd: cwd),
                waitingFor: o["waitingFor"] as? String,
                startedAt: (o["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        let unreadable = parsed > 0 && recognised == 0 || !sessions.isEmpty && withStatus == 0
        return Reading(sessions: sessions.sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) },
                       warning: unreadable ? formatWarning : nil)
    }

    /// Every account's live sessions together. Each is tagged with its folder, and with its account's name when there
    /// is more than one account. A format warning from any account is passed on.
    static func readChecked(accounts: [ResolvedAccount]) -> Reading {
        var out = Reading()
        for account in accounts {
            let r = readChecked(dir: account.sessionsDir)
            out.warning = out.warning ?? r.warning
            out.sessions += r.sessions.map { s in
                var s = s
                s.configDir = account.isDefault ? nil : account.path
                s.account = accounts.count > 1 ? account.label : nil
                return s
            }
        }
        out.sessions.sort { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        return out
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Other agent processes

struct AgentProcess: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

enum AgentProcesses {
    /// Executable basename -> display name. Tools whose sessions Dashbar lists by workspace (opencode, via
    /// `OpenCodeCollector`) stay out of this list, so they never show twice.
    static let known: [String: String] = [
        "codex": "Codex", "Codex": "Codex app",
        "cursor-agent": "Cursor Agent", "Cursor": "Cursor",
        "aider": "Aider",
        "amp": "Amp", "goose": "Goose", "copilot": "Copilot CLI",
        "ollama": "Ollama", "LM Studio": "LM Studio",
        "T3 Code": "T3 Code", "T3 Code (Beta)": "T3 Code", "T3 Code (Alpha)": "T3 Code",
        "Superset": "Superset",
    ]

    /// Apps that run a second copy of their own binary as a helper, so they count once however many show up.
    private static let countsOnce: Set<String> = ["T3 Code"]

    static func read() -> [AgentProcess] {
        read(executables: Proc.allPIDs().compactMap(Proc.path))
    }

    /// Counts known agent tools among executable paths.
    static func read(executables: [String]) -> [AgentProcess] {
        var counts: [String: Int] = [:]
        for path in executables {
            if let name = known[URL(fileURLWithPath: path).lastPathComponent] { counts[name, default: 0] += 1 }
        }
        return counts.map { AgentProcess(name: $0.key, count: countsOnce.contains($0.key) ? 1 : $0.value) }.sorted { $0.name < $1.name }
    }
}

// MARK: - Listening TCP ports

struct Listener: Identifiable, Equatable {
    var id: String { "\(pid):\(port)" }
    let pid: Int32
    let port: Int
    let command: String
    let address: String
    var cwd: String = ""
    var cmdline: String = ""
    var isDev = false
    var memory: UInt64 = 0
    var root: String?
    var started: Date?
    /// CPU time used since the process started, in seconds.
    var cpuSeconds: Double = 0
    /// True when a dev server has been up a while and is doing almost nothing (see `ServerActivity`).
    var isIdle = false
    /// The agent session (its process ID) whose process tree this server runs in.
    var startedBy: Int32?

    var isDocker: Bool { command.hasPrefix("com.docke") || cmdline.contains("com.docker.backend") }
    var title: String { isDocker ? "Docker container" : (project ?? command) }

    var isLoopbackOnly: Bool { address.hasPrefix("127.") || address.hasPrefix("[::1]") }
    var project: String? { root.map { URL(fileURLWithPath: $0).lastPathComponent } }
    /// Short human hint like "next dev" or "vite".
    var hint: String {
        let tokens = cmdline.split(separator: " ").map { String($0) }
        guard let first = tokens.first else { return command }
        let exe = URL(fileURLWithPath: first).lastPathComponent
        let interesting = tokens.dropFirst().map { tok -> String in
            tok.contains("/") ? URL(fileURLWithPath: tok).lastPathComponent : tok
        }.filter { !$0.hasPrefix("-") }.prefix(2)
        return ([exe] + interesting).joined(separator: " ")
    }
}

enum Listeners {
    static let devExecutables: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "java", "go", "php", "postgres", "redis-server",
        "mysqld", "mongod", "vite", "next-server", "uvicorn", "gunicorn", "rails", "puma", "hugo", "caddy",
        "nginx", "httpd", "ollama", "beam.smp", "dotnet", "cargo", "air", "wrangler", "workerd", "supabase",
        "com.docker.backend", "vfkit", "esbuild", "turbo", "pnpm", "npm", "yarn", "flask", "django-admin",
    ]

    /// Whether a listening process is a dev server, from its process name, command line and working folder alone.
    static func isDevServer(command: String, cmdline: String, cwd: String) -> Bool {
        let probe = Listener(pid: 0, port: 0, command: command, address: "", cmdline: cmdline)
        if probe.isDocker { return true }
        let exe = URL(fileURLWithPath: cmdline.split(separator: " ").first.map(String.init) ?? command).lastPathComponent.lowercased()
        // Helpers bundled inside Mac apps (Raycast's node, sync clients…) aren't dev servers.
        // Developer toolchains also live inside bundles (Xcode's Python, Python.org's framework build).
        let toolchain = cmdline.contains("/Contents/Developer/") || cmdline.contains("Python.framework/")
            || cmdline.contains("Python3.framework/")
        let insideApp = !toolchain && cmdline.contains(".app/Contents/")
            || cmdline.contains("/Library/Application Support/")
            || cwd.contains("/Library/Application Support/")
        guard !insideApp else { return false }
        return devExecutables.contains(exe) || exe.hasPrefix("python")
            // The process name says "node" but the process renamed itself (e.g. "Raycast Backend"): an app helper.
            || devExecutables.contains(command) && cmdline.contains(command)
    }

    static func read() -> [Listener] {
        var result: [String: Listener] = [:]
        var cwds: [Int32: String] = [:]
        var cmdlines: [Int32: String] = [:]
        var rss: [Int32: UInt64] = [:]
        var info: [Int32: (started: Date?, cpu: Double)] = [:]
        for pid in Proc.allPIDs() {
            let sockets = Proc.listeningSockets(pid)
            guard !sockets.isEmpty else { continue }
            let command = Proc.name(pid)
            for socket in sockets {
                let l = Listener(pid: pid, port: socket.port, command: command, address: socket.address)
                // A process bound on both loopback and any-address keeps the wider binding.
                if result[l.id] == nil || l.isLoopbackOnly == false { result[l.id] = l }
            }
            cwds[pid] = Proc.cwd(pid)
            cmdlines[pid] = Proc.commandLine(pid)
            rss[pid] = Proc.residentBytes(pid)
            info[pid] = (Proc.bsdInfo(pid)?.started, Proc.cpuSeconds(pid) ?? 0)
        }
        var listeners = Array(result.values)
        guard !listeners.isEmpty else { return [] }

        for i in listeners.indices {
            let l = listeners[i]
            let cwd = cwds[l.pid] ?? ""
            listeners[i].cwd = cwd
            listeners[i].cmdline = cmdlines[l.pid] ?? l.command
            listeners[i].memory = rss[l.pid] ?? 0
            listeners[i].started = info[l.pid]?.started
            listeners[i].cpuSeconds = info[l.pid]?.cpu ?? 0
            if !cwd.isEmpty, cwd != "/", cwd != homeDir.path, !cwd.contains("/Library/") {
                listeners[i].root = Fmt.root(fromCwd: cwd)
            }
            listeners[i].isDev = isDevServer(command: l.command, cmdline: listeners[i].cmdline, cwd: cwd)
        }
        return listeners.sorted { ($0.isDev ? 0 : 1, $0.port) < ($1.isDev ? 0 : 1, $1.port) }
    }
}

// MARK: - Idle dev servers

/// Spots dev servers that have been up for a while and are barely doing anything, so they can be stopped.
/// It watches each server's CPU time over the last hour; until it has watched for 15 minutes it falls back
/// to the average since the server started.
final class ServerActivity {
    static let minimumUptime: TimeInterval = 60 * 60
    /// Average share of one core below which a server counts as idle. File watchers alone stay under this.
    static let idleRate = 0.003
    private static let window: TimeInterval = 60 * 60
    private static let minimumWatch: TimeInterval = 15 * 60

    private var samples: [Int32: [(at: Date, cpu: Double)]] = [:]

    func annotate(_ listeners: inout [Listener], now: Date = Date()) {
        var seen = Set<Int32>()
        for i in listeners.indices where listeners[i].isDev && !listeners[i].isDocker {
            let l = listeners[i]
            if seen.insert(l.pid).inserted {
                var list = samples[l.pid] ?? []
                list.append((now, l.cpuSeconds))
                list.removeAll { now.timeIntervalSince($0.at) > Self.window }
                samples[l.pid] = list
            }
            listeners[i].isIdle = Self.isIdle(uptime: l.started.map { now.timeIntervalSince($0) },
                                              cpu: l.cpuSeconds, watched: samples[l.pid] ?? [], now: now)
        }
        samples = samples.filter { seen.contains($0.key) }
    }

    static func isIdle(uptime: TimeInterval?, cpu: Double, watched: [(at: Date, cpu: Double)], now: Date) -> Bool {
        guard let uptime, uptime >= minimumUptime else { return false }
        if let first = watched.first, now.timeIntervalSince(first.at) >= minimumWatch {
            return (cpu - first.cpu) / now.timeIntervalSince(first.at) < idleRate
        }
        return cpu / uptime < idleRate
    }
}

// MARK: - What each agent started

/// The processes running under an agent session: its dev servers, browsers and tool servers.
struct SpawnedProcesses: Equatable {
    var count = 0
    var memory: UInt64 = 0
    var ports: [Int] = []
    /// A few process names, most memory first, for the tooltip.
    var names: [String] = []
}

enum ProcessTree {
    /// Descendants of each session process. Servers that were started under a session get `startedBy` set.
    static func spawned(sessions: [LiveSession], listeners: inout [Listener]) -> [Int32: SpawnedProcesses] {
        let roots = Set(sessions.map(\.pid))
        guard !roots.isEmpty else { return [:] }
        let parents = Proc.parents(of: Proc.allPIDs())
        return spawned(roots: roots, parents: parents, listeners: &listeners,
                       memory: Proc.residentBytes, name: Proc.name)
    }

    static func spawned(roots: Set<Int32>, parents: [Int32: Int32], listeners: inout [Listener],
                        memory: (Int32) -> UInt64, name: (Int32) -> String) -> [Int32: SpawnedProcesses] {
        // Which session, if any, each process descends from.
        var owner: [Int32: Int32] = [:]
        func session(of pid: Int32) -> Int32? {
            var chain: [Int32] = []
            var current = pid
            var found: Int32?
            while let parent = parents[current], parent > 1, chain.count < 64 {
                if let known = owner[parent] { found = known; break }
                if roots.contains(parent) { found = parent; break }
                chain.append(current)
                current = parent
            }
            if let found { for p in chain + [pid] { owner[p] = found } }
            return found
        }

        var result: [Int32: SpawnedProcesses] = [:]
        var named: [Int32: [(String, UInt64)]] = [:]
        for pid in parents.keys where !roots.contains(pid) {
            guard let root = session(of: pid) else { continue }
            let bytes = memory(pid)
            result[root, default: SpawnedProcesses()].count += 1
            result[root]!.memory += bytes
            named[root, default: []].append((name(pid), bytes))
        }
        for (root, list) in named {
            var names: [String] = []
            for (n, _) in list.sorted(by: { $0.1 > $1.1 }) where !n.isEmpty && !names.contains(n) {
                names.append(n)
                if names.count == 4 { break }
            }
            result[root]?.names = names
        }
        for i in listeners.indices {
            guard let root = roots.contains(listeners[i].pid) ? nil : session(of: listeners[i].pid) else { continue }
            listeners[i].startedBy = root
            if !(result[root]?.ports.contains(listeners[i].port) ?? true) { result[root]?.ports.append(listeners[i].port) }
        }
        for key in result.keys { result[key]?.ports.sort() }
        return result
    }
}
