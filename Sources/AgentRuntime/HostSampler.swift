import Darwin
import Foundation

/// What this Mac is using, for `subscribeHost`, measured as the Rust core's `host_stats.rs` does
/// on macOS. CPU use is measured between two samples, so the first covers the time since the
/// sampler was made.
struct HostSampler {
    /// Processor ticks so far: idle, and all of them.
    private var previous = HostSampler.cpuTicks()

    mutating func sample() -> HostStats {
        let ticks = Self.cpuTicks()
        let idle = ticks.idle - min(previous.idle, ticks.idle), total = ticks.total - min(previous.total, ticks.total)
        previous = ticks
        let cpu = total == 0 ? 0 : min(max(1 - Double(idle) / Double(total), 0), 1)
        let memory = Self.memory(), disk = Self.disk()
        var load = [0.0]
        getloadavg(&load, 1)
        return HostStats(cpu: cpu, memoryUsed: memory.used, memoryTotal: memory.total, diskUsed: disk.used, diskTotal: disk.total,
                         load: load[0], cores: max(ProcessInfo.processInfo.activeProcessorCount, 1))
    }

    private static func cpuTicks() -> (idle: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
        return (ticks[Int(CPU_STATE_IDLE)], ticks.reduce(0, +))
    }

    /// What Activity Monitor calls memory used: app (active), wired and compressed.
    private static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return (min(pages * UInt64(vm_page_size), total), total)
    }

    /// Used and total bytes of the volume the home folder is on. Used is everything but the
    /// blocks available to the user.
    private static func disk() -> (used: UInt64, total: UInt64) {
        var volume = statvfs()
        guard statvfs(NSHomeDirectory(), &volume) == 0 else { return (0, 0) }
        let block = UInt64(volume.f_frsize), total = UInt64(volume.f_blocks) * block
        return (total - min(UInt64(volume.f_bavail) * block, total), total)
    }
}
