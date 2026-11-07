import Foundation
import Darwin

/// `Dashbar --bench`: times the expensive collectors and prints resident memory, then exits.
/// Used to compare performance work before and after.
enum Bench {
    static func run() -> Never {
        func time<T>(_ label: String, runs: Int = 1, _ body: () -> T) -> T {
            var result: T!
            let start = Date()
            for _ in 0..<runs { result = body() }
            let ms = Date().timeIntervalSince(start) * 1000 / Double(runs)
            print(label.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%8.1f ms", ms) + (runs > 1 ? " (avg of \(runs))" : ""))
            return result
        }
        let scanner = ClaudeUsageScanner()
        let s = time("Claude scan (first)") { scanner.scan() }
        _ = time("Claude scan (incremental)") { scanner.scan() }
        print("  today \(Fmt.tokens(s.today.total)) tokens, \(s.today.messages) msgs")
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("dashbar-bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let warm = ClaudeUsageScanner(cache: cacheURL)
        _ = warm.scan(); warm.save()
        let size = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int) ?? 0
        let relaunched = time("Claude scan (from saved)") { ClaudeUsageScanner(cache: cacheURL).scan() }
        print("  saved file \(Fmt.bytes(UInt64(size))), today \(Fmt.tokens(relaunched.today.total)) (matches: \(relaunched.today == s.today))")
        let l = time("Listening ports", runs: 5) { Listeners.read() }
        print("  \(l.count) listeners, \(l.filter(\.isDev).count) dev")
        let a = time("Agent processes", runs: 5) { AgentProcesses.read() }
        print("  \(a.map(\.name).joined(separator: ", "))")
        let sampler = SystemSampler()
        _ = sampler.sample(); _ = sampler.topApps()
        Thread.sleep(forTimeInterval: 1.5)
        let sys = time("System sample") { sampler.sample() }
        let apps = time("Busiest apps") { sampler.topApps() }
        print(String(format: "  CPU %.0f%% (user %.0f%%, system %.0f%%), load %.2f, %d cores, %@", sys.cpu * 100, sys.cpuUser * 100, sys.cpuSystem * 100, sys.load[0], sys.cores, sys.chip))
        print("  Memory \(Fmt.bytes(sys.memUsed)) of \(Fmt.bytes(sys.memTotal)): app \(Fmt.bytes(sys.memApp)), wired \(Fmt.bytes(sys.memWired)), compressed \(Fmt.bytes(sys.memCompressed)), swap \(Fmt.bytes(sys.swapUsed)), pressure \(sys.pressure.label)")
        print("  Network ↓\(Fmt.rate(sys.netDown)) ↑\(Fmt.rate(sys.netUp)), GPU \(sys.gpu.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a")")
        print("  Battery \(sys.battery.map { "\($0)%" } ?? "none"), charging \(sys.charging), AC \(sys.onAC), \(sys.batteryMinutes.map { Fmt.minutes($0) } ?? "no estimate")")
        for a in apps { print(String(format: "  %5.1f%%  %@", a.cpu * 100, a.name)) }
        let workspaces = Workspace.build(sessions: ClaudeSessions.read(), servers: l.filter { $0.isDev && $0.root != nil && !$0.isDocker })
        var anchors: [pid_t: String] = [:]
        for w in workspaces { for s in w.sessions { anchors[s.pid] = w.root }; for s in w.servers { anchors[s.pid] = w.root } }
        let ws = WorkspaceSampler()
        _ = ws.sample(roots: workspaces.map(\.root), anchors: anchors)
        Thread.sleep(forTimeInterval: 1.5)
        let usage = time("Workspace usage") { ws.sample(roots: workspaces.map(\.root), anchors: anchors) }
        for w in workspaces {
            guard let u = usage[w.root] else { continue }
            print(String(format: "  %-22@ %5.1f%% %9@ %@  %@", w.name as NSString, u.cpu * 100, Fmt.bytes(u.memory) as NSString,
                         u.watts.map { String(format: "%.2f W", $0) } ?? "no energy",
                         u.processes.prefix(4).map { "\($0.name)×\($0.count)" }.joined(separator: " ")))
        }
        print("Resident memory: \(Fmt.bytes(residentBytes()))")
        exit(0)
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? info.resident_size : 0
    }
}
