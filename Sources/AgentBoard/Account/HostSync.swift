import Foundation
import Orchestration

/// What makes an agent on another host behave like one here: this Mac's skills, commands,
/// subagents and instructions (from `~/.claude`), and its user-scope MCP servers (from
/// `~/.claude.json`), copied to the host's home. Only the default organization's: a host's
/// organization folders link to its `~/.claude` as they do here (docs/organizations.md).
/// `settings.json`, project-scoped MCP servers, the other agent programs' own settings,
/// logins, transcripts, history and caches never go. What an earlier sync put on the host and
/// is gone here is removed there; what the host had on its own never is.
enum HostSync {
    /// `plugins/` goes along only while it is at most this large on disk.
    static let pluginsLimit = 32 * 1024 * 1024

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What of `home`'s `.claude` goes, as paths inside `home`: the folders agents read their
    /// skills, commands and subagents from, and every instructions file at the top (`CLAUDE.md`
    /// and what it includes, like `@RTK.md`). Not `settings.json`: its hooks and status line run
    /// programs of this Mac, and would fail on every prompt there.
    static func entries(in home: URL) -> [String] {
        let claude = home.appendingPathComponent(".claude")
        var names = ["skills", "commands", "agents"]
        names += ((try? FileManager.default.contentsOfDirectory(atPath: claude.path)) ?? []).filter { $0.lowercased().hasSuffix(".md") }.sorted()
        if size(of: claude.appendingPathComponent("plugins"), upTo: pluginsLimit) != nil { names.append("plugins") }
        return names.filter { FileManager.default.fileExists(atPath: claude.appendingPathComponent($0).path) }.map { ".claude/" + $0 }
    }

    /// The bytes under `folder`, links followed; nil when it isn't there or passes `limit`.
    private static func size(of folder: URL, upTo limit: Int) -> Int? {
        guard let walker = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total > limit { return nil }
        }
        return FileManager.default.fileExists(atPath: folder.path) ? total : nil
    }

    /// What only this Mac needs, wherever it is: Finder's files, git folders, caches, `.env` files.
    private static let left: Set<String> = [".DS_Store", ".git", "__pycache__", ".env"]

    /// Every file that goes, by its path inside `home`. Links are followed: a skill linked in
    /// from elsewhere goes as its files.
    static func files(in home: URL) -> [String] {
        var found: [String] = []
        func walk(_ path: String, depth: Int) {
            let url = home.appendingPathComponent(path)
            var isFolder: ObjCBool = false
            // Deep enough for any skill, and an end to a link that leads back up.
            guard depth < 40, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
            guard isFolder.boolValue else { return found.append(path) }
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() where !left.contains(name) && !name.contains("\n") {
                walk(path + "/" + name, depth: depth + 1)
            }
        }
        entries(in: home).forEach { walk($0, depth: 0) }
        return found
    }

    /// The programs a host has under the same name, wherever they are installed here.
    private static let portable: Set<String> = ["npx", "uvx", "node", "python3", "docker"]

    /// The user's MCP servers (`mcpServers` of `~/.claude.json`, given as `config`) that can
    /// run on another host, with their `env` and `headers` as they are, and why each of the
    /// others can't, by name. A program given by its path goes when a host has it under the
    /// same name (`portable`), or when it is a tool uv installed, which `uvx` runs anywhere. A
    /// program given by name that is an npm package installed for everyone here (found in
    /// `searchPath`, the user's PATH) goes as `npx -y <package>`, which fetches it there.
    /// With `pinsFolder` (where the host will keep them), a uv tool goes held to the versions it
    /// has here, in `pins` by tool: what uv would pick today may be newer than the tool works with.
    static func servers(in config: Data, searchPath: String? = nil, pinned: Bool = false)
        -> (copied: [String: Any], skipped: [String: String], pins: [String: String]) {
        let all = ((try? JSONSerialization.jsonObject(with: config)) as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
        var copied: [String: Any] = [:], skipped: [String: String] = [:], pins: [String: String] = [:]
        for (name, value) in all {
            guard var server = value as? [String: Any] else { continue }
            if let command = server["command"] as? String, command.contains("/") {
                let program = (command as NSString).lastPathComponent
                let start = FileHandle(forReadingAtPath: command).flatMap { try? $0.read(upToCount: 512) } ?? Data()
                if portable.contains(program) {
                    server["command"] = program
                } else if let tool = uvTool(startingWith: start) {
                    server["command"] = "uvx"
                    var run = ["--from", tool.name, program]
                    let installed = packages(in: tool.environment)
                    let same = { (name: String) in name.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-") }
                    if pinned, let own = installed.first(where: { same($0.name) == same(tool.name) }) {
                        pins[tool.name] = installed.map { "\($0.name)==\($0.version)\n" }.joined()
                        // Through a shell: only the host knows where its data folder, which holds the pins, is.
                        server["command"] = "sh"
                        run = ["-c", pinnedScript, "sh", tool.name, "--from", "\(tool.name)==\(own.version)", program]
                    }
                    server["args"] = run + (server["args"] as? [Any] ?? [])
                } else {
                    // Mach-O, thin or universal.
                    let isMacBinary = [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xCE, 0xFA, 0xED, 0xFE]].contains(Array(start.prefix(4)))
                    skipped[name] = isMacBinary ? L("a program built for the Mac") : L("a program only this Mac has")
                    continue
                }
            } else if let command = server["command"] as? String, !portable.contains(command), let package = npmPackage(of: command, in: searchPath ?? loginPath) {
                server["command"] = "npx"
                server["args"] = ["-y", package] + (server["args"] as? [Any] ?? [])
            }
            copied[name] = server
        }
        return (copied, skipped, pins)
    }

    /// Runs `uvx` held to the pins a host keeps for the tool named first (`synced-pins/<tool>.txt`
    /// in its data folder: see "The vault" in docs/hosts.md), with the rest as `uvx`'s arguments.
    // shortcut: a host run as a user service, whose data folder is `~/.local/share/agentboard`; a system-wide one needs the host to say where its pins are.
    static let pinnedScript = #"tool=$1; shift; PATH="$HOME/.local/bin:$PATH"; exec uvx --constraints "${XDG_DATA_HOME:-$HOME/.local/share}/agentboard/synced-pins/$tool.txt" "$@""#

    /// What is installed in the Python environment at `environment`, from its packages' own
    /// records (`<name>-<version>.dist-info` in site-packages), by name.
    private static func packages(in environment: URL) -> [(name: String, version: String)] {
        let lib = environment.appendingPathComponent("lib")
        let pythons = ((try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []).filter { $0.hasPrefix("python") }
        return pythons.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: lib.appendingPathComponent($0 + "/site-packages").path)) ?? [] }
            .filter { $0.hasSuffix(".dist-info") }.sorted()
            .compactMap { record in
                let parts = record.dropLast(".dist-info".count).split(separator: "-", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
    }

    /// The user's PATH, asked of a login shell once per launch and only when a server needs it:
    /// that shell can take seconds to start.
    private static let loginPath = Orchestrator.loginShellPath()

    /// The npm package the command `name` belongs to, when it is one installed globally: its
    /// file in `searchPath` links into a `node_modules` folder (`…/node_modules/@scope/name/…`).
    private static func npmPackage(of name: String, in searchPath: String) -> String? {
        for folder in searchPath.split(separator: ":") {
            let file = URL(fileURLWithPath: String(folder)).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let parts = file.resolvingSymlinksInPath().pathComponents
            guard let modules = parts.lastIndex(of: "node_modules"), modules + 1 < parts.count else { return nil }
            let package = parts[modules + 1]
            return package.hasPrefix("@") && modules + 2 < parts.count ? package + "/" + parts[modules + 2] : package
        }
        return nil
    }

    /// The uv tool a script belongs to and where its environment is, from its first line
    /// (`#!…/uv/tools/<tool>/bin/python`).
    private static func uvTool(startingWith start: Data) -> (name: String, environment: URL)? {
        let line = String(decoding: start, as: UTF8.self).components(separatedBy: "\n")[0]
        guard line.hasPrefix("#!"), let tools = line.range(of: "/uv/tools/") else { return nil }
        let tool = String(line[tools.upperBound...].prefix { $0 != "/" })
        // A name that is safe as a file's on the host.
        guard !tool.isEmpty, !tool.hasPrefix("."), tool.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return nil }
        return (tool, URL(fileURLWithPath: String(line.dropFirst(2)[..<tools.upperBound])).appendingPathComponent(tool))
    }

    /// This Mac's git identity, when it has one: a host with none gets it, or agents there can't commit.
    static func gitIdentity() -> (name: String, email: String)? {
        guard let name = localGit(["config", "--global", "--get", "user.name"]), !name.isEmpty,
              let email = localGit(["config", "--global", "--get", "user.email"]), !email.isEmpty else { return nil }
        return (name, email)
    }

    /// The GitHub login of this Mac's `gh`, when it is installed and signed in: who, and the token.
    static func githubLogin() -> (user: String, token: String)? {
        func gh(_ arguments: [String]) -> String? {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["PATH": loginPath, "GH_PROMPT_DISABLED": "1"]) { $1 }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            return process.terminationStatus == 0 && !text.isEmpty ? text : nil
        }
        guard let token = gh(["auth", "token", "--hostname", "github.com"]), let user = gh(["api", "user", "-q", ".login"]) else { return nil }
        return (user, token)
    }

    private static func localGit(_ arguments: [String]) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
