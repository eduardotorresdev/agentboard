import AgentRuntime
import Foundation
import Network

/// Something whose cards can be streamed: simulators, browsers.
@MainActor
protocol StreamSource: AnyObject {
    /// Starts sending `card`'s frames to `sink`; nil when the card isn't this source's. Calling
    /// the result stops it.
    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)?
    func input(_ card: UUID, _ event: StreamWire.Input)
    /// A client dropped frames to catch up and waits for a keyframe.
    func requestKeyFrame(_ card: UUID)
}

/// Serves cards as live video on this Mac's loopback, one TCP connection per card
/// (docs/streams.md). A remote board reaches it through a channel's `tcp:<port>`, after asking
/// the core for the port and the token every connection must open with (`streamTicket`).
@MainActor
final class StreamServer {
    let token: String
    private(set) var port: UInt16 = 0
    var sources: [StreamSource]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agentboard.streams")

    init(sources: [StreamSource]) throws {
        self.sources = sources
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw POSIXError(.EIO) }
        token = Data(bytes).base64EncodedString()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Listens; returns the port.
    @discardableResult
    func start() async throws -> UInt16 {
        let token = token
        listener.newConnectionHandler = { [weak self] connection in
            let stream = StreamConnection(connection, token: token)
            stream.find = { [weak self] card, sink in
                await MainActor.run { () -> StreamConnection.Found? in
                    guard let self else { return nil }
                    for source in self.sources {
                        guard let stop = source.stream(card, to: sink) else { continue }
                        // Only the source that streams the card gets its input.
                        return StreamConnection.Found(stop: stop, input: { event in Task { @MainActor in source.input(card, event) } },
                                                      keyFrame: { Task { @MainActor in source.requestKeyFrame(card) } })
                    }
                    return nil
                }
            }
            stream.start(on: self?.queue ?? .global())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready: if once.take() { continuation.resume(returning: listener?.port?.rawValue ?? 0) }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.port = port
        return port
    }

    func stop() { listener.cancel() }

    /// The app's server, kept for its lifetime.
    private static var running: StreamServer?

    /// Starts the app's server on a free port and tells `agents`' core how to reach it. The
    /// token stays in memory: it leaves only in the core's answer to a board's `streamTicket`.
    static func launch(sources: [StreamSource], agents: AgentStore) {
        guard let server = try? StreamServer(sources: sources) else { return }
        running = server
        Task {
            do {
                let port = try await server.start()
                agents.servedStreams = (Int(port), server.token)
            } catch {
                NSLog("AgentBoard: card streams didn't start: \(error.localizedDescription)")
            }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()
    func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
}

/// One client: the hello, then frames out and input in.
private final class StreamConnection: @unchecked Sendable {
    struct Found: @unchecked Sendable {
        let stop: () -> Void
        let input: @Sendable (StreamWire.Input) -> Void
        let keyFrame: @Sendable () -> Void
    }
    var find: (@Sendable (UUID, @escaping StreamTaps.Sink) async -> Found?)?
    private let connection: NWConnection
    private let token: String
    private var reader = StreamWire.Reader()
    private var card: UUID?
    private var found: Found?
    private var ended = false
    private var pending = 0
    /// Frames are being dropped until a keyframe, after the client fell behind.
    private var skipping = false
    private let lock = NSLock()
    /// Past this many bytes not yet sent, frames are dropped: JPEG ones until the backlog
    /// clears, H.264 ones until the next keyframe (asked for at once), so a slow client catches
    /// up instead of lagging.
    static let backlog = 1 << 20

    init(_ connection: NWConnection, token: String) {
        self.connection = connection
        self.token = token
    }

    func start(on queue: DispatchQueue) {
        // Holds the connection until it ends, which drops the handler.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: self.end()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.reader.append(data) }
            do {
                try self.consume()
            } catch {
                return self.connection.cancel()
            }
            if complete || error != nil { return self.connection.cancel() }
            if self.card != nil || self.hello == nil { self.receive() }
        }
    }

    private var hello: Task<Void, Never>?

    private func consume() throws {
        if card == nil {
            // Nothing past the hello is read until it is accepted: no input before the token.
            guard hello == nil, let line = try reader.line() else { return }
            guard let card = StreamWire.card(inHello: line, token: token) else { throw StreamWire.Reader.TooLarge() }
            hello = Task { [weak self] in
                guard let self, let find = self.find else { return }
                guard let found = await find(card, { [weak self] out in self?.send(out) }) else { return self.connection.cancel() }
                let ended = self.lock.withLock { () -> Bool in
                    if !self.ended { self.found = found }
                    return self.ended
                }
                if ended { return await MainActor.run { found.stop() } }
                // Back on the connection's queue: read what followed the hello, then the rest.
                self.connection.queue?.async {
                    self.card = card
                    try? self.consume()
                    self.receive()
                }
            }
            return
        }
        while let message = try reader.next() {
            if let event = StreamWire.input(message) { lock.withLock { found }?.input(event) }
        }
    }

    private func send(_ out: StreamWire.Out) {
        let data = StreamWire.encode(out)
        enum Verdict { case send, drop, dropAndAsk }
        let verdict = lock.withLock { () -> Verdict in
            switch out {
            case .header: break
            case .jpeg: if pending > Self.backlog { return .drop }
            case .video(let unit):
                if skipping {
                    // A gap breaks decoding until a keyframe: resume only at one.
                    let key = StreamWire.isKeyFrame(unit)
                    // A keyframe that comes while still behind is dropped too: ask for the next.
                    guard pending <= Self.backlog, key else { return key ? .dropAndAsk : .drop }
                    skipping = false
                } else if pending > Self.backlog {
                    skipping = true
                    return .dropAndAsk
                }
            }
            pending += data.count
            return .send
        }
        if verdict == .dropAndAsk { lock.withLock { found }?.keyFrame() }
        guard verdict == .send else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.pending -= data.count }
            if error != nil { self.connection.cancel() }
        })
    }

    private func end() {
        connection.stateUpdateHandler = nil
        let found = lock.withLock { () -> Found? in
            ended = true
            defer { self.found = nil }
            return self.found
        }
        guard let found else { return }
        Task { @MainActor in found.stop() }
    }
}
