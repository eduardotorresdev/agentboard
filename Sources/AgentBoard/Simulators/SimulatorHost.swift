import Foundation

/// The simulator sidecar (`simulator-host`, built next to the app): one process for every
/// simulator card, started with the first one. It is the only code that loads Apple's private
/// simulator frameworks, so an Xcode change or a crash there never takes the app down.
///
/// Requests and responses are JSON lines on its stdin and stdout, like `BrowserHost`'s.
@MainActor
final class SimulatorHost {
    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    private(set) var state = State.stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    /// Events the sidecar sends on its own (a card's screen surface).
    var onEvent: (([String: Any]) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var queued: [Data] = []

    struct Failure: LocalizedError {
        let message: String
        /// What kind of failure, for the card's state: `noXcode`, `noRuntime`, or nil.
        var code: String?
        var errorDescription: String? { message }
    }

    /// Where screenshots go.
    nonisolated static var folder: URL {
        let base = (try? Database.defaultURL().deletingLastPathComponent())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AgentBoard")
        return base.appendingPathComponent("Simulators", isDirectory: true)
    }

    func start() {
        guard process == nil else { return }
        do {
            try launch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Sends `method` and waits for its answer.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if case .failed(let reason) = state { throw Failure(message: reason) }
        start()
        let id = nextID
        nextID += 1
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data("\n".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            write(data)
        }
    }

    /// Sends input without waiting: a drag must go as fast as the pointer.
    func post(_ method: String, _ params: [String: Any]) {
        guard process != nil, let data = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]) else { return }
        write(data + Data("\n".utf8))
    }

    /// Clears a failure so the next request starts the sidecar again.
    func retry() {
        if case .failed = state { state = .stopped }
    }

    private func write(_ data: Data) {
        if let input, state == .running { input.write(data) } else { queued.append(data) }
    }

    private func launch() throws {
        // AGENTBOARD_SIMULATOR_HOST: a build's own, for runs whose main executable isn't the app's (tests).
        let override = ProcessInfo.processInfo.environment["AGENTBOARD_SIMULATOR_HOST"].map(URL.init(fileURLWithPath:))
        guard let executable = override ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("simulator-host"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure(message: L("The simulator helper is missing from the app."))
        }
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("DYLD_") { environment[key] = nil }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let lines = SidecarLines()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in lines.append(chunk) {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                let message = UncheckedMessage(value: object)
                Task { @MainActor in self?.received(message.value) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.exited(process, status: status) }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
    }

    private func received(_ message: [String: Any]) {
        if let id = message["id"] as? Int, let continuation = waiting.removeValue(forKey: id) {
            if let error = message["error"] as? String {
                continuation.resume(throwing: Failure(message: error, code: message["code"] as? String))
            } else {
                continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
            return
        }
        if message["event"] as? String == "ready" {
            state = .running
            let pending = queued
            queued.removeAll()
            pending.forEach { input?.write($0) }
            return
        }
        onEvent?(message)
    }

    private func exited(_ ended: Process, status: Int32) {
        guard ended === process else { return }
        process = nil
        input = nil
        queued.removeAll()
        state = .failed(L("The simulator helper stopped (status \(Int(status))). Click to start it again."))
        let pending = waiting
        waiting.removeAll()
        pending.values.forEach { $0.resume(throwing: Failure(message: "The simulator helper stopped.")) }
    }
}
