//! Projects and worktrees made on the host, for a board that can't run git itself (the phone).
//! A port of `Git.createWorktree`, `Git.createRepository` and the clone in `ProjectTools.create`
//! (`Sources/AgentBoard`), with the checks a request from another device needs: everything it
//! names stays inside the projects folder, and clones come only from https or ssh.

use std::path::{Component, Path, PathBuf};
use std::process::Command;

/// What a create made, or why it didn't.
pub type Created = Result<PathBuf, String>;

/// A folder name for a new project: one plain component, never one that climbs out.
pub fn check_name(name: &str) -> Result<(), String> {
    if name.trim().is_empty() {
        return Err("Give the project a name.".into());
    }
    if name == "." || name == ".." || name.contains('/') || name.contains('\\') || name.contains('\0') {
        return Err("A project name is one folder name: no “/”, and not “.” or “..”.".into());
    }
    if name.starts_with('-') || name.starts_with('.') || name.chars().any(char::is_control) || name.len() > 255 {
        return Err("A project name can't start with “-” or “.”, nor hold control characters.".into());
    }
    Ok(())
}

/// A repository URL to clone: `https://…`, `ssh://…` or the scp form (`git@host:owner/repo`).
/// Anything else (`file://`, `ext::`, a local path, an option) could run or read things on
/// the host.
pub fn check_clone_url(url: &str) -> Result<(), String> {
    let refused = || Err("Clone from an https or ssh URL (https://…, ssh://… or git@host:owner/repo).".to_string());
    if url.is_empty() || url.starts_with('-') || url.chars().any(|c| c.is_whitespace() || c.is_control()) || url.contains("::") {
        return refused();
    }
    let rest = if let Some(rest) = url.strip_prefix("https://").or_else(|| url.strip_prefix("ssh://")) {
        rest
    } else if let Some((user_host, path)) = url.split_once(':') {
        // scp form: user@host:path, with no "/" before the colon (else it's a local path).
        if user_host.contains('/') || !user_host.contains('@') || path.is_empty() || path.starts_with("//") {
            return refused();
        }
        user_host
    } else {
        return refused();
    };
    let host = rest.split(['/', ':']).next().unwrap_or("").rsplit('@').next().unwrap_or("");
    if host.is_empty() || host.starts_with('-') {
        return refused();
    }
    Ok(())
}

/// The repository's folder name a clone of `url` takes: its last component, less `.git`.
pub fn repository_name(url: &str) -> String {
    let last = url.trim_end_matches('/').rsplit(['/', ':']).next().unwrap_or("");
    last.strip_suffix(".git").unwrap_or(last).to_string()
}

/// `path`, made absolute against nothing and resolved through any symlinks that exist, only if
/// it lies inside `projects` (itself resolved).
pub fn inside(projects: &Path, path: &Path) -> Result<PathBuf, String> {
    let outside = || Err(format!("{} isn't inside the projects folder.", path.display()));
    if !path.is_absolute() || path.components().any(|part| matches!(part, Component::ParentDir | Component::CurDir)) {
        return outside();
    }
    let root = projects.canonicalize().map_err(|_| format!("The projects folder {} isn't there.", projects.display()))?;
    // The deepest part that exists is resolved; what doesn't exist yet can't be a link.
    let mut existing = path.to_path_buf();
    let mut missing = Vec::new();
    while !existing.exists() {
        let Some(name) = existing.file_name() else { return outside() };
        missing.push(name.to_owned());
        existing.pop();
    }
    let mut resolved = existing.canonicalize().map_err(|error| error.to_string())?;
    resolved.extend(missing.iter().rev());
    if resolved == root || !resolved.starts_with(&root) {
        return outside();
    }
    Ok(resolved)
}

/// Makes the project `name` in `projects`: a clone of `clone`, or a new repository on `main`
/// with an empty first commit. A folder it made is removed when making it fails, so a retry
/// finds the name free; one that was there is never touched. If only the first commit fails
/// (commit signing that can't run here, say), the repository stays and the error says so.
pub fn create_project(projects: &Path, name: Option<&str>, clone: Option<&str>) -> Created {
    if let Some(url) = clone {
        check_clone_url(url)?;
    }
    let name = match (name.map(str::trim).filter(|name| !name.is_empty()), clone) {
        (Some(name), _) => name.to_string(),
        (None, Some(url)) => repository_name(url),
        (None, None) => return Err("Give a name, or a URL to clone.".into()),
    };
    check_name(&name)?;
    std::fs::create_dir_all(projects).map_err(|error| format!("Can't make the projects folder: {error}"))?;
    let destination = inside(projects, &projects.join(&name))?;
    if destination.exists() {
        return Err(format!("{} already exists.", destination.display()));
    }
    let undo = |error: String| {
        let _ = std::fs::remove_dir_all(&destination);
        Err(error)
    };
    if let Some(url) = clone {
        if let Err(error) = git(None, &["clone", "--", url, &destination.to_string_lossy()]) {
            return undo(error);
        }
        return Ok(destination);
    }
    if let Err(error) = std::fs::create_dir(&destination).map_err(|error| error.to_string()).and_then(|()| git(Some(&destination), &["init", "-b", "main"])) {
        return undo(error);
    }
    if let Err(error) = git(Some(&destination), &["commit", "--allow-empty", "-m", "Initial commit"]) {
        return Err(format!("Created {}, but the first commit failed: {error} The repository was kept; fix the problem (often commit signing) and commit there.", destination.display()));
    }
    Ok(destination)
}

/// Where a new worktree for `branch` goes: `<repository>-worktrees/<branch>` beside the
/// repository, the branch's slashes turned into dashes.
pub fn worktree_location(repository: &Path, branch: &str) -> PathBuf {
    let name = repository.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    repository.with_file_name(format!("{name}-worktrees")).join(branch.replace('/', "-"))
}

/// What a worktree for a branch checks out: the local branch with exactly that name; else a
/// remote's (origin's when several have it), as a new local branch tracking it; else a new
/// branch from HEAD.
#[derive(Debug, PartialEq)]
pub enum Start {
    Existing,
    Remote(String),
    New,
}

pub fn start(repository: &Path, branch: &str) -> Start {
    if !refs(repository, &format!("refs/heads/{branch}")).is_empty() {
        return Start::Existing;
    }
    let mut remotes: Vec<String> = refs(repository, &format!("refs/remotes/*/{branch}")).into_iter().map(|name| name.trim_start_matches("refs/remotes/").to_string()).collect();
    remotes.sort();
    let origin = format!("origin/{branch}");
    match remotes.iter().find(|remote| **remote == origin).or(remotes.first()) {
        Some(remote) => Start::Remote(remote.clone()),
        None => Start::New,
    }
}

/// Adds a worktree on `branch` to the project at `repository` (inside `projects`). After a
/// failure it undoes only what it made: the branch only if it made it and nothing moved it
/// since, the worktree through a plain `git worktree remove`, the folder only if empty.
/// Never forces, prunes or deletes recursively; what it couldn't undo, the error names.
pub fn create_worktree(projects: &Path, repository: &Path, branch: &str) -> Created {
    let repository = inside(projects, repository)?;
    if !repository.join(".git").exists() {
        return Err(format!("{} isn't a project's repository.", repository.display()));
    }
    if branch.is_empty() || branch.starts_with('-') || git(None, &["check-ref-format", "--branch", branch]).is_err() {
        return Err(format!("“{branch}” isn't a valid branch name."));
    }
    let location = inside(projects, &worktree_location(&repository, branch))?;
    if location.exists() {
        return Err(format!("{} already exists.", location.display()));
    }
    let parent = location.parent().map(Path::to_path_buf).unwrap_or_default();
    let made_parent = !parent.exists();
    std::fs::create_dir_all(&parent).map_err(|error| error.to_string())?;
    let mut made_branch: Option<String> = None;
    let result = (|| {
        let make_branch = |commit: String, made: &mut Option<String>| -> Result<(), String> {
            // Compare-and-swap against "doesn't exist": a branch someone else made is never taken for ours.
            git(Some(&repository), &["update-ref", &format!("refs/heads/{branch}"), &commit, ""])?;
            *made = Some(commit);
            Ok(())
        };
        match start(&repository, branch) {
            Start::Existing => {}
            Start::Remote(remote) => {
                // Named in full so a tag with the branch's name can't be picked instead.
                let commit = git(Some(&repository), &["rev-parse", "--verify", &format!("refs/remotes/{remote}^{{commit}}")])?;
                make_branch(commit, &mut made_branch)?;
                let _ = git(Some(&repository), &["branch", &format!("--set-upstream-to={remote}"), branch]);
            }
            Start::New => {
                let head = git(Some(&repository), &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
                    .map_err(|_| "The repository has no commits yet. Make a first commit, then add worktrees.".to_string())?;
                make_branch(head, &mut made_branch)?;
            }
        }
        git(Some(&repository), &["worktree", "add", "--", &location.to_string_lossy(), branch])
    })();
    // A worktree in place when a later step failed (a post-checkout hook) is usable: kept, as Swift does.
    if result.is_ok() || location.join(".git").exists() {
        return Ok(location);
    }
    let Err(error) = result else { unreachable!() };
    let mut left = Vec::new();
    // rmdir only removes an empty folder: anyone's files in it stay.
    if location.exists() && std::fs::remove_dir(&location).is_err() {
        left.push(location.display().to_string());
    }
    if made_parent {
        let _ = std::fs::remove_dir(&parent);
    }
    if let Some(commit) = made_branch {
        if git(Some(&repository), &["update-ref", "-d", &format!("refs/heads/{branch}"), &commit]).is_err() && !refs(&repository, &format!("refs/heads/{branch}")).is_empty() {
            left.push(format!("the branch {branch}"));
        }
    }
    if left.is_empty() {
        Err(error)
    } else {
        Err(format!("{error}\nLeft in place: {}.", left.join(", ")))
    }
}

fn refs(repository: &Path, pattern: &str) -> Vec<String> {
    git(Some(repository), &["for-each-ref", "--format=%(refname)", pattern]).map(|out| out.lines().map(str::to_string).collect()).unwrap_or_default()
}

/// Runs git (in `directory` when given): its output, trimmed, or its last error line.
fn git(directory: Option<&Path>, arguments: &[&str]) -> Result<String, String> {
    let mut command = Command::new("git");
    if let Some(directory) = directory {
        command.arg("-C").arg(directory);
    }
    // Never asks for a password on a terminal nobody sees: a clone that needs one fails.
    let output = command.args(arguments).env("GIT_TERMINAL_PROMPT", "0").stdin(std::process::Stdio::null()).output().map_err(|error| format!("git didn't run: {error}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
    }
    let errors = String::from_utf8_lossy(&output.stderr);
    Err(errors.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("git failed.").trim().to_string())
}
