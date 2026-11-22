import AgentRuntime
import Foundation

/// Where organizations, projects and worktrees come from. Screens read only this, so the
/// source can change without touching them.
@MainActor protocol CatalogSource {
    func worktrees(on link: HostLink) async -> [Worktree]
}

struct Worktree: Identifiable, Hashable {
    let path: String
    var branch: String? = nil
    /// The project's name, and its organization's when the catalog knows it.
    var project: String = ""
    var organization: String? = nil
    var id: String { path }
    var title: String { branch ?? (path as NSString).lastPathComponent }
}

/// The account's catalog (docs/catalog.md) for projects and organizations; each host's git for
/// its worktrees, so the phone doesn't depend on a Mac having listed them.
struct AccountCatalog: CatalogSource {
    let server: AccountServer

    /// The parts of `CatalogDocument` (Sources/AgentBoard/Catalog) the phone reads.
    struct Document: Decodable {
        struct Organization: Decodable { let id: UUID; let name: String }
        struct Project: Decodable { let organization: UUID; let name: String; let path: String }
        struct Entry: Decodable { let project: String; let host: String; let path: String; let branch: String? }
        let organizations: [Organization]
        let projects: [Project]
        let worktrees: [Entry]
    }

    func document() async -> Document? {
        guard let reply = try? JSONSerialization.jsonObject(with: await server.call("GET", "v1/catalog")) as? [String: Any],
              let text = reply["document"] as? String, let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(Document.self, from: data)
    }

    func worktrees(on link: HostLink) async -> [Worktree] {
        let document = await document()
        let projects = document?.projects ?? []
        var found: [Worktree] = []
        // A host keeps its clone of a project at ~/agentboard/projects/<name>, or <name>-<hash>
        // when two repositories share a name (`GitHost.clone(of:)`).
        let script = #"for p in "$@"; do for d in "$HOME/agentboard/projects/$p" "$HOME/agentboard/projects/$p"-*; do [ -d "$d" ] || continue; echo "project $p"; git -C "$d" worktree list --porcelain; echo; done; done"#
        let names = Array(Set(projects.map { ($0.path as NSString).lastPathComponent }))
        if !names.isEmpty, let ran = await link.run("sh", ["-c", script, "sh"] + names), ran.status == 0 {
            found = Self.parse(String(decoding: ran.output, as: UTF8.self))
        }
        // Named as the catalog names them.
        let organizations = Dictionary((document?.organizations ?? []).map { ($0.id, $0.name) }) { a, _ in a }
        for index in found.indices {
            if let project = projects.first(where: { ($0.path as NSString).lastPathComponent == found[index].project }) {
                found[index].project = project.name
                found[index].organization = organizations[project.organization]
            }
        }
        // What the host's board shows (and the catalog lists for it) that git didn't: cards in a folder outside any clone.
        let host = link.host.id.lowercased()
        let listed = (document?.worktrees ?? []).filter { $0.host.lowercased() == host }.map { Worktree(path: $0.path, branch: $0.branch) }
        for extra in listed + link.worktrees.map({ Worktree(path: $0) }) where !found.contains(where: { $0.path == extra.path }) {
            found.append(extra)
        }
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
