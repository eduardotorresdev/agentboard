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
    /// Titles agents gave worktrees (see `WorktreeTitle`), keyed by worktree path.
    private(set) var agentTitles: [String: String] = [:]
    var errorMessage: String?

    let database: Database?
    /// Title writes go through their own connection on this queue, so a database another
    /// process holds locked (it waits up to the busy timeout, 3 s) never stalls the UI.
    @ObservationIgnored private let titleWriter: TitleWriter?

    /// `databaseURL`: the data folder's database by default; another in tests.
    init(databaseURL: URL? = nil) {
        do {
            let url = try databaseURL ?? Database.defaultURL()
            database = try Database(url: url)
            titleWriter = TitleWriter(url: url)
        } catch {
            database = nil
            titleWriter = nil
            errorMessage = L("Failed to open database: \(String(describing: error))")
        }
        if let stored = AppDefaults.shared.string(forKey: Self.organizationKey).flatMap(UUID.init) {
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

    /// Adds a project to `organization`, which needn't be the one shown.
    func addProject(at url: URL, to organization: UUID) {
        perform { try $0.insertProject(name: url.lastPathComponent, path: url.path, organization: organization) }
    }

    /// `organization`'s projects, read fresh from the database.
    func projects(in organization: UUID) -> [Project] {
        (try? database?.projects(in: organization)) ?? []
    }

    func removeProject(_ project: Project) {
        perform { try $0.deleteProject(id: project.id) }
    }

    /// The user's name for the worktree, else the title an agent or its creation gave it, else
    /// a fallback that never shows a branch (see `WorktreeTitle`).
    func displayName(of worktree: Worktree) -> String {
        displayName(ofPath: worktree.path)
    }

    /// The same for a worktree that may not be in the shown organization (Needs you).
    func displayName(ofPath path: String) -> String {
        WorktreeTitle.resolve(user: aliases[path], agent: agentTitles[path],
                              folder: URL(fileURLWithPath: path).lastPathComponent, isMain: isMainCheckout(path))
    }

    /// Whether `path` is a project's own checkout, in the shown organization.
    func isMainCheckout(_ path: String) -> Bool {
        worktrees.values.contains { $0.first?.path == path }
    }

    /// Whether the user named the worktree, which agents then can't retitle.
    func isNamedByUser(_ worktree: Worktree) -> Bool {
        aliases[worktree.path] != nil
    }

    /// The user named the worktree in the sidebar: the name is theirs, and agents can't replace
    /// it. An empty name hands the title back to agents.
    func rename(_ worktree: Worktree, to name: String) {
        let alias = WorktreeTitle.clean(name), path = worktree.path, before = aliases[path]
        aliases[path] = alias
        titleWriter?.write({ try $0.setAlias(alias, path: path) }) { [weak self] error in
            guard let self, aliases[path] == alias else { return }
            aliases[path] = before
            errorMessage = "\(error)"
        }
    }

    enum TitleResult: Equatable {
        case applied
        /// The user named it; their name stays.
        case keptUserTitle(String)
        case unknownWorktree
        /// Nothing visible was left once cleaned, or it would pass for a label the app shows.
        case invalid
        case failed(String)
    }

    /// The name typed when the worktree was created: its first title, which agents may refine
    /// with `worktree_set_title` (unlike a rename, it doesn't lock). `organization`: where the
    /// worktree's project is, when not the shown one.
    @discardableResult
    func setInitialTitle(_ title: String, path: String, in organization: UUID? = nil) -> TitleResult {
        setTitle(title, path: path, in: organization)
    }

    /// An agent's title for the worktree at `path` (in its card's organization), unless the user
    /// named it.
    func setAgentTitle(_ title: String, path: String, in organization: UUID? = nil) -> TitleResult {
        setTitle(title, path: path, in: organization)
    }

    private func setTitle(_ title: String, path: String, in organization: UUID?) -> TitleResult {
        guard isWorktree(path, in: organization ?? organizationID) else { return .unknownWorktree }
        guard let title = WorktreeTitle.clean(title), !WorktreeTitle.isReserved(title) else { return .invalid }
        if let user = aliases[path] { return .keptUserTitle(user) }
        guard let titleWriter else { return .failed("The app's database isn't open.") }
        let before = agentTitles[path]
        agentTitles[path] = title
        // Shown at once; a write that fails puts the old title back.
        titleWriter.write({ try $0.setWorktreeTitle(title, path: path) }) { [weak self] error in
            guard let self, agentTitles[path] == title else { return }
            agentTitles[path] = before
            errorMessage = "\(error)"
        }
        return .applied
    }

    /// Waits for the title writes sent so far (tests, before reading the database back).
    func finishTitleWrites() { titleWriter?.finish() }

    /// Whether `path` is a worktree of one of `organization`'s projects.
    private func isWorktree(_ path: String, in organization: UUID) -> Bool {
        if organization == organizationID, worktrees.values.contains(where: { $0.contains { $0.path == path } }) { return true }
        return projects(in: organization).contains { Git.worktrees(at: $0.path)?.contains { $0.path == path } == true }
    }

    /// Whether the worktree is the repository's own checkout, which can't be removed.
    func isMain(_ worktree: Worktree, in project: Project) -> Bool {
        worktrees[project.id]?.first == worktree
    }

    /// Adds a worktree on `branch` to the project and returns it.
    func addWorktree(branch: String, to project: Project) throws -> Worktree? {
        worktree(at: try Git.addWorktree(branch: branch, to: project.path), in: project)
    }

    /// The project's worktree at `path`, after rereading the project's worktrees (only this
    /// project's, which is one quick git call) so a just-added one is there.
    func worktree(at path: String, in project: Project) -> Worktree? {
        if let list = Git.worktrees(at: project.path) { worktrees[project.id] = list }
        // git reports the path resolved (e.g. /private/var for /var): match on the folder.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return worktrees[project.id]?.first {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolved
        }
    }

    func removeWorktree(_ worktree: Worktree, from project: Project, force: Bool) {
        do {
            try Git.removeWorktree(at: worktree.path, from: project.path, force: force)
            // A worktree made again at this path starts without the old one's titles.
            try? database?.forgetWorktreeNames(path: worktree.path)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    /// Saves the worktree's work to the remote, then removes it; stops at the first failure.
    func commitPushAndRemove(_ worktree: Worktree, from project: Project) {
        do {
            try Git.commitAndPush(at: worktree.path, message: "Save work before removing the worktree")
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        removeWorktree(worktree, from: project, force: false)
    }

    func reload() {
        guard let database else { return }
        do {
            organizations = try database.organizations()
            if !organizations.contains(where: { $0.id == organizationID }) { organizationID = OrganizationHome.defaultID }
            projects = try database.projects(in: organizationID)
            // Names of paths missing on disk stay: a volume may be unmounted. Only removing the
            // worktree in the app forgets them.
            aliases = try database.aliases()
            agentTitles = try database.worktreeTitles()
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
        AppDefaults.shared.set(id.uuidString, forKey: Self.organizationKey)
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

/// Writes worktree titles on a queue of its own, through a connection only that queue uses.
private final class TitleWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "worktree-titles", qos: .userInitiated)
    private let url: URL
    private var database: Database?

    init(url: URL) { self.url = url }

    /// `failed` runs on the main actor when the write throws.
    func write(_ body: @escaping (Database) throws -> Void, failed: @escaping @MainActor (Error) -> Void) {
        queue.async { [self] in
            do {
                if database == nil { database = try Database(url: url) }
                try body(database!)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { failed(error) } }
            }
        }
    }

    func finish() { queue.sync {} }
}
