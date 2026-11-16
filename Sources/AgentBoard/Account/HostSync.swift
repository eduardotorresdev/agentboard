import AgentRuntime
import CryptoKit
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

    /// What only this Mac needs, wherever it is: Finder's files, git folders, caches, `.env` files.
    private static let left: Set<String> = [".DS_Store", ".git", "__pycache__", ".env"]

    /// Every file that goes, by its path inside `home`, with the SHA-256 of its content (hashing
    /// what a home has takes a fraction of a second; times and sizes would miss a file put back).
    /// Links are followed: a skill linked in from elsewhere goes as its files.
    static func manifest(of home: URL) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ path: String, depth: Int) {
            let url = home.appendingPathComponent(path)
            var isFolder: ObjCBool = false
            // Deep enough for any skill, and an end to a link that leads back up.
            guard depth < 40, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
            if isFolder.boolValue {
                // The lists are lines: a name with a line break in it stays here.
                for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where !left.contains(name) && !name.contains("\n") {
                    walk(path + "/" + name, depth: depth + 1)
                }
            } else if let hash = hash(of: url) {
                found[path] = hash
            }
        }
        entries(in: home).forEach { walk($0, depth: 0) }
        return found
    }

    /// The hashes found this launch, by file, with the size and date each file had then: a file
    /// is read again only when one of those changed (reading every skill takes seconds).
    private static let hashed = Hashed()
    private final class Hashed: @unchecked Sendable {
        let lock = NSLock()
        var files: [String: (size: Int, changed: Date, hash: String)] = [:]
    }

    private static func hash(of url: URL) -> String? {
        let file = url.resolvingSymlinksInPath()
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let size = values?.fileSize, let changed = values?.contentModificationDate,
           let kept = hashed.lock.withLock({ hashed.files[file.path] }), kept.size == size, kept.changed == changed {
            return kept.hash
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let hash = hex(SHA256.hash(data: data))
        if let size = values?.fileSize, let changed = values?.contentModificationDate {
            hashed.lock.withLock { hashed.files[file.path] = (size, changed, hash) }
        }
        return hash
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// A manifest as the host keeps it (`synced-files.txt`): a line per file, hash then path,
    /// sorted by path.
    static func listing(_ manifest: [String: String]) -> String {
        manifest.keys.sorted().map { "\(manifest[$0] ?? "") \($0)\n" }.joined()
    }

    /// The same read back. A line without a hash (a list from before there were any) is a file
    /// with none: it counts as changed.
    static func manifest(listed text: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let hash = line.prefix(64)
            if line.count > 65, line.dropFirst(64).first == " ", hash.allSatisfy({ $0.isHexDigit }) {
                found[String(line.dropFirst(65))] = String(hash)
            } else {
                found[String(line)] = ""
            }
        }
        return found
    }

    /// A gzipped tar of `paths` (inside `home`; every file that goes, when nil), to unpack in the
    /// host's home; nil when there is nothing to send.
    static func archive(of home: URL, paths: [String]? = nil) throws -> Data? {
        let paths = paths ?? manifest(of: home).keys.sorted()
        guard !paths.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // To a file: written to a pipe, tar pads the archive with zeros past its end.
        let packed = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-sync-\(UUID().uuidString).tgz")
        let named = packed.appendingPathExtension("files")
        defer { [packed, named].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data(paths.joined(separator: "\n").utf8).write(to: named)
        process.arguments = ["-czLf", packed.path, "--no-mac-metadata", "--no-xattrs", "-C", home.path, "-T", named.path]
        // No `._name` companions either.
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // tar says 1 for a file it couldn't read: the rest still goes.
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
    static func servers(in config: Data, searchPath: String? = nil, pinsFolder: String? = nil)
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
            } else if let command = server["command"] as? String, !portable.contains(command), let package = npmPackage(of: command, in: searchPath ?? loginPath) {
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
        /// The host already had all of it from the last sync: nothing was sent.
        var upToDate = false

        /// For the row of the host called `host`.
        func note(on host: String) -> String {
            if upToDate { return L("Up to date.") }
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

    /// Run on the host with an archive of the new and changed files on its stdin (nothing: none
    /// are) and its data folder as `$1`, after the list of all that this Mac has was put in
    /// `synced-files.txt.next` there: removes the files an earlier sync put in the home that the
    /// new list no longer has, unpacks, and makes the new list `synced-files.txt`. Only what
    /// that list names is ever removed, so nothing the host had on its own is.
    static let unpackScript = #"""
        set -e
        list="$1/synced-files.txt"
        packed=$(mktemp)
        trap 'rm -f "$packed" "$packed.old" "$packed.new"' EXIT
        cat > "$packed"
        paths() { sed -E 's/^[0-9a-f]{64} //' "$1" | LC_ALL=C sort; }
        if [ -f "$list" ]; then
            paths "$list" > "$packed.old"
            paths "$list.next" > "$packed.new"
            LC_ALL=C comm -23 "$packed.old" "$packed.new" | while IFS= read -r file; do
                case "$file" in *..*) ;; .claude/*) rm -f -- "$HOME/$file" ;; esac
            done
        fi
        if [ -s "$packed" ]; then tar -xzf "$packed" -C "$HOME"; fi
        mv "$list.next" "$list"
        """#

    static func run(from home: URL, to files: HostFiles, dataFolder: String) async throws -> Outcome {
        let stopped = Failure(message: L("The host stopped answering."))
        func said(_ ran: CoreClient.Ran) -> Failure { Failure(message: String(decoding: ran.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Off the main thread: hashing reads every file, and finding the user's PATH asks a login shell.
        let pinsFolder = dataFolder + "/synced-pins"
        let (here, servers) = await Task.detached {
            (manifest(of: home), (try? Data(contentsOf: home.appendingPathComponent(".claude.json"))).map { Self.servers(in: $0, pinsFolder: pinsFolder) })
        }.value
        let listing = listing(here)
        let sent = try servers.map { try JSONSerialization.data(withJSONObject: ["servers": $0.copied, "pins": $0.pins], options: .sortedKeys) }
        let digest = hex(SHA256.hash(data: Data(listing.utf8) + (sent ?? Data())))

        // One small question first: what the last sync left there. The same as now: nothing to send.
        guard let had = await files.run("sh", ["-c", #"cat "$1/synced.digest" 2>/dev/null; echo; cat "$1/synced-files.txt" 2>/dev/null; true"#, "sh", dataFolder], nil) else { throw stopped }
        let answer = String(decoding: had.output, as: UTF8.self)
        let firstLine = answer.firstIndex(of: "\n") ?? answer.endIndex
        var outcome = Outcome()
        if answer[..<firstLine] == digest {
            outcome.upToDate = true
            return outcome
        }
        let there = manifest(listed: String(answer[firstLine...]))
        if there != here {
            // Only the new and changed files travel; the whole list goes along, for what to remove.
            let changed = here.filter { there[$0.key] != $0.value }.keys.sorted()
            guard let listed = await files.run("sh", ["-c", #"mkdir -p "$1" && cat > "$1/synced-files.txt.next""#, "sh", dataFolder], Data(listing.utf8)) else { throw stopped }
            guard listed.status == 0 else { throw said(listed) }
            let packed: Data? = try await Task.detached(operation: { try archive(of: home, paths: changed) }).value
            guard let unpacked = await files.run("sh", ["-c", unpackScript, "sh", dataFolder], packed ?? Data()) else { throw stopped }
            guard unpacked.status == 0 else { throw said(unpacked) }
        }
        // Who commits: a host that has no git identity gets this Mac's, or agents there can't commit.
        for key in ["user.name", "user.email"] {
            guard let value = localGit(["config", "--global", "--get", key]), !value.isEmpty else { continue }
            _ = await files.run("sh", ["-c", "git config --global --get \"$1\" >/dev/null || git config --global \"$1\" \"$2\"", "sh", key, value], nil)
        }
        if let servers, let sent {
            outcome.skipped = servers.skipped
            guard let ran = await files.run("sh", ["-c", "exec python3 -c \"$1\" \"$HOME/.claude.json\" \"$2\" \"$3\"", "sh", mergeScript, dataFolder + "/synced-mcp.json", pinsFolder], sent) else { throw stopped }
            guard ran.status == 0 else { throw said(ran) }
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
                // Fetching a tool's packages takes what it takes: minutes on a slow line.
                guard let tried = await files.carried("sh", ["-c", #"PATH="$HOME/.local/bin:$PATH"; exec uvx "$@" python -c pass"#, "sh"] + pinned, patience: 600),
                      tried.status != 0 else { continue }
                let lines = String(decoding: tried.error, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                outcome.unresolved[name] = String((lines.first { $0.contains("error") || $0.contains("×") } ?? lines.last ?? "uvx").prefix(200))
            }
            outcome.copied = servers.copied.keys.filter { !outcome.kept.contains($0) && outcome.missing[$0] == nil && outcome.unresolved[$0] == nil }.sorted()
        }
        // Remembered only when all of it is as it should be there: a server that won't start is said again next time.
        if outcome.missing.isEmpty, outcome.unresolved.isEmpty {
            _ = await files.run("sh", ["-c", #"printf %s "$2" > "$1/synced.digest""#, "sh", dataFolder, digest], nil)
        }
        return outcome
    }
}
