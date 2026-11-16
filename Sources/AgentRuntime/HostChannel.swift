import CryptoKit
import Darwin
import Foundation

/// A board's end of a channel to another host's core, made straight to the host or relayed by
/// the account server, and sealed end to end either way (see "The channel" in docs/hosts.md). What comes out is a descriptor carrying the
/// core's own frame stream, which `CoreClient.open(on:)` reads like its socket.
public enum HostChannel {
    static let info = Data("agentboard channel v1".utf8)
    /// Per message; the server refuses messages over 1 MiB.
    static let chunk = 64 * 1024

    /// What a channel carries: the host's core, a port on the host's loopback, or the host's
    /// list of boards (see "Board identity" in docs/hosts.md).
    public enum Carrying: Sendable {
        case core, tcp(port: UInt16), boards

        /// What a trusted board says after the host's verdict.
        var text: String {
            switch self {
            case .core: "core"
            case .tcp(let port): "tcp:\(port)"
            case .boards: "boards"
            }
        }
    }

    /// Who opens the channel: this board's own key, which the host decides by, and what the
    /// computer calls itself (shown beside the key's fingerprint, never decided by).
    public struct Board: Sendable {
        public let key: Curve25519.Signing.PrivateKey
        public let name: String

        public init(key: Curve25519.Signing.PrivateKey, name: String) {
            self.key = key
            self.name = name
        }
    }

    /// How opening a channel went.
    public enum Opened: Sendable, Equatable {
        /// A descriptor carrying what was asked for.
        case channel(Int32)
        /// The host answered, and doesn't trust this board yet; it trusts `trusted` boards.
        case pending(trusted: Int)
        /// Offline, not who its key says, or nothing answered.
        case failed

        public var channel: Int32? { if case .channel(let fd) = self { fd } else { nil } }
    }

    static let boardInfo = Data("agentboard board v1".utf8)

    /// A key as people compare it: the first 10 bytes of the SHA-256 of its 32 bytes, lowercase
    /// hex in five groups of four.
    public static func fingerprint(of key: Data) -> String {
        let hex = SHA256.hash(data: key).prefix(10).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { String(hex.dropFirst($0).prefix(4)) }.joined(separator: " ")
    }

    /// What a board's proof signs: this channel's two ephemeral keys and the host it is for.
    static func signed(boardEphemeral: Data, hostEphemeral: Data, hostIdentity: Data) -> Data {
        boardInfo + boardEphemeral + hostEphemeral + hostIdentity
    }

    /// A board's proof: its key, its signature, and its name cut to 64 bytes of whole characters.
    static func proof(_ board: Board, boardEphemeral: Data, hostEphemeral: Data, hostIdentity: Data) -> Data? {
        guard let signature = try? board.key.signature(for: signed(boardEphemeral: boardEphemeral, hostEphemeral: hostEphemeral, hostIdentity: hostIdentity)) else { return nil }
        var name = board.name
        while name.utf8.count > 64 { name.removeLast() }
        return board.key.publicKey.rawRepresentation + signature + Data(name.utf8)
    }

    /// The host's verdict as it says it; nil for anything else.
    static func verdict(_ text: Data) -> Opened? {
        let words = String(decoding: text, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        if words == ["trusted"] { return .channel(-1) }
        if words.count == 2, words[0] == "pending", let trusted = Int(words[1]), trusted >= 0 { return .pending(trusted: trusted) }
        return nil
    }

    /// How a channel reached the host.
    public enum Path: Sendable { case direct, relay }

    /// Opens a channel to `host`, whose identity key is `hostKey` (the `public_key` it
    /// registered), as `board`, carrying `carrying`. With `addresses` (the ones the host
    /// registered) it first tries the host itself ("The direct path" in docs/hosts.md), and the
    /// relay when that doesn't work; `took` hears which. Blocks until the host proved who it is
    /// and said whether it trusts this board, or `timeout`: call it off the main thread.
    public static func open(server: URL, token: String, host: UUID, hostKey: Data, board: Board, carrying: Carrying = .core,
                            addresses: [String] = [], timeout: Double = 15, took: ((Path) -> Void)? = nil) -> Opened {
        guard let identity = try? Curve25519.Signing.PublicKey(rawRepresentation: hostKey) else { return .failed }
        let kind = Data(carrying.text.utf8)

        // A host that couldn't be reached directly a moment ago isn't asked again for every
        // channel (a page opens many): each try costs a ticket and the wait on its addresses.
        if !addresses.isEmpty, !unreachable.recently(host), let ticket = ticket(server: server, token: token, host: host) {
          if let fd = reach(addresses) {
            let line = direct(fd)
            // The host gives a direct connection 5 seconds to say all of this.
            let opened = admit(line, hostKey: hostKey, identity: identity, board: board, ticket: ticket, kind: kind, timeout: min(timeout, 5))
            if opened != .failed {
                took?(.direct)
                return opened
            }
            line.dispose()
          }
          unreachable.note(host)
        }

        guard var components = URLComponents(url: server.appendingPathComponent("v1/hosts/\(host.uuidString)/connect"),
                                             resolvingAgainstBaseURL: false) else { return .failed }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        let line = Line(send: { send($0, on: task, timeout: $1) }, receive: { receive(on: task, timeout: $0) },
                        close: { task.cancel(with: .goingAway, reason: nil) }, dispose: {})
        let opened = admit(line, hostKey: hostKey, identity: identity, board: board, ticket: nil, kind: kind, timeout: timeout)
        if opened != .failed { took?(.relay) }
        return opened
    }

    /// The handshake, the board's proof (after the ticket, on the direct path), and what the
    /// host makes of it: a channel carrying `kind` when it trusts the board. The line is closed
    /// unless a channel comes out of it.
    private static func admit(_ line: Line, hostKey: Data, identity: Curve25519.Signing.PublicKey, board: Board, ticket: Data?,
                              kind: Data, timeout: Double) -> Opened {
        guard let made = establish(line, identity: identity, timeout: timeout) else {
            line.close()
            return .failed
        }
        let opened = prove(line, keys: (made.sealing, made.opening), boardEphemeral: made.boardEphemeral, hostEphemeral: made.hostEphemeral,
                           hostKey: hostKey, board: board, ticket: ticket, kind: kind, timeout: timeout)
        if opened.channel == nil { line.close() }
        return opened
    }

    /// After the handshake: says the ticket (if any), the proof and `kind` back to back (no
    /// wait for the verdict in between: a host that answers "pending" drops the kind), reads the
    /// host's verdict (its sealed message number 0), and for a trusted board starts the stream.
    static func prove(_ line: Line, keys: (sealing: SymmetricKey, opening: SymmetricKey), boardEphemeral: Data, hostEphemeral: Data,
                      hostKey: Data, board: Board, ticket: Data?, kind: Data, timeout: Double) -> Opened {
        guard let proof = proof(board, boardEphemeral: boardEphemeral, hostEphemeral: hostEphemeral, hostIdentity: hostKey) else { return .failed }
        let first = (ticket.map { [$0] } ?? []) + [proof, kind]
        for (number, message) in first.enumerated() {
            guard let sealed = try? ChaChaPoly.seal(message, using: keys.sealing, nonce: nonce(UInt64(number))),
                  line.send(sealed.ciphertext + sealed.tag, timeout) else { return .failed }
        }
        guard let answer = line.receive(timeout), answer.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: nonce(0), ciphertext: answer.dropLast(16), tag: answer.suffix(16)),
              let text = try? ChaChaPoly.open(box, using: keys.opening), let verdict = verdict(text) else { return .failed }
        guard case .channel = verdict else { return verdict }
        guard let channel = bridge(line, keys: keys, said: UInt64(first.count), heard: 1) else { return .failed }
        return .channel(channel)
    }

    static let unreachable = Unreachable()

    /// The hosts whose direct path just failed, for 45 seconds each.
    final class Unreachable: @unchecked Sendable {
        private let lock = NSLock()
        private var since: [UUID: Date] = [:]
        func recently(_ host: UUID) -> Bool { lock.withLock { since[host].map { $0.timeIntervalSinceNow > -45 } ?? false } }
        func note(_ host: UUID) { lock.withLock { since[host] = Date() } }
        /// As if no try had failed (tests).
        func forget(_ host: UUID) { lock.withLock { since[host] = nil } }
    }

    /// What carries a channel's messages: the relay's WebSocket, or a TCP connection to the host.
    struct Line: Sendable {
        /// One message, within so many seconds.
        let send: @Sendable (Data, Double) -> Bool
        /// The next message; nil when there is none within so many seconds (nil: however long).
        let receive: @Sendable (Double?) -> Data?
        /// Ends both directions, waking whoever waits on them. May be called more than once.
        let close: @Sendable () -> Void
        /// Once, when no thread uses the line any more.
        let dispose: @Sendable () -> Void
    }

    /// The handshake: the keys both ends now seal with, and the two ephemeral keys they came
    /// from. Nil when the other end isn't the host `identity` names.
    private static func establish(_ line: Line, identity: Curve25519.Signing.PublicKey, timeout: Double)
        -> (sealing: SymmetricKey, opening: SymmetricKey, boardEphemeral: Data, hostEphemeral: Data)? {
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let boardKey = mine.publicKey.rawRepresentation
        guard line.send(Data(boardKey), timeout), let answer = line.receive(timeout), answer.count == 96 else { return nil }
        let theirKey = answer.prefix(32), signature = answer.suffix(64)
        let salt = boardKey + theirKey
        // Signed with what it is for (see docs/hosts.md).
        guard identity.isValidSignature(signature, for: info + salt),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirKey),
              let secret = try? mine.sharedSecretFromKeyAgreement(with: theirs) else { return nil }
        let keys = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 64)
            .withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: keys.prefix(32)), SymmetricKey(data: keys.suffix(32)), Data(boardKey), Data(theirKey))
    }

    /// Pumps the line to a socket pair and back, and gives the pair's other end. `said` and
    /// `heard` are how many messages the board and the host already sealed: the stream's
    /// chunks count on from there.
    private static func bridge(_ line: Line, keys: (sealing: SymmetricKey, opening: SymmetricKey), said: UInt64, heard: UInt64) -> Int32? {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        let inner = pair[1]
        let (sealing, opening) = keys
        // Either side ending ends both: the client sees its descriptor close, as a core going away.
        let end: @Sendable () -> Void = {
            shutdown(inner, SHUT_RDWR)
            line.close()
        }
        let sendingEnded = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: chunk)
            var counter = said
            while true {
                let count = read(inner, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, let sealed = try? ChaChaPoly.seal(buffer.prefix(count), using: sealing, nonce: nonce(counter)),
                      line.send(sealed.ciphertext + sealed.tag, 60) else { break }
                counter += 1
            }
            end()
            sendingEnded.signal()
        }
        Thread.detachNewThread {
            var counter = heard
            // No timeout: an idle core says nothing for as long as its programs do.
            while let message = line.receive(nil), message.count >= 16,
                  let box = try? ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: message.dropLast(16), tag: message.suffix(16)),
                  let plain = try? ChaChaPoly.open(box, using: opening), writeAll(plain, to: inner) {
                counter += 1
            }
            end()
            // Closed only once the other thread let go of them: a number may be another
            // descriptor's by then, and its `shutdown` would hit that one.
            sendingEnded.wait()
            close(inner)
            line.dispose()
        }
        return pair[0]
    }

    // MARK: The direct path

    /// A pass for one direct connection, which the server also tells the host. Nil when the
    /// host is offline or the server is slow: the relay it is.
    private static func ticket(server: URL, token: String, host: UUID) -> Data? {
        var request = URLRequest(url: server.appendingPathComponent("v1/hosts/\(host.uuidString)/ticket"), timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        let ticket = Box<Data?>(nil)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = reply["ticket"] as? String {
                ticket.value = Data(base64Encoded: text)
            }
            done.signal()
        }.resume()
        done.wait()
        return ticket.value?.count == 32 ? ticket.value : nil
    }

    /// Connects to every one of `addresses` ("address:port") at once and gives the first that
    /// answers within `seconds`, closing the others.
    static func reach(_ addresses: [String], within seconds: Double = 0.4) -> Int32? {
        var pending: [pollfd] = []
        for address in addresses.prefix(8) {
            guard let colon = address.lastIndex(of: ":") else { continue }
            let name = address[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            // Numbers only: nothing here looks a name up.
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
            hints.ai_socktype = SOCK_STREAM
            var found: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, String(address[address.index(after: colon)...]), &hints, &found) == 0, let found else { continue }
            defer { freeaddrinfo(found) }
            let fd = socket(found.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if connect(fd, found.pointee.ai_addr, found.pointee.ai_addrlen) == 0 || errno == EINPROGRESS {
                pending.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
            } else {
                close(fd)
            }
        }
        let deadline = Date().addingTimeInterval(seconds)
        var winner: Int32?
        while winner == nil, !pending.isEmpty {
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            guard left > 0 else { break }
            let ready = poll(&pending, nfds_t(pending.count), left)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            for entry in pending where entry.revents != 0 {
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &failure, &size)
                if winner == nil, failure == 0, entry.revents & Int16(POLLOUT) != 0 { winner = entry.fd } else { close(entry.fd) }
            }
            pending.removeAll { $0.revents != 0 }
        }
        for entry in pending { close(entry.fd) }
        guard let winner else { return nil }
        _ = fcntl(winner, F_SETFL, fcntl(winner, F_GETFL) & ~O_NONBLOCK)
        var one: Int32 = 1
        // Keystrokes travel here: nothing waits for a fuller packet. And a host that left is
        // an error to handle, not a signal.
        setsockopt(winner, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(winner, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return winner
    }

    /// A TCP connection to the host as a line: each message behind its length, 4 bytes big-endian.
    private static func direct(_ fd: Int32) -> Line {
        @Sendable func patience(_ option: Int32, _ seconds: Double) {
            var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, option, &time, socklen_t(MemoryLayout<timeval>.size))
        }
        // Set only when it changes: once for the handshake, once for the stream.
        let waiting = Box<Double?>(-1), sending = Box<Double>(-1)
        @Sendable func fill(_ count: Int) -> Data? {
            var data = Data(count: count)
            var filled = 0
            while filled < count {
                let got = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, count - filled) }
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { return nil }
                filled += got
            }
            return data
        }
        return Line(
            send: { message, timeout in
                if sending.value != timeout {
                    sending.value = timeout
                    patience(SO_SNDTIMEO, timeout)
                }
                var frame = Data(capacity: 4 + message.count)
                withUnsafeBytes(of: UInt32(message.count).bigEndian) { frame.append(contentsOf: $0) }
                frame.append(message)
                return writeAll(frame, to: fd)
            },
            receive: { timeout in
                if waiting.value != timeout {
                    waiting.value = timeout
                    patience(SO_RCVTIMEO, timeout ?? 0)
                }
                guard let header = fill(4) else { return nil }
                let length = header.reduce(0) { $0 << 8 | Int($1) }
                return length <= chunk + 16 ? fill(length) : nil
            },
            close: { shutdown(fd, SHUT_RDWR) },
            dispose: { Darwin.close(fd) }
        )
    }

    /// The message counter as a nonce: 12 bytes, little-endian.
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        withUnsafeBytes(of: counter.littleEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    private static func send(_ data: Data, on task: URLSessionWebSocketTask, timeout: Double) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let sent = Box(false)
        task.send(.data(data)) { error in
            sent.value = error == nil
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success && sent.value
    }

    private static func receive(on task: URLSessionWebSocketTask, timeout: Double?) -> Data? {
        let done = DispatchSemaphore(value: 0)
        let received = Box<Data?>(nil)
        task.receive { result in
            if case .success(.data(let data)) = result { received.value = data }
            done.signal()
        }
        if let timeout {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        } else {
            done.wait()
        }
        return received.value
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

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
