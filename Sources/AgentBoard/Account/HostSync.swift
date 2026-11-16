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
    /// The largest archive sent: what one `run` carries (see docs/hosts.md).
    static let archiveLimit = HostMediaFailure.maximumBytes

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

    /// A gzipped tar of `entries(in:)`, to unpack in the host's home; nil when there is nothing
    /// to send. Links are followed (a skill linked in from elsewhere goes as its files), and
    /// what only this Mac needs stays: Finder's files, git folders, caches, `.env` files.
    static func archive(of home: URL) throws -> Data? {
        let entries = entries(in: home)
        guard !entries.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // To a file: written to a pipe, tar pads the archive with zeros past its end.
        let packed = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-sync-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: packed) }
        process.arguments = ["-czLf", packed.path, "--no-mac-metadata", "--no-xattrs"]
            + [".DS_Store", ".git", "__pycache__", ".env"].flatMap { ["--exclude", $0] } + ["-C", home.path] + entries
        // No `._name` companions either.
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // tar says 1 for a file it couldn't read (a dangling link): the rest still goes.
        guard process.terminationStatus <= 1, let data = try? Data(contentsOf: packed), !data.isEmpty else {
            throw Failure(message: L("Couldn't pack the skills to send."))
        }
        guard data.count <= archiveLimit else {
            throw Failure(message: L("The skills are larger than \(archiveLimit / 1024 / 1024) MB packed: too large to send."))
        }
        return data
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
    static func servers(in config: Data, searchPath: String = Orchestrator.loginShellPath(), pinsFolder: String? = nil)
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
                    if let pinsFolder, let own = installed.first(where: { same($0.name) == same(tool.name) }) {
                        pins[tool.name] = installed.map { "\($0.name)==\($0.version)\n" }.joined()
                        run = ["--constraints", pinsFolder + "/" + tool.name + ".txt", "--from", "\(tool.name)==\(own.version)", program]
                    }
                    server["args"] = run + (server["args"] as? [Any] ?? [])
                } else {
                    // Mach-O, thin or universal.
                    let isMacBinary = [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xCE, 0xFA, 0xED, 0xFE]].contains(Array(start.prefix(4)))
                    skipped[name] = isMacBinary ? L("a program built for the Mac") : L("a program only this Mac has")
                    continue
                }
            } else if let command = server["command"] as? String, !portable.contains(command), let package = npmPackage(of: command, in: searchPath) {
                server["command"] = "npx"
                server["args"] = ["-y", package] + (server["args"] as? [Any] ?? [])
            }
            copied[name] = server
        }
        return (copied, skipped, pins)
    }

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

    /// Run on the host with python3: merges the servers on its stdin (`{name: server}`) into
    /// `mcpServers` of the file named first (made if missing; its other keys are left alone),
    /// keeping in the file named second the names it put there. A server the host already had
    /// under a name is kept unless an earlier sync put it there; one synced before that is no
    /// longer sent is removed. Prints `{"kept": [names]}`. A file that isn't JSON stops it.
    /// Its stdin is `{"servers": {name: server}, "pins": {tool: text}}`: each tool's pins go to
    /// `<tool>.txt` in the folder named third, which holds nothing else, so one no longer sent
    /// is removed.
    static let mergeScript = """
        import json, os, sys
        config, marks, pinned = sys.argv[1], sys.argv[2], sys.argv[3]
        def load(path, empty):
            try:
                with open(path) as file: return json.load(file)
            except FileNotFoundError: return empty
        def save(path, value):
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(os.open(path + ".sync", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file: json.dump(value, file, indent=2)
            os.replace(path + ".sync", path)
        given = json.load(sys.stdin)
        sent, pins = given["servers"], given["pins"]
        os.makedirs(pinned, exist_ok=True)
        for old in os.listdir(pinned):
            if old[:-4] not in pins: os.remove(os.path.join(pinned, old))
        for tool in pins:
            with open(os.path.join(pinned, tool + ".txt"), "w") as file: file.write(pins[tool])
        whole, synced = load(config, {}), set(load(marks, []))
        if not isinstance(whole, dict): sys.exit("not a JSON object: " + config)
        servers = whole.get("mcpServers")
        if not isinstance(servers, dict): servers = whole["mcpServers"] = {}
        for name in synced - set(sent): servers.pop(name, None)
        kept = sorted(name for name in sent if name in servers and name not in synced)
        for name in sent:
            if name not in kept: servers[name] = sent[name]
        save(config, whole)
        save(marks, sorted(set(sent) - set(kept)))
        print(json.dumps({"kept": kept}))
        """

    /// What a sync did, for the host's row in the account menu.
    struct Outcome: Equatable {
        /// MCP servers put on the host whose program it has. That they start isn't known.
        var copied: [String] = []
        /// MCP servers left out, and why each.
        var skipped: [String: String] = [:]
        /// MCP servers the host had its own of, under the same name: left as they were.
        var kept: [String] = []
        /// Copied servers that won't start on the host, and the program each needs that it lacks.
        var missing: [String: String] = [:]
        /// Copied uv tools whose versions from this Mac the host couldn't install, and what uv said.
        var unresolved: [String: String] = [:]

        /// For the row of the host called `host`.
        func note(on host: String) -> String {
            var parts = [L("Synced.")]
            if !copied.isEmpty { parts.append(L("Servers copied: \(copied.joined(separator: ", ")).")) }
            if !skipped.isEmpty {
                // Each reason once, after the servers it is for.
                let byReason = Dictionary(grouping: skipped.keys.sorted()) { skipped[$0] ?? "" }
                parts.append(L("Not copied: \(byReason.sorted { $0.value[0] < $1.value[0] }.map { "\($0.value.joined(separator: ", ")) (\($0.key))" }.joined(separator: "; ")).")) }
            if !kept.isEmpty { parts.append(L("Kept the host's own: \(kept.joined(separator: ", ")).")) }
            if !missing.isEmpty {
                let each = missing.sorted { $0.key < $1.key }.map { L("\($0.key): \($0.value) isn't installed on \(host)") }
                parts.append(L("Won't start there: \(each.joined(separator: "; "))."))
            }
            for (name, said) in unresolved.sorted(by: { $0.key < $1.key }) {
                parts.append(L("\(name): the versions it has on this Mac can't be installed on \(host) (\(said))."))
            }
            return parts.joined(separator: " ")
        }
    }

    /// Copies `home`'s skills and MCP servers to the host `files` reaches, whose data folder is
    /// `dataFolder`.
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

    /// Run on the host with the archive on its stdin (nothing: all that was sent is gone here)
    /// and its data folder as `$1`: unpacks it in the home, and removes the files an earlier
    /// sync put there that this one no longer has. Which those are is kept in
    /// `synced-files.txt` of the data folder, so nothing the host had on its own is removed.
    static let unpackScript = #"""
        set -e
        list="$1/synced-files.txt"
        mkdir -p "$1"
        packed=$(mktemp)
        trap 'rm -f "$packed" "$list.next"' EXIT
        cat > "$packed"
        if [ -s "$packed" ]; then tar -tzf "$packed" | grep -v '/$' | LC_ALL=C sort > "$list.next"; else : > "$list.next"; fi
        if [ -f "$list" ]; then
            LC_ALL=C comm -23 "$list" "$list.next" | while IFS= read -r file; do
                case "$file" in *..*) ;; .claude/*) rm -f -- "$HOME/$file" ;; esac
            done
        fi
        if [ -s "$packed" ]; then tar -xzf "$packed" -C "$HOME"; fi
        mv "$list.next" "$list"
        """#

    static func run(from home: URL, to files: HostFiles, dataFolder: String) async throws -> Outcome {
        let packed: Data? = try await Task.detached(operation: { try archive(of: home) }).value
        guard let unpacked = await files.run("sh", ["-c", unpackScript, "sh", dataFolder], packed ?? Data()) else { throw Failure(message: L("The host stopped answering.")) }
        guard unpacked.status == 0 else { throw Failure(message: String(decoding: unpacked.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Who commits: a host that has no git identity gets this Mac's, or agents there can't commit.
        for key in ["user.name", "user.email"] {
            guard let value = localGit(["config", "--global", "--get", key]), !value.isEmpty else { continue }
            _ = await files.run("sh", ["-c", "git config --global --get \"$1\" >/dev/null || git config --global \"$1\" \"$2\"", "sh", key, value], nil)
        }
        var outcome = Outcome()
        guard let config = try? Data(contentsOf: home.appendingPathComponent(".claude.json")) else { return outcome }
        // Off the main thread: finding the user's PATH asks a login shell.
        let pinsFolder = dataFolder + "/synced-pins"
        let servers = await Task.detached { Self.servers(in: config, pinsFolder: pinsFolder) }.value
        outcome.skipped = servers.skipped
        let sent = try JSONSerialization.data(withJSONObject: ["servers": servers.copied, "pins": servers.pins])
        guard let ran = await files.run("sh", ["-c", "exec python3 -c \"$1\" \"$HOME/.claude.json\" \"$2\" \"$3\"", "sh", mergeScript, dataFolder + "/synced-mcp.json", pinsFolder], sent) else {
            throw Failure(message: L("The host stopped answering."))
        }
        guard ran.status == 0 else { throw Failure(message: String(decoding: ran.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        outcome.kept = ((try? JSONSerialization.jsonObject(with: ran.output)) as? [String: [String]])?["kept"] ?? []
        // Asked once, with the PATH agents get there: a server whose program the host lacks isn't one it has.
        let programs = servers.copied.filter { !outcome.kept.contains($0.key) }.compactMapValues { ($0 as? [String: Any])?["command"] as? String }
        let distinct = Set(programs.values).sorted()
        if !distinct.isEmpty, let lacking = await files.run("sh", ["-c", #"PATH="$HOME/.local/bin:$PATH"; for p in "$@"; do command -v "$p" >/dev/null 2>&1 || echo "$p"; done"#, "sh"] + distinct, nil) {
            let absent = Set(String(decoding: lacking.output, as: UTF8.self).split(separator: "\n").map(String.init))
            outcome.missing = programs.filter { absent.contains($0.value) }
        }
        // A pinned tool is installed now, held to this Mac's versions: where one has no build for
        // the host, that is known here and not when an agent first needs the server.
        for (name, value) in servers.copied where !outcome.kept.contains(name) && outcome.missing[name] == nil {
            guard let server = value as? [String: Any], server["command"] as? String == "uvx",
                  let arguments = server["args"] as? [Any], arguments.first as? String == "--constraints" else { continue }
            let pinned = arguments.prefix(4).compactMap { $0 as? String }
            guard let tried = await files.run("sh", ["-c", #"PATH="$HOME/.local/bin:$PATH"; exec uvx "$@" python -c pass"#, "sh"] + pinned, nil), tried.status != 0 else { continue }
            let lines = String(decoding: tried.error, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            outcome.unresolved[name] = String((lines.first { $0.contains("error") || $0.contains("×") } ?? lines.last ?? "uvx").prefix(200))
        }
        outcome.copied = servers.copied.keys.filter { !outcome.kept.contains($0) && outcome.missing[$0] == nil && outcome.unresolved[$0] == nil }.sorted()
        return outcome
    }
}
