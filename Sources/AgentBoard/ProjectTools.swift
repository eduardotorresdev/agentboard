import Connections
import Foundation
import Orchestration

/// Runs the project tools the core lists (see `ProjectRelay`): what Add Project does in the UI,
/// for an agent, in the organization of the agent's card.
@MainActor
final class ProjectTools {
    private let projects: ProjectStore
    private unowned let agents: AgentStore

    init(projects: ProjectStore, agents: AgentStore) {
        self.projects = projects
        self.agents = agents
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard let organization = agents.record(caller)?.organizationID else {
            return .error("Your card isn't on the board.")
        }
        switch name {
        case "project_list": return .text(list(in: organization))
        case "project_create": return await create(arguments, in: organization)
        default: return .error("Unknown tool “\(name)”.")
        }
    }

    private func list(in organization: UUID) -> String {
        let found = projects.projects(in: organization)
        guard !found.isEmpty else { return "No projects yet." }
        return found.map { project in
            let worktrees = (Git.worktrees(at: project.path) ?? []).map { "  - \($0.path) (\($0.branch ?? "detached"))" }
            return (["\(project.name): \(project.path)"] + worktrees).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private func create(_ arguments: [String: Any], in organization: UUID) async -> ToolResult {
        let clone = (arguments["clone"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
        let destination: URL
        if let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty {
            guard path.hasPrefix("/") || path.hasPrefix("~") else { return .error("`path` must be absolute.") }
            destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? clone.map(AddProjectDialog.repositoryName(from:))?.nonEmpty
            guard let name else { return .error("Give a `name`, a `path`, or a `clone` URL.") }
            guard !name.contains("/") else { return .error("`name` can't contain “/”; use `path` for a full folder.") }
            let location = UserDefaults.standard.string(forKey: "projectLocation") ?? AddProjectDialog.defaultLocation
            destination = URL(fileURLWithPath: location).appendingPathComponent(name)
        }
        if projects.projects(in: organization).contains(where: { $0.path == destination.path }) {
            return .text("\(destination.path) is already a project.")
        }
        let exists = FileManager.default.fileExists(atPath: destination.path)
        do {
            if exists {
                guard clone == nil else { return .error("\(destination.path) already exists: can't clone into it.") }
                guard Git.worktrees(at: destination.path) != nil else {
                    return .error("\(destination.path) exists but isn't a git repository.")
                }
            } else if let clone {
                try await Git.clone(clone, into: destination) { _ in }
            } else {
                try Git.createRepository(at: destination)
            }
        } catch {
            if clone != nil { try? FileManager.default.removeItem(at: destination) }
            return .error(error.localizedDescription)
        }
        projects.addProject(at: destination, to: organization)
        let verb = exists ? "Added" : clone != nil ? "Cloned and added" : "Created and added"
        return .text("\(verb) \(destination.path).")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
