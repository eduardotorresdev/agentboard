import AgentRuntime
import CoreMedia
import UIKit
import VideoToolbox
import XCTest
@testable import AgentBoardPhone

final class StreamTests: XCTestCase {
    private let card = UUID()

    /// A fake server on the other end of a socket pair: checks the hello, sends a header and a
    /// JPEG, and hears an input event back, all framed as docs/streams.md says.
    func testTheClientSaysHelloReadsFramesAndSendsInput() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let server = pair[1]
        let client = StreamClient(fd: pair[0])
        let got = expectation(description: "header and frame")
        got.expectedFulfillmentCount = 2
        let outs = Locked<[StreamWire.Out]>([])
        client.onOut = { out in outs.mutate { $0.append(out) }; got.fulfill() }
        client.start(token: "secret", card: card)

        var reader = StreamWire.Reader()
        let hello = try readUntil(server, &reader) { try $0.line() }
        XCTAssertEqual(StreamWire.card(inHello: hello, token: "secret"), card)
        let header = StreamWire.Header(kind: "jpeg", width: 390, height: 844, units: "points")
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).jpegData(withCompressionQuality: 0.7) { _ in }
        send(server, StreamWire.encode(.header(header)) + StreamWire.encode(.jpeg(jpeg)))
        wait(for: [got], timeout: 5)
        XCTAssertEqual(outs.value, [.header(header), .jpeg(jpeg)])

        client.send(["type": "touch", "phase": "down", "x": 10, "y": 20])
        let event = try readUntil(server, &reader) { try $0.next() }
        XCTAssertEqual(StreamWire.input(event), .touch(phase: "down", x: 10, y: 20))

        let closed = expectation(description: "closed")
        client.onClose = { closed.fulfill() }
        Darwin.close(server)
        wait(for: [closed], timeout: 5)
    }

    func testAJPEGFrameDecodesToItsImage() {
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .jpegData(withCompressionQuality: 0.7) { _ in }
        var decoder = StreamDecoder()
        guard case .image(let image) = decoder.decode(.jpeg(jpeg)) else { return XCTFail("no image") }
        XCTAssertEqual([image.width, image.height], [32, 16])
    }

    /// Frames captured from a real H.264 encoder, sent as the server sends them (Annex B, the
    /// keyframe with its parameter sets in front): nothing shows before the keyframe, then every
    /// unit is a sample a decoder turns into a picture of the stream's size.
    func testCapturedH264ShowsFromTheFirstKeyFrame() throws {
        let units = try Self.encodedFrames(count: 3, width: 320, height: 240)
        XCTAssertTrue(StreamWire.isKeyFrame(units[0]))
        XCTAssertFalse(StreamWire.isKeyFrame(units[1]))
        var decoder = StreamDecoder()
        XCTAssertNil(decoder.decode(.video(units[1])), "a unit before any keyframe shows nothing")
        var samples: [CMSampleBuffer] = []
        for unit in units {
            guard case .sample(let sample) = decoder.decode(.video(unit)) else { return XCTFail("no sample") }
            samples.append(sample)
        }
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(samples[0]))
        let size = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual([size.width, size.height], [320, 240])
        XCTAssertEqual(try Self.decodedFrames(samples, format: format), 3)
    }

    func testElementsAndTicketsDecodeAsTheCoreSendsThem() throws {
        let elements = #"{"elements":{"_0":[{"id":"00000005-ABCD-4EF0-8A1B-000000000005","name":"Desktop","kind":"browser","detail":"desktop, 1280 × 720","worktree":"/work/tree","frame":[[5,6],[700,500]]},{"id":"00000006-ABCD-4EF0-8A1B-000000000006","name":"Files","kind":"filetree","worktree":"/work/tree","frame":[[0,0],[300,500]]}]}}"#
        guard case .elements(let list) = try JSONDecoder().decode(BoardUpdate.self, from: Data(elements.utf8)) else { return XCTFail() }
        XCTAssertEqual(list.map(\.streams), [true, false])
        XCTAssertEqual(list[0].frame, CGRect(x: 5, y: 6, width: 700, height: 500))
        let ticket = #"{"streamTicket":{"card":"00000005-ABCD-4EF0-8A1B-000000000005","port":50123,"token":"t"}}"#
        guard case .streamTicket(_, let port, let token) = try JSONDecoder().decode(BoardUpdate.self, from: Data(ticket.utf8)) else { return XCTFail() }
        XCTAssertEqual(port, 50123)
        XCTAssertEqual(token, "t")
        let none = #"{"streamTicket":{"card":"00000005-ABCD-4EF0-8A1B-000000000005"}}"#
        guard case .streamTicket(_, nil, nil) = try JSONDecoder().decode(BoardUpdate.self, from: Data(none.utf8)) else { return XCTFail() }
        XCTAssertEqual(String(data: BoardSay.streamTicket(list[0].id), encoding: .utf8), #"{"streamTicket":{"card":"00000005-ABCD-4EF0-8A1B-000000000005"}}"#)
    }

    func testASeededTokenIsOnlyTakenForALoopbackServer() {
        XCTAssertTrue(Account.allowsSeededToken(URL(string: "http://127.0.0.1:8787")!))
        XCTAssertTrue(Account.allowsSeededToken(URL(string: "http://localhost:8787")!))
        XCTAssertFalse(Account.allowsSeededToken(URL(string: "https://agentboard-account.agentboard-account-server.workers.dev")!))
        XCTAssertFalse(Account.allowsSeededToken(URL(string: "http://127.0.0.1.example.com")!))
    }

    /// Touches land in the stream's own space, the picture aspect-fit and centered: a 390×844
    /// screen shown in a 390×390 view is pillarboxed, and the bars take no input.
    func testTouchesMapIntoTheStreamsSpace() {
        let view = CGSize(width: 390, height: 390), space = CGSize(width: 390, height: 844)
        let scale = 390.0 / 844
        let left = (390 - 390 * scale) / 2
        let center = StreamSurfaceView.map(CGPoint(x: 195, y: 195), in: view, to: space)
        XCTAssertEqual(center?.x ?? -1, 195, accuracy: 0.001)
        XCTAssertEqual(center?.y ?? -1, 422, accuracy: 0.001)
        let corner = StreamSurfaceView.map(CGPoint(x: left, y: 0), in: view, to: space)
        XCTAssertEqual(corner?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(StreamSurfaceView.map(CGPoint(x: 10, y: 195), in: view, to: space), "the bar beside the picture")
        XCTAssertNil(StreamSurfaceView.map(CGPoint(x: 10, y: 10), in: view, to: .zero), "no header yet")
    }

    // MARK: Helpers

    private func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
    }

    private func readUntil(_ fd: Int32, _ reader: inout StreamWire.Reader, _ take: (inout StreamWire.Reader) throws -> Data?) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let got = try take(&reader) { return got }
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            reader.append(Data(buffer[0..<count]))
        }
    }

    /// Real-time H.264 of `count` changing frames, as Annex B units the way the server sends them.
    static func encodedFrames(count: Int, width: Int, height: Int) throws -> [Data] {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else { throw CocoaError(.featureUnsupported) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let units = Locked<[Data]>([])
        for index in 0..<count {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
            guard let pixels else { throw CocoaError(.featureUnsupported) }
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(40 * index), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, let unit = annexB(sample) else { return }
                units.mutate { $0.append(unit) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        guard units.value.count == count else { throw CocoaError(.featureUnsupported) }
        return units.value
    }

    /// A sample's length-prefixed units with start codes, parameter sets in front of a keyframe.
    private static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var out = Data()
        if key {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer { out += Data([0, 0, 0, 1]) + Data(bytes: pointer, count: size) }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return nil }
        let avcc = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= avcc.count {
            let size = avcc[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            out += Data([0, 0, 0, 1]) + avcc[offset + 4..<offset + 4 + size]
            offset += 4 + size
        }
        return out
    }

    /// How many of `samples` a real decoder turned into pictures.
    private static func decodedFrames(_ samples: [CMSampleBuffer], format: CMVideoFormatDescription) throws -> Int {
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
                                           outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else { throw CocoaError(.featureUnsupported) }
        let pictures = Locked(0)
        for sample in samples {
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, image != nil { pictures.mutate { $0 += 1 } }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        return pictures.value
    }
}
