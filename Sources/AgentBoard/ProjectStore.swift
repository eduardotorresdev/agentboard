import AgentRuntime
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ProjectStore {
    /// Every organization, the default one first.
    private(set) var organizations: [Organization] = []
    /// The organization whose projects are shown; kept per data folder.
    private(set) var organizationID: UUID = OrganizationHome.defaultID
    /// The current organization's projects.
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
        if let stored = UserDefaults.standard.string(forKey: Self.organizationKey).flatMap(UUID.init) {
            organizationID = stored
        }
        reload()
    }

    /// Adds the folder at `url` and returns the stored project.
    @discardableResult
    func addProject(at url: URL) -> Project? {
        perform { try $0.insertProject(name: url.lastPathComponent, path: url.path, organization: organizationID) }
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

    /// Whether the worktree is the repository's own checkout, which can't be removed.
    func isMain(_ worktree: Worktree, in project: Project) -> Bool {
        worktrees[project.id]?.first == worktree
    }

    func removeWorktree(_ worktree: Worktree, from project: Project, force: Bool) {
        do {
            try Git.removeWorktree(at: worktree.path, from: project.path, force: force)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func reload() {
        guard let database else { return }
        do {
            organizations = try database.organizations()
            if !organizations.contains(where: { $0.id == organizationID }) { organizationID = OrganizationHome.defaultID }
            projects = try database.projects(in: organizationID)
            aliases = try database.aliases()
            worktrees = projects.reduce(into: [:]) { $0[$1.id] = Git.worktrees(at: $1.path) }
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: Organizations

    private static var organizationKey: String { "organization:" + DataFolder.url.path }

    var organization: Organization? { organizations.first { $0.id == organizationID } }

    func selectOrganization(_ id: UUID) {
        guard id != organizationID else { return }
        organizationID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.organizationKey)
        reload()
    }

    /// Adds an organization signed in as `~/.claude` is, and switches to it.
    @discardableResult
    func addOrganization(named name: String) -> Organization {
        let organization = Organization(id: UUID(), name: name, color: organizations.count % OrganizationAvatar.palette.count)
        perform { try $0.saveOrganization(organization) }
        // Copying the login may ask for keychain access: off the main thread.
        Task.detached(priority: .userInitiated) { OrganizationHome.prepare(organization.id) }
        selectOrganization(organization.id)
        return organization
    }

    func updateOrganization(_ organization: Organization) {
        perform { try $0.saveOrganization(organization) }
    }

    /// Copies the image at `url` into the organization's folder and uses it as its avatar.
    func setIcon(of organization: Organization, from url: URL) {
        guard let image = NSImage(contentsOf: url), let png = image.squarePNG(side: 128) else {
            errorMessage = L("That file isn't an image.")
            return
        }
        let folder = OrganizationHome.folder(organization.id)
        // A new name each time, so the avatar doesn't show a cached old image.
        let file = folder.appendingPathComponent("icon-\(UUID().uuidString.prefix(8)).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch {
            errorMessage = "\(error)"
            return
        }
        if let old = organization.icon { try? FileManager.default.removeItem(atPath: old) }
        var updated = organization
        updated.icon = file.path
        updateOrganization(updated)
    }

    func clearIcon(of organization: Organization) {
        if let old = organization.icon { try? FileManager.default.removeItem(atPath: old) }
        var updated = organization
        updated.icon = nil
        updateOrganization(updated)
    }

    /// Removes an organization and its project list (the projects stay on disk, and its
    /// folder, with its login, stays too). The default one can't be removed.
    func removeOrganization(_ organization: Organization) {
        guard !organization.isDefault else { return }
        if organization.id == organizationID { selectOrganization(OrganizationHome.defaultID) }
        perform { try $0.deleteOrganization(id: organization.id) }
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
