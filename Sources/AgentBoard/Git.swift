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
    static func worktrees(at path: String) -> [Worktree]? {
        guard let output = try? run(["-C", path, "worktree", "list", "--porcelain"]) else { return nil }
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

    /// Creates `directory`, initializes a repository on `main`, and makes an empty first commit
    /// so the main worktree has a real branch.
    static func createRepository(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run(["-C", directory.path, "init", "-b", "main"])
        try run(["-C", directory.path, "commit", "--allow-empty", "-m", "Initial commit"])
    }

    /// Clones `url` into `directory`, reporting git's progress lines. Cancelling the task stops git.
    static func clone(_ url: String, into directory: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
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

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
