import Darwin
import Foundation

// How a core hands everything to a newer one without ending its programs.
//
// The new core connects to the old one's socket and sends `CoreRequest.takeOver`; the old core
// answers one byte (`accepted`) at once, so a core that can't hand over (an older build) is told
// apart quickly. Once the calls its tools are answering are done, the old core stops reading every PTY (what the programs write next waits in the PTY), snapshots each
// terminal, and writes on that connection: a 4-byte big-endian length, the `HandoffManifest`
// as JSON, then, once the new core says it read it (`manifestRead`), the file descriptors with
// SCM_RIGHTS, in batches. (They go straight into the reader's buffer, which a manifest of
// megabytes could still fill: sending them then fails with EMSGSIZE.) The descriptors are the
// lock file (still locked: no third core can start in between), the listening socket (boards
// that reconnect meanwhile wait in its backlog), and each session's PTY master. The new core
// answers one byte once it has everything; the old one then exits without touching the
// programs, which the new one watches from then on.

/// What the old core hands over, besides the descriptors.
struct HandoffManifest: Codable {
    struct Session: Codable {
        let id: UUID
        /// Whether a program runs, whose PTY master is among the descriptors.
        let running: Bool
        let processID: Int32
        let status: SessionStatus
        let snapshot: Data
        /// Typed but not taken by the program yet; nil from a core that kept none.
        let input: Data?
    }

    /// The old core's pid: the new one waits for it to exit before taking its other resources
    /// (the tool server's port).
    let processID: Int32
    /// Running ones in the order of their PTY masters among the descriptors, after the lock and
    /// the listener.
    let sessions: [Session]
    /// The core service's own state (see `CoreService.handOffState`).
    let service: Data?
    /// How many of the descriptors, the last ones, are the service's.
    let serviceDescriptors: Int
}

/// What a new core gets from the one it replaces.
public struct Inheritance {
    /// The lock file, still locked.
    public let lock: Int32
    /// The socket boards connect to, still listening.
    public let listener: Int32
    /// The old core's pid.
    public let processID: Int32
    public let sessions: [(id: UUID, handoff: AgentSession.Handoff)]
    public let service: Data?
    /// The service's own descriptors (see `CoreService.handOffState`).
    public let serviceDescriptors: [Int32]
}

public enum CoreHandoff {
    /// The byte an old core answers `takeOver` with before anything else.
    static let accepted: UInt8 = 2
    /// The byte the new core sends once it has the whole manifest.
    static let manifestRead: UInt8 = 3

    /// Asks the core at `socketPath` to hand everything over and takes it. Nil when no core
    /// answers or it can't hand over (an older build), after saying why to `log`.
    public static func takeOver(socketPath: String, timeout: Double = 15, log: (String) -> Void = { _ in }) -> Inheritance? {
        guard let fd = try? UnixSocket.connect(to: socketPath) else {
            log("no core answers on \(socketPath)")
            return nil
        }
        defer { close(fd) }
        var time = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard let request = try? JSONEncoder().encode(CoreRequest.takeOver) else { return nil }
        let length = UInt32(1 + request.count)
        let frame = [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
                     FrameKind.control.rawValue] + Array(request)
        guard writeAll(fd, frame) else {
            log("couldn't ask: \(String(cString: strerror(errno)))")
            return nil
        }
        guard readExactly(fd, 1) == [accepted] else {
            log("it can't hand over (an older build?)")
            return nil
        }
        time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        guard let header = readExactly(fd, 4) else {
            log("no answer: \(errno == EAGAIN ? "timed out" : errno == 0 ? "it hung up" : String(cString: strerror(errno)))")
            return nil
        }
        let size = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard size <= CoreProtocol.maximumFrame, let body = readExactly(fd, size),
              let manifest = try? JSONDecoder().decode(HandoffManifest.self, from: Data(body)) else {
            log("its answer wasn't a handoff manifest")
            return nil
        }
        guard writeAll(fd, [manifestRead]) else {
            log("it hung up after the manifest")
            return nil
        }
        let running = manifest.sessions.filter(\.running).count
        let expected = 2 + running + manifest.serviceDescriptors
        var fds: [Int32] = []
        while fds.count < expected {
            guard let batch = receiveDescriptors(fd), !batch.isEmpty else {
                log("got \(fds.count) of \(expected) descriptors")
                fds.forEach { close($0) }
                return nil
            }
            fds += batch
        }
        _ = writeAll(fd, [1])
        var masters = fds.dropFirst(2).makeIterator()
        let sessions = manifest.sessions.map { session in
            (session.id, AgentSession.Handoff(master: session.running ? masters.next() ?? -1 : -1, processID: session.processID,
                                              status: session.status, snapshot: Array(session.snapshot),
                                              input: Array(session.input ?? Data())))
        }
        return Inheritance(lock: fds[0], listener: fds[1], processID: manifest.processID, sessions: sessions, service: manifest.service,
                           serviceDescriptors: Array(fds.dropFirst(2 + running)))
    }

    /// Writes `manifest` and `fds` to the new core on `fd` (blocking) and waits for its answer;
    /// says why it failed to `log`.
    static func send(_ manifest: HandoffManifest, fds: [Int32], on fd: Int32, log: (String) -> Void = { _ in }) -> Bool {
        guard let body = try? JSONEncoder().encode(manifest) else { return false }
        let length = UInt32(body.count)
        guard writeAll(fd, [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + Array(body)) else {
            log("couldn't send the manifest: \(String(cString: strerror(errno)))")
            return false
        }
        var time = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        guard readExactly(fd, 1) == [manifestRead] else {
            log("the newer core didn't read the manifest: \(errno == 0 ? "it hung up" : String(cString: strerror(errno)))")
            return false
        }
        var index = 0
        while index < fds.count {
            let batch = Array(fds[index..<min(index + 16, fds.count)])
            guard sendDescriptors(batch, on: fd) else {
                let error = String(cString: strerror(errno))
                let invalid = batch.filter { fcntl($0, F_GETFD) < 0 }
                log("couldn't send descriptors \(batch): \(error); invalid: \(invalid)")
                return false
            }
            index += batch.count
        }
        guard readExactly(fd, 1) == [1] else {
            log("no answer from the newer core: \(errno == 0 ? "it hung up" : String(cString: strerror(errno)))")
            return false
        }
        return true
    }

    // MARK: Plumbing

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { return false }
        }
        return true
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if got > 0 {
                offset += got
            } else if got < 0, errno == EINTR {
                continue
            } else {
                if got == 0 { errno = 0 }
                return nil
            }
        }
        return bytes
    }

    /// One byte of payload carrying `fds` as SCM_RIGHTS.
    private static func sendDescriptors(_ fds: [Int32], on socket: Int32) -> Bool {
        let space = cmsgSpace(fds.count)
        let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, space)
        let header = control.assumingMemoryBound(to: cmsghdr.self)
        header.pointee.cmsg_len = socklen_t(cmsgLength(fds.count))
        header.pointee.cmsg_level = SOL_SOCKET
        header.pointee.cmsg_type = SCM_RIGHTS
        fds.withUnsafeBytes { (control + cmsgDataOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        var byte: UInt8 = 0
        return withUnsafeMutablePointer(to: &byte) { pointer in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(pointer), iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                     msg_control: control, msg_controllen: socklen_t(space), msg_flags: 0)
                // No room for them in the reader's buffer yet: it is reading, so wait a little.
                let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
                while true {
                    let sent = sendmsg(socket, &message, 0)
                    if sent == 1 { return true }
                    if sent < 0, errno == EINTR { continue }
                    if sent < 0, errno == EMSGSIZE || errno == ENOBUFS, DispatchTime.now().uptimeNanoseconds < deadline {
                        usleep(2_000)
                        continue
                    }
                    return false
                }
            }
        }
    }

    private static func receiveDescriptors(_ socket: Int32) -> [Int32]? {
        let space = cmsgSpace(64)
        let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        var byte: UInt8 = 0
        let received = withUnsafeMutablePointer(to: &byte) { pointer -> Int32? in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(pointer), iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer -> Int32? in
                var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                     msg_control: control, msg_controllen: socklen_t(space), msg_flags: 0)
                while true {
                    let got = recvmsg(socket, &message, 0)
                    if got == 1 { return Int32(message.msg_controllen) }
                    if got < 0, errno == EINTR { continue }
                    return nil
                }
            }
        }
        guard let length = received, Int(length) >= cmsgLength(0) else { return nil }
        let header = control.assumingMemoryBound(to: cmsghdr.self)
        guard header.pointee.cmsg_level == SOL_SOCKET, header.pointee.cmsg_type == SCM_RIGHTS else { return nil }
        let count = (Int(header.pointee.cmsg_len) - cmsgLength(0)) / MemoryLayout<Int32>.size
        let fds = (0..<count).map { (control + cmsgDataOffset).load(fromByteOffset: $0 * MemoryLayout<Int32>.size, as: Int32.self) }
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return fds
    }

    // CMSG_ALIGN and friends, which Swift doesn't import.
    private static func align(_ length: Int) -> Int { (length + MemoryLayout<UInt32>.size - 1) & ~(MemoryLayout<UInt32>.size - 1) }
    private static var cmsgDataOffset: Int { align(MemoryLayout<cmsghdr>.size) }
    private static func cmsgLength(_ count: Int) -> Int { cmsgDataOffset + count * MemoryLayout<Int32>.size }
    private static func cmsgSpace(_ count: Int) -> Int { cmsgDataOffset + align(count * MemoryLayout<Int32>.size) }
}
