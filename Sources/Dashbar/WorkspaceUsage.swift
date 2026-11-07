import Foundation
import Darwin

/// What one workspace is costing right now: its dev servers, its agent sessions, everything they started, and any
/// other process working inside the project folder.
struct WorkspaceUsage: Equatable {
    /// Share of the Mac's total CPU capacity since the previous sample, 0...1 (the System tab's scale).
    var cpu: Double = 0
    var memory: UInt64 = 0
    /// Estimated power in watts. Nil until two samples exist, or where macOS reports no energy figures.
    var watts: Double?
    /// When the oldest of its servers and agent processes started.
    var started: Date?
    /// Its processes grouped by name, busiest first.
    var processes: [ProcessGroup] = []
    var branch: String?

    struct ProcessGroup: Equatable, Identifiable {
        var id: String { name }
        let name: String
        var count = 0
        var cpu: Double = 0
        var memory: UInt64 = 0
    }
}

/// Recent samples for one workspace's charts (newest last).
struct WorkspaceHistory: Equatable {
    static let length = SystemHistory.length
    var cpu: [Double] = []
    var memory: [Double] = []
    var watts: [Double] = []

    mutating func append(_ u: WorkspaceUsage) {
        func push(_ array: inout [Double], _ value: Double) {
            array.append(value)
            if array.count > Self.length { array.removeFirst(array.count - Self.length) }
        }
        push(&cpu, u.cpu)
        push(&memory, Double(u.memory))
        if let w = u.watts { push(&watts, w) }
    }
}

/// Which workspace each process belongs to, and what each workspace uses. Runs only while a window is open.
final class WorkspaceSampler {
    private var previous: [pid_t: (cpu: UInt64, energy: UInt64)] = [:]
    private var previousAt: Date?
    private let ownPID = getpid()
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// `anchors` are the processes known to belong to a workspace (its agent sessions and dev servers), keyed by pid.
    func sample(roots: [String], anchors: [pid_t: String], now: Date = Date()) -> [String: WorkspaceUsage] {
        guard !roots.isEmpty else { previous = [:]; previousAt = nil; return [:] }
        var parents: [pid_t: pid_t] = [:]
        var started: [pid_t: Date] = [:]
        let pids = Proc.allPIDs()
        for pid in pids {
            if let info = Proc.bsdInfo(pid) { parents[pid] = info.parent; started[pid] = info.started }
        }
        let owners = Self.assign(pids: pids, parents: parents, roots: roots, anchors: anchors, exclude: ownPID,
                                 cwd: Proc.cwd, path: Proc.path)

        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        let capacity = elapsed * 1e9 * Double(ProcessInfo.processInfo.activeProcessorCount)
        var current: [pid_t: (cpu: UInt64, energy: UInt64)] = [:]
        var result: [String: WorkspaceUsage] = Dictionary(uniqueKeysWithValues: roots.map { ($0, WorkspaceUsage()) })
        var groups: [String: [String: WorkspaceUsage.ProcessGroup]] = [:]
        var energy: [String: UInt64] = [:]
        var energyReported = false

        for (pid, root) in owners {
            var usage = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0 else { continue }
            let cpuNs = (usage.ri_user_time &+ usage.ri_system_time) &* timebase.numer / timebase.denom
            current[pid] = (cpuNs, usage.ri_energy_nj)
            if usage.ri_energy_nj > 0 { energyReported = true }

            var share = 0.0
            if let before = previous[pid], capacity > 0 {
                if cpuNs > before.cpu { share = Double(cpuNs - before.cpu) / capacity }
                if usage.ri_energy_nj > before.energy { energy[root, default: 0] += usage.ri_energy_nj - before.energy }
            }
            result[root]?.cpu += share
            result[root]?.memory += usage.ri_resident_size
            let name = Self.displayName(Proc.name(pid), path: Proc.path(pid))
            var group = groups[root, default: [:]][name] ?? .init(name: name.isEmpty ? "pid \(pid)" : name)
            group.count += 1
            group.cpu += share
            group.memory += usage.ri_resident_size
            groups[root, default: [:]][name] = group
        }

        for root in roots {
            result[root]?.processes = (groups[root] ?? [:]).values.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
            if previousAt != nil, energyReported, elapsed > 0 {
                result[root]?.watts = Double(energy[root] ?? 0) / 1e9 / elapsed
            }
            result[root]?.started = anchors.filter { $0.value == root }.compactMap { started[$0.key] }.min()
            result[root]?.branch = Self.branch(in: root)
        }
        previous = current
        previousAt = now
        return result
    }

    /// Each process's workspace. An anchor belongs to its own; a process descended from an anchor belongs to the
    /// anchor's; anything else belongs to the workspace its working folder is in (the deepest match), unless it runs
    /// from inside a Mac app (an editor's helpers), which is the app's business rather than the project's.
    static func assign(pids: [pid_t], parents: [pid_t: pid_t], roots: [String], anchors: [pid_t: String], exclude: pid_t,
                       cwd: (pid_t) -> String?, path: (pid_t) -> String?) -> [pid_t: String] {
        var owners: [pid_t: String] = [:]
        let deepestFirst = roots.sorted { $0.count > $1.count }
        for pid in pids where pid != exclude {
            if let root = anchors[pid] { owners[pid] = root; continue }
            var current = pid
            var depth = 0
            var inherited: String?
            while let parent = parents[current], parent > 1, depth < 64 {
                if let root = anchors[parent] { inherited = root; break }
                current = parent
                depth += 1
            }
            if let inherited { owners[pid] = inherited; continue }
            guard let dir = cwd(pid), dir != "/",
                  let root = deepestFirst.first(where: { dir == $0 || dir.hasPrefix($0 + "/") }) else { continue }
            if let exe = path(pid), exe.contains(".app/Contents/") { continue }
            owners[pid] = root
        }
        return owners
    }

    /// The name a person would recognise. Some tools install each version as its own binary named after the version
    /// (Claude Code runs as `~/.local/share/claude/versions/2.1.318`), so a bare version number takes the name of the
    /// folder above the versions.
    static func displayName(_ name: String, path: String?) -> String {
        let isVersion = !name.isEmpty && name.first!.isNumber && name.allSatisfy { $0.isNumber || $0 == "." }
        guard isVersion, let path else { return name }
        let parts = URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents
            .filter { $0 != "/" && $0.lowercased() != "versions" && !($0.first?.isNumber ?? true) }
        return parts.last ?? name
    }

    /// The checked-out branch, read from `.git/HEAD` (following a worktree's `.git` file). A short commit when detached.
    static func branch(in root: String) -> String? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var gitDir = dotGit
        if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
            let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: root))
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        return parseHead(head)
    }

    static func parseHead(_ head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
        if line.hasPrefix("ref: ") { return String(line.dropFirst(5)) }
        return line.count >= 7 && line.allSatisfy(\.isHexDigit) ? String(line.prefix(7)) : nil
    }
}

extension WorkspaceUsage {
    /// A plain word for the power draw, so the number means something without knowing what a watt buys.
    static func energyWord(_ watts: Double) -> String {
        switch watts {
        case ..<0.5: return "Very low"
        case ..<2: return "Low"
        case ..<8: return "Moderate"
        default: return "High"
        }
    }
}
