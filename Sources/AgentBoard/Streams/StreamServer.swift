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
}

/// Serves cards as live video on this Mac's loopback, one TCP connection per card
/// (docs/streams.md). A remote board reaches it through a channel's `tcp:<port>`; the port and
/// the token every connection must open with are in `streams.json` in the data folder.
@MainActor
final class StreamServer {
    let token: String
    private(set) var port: UInt16 = 0
    var sources: [StreamSource]
    private let listener: NWListener
    private let advertised: URL?
    private let queue = DispatchQueue(label: "agentboard.streams")

    /// `advertise`: the file the port and token are written to (nil: none).
    init(sources: [StreamSource], advertise: URL?) throws {
        self.sources = sources
        advertised = advertise
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw POSIXError(.EIO) }
        token = Data(bytes).base64EncodedString()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Listens and advertises; returns the port.
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
                        return StreamConnection.Found(stop: stop, input: { event in Task { @MainActor in source.input(card, event) } })
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
        if let advertised { try Self.advertise(port: port, token: token, at: advertised) }
        return port
    }

    func stop() {
        listener.cancel()
        if let advertised { try? FileManager.default.removeItem(at: advertised) }
    }

    /// `{port, token}`, readable by this user only: whoever has the token can drive the cards.
    nonisolated static func advertise(port: UInt16, token: String, at url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["port": Int(port), "token": token])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw POSIXError(.EACCES)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    /// The app's server, kept for its lifetime.
    private static var running: StreamServer?

    /// Starts the app's server on a free port, advertised in the data folder.
    static func launch(sources: [StreamSource]) {
        guard let server = try? StreamServer(sources: sources, advertise: defaultFile) else { return }
        running = server
        Task {
            do { try await server.start() } catch { NSLog("AgentBoard: card streams didn't start: \(error.localizedDescription)") }
        }
    }

    nonisolated static var defaultFile: URL { DataFolder.url.appendingPathComponent("streams.json") }
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
    }
    var find: (@Sendable (UUID, @escaping StreamTaps.Sink) async -> Found?)?
    private let connection: NWConnection
    private let token: String
    private var reader = StreamWire.Reader()
    private var card: UUID?
    private var found: Found?
    private var ended = false
    private var pending = 0
    private let lock = NSLock()
    /// Past this many bytes not yet sent, JPEG frames are dropped (the next one replaces them).
    private static let backlog = 1 << 20

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
        let drop = lock.withLock { () -> Bool in
            if case .jpeg = out, pending > Self.backlog { return true }
            pending += data.count
            return false
        }
        // shortcut: H.264 units are never dropped (a gap breaks decoding until the next keyframe); a slow client lags instead. Upgrade: drop to the next keyframe and ask for one.
        guard !drop else { return }
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
