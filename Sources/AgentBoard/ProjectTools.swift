import Connections
import Foundation
import Orchestration

/// Runs the project, worktree and host tools the core lists (see `ProjectRelay` and
/// `WorktreeTools`): what Add Project and New Worktree do in the UI, for an agent, in the
/// organization of the agent's card. One per store: `agents` is the calling agent's host's.
@MainActor
final class ProjectTools {
    private let projects: ProjectStore
    private unowned let agents: AgentStore
    private weak var hosts: HostStores?

    init(projects: ProjectStore, agents: AgentStore, hosts: HostStores? = nil) {
        self.projects = projects
        self.agents = agents
        self.hosts = hosts
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard let organization = agents.record(caller)?.organizationID else {
            return .error("Your card isn't on the board.")
        }
        switch name {
        case "project_list": return .text(list(in: organization))
        case "project_create": return await create(arguments, in: organization)
        case "worktree_set_title": return setTitle(arguments, caller: caller)
        case "worktree_create": return await createWorktree(arguments, caller: caller)
        case "worktree_remove": return await removeWorktree(arguments, caller: caller)
        case "worktree_resolve": return resolveWorktree(arguments, caller: caller)
        case "host_list": return .text(await hostList())
        default: return .error("Unknown tool “\(name)”.")
        }
    }

    /// Not listed to agents: the core asks it before starting an agent in a worktree other than
    /// its caller's (`agent_start`), since only the board knows the projects.
    private func resolveWorktree(_ arguments: [String: Any], caller: UUID) -> ToolResult {
        guard let record = agents.record(caller) else { return .error("Your card isn't on the board.") }
        let path = arguments["path"] as? String ?? ""
        let isBoard = agents.host == nil && path == MyBoard.worktree(in: record.organizationID).path
        guard isBoard || projects.project(ofWorktree: path, on: agents.host?.id, in: record.organizationID) != nil else {
            return .error("No worktree at \(path) on your host in your organization's projects. project_list shows them.")
        }
        return .text(path)
    }

    private func setTitle(_ arguments: [String: Any], caller: UUID) -> ToolResult {
        guard let record = agents.record(caller) else { return .error("Your card isn't on the board.") }
        let title = arguments["title"] as? String ?? ""
        if MyBoard.isBoard(record.worktree) { return .text("You are on the user's own board, not a worktree: only the user titles it.") }
        switch projects.setAgentTitle(title, path: record.worktree, in: record.organizationID, on: agents.host?.id) {
        case .applied: return .text("The worktree is titled “\(WorktreeTitle.clean(title) ?? title)”.")
        case .unknownWorktree: return .error("Your card's folder isn't a worktree of a project in your organization.")
        case .invalid: return .error("Give a `title` of a few visible words, other than a label the sidebar uses itself.")
        case .failed(let reason): return .error("Couldn't save the title: \(reason)")
        }
    }

    /// The account's hosts, when signed in.
    private var remoteHosts: [Host] { hosts?.account.account == nil ? [] : hosts?.account.hosts ?? [] }

    /// How long `host_list` waits for a host it wasn't connected to.
    nonisolated(unsafe) static var statsPatience: Double = 6

    private func hostList() async -> String {
        let own = { (id: UUID?) in id == self.agents.host?.id ? ", the host you run on" : "" }
        var lines = ["- This Mac (id: local, online\(own(nil)))"]
        // Every online host is asked, connecting to the ones this board had no use for yet.
        let online = remoteHosts.filter(\.online).compactMap { hosts?.store(for: $0.id) }
        let deadline = Date().addingTimeInterval(Self.statsPatience)
        while online.contains(where: { $0.hostStats == nil }), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        lines += remoteHosts.map { host in
            var line = "- \(host.name) (id: \(host.id.uuidString.lowercased()), \(host.online ? "online" : "offline"), \(host.platform)\(own(host.id)))"
            guard host.online else { return line }
            if let stats = hosts?[host.id]?.hostStats {
                let gigabytes = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
                line += ": CPU \(Int((stats.cpu * 100).rounded()))%, memory \(gigabytes(stats.memoryUsed)) of \(gigabytes(stats.memoryTotal)) GB, disk \(gigabytes(stats.diskUsed)) of \(gigabytes(stats.diskTotal)) GB"
            } else {
                line += ": stats: not connected"
            }
            return line
        }
        if hosts?.account.account == nil {
            lines.append("The user isn't signed in to an account, so there are no other hosts. They sign in from the board's top bar.")
        }
        return lines.joined(separator: "\n")
    }

    private func createWorktree(_ arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard let record = agents.record(caller) else { return .error("Your card isn't on the board.") }
        guard let branch = (arguments["branch"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty else {
            return .error("Give the `branch` to check out.")
        }
        let candidates = projects.projects(in: record.organizationID)
        let project: Project?
        if let wanted = (arguments["project"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty {
            project = candidates.first { $0.path == wanted } ?? candidates.first { $0.name == wanted }
            guard project != nil else { return .error("No project “\(wanted)” in your organization. project_list shows them.") }
        } else {
            project = projects.project(ofWorktree: record.worktree, on: agents.host?.id, in: record.organizationID)
            guard project != nil else { return .error("Your card's folder isn't a worktree of a project in your organization. Give the `project`.") }
        }
        guard let project else { return .error("Give the `project`.") }

        var host = agents.host?.id
        if let wanted = (arguments["host"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty {
            if ["local", "this mac"].contains(wanted.lowercased()) {
                host = nil
            } else if let known = remoteHosts.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) ?? remoteHosts.first(where: { $0.name == wanted }) {
                guard known.online else { return .error("\(known.name) is offline. host_list shows which hosts are online.") }
                host = known.id
            } else {
                return .error("No host “\(wanted)”. host_list shows them.")
            }
        }
        do {
            let repository = project.path
            guard let host else {
                // Off the main actor: hooks and a large checkout mustn't freeze the board.
                let created = try await Task.detached { try Git.createWorktree(branch: branch, in: repository) }.value
                projects.reload()
                return .text("Created the worktree at \(created.path) on This Mac, on \(branch)." + (created.warning.map { " git reported: \(WorktreeDraft.cause(of: $0))" } ?? ""))
            }
            let git = try await projects.gitHost(host)
            let created = try await Task.detached { try Git.createWorktree(branch: branch, in: repository, on: git) }.value
            _ = await projects.hostWorktree(at: created.path, branch: branch, on: host, in: project)
            return .text("Created the worktree at \(created.path) on \(git.name), on \(branch)." + (created.warning.map { " git reported: \(WorktreeDraft.cause(of: $0))" } ?? ""))
        } catch {
            return .error(WorktreeDraft.cause(of: error.localizedDescription))
        }
    }

    private func removeWorktree(_ arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard let record = agents.record(caller) else { return .error("Your card isn't on the board.") }
        guard let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty else {
            return .error("Give the `path` of the worktree, as project_list shows it.")
        }
        // Every worktree of the organization's projects, here and on the account's hosts; a list's first is the checkout itself.
        var found: (worktree: Worktree, project: Project, isMain: Bool)?
        for project in projects.projects(in: record.organizationID) where found == nil {
            let lists = [Git.worktrees(at: project.path) ?? []] + remoteHosts.map { projects.hostWorktrees[$0.id]?[project.path] ?? [] }
            for list in lists {
                if let index = list.firstIndex(where: { $0.path == path }) { found = (list[index], project, index == 0) }
            }
        }
        guard let found else { return .error("No worktree at \(path) in your organization's projects. project_list shows them.") }
        guard !found.isMain else { return .error("\(path) is the project's main checkout, not a worktree that can be removed.") }
        guard !(found.worktree.host == agents.host?.id && found.worktree.path == record.worktree) else {
            return .error("That is the worktree your card is in.")
        }
        let worktree = found.worktree
        if arguments["force"] as? Bool != true {
            let work: Git.PendingWork
            if let host = worktree.host {
                guard let asked = try? await projects.onHost(host, { _ in Git.pendingWork(at: path) }) else {
                    return .error("Couldn't reach the worktree's host to check for unsaved work.")
                }
                work = asked
            } else {
                work = await Task.detached { Git.pendingWork(at: path) }.value
            }
            guard work.isEmpty else {
                return .error("Kept it: it has \(work.changedFiles) changed file(s) and \(work.unpushedCommits) unpushed commit(s). Save them, or pass `force` to lose them.")
            }
        }
        do {
            try await projects.remove(worktree, from: found.project, force: arguments["force"] as? Bool == true)
            return .text("Removed the worktree at \(path). Its branch\(worktree.branch.map { " (\($0))" } ?? "") is kept.")
        } catch {
            return .error(WorktreeDraft.cause(of: error.localizedDescription))
        }
    }

    private func list(in organization: UUID) -> String {
        let found = projects.projects(in: organization)
        guard !found.isEmpty else { return "No projects yet." }
        return found.map { project in
            var worktrees = (Git.worktrees(at: project.path) ?? []).map { "  - \($0.path) (\($0.branch ?? "detached"))" }
            // Those on the account's hosts, as last listed; a host's first is its clone, not shown.
            for host in remoteHosts {
                worktrees += (projects.hostWorktrees[host.id]?[project.path] ?? []).dropFirst().map {
                    "  - \($0.path) (\($0.branch ?? "detached"), on \(host.name))"
                }
            }
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
            let location = AppDefaults.shared.string(forKey: "projectLocation") ?? AddProjectDialog.defaultLocation
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
                // Off the main actor: a commit-signing prompt mustn't freeze the board.
                try await Task.detached { try Git.createRepository(at: destination) }.value
            }
        } catch let failure as Git.InitialCommitFailed {
            // The repository exists: keep it and add it, and say what's missing.
            projects.addProject(at: destination, to: organization)
            return .text("Created and added \(destination.path), but the initial commit failed: \(failure.cause) The repository was kept; fix the problem (often commit signing) and commit there.")
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
