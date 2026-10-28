import Foundation
import Network

/// Carries a `ToolCatalog` to agents over MCP's Streamable HTTP transport, on 127.0.0.1 only.
/// Each element gets its own bearer token, which is how a request says who is asking; a request
/// without a known token is refused. Answers are plain JSON (no event streams: the tools never
/// push anything).
public final class ToolServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agentboard.tools")
    private let handle: @Sendable (Data, UUID) async -> Data?
    private var listener: NWListener?
    private let lock = NSLock()
    private var callers: [String: UUID] = [:]
    private var tokens: [UUID: String] = [:]

    public static let path = "/mcp"

    @MainActor
    public init(catalog: ToolCatalog) {
        handle = { body, caller in await catalog.respond(to: body, caller: caller) }
    }

    /// Starts listening on a free port. `ready` gets the endpoint URL, or nil if it couldn't start.
    public func start(_ ready: @escaping @MainActor @Sendable (URL?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            Task { @MainActor in ready(nil) }
            return
        }
        var reported = false
        listener.stateUpdateHandler = { [weak listener] state in
            let url: URL?
            switch state {
            case .ready: url = listener?.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)\(Self.path)") }
            case .failed: url = nil
            default: return
            }
            guard !reported else { return }
            reported = true
            Task { @MainActor in ready(url) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            HTTPExchange(connection: connection, server: self).start(on: self.queue)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The token `element` authenticates with; the same one every time until revoked.
    public func token(for element: UUID) -> String {
        lock.withLock {
            if let token = tokens[element] { return token }
            let token = UUID().uuidString + UUID().uuidString
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
}

/// One TCP connection: HTTP/1.1 requests read one at a time, kept alive between them.
private final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let server: ToolServer
    private var queue: DispatchQueue?
    private var buffer = Data()
    private static let maximumHeader = 64 * 1024
    private static let maximumBody = 4 * 1024 * 1024

    init(connection: NWConnection, server: ToolServer) {
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        self.queue = queue
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if error != nil || (complete && buffer.isEmpty) { return connection.cancel() }
            process(peerClosed: complete)
        }
    }

    /// Handles the next whole request in the buffer, or reads more.
    private func process(peerClosed: Bool) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maximumHeader { return reply(431, "Request Header Fields Too Large", close: true) }
            return peerClosed ? connection.cancel() : receive()
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
            return peerClosed ? connection.cancel() : receive()
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
        guard method == "POST" else { return reply(405, "Method Not Allowed", headers: ["Allow": "POST"], close: close) }
        Task { [self] in
            let answer = await server.respond(to: body, caller: caller)
            queue?.async { [self] in
                if let answer {
                    reply(200, "OK", headers: ["Content-Type": "application/json"], body: answer, close: close)
                } else {
                    reply(202, "Accepted", close: close)
                }
            }
        }
    }

    private func reply(_ status: Int, _ reason: String, headers: [String: String] = [:], body: Data = Data(), close: Bool) {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        head += close ? "Connection: close\r\n" : "Connection: keep-alive\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        let data = Data((head + "\r\n").utf8) + body
        connection.send(content: data, completion: .contentProcessed { [self] _ in
            if close { connection.cancel() } else { process(peerClosed: false) }
        })
    }
}
