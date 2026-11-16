import Foundation

struct Worktree: Identifiable, Hashable {
    var id: String { path }
    let path: String
    /// Short branch name, or nil when the worktree is on a detached HEAD.
    let branch: String?

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct GitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Git {
    /// Worktrees of the repository at `path`, or nil if it isn't a git repository.
    static func worktrees(at path: String, cancellable: Bool = true) -> [Worktree]? {
        guard let output = try? run(["-C", path, "worktree", "list", "--porcelain"], cancellable: cancellable) else { return nil }
        var result: [Worktree] = []
        // Porcelain output is one block per worktree, separated by blank lines.
        for block in output.components(separatedBy: "\n\n") {
            var worktreePath: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    worktreePath = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst("branch ".count))
                        .replacingOccurrences(of: "refs/heads/", with: "")
                }
            }
            if let worktreePath {
                result.append(Worktree(path: worktreePath, branch: branch))
            }
        }
        return result
    }

    /// Work in a worktree that removing it would lose: changed or untracked files, and commits
    /// no remote branch has.
    struct PendingWork {
        let changedFiles: Int
        let unpushedCommits: Int
        var isEmpty: Bool { changedFiles == 0 && unpushedCommits == 0 }
    }

    static func pendingWork(at path: String) -> PendingWork {
        let status = (try? run(["-C", path, "status", "--porcelain"])) ?? ""
        let unpushed = (try? run(["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"]))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        return PendingWork(changedFiles: status.split(separator: "\n").count, unpushedCommits: unpushed)
    }

    /// Commits every change in the worktree at `path` and pushes its branch, setting the
    /// upstream when it has none.
    static func commitAndPush(at path: String, message: String) throws {
        if !(try run(["-C", path, "status", "--porcelain"])).isEmpty {
            try run(["-C", path, "add", "-A"])
            try run(["-C", path, "commit", "-m", message])
        }
        try run(["-C", path, "push", "-u", "origin", "HEAD"])
    }

    /// Removes the worktree at `path` from the repository at `repository`, deleting its folder.
    /// `force` discards its changed and untracked files.
    static func removeWorktree(at path: String, from repository: String, force: Bool) throws {
        try run(["-C", repository, "worktree", "remove"] + (force ? ["--force"] : []) + [path])
    }

    /// Whether git accepts `name` as a branch name.
    static func isValidBranchName(_ name: String) -> Bool {
        !name.isEmpty && (try? run(["check-ref-format", "--branch", name])) != nil
    }

    /// What creating a worktree for `branch` checks out: the local branch with exactly that
    /// name; else a remote's (origin's when several have it), as a new local branch tracking it;
    /// else a new branch from HEAD.
    enum WorktreeStart: Equatable {
        case existingBranch
        /// Only a remote has it: "origin/fix".
        case remoteBranch(String)
        case newBranch(from: String?)
    }

    static func worktreeStart(for branch: String, in repository: String) -> WorktreeStart {
        // for-each-ref matches names exactly, unlike rev-parse on a case-insensitive volume.
        if refs("refs/heads/\(branch)", in: repository)?.isEmpty == false { return .existingBranch }
        let remotes = (refs("refs/remotes/*/\(branch)", in: repository) ?? []).map { String($0.dropFirst("refs/remotes/".count)) }
        if let remote = remotes.first(where: { $0 == "origin/\(branch)" }) ?? remotes.sorted().first {
            return .remoteBranch(remote)
        }
        let head = try? run(["-C", repository, "symbolic-ref", "--quiet", "--short", "HEAD"])
        return .newBranch(from: head?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Full names of the refs matching `pattern`; nil when git can't say.
    static func refs(_ pattern: String, in repository: String, cancellable: Bool = true) -> [String]? {
        guard let output = try? run(["-C", repository, "for-each-ref", "--format=%(refname)", pattern], cancellable: cancellable) else { return nil }
        return output.split(separator: "\n").map(String.init)
    }

    /// The commit HEAD is on; nil in a repository without commits (or when git can't say).
    static func headCommit(in repository: String) -> String? {
        (try? run(["-C", repository, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where a new worktree for `branch` goes: `<repository>-worktrees/<branch>` beside the
    /// repository, with the branch's slashes turned into dashes.
    static func worktreeLocation(for branch: String, in repository: String) -> URL {
        let repository = URL(fileURLWithPath: repository)
        return repository.deletingLastPathComponent()
            .appendingPathComponent(repository.lastPathComponent + "-worktrees")
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
    }

    /// Adds a worktree on `branch` to the repository at `repository`, at `worktreeLocation`, and
    /// returns its path.
    @discardableResult
    static func addWorktree(branch: String, to repository: String) throws -> String {
        try createWorktree(branch: branch, in: repository).path
    }

    struct CreatedWorktree: Sendable {
        let path: String
        /// What git reported when it failed after the worktree was already in place (e.g. a
        /// post-checkout hook).
        let warning: String?
    }

    /// `addWorktree`, telling apart a failure that left a usable worktree this call made
    /// (returned, with git's message as a warning) from one that didn't (thrown).
    ///
    /// After a failure it undoes only what it can prove this call made and nothing touched
    /// since: the branch only if git reported creating it here and it still points at the commit
    /// it started from (compare-and-swap), the worktree only through a plain `git worktree
    /// remove`, the folder only if empty. Anything else stays, and the error says where. Never
    /// prunes, forces or deletes recursively. Creates in one repository run one at a time.
    /// `start` is decided here unless given (tests pass it to stage races).
    static func createWorktree(branch: String, in repository: String, start given: WorktreeStart? = nil) throws -> CreatedWorktree {
        let lock = creationLock(for: repository)
        lock.lock()
        defer { lock.unlock() }

        let location = worktreeLocation(for: branch, in: repository)
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let start = given ?? worktreeStart(for: branch, in: repository)
        let resolved = location.resolvingSymlinksInPath().path
        func isRegistered() -> Bool? {
            worktrees(at: repository, cancellable: false).map { $0.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolved } }
        }
        // Unknown counts as registered: then nothing is claimed or undone.
        let registeredBefore = isRegistered() ?? true
        /// Set once this call has created the branch, at this commit.
        var madeBranch: String?
        /// Creates the branch only if no branch has its name (compare-and-swap against
        /// "doesn't exist"), so a branch made by anyone else is never taken for ours.
        func makeBranch(at commit: String) throws {
            try run(["-C", repository, "update-ref", "refs/heads/\(branch)", commit, ""])
            madeBranch = commit
        }
        do {
            switch start {
            case .existingBranch:
                break
            case .remoteBranch(let remote):
                // Named in full so a tag with the branch's name can't be picked instead.
                try makeBranch(at: try run(["-C", repository, "rev-parse", "--verify", "refs/remotes/\(remote)^{commit}"])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                _ = try? run(["-C", repository, "branch", "--set-upstream-to=\(remote)", branch])
            case .newBranch:
                guard let head = headCommit(in: repository) else {
                    throw GitError(message: L("The repository has no commits yet. Make a first commit, then add worktrees."))
                }
                try makeBranch(at: head)
            }
            try run(["-C", repository, "worktree", "add", location.path, branch])
            return CreatedWorktree(path: location.path, warning: nil)
        } catch {
            let message = (error as? GitError)?.message ?? error.localizedDescription
            let cancelled = error is CancellationError
            let madeHere = !registeredBefore && isRegistered() == true
            if madeHere && !cancelled && FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path) {
                return CreatedWorktree(path: location.path, warning: message)
            }
            var leftovers: [String] = []
            if madeHere, (try? run(["-C", repository, "worktree", "remove", location.path], cancellable: false)) == nil {
                leftovers.append(location.path)
            } else if !madeHere, !registeredBefore, FileManager.default.fileExists(atPath: location.path) {
                // rmdir only removes an empty folder: anyone's files in it stay.
                if rmdir(location.path) != 0 { leftovers.append(location.path) }
            }
            // Only a branch this call created, and only if nothing has moved it since.
            if let madeBranch {
                if (try? run(["-C", repository, "update-ref", "-d", "refs/heads/\(branch)", madeBranch], cancellable: false)) == nil,
                   refs("refs/heads/\(branch)", in: repository, cancellable: false)?.isEmpty == false {
                    leftovers.append(L("the branch \(branch)"))
                }
            }
            guard !leftovers.isEmpty, !cancelled else { throw error }
            throw GitError(message: message + "\n" + L("Left in place: \(leftovers.joined(separator: ", ")).") )
        }
    }

    private static let creationLocks = NSLock()
    nonisolated(unsafe) private static var locksByRepository: [String: NSLock] = [:]

    private static func creationLock(for repository: String) -> NSLock {
        let key = URL(fileURLWithPath: repository).resolvingSymlinksInPath().path
        return creationLocks.withLock {
            if let lock = locksByRepository[key] { return lock }
            let lock = NSLock()
            locksByRepository[key] = lock
            return lock
        }
    }

    /// Creates `directory`, initializes a repository on `main`, and makes an empty first commit
    /// so the main worktree has a real branch.
    /// If making the repository fails, removes the folder it made, so a retry doesn't find it
    /// taken. If only the first commit fails (e.g. commit signing that can't run from the app),
    /// the repository stays and `InitialCommitFailed` says why; signing is never turned off.
    static func createRepository(at directory: URL) throws {
        let hadFolder = FileManager.default.fileExists(atPath: directory.path)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try run(["-C", directory.path, "init", "-b", "main"])
        } catch {
            if !hadFolder { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        do {
            try run(["-C", directory.path, "commit", "--allow-empty", "-m", "Initial commit"])
        } catch {
            throw InitialCommitFailed(cause: error.localizedDescription)
        }
    }

    struct InitialCommitFailed: LocalizedError {
        let cause: String
        var errorDescription: String? { "Initial commit failed: \(cause)" }
    }

    /// Clones `url` into `directory`, reporting git's progress lines. Cancelling the task stops git.
    static func clone(_ url: String, into directory: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.environment = environment
        process.arguments = ["clone", "--progress", url, directory.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        let log = LineBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            // git rewrites progress in place with carriage returns.
            for line in chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                log.append(text)
                progress(text)
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    errors.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: GitError(message: log.lastError ?? "git clone failed."))
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// The app's environment with the usual tool folders on PATH: launched from the Dock, the
    /// app gets only /usr/bin:/bin, and hooks that call git-lfs and the like would fail.
    /// Replaceable so tests can point git at a throwaway config; the app never changes it.
    nonisolated(unsafe) static var environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath(environment["PATH"])
        return environment
    }()

    /// `path` with the usual tool folders appended, never in front: what the user's PATH
    /// already finds (their git, gpg) still wins.
    static func searchPath(_ path: String?) -> String {
        let path = path.flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var folders = path.split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !folders.contains(extra) { folders.append(extra) }
        return folders.joined(separator: ":")
    }

    /// Runs git, reading its output and errors at the same time (a hook that writes a lot to
    /// either can't block it). Stops git after `timeout`, or when the calling task is cancelled
    /// if `cancellable`.
    @discardableResult
    private static func run(_ arguments: [String], cancellable: Bool = true, timeout: TimeInterval = 600) throws -> String {
        if cancellable && Task.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.environment = environment
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let collected = Collected()
        let readers = DispatchGroup()
        // Threads of their own: GCD's shared pool can run dry when many git calls block at once.
        for (pipe, isOutput) in [(output, true), (errors, false)] {
            readers.enter()
            Thread.detachNewThread {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOutput { collected.output = data } else { collected.errors = data }
                readers.leave()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var stopped: Error?
        while process.isRunning {
            if cancellable && Task.isCancelled { stopped = CancellationError() }
            if Date() > deadline { stopped = GitError(message: L("git took too long and was stopped.")) }
            if stopped != nil { process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        // A hook's leftover child may keep a pipe open; don't wait on it forever.
        _ = readers.wait(timeout: .now() + 10)
        if let stopped { throw stopped }
        let data = collected.output, errorData = collected.errors
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: message.isEmpty ? "git \(arguments.joined(separator: " ")) failed." : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Keeps the most recent git error line so a failed clone can explain itself.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var lastError: String? {
        lock.withLock {
            lines.last { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
                .map { $0.replacingOccurrences(of: "fatal: ", with: "") }
        }
    }
}

/// What a git run wrote, filled from two reader threads.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _output = Data(), _errors = Data()
    var output: Data { get { lock.withLock { _output } } set { lock.withLock { _output = newValue } } }
    var errors: Data { get { lock.withLock { _errors } } set { lock.withLock { _errors = newValue } } }
}
