import Foundation

/// The bytes of a card stream (docs/streams.md): a hello line from the client, then
/// length-prefixed messages both ways. Pure, so the framing is tested on its own.
enum StreamWire {
    /// Message types, the first byte of a server message's payload.
    static let header: UInt8 = 0x48  // "H": JSON header
    static let video: UInt8 = 0x56   // "V": one H.264 access unit, Annex B
    static let jpeg: UInt8 = 0x4a    // "J": one JPEG frame
    /// Larger messages end the connection: a frame of a 4K screen fits well under it.
    static let maxMessage = 16 << 20
    static let maxHello = 4096

    /// What the client is sent.
    enum Out: Equatable {
        case header(Header)
        case video(Data)
        case jpeg(Data)
    }

    struct Header: Codable, Equatable {
        /// `h264` or `jpeg`.
        var kind: String
        /// The size input events are in, in `units`; the video may have another (its SPS says).
        var width: Double
        var height: Double
        /// `points` (iOS, browsers) or `pixels` (Android).
        var units: String
    }

    /// 4-byte big-endian length, then the payload.
    static func frame(_ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }

    static func encode(_ out: Out) -> Data {
        switch out {
        case .header(let header): frame(Data([Self.header]) + ((try? JSONEncoder().encode(header)) ?? Data()))
        case .video(let unit): frame(Data([video]) + unit)
        case .jpeg(let image): frame(Data([jpeg]) + image)
        }
    }

    static func decode(_ payload: Data) -> Out? {
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
    struct Reader {
        private var buffer = Data()
        struct TooLarge: Error {}

        mutating func append(_ data: Data) { buffer += data }

        /// The next whole message, nil while incomplete.
        mutating func next() throws -> Data? {
            guard buffer.count >= 4 else { return nil }
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= StreamWire.maxMessage else { throw TooLarge() }
            guard buffer.count >= 4 + length else { return nil }
            let message = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            return message
        }

        /// A newline-terminated line (the hello), nil while incomplete.
        mutating func line() throws -> Data? {
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
    static func isKeyFrame(_ unit: Data) -> Bool {
        ScrcpyStream.nalUnits(unit).contains { [5, 7].contains(($0.first ?? 0) & 0x1f) }
    }

    /// The card a hello asks for, or nil when it isn't one or its token isn't `token`.
    static func card(inHello line: Data, token: String) -> UUID? {
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
    enum Input: Equatable {
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

    static func input(_ payload: Data) -> Input? {
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
}

/// The connections watching each card, so a backend fans frames out without knowing them.
/// Thread-safe: frames arrive on video threads.
final class StreamTaps: @unchecked Sendable {
    typealias Sink = @Sendable (StreamWire.Out) -> Void
    private var sinks: [UUID: [UUID: Sink]] = [:]
    private var headers: [UUID: StreamWire.Header] = [:]
    private let lock = NSLock()

    /// Adds `sink` to `card`; the returned id removes it. The last header goes out at once.
    func add(_ card: UUID, _ sink: @escaping Sink) -> UUID {
        let id = UUID()
        let header = lock.withLock { () -> StreamWire.Header? in
            sinks[card, default: [:]][id] = sink
            return headers[card]
        }
        if let header { sink(.header(header)) }
        return id
    }

    /// True when it was the card's last one.
    @discardableResult
    func remove(_ card: UUID, _ id: UUID) -> Bool {
        lock.withLock {
            sinks[card]?[id] = nil
            if sinks[card]?.isEmpty == true { sinks[card] = nil }
            return sinks[card] == nil
        }
    }

    func watched(_ card: UUID) -> Bool { lock.withLock { sinks[card] != nil } }

    /// Forgets the card's header, so the next one goes out even if unchanged: a restarted
    /// source's clients learn to start over.
    func reset(_ card: UUID) { lock.withLock { headers[card] = nil } }

    /// Sends to every sink of `card`; a header is also kept for those added later, and only
    /// sent when it changed.
    func send(_ card: UUID, _ out: StreamWire.Out) {
        let targets = lock.withLock { () -> [Sink] in
            if case .header(let header) = out {
                guard headers[card] != header else { return [] }
                headers[card] = header
            }
            return sinks[card].map { Array($0.values) } ?? []
        }
        targets.forEach { $0(out) }
    }
}
