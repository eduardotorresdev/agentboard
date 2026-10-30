import AgentRuntime
import Connections
import CryptoKit
import Darwin
import Foundation
import Orchestration

/// A data folder of its own, the core binary serving it, and the way agents call its tools.
final class Instance: @unchecked Sendable {
    let home: URL
    let socket: String
    let core: URL
    /// What the cores run with; set before the first starts.
    var environment: [String: String]

    init(core: URL) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abchaos-\(UUID().uuidString.prefix(8))")
        let user = home.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        socket = home.appendingPathComponent("core.sock").path
        self.core = core
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        environment["AGENTBOARD_HOME"] = home.path
        environment["AGENTBOARD_CORE_SOCKET"] = socket
        // Runners run in `$SHELL -l`: a plain sh with an empty home prints nothing of its own, so
        // what a terminal shows is exactly what its program wrote.
        environment["HOME"] = user.path
        environment["SHELL"] = "/bin/sh"
        self.environment = environment
    }

    /// Starts a core in place of the running one (or the first one), as `./run --restart-core`
    /// does; true once it serves. Blocks.
    func replaceCore() -> Bool {
        let process = Process()
        process.executableURL = core
        process.arguments = ["--take-over"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// What the cores serving this folder logged.
    var log: String { (try? String(contentsOf: home.appendingPathComponent("core.log"), encoding: .utf8)) ?? "" }

    struct Answer {
        let text: String
        let isError: Bool
    }

    /// Calls `tool` as the card `caller`, as an agent launched by the core would. Nil when no
    /// answer came: the transport failed.
    func call(_ tool: String, _ arguments: [String: Any] = [:], as caller: UUID) async -> Answer? {
        guard let port = (try? String(contentsOf: home.appendingPathComponent("tools.port"), encoding: .utf8)).flatMap({ Int($0) }),
              let key = try? Data(contentsOf: home.appendingPathComponent("tools.key")) else { return nil }
        let token = HMAC<SHA256>.authenticationCode(for: Data(caller.uuidString.utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = answer["result"] as? [String: Any] else { return nil }
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return Answer(text: text, isError: result["isError"] as? Bool ?? false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

/// A card the chaos run puts on the board.
struct Card {
    let record: AgentRecord
    let cols: Int
    let rows: Int
    var id: UUID { record.id }

    static func runner(_ name: String, _ command: String, in folder: URL, cols: Int = 100, rows: Int = 30) -> Card {
        Card(record: AgentRecord(id: UUID(), worktree: folder.path, providerID: AgentRecord.runnerProviderID, name: name,
                                 frame: CGRect(x: 0, y: 0, width: 700, height: 460),
                                 runner: RunnerSpec(command: command, directory: folder.path, owner: nil)),
             cols: cols, rows: rows)
    }
}

/// A board as the app is one, minus the drawing: mirrors every card's session, and when the
/// core goes away connects to the next one and mirrors them again.
@MainActor
final class Board {
    let link: CoreLink
    private(set) var mirrors: [UUID: AgentSession] = [:]
    private let cards: [Card]
    private var startPrograms: Bool
    /// Only watches: picks the core's sessions up as they are, at the size another board gave them.
    private let watching: Bool
    private(set) var connections = 0
    /// By connection number: the next client can reuse a client's address.
    private var hosted: [UUID: Int] = [:]

    init(socket: String, cards: [Card], startPrograms: Bool, watching: Bool = false) {
        link = CoreLink(connect: { CoreClient.open(socketPath: socket, timeout: 2) })
        link.retryInterval = 0.02
        self.cards = cards
        self.startPrograms = startPrograms
        self.watching = watching
        for card in cards { mirrors[card.id] = AgentSession(cols: card.cols, rows: card.rows) }
        link.onConnect = { [weak self] client, _, _ in self?.connected(client) }
    }

    func start() async -> Bool { await link.start() }

    /// Every mirror hosted on the connection there is now.
    var isCurrent: Bool {
        guard link.client != nil else { return false }
        return cards.allSatisfy { hosted[$0.id] == connections }
    }

    /// Goes away the way a killed board does: the socket just closes.
    func kill() { link.close() }

    private func connected(_ client: CoreClient) {
        connections += 1
        for card in cards {
            guard let mirror = mirrors[card.id] else { continue }
            hosted[card.id] = connections
            mirror.host(on: client, id: card.id)
            if watching {
                mirror.attach()
                continue
            }
            client.send(.open(id: card.id, cols: card.cols, rows: card.rows, start: startPrograms))
        }
        startPrograms = false
    }
}

/// A counter several tasks share.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var notes: [String] = []

    func add(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
    func note(_ text: String) { lock.withLock { notes.append(text) } }
    var allNotes: [String] { lock.withLock { notes } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}
