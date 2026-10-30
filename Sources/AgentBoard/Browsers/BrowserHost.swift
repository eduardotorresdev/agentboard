import CryptoKit
import Foundation
import Orchestration

/// The browser sidecar: a Node process running Playwright's WebKit, shared by every browser card.
///
/// Before starting it makes sure what it needs is there, using what the machine already has:
/// Node 18 or newer from the user's PATH (otherwise an official Node build downloaded into
/// Application Support), Playwright in its own folder there, and Playwright's WebKit build in the
/// shared Playwright cache.
///
/// Requests and responses are JSON lines on the sidecar's stdin and stdout (see
/// `Resources/browser-host.mjs`).
@MainActor
final class BrowserHost {
    enum State: Equatable {
        case stopped
        case preparing(String)
        case running
        case failed(String)
    }

    private(set) var state = State.stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    /// Events the sidecar sends on its own (a page's surface, its address and title…).
    var onEvent: (([String: Any]) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var queued: [Data] = []
    private var starting = false

    nonisolated private static let playwrightVersion = "1.64.1"
    nonisolated private static let nodeLine = "latest-v24.x"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static var folder: URL {
        let base = (try? Database.defaultURL().deletingLastPathComponent())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AgentBoard")
        return base.appendingPathComponent("Browsers", isDirectory: true)
    }

    /// Starts the sidecar if it isn't running; calls made meanwhile wait for it.
    func start() {
        guard process == nil, !starting else { return }
        starting = true
        state = .preparing(L("Preparing the browser…"))
        Task {
            do {
                let launch = try await Self.prepare { [weak self] step in
                    Task { @MainActor in self?.state = .preparing(step) }
                }
                try launchSidecar(launch)
            } catch {
                state = .failed(error.localizedDescription)
                failWaiting(error)
            }
            starting = false
        }
    }

    func stop() {
        input?.closeFile()
        process = nil
        input = nil
    }

    /// Sends `method` and waits for its answer.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if case .failed(let reason) = state { throw Failure(message: reason) }
        start()
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            write(data)
        }
    }

    /// Sends `method` without waiting for an answer (the developer's input on a card).
    func post(_ method: String, _ params: [String: Any]) {
        guard state == .running || starting || process != nil else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params]) else { return }
        write(data + Data("\n".utf8))
    }

    /// Clears a failure so the next request tries again.
    func retry() {
        if case .failed = state { state = .stopped }
    }

    private func write(_ data: Data) {
        if let input, state == .running { input.write(data) } else { queued.append(data) }
    }

    // MARK: Process

    private struct Launch: Sendable {
        let node: URL
        let folder: URL
        let path: String
    }

    private func launchSidecar(_ launch: Launch) throws {
        let process = Process()
        process.executableURL = launch.node
        process.arguments = [launch.folder.appendingPathComponent("browser-host.mjs").path]
        process.currentDirectoryURL = launch.folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = launch.path
        environment["AGENTBOARD_ARTIFACTS"] = Self.folder.path
        if let injection = Self.injectionLibrary { environment["AGENTBOARD_INJECT"] = injection.path }
        // Inherited from a terminal the app was started from; WebKit must not see them.
        for key in environment.keys where key.hasPrefix("DYLD_") { environment[key] = nil }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in lines.append(chunk) {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                let message = UncheckedMessage(value: object)
                Task { @MainActor in self?.received(message.value) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { FileHandle.standardError.write(chunk) }
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
                continuation.resume(throwing: Failure(message: error))
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
        state = .failed(L("The browser stopped (status \(Int(status))). Click to start it again."))
        failWaiting(Failure(message: "The browser stopped."))
    }

    private func failWaiting(_ error: Error) {
        let pending = waiting
        waiting.removeAll()
        queued.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }

    /// Built next to the app by `swift build` (the `BrowserInjection` product).
    private static var injectionLibrary: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let library = executable.deletingLastPathComponent().appendingPathComponent("libBrowserInjection.dylib")
        return FileManager.default.fileExists(atPath: library.path) ? library : nil
    }

    // MARK: Provisioning

    /// Finds or installs Node, Playwright and WebKit, and copies the sidecar script in place.
    nonisolated private static func prepare(_ progress: @escaping @Sendable (String) -> Void) async throws -> Launch {
        let files = FileManager.default
        let folder = Self.folder.appendingPathComponent("Host", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let script = Bundle.module.url(forResource: "browser-host", withExtension: "mjs") else {
            throw Failure(message: "The browser sidecar is missing from the app.")
        }
        let installed = folder.appendingPathComponent("browser-host.mjs")
        try? files.removeItem(at: installed)
        try files.copyItem(at: script, to: installed)

        let loginPath = Orchestrator.loginShellPath()
        let node = try await findOrInstallNode(searchPath: loginPath, progress: progress)
        let path = node.deletingLastPathComponent().path + ":" + loginPath

        let manifest = folder.appendingPathComponent("node_modules/playwright-core/package.json")
        let current = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])?["version"] as? String
        if current != playwrightVersion {
            progress(L("Installing Playwright…"))
            let package = ["name": "agentboard-browser-host", "private": true, "type": "module",
                           "dependencies": ["playwright-core": playwrightVersion]] as [String: Any]
            try JSONSerialization.data(withJSONObject: package, options: .prettyPrinted)
                .write(to: folder.appendingPathComponent("package.json"))
            let npm = node.deletingLastPathComponent().appendingPathComponent("npm").resolvingSymlinksInPath()
            guard files.fileExists(atPath: npm.path) else { throw Failure(message: "npm was not found next to \(node.path).") }
            try run(node, [npm.path, "install", "--no-audit", "--no-fund", "--loglevel=error"], in: folder, path: path)
        }
        progress(L("Checking WebKit…"))
        try run(node, [folder.appendingPathComponent("node_modules/playwright-core/cli.js").path, "install", "webkit"], in: folder, path: path)
        return Launch(node: node, folder: folder, path: path)
    }

    /// Node 18 or newer from `searchPath`, else the copy this app installed, else a fresh one.
    nonisolated private static func findOrInstallNode(searchPath: String, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let candidates = searchPath.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        let own = Self.folder.appendingPathComponent("Node/bin/node")
        for node in candidates + [own] where FileManager.default.isExecutableFile(atPath: node.path) {
            if let version = output(node, ["--version"]), let major = Int(version.dropFirst().prefix { $0 != "." }), major >= 18 {
                return node
            }
        }
        progress(L("Downloading Node…"))
        try await installNode(into: own.deletingLastPathComponent().deletingLastPathComponent())
        return own
    }

    /// Downloads the current official Node 24 build for this Mac, checked against its published hash.
    nonisolated private static func installNode(into destination: URL) async throws {
        let arch = output(URL(fileURLWithPath: "/usr/bin/uname"), ["-m"])?.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" ? "arm64" : "x64"
        let base = URL(string: "https://nodejs.org/dist/\(nodeLine)/")!
        let (sums, _) = try await URLSession.shared.data(from: base.appendingPathComponent("SHASUMS256.txt"))
        guard let line = String(decoding: sums, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix("-darwin-\(arch).tar.gz") }),
              let hash = line.split(separator: " ").first, let name = line.split(separator: " ").last else {
            throw Failure(message: "Couldn't find a Node build for this Mac.")
        }
        let (archive, _) = try await URLSession.shared.download(from: base.appendingPathComponent(String(name)))
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        guard digest == hash else { throw Failure(message: "The downloaded Node didn't match its published checksum.") }
        let files = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent("Node-download")
        try? files.removeItem(at: staging)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path, "--strip-components", "1"], in: staging, path: "/usr/bin:/bin")
        try? files.removeItem(at: destination)
        try files.moveItem(at: staging, to: destination)
    }

    nonisolated private static func run(_ executable: URL, _ arguments: [String], in directory: URL, path: String) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: message, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            throw Failure(message: "\(executable.lastPathComponent) \(arguments.dropFirst().first ?? "") failed: \(detail)")
        }
    }

    nonisolated private static func output(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// JSON from the sidecar, handed from the reading thread to the main actor.
private struct UncheckedMessage: @unchecked Sendable {
    let value: [String: Any]
}

/// Splits the sidecar's output into lines; only its pipe's reading thread touches it.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }
}
