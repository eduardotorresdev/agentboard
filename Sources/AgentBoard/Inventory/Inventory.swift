import AgentRuntime
import Foundation

/// What the agents have configured today, read from their own files. Read-only: nothing here
/// ever writes a config file or a skills folder.
enum Inventory {
    enum Agent: String, CaseIterable, Identifiable {
        case claude = "Claude Code"
        case codex = "Codex"
        var id: String { rawValue }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case machine, organization, project
        var id: String { rawValue }
    }

    struct Server: Identifiable, Equatable {
        var name: String
        /// The command line or URL it reaches the server by.
        var target: String
        /// Names of env vars and headers; their values are never read into the app.
        var secretKeys: [String]
        var source: String
        var id: String { source + "#" + name }
    }

    struct Skill: Identifiable, Equatable {
        var name: String
        var summary: String
        var source: String
        var id: String { source }
    }

    struct Entry: Equatable {
        var servers: [Server] = []
        var skills: [Skill] = []
    }

    /// Everything found, by agent and scope.
    typealias Snapshot = [Agent: [Scope: Entry]]

    // MARK: Parsers

    /// MCP servers in a Claude JSON file: top-level `mcpServers`, and when `project` is given,
    /// the ones `~/.claude.json` keeps under `projects.<path>.mcpServers` (local scope).
    static func claudeServers(json: Data, project: String? = nil, source: String) -> [Server] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        let table: Any?
        if let project {
            table = ((root["projects"] as? [String: Any])?[project] as? [String: Any])?["mcpServers"]
        } else {
            table = root["mcpServers"]
        }
        guard let servers = table as? [String: Any] else { return [] }
        return servers.keys.sorted().map { name in
            let spec = servers[name] as? [String: Any] ?? [:]
            let command = ([spec["command"] as? String].compactMap { $0 } + (spec["args"] as? [String] ?? []))
                .joined(separator: " ")
            let target = (spec["url"] as? String) ?? command
            let keys = ((spec["env"] as? [String: Any])?.keys.map { $0 } ?? [])
                + ((spec["headers"] as? [String: Any])?.keys.map { $0 } ?? [])
            return Server(name: name, target: target, secretKeys: keys.sorted(), source: source)
        }
    }

    /// MCP servers in a Codex `config.toml`: the `[mcp_servers.<name>]` tables.
    /// shortcut: a line-based reader covering the documented keys (strings, string arrays,
    /// inline tables, `.env` / `.http_headers` subtables); swap for a TOML library if it misreads.
    static func codexServers(toml: String, source: String) -> [Server] {
        var order: [String] = []
        var servers: [String: Server] = [:]
        var current: String?
        var subtable: String?

        func server(_ name: String) -> Server {
            servers[name] ?? Server(name: name, target: "", secretKeys: [], source: source)
        }

        for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let parts = splitDotted(header)
                current = nil; subtable = nil
                guard parts.count >= 2, parts[0] == "mcp_servers" else { continue }
                current = parts[1]
                subtable = parts.count > 2 ? parts[2] : nil
                if servers[parts[1]] == nil { order.append(parts[1]); servers[parts[1]] = server(parts[1]) }
                continue
            }
            guard let name = current, let equals = line.firstIndex(of: "=") else { continue }
            let key = unquote(line[..<equals].trimmingCharacters(in: .whitespaces))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            var entry = server(name)
            if subtable == "env" || subtable == "http_headers" || subtable == "env_http_headers" {
                entry.secretKeys.append(key)
            } else {
                switch key {
                case "command": entry.target = unquote(value) + entry.target
                case "args": entry.target += quoted(value).map { " " + $0 }.joined()
                case "url": entry.target = unquote(value)
                case "env", "http_headers", "env_http_headers": entry.secretKeys += inlineTableKeys(value)
                case "bearer_token_env_var": entry.secretKeys.append("Authorization")
                default: break
                }
            }
            servers[name] = entry
        }
        return order.compactMap { name in
            servers[name].map { var s = $0; s.secretKeys.sort(); return s }
        }
    }

    /// A skill's name and description from its `SKILL.md` frontmatter; the folder name when
    /// it has no `name`.
    static func skill(markdown: String, folder: String, source: String) -> Skill {
        var name = folder
        var summary = ""
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
                if line.hasPrefix("name:") { name = unquote(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                if line.hasPrefix("description:") {
                    summary = unquote(String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return Skill(name: name.isEmpty ? folder : name, summary: summary, source: source)
    }

    private static func splitDotted(_ text: String) -> [String] {
        var parts: [String] = []
        var part = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { part.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(part.trimmingCharacters(in: .whitespaces)); part = ""
            } else {
                part.append(character)
            }
        }
        parts.append(part.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static func unquote(_ text: String) -> String {
        var value = text
        if let hash = value.range(of: " #"), !value.hasPrefix("\"") { value = String(value[..<hash.lowerBound]) }
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            return String(value.dropFirst().dropLast())
        }
        if value.first == "\"", let end = value.dropFirst().firstIndex(of: "\"") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        return value
    }

    /// Keys of `{ A = "x", "B" = "y" }`; values are skipped.
    private static func inlineTableKeys(_ value: String) -> [String] {
        let body = value.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        var keys: [String] = []
        for pair in body.split(separator: ",") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            keys.append(unquote(pair[..<equals].trimmingCharacters(in: .whitespaces)))
        }
        return keys
    }

    private static func quoted(_ text: String) -> [String] {
        var results: [String] = []
        var current: String?
        var open: Character = "\""
        for character in text {
            if current != nil {
                if character == open { results.append(current!); current = nil } else { current!.append(character) }
            } else if character == "\"" || character == "'" {
                open = character; current = ""
            }
        }
        return results
    }

    // MARK: Reading the files

    /// Reads every location; call off the main thread.
    static func load(organization: UUID, project: String?) -> Snapshot {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let userClaude = home.appendingPathComponent(".claude")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let managed = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
        let plugins = claudePlugins(userClaude)

        var claude: [Scope: Entry] = [:]
        claude[.machine] = Entry(
            servers: servers(home.appendingPathComponent(".claude.json"))
                + servers(managed.appendingPathComponent("managed-mcp.json"))
                + plugins.filter { $0.project == nil }.flatMap { servers($0.root.appendingPathComponent(".mcp.json")) },
            skills: skills(in: userClaude.appendingPathComponent("skills"))
                + skills(in: managed.appendingPathComponent(".claude/skills"))
                + plugins.filter { $0.project == nil }.flatMap { skills(in: $0.root.appendingPathComponent("skills")) }
        )
        var organizationEntry = Entry()
        if let folder = OrganizationHome.claudeDirectory(organization) {
            organizationEntry.servers = servers(folder.appendingPathComponent(".claude.json"))
            // Only skills the organization keeps itself; a link to `~/.claude/skills` is machine scope.
            let own = folder.appendingPathComponent("skills")
            if (try? files.destinationOfSymbolicLink(atPath: own.path)) == nil {
                organizationEntry.skills = skills(in: own)
            }
        }
        claude[.organization] = organizationEntry
        var codex: [Scope: Entry] = [
            .machine: Entry(servers: codexServers(codexHome.appendingPathComponent("config.toml")),
                            skills: skills(in: home.appendingPathComponent(".agents/skills"))
                                + skills(in: URL(fileURLWithPath: "/etc/codex/skills"))),
            .organization: Entry(),
        ]

        if let project {
            let root = URL(fileURLWithPath: project)
            // Local scope lives in whichever `.claude.json` the organization's agents use.
            let account = (OrganizationHome.claudeDirectory(organization) ?? home)
                .appendingPathComponent(".claude.json")
            let projectPlugins = plugins.filter { $0.project == project }
            claude[.project] = Entry(
                servers: servers(account, project: project)
                    + servers(root.appendingPathComponent(".mcp.json"))
                    + projectPlugins.flatMap { servers($0.root.appendingPathComponent(".mcp.json")) },
                skills: skills(in: root.appendingPathComponent(".claude/skills"))
                    + projectPlugins.flatMap { skills(in: $0.root.appendingPathComponent("skills")) }
            )
            codex[.project] = Entry(servers: codexServers(root.appendingPathComponent(".codex/config.toml")),
                                    skills: skills(in: root.appendingPathComponent(".agents/skills")))
        }
        return [.claude: claude, .codex: codex]
    }

    private static func servers(_ url: URL, project: String? = nil) -> [Server] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return claudeServers(json: data, project: project, source: url.path)
    }

    private static func codexServers(_ url: URL) -> [Server] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return codexServers(toml: text, source: url.path)
    }

    private static func skills(in folder: URL) -> [Skill] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            let file = folder.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return skill(markdown: text, folder: name, source: file.path)
        }
    }

    /// Installed Claude Code plugins: where each lives, and the project it's limited to.
    private static func claudePlugins(_ userClaude: URL) -> [(root: URL, project: String?)] {
        let file = userClaude.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: [[String: Any]]] else { return [] }
        return plugins.values.flatMap { $0 }.compactMap { install in
            guard let path = install["installPath"] as? String else { return nil }
            let scope = install["scope"] as? String
            return (URL(fileURLWithPath: path), scope == "user" ? nil : install["projectPath"] as? String)
        }
    }
}
