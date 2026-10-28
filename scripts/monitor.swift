import Darwin
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

// Usage: monitor <pid> — prints the process CPU, memory, disk and network every second.
guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: monitor <pid>"); exit(1)
}

func usage() -> rusage_info_v4? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return ok == 0 ? info : nil
}

func network() -> (UInt64, UInt64) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    p.arguments = ["-P", "-L", "1", "-x", "-p", "\(pid)", "-J", "bytes_in,bytes_out"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return (0, 0) }
    p.waitUntilExit()
    let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").dropFirst()
    var rx: UInt64 = 0, tx: UInt64 = 0
    for line in lines {
        let f = line.split(separator: ",")
        if f.count >= 3 { rx += UInt64(f[1]) ?? 0; tx += UInt64(f[2]) ?? 0 }
    }
    return (rx, tx)
}

func fmt(_ b: Double) -> String {
    let u = ["B", "KB", "MB", "GB"]; var v = b; var i = 0
    while v >= 1024 && i < u.count - 1 { v /= 1024; i += 1 }
    return String(format: "%.1f %@", v, u[i])
}

var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
let toNs = Double(timebase.numer) / Double(timebase.denom)

guard var prev = usage() else { print("process \(pid) not found"); exit(1) }
var prevNet = network()
print("  CPU %   Memory      Disk read/s   Disk write/s  Net rx/s    Net tx/s")
while true {
    sleep(1)
    guard let cur = usage() else { print("process exited"); exit(0) }
    let net = network()
    let cpuNs = Double((cur.ri_user_time + cur.ri_system_time) - (prev.ri_user_time + prev.ri_system_time)) * toNs
    let pad = { (s: String, w: Int) in s.padding(toLength: w, withPad: " ", startingAt: 0) }
    print(String(format: "%6.1f   ", cpuNs / 1e7)
        + pad(fmt(Double(cur.ri_phys_footprint)), 12)
        + pad(fmt(Double(cur.ri_diskio_bytesread - prev.ri_diskio_bytesread)), 14)
        + pad(fmt(Double(cur.ri_diskio_byteswritten - prev.ri_diskio_byteswritten)), 14)
        + pad(fmt(Double(net.0 &- prevNet.0)), 12)
        + fmt(Double(net.1 &- prevNet.1)))
    prev = cur; prevNet = net
}
