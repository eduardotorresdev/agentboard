//! Projects and worktrees made on the host: the refusals a request from another device meets,
//! and git's work with its undo, in throwaway folders with a throwaway git config.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Once;

use orchestration::projects::{self, check_clone_url, check_name, create_project, create_worktree, inside, Start};

/// A fresh folder; git (for the whole test process) reads only a config made here, never the
/// user's, and rewrites `https://repos.invalid/` to local bare repositories.
fn scratch() -> PathBuf {
    static SETUP: Once = Once::new();
    let base = std::env::temp_dir().join(format!("abprojects-{}", std::process::id()));
    SETUP.call_once(|| {
        std::fs::create_dir_all(&base).unwrap();
        let config = base.join("gitconfig");
        std::fs::write(&config, format!("[user]\n\tname = Test\n\temail = test@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n[url \"file://{}/bare/\"]\n\tinsteadOf = https://repos.invalid/\n", base.display())).unwrap();
        std::env::set_var("GIT_CONFIG_GLOBAL", &config);
        std::env::set_var("GIT_CONFIG_NOSYSTEM", "1");
    });
    let folder = base.join(uuid());
    std::fs::create_dir_all(&folder).unwrap();
    folder.canonicalize().unwrap()
}

fn uuid() -> String {
    runtime::Uuid::new().to_string()
}

fn git(directory: &Path, arguments: &[&str]) -> String {
    let output = Command::new("git").arg("-C").arg(directory).args(arguments).output().unwrap();
    assert!(output.status.success(), "git {arguments:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// A bare repository reachable as `https://repos.invalid/<name>.git`, with a commit on main and
/// one on `feature`.
fn remote(name: &str) -> String {
    let base = std::env::temp_dir().join(format!("abprojects-{}", std::process::id()));
    let work = scratch().join("seed");
    std::fs::create_dir_all(&work).unwrap();
    git(&work, &["init", "-b", "main"]);
    git(&work, &["commit", "--allow-empty", "-m", "first"]);
    git(&work, &["branch", "feature"]);
    let bare = base.join("bare").join(format!("{name}.git"));
    std::fs::create_dir_all(bare.parent().unwrap()).unwrap();
    git(&work, &["clone", "--bare", "--", &work.to_string_lossy(), &bare.to_string_lossy()]);
    format!("https://repos.invalid/{name}.git")
}

/// The shared cases (`core/fixtures/projects/checks.json`), refused with the same reason by
/// the Swift core's checks.
fn checks() -> serde_json::Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/projects/checks.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn each(list: &serde_json::Value, check: impl Fn(&str) -> Result<(), String>) {
    for case in list.as_array().unwrap() {
        let value = case["value"].as_str().unwrap();
        assert_eq!(check(value).err().as_deref(), case["refused"].as_str(), "{value:?}");
    }
}

#[test]
fn names_that_climb_out_or_hide_are_refused() {
    each(&checks()["names"], check_name);
}

#[test]
fn only_https_and_ssh_clone_urls_are_taken() {
    each(&checks()["cloneURLs"], check_clone_url);
    for case in checks()["repositoryNames"].as_array().unwrap() {
        assert_eq!(projects::repository_name(case["url"].as_str().unwrap()), case["name"].as_str().unwrap());
    }
}

#[test]
fn paths_stay_inside_the_projects_folder() {
    let root = scratch();
    let projects = root.join("projects");
    std::fs::create_dir_all(projects.join("app")).unwrap();
    std::fs::create_dir_all(root.join("outside")).unwrap();
    std::os::unix::fs::symlink(root.join("outside"), projects.join("link")).unwrap();
    assert_eq!(inside(&projects, &projects.join("app")).unwrap(), projects.join("app"));
    assert_eq!(inside(&projects, &projects.join("new/deeper")).unwrap(), projects.join("new/deeper"));
    for path in [projects.clone(), root.join("outside"), projects.join("../outside"), projects.join("app/../../outside"), projects.join("link"),
                 projects.join("link/x"), PathBuf::from("app"), PathBuf::from("/etc")] {
        assert!(inside(&projects, &path).is_err(), "{path:?}");
    }
    // Through the creates: a project behind a link, a name that climbs.
    assert!(create_worktree(&projects, &projects.join("link"), "fix").unwrap_err().contains("isn't inside the projects folder"));
    assert!(create_project(&projects, Some(".."), None).is_err());
    assert!(create_project(&projects, Some("link"), None).is_err());
    assert!(!root.join("outside/.git").exists());
}

#[test]
fn a_new_project_is_a_repository_on_main_with_a_first_commit() {
    let projects = scratch().join("projects");
    let made = create_project(&projects, Some("app"), None).unwrap();
    assert_eq!(made, projects.join("app"));
    assert_eq!(git(&made, &["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(git(&made, &["log", "--format=%s"]), "Initial commit");

    // One that's there is never touched.
    std::fs::write(made.join("notes"), "mine").unwrap();
    assert!(create_project(&projects, Some("app"), None).unwrap_err().contains("already exists"));
    assert_eq!(std::fs::read_to_string(made.join("notes")).unwrap(), "mine");
}

#[test]
fn a_clone_takes_its_name_from_the_url_and_a_failed_one_leaves_nothing() {
    let projects = scratch().join("projects");
    let url = remote(&format!("shop-{}", uuid()));
    let made = create_project(&projects, None, Some(&url)).unwrap();
    assert!(made.file_name().unwrap().to_string_lossy().starts_with("shop-"));
    assert_eq!(git(&made, &["log", "--format=%s"]), "first");

    let failed = create_project(&projects, Some("gone"), Some("https://repos.invalid/missing.git"));
    assert!(failed.is_err());
    assert!(!projects.join("gone").exists(), "the failed clone's folder stays");
    assert!(create_project(&projects, Some("x"), Some("file:///etc")).unwrap_err().contains("https or ssh"));
    assert!(!projects.join("x").exists());
}

#[test]
fn a_worktree_takes_the_local_branch_else_origins_else_a_new_one() {
    let projects = scratch().join("projects");
    let url = remote(&format!("app-{}", uuid()));
    let repository = create_project(&projects, Some("app"), Some(&url)).unwrap();
    git(&repository, &["branch", "local"]);
    assert_eq!(projects::start(&repository, "local"), Start::Existing);
    assert_eq!(projects::start(&repository, "feature"), Start::Remote("origin/feature".into()));
    assert_eq!(projects::start(&repository, "fresh/idea"), Start::New);

    let local = create_worktree(&projects, &repository, "local").unwrap();
    assert_eq!(local, projects.join("app-worktrees/local"));
    let feature = create_worktree(&projects, &repository, "feature").unwrap();
    assert_eq!(git(&feature, &["rev-parse", "--abbrev-ref", "@{upstream}"]), "origin/feature");
    let fresh = create_worktree(&projects, &repository, "fresh/idea").unwrap();
    assert_eq!(fresh, projects.join("app-worktrees/fresh-idea"));
    assert_eq!(git(&fresh, &["rev-parse", "HEAD"]), git(&repository, &["rev-parse", "HEAD"]));
    assert!(create_worktree(&projects, &repository, "local").unwrap_err().contains("already exists"));
}

#[test]
fn bad_branches_and_non_projects_are_refused() {
    let projects = scratch().join("projects");
    let repository = create_project(&projects, Some("app"), None).unwrap();
    for branch in ["", "a..b", "-b", "x y", "a~1", "refs/../x", "@{-1}"] {
        assert!(create_worktree(&projects, &repository, branch).unwrap_err().contains("valid branch"), "{branch:?}");
    }
    std::fs::create_dir_all(projects.join("plain")).unwrap();
    assert!(create_worktree(&projects, &projects.join("plain"), "fix").unwrap_err().contains("isn't a project's repository"));
    assert!(!projects.join("app-worktrees").exists());
}

#[test]
fn a_failed_worktree_undoes_its_branch_and_folder_only() {
    let projects = scratch().join("projects");
    let repository = create_project(&projects, Some("app"), None).unwrap();
    // main is checked out already: git refuses, and the branch, not ours, stays.
    assert!(create_worktree(&projects, &repository, "main").is_err());
    assert!(!projects.join("app-worktrees").exists(), "the folder it made stays");
    assert_eq!(git(&repository, &["branch", "--list", "main"]), "* main");

    // The worktree can't be written: the branch it made goes again.
    let parent = projects.join("app-worktrees");
    std::fs::create_dir_all(&parent).unwrap();
    std::fs::set_permissions(&parent, std::os::unix::fs::PermissionsExt::from_mode(0o555)).unwrap();
    let failed = create_worktree(&projects, &repository, "fix");
    std::fs::set_permissions(&parent, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    assert!(failed.is_err());
    assert_eq!(git(&repository, &["branch", "--list", "fix"]), "", "the branch it made stays");
    assert!(parent.exists(), "a folder that was there goes");
}
