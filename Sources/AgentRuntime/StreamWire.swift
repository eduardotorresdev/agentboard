import CoreMedia
import Foundation

/// The bytes of a card stream (docs/streams.md): a hello line from the client, then
/// length-prefixed messages both ways. Pure, so the framing is tested on its own.
public enum StreamWire {
    /// Message types, the first byte of a server message's payload.
    public static let header: UInt8 = 0x48  // "H": JSON header
    public static let video: UInt8 = 0x56   // "V": one H.264 access unit, Annex B
    public static let jpeg: UInt8 = 0x4a    // "J": one JPEG frame
    /// Larger messages end the connection: a frame of a 4K screen fits well under it.
    public static let maxMessage = 16 << 20
    public static let maxHello = 4096

    /// What the client is sent.
    public enum Out: Equatable {
        case header(Header)
        case video(Data)
        case jpeg(Data)
    }

    public struct Header: Codable, Equatable {
        /// `h264` or `jpeg`.
        public var kind: String
        /// The size input events are in, in `units`; the video may have another (its SPS says).
        public var width: Double
        public var height: Double
        /// `points` (iOS, browsers) or `pixels` (Android).
        public var units: String

        public init(kind: String, width: Double, height: Double, units: String) {
            self.kind = kind
            self.width = width
            self.height = height
            self.units = units
        }
    }

    /// 4-byte big-endian length, then the payload.
    public static func frame(_ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }

    public static func encode(_ out: Out) -> Data {
        switch out {
        case .header(let header): frame(Data([Self.header]) + ((try? JSONEncoder().encode(header)) ?? Data()))
        case .video(let unit): frame(Data([video]) + unit)
        case .jpeg(let image): frame(Data([jpeg]) + image)
        }
    }

    public static func decode(_ payload: Data) -> Out? {
        guard let type = payload.first else { return nil }
        let body = payload.dropFirst()
        switch type {
        case header: return (try? JSONDecoder().decode(Header.self, from: Data(body))).map(Out.header)
        case video: return .video(Data(body))
        case jpeg: return .jpeg(Data(body))
        default: return nil
        }
    }

    /// Splits a byte stream into length-prefixed messages.
    public struct Reader {
        private var buffer = Data()
        public struct TooLarge: Error { public init() {} }

        public init() {}

        public mutating func append(_ data: Data) { buffer += data }

        /// The next whole message, nil while incomplete.
        public mutating func next() throws -> Data? {
            guard buffer.count >= 4 else { return nil }
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= StreamWire.maxMessage else { throw TooLarge() }
            guard buffer.count >= 4 + length else { return nil }
            let message = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            return message
        }

        /// A newline-terminated line (the hello), nil while incomplete.
        public mutating func line() throws -> Data? {
            guard let end = buffer.firstIndex(of: 0x0a) else {
                if buffer.count > StreamWire.maxHello { throw TooLarge() }
                return nil
            }
            let line = Data(buffer[buffer.startIndex..<end])
            buffer = Data(buffer[(end + 1)...])
            return line
        }
    }

    /// Whether an Annex B unit starts a picture a decoder can begin at: an IDR slice, or the
    /// parameter sets sent in front of one.
    public static func isKeyFrame(_ unit: Data) -> Bool {
        nalUnits(unit).contains { [5, 7].contains(($0.first ?? 0) & 0x1f) }
    }

    /// The card a hello asks for, or nil when it isn't one or its token isn't `token`.
    public static func card(inHello line: Data, token: String) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let given = object["token"] as? String, equal(Data(given.utf8), Data(token.utf8)),
              let card = (object["card"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return card
    }

    /// Constant time, so a wrong token says nothing of how close it was.
    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// An input event from the client, in the header's units.
    public enum Input: Equatable {
        case touch(phase: String, x: Double, y: Double)
        /// `dx`, `dy`: how far the content moves.
        case scroll(x: Double, y: Double, dx: Double, dy: Double)
        /// A key by HID usage (simulators) or by name (`Enter`, `a`: browsers take either kind
        /// of name Playwright knows).
        case key(usage: Int?, name: String?, down: Bool, characters: String?)
        case text(String)
        /// A device button (`home`, `lock`, ...), simulators only.
        case button(String)
    }

    public static func input(_ payload: Data) -> Input? {
        guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? { (event[key] as? NSNumber)?.doubleValue }
        switch event["type"] as? String {
        case "touch":
            guard let phase = event["phase"] as? String, ["down", "move", "up"].contains(phase), let x = number("x"), let y = number("y") else { return nil }
            return .touch(phase: phase, x: x, y: y)
        case "scroll":
            guard let x = number("x"), let y = number("y") else { return nil }
            return .scroll(x: x, y: y, dx: number("dx") ?? 0, dy: number("dy") ?? 0)
        case "key":
            let usage = (event["usage"] as? NSNumber)?.intValue, name = event["key"] as? String
            guard usage != nil || name != nil else { return nil }
            return .key(usage: usage, name: name, down: event["down"] as? Bool ?? true, characters: event["characters"] as? String)
        case "text":
            return (event["text"] as? String).map(Input.text)
        case "button":
            return (event["name"] as? String).map(Input.button)
        default:
            return nil
        }
    }

    // MARK: H.264

    /// The NAL units of an Annex B stream (each after a 00 00 01 or 00 00 00 01 start code).
    public static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 || (index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1) {
                let skip = bytes[index + 2] == 1 ? 3 : 4
                if let start { units.append(Data(bytes[start..<index])) }
                index += skip
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    public static func formatDescription(fromConfig config: Data) -> CMVideoFormatDescription? {
        let units = nalUnits(config)
        guard let sps = units.first(where: { ($0.first ?? 0) & 0x1f == 7 }), let pps = units.first(where: { ($0.first ?? 0) & 0x1f == 8 }) else { return nil }
        var format: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                        parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                                                                        formatDescriptionOut: &format)
            }
        }
        return format
    }

    /// Annex B to the length-prefixed form the decoder takes, shown as soon as it is enqueued.
    public static func sampleBuffer(annexB: Data, format: CMVideoFormatDescription, keyFrame: Bool) -> CMSampleBuffer? {
        var avcc = Data()
        for unit in nalUnits(annexB) { avcc += withUnsafeBytes(of: UInt32(unit.count).bigEndian) { Data($0) } + unit }
        guard !avcc.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
              let first = attachments.first else { return nil }
        first[kCMSampleAttachmentKey_DisplayImmediately] = true
        if !keyFrame { first[kCMSampleAttachmentKey_NotSync] = true }
        return sample
    }
}
