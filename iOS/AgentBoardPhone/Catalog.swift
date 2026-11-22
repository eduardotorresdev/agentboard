import AgentRuntime
import Foundation

/// Where organizations, projects and worktrees come from. Screens read only this, so the
/// source can change without touching them.
@MainActor protocol CatalogSource {
    /// Every worktree the account knows, from any host: the connected ones' git, and the catalog's
    /// list for the rest.
    func browse(_ links: [HostLink]) async -> Browse
}

struct Browse: Equatable {
    var organizations: [Organization] = []
    var worktrees: [Worktree] = []
}

struct Organization: Hashable, Identifiable {
    /// Nil when nothing says which organization a project is in (no catalog).
    let id: UUID?
    let name: String
    /// Index into the avatar palette, as on the Mac.
    var color: Int = 0
    /// Its avatar image (PNG or JPEG), when it has one.
    var image: Data? = nil
}

struct Worktree: Identifiable, Hashable {
    let path: String
    var branch: String? = nil
    /// The project's name, and its organization when the catalog knows it.
    var project: String = ""
    var organization: UUID? = nil
    /// The host it is on (lowercase id).
    var host: String = ""
    var id: String { host + ":" + path }
    var title: String { branch ?? (path as NSString).lastPathComponent }
}

/// Organization → project → worktrees, as the Mac's sidebar has them.
struct OrganizationGroup: Identifiable, Equatable {
    struct Project: Identifiable, Hashable {
        let name: String
        var worktrees: [Worktree]
        var id: String { name }
    }
    let organization: Organization
    var projects: [Project]
    var id: String { organization.id?.uuidString ?? "" }

    /// Grouped by organization then project, worktrees from every host together. Worktrees whose
    /// organization nothing names go last, under one with no id.
    static func group(_ browse: Browse) -> [OrganizationGroup] {
        let known = Set(browse.organizations.map(\.id))
        var result = browse.organizations.map { OrganizationGroup(organization: $0, projects: []) }
        for worktree in browse.worktrees {
            let key = known.contains(worktree.organization) ? worktree.organization : nil
            if !result.contains(where: { $0.organization.id == key }) {
                result.append(OrganizationGroup(organization: Organization(id: nil, name: "Other"), projects: []))
            }
            let index = result.firstIndex { $0.organization.id == key }!
            let name = worktree.project.isEmpty ? "Other folders" : worktree.project
            if let p = result[index].projects.firstIndex(where: { $0.name == name }) {
                result[index].projects[p].worktrees.append(worktree)
            } else {
                result[index].projects.append(Project(name: name, worktrees: [worktree]))
            }
        }
        for index in result.indices {
            result[index].projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for p in result[index].projects.indices {
                result[index].projects[p].worktrees.sort { ($0.title, $0.host) < ($1.title, $1.host) }
            }
        }
        return result
    }
}

/// The account's catalog (docs/catalog.md) for projects and organizations; each host's git for
/// its worktrees, so the phone doesn't depend on a Mac having listed them.
struct AccountCatalog: CatalogSource {
    let server: AccountServer

    /// The parts of `CatalogDocument` (Sources/AgentBoard/Catalog) the phone reads.
    struct Document: Decodable {
        struct Organization: Decodable { let id: UUID; let name: String; var color: Int? }
        struct Project: Decodable { let organization: UUID; let name: String; let path: String }
        struct Entry: Decodable { let project: String; let host: String; let path: String; let branch: String? }
        let organizations: [Organization]
        let projects: [Project]
        let worktrees: [Entry]
    }

    /// Nil when the server has no catalog (not deployed, or nothing written yet).
    func document() async -> Document? {
        guard let text = await get("v1/catalog")?["document"] as? String, let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(Document.self, from: data)
    }

    /// An organization's avatar image, when it has one.
    func avatar(_ organization: UUID) async -> Data? {
        (await get("v1/catalog/avatars/\(organization.uuidString.lowercased())")?["image"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// Avatar images already brought down, by organization, with their version.
    private static var avatars: [String: (version: Int, image: Data?)] = [:]

    private func get(_ path: String) async -> [String: Any]? { await getAny(path) as? [String: Any] }

    private func getAny(_ path: String) async -> Any? {
        #if DEBUG
        // `-catalogServer <url> -catalogToken <token>`: the catalog alone from another server (a
        // local `wrangler dev`) with its own session; the real token never goes there.
        if let base = DebugLaunch.value("catalogServer").flatMap(URL.init), let token = DebugLaunch.value("catalogToken") {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        #endif
        return (try? await server.call("GET", path)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    func browse(_ links: [HostLink]) async -> Browse {
        let document = await document()
        var worktrees: [Worktree] = []
        for link in links {
            if link.phase == .connected {
                worktrees += await self.worktrees(on: link, document: document)
            } else {
                // Not reachable: what the catalog last listed for it.
                worktrees += Self.listed(on: link.host.id, in: document)
            }
        }
        // Avatars by version: only the ones that changed since the last look come down again.
        var versions: [String: Int] = [:]
        if let list = await getAny("v1/catalog/avatars") as? [[String: Any]] {
            for row in list { if let id = row["organization"] as? String, let version = row["version"] as? Int { versions[id] = version } }
        }
        var organizations: [Organization] = []
        for organization in document?.organizations ?? [] {
            let key = organization.id.uuidString.lowercased()
            var image: Data?
            if let version = versions[key] {
                if let cached = Self.avatars[key], cached.version == version { image = cached.image } else {
                    image = await avatar(organization.id)
                    Self.avatars[key] = (version, image)
                }
            }
            organizations.append(Organization(id: organization.id, name: organization.name, color: organization.color ?? 0, image: image))
        }
        return Browse(organizations: organizations, worktrees: worktrees)
    }

    /// The catalog's worktrees on one host, named after their projects.
    nonisolated static func listed(on hostID: String, in document: Document?) -> [Worktree] {
        let host = hostID.lowercased()
        return (document?.worktrees ?? []).filter { $0.host.lowercased() == host }.map { entry in
            let project = document?.projects.first { $0.path == entry.project }
            return Worktree(path: entry.path, branch: entry.branch, project: project?.name ?? "", organization: project?.organization, host: host)
        }
    }

    func worktrees(on link: HostLink, document: Document?) async -> [Worktree] {
        let projects = document?.projects ?? []
        var found: [Worktree] = []
        // A host keeps its clone of a project at ~/agentboard/projects/<name>, or <name>-<hash>
        // when two repositories share a name (`GitHost.clone(of:)`). Without a catalog, every
        // clone there is a project named after its folder, in no known organization.
        let script = #"""
        if [ $# -eq 0 ]; then for d in "$HOME"/agentboard/projects/*/; do [ -d "$d" ] || continue; echo "project $(basename "$d")"; git -C "$d" worktree list --porcelain; echo; done; fi
        for p in "$@"; do for d in "$HOME/agentboard/projects/$p" "$HOME/agentboard/projects/$p"-*; do [ -d "$d" ] || continue; echo "project $p"; git -C "$d" worktree list --porcelain; echo; done; done
        """#
        let names = Array(Set(projects.map { ($0.path as NSString).lastPathComponent }))
        if document == nil || !names.isEmpty, let ran = await link.run("sh", ["-c", script, "sh"] + names), ran.status == 0 {
            found = Self.parse(String(decoding: ran.output, as: UTF8.self))
        }
        for index in found.indices {
            if let project = projects.first(where: { ($0.path as NSString).lastPathComponent == found[index].project }) {
                found[index].project = project.name
                found[index].organization = project.organization
            }
        }
        // What the host's board shows (and the catalog lists for it) that git didn't: cards in a folder outside any clone.
        let host = link.host.id.lowercased()
        for extra in Self.listed(on: host, in: document) + link.worktrees.map({ Worktree(path: $0, host: host) })
        where !found.contains(where: { $0.path == extra.path }) {
            found.append(extra)
        }
        for index in found.indices { found[index].host = host }
        return found
    }

    /// `project <name>` lines, each followed by `git worktree list --porcelain`.
    nonisolated static func parse(_ output: String) -> [Worktree] {
        var result: [Worktree] = []
        var project = ""
        for block in output.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("project ") { project = String(line.dropFirst(8)) }
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            }
            if let path, !result.contains(where: { $0.path == path }) { result.append(Worktree(path: path, branch: branch, project: project)) }
        }
        return result
    }
}
