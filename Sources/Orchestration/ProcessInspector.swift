import Darwin
import Foundation

/// A TCP port a runner's processes listen on.
public struct ListeningPort: Hashable, Comparable, Codable, Sendable {
    public let port: Int
    /// Listens on every interface, so other devices on the network reach it too (not only this Mac).
    public let exposed: Bool

    public static func < (a: ListeningPort, b: ListeningPort) -> Bool { a.port < b.port }
}

/// What a runner costs and serves right now, summed over its process and everything it started.
public struct RunnerStats: Equatable, Codable, Sendable {
    /// Percent of one core over the last sample interval; nil until two samples exist.
    public var cpu: Double?
    /// Physical footprint in bytes, as Activity Monitor's Memory column shows it.
    public var memory: UInt64
    public var processes: Int
    public var ports: [ListeningPort]
}

/// Reads processes through libproc and sysctl (no `ps` or `lsof` to spawn): a process's
/// descendants, their CPU time and memory, and the TCP ports they listen on. Only the user's own
/// processes are visible, which is all a runner starts.
public enum ProcessInspector {
    /// A measurement of one runner: its stats, and the CPU time it had used, for the next sample.
    public struct Sample: Sendable {
        public var stats: RunnerStats
        let cpuTime: UInt64
        let time: UInt64
    }

    /// Measures each root process and its descendants. `previous` gives each its last sample, to
    /// turn CPU time into a percentage.
    public static func sample(_ roots: [UUID: pid_t], previous: [UUID: Sample]) -> [UUID: Sample] {
        guard !roots.isEmpty else { return [:] }
        let children = childrenByParent()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var result: [UUID: Sample] = [:]
        for (id, root) in roots {
            let tree = descendants(of: root, children: children)
            var cpuTime: UInt64 = 0
            var memory: UInt64 = 0
            var ports = Set<ListeningPort>()
            for pid in tree {
                if let usage = usage(of: pid) {
                    cpuTime += usage.cpu
                    memory += usage.memory
                }
                ports.formUnion(listeningPorts(of: pid))
            }
            var cpu: Double?
            if let last = previous[id], now > last.time, cpuTime >= last.cpuTime {
                cpu = Double(cpuTime - last.cpuTime) / Double(now - last.time) * 100
            }
            // A port on both IPv4 and IPv6 shows once, exposed if either is.
            let merged = Dictionary(grouping: ports, by: \.port).map { port, all in
                ListeningPort(port: port, exposed: all.contains { $0.exposed })
            }
            result[id] = Sample(stats: RunnerStats(cpu: cpu, memory: memory, processes: tree.count, ports: merged.sorted()),
                                cpuTime: cpuTime, time: now)
        }
        return result
    }

    /// `root` and every process below it.
    static func descendants(of root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var result = [root]
        var index = 0
        while index < result.count {
            result += children[result[index]] ?? []
            index += 1
        }
        return result
    }

    /// The user's processes by parent, from one sysctl call.
    static func childrenByParent() -> [pid_t: [pid_t]] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Processes may start between the two calls.
        size += size / 4
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        var children: [pid_t: [pid_t]] = [:]
        for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            children[proc.kp_eproc.e_ppid, default: []].append(proc.kp_proc.p_pid)
        }
        return children
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// CPU time used (nanoseconds) and physical footprint (bytes).
    private static func usage(of pid: pid_t) -> (cpu: UInt64, memory: UInt64)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        // Times are in Mach ticks, which are not nanoseconds on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return (ticks * UInt64(timebase.numer) / UInt64(timebase.denom), info.ri_phys_footprint)
    }

    /// The TCP ports `pid` listens on.
    private static func listeningPorts(of pid: pid_t) -> [ListeningPort] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard filled > 0 else { return [] }
        var ports: [ListeningPort] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            guard port > 0 else { continue }
            let address = tcp.tcpsi_ini.insi_laddr
            let exposed: Bool
            if tcp.tcpsi_ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                // In network order; the first byte 127 is loopback.
                let ip = UInt32(bigEndian: address.ina_46.i46a_addr4.s_addr)
                exposed = ip >> 24 != 127
            } else {
                var loopback = in6addr_loopback
                var v6 = address.ina_6
                exposed = memcmp(&v6, &loopback, MemoryLayout<in6_addr>.size) != 0
            }
            ports.append(ListeningPort(port: port, exposed: exposed))
        }
        return ports
    }

    /// This Mac's address on the local network (Wi-Fi or Ethernet), for ports other devices can reach.
    public static func networkAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((name, String(cString: host)))
        }
        // en0 is the built-in Wi-Fi (or Ethernet) on every Mac.
        return (candidates.first { $0.name == "en0" } ?? candidates.first)?.address
    }
}
