import Darwin
import Foundation

/// Speaks the adb server's wire protocol (port 5037 on the emulator's machine) directly: every
/// stream to a device is one more connection to the server, so a host needs no `adb forward` and
/// no extra ports. See SERVICES.TXT and SYNC.TXT in adb's sources.
/// Calls block: run them off the main thread.
struct AdbClient: Sendable {
    static let port: UInt16 = 5037

    let machine: Machine

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The emulators and devices the server knows, by serial, with their state (“device”,
    /// “offline”…).
    func devices() throws -> [String: String] {
        let stream = try open()
        defer { stream.close() }
        try stream.request("host:devices")
        let length = Int(String(decoding: try stream.read(4), as: UTF8.self), radix: 16) ?? 0
        return Self.parseDevices(String(decoding: try stream.read(length), as: UTF8.self))
    }

    /// A stream to `service` on the device (`shell:…`, `exec:…`, `sync:`, `localabstract:…`).
    func open(_ serial: String, _ service: String) throws -> AdbStream {
        let stream = try open()
        do {
            try stream.request("host:transport:\(serial)")
            try stream.request(service)
            return stream
        } catch {
            stream.close()
            throw error
        }
    }

    /// Runs a command on the device and returns its output (stdout only, unaltered).
    func exec(_ serial: String, _ command: String, timeout: TimeInterval = 60) throws -> Data {
        let stream = try open(serial, "exec:\(command)")
        defer { stream.close() }
        stream.timeout(timeout)
        return stream.readAll()
    }

    /// Writes `data` to `path` on the device.
    func push(_ serial: String, _ data: Data, to path: String, mode: Int = 0o644) throws {
        let stream = try open(serial, "sync:")
        defer { stream.close() }
        stream.timeout(60)
        try stream.write(Self.syncPush(data, to: path, mode: mode, modified: UInt32(Date().timeIntervalSince1970)))
        let status = String(decoding: try stream.read(4), as: UTF8.self)
        let length = Int(Self.littleEndian(try stream.read(4)))
        guard status == "OKAY" else {
            throw Failure(message: "Couldn't copy to the device: \(String(decoding: (try? stream.read(length)) ?? Data(), as: UTF8.self))")
        }
    }

    private func open() throws -> AdbStream {
        guard let fd = machine.connect(Self.port) else {
            throw Failure(message: "The adb server on \(machine.name) isn't running.")
        }
        let stream = AdbStream(fd: fd)
        stream.timeout(15)
        return stream
    }

    // MARK: Framing

    /// A request to the server: its length in 4 hex digits, then the text.
    static func request(_ service: String) -> Data {
        Data(String(format: "%04x", service.utf8.count).utf8) + Data(service.utf8)
    }

    /// `host:devices`' answer: a line per device, “serial<TAB>state”.
    static func parseDevices(_ text: String) -> [String: String] {
        var devices: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 { devices[String(parts[0])] = String(parts[1]) }
        }
        return devices
    }

    /// A whole `sync:` push: SEND path,mode, the bytes in DATA chunks of at most 64 KiB, DONE with
    /// the modification time.
    static func syncPush(_ data: Data, to path: String, mode: Int, modified: UInt32) -> Data {
        let target = Data("\(path),\(mode)".utf8)
        var packet = Data("SEND".utf8) + littleEndian(UInt32(target.count)) + target
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(data.endIndex, offset + 65536)
            packet += Data("DATA".utf8) + littleEndian(UInt32(end - offset)) + data[offset..<end]
            offset = end
        }
        return packet + Data("DONE".utf8) + littleEndian(modified)
    }

    static func littleEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func littleEndian(_ data: Data) -> UInt32 { data.prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }
}

/// One connection to the adb server, a byte stream to a device once its service is open.
final class AdbStream: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// How long a read waits; 0 waits for ever (a video stream that goes quiet on a still screen).
    func timeout(_ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends a request and reads the server's OKAY, or throws its FAIL message.
    func request(_ service: String) throws {
        try write(AdbClient.request(service))
        let status = String(decoding: try read(4), as: UTF8.self)
        guard status == "OKAY" else {
            let length = Int(String(decoding: (try? read(4)) ?? Data(), as: UTF8.self), radix: 16) ?? 0
            let message = String(decoding: (try? read(length)) ?? Data(), as: UTF8.self)
            throw AdbClient.Failure(message: message.isEmpty ? "adb refused \(service)" : message)
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw AdbClient.Failure(message: "The connection to the device closed.") }
                offset += written
            }
        }
    }

    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let got = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { throw AdbClient.Failure(message: "The connection to the device closed.") }
                offset += got
            }
        }
        return data
    }

    /// Everything until the other end closes (or a read times out).
    func readAll() -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let got = Darwin.read(fd, &buffer, buffer.count)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return data }
            data.append(buffer, count: got)
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            // Wakes a read blocked on it in another thread before the descriptor goes away.
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}
