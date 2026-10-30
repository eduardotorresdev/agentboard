import Darwin
import Foundation

/// One end of a core connection: reads frames as they arrive and writes them without blocking,
/// queueing what the socket can't take yet. Sends are safe from any thread.
final class CoreSocket: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private let lock = NSLock()
    private var outbox: [UInt8] = []
    private var outboxStart = 0
    private var closed = false
    private var inbox: [UInt8] = []
    private var inboxStart = 0
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
    /// A peer that stops reading is dropped once this much is waiting for it.
    private static let outboxLimit = 64 * 1024 * 1024

    /// Called on `queue` with each frame.
    var onFrame: ((FrameKind, ArraySlice<UInt8>) -> Void)?
    /// Called on `queue` once, when the connection ends for any reason.
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    deinit { readBuffer.deallocate() }

    func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.resume()
        self.reader = reader
    }

    func send(_ kind: FrameKind, _ payload: [UInt8]) {
        send(kind, prefix: [], payload)
    }

    func send(_ kind: FrameKind, id: UUID, _ payload: UnsafeRawBufferPointer) {
        send(kind, prefix: id.bytes, payload)
    }

    func send(_ kind: FrameKind, id: UUID, _ payload: [UInt8]) {
        payload.withUnsafeBytes { send(kind, prefix: id.bytes, $0) }
    }

    func send<Message: Encodable>(_ message: Message) {
        guard let json = try? JSONEncoder().encode(message) else { return }
        send(.control, Array(json))
    }

    private func send<Payload: Collection>(_ kind: FrameKind, prefix: [UInt8], _ payload: Payload) where Payload.Element == UInt8 {
        let length = UInt32(1 + prefix.count + payload.count)
        let flush = lock.withLock { () -> Bool in
            guard !closed else { return false }
            let wasEmpty = outbox.count == outboxStart
            outbox.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), kind.rawValue])
            outbox.append(contentsOf: prefix)
            outbox.append(contentsOf: payload)
            return wasEmpty
        }
        if flush { queue.async { [self] in self.flush() } }
    }

    func close() {
        queue.async { [self] in shutDown() }
    }

    /// Stops reading and writing frames and gives the connection itself (a duplicate, blocking),
    /// for a conversation that doesn't fit frames: a core handing itself over. Must be called on
    /// `queue`; unsent frames are dropped.
    func detach() -> Int32? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        _ = fcntl(copy, F_SETFL, fcntl(copy, F_GETFL) & ~O_NONBLOCK)
        shutDown()
        return copy
    }

    // MARK: On `queue`

    private func flush() {
        let overflow = lock.withLock { () -> Bool? in
            guard !closed else { return nil }
            while outboxStart < outbox.count {
                let written = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + outboxStart, $0.count - outboxStart) }
                if written > 0 {
                    outboxStart += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && errno == EAGAIN {
                    break
                } else {
                    return true
                }
            }
            if outboxStart == outbox.count {
                outbox.removeAll(keepingCapacity: outbox.count < 1024 * 1024)
                outboxStart = 0
                return false
            }
            if outboxStart > 1024 * 1024 {
                outbox.removeFirst(outboxStart)
                outboxStart = 0
            }
            return outbox.count - outboxStart > Self.outboxLimit
        }
        guard let overflow else { return }
        if overflow { return shutDown() }
        let pending = lock.withLock { outbox.count > outboxStart }
        if pending, writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            writer.setEventHandler { [weak self] in self?.flush() }
            writer.resume()
            self.writer = writer
        } else if !pending {
            writer?.cancel()
            writer = nil
        }
    }

    private func readAvailable() {
        while true {
            let count = read(fd, readBuffer.baseAddress, readBuffer.count)
            if count > 0 {
                inbox.append(contentsOf: UnsafeRawBufferPointer(rebasing: readBuffer[0..<count]))
                if count < readBuffer.count { break }
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                break
            } else {
                parseFrames()
                return shutDown()
            }
        }
        parseFrames()
    }

    private func parseFrames() {
        while inbox.count - inboxStart >= 5 {
            let length = Int(inbox[inboxStart]) << 24 | Int(inbox[inboxStart + 1]) << 16 | Int(inbox[inboxStart + 2]) << 8 | Int(inbox[inboxStart + 3])
            guard length >= 1, length <= CoreProtocol.maximumFrame else { return shutDown() }
            guard inbox.count - inboxStart >= 4 + length else { break }
            let kind = FrameKind(rawValue: inbox[inboxStart + 4])
            let payload = inbox[(inboxStart + 5)..<(inboxStart + 4 + length)]
            inboxStart += 4 + length
            if let kind { onFrame?(kind, payload) }
            if closed { return }
        }
        if inboxStart == inbox.count {
            inbox.removeAll(keepingCapacity: inbox.count < 1024 * 1024)
            inboxStart = 0
        } else if inboxStart > 1024 * 1024 {
            inbox.removeFirst(inboxStart)
            inboxStart = 0
        }
    }

    private func shutDown() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { closed = true }
            outbox.removeAll()
            outboxStart = 0
            return !closed
        }
        guard wasOpen else { return }
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        Darwin.close(fd)
        let onClose = onClose
        self.onClose = nil
        onFrame = nil
        onClose?()
    }
}

// MARK: Unix sockets

enum UnixSocket {
    struct Failure: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    /// A socket connected to `path`.
    static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        var address = try self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure(call: "connect", code: code)
        }
        return fd
    }

    /// A socket listening at `path`, readable by this user only. Replaces a stale socket file.
    static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        var address = try self.address(path)
        unlink(path)
        let previous = umask(0o077)
        defer { umask(previous) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure(call: "bind", code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure(call: "socket path", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}
