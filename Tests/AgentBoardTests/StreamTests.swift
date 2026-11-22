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
        let ios = IOSSimulators()
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

    /// A real browser card through the real sidecar (Playwright's WebKit, reused from another
    /// install: AGENTBOARD_PLAYWRIGHT_MODULES), streamed over the loopback: measures frames a
    /// second and input-to-picture latency, then kills the sidecar and expects the stream back.
    @Test(.enabled(if: BrowserHost.reusablePlaywright != nil, "needs AGENTBOARD_PLAYWRIGHT_MODULES with this build's Playwright"), .timeLimit(.minutes(3)))
    @MainActor func aBrowserStreamLivesThroughItsSidecarRestarting() async throws {
        let browsers = BrowserStore(database: nil)
        let record = browsers.add(.desktop, to: NSTemporaryDirectory(), at: .zero, url: "about:blank")
        defer { browsers.remove(record.id) }
        try await browsers.ready(record.id)
        // A still page whose colour flips on each click: the screencast sends a frame only when
        // the picture changes, so the first frame after a click is the click's.
        let page = "() => { document.body.style.margin = '0'; document.body.style.height = '100vh'; let on = false; "
            + "document.body.onclick = () => { on = !on; document.body.style.background = on ? '#0090ff' : '#ffffff' } }"
        // The first page may still be navigating: try until it settles.
        for attempt in 1...10 {
            do {
                _ = try await browsers.call("evaluate", on: record.id, ["function": page])
                break
            } catch where attempt < 10 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        let server = try StreamServer(sources: [browsers])
        let port = try await server.start()
        defer { server.stop() }
        let client = try Client(port: port)
        client.write(Data(#"{"token":"\#(server.token)","card":"\#(record.id.uuidString)"}"#.utf8 + [0x0a]))
        let first = await Task.detached { client.messages(count: 1, timeout: 20) }.value
        guard case .header(let header)? = first.first else { Issue.record("no header"); return }
        #expect(header.kind == "jpeg")

        var latencies: [Double] = []
        for _ in 0..<8 {
            await Task.detached { client.drain(0.5) }.value
            let sent = Date()
            for phase in ["down", "up"] {
                client.write(StreamWire.frame(Data(#"{"type":"touch","phase":"\#(phase)","x":40,"y":40}"#.utf8)))
            }
            if let shown = await Task.detached(operation: { client.nextJPEG(timeout: 3) }).value { latencies.append(shown.timeIntervalSince(sent) * 1000) }
        }
        #expect(latencies.count >= 6, "clicks didn't show: \(latencies)")

        let animate = "() => { const tick = () => { document.body.style.background = `hsl(${Date.now() % 360}, 80%, 50%)`; requestAnimationFrame(tick) }; tick() }"
        _ = try await browsers.call("evaluate", on: record.id, ["function": animate])
        await Task.detached { client.drain(0.5) }.value
        let frames = await Task.detached { () -> Int in
            var count = 0
            let end = Date().addingTimeInterval(5)
            while let _ = client.nextJPEG(timeout: end.timeIntervalSinceNow) { count += 1 }
            return count
        }.value
        let sorted = latencies.sorted()
        print("stream-live browser: \(Double(frames) / 5) fps animating; click to frame ms median \(sorted.isEmpty ? 0 : sorted[sorted.count / 2]) "
              + "min \(sorted.first ?? 0) max \(sorted.last ?? 0); load \(Self.load())")
        #expect(frames > 25)

        // The sidecar dies; nothing shows the card on a board, yet its stream comes back.
        let pid = try #require(browsers.host.pid)
        kill(pid, SIGKILL)
        let killed = Date()
        let again = await Task.detached { () -> (Bool, Date?) in
            var header = false
            let end = Date().addingTimeInterval(60)
            while let out = client.next(timeout: end.timeIntervalSinceNow) {
                if case .header = out { header = true }
                if header, case .jpeg = out { return (true, Date()) }
            }
            return (header, nil)
        }.value
        #expect(again.0, "no fresh header after the sidecar restarted")
        let back = try #require(again.1, "no frame after the sidecar restarted")
        print("stream-live browser: back \(back.timeIntervalSince(killed)) s after the sidecar was killed")
        client.close()
    }

    /// Tests never run an installer: with no existing Playwright named, the sidecar refuses to
    /// start rather than download Node, Playwright or WebKit.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_PLAYWRIGHT_MODULES"] == nil))
    @MainActor func aTestNeverInstallsPlaywright() async {
        let host = BrowserHost()
        do {
            _ = try await host.request("devices", [:])
            Issue.record("the sidecar started")
        } catch {
            #expect(error.localizedDescription.contains("Tests don't install Playwright"))
        }
        #expect(!FileManager.default.fileExists(atPath: BrowserHost.folder.appendingPathComponent("Host/node_modules").path))
        host.stop()
    }

    /// A real iOS Simulator (a device made for the test, booted headless by the real
    /// simulator-host: AGENTBOARD_SIMULATOR_HOST, then shut down and deleted) streamed over the
    /// loopback: how soon a viewer gets its first picture, and frames while a finger drags.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_SIMULATOR_HOST"] != nil), .timeLimit(.minutes(14)))
    @MainActor func anIOSSimulatorStreamsLive() async throws {
        let udid = try Self.simctl(["create", "AgentBoard stream test", "iPhone 17"]).trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            _ = try? Self.simctl(["shutdown", udid])
            _ = try? Self.simctl(["delete", udid])
        }
        let ios = IOSSimulators()
        let record = SimulatorRecord(id: UUID(), worktree: "/w", name: "iPhone 17", udid: udid, deviceType: "iPhone 17", frame: .zero)
        _ = try await ios.open(record, pixels: 800)
        // The screen comes up and the encoder warms before anyone watches, as on a board.
        try await Task.sleep(for: .seconds(8))
        let source = IOSSource(ios: ios, card: record.id)
        let server = try StreamServer(sources: [source])
        let port = try await server.start()
        defer { server.stop() }
        let client = try Client(port: port)
        let asked = Date()
        client.write(Data(#"{"token":"\#(server.token)","card":"\#(record.id.uuidString)"}"#.utf8 + [0x0a]))
        let firstPicture = await Task.detached { () -> Date? in
            let end = Date().addingTimeInterval(20)
            while let out = client.next(timeout: end.timeIntervalSinceNow) { if case .video = out { return Date() } }
            return nil
        }.value
        _ = try #require(firstPicture, "no picture").timeIntervalSince(asked)

        // Booting the device loads the machine: measure only once the 1-minute load is below 5
        // (up to 480 s), the first stream still open and drained meanwhile.
        let settled = await Task.detached { () -> Bool in
            let end = Date().addingTimeInterval(480)
            while Date() < end {
                if Self.oneMinuteLoad() < 5 { return true }
                client.drain(5)
                print("stream-live ios: waiting for the load to settle: \(Self.load())")
            }
            return false
        }.value
        let loadAtStart = Self.load()

        // A second viewer joins the warm stream: how soon its first picture comes.
        let viewer = try Client(port: port)
        let joining = Date()
        viewer.write(Data(#"{"token":"\#(server.token)","card":"\#(record.id.uuidString)"}"#.utf8 + [0x0a]))
        let viewerPicture = await Task.detached { () -> Date? in
            let end = Date().addingTimeInterval(20)
            while let out = viewer.next(timeout: end.timeIntervalSinceNow) { if case .video = out { return Date() } }
            return nil
        }.value
        let joined = try #require(viewerPicture, "no picture for the second viewer").timeIntervalSince(joining)
        client.close()

        // A finger drags the home screen sideways and back for 3 s.
        let size = CGSize(width: 402, height: 874)
        let dragged = Date()
        let counting = Task.detached { () -> (Int, Date?) in
            var count = 0, first: Date?
            let end = Date().addingTimeInterval(4)
            while let out = viewer.next(timeout: end.timeIntervalSinceNow) {
                if case .video = out { count += 1; first = first ?? Date() }
            }
            return (count, first)
        }
        ios.touch(record.id, "down", at: CGPoint(x: size.width * 0.8, y: size.height / 2))
        for step in 0..<180 {
            try await Task.sleep(for: .milliseconds(16))
            let t = Double(step % 60) / 60
            ios.touch(record.id, "move", at: CGPoint(x: size.width * (0.8 - 0.6 * (step / 60 % 2 == 0 ? t : 1 - t)), y: size.height / 2))
        }
        ios.touch(record.id, "up", at: CGPoint(x: size.width * 0.5, y: size.height / 2))
        let (frames, first) = await counting.value
        let toPicture = first.map { $0.timeIntervalSince(dragged) * 1000 } ?? -1

        // 20 separate touches, 0.5 s apart: a finger goes down and moves 40 points (the home
        // screen follows), and the time to the next frame is taken from the move.
        var touches: [Double] = []
        for index in 0..<20 {
            await Task.detached { viewer.drain(0.5) }.value
            let x = size.width / 2, y = size.height / 2, toward: CGFloat = index % 2 == 0 ? -40 : 40
            ios.touch(record.id, "down", at: CGPoint(x: x, y: y))
            try await Task.sleep(for: .milliseconds(20))
            let moved = Date()
            ios.touch(record.id, "move", at: CGPoint(x: x + toward, y: y))
            let shown = await Task.detached { () -> Date? in
                let end = Date().addingTimeInterval(2)
                while let out = viewer.next(timeout: end.timeIntervalSinceNow) { if case .video = out { return Date() } }
                return nil
            }.value
            ios.touch(record.id, "up", at: CGPoint(x: x + toward, y: y))
            if let shown { touches.append(shown.timeIntervalSince(moved) * 1000) }
        }
        let sortedTouches = touches.dropFirst().sorted()
        func percentile(_ q: Double) -> Double { sortedTouches.isEmpty ? -1 : sortedTouches[min(sortedTouches.count - 1, Int(Double(sortedTouches.count) * q))] }
        print("stream-live ios touches: \(touches.count) of 20 showed; first \(String(format: "%.0f", touches.first ?? -1)) ms; "
              + "the rest median \(String(format: "%.0f", percentile(0.5))) p90 \(String(format: "%.0f", percentile(0.9))) "
              + "max \(String(format: "%.0f", sortedTouches.last ?? -1)) ms; all \(touches.map { Int($0) })")
        let valid = settled && Self.oneMinuteLoad() < 5
        print("stream-live ios \(valid ? "VALID" : "INVALID (load not below 5)"): first picture \(String(format: "%.2f", joined)) s after a viewer's hello; "
              + "\(Double(frames) / 3) fps while dragging; first drag frame \(String(format: "%.0f", toPicture)) ms after the finger went down; "
              + "load at start \(loadAtStart), at end \(Self.load())")
        #expect(frames > 30)
        viewer.close()
        await ios.close(record, deleting: false)
    }

    static func simctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func oneMinuteLoad() -> Double {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return load[0]
    }

    static func load() -> String {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return load.map { String(format: "%.1f", $0) }.joined(separator: " ")
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

/// One iOS card of an `IOSSimulators`, as `SimulatorStore` serves it.
@MainActor
private final class IOSSource: StreamSource {
    let ios: IOSSimulators
    let card: UUID
    init(ios: IOSSimulators, card: UUID) {
        self.ios = ios
        self.card = card
    }
    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)? { card == self.card ? ios.stream(card, to: sink) : nil }
    func input(_ card: UUID, _ event: StreamWire.Input) {
        if case .touch(let phase, let x, let y) = event { ios.touch(card, phase, at: CGPoint(x: x, y: y)) }
    }
    func requestKeyFrame(_ card: UUID) { ios.requestKeyFrame(card) }
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

    private var reader = StreamWire.Reader()

    /// The next message, or nil if none comes within `timeout`.
    func next(timeout: TimeInterval) -> StreamWire.Out? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let message = try? reader.next() {
                if let out = StreamWire.decode(message) { return out }
                continue
            }
            guard deadline.timeIntervalSinceNow > 0, let data = read(timeout: max(0.01, deadline.timeIntervalSinceNow)) else { return nil }
            reader.append(data)
        }
    }

    func messages(count: Int, timeout: TimeInterval) -> [StreamWire.Out] {
        var outs: [StreamWire.Out] = []
        let deadline = Date().addingTimeInterval(timeout)
        while outs.count < count, let out = next(timeout: deadline.timeIntervalSinceNow) { outs.append(out) }
        return outs
    }

    /// The next JPEG, skipping anything else, and when it came.
    func nextJPEG(timeout: TimeInterval) -> Date? {
        let deadline = Date().addingTimeInterval(timeout)
        while let out = next(timeout: deadline.timeIntervalSinceNow) { if case .jpeg = out { return Date() } }
        return nil
    }

    /// Reads and drops whatever comes for `seconds`.
    func drain(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while next(timeout: deadline.timeIntervalSinceNow) != nil {}
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}
