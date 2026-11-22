#if DEBUG
import OSLog
import QuartzCore
import SwiftUI

/// Frames the main thread managed, per second, logged as `fps <n>` under the app's subsystem
/// (`-perf YES`). Read with `xcrun simctl spawn booted log show --predicate 'subsystem == "dev.agentboard.phone"'`.
@MainActor final class DebugPerf: NSObject {
    static let shared = DebugPerf()
    private var link: CADisplayLink?
    private var frames = 0
    private var since = CACurrentMediaTime()
    private let log = Logger(subsystem: "dev.agentboard.phone", category: "perf")
    /// Work done since the last tick, by name (canvas bodies, terminal draws), to find what keeps a still board busy.
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    static func count(_ name: String) { counts[name, default: 0] += 1 }

    func start() {
        guard link == nil, UserDefaults.standard.bool(forKey: "perf") else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        frames += 1
        let now = CACurrentMediaTime()
        guard now - since >= 1 else { return }
        let fps = Int(Double(frames) / (now - since))
        log.notice("fps \(fps, privacy: .public)")
        // Also to Documents/perf.txt, which `simctl get_app_container … data` reaches.
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("perf.txt"),
           let handle = (try? FileHandle(forWritingTo: url)) ?? { FileManager.default.createFile(atPath: url.path, contents: nil); return try? FileHandle(forWritingTo: url) }() {
            handle.seekToEndOfFile()
            let work = Self.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            Self.counts = [:]
            handle.write(Data("fps \(fps) \(work)\n".utf8))
            try? handle.close()
        }
        frames = 0
        since = now
    }
}
#endif
