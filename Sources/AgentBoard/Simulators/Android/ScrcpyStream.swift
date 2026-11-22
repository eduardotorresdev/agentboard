import AgentRuntime
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// An Android screen through scrcpy-server (bundled, pinned at `version`; Apache 2.0, see
/// scrcpy-LICENSE.txt): the server runs on the device with app_process, encodes the screen as
/// H.264 only when it changes, and takes input on a control socket. Both sockets are adb
/// `localabstract:` streams. The video is decoded by an AVSampleBufferDisplayLayer: no decoder
/// or frame loop of ours. Protocol: doc/develop.md at the pinned tag (it changes between versions).
final class ScrcpyStream: @unchecked Sendable {
    static let version = "5.0.1"
    static let serverPath = "/data/local/tmp/agentboard-scrcpy-\(version).jar"

    /// Shows the screen; owned by the stream, put in the card by the board.
    let layer = AVSampleBufferDisplayLayer()
    /// The size of the video, which control messages are in, once the first session says it.
    private(set) var videoSize = CGSize.zero
    /// Called (on the video thread) when the video size changes, and when the stream ends.
    var onSize: ((CGSize) -> Void)?
    var onEnd: ((Error?) -> Void)?
    /// Called (on the video thread) with each H.264 unit as it came, Annex B: the codec
    /// configuration, then frames. What a card stream passes through (StreamServer).
    var onVideo: ((Data) -> Void)?

    private let adb: AdbClient
    private let serial: String
    private var server: AdbStream?
    private var video: AdbStream?
    private var control: AdbStream?
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var frames = 0
    private var stopped = false
    private var capture: ((CGImage?) -> Void)?
    private var clipboardSequence: UInt64 = 1

    init(adb: AdbClient, serial: String) {
        self.adb = adb
        self.serial = serial
        layer.videoGravity = .resize
    }

    /// Copies the server to the device if it isn't there, starts it and connects. Blocks.
    func start(maxSize: Int) throws {
        let present = String(decoding: try adb.exec(serial, "[ -f \(Self.serverPath) ] && echo yes", timeout: 15), as: UTF8.self)
        if !present.contains("yes") {
            guard let url = Bundle.module.url(forResource: "scrcpy-server", withExtension: "jar"), let jar = try? Data(contentsOf: url) else {
                throw AdbClient.Failure(message: "The screen server is missing from the app.")
            }
            try adb.push(serial, jar, to: Self.serverPath)
        }
        let scid = String(format: "%08x", UInt32.random(in: 1..<0x7fff_ffff))
        let options = "scid=\(scid) log_level=warn tunnel_forward=true audio=false control=true video_codec=h264 max_size=\(maxSize) max_fps=60 clipboard_autosync=false cleanup=true"
        let server = try adb.open(serial, "shell:CLASSPATH=\(Self.serverPath) app_process / com.genymobile.scrcpy.Server \(Self.version) \(options)")
        self.server = server
        server.timeout(0)
        // The server listens a few seconds after app_process starts; until then adb refuses.
        var video: AdbStream?
        let deadline = Date().addingTimeInterval(30)
        while video == nil, Date() < deadline, !stopped {
            video = try? adb.open(serial, "localabstract:scrcpy_\(scid)")
            if video == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard let video else { stop(); throw AdbClient.Failure(message: "The screen server didn't start.") }
        self.video = video
        video.timeout(20)
        _ = try video.read(1)  // the forward tunnel's dummy byte
        let control = try adb.open(serial, "localabstract:scrcpy_\(scid)")
        self.control = control
        _ = try video.read(64)  // device name
        _ = try video.read(4)   // codec id: h264, as asked
        video.timeout(0)
        Thread.detachNewThread { [weak self] in self?.readVideo(video) }
        // Drains the device's messages (clipboard), which would otherwise fill the socket.
        Thread.detachNewThread { _ = control.readAll() }
    }

    func stop() {
        lock.withLock { stopped = true }
        [video, control, server].forEach { $0?.close() }
    }

    // MARK: Video

    private func readVideo(_ video: AdbStream) {
        var sessionAt: Date?
        do {
            while true {
                let header = try video.read(12)
                switch Self.packet(header) {
                case .session(let size):
                    videoSize = size
                    sessionAt = Date()
                    let frames = self.frames
                    onSize?(size)
                    // After an encoder restart or on a still screen the server may send no frame
                    // until something changes: ask for one.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.frames == frames, sessionAt != nil else { return }
                        self.send(Self.resetVideo())
                    }
                case .config(let size):
                    let config = try video.read(size)
                    format = StreamWire.formatDescription(fromConfig: config)
                    onVideo?(config)
                case .frame(let size, let key, _):
                    let payload = try video.read(size)
                    onVideo?(payload)
                    guard let format, let sample = StreamWire.sampleBuffer(annexB: payload, format: format, keyFrame: key) else { continue }
                    frames += 1
                    if layer.sampleBufferRenderer.status == .failed { layer.sampleBufferRenderer.flush() }
                    layer.sampleBufferRenderer.enqueue(sample)
                    if key, let capture = lock.withLock({ () -> ((CGImage?) -> Void)? in defer { self.capture = nil }; return self.capture }) {
                        Self.decode(sample, format: format, then: capture)
                    }
                }
            }
        } catch {
            let stopped = lock.withLock { self.stopped }
            onEnd?(stopped ? nil : error)
        }
    }

    /// The screen as it is now, from the next keyframe (asked for at once), without the device
    /// taking a screenshot; nil if none comes within `timeout`.
    func capture(timeout: TimeInterval = 3) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            lock.withLock { capture = { once.resume($0) } }
            send(Self.resetVideo())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.lock.withLock { self?.capture = nil }
                once.resume(nil)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<CGImage?, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }
        func resume(_ image: CGImage?) {
            lock.withLock { () -> CheckedContinuation<CGImage?, Never>? in defer { continuation = nil }; return continuation }?.resume(returning: image)
        }
    }

    private static func decode(_ sample: CMSampleBuffer, format: CMVideoFormatDescription, then done: @escaping (CGImage?) -> Void) {
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
                                           outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else { return done(nil) }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            var cgImage: CGImage?
            if status == noErr, let image { VTCreateCGImageFromCVPixelBuffer(image, options: nil, imageOut: &cgImage) }
            done(cgImage)
        }
        if status != noErr { done(nil) }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    // MARK: Control

    /// Sends a control message; dropped if the stream isn't up.
    func send(_ message: Data) {
        guard let control else { return }
        try? control.write(message)
    }

    /// Puts `text` on the device's clipboard and pastes it: typed in one go, any character.
    func paste(_ text: String) {
        let sequence = lock.withLock { () -> UInt64 in clipboardSequence += 1; return clipboardSequence }
        send(Self.setClipboard(text, sequence: sequence, paste: true))
    }

    // MARK: Protocol

    enum Packet: Equatable {
        /// A capture session starts, at this video size.
        case session(CGSize)
        /// Codec configuration (H.264: SPS and PPS) of this many bytes.
        case config(Int)
        case frame(size: Int, key: Bool, pts: UInt64)
    }

    /// A 12-byte header on the video socket.
    static func packet(_ header: Data) -> Packet {
        let bytes = [UInt8](header)
        let first = bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let last = Int(bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        if first & (1 << 63) != 0 {
            let width = Int(bytes[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            return .session(CGSize(width: width, height: last))
        }
        if first & (1 << 62) != 0 { return .config(last) }
        return .frame(size: last, key: first & (1 << 61) != 0, pts: first & ((1 << 61) - 1))
    }

    enum Action: UInt8 { case down = 0, up = 1, move = 2 }

    /// A finger (scrcpy's generic finger pointer) at `point` in video pixels.
    static func touch(_ action: Action, at point: CGPoint, video: CGSize) -> Data {
        var data = Data([2, action.rawValue]) + big(UInt64.max - 1)
        data += position(point, video)
        data += big(UInt16(action == .up ? 0 : 0xffff)) + big(Int32(0)) + big(Int32(0))
        return data
    }

    /// A scroll of `delta` notches (positive: content moves right/down, as a wheel turned
    /// toward the user), at most 16 each way.
    static func scroll(at point: CGPoint, video: CGSize, by delta: CGSize) -> Data {
        func fixed(_ value: CGFloat) -> Int16 { Int16(max(-1, min(1, value / 16)) * 32767) }
        return Data([3]) + position(point, video) + big(fixed(delta.width)) + big(fixed(delta.height)) + big(Int32(0))
    }

    /// An Android key event (`KeyEvent.KEYCODE_*`), `meta` its modifier state.
    static func key(_ code: Int, down: Bool, meta: Int = 0) -> Data {
        Data([0, down ? 0 : 1]) + big(Int32(code)) + big(Int32(0)) + big(Int32(meta))
    }

    static func text(_ text: String) -> Data {
        let bytes = Data(text.utf8.prefix(300))
        return Data([1]) + big(UInt32(bytes.count)) + bytes
    }

    static func setClipboard(_ text: String, sequence: UInt64, paste: Bool) -> Data {
        let bytes = Data(text.utf8)
        return Data([9]) + big(sequence) + Data([paste ? 1 : 0]) + big(UInt32(bytes.count)) + bytes
    }

    static func resetVideo() -> Data { Data([17]) }

    private static func position(_ point: CGPoint, _ video: CGSize) -> Data {
        big(Int32(point.x.rounded())) + big(Int32(point.y.rounded())) + big(UInt16(video.width)) + big(UInt16(video.height))
    }

    static func big<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}

