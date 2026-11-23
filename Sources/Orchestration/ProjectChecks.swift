import Foundation

/// What a request from another device (the phone) may make on this host: a project folder
/// inside the projects folder, cloned only from https or ssh. The same rules and reasons as the
/// Rust core's `projects` module, held to the shared cases in `core/fixtures/projects`.
package enum ProjectChecks {
    /// A folder name for a new project: one plain component, never one that climbs out.
    package static func name(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the project a name." }
        if name == "." || name == ".." || name.contains("/") || name.contains("\\") || name.contains("\0") {
            return "A project name is one folder name: no “/”, and not “.” or “..”."
        }
        if name.hasPrefix("-") || name.hasPrefix(".") || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            || name.utf8.count > 255 {
            return "A project name can't start with “-” or “.”, nor hold control characters."
        }
        return nil
    }

    /// A repository URL to clone: `https://…`, `ssh://…` or the scp form (`git@host:owner/repo`).
    /// Anything else (`file://`, `ext::`, a local path, an option) could run or read things here.
    package static func cloneURL(_ url: String) -> String? {
        let refused = "Clone from an https or ssh URL (https://…, ssh://… or git@host:owner/repo)."
        if url.isEmpty || url.hasPrefix("-") || url.contains("::")
            || url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return refused
        }
        let rest: Substring
        if url.hasPrefix("https://") {
            rest = url.dropFirst("https://".count)
        } else if url.hasPrefix("ssh://") {
            rest = url.dropFirst("ssh://".count)
        } else if let colon = url.firstIndex(of: ":") {
            // scp form: user@host:path, with no "/" before the colon (else it's a local path).
            let userHost = url[..<colon], path = url[url.index(after: colon)...]
            if userHost.contains("/") || !userHost.contains("@") || path.isEmpty || path.hasPrefix("//") { return refused }
            rest = userHost
        } else {
            return refused
        }
        let hostPart = rest.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == ":" }).first ?? ""
        let host = hostPart.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        if host.isEmpty || host.hasPrefix("-") { return refused }
        return nil
    }

    /// The folder name a clone of `url` takes: its last component, less `.git`.
    package static func repositoryName(_ url: String) -> String {
        var trimmed = Substring(url)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let last = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// `path`, resolved through any links that exist, only if it lies inside `projects`.
    package static func inside(_ projects: URL, _ path: String) -> Result<URL, ProjectRefusal> {
        let outside = ProjectRefusal("\(path) isn't inside the projects folder.")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else { return .failure(outside) }
        let root = projects.resolvingSymlinksInPath().standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: root) else { return .failure(ProjectRefusal("The projects folder \(projects.path) isn't there.")) }
        // The deepest part that exists is resolved; what doesn't exist yet can't be a link.
        var existing = URL(fileURLWithPath: path)
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            guard existing.path != "/" else { return .failure(outside) }
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for name in missing { resolved.appendPathComponent(name) }
        let full = resolved.standardizedFileURL.path
        guard full != root, full.hasPrefix(root + "/") else { return .failure(outside) }
        return .success(URL(fileURLWithPath: full))
    }
}

package struct ProjectRefusal: Error, Equatable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// Projects and worktrees made for a board that can't run git (the phone), with the checks
/// above, by the same git functions the app uses. Off the main actor: git can take a while.
package enum ProjectMaker {
    /// `~/agentboard/projects`, where the app makes projects too.
    package static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("agentboard/projects")
    }

    /// Makes project `name` (or the clone's name) in `projects`: a clone of `clone`, or a new
    /// repository on main with a first commit. A folder it made is removed when making it
    /// fails; one that was there is never touched.
    package static func project(in projects: URL, name: String?, clone: String?) async -> Result<String, ProjectRefusal> {
        if let clone, let problem = ProjectChecks.cloneURL(clone) { return .failure(ProjectRefusal(problem)) }
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = given.flatMap({ $0.isEmpty ? nil : $0 }) ?? clone.map(ProjectChecks.repositoryName) else {
            return .failure(ProjectRefusal("Give a name, or a URL to clone."))
        }
        if let problem = ProjectChecks.name(name) { return .failure(ProjectRefusal(problem)) }
        do {
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        } catch {
            return .failure(ProjectRefusal("Can't make the projects folder: \(error.localizedDescription)"))
        }
        let destination: URL
        switch ProjectChecks.inside(projects, projects.appendingPathComponent(name).path) {
        case .success(let url): destination = url
        case .failure(let refusal): return .failure(refusal)
        }
        if FileManager.default.fileExists(atPath: destination.path) { return .failure(ProjectRefusal("\(destination.path) already exists.")) }
        do {
            if let clone {
                try await Git.clone(clone, into: destination) { _ in }
            } else {
                try await Task.detached { try Git.createRepository(at: destination) }.value
            }
        } catch let failure as Git.InitialCommitFailed {
            return .failure(ProjectRefusal("Created \(destination.path), but the first commit failed: \(failure.cause) The repository was kept; fix the problem (often commit signing) and commit there."))
        } catch {
            // createRepository removes a folder it made; a failed clone leaves one behind.
            if clone != nil { try? FileManager.default.removeItem(at: destination) }
            return .failure(ProjectRefusal((error as? GitError)?.message ?? error.localizedDescription))
        }
        return .success(destination.path)
    }

    /// Adds a worktree on `branch` to the project at `repository` (inside `projects`), with
    /// the branch rule and undo of `Git.createWorktree`.
    package static func worktree(in projects: URL, repository: String, branch: String) async -> Result<String, ProjectRefusal> {
        let resolved: URL
        switch ProjectChecks.inside(projects, repository) {
        case .success(let url): resolved = url
        case .failure(let refusal): return .failure(refusal)
        }
        guard FileManager.default.fileExists(atPath: resolved.appendingPathComponent(".git").path) else {
            return .failure(ProjectRefusal("\(resolved.path) isn't a project's repository."))
        }
        guard !branch.isEmpty, !branch.hasPrefix("-"), Git.isValidBranchName(branch) else {
            return .failure(ProjectRefusal("“\(branch)” isn't a valid branch name."))
        }
        let location = Git.worktreeLocation(for: branch, in: resolved.path)
        if case .failure(let refusal) = ProjectChecks.inside(projects, location.path) { return .failure(refusal) }
        if FileManager.default.fileExists(atPath: location.path) { return .failure(ProjectRefusal("\(location.path) already exists.")) }
        return await Task.detached {
            do {
                return .success(try Git.createWorktree(branch: branch, in: resolved.path).path)
            } catch {
                return .failure(ProjectRefusal((error as? GitError)?.message ?? error.localizedDescription))
            }
        }.value
    }
}
