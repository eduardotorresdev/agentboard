import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import AgentBoard
@testable import simulator_host

/// Card streams (docs/streams.md): the framing, the hello and its token, input parsing, and a
/// real server on the loopback whose H.264 a client decodes.
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

    @Test @MainActor func theAdvertisedFileIsPrivate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("streams.json")
        let server = try StreamServer(sources: [], advertise: file)
        let port = try await server.start()
        defer { server.stop() }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(object?["port"] as? Int == Int(port))
        #expect(object?["token"] as? String == server.token)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test @MainActor func aWrongTokenIsClosedAndItsInputNeverArrives() async throws {
        let source = FakeSource()
        let server = try StreamServer(sources: [source], advertise: nil)
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
        let server = try StreamServer(sources: [source], advertise: nil)
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
}

/// A blocking loopback TCP client, as a phone's would be past the channel.
private final class Client: @unchecked Sendable {
    private var fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
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
