import Benchmark
import Darwin
import Metal

/// The few metrics package-benchmark can't measure itself, each read from the system's own
/// counters (Metal's timestamps, the kernel's accounting of another process), never timed by hand.
public enum Metrics {
    /// GPU time of a frame's command buffer: Metal's `gpuEndTime - gpuStartTime`.
    public static let gpuTime = BenchmarkMetric.custom("GPU time (ns)", useScalingFactor: false)
    /// CPU time another process used over one sample of one second: 10 000 µs/s is 1% of a core.
    public static let processCPU = BenchmarkMetric.custom("Process CPU (µs/s)", useScalingFactor: false)
    /// Another process's physical footprint, what Activity Monitor shows as Memory.
    public static let processFootprint = BenchmarkMetric.custom("Process footprint (MB)", useScalingFactor: false)
    /// Frames a board drew in one sample of one second.
    public static let framesDrawn = BenchmarkMetric.custom("Frames drawn (per s)", polarity: .prefersLarger, useScalingFactor: false)
}

extension Benchmark {
    /// Records the GPU time of a completed command buffer.
    public func measureGPU(_ commands: MTLCommandBuffer) {
        measurement(Metrics.gpuTime, Int((commands.gpuEndTime - commands.gpuStartTime) * 1e9))
    }
}

/// The kernel's accounting for another process: CPU time summed over its threads as they are
/// now (what `ps` and `top` read), and its physical footprint.
public struct ProcessUsage {
    public let cpuNanoseconds: UInt64
    public let footprintBytes: UInt64

    public init?(pid: pid_t) {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { return nil }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // In Mach time units on Apple silicon, despite the field names.
        cpuNanoseconds = (task.pti_total_user + task.pti_total_system) * UInt64(timebase.numer) / UInt64(timebase.denom)
        footprintBytes = usage.ri_phys_footprint
    }
}

extension Benchmark {
    /// Records what `pid` used between two readings taken one sample apart.
    public func measureProcess(from start: ProcessUsage, to end: ProcessUsage, seconds: Double) {
        measurement(Metrics.processCPU, Int(Double(end.cpuNanoseconds - start.cpuNanoseconds) / 1000 / seconds))
        measurement(Metrics.processFootprint, Int(end.footprintBytes >> 20))
    }
}
