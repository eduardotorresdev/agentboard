import AgentRuntime
import Connections
import Foundation
import Orchestration

/// Runners: commands the board keeps running in a terminal card (dev servers, watchers, workers),
/// started by the developer or by an agent through the runner tools. The core runs and measures
/// them; the board shows what each serves (ports, with the network address when other devices can
/// reach it) and costs (CPU, memory).
extension AgentStore {
    var runnerStats: [UUID: RunnerStats] { runnerReport.stats }
    /// When each runner last started, while the core has run it.
    var runnerStarts: [UUID: Date] { runnerReport.starts }

    func runners(in worktree: String) -> [AgentRecord] {
        agents.filter { $0.worktree == worktree && $0.runner != nil }
    }

    /// Adds a runner card; it starts once the board shows it.
    @discardableResult
    func addRunner(command: String, name: String?, directory: String?, to worktree: String, at origin: CGPoint) -> AgentRecord {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = trimmed.isEmpty ? AgentRecord.runnerName(for: command) : trimmed
        let record = AgentRecord(id: UUID(), worktree: worktree, providerID: AgentRecord.runnerProviderID,
                                 name: AgentRecord.uniqueName(base, among: agents(in: worktree)),
                                 frame: CGRect(origin: origin, size: AgentRecord.runnerSize),
                                 runner: RunnerSpec(command: command, directory: directory ?? worktree, owner: nil))
        runnersToStart.insert(record.id)
        insert(record)
        return record
    }

    /// Starts a runner that isn't running.
    func startRunner(_ id: UUID) {
        send(.startRunner(id))
    }

    /// Stops a runner and everything it started.
    func stopRunner(_ id: UUID) {
        send(.stopRunner(id))
    }

    /// Stops the runner if it runs and starts it again, with `command` instead when given.
    func restartRunner(_ id: UUID, command: String? = nil) {
        send(.restart(id: id, command: command))
    }

    /// The addresses a runner serves, in port order: `localhost`, then the network address
    /// when the port is open to other devices.
    func urls(of id: UUID) -> [(local: String, network: String?)] {
        (runnerStats[id]?.ports ?? []).map { port in
            ("http://localhost:\(port.port)", port.exposed ? runnerReport.networkAddress.map { "http://\($0):\(port.port)" } : nil)
        }
    }
}
