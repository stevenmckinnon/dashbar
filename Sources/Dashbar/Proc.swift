import Foundation
import Darwin

/// Process inspection through libproc and sysctl, in place of spawning `lsof` and `ps`.
/// Like those tools without sudo, it sees full detail only for the current user's processes.
enum Proc {
    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    /// Full path of the executable.
    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Short process name, as `lsof` and Activity Monitor show it.
    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    /// Current working directory.
    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Resident memory in bytes (what `ps -o rss` reports).
    static func residentBytes(_ pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_resident_size
    }

    /// Parent process and start time.
    static func bsdInfo(_ pid: pid_t) -> (parent: pid_t, started: Date)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return (pid_t(info.pbi_ppid), started)
    }

    /// Total CPU time the process has used since it started, in seconds.
    static func cpuSeconds(_ pid: pid_t) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // Task times are Mach ticks on Apple silicon (nanoseconds on Intel, where the timebase is 1/1).
        let ticks = info.pti_total_user &+ info.pti_total_system
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Every process's parent, for walking the process tree.
    static func parents(of pids: [pid_t]) -> [pid_t: pid_t] {
        var map: [pid_t: pid_t] = [:]
        map.reserveCapacity(pids.count)
        for pid in pids { if let info = bsdInfo(pid) { map[pid] = info.parent } }
        return map
    }

    /// The command line, including any title the process set for itself (as `ps -o command` shows).
    static func commandLine(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated arguments.
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // skip exec path
        while i < size, buf[i] == 0 { i += 1 }   // skip padding
        var args: [String] = []
        var start = i
        while i < size, args.count < argc {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    struct ListeningSocket: Equatable {
        let port: Int
        /// "*" for any address, otherwise the bound address ("127.0.0.1", "[::1]").
        let address: String
    }

    /// TCP sockets this process is listening on.
    static func listeningSockets(_ pid: pid_t) -> [ListeningSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }

        var result: [ListeningSocket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            let socket = ListeningSocket(port: port, address: address(ini))
            if !result.contains(socket) { result.append(socket) }
        }
        return result
    }

    private static func address(_ ini: in_sockinfo) -> String {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            if addr.s_addr == 0 { return "*" }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
            return String(cString: buf)
        }
        var addr6 = ini.insi_laddr.ina_6
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addr6, &buf, socklen_t(buf.count))
        let text = String(cString: buf)
        return text == "::" ? "*" : "[\(text)]"
    }
}
