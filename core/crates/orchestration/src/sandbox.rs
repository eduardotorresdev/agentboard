//! On a host, each worktree's programs run in a sandbox of their own (bubblewrap): the system
//! is read-only, and of the other worktrees and of the core's own data (the account token, the
//! tools key) they see nothing. Home stays writable, as agents keep their settings, caches and
//! logins there, and so does `/tmp`, where they leave files for the core to pick up.
//!
//! It keeps worktrees out of each other's way and the host's own program, service and logins
//! out of their reach. It is not a wall against a program that means harm: the network is
//! shared, whoever can reach Docker can leave (see `AGENTBOARD_SANDBOX_DOCKER`), and home is
//! shared. What a board runs about a project (git) runs in such a sandbox too (`wrap_command`).

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use runtime::LaunchSpec;

/// `spec` as it runs for `worktree`: inside a sandbox where one can be made, as it is otherwise
/// (not Linux, no working `bwrap`, or `AGENTBOARD_SANDBOX=0`).
pub fn wrap(spec: LaunchSpec, worktree: &str, data_folder: &Path) -> LaunchSpec {
    let (Some(bwrap), Some(home)) = (bwrap(), std::env::var_os("HOME").map(PathBuf::from)) else { return spec };
    let worktree = Path::new(worktree);
    let visible: Vec<PathBuf> = repository(worktree, &home, data_folder).into_iter().chain([worktree.to_path_buf()]).collect();
    let mut arguments = arguments(&home, &visible, data_folder, Some(&spec.directory));
    arguments.push(spec.executable);
    arguments.extend(spec.arguments);
    LaunchSpec { executable: bwrap.to_string(), arguments, environment: spec.environment, directory: spec.directory }
}

/// Where `bwrap` is, if it can make a sandbox here: Ubuntu forbids it until `agentboard setup`
/// allowed it (AppArmor).
fn probe() -> Option<String> {
    if !cfg!(target_os = "linux") || std::env::var("AGENTBOARD_SANDBOX").is_ok_and(|value| value == "0") {
        return None;
    }
    ["/usr/bin/bwrap", "/usr/local/bin/bwrap"].into_iter().find(|path| {
        std::process::Command::new(path)
            .args(["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "/bin/true"])
            .stdin(std::process::Stdio::null())
            .output()
            .is_ok_and(|output| output.status.success())
    }).map(String::from)
}

/// A command a board runs about `folder` (git in a clone or a worktree, a file read), inside a
/// sandbox that sees the project `folder` belongs to, its clone and its worktrees, and no other:
/// what the worktrees' programs left there (git hooks, settings) then runs with no more reach
/// than they had. As it is when `folder` is no project's, or no sandbox can be made.
pub fn wrap_command(folder: &str, executable: String, arguments: Vec<String>, directory: Option<&str>, data_folder: &Path) -> (String, Vec<String>) {
    let (Some(bwrap), Some(home)) = (bwrap(), std::env::var_os("HOME").map(PathBuf::from)) else { return (executable, arguments) };
    let projects = home.join("agentboard/projects");
    let Some(entry) = Path::new(folder).strip_prefix(&projects).ok().and_then(|inside| inside.components().next()) else { return (executable, arguments) };
    let name = entry.as_os_str().to_string_lossy();
    let name = name.strip_suffix("-worktrees").unwrap_or(&name);
    let visible = [projects.join(name), projects.join(format!("{name}-worktrees"))];
    // Made here: one made inside, under the hidden `~/agentboard`, would vanish with the sandbox.
    let _ = std::fs::create_dir_all(&visible[1]);
    let mut list = self::arguments(&home, &visible, data_folder, directory);
    list.push(executable);
    list.extend(arguments);
    (bwrap.to_string(), list)
}

fn bwrap() -> Option<&'static str> {
    static BWRAP: OnceLock<Option<String>> = OnceLock::new();
    BWRAP.get_or_init(probe).as_deref()
}

/// The git folder a linked worktree's commits go to (its repository's). Never taken on the
/// word of the worktree's `.git` file alone: programs inside write that file, and what it named
/// would be theirs to write at the next launch.
fn repository(worktree: &Path, home: &Path, data_folder: &Path) -> Option<PathBuf> {
    let boards = home.join("agentboard");
    // A board's worktree: `projects/<name>-worktrees/<x>`, its repository `projects/<name>/.git`.
    if let Ok(inside) = worktree.strip_prefix(boards.join("projects")) {
        let name = inside.components().next()?.as_os_str().to_str()?.strip_suffix("-worktrees")?;
        return Some(boards.join("projects").join(name).join(".git"));
    }
    // Elsewhere, what the file says, if it is a repository's folder and nothing kept from them.
    // shortcut: checked here, bound later by path: a program still inside could swap the folder for a link in between; refuse or bind by descriptor when a Mac becomes a host.
    let text = std::fs::read_to_string(worktree.join(".git")).ok()?;
    let folder = std::fs::canonicalize(text.strip_prefix("gitdir:")?.trim()).ok()?;
    let repository = folder.parent().filter(|parent| parent.ends_with(".git/worktrees"))?.parent()?;
    let kept = KEPT_FOLDERS.iter().map(|name| home.join(name)).chain([data_folder.to_path_buf(), boards, home.join(".local/bin")]);
    let safe = !kept.into_iter().any(|kept| repository.starts_with(std::fs::canonicalize(&kept).unwrap_or(kept)));
    safe.then(|| repository.to_path_buf())
}

/// What would run outside the sandbox later, were it written from inside: the host's own
/// service, who may log in, git's own settings, the shell's start files. Read-only inside;
/// the folders and git's settings are made when absent (or a program inside would make them),
/// the shell's files are not: an empty one would change how the user's own shell starts.
const KEPT_FOLDERS: [&str; 5] = [".config/systemd", ".local/share/systemd", ".config/autostart", ".ssh", ".config/git"];
const KEPT_FILES: [&str; 10] = [".local/bin/agentboard", ".gitconfig", ".profile", ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".zshrc", ".zprofile", ".zshenv"];

/// `visible`: what of `~/agentboard` the programs see and write, the rest of it hidden.
fn arguments(home: &Path, visible: &[PathBuf], data_folder: &Path, directory: Option<&str>) -> Vec<String> {
    let text = |path: &Path| path.to_string_lossy().into_owned();
    let mut list: Vec<String> = ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"].map(String::from).to_vec();
    let bind = |list: &mut Vec<String>, flag: &str, from: &Path, to: &Path| list.extend([flag.to_string(), text(from), text(to)]);
    bind(&mut list, "--bind", home, home);
    bind(&mut list, "--bind", Path::new("/tmp"), Path::new("/tmp"));
    for folder in KEPT_FOLDERS.map(|name| home.join(name)) {
        let _ = std::fs::create_dir_all(&folder);
        bind(&mut list, "--ro-bind", &folder, &folder);
    }
    let settings = home.join(".gitconfig");
    if !settings.exists() {
        let _ = std::fs::write(&settings, "");
    }
    let own = std::env::current_exe().ok().filter(|path| path.starts_with(home));
    for file in KEPT_FILES.iter().map(|name| home.join(name)).chain(own).filter(|file| file.exists()) {
        bind(&mut list, "--ro-bind", &file, &file);
    }
    // The user's service manager answers on a socket here: asking it to run something is a way out.
    // SAFETY: getuid only reads.
    let session = PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }));
    if session.is_dir() {
        list.extend(["--tmpfs".to_string(), text(&session)]);
    }
    // Docker is a way out too (a container can mount anything): `AGENTBOARD_SANDBOX_DOCKER=0`
    // takes it away from the worktrees' programs.
    if std::env::var("AGENTBOARD_SANDBOX_DOCKER").is_ok_and(|value| value == "0") && Path::new("/run/docker.sock").exists() {
        list.extend(["--ro-bind", "/dev/null", "/run/docker.sock"].map(String::from));
    }
    // Where a board puts a host's projects and their worktrees (docs/hosts.md).
    let projects = home.join("agentboard");
    if visible.iter().any(|path| path.starts_with(&projects)) {
        list.extend(["--tmpfs".to_string(), text(&projects)]);
    }
    list.extend(["--tmpfs".to_string(), text(data_folder)]);
    // Back in from the data folder: the organizations' agent settings, which agents write, and
    // the private toolchain `agentboard setup` made (git, Node), which nothing inside may change.
    let organizations = data_folder.join("organizations");
    if organizations.is_dir() {
        bind(&mut list, "--bind", &organizations, &organizations);
    }
    let tools = data_folder.join("tools");
    if tools.is_dir() {
        bind(&mut list, "--ro-bind", &tools, &tools);
    }
    for path in visible.iter().filter(|path| path.exists()) {
        bind(&mut list, "--bind", path, path);
    }
    // Processes of their own: the core and the other worktrees' programs can't be signalled or
    // read. Not a session of their own, though: the program would lose its terminal (no Ctrl+C,
    // no job control), and what it could type into that terminal only reaches itself.
    list.extend(["--unshare-pid".to_string(), "--die-with-parent".to_string()]);
    if let Some(directory) = directory {
        list.extend(["--chdir".to_string(), directory.to_string()]);
    }
    list.push("--".to_string());
    list
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_worktree_sees_itself_and_its_repository_only() {
        let root = std::env::temp_dir().join(format!("sandbox-{}", std::process::id()));
        let home = root.join("home");
        let worktree = home.join("agentboard/projects/app-worktrees/fix");
        let data = home.join(".local/share/agentboard");
        std::fs::create_dir_all(&worktree).unwrap();
        std::fs::create_dir_all(data.join("organizations")).unwrap();
        let repository = home.join("agentboard/projects/app/.git");
        std::fs::write(worktree.join(".git"), format!("gitdir: {}/worktrees/fix\n", repository.display())).unwrap();

        let visible = [repository.clone(), worktree.clone()];
        std::fs::create_dir_all(&repository).unwrap();
        let list = arguments(&home, &visible, &data, Some(&worktree.to_string_lossy()));
        let at = |flag: &str, path: &Path| list.windows(2).position(|pair| pair[0] == flag && pair[1] == path.to_string_lossy()).unwrap_or_else(|| panic!("{flag} {path:?} in {list:?}"));
        // Hidden first, then what is let back in over it.
        assert!(at("--bind", &home) < at("--tmpfs", &home.join("agentboard")));
        assert!(at("--tmpfs", &home.join("agentboard")) < at("--bind", &repository));
        assert!(at("--tmpfs", &home.join("agentboard")) < at("--bind", &worktree));
        assert!(at("--tmpfs", &data) < at("--bind", &data.join("organizations")));
        assert_eq!(&list[..3], ["--ro-bind", "/", "/"]);
        assert_eq!(list.last().unwrap(), "--");
        // Git's settings and the kept folders are there, read-only; no shell file is made up.
        assert!(at("--ro-bind", &home.join(".gitconfig")) > 0 && at("--ro-bind", &home.join(".ssh")) > 0);
        assert!(!home.join(".bash_profile").exists() && !list.contains(&home.join(".bash_profile").to_string_lossy().into_owned()));

        // The worktree's own `.git` file doesn't choose what is bound.
        assert_eq!(super::repository(&worktree, &home, &data), Some(repository.clone()));
        std::fs::write(worktree.join(".git"), format!("gitdir: {}/x/y\n", data.display())).unwrap();
        assert_eq!(super::repository(&worktree, &home, &data), Some(repository.clone()));
        let outside = root.join("elsewhere");
        for hostile in [data.join(".git/worktrees/x"), home.join(".ssh/.git/worktrees/x"), home.join("agentboard/projects/other/.git/worktrees/x"), root.join("plain/a/b")] {
            std::fs::create_dir_all(&hostile).unwrap();
            std::fs::create_dir_all(&outside).unwrap();
            std::fs::write(outside.join(".git"), format!("gitdir: {}\n", hostile.display())).unwrap();
            assert_eq!(super::repository(&outside, &home, &data), None, "{hostile:?}");
        }
        let real = root.join("repo/.git/worktrees/x");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(outside.join(".git"), format!("gitdir: {}\n", real.display())).unwrap();
        assert_eq!(super::repository(&outside, &home, &data), Some(std::fs::canonicalize(root.join("repo/.git")).unwrap()));
        let _ = std::fs::remove_dir_all(root);
    }
}
