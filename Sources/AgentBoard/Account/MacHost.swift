import AgentRuntime
import AppKit
import Foundation

/// This Mac as a host of the account: `agentboard relay`, next to the app's executable, bridging
/// boards that the user approved here to this app's core. Runs only while signed in and wanted.
@MainActor @Observable
final class MacHost {
    struct Waiting: Decodable, Identifiable, Equatable {
        var key: String
        var name: String
        var lastSeen: Double
        var id: String { key }
        var fingerprint: String { AccountStore.fingerprint(of: key) }
    }

    /// The code the relay's own sign-in shows, until it is confirmed.
    struct SignIn: Equatable {
        var page: URL
        var code: String
    }

    private static let wantedKey = "macHostEnabled"
    private(set) var isWanted = UserDefaults.standard.bool(forKey: MacHost.wantedKey)
    private(set) var isRunning = false
    private(set) var signIn: SignIn?
    private(set) var waiting: [Waiting] = []
    private(set) var error: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var watching: Task<Void, Never>?

    /// The relay keeps its identity, its account session and its boards here (`agentboard relay`).
    nonisolated private static var folder: URL { DataFolder.url.appendingPathComponent("host") }

    /// The id this Mac registered with as a host, once it did.
    nonisolated static var hostID: UUID? {
        struct Config: Decodable { var id: UUID }
        let data = try? Data(contentsOf: folder.appendingPathComponent("host.json"))
        return data.flatMap { try? JSONDecoder().decode(Config.self, from: $0) }?.id
    }
    private static var executable: URL? { Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agentboard") }

    func setWanted(_ wanted: Bool, signedIn: Bool) {
        isWanted = wanted
        UserDefaults.standard.set(wanted, forKey: Self.wantedKey)
        if wanted, signedIn { start() } else { stop() }
    }

    /// Starts it when wanted and not running yet.
    func start() {
        guard isWanted, process == nil else { return }
        guard let executable = Self.executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            error = L("The host program isn't in this build.")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["relay", "--core", CoreProtocol.socketPath]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTBOARD_HOME"] = DataFolder.url.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in self?.heard(text) }
        }
        process.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            let status = ended.terminationStatus, reason = ended.terminationReason
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.process = nil
                self.isRunning = false
                self.signIn = nil
                if reason == .exit, status != 0 { self.error = L("The host stopped. Turn it on again to retry.") }
            }
        }
        do { try process.run() } catch {
            self.error = error.localizedDescription
            return
        }
        self.process = process
        isRunning = true
        error = nil
        watching = Task { [weak self] in
            while !Task.isCancelled {
                self?.readWaiting()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        watching?.cancel()
        watching = nil
        process?.terminate()
        process = nil
        isRunning = false
        signIn = nil
        waiting = []
    }

    /// Signing out of the account: the host signs out too, forgetting its boards, and leaves
    /// the account's hosts.
    func signOut() {
        stop()
        guard FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent("host.json").path) else { return }
        tool(["logout"])
    }

    /// Lets the board holding `key` use this Mac, as `agentboard trust` at its terminal does.
    func approve(_ board: Waiting) {
        tool(["trust", board.key])
    }

    /// `agentboard` on the host's folder, as at a host's terminal.
    private func tool(_ arguments: [String]) {
        guard let executable = Self.executable else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTBOARD_HOME"] = Self.folder.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in Task { @MainActor [weak self] in self?.readWaiting() } }
        try? process.run()
    }

    /// Lines of `agentboard relay`: `sign-in <page> <code>`, then `signed-in <login>`.
    private func heard(_ text: String) {
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ")
            if words.first == "sign-in", words.count == 3, let page = URL(string: String(words[1])), page.scheme == "https" {
                signIn = SignIn(page: page, code: String(words[2]))
            } else if words.first == "signed-in" {
                signIn = nil
            }
        }
    }

    private func readWaiting() {
        struct List: Decodable { var pending: [Waiting]? }
        let data = try? Data(contentsOf: Self.folder.appendingPathComponent("boards.json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // A board silent 5 minutes has gone, as the relay counts it.
        let now = Date().timeIntervalSince1970
        let fresh = (data.flatMap { try? decoder.decode(List.self, from: $0) }?.pending ?? []).filter { now - $0.lastSeen < 300 }
        if fresh != waiting { waiting = fresh }
    }
}
