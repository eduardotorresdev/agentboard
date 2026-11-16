import AVFoundation
import AppKit
import Benchmark

// A lower bound only: raw AVPlayerLayers in an offscreen window, with a 4 Hz time observer
// each, against a 60 Hz main-thread timer standing in for the board's display link. It doesn't
// run VideoPlayback or BoardView and doesn't confirm frames were decoded, so it says nothing
// about the real board's frame pacing; that needs the App suite with visible video cards.
enum VideoPacing {
    static let lateMean = BenchmarkMetric.custom("Tick lateness, mean (µs)", useScalingFactor: false)
    static let lateP99 = BenchmarkMetric.custom("Tick lateness, p99 (µs)", useScalingFactor: false)
    static let missed = BenchmarkMetric.custom("Ticks later than a frame (count)", useScalingFactor: false)
    static let cpu = BenchmarkMetric.custom("Own CPU (µs/s)", useScalingFactor: false)
    static let metrics = [lateMean, lateP99, missed, cpu]

    static func register() {
        for (count, playing) in [(0, false), (4, false), (4, true), (8, true)] {
            Benchmark("video/\(count) \(playing ? "playing" : "paused")",
                      configuration: .init(metrics: metrics, warmupIterations: 0, maxIterations: 1)) { benchmark in
                let result = onMain { run(count: count, playing: playing) }
                benchmark.measurement(lateMean, result.mean)
                benchmark.measurement(lateP99, result.p99)
                benchmark.measurement(missed, result.missed)
                benchmark.measurement(cpu, result.cpu)
            }
        }
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// A 10 s 1280×720 H.264 clip, written once.
    private static let clip: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-clip-720p.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let (width, height, fps, seconds) = (1280, 720, 30, 10)
        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            // Moving noise, so the encoder can't make every frame free.
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt32.self)
            for i in 0..<(CVPixelBufferGetDataSize(buffer!) / 4) { base[i] = UInt32(truncatingIfNeeded: (i &* 2654435761) ^ (frame &* 40503)) }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return url
    }()

    private static func run(count: Int, playing: Bool) -> (mean: Int, p99: Int, missed: Int, cpu: Int) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 1600, height: 1000), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let root = window.contentView!.layer!
        var players: [AVPlayer] = []
        var observers: [Any] = []
        for index in 0..<count {
            let player = AVPlayer(url: clip)
            player.isMuted = true
            let layer = AVPlayerLayer(player: player)
            layer.frame = CGRect(x: index % 4 * 400, y: index / 4 * 240, width: 384, height: 216)
            root.addSublayer(layer)
            observers.append(player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { _ in })
            if playing { player.play() }
            players.append(player)
        }
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1)) // players load and start

        var late: [Double] = []
        let start = CACurrentMediaTime(), cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        var tick = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            tick += 1
            late.append(max(0, CACurrentMediaTime() - (start + Double(tick) / 60)))
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        timer.invalidate()
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart) / 1000 / 3
        for (player, observer) in zip(players, observers) { player.pause(); player.removeTimeObserver(observer) }
        window.orderOut(nil)

        late.sort()
        let mean = late.reduce(0, +) / Double(max(1, late.count))
        return (Int(mean * 1e6), Int((late.isEmpty ? 0 : late[late.count * 99 / 100]) * 1e6),
                late.filter { $0 > 1.0 / 60 }.count, Int(cpu))
    }
}
