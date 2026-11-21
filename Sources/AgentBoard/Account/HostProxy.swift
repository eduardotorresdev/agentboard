import AgentRuntime
import Darwin
import Foundation

/// How a page on this Mac reaches what a worktree's host serves on its own loopback
/// (`http://localhost:5173` on a browser card of a remote worktree is the host's port 5173).
///
/// An HTTP proxy on this Mac's loopback, which those cards' pages are opened with: a request to
/// a loopback address goes to that port on the host, through a channel of its own (see "The
/// channel" in docs/hosts.md); every other address is connected to from here, as without it.
/// WebKit doesn't reliably send `localhost` or 127.0.0.1 to a proxy, and always sends a name
/// under `.localhost`: the browser sidecar asks for loopback addresses under `alias(for:)`
/// instead (see `onHost` in browser-host.mjs), which is why the card's address reads
/// `builder.localhost:5173`.
/// The proxy's user name says which host and its password is `token`, so no other program on
/// this Mac can use it. Bytes are copied as they come, never a whole answer at once.
final class HostProxy: @unchecked Sendable {
    /// Opens a stream to `port` on `host`'s loopback; nil when it can't. It blocks.
    typealias Open = @Sendable (_ host: UUID, _ port: UInt16) -> Int32?

    /// Made anew at each launch.
    let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    /// The proxy's port on this Mac's loopback; 0 when it couldn't listen.
    private(set) var port: UInt16 = 0
    private let open: Open
    private let lock = NSLock()
    /// The ports opened for runner links, by "host:port" there.
    private var forwards: [String: Listener] = [:]
    private var listener: Listener?

    init(open: @escaping Open) {
        self.open = open
        // As the core's sockets do: SO_NOSIGPIPE can't be set on a stream whose other end is
        // already gone (a channel to a port nothing serves), and a write to it must only fail.
        signal(SIGPIPE, SIG_IGN)
        let token = token
        if let made = Self.listen({ Self.serve($0, token: token, open: open) }) {
            port = made.port
            listener = made
        }
    }

    deinit { ([listener].compactMap { $0 } + forwards.values).forEach { $0.stop(waiting: false) } }

    /// What a page's context is opened with (Playwright's `proxy`) to browse as on `host`.
    func settings(for host: UUID) -> [String: String] {
        ["server": "http://127.0.0.1:\(port)", "username": host.uuidString, "password": token]
    }

    /// The name pages of a worktree on the host called `name` use for its loopback: the host's
    /// name as a label under `.localhost`, which every server treats as localhost.
    static func alias(for name: String) -> String {
        let label = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let trimmed = String(label).split(separator: "-").joined(separator: "-")
        return (trimmed.isEmpty ? "host" : String(trimmed.prefix(63))) + ".localhost"
    }

    /// A port on this Mac's loopback that is `port` on `host`'s, for a program that can't be
    /// given the proxy (the system browser, opening a runner's link). Any program on this Mac
    /// can connect to it until `keepForwards` closes it.
    func forward(_ port: UInt16, on host: UUID) -> UInt16? {
        lock.withLock {
            let key = "\(host.uuidString):\(port)"
            if let local = forwards[key] { return local.port }
            let open = open
            guard let made = Self.listen({ client in
                defer { close(client) }
                guard let upstream = open(host, port) else { return }
                Self.pipe(client, upstream)
                close(upstream)
            }) else { return nil }
            forwards[key] = made
            return made.port
        }
    }

    /// Closes the ports forwarded to `host` other than `ports` there: what its runners still
    /// serve in the worktree shown. Connections already made carry on to their end.
    func keepForwards(_ ports: Set<UInt16>, on host: UUID) {
        lock.withLock {
            for (key, forward) in forwards where key.hasPrefix(host.uuidString + ":") && !ports.contains(UInt16(key.dropFirst(37)) ?? 0) {
                forward.stop()
                forwards[key] = nil
            }
        }
    }

    /// `address` (a runner's `http://localhost:3000/…`) as it opens on this Mac for a worktree
    /// on `host`: the same address on a forwarded port. Nil when it isn't a loopback address.
    func forwarded(_ address: String, on host: UUID) -> URL? {
        guard var components = URLComponents(string: address), let name = components.host, Self.isLoopback(name),
              let local = forward(UInt16(clamping: components.port ?? 80), on: host) else { return nil }
        components.host = "127.0.0.1"
        components.port = Int(local)
        return components.url
    }

    // MARK: The proxy

    /// One connection from a page: requests in plain HTTP one after another, each sent on to
    /// where it is addressed, or one CONNECT, tunnelled.
    private static func serve(_ client: Int32, token: String, open: @escaping Open) {
        var pending = Data()
        var lane: Lane?
        defer {
            lane?.retire()
            close(client)
        }
        while let head = readHead(client, &pending) {
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count == 3 else { return reply(client, "400 Bad Request") }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let host = authorized(headers["proxy-authorization"], token: token) else {
                return reply(client, "407 Proxy Authentication Required", extra: "Proxy-Authenticate: Basic realm=\"board\"\r\n")
            }
            let connect = { (name: String, port: UInt16) -> Int32? in
                let fd = isLoopback(name) ? open(host, port) : dial(name, port)
                // A channel the host already ended must fail a write, not end the app.
                if let fd { quiet(fd) }
                return fd
            }

            if first[0] == "CONNECT" {
                lane?.retire()
                lane = nil
                guard let target = authority(first[1], defaultPort: 443), let upstream = connect(target.host, target.port) else {
                    return reply(client, "502 Bad Gateway")
                }
                defer { close(upstream) }
                guard writeAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: client), writeAll(pending, to: upstream) else { return }
                return pipe(client, upstream)
            }

            // `GET http://localhost:5173/path HTTP/1.1`: the server gets `GET /path HTTP/1.1`.
            // WebKit opens a web socket the same way, as `GET ws://…` with `Upgrade`.
            let uri = first[1]
            guard let scheme = ["http://", "ws://"].first(where: { uri.lowercased().hasPrefix($0) }) else { return reply(client, "400 Bad Request") }
            let rest = uri.dropFirst(scheme.count)
            let pathStart = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
            guard let target = authority(rest[..<pathStart], defaultPort: 80) else { return reply(client, "400 Bad Request") }
            let path = rest[pathStart...]
            let name = "\(target.host):\(target.port)"
            let fresh = lane?.target != name
            if fresh {
                // The page's connection moved on to another server: so does its upstream.
                lane?.retire()
                lane = nil
                guard let upstream = connect(target.host, target.port) else { return reply(client, "502 Bad Gateway") }
                lane = Lane(target: name, fd: upstream, client: client)
            }
            guard let upstream = lane?.fd else { return }
            // Where a body ends is only followed by its length: after any other, the connection ends.
            let opaque = headers["upgrade"] != nil || headers["transfer-encoding"] != nil
            let closes = headers["transfer-encoding"] != nil && headers["upgrade"] == nil
            // The proxy's own headers stop here: the password never reaches a server.
            let kept = lines.filter { line in
                let name = line.prefix { $0 != ":" }.lowercased()
                return !line.isEmpty && name != "proxy-authorization" && name != "proxy-connection" && !(closes && name == "connection")
            }
            let sent = (["\(first[0]) \(path.hasPrefix("/") ? "" : "/")\(path) \(first[2])"] + kept + (closes ? ["Connection: close"] : []))
                .joined(separator: "\r\n") + "\r\n\r\n"
            guard writeAll(Data(sent.utf8), to: upstream) else {
                // A new upstream that is already gone: the port serves nothing (see `Lane`).
                lane?.retire()
                lane = nil
                return fresh ? reply(client, "502 Bad Gateway") : ()
            }
            if opaque {
                guard writeAll(pending, to: upstream) else { return }
                copy(from: client, to: upstream)
                return
            }
            var body = Int(headers["content-length"] ?? "") ?? 0
            let buffered = pending.prefix(body)
            guard writeAll(buffered, to: upstream) else { return }
            pending = Data(pending.dropFirst(buffered.count))
            body -= buffered.count
            guard copy(from: client, to: upstream, count: body) else { return }
        }
    }

    /// One upstream of a page's connection, and the thread copying its answers back.
    private final class Lane: @unchecked Sendable {
        let target: String
        let fd: Int32
        private let lock = NSLock()
        private var retired = false
        private let done = DispatchSemaphore(value: 0)

        init(target: String, fd: Int32, client: Int32) {
            self.target = target
            self.fd = fd
            Thread.detachNewThread { [self] in
                // A channel opens before the host knows whether the port answers: one that ends
                // without a byte is a port nothing serves there, which the page is told.
                var first = [UInt8](repeating: 0, count: 64 * 1024)
                var got = read(fd, &first, first.count)
                while got < 0 && errno == EINTR { got = read(fd, &first, first.count) }
                let answered = got > 0
                if answered, HostProxy.writeAll(Data(first[..<got]), to: client) { HostProxy.copy(from: fd, to: client) }
                // The server ended it: so ends the page's connection, which was waiting on it.
                if !lock.withLock({ retired }) {
                    if !answered { HostProxy.reply(client, "502 Bad Gateway") }
                    shutdown(client, SHUT_RDWR)
                }
                done.signal()
            }
        }

        /// Ends the upstream and waits for its thread, so nothing writes to the page after this.
        func retire() {
            lock.withLock { retired = true }
            shutdown(fd, SHUT_RDWR)
            done.wait()
            close(fd)
        }
    }

    /// The host a request is for, when it presents the token (`Basic <host id>:<token>`).
    private static func authorized(_ header: String?, token: String) -> UUID? {
        guard let header, header.lowercased().hasPrefix("basic "),
              let data = Data(base64Encoded: header.dropFirst(6).trimmingCharacters(in: .whitespaces)) else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[1] == token else { return nil }
        return UUID(uuidString: String(parts[0]))
    }

    /// `name:port`, `[::1]:port` or either without a port, as a host and a port.
    static func authority(_ text: Substring, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        let text = text.split(separator: "@", omittingEmptySubsequences: false).last ?? text
        let name: Substring, rest: Substring
        if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
            name = text[text.index(after: text.startIndex)..<end]
            rest = text[text.index(after: end)...]
        } else {
            name = text.prefix { $0 != ":" }
            rest = text[name.endIndex...]
        }
        guard !name.isEmpty, rest.isEmpty || rest.hasPrefix(":") else { return nil }
        guard let port = rest.isEmpty ? defaultPort : UInt16(rest.dropFirst()) else { return nil }
        return (String(name), port)
    }

    /// Whether `name` is the machine itself: `localhost` and names under it, 127.0.0.0/8,
    /// 0.0.0.0 and ::1. Only real addresses count: `127.example.com` is a name like any other.
    static func isLoopback(_ name: String) -> Bool {
        let name = name.lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") || name == "::1" { return true }
        var address = in_addr()
        guard inet_pton(AF_INET, name, &address) == 1 else { return false }
        return address.s_addr == 0 || UInt32(bigEndian: address.s_addr) >> 24 == 127
    }

    // MARK: Sockets

    /// Listens on a port of this Mac's loopback the system picks, never on another interface,
    /// and hands each connection to `accepted` on a thread of its own.
    /// A port being listened on, until `stop`.
    private final class Listener: @unchecked Sendable {
        let port: UInt16
        private let lock = NSLock()
        private var stopped = false
        fileprivate let ended = DispatchSemaphore(value: 0)

        init(port: UInt16) { self.port = port }

        var isStopped: Bool { lock.withLock { stopped } }

        /// Stops listening; `waiting`, returns once the port is closed.
        func stop(waiting: Bool = true) {
            lock.withLock { stopped = true }
            if waiting { _ = ended.wait(timeout: .now() + 2) }
        }
    }

    private static func listen(_ accepted: @escaping @Sendable (Int32) -> Void) -> Listener? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && Darwin.listen(fd, 64) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            close(fd)
            return nil
        }
        let listener = Listener(port: UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread {
            // The thread that accepts closes the port: closed from elsewhere, it would stay open
            // for as long as `accept` waits.
            while !listener.isStopped {
                var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&waiting, 1, 100) > 0 else { continue }
                let client = accept(fd, nil, nil)
                if client < 0 && errno == EINTR { continue }
                guard client >= 0 else { break }
                quiet(client)
                Thread.detachNewThread { accepted(client) }
            }
            close(fd)
            listener.ended.signal()
        }
        return listener
    }

    /// A write to a connection the other end closed fails; it doesn't end the app.
    private static func quiet(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to `name` from this Mac.
    private static func dial(_ name: String, _ port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, String(port), &hints, &found) == 0 else { return nil }
        defer { freeaddrinfo(found) }
        var next = found
        while let info = next?.pointee {
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 {
                    quiet(fd)
                    return fd
                }
                close(fd)
            }
            next = info.ai_next
        }
        return nil
    }

    /// Copies each way until either side ends, then ends both. The caller closes them.
    static func pipe(_ a: Int32, _ b: Int32) {
        quiet(a)
        quiet(b)
        let back = DispatchSemaphore(value: 0)
        let end = {
            shutdown(a, SHUT_RDWR)
            shutdown(b, SHUT_RDWR)
        }
        Thread.detachNewThread {
            copy(from: b, to: a)
            end()
            back.signal()
        }
        copy(from: a, to: b)
        end()
        back.wait()
    }

    /// Copies `count` bytes, or until the source ends when nil, 64 KiB at most at a time; false
    /// when either side failed first.
    @discardableResult
    private static func copy(from: Int32, to: Int32, count: Int? = nil) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var left = count ?? .max
        while left > 0 {
            let got = read(from, &buffer, min(buffer.count, left))
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { return count == nil }
            guard writeAll(Data(buffer[..<got]), to: to) else { return false }
            left -= got
        }
        return true
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    /// Reads up to the blank line that ends a request's head; what came after it stays in
    /// `pending`. Nil when the connection ended, or the head passed 64 KiB.
    private static func readHead(_ fd: Int32, _ pending: inout Data) -> String? {
        let end = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let range = pending.range(of: end) {
                let head = String(decoding: pending[pending.startIndex..<range.lowerBound], as: UTF8.self)
                pending = Data(pending[range.upperBound...])
                return head
            }
            guard pending.count < 64 * 1024 else { return nil }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer[..<count])
        }
    }

    private static func reply(_ fd: Int32, _ status: String, extra: String = "") {
        _ = writeAll(Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: fd)
    }
}

extension HostProxy {
    /// The proxy the app's browser cards use: each connection to a host's loopback is a channel
    /// of its own to that host of `account`, carrying `tcp:<port>`.
    @MainActor convenience init(account: AccountStore) {
        self.init(open: Self.opener(account: account))
    }

    /// Opens a channel to a port on a host of `account`. Never call it on the main thread.
    @MainActor static func opener(account: AccountStore) -> Open {
        { [weak account] host, port in
            // Read at each connection: the token and the host's key and presence change.
            let target = DispatchQueue.main.sync { MainActor.assumeIsolated { account?.channel(to: host) } }
            return target.flatMap {
                HostChannel.open(server: $0.server, token: $0.token, host: host, hostKey: $0.key, board: $0.board, carrying: .tcp(port: port),
                                 addresses: $0.addresses).channel
            }
        }
    }
}
