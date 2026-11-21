import AgentRuntime
import Darwin
import Foundation

/// The machine an Android emulator runs on: this Mac, or a host (see docs/hosts.md). It runs a
/// program and waits for it, and opens a byte stream to a port on its own loopback. Nothing else
/// in the Android code knows where the emulator is.
struct Machine: Sendable {
    /// What the card's messages call it: “this Mac” or the host's name.
    let name: String
    let host: UUID?
    let run: @Sendable (_ executable: String, _ arguments: [String]) async -> CoreClient.Ran?
    /// A connected stream to `port` on the machine's loopback; nil when nothing listens or the
    /// machine can't be reached. It blocks: never call it on the main thread.
    let connect: @Sendable (_ port: UInt16) -> Int32?

    /// Runs a POSIX sh script there.
    func sh(_ script: String) async -> CoreClient.Ran? {
        await run("/bin/sh", ["-c", script])
    }

    static let local = Machine(name: "this Mac", host: nil, run: { executable, arguments in
        await Task.detached { runLocally(executable, arguments) }.value
    }, connect: { connectLocally($0) })

    /// A host, through its core (`run`) and its channels (`open`).
    static func host(_ id: UUID, name: String, run: @escaping @Sendable (String, [String]) async -> CoreClient.Ran?,
                     open: @escaping HostProxy.Open) -> Machine {
        Machine(name: name, host: id, run: run, connect: { open(id, $0) })
    }

    private static func runLocally(_ executable: String, _ arguments: [String]) -> CoreClient.Ran? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        guard (try? process.run()) != nil else { return nil }
        // Read both while it runs, so neither pipe fills up and blocks it.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return CoreClient.Ran(status: process.terminationStatus, output: outputData, error: errorData)
    }

    static func connectLocally(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}
