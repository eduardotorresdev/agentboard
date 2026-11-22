import AgentRuntime
import CoreMedia
import Foundation
import ImageIO

/// One card's stream (docs/streams.md) over a channel's descriptor: says the hello, hands each
/// server message to `onOut` on its reading thread, and sends input events framed the same way.
final class StreamClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    /// Set before `start`; called on the reading thread.
    var onOut: (@Sendable (StreamWire.Out) -> Void)?
    var onClose: (@Sendable () -> Void)?

    init(fd: Int32) { self.fd = fd }

    func start(token: String, card: UUID) {
        let hello = (try? JSONSerialization.data(withJSONObject: ["token": token, "card": card.uuidString])) ?? Data()
        write(hello + Data([0x0a]))
        Thread.detachNewThread { [self] in read() }
    }

    /// One input event (`{"type":"touch",...}`), in the header's units.
    func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        write(StreamWire.frame(data))
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func read() {
        var reader = StreamWire.Reader()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        reading: while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            reader.append(Data(buffer[0..<count]))
            do {
                while let message = try reader.next() {
                    if let out = StreamWire.decode(message) { onOut?(out) }
                }
            } catch {
                break reading
            }
        }
        close()
        onClose?()
    }

    private func write(_ data: Data) {
        lock.withLock {
            guard !closed else { return }
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let wrote = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    guard wrote > 0 else { return }
                    offset += wrote
                }
            }
        }
    }
}

/// Stream messages as pictures: H.264 units as sample buffers an `AVSampleBufferDisplayLayer`
/// shows at once, JPEG frames as images.
struct StreamDecoder {
    enum Picture {
        case header(StreamWire.Header)
        case sample(CMSampleBuffer)
        case image(CGImage)
    }

    private var format: CMVideoFormatDescription?
    private var waitingForKeyFrame = true

    /// Nil for what shows nothing: units before the first keyframe, parameter sets on their own.
    mutating func decode(_ out: StreamWire.Out) -> Picture? {
        switch out {
        case .header(let header):
            return .header(header)
        case .jpeg(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return .image(image)
        case .video(let unit):
            let key = StreamWire.isKeyFrame(unit)
            if key {
                // New parameter sets (a rotation) replace the format; a bare IDR keeps the last.
                if let next = StreamWire.formatDescription(fromConfig: unit) { format = next }
                waitingForKeyFrame = false
            }
            guard !waitingForKeyFrame, let format else { return nil }
            let picture = StreamWire.nalUnits(unit).filter { ![7, 8].contains(($0.first ?? 0) & 0x1f) }
            guard !picture.isEmpty else { return nil }
            let annexB = picture.reduce(Data()) { $0 + Data([0, 0, 0, 1]) + $1 }
            return StreamWire.sampleBuffer(annexB: annexB, format: format, keyFrame: key).map(Picture.sample)
        }
    }

    /// After the layer failed: nothing shows until the next keyframe.
    mutating func restart() { waitingForKeyFrame = true }
}

/// A value shared with callback threads.
final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}
