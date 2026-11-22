import CryptoKit
import Foundation
import Testing
@testable import AgentRuntime

/// A board's channel to a host, end to end: the real account server run locally (`server/`),
/// the Rust host's relay (`core/crates/host`), and this build's `HostChannel`. Needs node, the
/// server's packages (`npm install` in `server/`) and the relay built
/// (`cargo build -p host --example relay` in `core/`):
/// `AGENTBOARD_HOST_E2E=1 swift test --filter HostChannelTests`.
struct HostChannelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_HOST_E2E"] == "1"))
    func aBoardReachesAHostsCoreAndPortsThroughTheAccountServer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = root.appendingPathComponent("server")
        let wrangler = server.appendingPathComponent("node_modules/.bin/wrangler").path
        let relayPath = ProcessInfo.processInfo.environment["AGENTBOARD_HOST_RELAY"] ?? root.appendingPathComponent("core/target/debug/examples/relay").path
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abhost-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var running: [Process] = []
        defer {
            for process in running where process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: folder)
        }

        func launch(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = server
            // No prompts and no usage reports from wrangler.
            process.environment = ProcessInfo.processInfo.environment.merging(["CI": "1", "WRANGLER_SEND_METRICS": "false"]) { $1 }.merging(environment) { $1 }
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            return process
        }
        func run(_ arguments: [String]) throws {
            let process = try launch(wrangler, arguments)
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "wrangler \(arguments.joined(separator: " "))")
        }

        // The account server, with an account and a signed-in session put straight in its database.
        let state = folder.appendingPathComponent("state").path
        let token = "e2e-\(UUID().uuidString)"
        // The host's own session, as `agentboard login` gets it: the server keeps boards' and hosts' apart.
        let host = UUID(), hostToken = "e2e-host-\(UUID().uuidString)"
        let hash = { (token: String) in SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
        let tokenHash = hash(token), made = Int(Date().timeIntervalSince1970)
        try run(["d1", "migrations", "apply", "agentboard-account", "--local", "--persist-to", state])
        try run(["d1", "execute", "agentboard-account", "--local", "--persist-to", state, "--command",
                 "INSERT INTO accounts (id, login) VALUES (1, 'tester'); INSERT INTO sessions (token_hash, account_id, created_at) VALUES ('\(tokenHash)', 1, \(made)); INSERT INTO sessions (token_hash, account_id, created_at, host_id) VALUES ('\(hash(hostToken))', 1, \(made), '\(host.uuidString.lowercased())');"])
        let port = try freePort()
        running.append(try launch(wrangler, ["dev", "--local", "--ip", "127.0.0.1", "--port", "\(port)", "--inspector-port", "\(try freePort())", "--persist-to", state]))
        let address = try #require(URL(string: "http://127.0.0.1:\(port)"))
        try #require(eventually(60) { (try? String(contentsOf: address, encoding: .utf8)) == "ok" }, "the account server starts")

        // The host: its identity and token as `agentboard login` leaves them, an echo in place of
        // its core, and an echo on a loopback port in place of what a runner serves.
        let identity = Curve25519.Signing.PrivateKey()
        let config = ["id": host.uuidString.lowercased(), "key": identity.rawRepresentation.base64EncodedString(), "name": "e2e host", "token": hostToken]
        try JSONSerialization.data(withJSONObject: config).write(to: folder.appendingPathComponent("host.json"))
        // The board the host already trusts.
        let board = HostChannel.Board(key: Curve25519.Signing.PrivateKey(), name: "e2e board")
        let trusted = ["trusted": [["key": board.key.publicKey.rawRepresentation.base64EncodedString(), "name": "e2e board", "added": 0]], "pending": []]
        try JSONSerialization.data(withJSONObject: trusted).write(to: folder.appendingPathComponent("boards.json"))
        let corePath = folder.appendingPathComponent("core.sock").path
        let coreListener = try echoServer(unixPath: corePath)
        let (tcpListener, tcpPort) = try echoServer()
        defer {
            close(coreListener)
            close(tcpListener)
        }
        running.append(try launch(relayPath, [corePath], environment: ["AGENTBOARD_HOME": folder.path, "AGENTBOARD_SERVER": address.absoluteString]))

        let hostKey = identity.publicKey.rawRepresentation
        var opened: Int32?
        var said = HostChannel.Opened.failed
        // Until the relay registered the host and its line is up.
        try #require(eventually(30) {
            said = HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: board)
            opened = said.channel
            return opened != nil
        }, "the host comes online and trusts the board: \(said)")
        let core = try #require(opened)
        defer { close(core) }

        // The direct path: the addresses the host registered, here its loopback's (the machine's
        // own addresses reach it too, but a test shouldn't lean on the network it runs in).
        var hosts = URLRequest(url: address.appendingPathComponent("v1/hosts"))
        hosts.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let listed = try JSONSerialization.jsonObject(with: fetch(hosts)) as? [[String: Any]]
        let registered = try #require(listed?.first?["addresses"] as? [String])
        let hostPort = try #require(registered.first.flatMap { $0.split(separator: ":").last }.flatMap { UInt16($0) }, "the host registers where it listens: \(registered)")
        #expect(registered.allSatisfy { $0.hasSuffix(":\(hostPort)") })
        let paths = Paths()
        func open(_ carrying: HostChannel.Carrying, at addresses: [String], key: Data? = nil) -> Int32? {
            HostChannel.open(server: address, token: token, host: host, hostKey: key ?? hostKey, board: board, carrying: carrying, addresses: addresses) { paths.taken.append($0) }.channel
        }
        let direct = try #require(open(.core, at: ["127.0.0.1:\(hostPort)"]))
        defer { close(direct) }
        #expect(paths.taken == [.direct])
        try #require(echoes(Array("straight to the host".utf8), on: direct))
        let started = Date()
        for _ in 0..<200 { try #require(echoes([107], on: direct)) }
        print("1-byte echo on the direct path, mean of 200: \(Int(Date().timeIntervalSince(started) / 200 * 1_000_000)) µs")
        // What the host registered works as it is, when the machine has an address at all.
        if !registered.isEmpty, let own = open(.core, at: registered) {
            #expect(paths.taken == [.direct, .direct])
            #expect(echoes(Array("by its own address".utf8), on: own))
            close(own)
        }
        paths.taken = []
        // An address nothing answers at, beside the one that does: the first to answer wins.
        let chosen = try #require(open(.tcp(port: 1), at: ["127.0.0.1:1", "[::1]:1", "not an address", "127.0.0.1:\(hostPort)"]))
        close(chosen)
        #expect(paths.taken == [.direct])
        // Nothing answering: the relay, silently.
        let relayed = try #require(open(.core, at: ["127.0.0.1:1"]))
        defer { close(relayed) }
        #expect(paths.taken == [.direct, .relay])
        try #require(echoes(Array("through the relay".utf8), on: relayed))
        // Something else answering there (the echo, which is no host): the relay as well.
        let mistaken = try #require(open(.core, at: ["127.0.0.1:\(tcpPort)"]))
        defer { close(mistaken) }
        #expect(paths.taken == [.direct, .relay, .relay])
        try #require(echoes(Array("through the relay again".utf8), on: mistaken))
        // Not the host the key says, whichever way.
        #expect(open(.core, at: ["127.0.0.1:\(hostPort)"], key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) == nil)
        #expect(paths.taken.count == 3)

        try #require(echoes(Array("hello".utf8), on: core))
        // Larger than five chunks, in one write.
        let large = (0..<300 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try #require(echoes(large, on: core))
        try #require(echoes(Array("again".utf8), on: core))

        // The tries above that found nothing at the address keep the host off the direct path for a while.
        HostChannel.unreachable.forget(host)
        let tcpDirect = try #require(open(.tcp(port: tcpPort), at: ["127.0.0.1:\(hostPort)"]))
        defer { close(tcpDirect) }
        #expect(paths.taken.last == .direct)
        try #require(echoes(large, on: tcpDirect))
        try #require(echoes(large, on: direct))

        let tcp = try #require(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: board, carrying: .tcp(port: tcpPort)).channel)
        defer { close(tcp) }
        try #require(echoes(Array("GET / HTTP/1.1\r\n\r\n".utf8), on: tcp))
        try #require(echoes(large, on: tcp))
        // The first channel is still its own stream.
        try #require(echoes(Array("core".utf8), on: core))

        // A port nothing listens on: the channel opens (the host proved itself) and then ends.
        let closedPort = try freePort()
        let refused = try #require(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: board, carrying: .tcp(port: closedPort)).channel)
        defer { close(refused) }
        var byte: UInt8 = 0
        setTimeout(refused, seconds: 20)
        #expect(read(refused, &byte, 1) == 0, "a channel to a closed port ends")

        // Another key than the one the host registered: not this host.
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        #expect(HostChannel.open(server: address, token: token, host: host, hostKey: other, board: board) == .failed)
        #expect(HostChannel.open(server: address, token: token, host: host, hostKey: other, board: board, carrying: .tcp(port: tcpPort)) == .failed)

        // A board the host doesn't know waits, and is told how many it trusts; the trusted one sees it asking and lets it in.
        let stranger = HostChannel.Board(key: Curve25519.Signing.PrivateKey(), name: "stranger")
        #expect(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: stranger) == .pending(trusted: 1))
        func ask(_ request: String) throws -> [String: Any] {
            let boards = try #require(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: board, carrying: .boards).channel)
            defer { close(boards) }
            setTimeout(boards, seconds: 20)
            #expect(write(boards, request + "\n", request.utf8.count + 1) == request.utf8.count + 1)
            var answer = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while answer.last != 10 {
                let count = read(boards, &buffer, buffer.count)
                try #require(count > 0, "the host answers \(request)")
                answer.append(contentsOf: buffer[..<count])
            }
            return try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
        }
        let strangerKey = stranger.key.publicKey.rawRepresentation.base64EncodedString()
        #expect(((try ask(#"{"list":{}}"#)["pending"] as? [[String: Any]]) ?? []).contains { $0["key"] as? String == strangerKey && $0["name"] as? String == "stranger" })
        #expect(try ask(#"{"trust":{"key":"\#(strangerKey)"}}"#)["ok"] as? Bool == true)
        let admitted = try #require(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: stranger).channel)
        close(admitted)
        #expect(try ask(#"{"forget":{"key":"\#(strangerKey)"}}"#)["ok"] as? Bool == true)
        #expect(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: stranger) == .pending(trusted: 1))
    }

    /// This Mac as a host, as a phone reaches it: the account server run locally, `agentboard
    /// relay` (`cargo build -p agentboard` in `core/`) and this build's Swift core
    /// (`swift build --product AgentBoardCore`), on a data folder of their own. A new board
    /// waits; once trusted, its channel says hello to the Swift core and is welcomed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_HOST_E2E"] == "1"))
    func aBoardReachesThisMacsCoreOnceApproved() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = root.appendingPathComponent("server")
        let wrangler = server.appendingPathComponent("node_modules/.bin/wrangler").path
        let agentboard = root.appendingPathComponent("core/target/debug/agentboard").path
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abmac-\(UUID().uuidString.prefix(8))")
        let data = folder.appendingPathComponent("data"), hostFolder = data.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
        var running: [Process] = []
        defer {
            for process in running where process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: folder)
        }
        func launch(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = server
            process.environment = ProcessInfo.processInfo.environment.merging(["CI": "1", "WRANGLER_SEND_METRICS": "false"]) { $1 }.merging(environment) { $1 }
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            return process
        }
        func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws {
            let process = try launch(executable, arguments, environment: environment)
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "\(executable) \(arguments.joined(separator: " "))")
        }

        let state = folder.appendingPathComponent("state").path
        let token = "e2e-\(UUID().uuidString)"
        let host = UUID(), hostToken = "e2e-host-\(UUID().uuidString)"
        let hash = { (token: String) in SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
        let made = Int(Date().timeIntervalSince1970)
        try run(wrangler, ["d1", "migrations", "apply", "agentboard-account", "--local", "--persist-to", state])
        try run(wrangler, ["d1", "execute", "agentboard-account", "--local", "--persist-to", state, "--command",
                           "INSERT INTO accounts (id, login) VALUES (1, 'tester'); INSERT INTO sessions (token_hash, account_id, created_at) VALUES ('\(hash(token))', 1, \(made)); INSERT INTO sessions (token_hash, account_id, created_at, host_id) VALUES ('\(hash(hostToken))', 1, \(made), '\(host.uuidString.lowercased())');"])
        let port = try freePort()
        running.append(try launch(wrangler, ["dev", "--local", "--ip", "127.0.0.1", "--port", "\(port)", "--inspector-port", "\(try freePort())", "--persist-to", state]))
        let address = try #require(URL(string: "http://127.0.0.1:\(port)"))
        try #require(eventually(60) { (try? String(contentsOf: address, encoding: .utf8)) == "ok" }, "the account server starts")

        // The Mac's host as the relay's own sign-in leaves it; no board trusted, no first-use window.
        let identity = Curve25519.Signing.PrivateKey()
        let config = ["id": host.uuidString.lowercased(), "key": identity.rawRepresentation.base64EncodedString(), "name": "e2e mac", "token": hostToken]
        try JSONSerialization.data(withJSONObject: config).write(to: hostFolder.appendingPathComponent("host.json"))
        let socket = folder.appendingPathComponent("core.sock").path
        let core = root.appendingPathComponent(".build/debug/AgentBoardCore").path
        running.append(try launch(core, [], environment: ["AGENTBOARD_HOME": data.path, "AGENTBOARD_CORE_SOCKET": socket]))
        try #require(eventually(10) { FileManager.default.fileExists(atPath: socket) }, "the Swift core listens")
        running.append(try launch(agentboard, ["relay", "--core", socket], environment: ["AGENTBOARD_HOME": data.path, "AGENTBOARD_SERVER": address.absoluteString]))

        let hostKey = identity.publicKey.rawRepresentation
        let phone = HostChannel.Board(key: Curve25519.Signing.PrivateKey(), name: "e2e phone")
        var said = HostChannel.Opened.failed
        try #require(eventually(30) {
            said = HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: phone)
            return said != .failed
        }, "the Mac comes online")
        #expect(said == .pending(trusted: 0))
        #expect(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: phone, carrying: .tcp(port: port)) == .pending(trusted: 0))

        // Approved as the app does it: `agentboard trust` on the host's folder.
        try run(agentboard, ["trust", phone.key.publicKey.rawRepresentation.base64EncodedString()], environment: ["AGENTBOARD_HOME": hostFolder.path])
        let channel = try #require(HostChannel.open(server: address, token: token, host: host, hostKey: hostKey, board: phone).channel)
        let client = try CoreClient.open(on: channel).get()
        #expect(client.version == CoreProtocol.version)
        client.disconnect()
    }

    private final class Paths: @unchecked Sendable {
        var taken: [HostChannel.Path] = []
    }

    private func fetch(_ request: URLRequest) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var body: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            body = data
            done.signal()
        }.resume()
        done.wait()
        return try #require(body)
    }

    private func eventually(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func setTimeout(_ fd: Int32, seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes `bytes` and reads as many back, concurrently as a terminal would; true when they match.
    private func echoes(_ bytes: [UInt8], on fd: Int32) -> Bool {
        setTimeout(fd, seconds: 20)
        let writer = Thread {
            var offset = 0
            while offset < bytes.count {
                let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { return }
                offset += count
            }
        }
        writer.start()
        var back: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while back.count < bytes.count {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return false }
            back.append(contentsOf: buffer[..<count])
        }
        return back == bytes
    }

    private func freePort() throws -> UInt16 {
        let (listener, port) = try echoServer(serving: false)
        close(listener)
        return port
    }

    /// An echo on a loopback TCP port the system picks.
    private func echoServer(serving: Bool = true) throws -> (Int32, UInt16) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
        }
        try #require(bound && listen(listener, 16) == 0)
        if serving { echo(listener) }
        return (listener, UInt16(bigEndian: address.sin_port))
    }

    /// An echo on a Unix socket, standing for the core.
    private func echoServer(unixPath: String) throws -> Int32 {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try #require(unixPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: unixPath.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        try #require(bound && listen(listener, 16) == 0)
        echo(listener)
        return listener
    }

    private func echo(_ listener: Int32) {
        Thread.detachNewThread {
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = read(connection, &buffer, buffer.count)
                        guard count > 0 else { break }
                        var offset = 0
                        while offset < count {
                            let written = buffer[offset..<count].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                            guard written > 0 else { break }
                            offset += written
                        }
                    }
                    close(connection)
                }
            }
        }
    }
}
