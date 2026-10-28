import Foundation
import Observation

@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    /// Worktrees per project; a missing entry means the project path is not a git repository.
    private(set) var worktrees: [Project.ID: [Worktree]] = [:]
    /// User-given names for worktrees, keyed by worktree path.
    private(set) var aliases: [String: String] = [:]
    var errorMessage: String?

    let database: Database?

    init() {
        do {
            database = try Database(url: Database.defaultURL())
        } catch {
            database = nil
            errorMessage = L("Failed to open database: \(String(describing: error))")
        }
        reload()
    }

    /// Adds the folder at `url` and returns the stored project.
    @discardableResult
    func addProject(at url: URL) -> Project? {
        perform { try $0.insertProject(name: url.lastPathComponent, path: url.path) }
        return projects.first { $0.path == url.path }
    }

    func removeProject(_ project: Project) {
        perform { try $0.deleteProject(id: project.id) }
    }

    /// The worktree's alias, or its folder name when it has none.
    func displayName(of worktree: Worktree) -> String {
        aliases[worktree.path] ?? worktree.name
    }

    /// Renames a worktree inside the app only; an empty name goes back to the folder name.
    func rename(_ worktree: Worktree, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = trimmed.isEmpty || trimmed == worktree.name ? nil : trimmed
        perform { try $0.setAlias(alias, path: worktree.path) }
    }

    func reload() {
        guard let database else { return }
        do {
            projects = try database.projects()
            aliases = try database.aliases()
            worktrees = projects.reduce(into: [:]) { $0[$1.id] = Git.worktrees(at: $1.path) }
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func perform(_ change: (Database) throws -> Void) {
        guard let database else { return }
        do {
            try change(database)
        } catch {
            errorMessage = "\(error)"
        }
        reload()
    }
}
