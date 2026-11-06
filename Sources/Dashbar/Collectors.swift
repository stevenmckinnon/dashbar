import Foundation
import Darwin

// MARK: - Live Claude Code sessions (~/.claude/sessions/<pid>.json)

struct LiveSession: Identifiable {
    let id: String
    let pid: Int32
    let name: String
    let cwd: String
    let status: String
    let since: Date
    let entrypoint: String
    let root: String

    var project: String { URL(fileURLWithPath: root).lastPathComponent }
    var isBusy: Bool { status == "busy" }
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

    static func read(dir: URL = ClaudeSessions.defaultDir) -> [LiveSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let sessions: [LiveSession] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (o["pid"] as? Int).map(Int32.init), isAlive(pid) else { return nil }
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
                root: cwd.isEmpty ? homeDir.path : Fmt.root(fromCwd: cwd))
        }
        return sessions.sorted { ($0.isBusy ? 0 : 1, $1.since) < ($1.isBusy ? 0 : 1, $0.since) }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Other agent processes

struct AgentProcess: Identifiable {
    var id: String { name }
    let name: String
    let count: Int
}

enum AgentProcesses {
    /// Executable basename -> display name.
    static let known: [String: String] = [
        "codex": "Codex", "Codex": "Codex app",
        "cursor-agent": "Cursor Agent", "Cursor": "Cursor",
        "gemini": "Gemini CLI", "aider": "Aider", "opencode": "opencode",
        "amp": "Amp", "goose": "Goose", "copilot": "Copilot CLI",
        "ollama": "Ollama", "LM Studio": "LM Studio",
    ]

    static func read() -> [AgentProcess] {
        read(executables: Proc.allPIDs().compactMap(Proc.path))
    }

    /// Counts known agent tools among executable paths.
    static func read(executables: [String]) -> [AgentProcess] {
        var counts: [String: Int] = [:]
        for path in executables {
            if let name = known[URL(fileURLWithPath: path).lastPathComponent] { counts[name, default: 0] += 1 }
        }
        return counts.map { AgentProcess(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }
}

// MARK: - Listening TCP ports

struct Listener: Identifiable {
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
            let exe = URL(fileURLWithPath: listeners[i].cmdline.split(separator: " ").first.map(String.init) ?? l.command).lastPathComponent.lowercased()
            // Helpers bundled inside Mac apps (Raycast's node, sync clients…) aren't dev servers.
            // Developer toolchains also live inside bundles (Xcode's Python, Python.org's framework build).
            let toolchain = listeners[i].cmdline.contains("/Contents/Developer/") || listeners[i].cmdline.contains("Python.framework/")
                || listeners[i].cmdline.contains("Python3.framework/")
            let insideApp = !toolchain && listeners[i].cmdline.contains(".app/Contents/")
                || listeners[i].cmdline.contains("/Library/Application Support/")
                || cwd.contains("/Library/Application Support/")
            listeners[i].isDev = listeners[i].isDocker || !insideApp && (
                devExecutables.contains(exe) || exe.hasPrefix("python")
                    // lsof says "node" but the process renamed itself (e.g. "Raycast Backend"): an app helper.
                    || devExecutables.contains(l.command) && listeners[i].cmdline.contains(l.command))
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
