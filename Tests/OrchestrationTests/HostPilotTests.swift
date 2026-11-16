import CryptoKit
import AgentRuntime
import Connections
import Foundation
import Testing
@testable import Orchestration

/// A real host, reached as the board reaches it: through the account server's relay, sealed end
/// to end (docs/hosts.md). Needs a signed-in account whose first online host runs `agentboard`:
/// `AGENTBOARD_PILOT=<account.json> scripts/test-safe --filter HostPilotTests`, the file holding what
/// `/v1/login/poll` answered (`token`, `account`). Leaves nothing on the host.
@MainActor struct HostPilotTests {
    private struct Saved: Decodable { var token: String }
    private struct Host: Decodable {
        var id: UUID
        var name: String
        var public_key: String
        var online: Bool
        var addresses: [String]?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_PILOT"] != nil))
    func aBoardDrivesARealHost() async throws {
        let environment = ProcessInfo.processInfo.environment
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: environment["AGENTBOARD_PILOT"]!)))
        let server = URL(string: environment["AGENTBOARD_SERVER"] ?? "https://agentboard-account.agentboard-account-server.workers.dev")!
        var listing = URLRequest(url: server.appendingPathComponent("v1/hosts"))
        listing.setValue("Bearer \(saved.token)", forHTTPHeaderField: "Authorization")
        let hosts = try JSONDecoder().decode([Host].self, from: try await URLSession.shared.data(for: listing).0)
        let online = hosts.first { $0.online }
        let host = try #require(online, "no host of this account is online")
        let key = try #require(Data(base64Encoded: host.public_key))
        let token = saved.token, id = host.id
        // The pilot's own key, which the host must trust (`agentboard trust <key>` there):
        // `board.key` beside the account file, the private key in base64.
        let kept = try String(contentsOf: URL(fileURLWithPath: environment["AGENTBOARD_PILOT"]!).deletingLastPathComponent().appendingPathComponent("board.key"), encoding: .utf8)
        let pilot = HostChannel.Board(key: try Curve25519.Signing.PrivateKey(rawRepresentation: try #require(Data(base64Encoded: kept))), name: "pilot")
        // `AGENTBOARD_PILOT_RELAY=1` keeps to the relay, to compare.
        // `AGENTBOARD_PILOT_ADDRESS` reaches the host's port some other way (a tunnel), for a
        // test process macOS keeps off the local network.
        let addresses = environment["AGENTBOARD_PILOT_ADDRESS"].map { [$0] }
            ?? (environment["AGENTBOARD_PILOT_RELAY"] == nil ? host.addresses ?? [] : [])

        func waitUntil(_ seconds: Double = 30, _ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        }

        let opening = Date()
        let link = CoreLink {
            let opened = HostChannel.open(server: server, token: token, host: id, hostKey: key, board: pilot, addresses: addresses,
                                          took: { print("pilot: took the \($0) path") })
            if case .pending = opened { print("pilot: the host doesn't trust \(HostChannel.fingerprint(of: pilot.key.publicKey.rawRepresentation)) yet") }
            guard let fd = opened.channel else { return .failure(.noCore) }
            return CoreClient.open(on: fd)
        }
        try await waitUntil { await link.start() }
        let board = try #require(link.client, "couldn't reach \(host.name)")
        print("pilot: connected to \(host.name) in \(Int(Date().timeIntervalSince(opening) * 1000)) ms, protocol \(board.version)")
        #expect(board.version == CoreProtocol.version)

        // Programs run on the host, found in its PATH; input reaches them.
        let system = try #require(await board.run("uname", ["-s"]))
        #expect(String(decoding: system.output, as: UTF8.self) == "Linux\n")
        let git = try #require(await board.run("git", ["--version"]))
        #expect(git.status == 0 && String(decoding: git.output, as: UTF8.self).hasPrefix("git version"))
        let echoed = try #require(await board.run("cat", [], input: Data("through the relay".utf8)))
        #expect(String(decoding: echoed.output, as: UTF8.self) == "through the relay")
        let home = String(decoding: try #require(await board.run("sh", ["-c", "printf %s \"$HOME\""])).output, as: UTF8.self)
        #expect(home.hasPrefix("/"))

        // The host's stats arrive.
        let stats = Box<HostStats?>(nil)
        board.onHost = { stats.value = $0 }
        board.subscribeToHost()
        try await waitUntil { stats.value != nil }
        let seen = try #require(stats.value)
        print("pilot: cpu \(Int(seen.cpu * 100))% memory \(seen.memoryUsed >> 20)/\(seen.memoryTotal >> 20) MiB disk \(seen.diskUsed >> 30)/\(seen.diskTotal >> 30) GiB cores \(seen.cores)")
        #expect(seen.memoryTotal > 0 && seen.diskTotal > 0 && seen.cores > 0 && (0...1).contains(seen.cpu))

        // A runner on the host, mirrored here; keys typed here echo back.
        let runner = AgentRecord(id: UUID(), worktree: home, providerID: AgentRecord.runnerProviderID, name: "pilot",
                                 frame: CGRect(x: 0, y: 0, width: 600, height: 340),
                                 runner: RunnerSpec(command: "echo ready on $(uname -n); cat", directory: home, owner: nil))
        link.send(.addCard(runner))
        let session = AgentSession(cols: 80, rows: 24)
        session.host(on: board, id: runner.id)
        link.send(.open(id: runner.id, cols: 80, rows: 24, start: true))
        func screen() -> String { session.withTerminal { $0.screenText().joined(separator: "\n") } }
        try await waitUntil { screen().contains("ready on") }
        #expect(screen().contains("ready on"), "\(screen())")

        var latencies: [Double] = []
        for index in 0..<40 {
            let mark = "k\(index)z"
            let sent = Date()
            session.send(Array((mark + "\r").utf8))
            // Each mark is typed on a row of its own (the Return), so it never wraps.
            try await waitUntil(10) { screen().contains(mark) }
            guard screen().contains(mark) else { break }
            latencies.append(Date().timeIntervalSince(sent) * 1000)
            try await Task.sleep(for: .milliseconds(50))
        }
        latencies.sort()
        #expect(latencies.count == 40, "\(screen())")
        if !latencies.isEmpty {
            print("pilot: key echo: median \(Int(latencies[latencies.count / 2])) ms, p95 \(Int(latencies[latencies.count * 95 / 100])) ms")
        }

        // A second board attaches and sees the same screen.
        let again = try #require(HostChannel.open(server: server, token: token, host: id, hostKey: key, board: pilot, addresses: addresses).channel)
        let other = try CoreClient.open(on: again).get()
        let mirror = AgentSession(cols: 80, rows: 24)
        mirror.host(on: other, id: runner.id)
        other.send(.open(id: runner.id, cols: 80, rows: 24, start: false))
        try await waitUntil { mirror.withTerminal { $0.snapshot() } == session.withTerminal { $0.snapshot() } }
        #expect(mirror.withTerminal { $0.snapshot() } == session.withTerminal { $0.snapshot() })
        other.disconnect()

        link.send(.removeCard(runner.id))

        // Six channels at once, as a page's connections: the host keeps two spares, the rest
        // are announced to it.
        let burst = Date()
        let opened = await withTaskGroup(of: Double?.self) { group -> [Double] in
            for _ in 0..<6 {
                group.addTask {
                    guard let fd = HostChannel.open(server: server, token: token, host: id, hostKey: key, board: pilot, addresses: addresses).channel else { return nil }
                    close(fd)
                    return Date().timeIntervalSince(burst) * 1000
                }
            }
            var times: [Double] = []
            for await time in group { if let time { times.append(time) } }
            return times.sorted()
        }
        print("pilot: six channels at once opened after \(opened.map { Int($0) }) ms")
        #expect(opened.count == 6)

        // A worktree on the host, as the board makes one, and a runner sandboxed in it: it
        // writes its own folder, and sees neither the other worktree nor the core's data.
        let projects = home + "/agentboard/projects"
        let clone = projects + "/pilot-\(UUID().uuidString.prefix(6))"
        func sh(_ script: String) async -> CoreClient.Ran? { await board.run("sh", ["-c", script]) }
        let cloned = try #require(await sh("mkdir -p '\(projects)' && git clone -q https://github.com/octocat/Hello-World.git '\(clone)' && git -C '\(clone)' worktree add -q -b pilot-a '\(clone)-worktrees/a' && git -C '\(clone)' worktree add -q -b pilot-b '\(clone)-worktrees/b' && echo other > '\(clone)-worktrees/b/secret'"))
        #expect(cloned.status == 0, "\(String(decoding: cloned.error, as: UTF8.self))")
        let data = String(decoding: try #require(await board.run("agentboard", ["data-folder"])).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let worktree = clone + "-worktrees/a"
        let probe = "touch mine && echo own=$?; cat ../b/secret 2>/dev/null; echo other=$?; cat '\(data)/host.json' >/dev/null 2>&1; echo data=$?; git status --short | head -3; git -c user.name=pilot -c user.email=pilot@example.invalid commit -q --allow-empty -m pilot && echo commit=ok; sleep 30"
        let boxed = AgentRecord(id: UUID(), worktree: worktree, providerID: AgentRecord.runnerProviderID, name: "boxed",
                                frame: CGRect(x: 0, y: 0, width: 600, height: 340),
                                runner: RunnerSpec(command: probe, directory: worktree, owner: nil))
        link.send(.addCard(boxed))
        let inside = AgentSession(cols: 100, rows: 24)
        inside.host(on: board, id: boxed.id)
        link.send(.open(id: boxed.id, cols: 100, rows: 24, start: true))
        func boxedScreen() -> String { inside.withTerminal { $0.screenText().joined(separator: "\n") } }
        try await waitUntil { boxedScreen().contains("commit=") || boxedScreen().contains("fatal") }
        print("pilot: in the sandbox:\n\(boxedScreen().trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(boxedScreen().contains("own=0") && boxedScreen().contains("commit=ok"), "\(boxedScreen())")
        #expect(boxedScreen().contains("other=1") || boxedScreen().contains("other=2"), "the other worktree is hidden")
        #expect(!boxedScreen().contains("data=0"), "the core's data is hidden")
        // What the board itself runs about the worktree is sandboxed too, and still works.
        let peek = try #require(await board.run("sh", ["-c", "cat '\(data)/host.json' >/dev/null 2>&1; echo data=$?; ls ../b >/dev/null 2>&1; echo sibling=$?"], in: worktree))
        #expect(String(decoding: peek.output, as: UTF8.self) == "data=1\nsibling=0\n", "\(String(decoding: peek.output, as: UTF8.self))")
        let added = try #require(await board.run("git", ["-C", clone, "worktree", "add", "-q", "-b", "pilot-c", clone + "-worktrees/c"]))
        #expect(added.status == 0, "\(String(decoding: added.error, as: UTF8.self))")
        #expect(await sh("test -f '\(clone)-worktrees/c/README'")?.status == 0, "a worktree made in the sandbox stays on the host")
        link.send(.removeCard(boxed.id))
        _ = await sh("rm -rf '\(clone)' '\(clone)-worktrees'")
        try await Task.sleep(for: .milliseconds(500))
        link.close()
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
