import Foundation
import Orchestration

/// Git work only the app does (its own pulls, removals, commits and other hosts' worktrees);
/// what a core also runs (making projects and worktrees) is in `Orchestration/Git.swift`.
extension Git {
    /// Brings the worktree's branch up to its upstream, when that only moves it forward; throws
    /// what git said otherwise.
    static func pull(at path: String) throws {
        try run(["-C", path, "pull", "--ff-only"])
    }

    /// Work in a worktree that removing it would lose: changed or untracked files, and commits
    /// no remote branch has.
    struct PendingWork: Sendable {
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
        try run(["-C", repository, "worktree", "remove"] + (force ? ["--force"] : []) + ["--", path])
    }

    /// `createWorktree` on another host: in its clone of the repository, made from `origin` on
    /// first use and fetched after that. The branch is the one the host has (its own, or
    /// origin's); a new one starts where it would here, as origin has it. Call it without
    /// `Git.host` set: the repository is read on this Mac.
    static func createWorktree(branch: String, in repository: String, on host: GitHost) throws -> CreatedWorktree {
        guard let origin = originURL(of: repository) else {
            throw GitError(message: L("This project has no origin remote, so its worktrees can only be on this Mac."))
        }
        let local = worktreeStart(for: branch, in: repository)
        return try $host.withValue(host) {
            let clone = host.clone(of: repository)
            if exists(clone + "/.git") {
                try run(["-C", clone, "fetch", "origin"])
            } else {
                try host.output("sh", ["-c", "mkdir -p \"$1\"", "sh", (clone as NSString).deletingLastPathComponent])
                try run(["clone", "--", origin, clone])
            }
            var start = worktreeStart(for: branch, in: clone)
            if case .newBranch = start {
                guard case .newBranch(let base) = local else {
                    throw GitError(message: L("The branch \(branch) isn't on origin. Push it, then try again."))
                }
                start = .newBranch(from: base)
            }
            return try createWorktree(branch: branch, in: clone, start: start)
        }
    }

}
