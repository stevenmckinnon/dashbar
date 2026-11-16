import Foundation
import Darwin
import AppKit

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
        print("  today \(Fmt.tokens(s.today.total)) tokens, \(s.today.messages) msgs, format \(s.warning == nil ? "reads" : "WARNING")")
        print("  of which subagents: today \(Fmt.tokens(s.period(.today).subagentTokens)), 7d \(Fmt.tokens(s.period(.week).subagentTokens))")
        // Counts only: never descriptions or anything else from the transcripts.
        let live = ClaudeSessions.read()
        let locator = ContextReader()
        let subagents = SubagentReader()
        let closed = time("Subagents (panel closed)") { subagents.read(live, transcript: { locator.transcript(for: $0) }, detail: false) }
        let open = time("Subagents (first open)") { subagents.read(live, transcript: { locator.transcript(for: $0) }, detail: true) }
        _ = time("Subagents (open, again)", runs: 5) { subagents.read(live, transcript: { locator.transcript(for: $0) }, detail: true) }
        let all = open.bySession.values.flatMap { $0 }
        print("  live sessions: \(live.count), with subagents: \(open.bySession.count), subagents running: \(open.runningCount) "
              + "(\(all.running.filter(\.background).count) background), just finished: \(all.count - all.running.count), "
              + "closed count matches: \(closed.runningCount == open.runningCount), format \(open.warning == nil ? "reads" : "WARNING")")
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
        let account = AgentAccounts.resolve(.claude, saved: []).first!
        let profile = time("Claude plan (profile)") { ClaudeProfile.plan(for: account) }
        _ = time("Claude plan (cached)", runs: 5) { ClaudeProfile.plan(for: account) }
        print("  \(Fmt.tilde(ClaudeProfile.file(for: account).path)): \(profile)")
        let gemini = GeminiUsageScanner()   // no saved progress: a full read of ~/.gemini/tmp
        let g = time("Gemini CLI scan (first)") { gemini.scan() }
        _ = time("Gemini CLI scan (again)") { gemini.scan() }
        print("  found \(g.found), today \(Fmt.tokens(g.today.total)) tokens, format \(g.warning == nil ? "reads" : "WARNING")")
        let google = GoogleCollector()
        let googleLive = time("Google sessions", runs: 5) { google.read() }
        print("  Gemini CLI and Antigravity sessions: \(googleLive.sessions.count) (\(googleLive.sessions.filter(\.isBusy).count) working), "
              + "format \(googleLive.warning == nil ? "reads" : "WARNING")")
        let openCodeUsage = OpenCodeUsage()
        let oc = time("OpenCode usage (first)") { openCodeUsage.scan() }
        let openCode = OpenCodeCollector()
        let ocLive = time("OpenCode sessions", runs: 5) { openCode.read() }
        print("  found \(oc.found), today \(Fmt.tokens(oc.today.total)) tokens, format \(oc.warning == nil ? "reads" : "WARNING"), "
              + "\(ocLive.count) live (\(ocLive.filter(\.isBusy).count) working)")
        let copilotUsage = CopilotUsageScanner()   // no cache: a bench run never writes the app's progress
        let cp = time("Copilot usage (first)") { copilotUsage.scan() }
        let copilot = CopilotCollector()
        let cpLive = time("Copilot sessions", runs: 5) { copilot.read() }
        print("  found \(cp.summary.found), today \(Fmt.tokens(cp.summary.today.total)) tokens, \(cp.unknownSessions) unknown, "
              + "format \(cp.summary.warning == nil ? "reads" : "WARNING"), \(cpLive.count) live (\(cpLive.filter(\.isBusy).count) working)")
        // One frame of the menu bar's working animation: the status, its image, and drawing it at 2x as the menu bar does.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var frame = 0
        time("Menu bar frame", runs: 500) {
            let status = MenuBarStatus.make(busySince: [Date().addingTimeInterval(-300)], waiting: 0, finished: nil,
                                            mode: .count, animate: true)
            let image = MenuBarStatusImage.image(status, fill: MenuBarStatus.sweep(tick: frame % MenuBarStatus.sweepFrames))
            frame += 1
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        print("  \(MenuBarStatus.sweepFrames) frames every \((MenuBarStatus.sweepFrames + MenuBarStatus.holdFrames) / Int(MenuBarStatus.fps)) s, only while agents work")
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
