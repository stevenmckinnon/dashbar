import Foundation
import Darwin
import IOKit
import IOKit.ps
import AppKit

// MARK: - Snapshot

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct SystemSnapshot {
    var cpu: Double = 0              // 0...1 of all cores
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var load: [Double] = [0, 0, 0]   // 1, 5, 15 minute load averages
    var cores = ProcessInfo.processInfo.activeProcessorCount

    var memUsed: UInt64 = 0          // app + wired + compressed, as Activity Monitor's "Memory Used"
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var netDown: Double = 0          // bytes per second, all non-loopback interfaces
    var netUp: Double = 0

    var gpu: Double?                 // 0...1, nil where the driver doesn't report it

    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0

    var battery: Int?                // percent
    var charging = false
    var onAC = false
    var batteryMinutes: Int?         // to empty when discharging, to full when charging

    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var chip: String = SystemSampler.chipName
}

/// CPU share of one app (all its helper processes together) or one command-line tool.
struct AppUsage: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    /// The .app bundle, when the process lives inside one (for its icon).
    let appPath: String?
    /// Share of total CPU capacity, 0...1.
    let cpu: Double
}

// MARK: - Sampler

final class SystemSampler {
    private var prevTicks: (UInt32, UInt32, UInt32, UInt32)?
    private var prevNet: (down: UInt64, up: UInt64, at: Date)?
    private var prevProcCPU: [pid_t: UInt64] = [:]
    private var prevProcAt: Date?
    private var groupCache: [pid_t: (key: String, name: String, appPath: String?)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    static let chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        (s.cpu, s.cpuUser, s.cpuSystem) = cpu()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.load = load }
        memory(into: &s)
        (s.netDown, s.netUp) = network()
        s.gpu = Self.gpuUtilization()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0))
            s.diskTotal = UInt64(max(0, v.volumeTotalCapacity ?? 0))
        }
        battery(into: &s)
        return s
    }

    // MARK: CPU

    private func cpu() -> (Double, Double, Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return (0, 0, 0) }
        let t = info.cpu_ticks // (user, system, idle, nice)
        defer { prevTicks = t }
        guard let p = prevTicks else { return (0, 0, 0) }
        let user = Double(t.0 &- p.0), sys = Double(t.1 &- p.1), idle = Double(t.2 &- p.2), nice = Double(t.3 &- p.3)
        let total = user + sys + idle + nice
        guard total > 0 else { return (0, 0, 0) }
        return ((user + sys + nice) / total, (user + nice) / total, sys / total)
    }

    // MARK: Memory

    private func memory(into s: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            s.memApp = (internalPages - min(internalPages, UInt64(stats.purgeable_count))) * page
            s.memWired = UInt64(stats.wire_count) * page
            s.memCompressed = UInt64(stats.compressor_page_count) * page
            s.memUsed = s.memApp + s.memWired + s.memCompressed
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { s.swapUsed = swap.xsu_used }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            s.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
    }

    // MARK: Network

    /// Bytes per second across interfaces, from the 64-bit counters in NET_RT_IFLIST2.
    private func network() -> (Double, Double) {
        guard let (down, up) = Self.interfaceBytes() else { return (0, 0) }
        let now = Date()
        defer { prevNet = (down, up, now) }
        guard let p = prevNet else { return (0, 0) }
        let dt = now.timeIntervalSince(p.at)
        guard dt > 0.2 else { return (0, 0) }
        // Counters reset when an interface goes down; never report a negative rate.
        return (Double(down >= p.down ? down - p.down : 0) / dt, Double(up >= p.up ? up - p.up : 0) / dt)
    }

    static func interfaceBytes() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        var down: UInt64 = 0, up: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if info.ifm_flags & IFF_LOOPBACK == 0 {
                        down &+= info.ifm_data.ifi_ibytes
                        up &+= info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (down, up)
    }

    // MARK: GPU

    /// Utilisation from the graphics driver's published PerformanceStatistics (IOAccelerator).
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let value = (stats["Device Utilization %"] as? NSNumber) ?? (stats["GPU Activity(%)"] as? NSNumber)
            if let v = value?.doubleValue { result = max(result ?? 0, min(1, v / 100)) }
        }
        return result
    }

    // MARK: Battery

    private func battery(into s: inout SystemSnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            s.battery = cap * 100 / max
            s.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            s.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = s.charging ? d[kIOPSTimeToFullChargeKey] as? Int : (s.onAC ? nil : d[kIOPSTimeToEmptyKey] as? Int)
            s.batteryMinutes = (minutes ?? -1) > 0 ? minutes : nil   // -1 means macOS is still estimating
            return
        }
    }

    // MARK: Busiest apps

    /// Top apps by CPU since the previous call, grouping helper processes under their app.
    /// The first call primes the counters and returns nothing.
    func topApps(limit: Int = 5) -> [AppUsage] {
        let now = Date()
        var current: [pid_t: UInt64] = [:]
        var byGroup: [String: (name: String, appPath: String?, ns: UInt64)] = [:]
        let pids = Proc.allPIDs()
        for pid in pids {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            let ns = ticks &* timebase.numer / timebase.denom
            current[pid] = ns
            guard let before = prevProcCPU[pid], ns > before else { continue }
            let group = groupCache[pid] ?? Self.group(for: pid)
            groupCache[pid] = group
            byGroup[group.key, default: (group.name, group.appPath, 0)].ns += ns - before
        }
        defer {
            prevProcCPU = current
            prevProcAt = now
            groupCache = groupCache.filter { current[$0.key] != nil }
        }
        guard let last = prevProcAt else { return [] }
        let capacity = now.timeIntervalSince(last) * 1e9 * Double(ProcessInfo.processInfo.activeProcessorCount)
        guard capacity > 0 else { return [] }
        return byGroup.map { AppUsage(key: $0.key, name: $0.value.name, appPath: $0.value.appPath, cpu: Double($0.value.ns) / capacity) }
            .filter { $0.cpu >= 0.001 }
            .sorted { $0.cpu > $1.cpu }
            .prefix(limit).map { $0 }
    }

    /// Groups a process under the outermost .app bundle it runs from (so Chrome's helpers count as Chrome),
    /// otherwise under its executable name.
    static func group(for pid: pid_t) -> (key: String, name: String, appPath: String?) {
        let path = Proc.path(pid) ?? ""
        if let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            let name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
            return (appPath, name, appPath)
        }
        let name = path.isEmpty ? Proc.name(pid) : URL(fileURLWithPath: path).lastPathComponent
        return ("exe:" + name, name.isEmpty ? "pid \(pid)" : name, nil)
    }
}

extension Fmt {
    /// "628 KB/s", "1.2 MB/s", "0 B/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        rateFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    private static let rateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false   // "0 bytes", never "Zero KB"
        return f
    }()

    /// Compact rate for the menu bar: "628K", "1.2M".
    static func shortRate(_ bytesPerSecond: Double) -> String {
        let v = bytesPerSecond
        switch v {
        case 1e9...: return String(format: "%.1fG", v / 1e9)
        case 1e7...: return String(format: "%.0fM", v / 1e6)
        case 1e6...: return String(format: "%.1fM", v / 1e6)
        case 1e3...: return String(format: "%.0fK", v / 1e3)
        default: return String(format: "%.0fB", v)
        }
    }

    /// "2h 27m", "45m"
    static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// Recent samples for the bar charts (newest last).
struct SystemHistory {
    static let length = 40
    var cpu: [Double] = []
    var memory: [Double] = []
    var gpu: [Double] = []
    var down: [Double] = []
    var up: [Double] = []

    mutating func append(_ s: SystemSnapshot) {
        func push(_ array: inout [Double], _ value: Double) {
            array.append(value)
            if array.count > Self.length { array.removeFirst(array.count - Self.length) }
        }
        push(&cpu, s.cpu)
        push(&memory, Double(s.memUsed) / Double(max(s.memTotal, 1)))
        if let g = s.gpu { push(&gpu, g) }
        push(&down, s.netDown)
        push(&up, s.netUp)
    }
}
