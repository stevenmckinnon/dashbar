import Foundation
import Darwin
import IOKit.ps

// MARK: - Live Claude Code sessions (~/.claude/sessions/<pid>.json)

struct LiveSession: Identifiable {
    let id: String
    let pid: Int32
    let name: String
    let cwd: String
    let status: String
    let since: Date
    let entrypoint: String

    var project: String { Fmt.project(fromCwd: cwd) }
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
    static func read() -> [LiveSession] {
        let dir = homeDir.appendingPathComponent(".claude/sessions")
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
                entrypoint: o["entrypoint"] as? String ?? "")
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

    static func read(psOutput: String) -> [AgentProcess] {
        var counts: [String: Int] = [:]
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let exe = URL(fileURLWithPath: String(parts[1]).trimmingCharacters(in: .whitespaces)).lastPathComponent
            if let name = known[exe] { counts[name, default: 0] += 1 }
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

    var isDocker: Bool { command.hasPrefix("com.docke") || cmdline.contains("com.docker.backend") }
    var title: String { isDocker ? "Docker container" : (project ?? command) }

    var isLoopbackOnly: Bool { address.hasPrefix("127.") || address.hasPrefix("[::1]") }
    var project: String? {
        guard !cwd.isEmpty, cwd != "/", cwd != homeDir.path else { return nil }
        return Fmt.project(fromCwd: cwd)
    }
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
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        var result: [String: Listener] = [:]
        var pid: Int32 = 0, cmd = ""
        for raw in out.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": cmd = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let l = Listener(pid: pid, port: port, command: cmd, address: String(value[..<colon]))
                if result[l.id] == nil || l.isLoopbackOnly == false { result[l.id] = l }
            default: break
            }
        }
        var listeners = Array(result.values)
        let pids = Set(listeners.map(\.pid))
        guard !pids.isEmpty else { return [] }
        let pidList = pids.map(String.init).joined(separator: ",")

        // Working directory per pid -> project name.
        var cwds: [Int32: String] = [:]
        var cur: Int32 = 0
        for raw in Shell.run("/usr/sbin/lsof", ["-a", "-p", pidList, "-d", "cwd", "-F", "pn"]).split(separator: "\n") {
            if raw.first == "p" { cur = Int32(raw.dropFirst()) ?? 0 }
            else if raw.first == "n" { cwds[cur] = String(raw.dropFirst()) }
        }
        // Full command line per pid.
        var cmdlines: [Int32: String] = [:]
        for raw in Shell.run("/bin/ps", ["-o", "pid=,command=", "-p", pidList]).split(separator: "\n") {
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            if parts.count == 2, let p = Int32(parts[0]) { cmdlines[p] = String(parts[1]) }
        }

        for i in listeners.indices {
            let l = listeners[i]
            listeners[i].cwd = cwds[l.pid] ?? ""
            listeners[i].cmdline = cmdlines[l.pid] ?? l.command
            let exe = URL(fileURLWithPath: listeners[i].cmdline.split(separator: " ").first.map(String.init) ?? l.command).lastPathComponent
            // Helpers bundled inside Mac apps (Raycast's node, sync clients…) aren't dev servers.
            let insideApp = listeners[i].cmdline.contains(".app/Contents/")
            listeners[i].isDev = listeners[i].isDocker || !insideApp && (
                devExecutables.contains(exe) || devExecutables.contains(l.command) || exe.hasPrefix("python"))
        }
        return listeners.sorted { ($0.isDev ? 0 : 1, $0.port) < ($1.isDev ? 0 : 1, $1.port) }
    }
}

// MARK: - System

struct SystemSnapshot {
    var cpu: Double = 0              // 0...1
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0
    var battery: Int?                // percent
    var charging = false
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
}

final class SystemSampler {
    private var prevTicks: (UInt32, UInt32, UInt32, UInt32)?

    func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpu = cpu()
        s.memUsed = memoryUsed()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0))
            s.diskTotal = UInt64(max(0, v.volumeTotalCapacity ?? 0))
        }
        (s.battery, s.charging) = battery()
        return s
    }

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks // (user, system, idle, nice)
        defer { prevTicks = t }
        guard let p = prevTicks else { return 0 }
        let user = Double(t.0 &- p.0), sys = Double(t.1 &- p.1), idle = Double(t.2 &- p.2), nice = Double(t.3 &- p.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total : 0
    }

    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        // Matches Activity Monitor's "Memory Used": app (internal - purgeable) + wired + compressed.
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private func battery() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return (cap * 100 / max, charging)
        }
        return (nil, false)
    }
}
