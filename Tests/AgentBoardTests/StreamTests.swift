import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import AgentBoard
@testable import simulator_host

/// Card streams (docs/streams.md): the framing, the hello and its token, input parsing, a real
/// server on the loopback whose H.264 a client decodes, a slow client, a restarted sidecar.
struct StreamTests {
    @Test func messagesSurviveAnyChunking() throws {
        let header = StreamWire.Out.header(.init(kind: "h264", width: 402, height: 874, units: "points"))
        let bytes = StreamWire.encode(header) + StreamWire.encode(.video(Data([0, 0, 0, 1, 0x65, 1, 2]))) + StreamWire.encode(.jpeg(Data([0xff, 0xd8])))
        var reader = StreamWire.Reader()
        var got: [StreamWire.Out] = []
        for byte in bytes {
            reader.append(Data([byte]))
            while let message = try reader.next() { got += [StreamWire.decode(message)].compactMap { $0 } }
        }
        #expect(got == [header, .video(Data([0, 0, 0, 1, 0x65, 1, 2])), .jpeg(Data([0xff, 0xd8]))])
    }

    @Test func oversizedMessagesAndHellosAreRefused() {
        var reader = StreamWire.Reader()
        reader.append(Data([0xff, 0xff, 0xff, 0xff]))
        #expect(throws: StreamWire.Reader.TooLarge.self) { try reader.next() }
        var hello = StreamWire.Reader()
        hello.append(Data(repeating: 0x61, count: StreamWire.maxHello + 1))
        #expect(throws: StreamWire.Reader.TooLarge.self) { try hello.line() }
    }

    @Test func theHelloNeedsTheToken() {
        let card = UUID()
        func hello(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        #expect(StreamWire.card(inHello: hello(["token": "secret", "card": card.uuidString]), token: "secret") == card)
        #expect(StreamWire.card(inHello: hello(["token": "secreT", "card": card.uuidString]), token: "secret") == nil)
        #expect(StreamWire.card(inHello: hello(["card": card.uuidString]), token: "secret") == nil)
        #expect(StreamWire.card(inHello: hello(["token": "secret", "card": "nope"]), token: "secret") == nil)
        #expect(StreamWire.card(inHello: Data("garbage".utf8), token: "secret") == nil)
    }

    @Test func inputEventsParse() {
        func parse(_ json: String) -> StreamWire.Input? { StreamWire.input(Data(json.utf8)) }
        #expect(parse(#"{"type":"touch","phase":"down","x":10,"y":20.5}"#) == .touch(phase: "down", x: 10, y: 20.5))
        #expect(parse(#"{"type":"touch","phase":"hover","x":1,"y":2}"#) == nil)
        #expect(parse(#"{"type":"scroll","x":1,"y":2,"dy":-30}"#) == .scroll(x: 1, y: 2, dx: 0, dy: -30))
        #expect(parse(#"{"type":"key","usage":40,"down":false}"#) == .key(usage: 40, name: nil, down: false, characters: nil))
        #expect(parse(#"{"type":"key","key":"Enter"}"#) == .key(usage: nil, name: "Enter", down: true, characters: nil))
        #expect(parse(#"{"type":"key"}"#) == nil)
        #expect(parse(#"{"type":"text","text":"hi"}"#) == .text("hi"))
        #expect(parse(#"{"type":"button","name":"home"}"#) == .button("home"))
        #expect(parse(#"{"type":"launch"}"#) == nil)
    }

    @Test @MainActor func aSlowClientSkipsToTheNextKeyframe() async throws {
        let source = FloodSource()
        let server = try StreamServer(sources: [source])
        let port = try await server.start()
        defer { server.stop() }
        // A small receive buffer, and nothing read while the card floods: the server backs up.
        let client = try Client(port: port, receiveBuffer: 16 << 10)
        client.write(Data(#"{"token":"\#(server.token)","card":"\#(source.card.uuidString)"}"#.utf8 + [0x0a]))
        try await Task.sleep(for: .seconds(2))
        let outs = await Task.detached { client.messages(count: FloodSource.count + 1, timeout: 3) }.value
        let units = outs.compactMap { out -> Data? in if case .video(let unit) = out { unit } else { nil } }
        let indices = units.map(FloodSource.index)
        #expect(units.count < FloodSource.count, "nothing was dropped")
        #expect(source.keyFrameRequests > 0)
        #expect(indices == indices.sorted())
        // Wherever frames were skipped, what comes next is a keyframe a decoder can start at.
        #expect(units.first.map(StreamWire.isKeyFrame) == true)
        for (previous, next) in zip(units, units.dropFirst()) where FloodSource.index(next) != FloodSource.index(previous) + 1 {
            #expect(StreamWire.isKeyFrame(next), "frame \(FloodSource.index(next)) follows a gap but isn't a keyframe")
        }
    }

    @Test @MainActor func anIOSStreamRecoversWhenTheSidecarRestarts() {
        let ios = IOSimulators()
        let card = UUID()
        ios.cards.insert(card)
        let got = Outs()
        let stop = ios.stream(card) { got.add($0) }
        #expect(stop != nil)
        let surface: [String: Any] = ["event": "surface", "card": card.uuidString, "contextID": 7, "width": 402.0, "height": 874.0]
        let header = StreamWire.Out.header(.init(kind: "h264", width: 402, height: 874, units: "points"))
        ios.received(surface)
        ios.received(["event": "video", "card": card.uuidString, "data": Data([0, 0, 0, 1, 0x65]).base64EncodedString()])
        #expect(got.all == [header, .video(Data([0, 0, 0, 1, 0x65]))])
        #expect(ios.streaming.contains(card))
        ios.sidecarEnded()
        #expect(!ios.streaming.contains(card))
        // The restarted sidecar shows the screen again: the stream is asked for again and the
        // client hears a fresh header, though the size is the same.
        ios.received(surface)
        #expect(got.all.last == header)
        #expect(got.all.filter { if case .header = $0 { true } else { false } }.count == 2)
        #expect(ios.streaming.contains(card))
        stop?()
        #expect(!ios.streaming.contains(card))
    }

    @Test @MainActor func aWrongTokenIsClosedAndItsInputNeverArrives() async throws {
        let source = FakeSource()
        let server = try StreamServer(sources: [source])
        let port = try await server.start()
        defer { server.stop() }
        let touch = StreamWire.frame(Data(#"{"type":"touch","phase":"down","x":1,"y":2}"#.utf8))
        let client = try Client(port: port)
        // The input rides right behind the hello, as an attacker would send it.
        client.write(Data(#"{"token":"wrong","card":"\#(source.card.uuidString)"}"#.utf8 + [0x0a]) + touch)
        #expect(await Task.detached { client.readToEnd(timeout: 3) }.value.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(source.inputs.isEmpty)
        #expect(source.watchers == 0)
    }

    @Test @MainActor func aClientWatchesACardAndDrivesIt() async throws {
        let source = FakeSource()
        let server = try StreamServer(sources: [source])
        let port = try await server.start()
        defer { server.stop() }
        let client = try Client(port: port)
        client.write(Data(#"{"token":"\#(server.token)","card":"\#(source.card.uuidString)"}"#.utf8 + [0x0a])
                     + StreamWire.frame(Data(#"{"type":"touch","phase":"up","x":3,"y":4}"#.utf8)))
        // The header, then the units the source encodes (H.264 from simulator-host's encoder).
        let count = 1 + source.unitCount
        // Off the main actor, where the server finds its sources.
        let outs = await Task.detached { client.messages(count: count, timeout: 10) }.value
        guard case .header(let header)? = outs.first else { Issue.record("no header"); return }
        #expect(header == FakeSource.header)
        let units = outs.dropFirst().compactMap { out -> Data? in if case .video(let unit) = out { unit } else { nil } }
        #expect(units.count == source.unitCount)
        // A client that decodes what came: the pictures are the encoded ones' size.
        let sizes = try Self.decode(units)
        #expect(sizes.count == source.unitCount)
        #expect(sizes.allSatisfy { $0 == CGSize(width: 320, height: 240) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(source.inputs == [.touch(phase: "up", x: 3, y: 4)])
        client.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(source.watchers == 0)
    }

    /// Decodes Annex B access units (parameter sets in front of the first) as a client would.
    static func decode(_ units: [Data]) throws -> [CGSize] {
        guard let first = units.first, let format = ScrcpyStream.formatDescription(fromConfig: first) else { throw Failed() }
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
                                           outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else { throw Failed() }
        defer { VTDecompressionSessionInvalidate(session) }
        let sizes = Sizes()
        for (index, unit) in units.enumerated() {
            // Parameter sets aren't picture data: the decoder takes them from the format.
            let picture = ScrcpyStream.nalUnits(unit).filter { ![7, 8].contains(($0.first ?? 0) & 0x1f) }
            var annexB = Data()
            for nal in picture { annexB += Data([0, 0, 0, 1]) + nal }
            guard let sample = ScrcpyStream.sampleBuffer(annexB: annexB, format: format, keyFrame: index == 0) else { throw Failed() }
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image { sizes.add(CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))) }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return sizes.all
    }

    struct Failed: Error {}

    final class Sizes: @unchecked Sendable {
        private var list: [CGSize] = []
        private let lock = NSLock()
        func add(_ size: CGSize) { lock.withLock { list.append(size) } }
        var all: [CGSize] { lock.withLock { list } }
    }
}

/// A card whose screen is a few frames from simulator-host's encoder.
@MainActor
private final class FakeSource: StreamSource {
    static let header = StreamWire.Header(kind: "h264", width: 160, height: 120, units: "points")
    let card = UUID()
    let unitCount = 5
    private(set) var inputs: [StreamWire.Input] = []
    private(set) var watchers = 0
    private let taps = StreamTaps()

    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)? {
        guard card == self.card else { return nil }
        watchers += 1
        taps.send(card, .header(Self.header))
        let id = taps.add(card, sink)
        let taps = taps, count = unitCount
        DispatchQueue.global().async {
            let encoder = VideoEncoder { data, _ in taps.send(card, .video(data)) }
            for index in 0..<count {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
                guard let buffer else { return }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32(index * 40), CVPixelBufferGetDataSize(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                encoder.encode(buffer)
                Thread.sleep(forTimeInterval: 0.03)
            }
            Thread.sleep(forTimeInterval: 3)  // the encoder takes ~2 s to start
            encoder.invalidate()
        }
        return { [weak self] in
            self?.taps.remove(card, id)
            self?.watchers -= 1
        }
    }

    func input(_ card: UUID, _ event: StreamWire.Input) { inputs.append(event) }
    func requestKeyFrame(_ card: UUID) {}
}

/// A card that sends numbered H.264-shaped units as fast as it can, a keyframe every 25, and
/// more often once asked.
@MainActor
private final class FloodSource: StreamSource {
    static let count = 400
    let card = UUID()
    private(set) var keyFrameRequests = 0
    private let taps = StreamTaps()
    private let asked = Flag()

    static func index(_ unit: Data) -> Int { unit.dropFirst(5).prefix(4).reduce(0) { $0 << 8 | Int($1) } }

    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)? {
        guard card == self.card else { return nil }
        let id = taps.add(card, sink)
        let taps = taps, asked = asked
        DispatchQueue.global().async {
            for index in 0..<Self.count {
                let key = index % 25 == 0 || asked.take()
                var unit = Data([0, 0, 0, 1, key ? 0x65 : 0x41])
                unit += withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) }
                unit += Data(repeating: 0x55, count: 64 << 10)
                taps.send(card, .video(unit))
            }
        }
        return { [weak self] in self?.taps.remove(card, id) }
    }

    func input(_ card: UUID, _ event: StreamWire.Input) {}

    func requestKeyFrame(_ card: UUID) {
        keyFrameRequests += 1
        asked.set()
    }
}

private final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.withLock { value = true } }
    func take() -> Bool { lock.withLock { defer { value = false }; return value } }
}

private final class Outs: @unchecked Sendable {
    private var list: [StreamWire.Out] = []
    private let lock = NSLock()
    func add(_ out: StreamWire.Out) { lock.withLock { list.append(out) } }
    var all: [StreamWire.Out] { lock.withLock { list } }
}

/// A blocking loopback TCP client, as a phone's would be past the channel.
private final class Client: @unchecked Sendable {
    private var fd: Int32

    init(port: UInt16, receiveBuffer: Int32? = nil) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        if var size = receiveBuffer { setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    func write(_ data: Data) { _ = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } }

    private func read(timeout: TimeInterval) -> Data? {
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }

    /// What arrives before the server closes (or `timeout` passes).
    func readToEnd(timeout: TimeInterval) -> Data {
        var all = Data()
        while let data = read(timeout: timeout) { all += data }
        return all
    }

    func messages(count: Int, timeout: TimeInterval) -> [StreamWire.Out] {
        var reader = StreamWire.Reader()
        var outs: [StreamWire.Out] = []
        let deadline = Date().addingTimeInterval(timeout)
        while outs.count < count, Date() < deadline, let data = read(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
            reader.append(data)
            while let message = try? reader.next() { outs += [StreamWire.decode(message)].compactMap { $0 } }
        }
        return outs
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}
