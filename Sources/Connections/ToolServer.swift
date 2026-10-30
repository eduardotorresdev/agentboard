import CryptoKit
import Darwin
import Foundation

/// Carries a `ToolCatalog` to agents over MCP's Streamable HTTP transport, on 127.0.0.1 only.
/// Each element gets its own bearer token, which is how a request says who is asking; a request
/// without a known token is refused. Answers are plain JSON. An agent's GET opens an event
/// stream, on which `notifyToolsChanged` tells it to list the tools again.
///
/// Given a `secret`, tokens are derived from it and the element's id, and `start` tries the port
/// it had before: an agent launched by an earlier run of the board (still running on the core)
/// then reaches the new one with the URL and token it was launched with.
///
/// A process replacing this one can carry on without refusing a single call: `drain` lets the
/// calls being answered finish, and `release` gives the listening socket and the idle
/// connections to pass on to it, for its `start(inheriting:)`. The event streams go with them:
/// the new server says the tools changed on each, as a newer build may serve other ones.
public final class ToolServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agentboard.tools")
    private let handle: @Sendable (Data, UUID) async -> Data?
    private var listener: DispatchSourceRead?
    private var listenerFD: Int32 = -1
    private var exchanges: [ObjectIdentifier: HTTPExchange] = [:]
    private var draining = false
    private var drained: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    private var callers: [String: UUID] = [:]
    private var tokens: [UUID: String] = [:]
    private let secret: SymmetricKey?
    private var keepAlive: DispatchSourceTimer?
    /// Each request (`<caller> <method>`) and stream opened, for a log. Set before `start`.
    public var onRequest: (@Sendable (String) -> Void)?
    /// A stream with nothing on it this long is sent a comment, or clients time it out.
    private static let keepAliveInterval = 25.0

    public static let path = "/mcp"

    /// What a server passes to the one replacing it.
    public struct Release: @unchecked Sendable {
        /// The listening socket.
        public let listener: Int32
        /// Idle keep-alive connections, each with what was read of its next request so far.
        public let connections: [(fd: Int32, pending: Data)]
        /// Event streams, past their response head.
        public let streams: [Int32]

        public init(listener: Int32, connections: [(fd: Int32, pending: Data)], streams: [Int32] = []) {
            self.listener = listener
            self.connections = connections
            self.streams = streams
        }
    }

    public init(catalog: ToolCatalog, secret: Data? = nil) {
        handle = { body, caller in await catalog.respond(to: body, caller: caller) }
        self.secret = secret.map { SymmetricKey(data: $0) }
    }

    /// Starts listening on `preferredPort`, or a free port when that one is taken, or carries on
    /// what an earlier server released. `ready` gets the endpoint URL, or nil if it couldn't
    /// start.
    public func start(preferredPort: UInt16? = nil, inheriting release: Release? = nil,
                      _ ready: @escaping @MainActor @Sendable (URL?) -> Void) {
        let url: URL? = queue.sync {
            let fd = release?.listener ?? Self.listen(port: preferredPort ?? 0) ?? (preferredPort != nil ? Self.listen(port: 0) : nil) ?? -1
            guard fd >= 0, let port = Self.port(of: fd) else { return nil }
            listenerFD = fd
            draining = false
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.resume()
            listener = source
            for connection in release?.connections ?? [] { open(connection.fd, pending: connection.pending) }
            for stream in release?.streams ?? [] { open(stream, pending: Data(), stream: true) }
            if release?.streams.isEmpty == false { sendToolsChanged() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.keepAliveInterval, repeating: Self.keepAliveInterval)
            timer.setEventHandler { [weak self] in
                self?.exchanges.values.filter(\.isStream).forEach { $0.send(Data(": keep-alive\n\n".utf8)) }
            }
            timer.resume()
            keepAlive = timer
            return URL(string: "http://127.0.0.1:\(port)\(Self.path)")
        }
        Task { @MainActor in ready(url) }
    }

    public func stop() {
        queue.sync {
            keepAlive?.cancel()
            keepAlive = nil
            listener?.cancel()
            listener = nil
            if listenerFD >= 0 { close(listenerFD) }
            listenerFD = -1
            exchanges.values.forEach { $0.cancel() }
            exchanges.removeAll()
            finishDraining()
        }
    }

    /// Stops taking connections and requests (they wait in the kernel), and returns once every
    /// request being answered has been, or after `timeout` seconds.
    public func drain(timeout: Double = 5) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                draining = true
                listener?.cancel()
                listener = nil
                exchanges.values.forEach { $0.pause() }
                drained.append(continuation)
                checkDrained()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finishDraining() }
            }
        }
    }

    /// After `drain`: the listening socket and the idle connections (duplicates, the caller's to
    /// own), for another process to carry on. Connections still busy are dropped.
    public func release() -> Release? {
        queue.sync {
            guard listenerFD >= 0 else { return nil }
            let listening = dup(listenerFD)
            keepAlive?.cancel()
            keepAlive = nil
            let streams = exchanges.values.filter(\.isStream).compactMap { $0.release()?.fd }
            let connections = exchanges.values.filter { !$0.isStream }.compactMap { $0.release() }
            exchanges.removeAll()
            return listening >= 0 ? Release(listener: listening, connections: connections, streams: streams) : nil
        }
    }

    /// Tells every agent with a stream open to list the tools again.
    public func notifyToolsChanged() {
        queue.async { [self] in sendToolsChanged() }
    }

    /// The token `element` authenticates with; the same one every time until revoked.
    public func token(for element: UUID) -> String {
        lock.withLock {
            if let token = tokens[element] { return token }
            let token: String
            if let secret {
                let code = HMAC<SHA256>.authenticationCode(for: Data(element.uuidString.utf8), using: secret)
                token = code.map { String(format: "%02x", $0) }.joined()
            } else {
                token = UUID().uuidString + UUID().uuidString
            }
            tokens[element] = token
            callers[token] = element
            return token
        }
    }

    public func revoke(_ element: UUID) {
        lock.withLock {
            guard let token = tokens.removeValue(forKey: element) else { return }
            callers[token] = nil
        }
    }

    fileprivate func caller(authorization: String?) -> UUID? {
        guard let authorization, authorization.lowercased().hasPrefix("bearer ") else { return nil }
        let token = authorization.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return lock.withLock { callers[token] }
    }

    fileprivate func respond(to body: Data, caller: UUID) async -> Data? {
        await handle(body, caller)
    }

    // MARK: On `queue`

    private func sendToolsChanged() {
        let event = Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n".utf8)
        exchanges.values.filter(\.isStream).forEach { $0.send(event) }
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            open(fd, pending: Data())
        }
    }

    private func open(_ fd: Int32, pending: Data, stream: Bool = false) {
        let exchange = HTTPExchange(fd: fd, pending: pending, server: self, queue: queue, stream: stream)
        let key = ObjectIdentifier(exchange)
        exchanges[key] = exchange
        exchange.onClose = { [weak self] in
            self?.exchanges[key] = nil
            self?.checkDrained()
        }
        exchange.onIdle = { [weak self] in self?.checkDrained() }
        exchange.start(paused: draining)
    }

    private func checkDrained() {
        guard draining, exchanges.values.allSatisfy({ !$0.isBusy }) else { return }
        finishDraining()
    }

    private func finishDraining() {
        let waiting = drained
        drained.removeAll()
        waiting.forEach { $0.resume() }
    }

    private static func listen(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func port(of fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return got == 0 ? UInt16(bigEndian: address.sin_port) : nil
    }
}

/// One TCP connection: HTTP/1.1 requests read one at a time, kept alive between them. Runs on
/// the server's queue.
private final class HTTPExchange: @unchecked Sendable {
    private let fd: Int32
    private let server: ToolServer
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var buffer: Data
    private var output = Data()
    /// Not reading requests (the server drains); `suspended` is whether the reader is.
    private var paused = false
    private var suspended = false
    private var closed = false
    private var closeAfterWrite = false
    /// A request is being answered, or its answer written.
    private(set) var isBusy = false
    /// An event stream: it gets no more requests, only events to write.
    private(set) var isStream: Bool
    var onClose: (() -> Void)?
    /// Called when an answer has been written while paused.
    var onIdle: (() -> Void)?
    private static let maximumHeader = 64 * 1024
    private static let maximumBody = 4 * 1024 * 1024

    init(fd: Int32, pending: Data, server: ToolServer, queue: DispatchQueue, stream: Bool) {
        self.fd = fd
        isStream = stream
        self.server = server
        self.queue = queue
        buffer = pending
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start(paused: Bool) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.setCancelHandler { [fd] in close(fd) }
        self.reader = reader
        reader.resume()
        if paused {
            pause()
        } else if !buffer.isEmpty {
            process(peerClosed: false)
        }
    }

    /// Stops reading requests; the one being answered still is.
    func pause() {
        guard !paused, !closed else { return }
        paused = true
        if !isBusy { suspendReader() }
    }

    /// The connection and what was read of its next request, unless a request is being answered
    /// (or, on a stream, an event is half written).
    func release() -> (fd: Int32, pending: Data)? {
        guard !closed else { return nil }
        let copy = isBusy || !output.isEmpty ? -1 : dup(fd)
        cancel()
        return copy >= 0 ? (copy, buffer) : nil
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        writer?.cancel()
        writer = nil
        if let reader {
            if suspended { reader.resume() }
            reader.cancel()
        }
        reader = nil
    }

    private func suspendReader() {
        guard !suspended, let reader else { return }
        suspended = true
        reader.suspend()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var peerClosed = false
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                peerClosed = true
                break
            }
        }
        if isStream {
            // Nothing more is expected on it; it ends when the agent goes.
            buffer.removeAll()
            if peerClosed { end() }
            return
        }
        if peerClosed, !isBusy, buffer.isEmpty { return end() }
        guard !isBusy else {
            // Answered once the current request is; a peer that left is noticed then.
            if peerClosed { suspendReader() }
            return
        }
        process(peerClosed: peerClosed)
    }

    private func end() {
        cancel()
        onClose?()
    }

    /// Handles the next whole request in the buffer, or waits for more.
    private func process(peerClosed: Bool) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maximumHeader { return reply(431, "Request Header Fields Too Large", close: true) }
            if peerClosed { end() }
            return
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard requestLine.count >= 2, length >= 0, length <= Self.maximumBody else {
            return reply(400, "Bad Request", close: true)
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else {
            if peerClosed { end() }
            return
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        let close = headers["connection"]?.lowercased() == "close" || peerClosed

        let method = String(requestLine[0])
        let path = requestLine[1].split(separator: "?").first.map(String.init) ?? ""
        guard path == ToolServer.path else { return reply(404, "Not Found", close: close) }
        guard let caller = server.caller(authorization: headers["authorization"]) else {
            return reply(401, "Unauthorized", close: close)
        }
        if method == "GET", headers["accept"]?.contains("text/event-stream") == true { return openStream(for: caller) }
        guard method == "POST" else { return reply(405, "Method Not Allowed", headers: ["Allow": "GET, POST"], close: close) }
        isBusy = true
        let server = self.server
        if let onRequest = server.onRequest {
            let name = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["method"] as? String ?? "?"
            onRequest("\(caller) \(name)")
        }
        Task { [weak self, queue] in
            let answer = await server.respond(to: body, caller: caller)
            queue.async { [weak self] in
                guard let self, !self.closed else { return }
                if let answer {
                    self.reply(200, "OK", headers: ["Content-Type": "application/json"], body: answer, close: close)
                } else {
                    self.reply(202, "Accepted", close: close)
                }
            }
        }
    }

    /// Answers with an event stream that stays open: the head now, events as they come.
    private func openStream(for caller: UUID) {
        isStream = true
        buffer.removeAll()
        server.onRequest?("\(caller) opened a stream")
        send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n".utf8))
    }

    /// On a stream: writes `bytes` after whatever is still being written.
    func send(_ bytes: Data) {
        guard !closed else { return }
        output.append(bytes)
        if writer == nil { flush() }
    }

    private func reply(_ status: Int, _ reason: String, headers: [String: String] = [:], body: Data = Data(), close: Bool) {
        isBusy = true
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        head += close ? "Connection: close\r\n" : "Connection: keep-alive\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        output = Data((head + "\r\n").utf8) + body
        closeAfterWrite = close
        flush()
    }

    private func flush() {
        while !output.isEmpty {
            let written = output.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                output.removeFirst(written)
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                guard writer == nil else { return }
                let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                writer.setEventHandler { [weak self] in self?.flush() }
                writer.resume()
                self.writer = writer
                return
            } else {
                return end()
            }
        }
        writer?.cancel()
        writer = nil
        if closeAfterWrite { return end() }
        if isStream { return }
        isBusy = false
        if paused {
            suspendReader()
            onIdle?()
        } else {
            if suspended {
                // Suspended while busy because the peer left: whatever it sent is in the buffer.
                suspended = false
                reader?.resume()
            }
            process(peerClosed: false)
        }
    }
}
