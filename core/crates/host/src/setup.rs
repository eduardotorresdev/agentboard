//! `agentboard setup`: what a fresh Debian or Ubuntu machine needs to run agents. With root,
//! the system's packages; without, a private toolchain in the data folder. Safe to run again.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

use crate::config;

// `gh`: the vault signs it in, and `gh auth setup-git` makes git push with it.
const PACKAGES: [&str; 8] = ["git", "curl", "ca-certificates", "build-essential", "unzip", "bubblewrap", "ffmpeg", "gh"];
/// The catalog's agents and their install commands (`Sources/AgentRuntime/AgentProvider.swift`).
/// The agent CLIs, and `uv`: many MCP servers start with `uvx`, as many do with `npx`.
const AGENTS: [(&str, &str); 3] = [
    ("claude", "curl -fsSL https://claude.ai/install.sh | bash"),
    ("codex", "npm install -g @openai/codex"),
    ("uv", "curl -LsSf https://astral.sh/uv/install.sh | sh"),
];
const OOM_USER: &str = "/etc/systemd/system/user@.service.d";
const OOM_DAEMON: &str = "/etc/systemd/oomd.conf.d";
const MICROMAMBA: &str = "https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-";

/// What `plan` needs to know about the machine.
#[derive(Clone, Default)]
struct Machine {
    /// Root, or sudo without a password.
    root: bool,
    superuser: bool,
    /// Who ran `sudo agentboard setup`, when that is how this runs.
    sudo_user: Option<String>,
    user: String,
    apt: bool,
    /// `uname -m`.
    architecture: String,
    /// Of `PACKAGES`.
    missing_packages: Vec<&'static str>,
    /// On the PATH, `~/.local/bin` included.
    programs: Vec<&'static str>,
    docker_group: bool,
    /// `bwrap` can make a sandbox (Ubuntu forbids it until AppArmor is told otherwise).
    sandbox: bool,
    /// The OOM daemon's limits are already loosened, or there is none.
    patient_oom: bool,
    browser_libraries: bool,
    chromium: bool,
    micromamba: bool,
    profile_has_path: bool,
    /// The private toolchain's folder.
    tools: String,
}

#[derive(Debug, PartialEq, Eq)]
enum Action {
    Ok,
    /// A shell command.
    Run(String),
    Download { url: String, to: String },
    NeedsRoot(String),
    Skip(String),
}

#[derive(Debug, PartialEq, Eq)]
struct Step {
    name: String,
    action: Action,
}

/// The steps for `machine`, in the order they must run.
fn plan(machine: &Machine) -> Vec<Step> {
    let has = |program: &str| machine.programs.contains(&program);
    let mut steps = Vec::new();
    let mut step = |name: &str, action: Action| steps.push(Step { name: name.to_string(), action });
    // As root when possible; else the command is shown for someone who can.
    let rooted = |done: bool, command: &dyn Fn(&str) -> String| match (done, machine.root, machine.superuser) {
        (true, ..) => Action::Ok,
        (_, true, true) => Action::Run(command("")),
        (_, true, false) => Action::Run(command("sudo -n ")),
        _ => Action::NeedsRoot(command("sudo ")),
    };
    // Through sudo, the home and its tools are another user's: only the system's part is done.
    let through_sudo = machine.superuser && machine.sudo_user.is_some();
    let user = machine.sudo_user.as_deref().unwrap_or(&machine.user);

    if machine.apt {
        let packages = machine.missing_packages.join(" ");
        step("system packages", rooted(packages.is_empty(), &|sudo| format!("{sudo}apt-get update && {sudo}env DEBIAN_FRONTEND=noninteractive apt-get install -y {packages}")));
        step("Docker", rooted(has("docker"), &|sudo| format!("curl -fsSL https://get.docker.com | {sudo}sh")));
        step("docker group", rooted(machine.docker_group || user == "root", &|sudo| format!("{sudo}usermod -aG docker {user}")));
        // Each worktree's programs run in a bubblewrap sandbox, which needs user namespaces.
        step("worktree sandbox", rooted(machine.sandbox, &|sudo| format!("[ -d /etc/apparmor.d ] || exit 0; printf '%s\\n' 'abi <abi/4.0>,' 'include <tunables/global>' 'profile bwrap /usr/bin/bwrap flags=(unconfined) {{' '  userns,' '  include if exists <local/bwrap>' '}}' | {sudo}tee /etc/apparmor.d/bwrap >/dev/null && {sudo}apparmor_parser -r /etc/apparmor.d/bwrap")));
        // Ubuntu's OOM daemon ends a user's services at 50% memory pressure for 20 seconds, which
        // a few agents building at once reach while the machine still copes: wait for 90% over a minute.
        step("memory pressure", rooted(machine.patient_oom, &|sudo| format!("{sudo}mkdir -p {OOM_USER} {OOM_DAEMON} && printf '[Service]\\nManagedOOMMemoryPressureLimit=90%%\\n' | {sudo}tee {OOM_USER}/90-agentboard.conf >/dev/null && printf '[OOM]\\nDefaultMemoryPressureDurationSec=60s\\n' | {sudo}tee {OOM_DAEMON}/90-agentboard.conf >/dev/null && {sudo}systemctl daemon-reload && {sudo}systemctl try-restart systemd-oomd")));
    } else {
        step("system packages", Action::Skip("no apt-get here: only Debian and Ubuntu are set up automatically".into()));
    }

    let apt_installs = machine.apt && machine.root;
    let mut node = has("node");
    if !through_sudo {
        let wanted: Vec<&str> = [("git", "git"), ("curl", "curl"), ("node", "nodejs"), ("gh", "gh")]
            .iter()
            .filter(|(program, package)| !(has(program) || apt_installs && PACKAGES.contains(package)))
            .map(|(_, package)| *package)
            .collect();
        if wanted.is_empty() {
            step("git, Node and gh", Action::Ok);
        } else {
            let tools = &machine.tools;
            let binary = format!("{tools}/bin/micromamba");
            let suffix = if machine.architecture == "aarch64" || machine.architecture == "arm64" { "aarch64" } else { "64" };
            step("micromamba", if machine.micromamba { Action::Ok } else { Action::Download { url: format!("{MICROMAMBA}{suffix}"), to: binary.clone() } });
            let links = wanted.iter().map(|package| if *package == "nodejs" { "node npm npx" } else { package }).collect::<Vec<_>>().join(" ");
            // A private toolchain from conda-forge, linked into ~/.local/bin: no root involved.
            step(
                &format!("{} (private, in {tools})", wanted.join(", ")),
                Action::Run(format!(
                    "if [ -d '{tools}/env/conda-meta' ]; then verb=install; else verb=create; fi; '{binary}' $verb -y -r '{tools}' -p '{tools}/env' -c conda-forge {} && mkdir -p \"$HOME/.local/bin\" && for program in {links}; do ln -sf '{tools}/env/bin/'$program \"$HOME/.local/bin/$program\"; done",
                    wanted.join(" ")
                )),
            );
            node = true;
        }
    }

    if machine.apt {
        // Playwright installs its own list of libraries, with apt, becoming root by itself.
        let action = match (machine.browser_libraries, node, machine.root) {
            (true, ..) => Action::Ok,
            (_, false, _) => Action::Skip("needs Node: run `agentboard setup` without sudo first".into()),
            (_, _, true) => Action::Run("npx -y playwright install-deps chromium".into()),
            _ => Action::NeedsRoot("sudo env \"PATH=$PATH\" npx -y playwright install-deps chromium".into()),
        };
        step("browser libraries", action);
    }

    if !through_sudo {
        for (program, install) in AGENTS {
            step(program, if has(program) { Action::Ok } else { Action::Run(install.into()) });
        }
        step("Chromium", if machine.chromium { Action::Ok } else { Action::Run("npx -y playwright install chromium".into()) });
        let export = r#"printf '\n# Added by agentboard setup\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.profile""#;
        step("~/.local/bin on PATH", if machine.profile_has_path { Action::Ok } else { Action::Run(export.into()) });
    }
    steps
}

fn output(program: &str, arguments: &[&str]) -> Option<String> {
    let output = Command::new(program).args(arguments).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub(crate) fn on_path(program: &str, path: &str) -> bool {
    path.split(':').any(|folder| std::fs::metadata(Path::new(folder).join(program)).is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0))
}

fn inspect(home: &str, path: &str, sudo_user: Option<String>) -> Machine {
    // SAFETY: geteuid has no preconditions.
    let superuser = unsafe { libc::geteuid() } == 0;
    let user = output("id", &["-un"]).unwrap_or_default();
    let group_of = sudo_user.clone().unwrap_or_else(|| user.clone());
    let tools = config::data_folder().join("tools").to_string_lossy().into_owned();
    // A few of what Chromium links, standing for the list Playwright installs.
    let libraries = output("/sbin/ldconfig", &["-p"]).unwrap_or_default();
    Machine {
        root: superuser || output("sudo", &["-n", "true"]).is_some(),
        superuser,
        sudo_user,
        user,
        apt: on_path("apt-get", path),
        architecture: std::env::consts::ARCH.into(),
        missing_packages: PACKAGES.into_iter().filter(|package| !output("dpkg-query", &["-W", "-f=${Status}", package]).is_some_and(|status| status.ends_with("ok installed"))).collect(),
        programs: ["git", "curl", "node", "gh", "docker", "claude", "codex", "uv"].into_iter().filter(|program| on_path(program, path)).collect(),
        docker_group: output("id", &["-nG", &group_of]).is_some_and(|groups| groups.split(' ').any(|group| group == "docker")),
        patient_oom: !std::path::Path::new("/usr/lib/systemd/systemd-oomd").exists() || [OOM_USER, OOM_DAEMON].iter().all(|folder| std::path::Path::new(&format!("{folder}/90-agentboard.conf")).exists()),
        sandbox: output("bwrap", &["--ro-bind", "/", "/", "/bin/true"]).is_some(),
        browser_libraries: ["libnss3.so", "libgbm.so.1", "libatk-bridge-2.0.so.0"].iter().all(|library| libraries.contains(library)),
        chromium: std::fs::read_dir(format!("{home}/.cache/ms-playwright")).is_ok_and(|entries| entries.flatten().any(|entry| entry.file_name().to_string_lossy().starts_with("chromium"))),
        micromamba: on_path("micromamba", &format!("{tools}/bin")),
        profile_has_path: std::fs::read_to_string(format!("{home}/.profile")).is_ok_and(|profile| profile.contains(".local/bin")),
        tools,
    }
}

fn download(url: &str, to: &str) -> Result<(), String> {
    let failed = |error: &dyn std::fmt::Display| format!("{url}: {error}");
    // Redirects included: nothing is fetched in the clear.
    let agent = ureq::AgentBuilder::new().https_only(true).build();
    let mut body = agent.get(url).call().map_err(|error| failed(&error))?.into_reader();
    let aside = format!("{to}.part");
    std::fs::create_dir_all(Path::new(to).parent().unwrap()).map_err(|error| failed(&error))?;
    let mut file = std::fs::File::create(&aside).map_err(|error| failed(&error))?;
    std::io::copy(&mut body, &mut file).map_err(|error| failed(&error))?;
    std::fs::set_permissions(&aside, std::fs::Permissions::from_mode(0o755)).and_then(|_| std::fs::rename(&aside, to)).map_err(|error| failed(&error))
}

/// `agentboard setup`: one line per step, then what works and what is left.
pub fn setup() -> Result<(), String> {
    if !cfg!(target_os = "linux") {
        println!("Hosts are Linux-only for now: nothing to set up on this machine.");
        return Ok(());
    }
    let sudo_user = std::env::var("SUDO_USER").ok().filter(|user| !user.is_empty() && user != "root");
    // Under sudo the tools are in the home of who ran it, not root's.
    let home = match &sudo_user {
        Some(user) => output("sh", &["-c", &format!("getent passwd '{user}' | cut -d: -f6")]).unwrap_or_default(),
        None => std::env::home_dir().unwrap_or_default().to_string_lossy().into_owned(),
    };
    let path = format!("{home}/.local/bin:{}", std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".into()));
    let machine = inspect(&home, &path, sudo_user);

    let (mut works, mut needs_root, mut failed) = (Vec::new(), Vec::new(), Vec::new());
    for Step { name, action } in plan(&machine) {
        let outcome = match action {
            Action::Ok => "ok".to_string(),
            Action::NeedsRoot(command) => format!("needs root: {command}"),
            Action::Skip(why) => format!("skipped: {why}"),
            Action::Download { url, to } => download(&url, &to).map_or_else(|error| format!("failed: {error}"), |_| "installed".into()),
            Action::Run(command) => {
                let mut shell = Command::new("sh");
                shell.args(["-c", &command]).env("PATH", &path).stdout(std::process::Stdio::null());
                if !machine.superuser {
                    // npm's global installs go to ~/.local, whoever owns Node's own folder.
                    shell.env("npm_config_prefix", format!("{home}/.local"));
                }
                match shell.status() {
                    Ok(status) if status.success() => "installed".into(),
                    Ok(status) => format!("failed: `{command}` ended with {status}"),
                    Err(error) => format!("failed: {error}"),
                }
            }
        };
        println!("{name}: {outcome}");
        let list = if outcome.starts_with("needs root") { &mut needs_root } else if outcome.starts_with("failed") || outcome.starts_with("skipped") { &mut failed } else { &mut works };
        list.push(name);
    }

    println!("\nWorks: {}", works.join(", "));
    if !needs_root.is_empty() {
        // By its full path: sudo's PATH doesn't have ~/.local/bin.
        let program = std::env::current_exe().map_or("agentboard".into(), |path| path.to_string_lossy().into_owned());
        println!("Needs root: {}. To finish, run: sudo {program} setup", needs_root.join(", "));
    }
    if machine.root && !machine.docker_group {
        println!("Docker without sudo starts at your next login (or after a reboot, for the host's service).");
    }
    if failed.is_empty() { Ok(()) } else { Err(format!("Not done: {}", failed.join(", "))) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> Machine {
        Machine { user: "dev".into(), apt: true, architecture: "x86_64".into(), missing_packages: PACKAGES.to_vec(), tools: "/home/dev/.local/share/agentboard/tools".into(), ..Machine::default() }
    }

    fn action<'a>(steps: &'a [Step], name: &str) -> &'a Action {
        &steps.iter().find(|step| step.name.starts_with(name)).unwrap_or_else(|| panic!("no step {name}")).action
    }

    fn names(steps: &[Step]) -> Vec<&str> {
        steps.iter().map(|step| step.name.split(" (").next().unwrap()).collect()
    }

    #[test]
    fn without_root_a_fresh_machine_gets_a_private_toolchain() {
        let steps = plan(&fresh());
        assert_eq!(names(&steps), ["system packages", "Docker", "docker group", "worktree sandbox", "memory pressure", "micromamba", "git, curl, nodejs, gh", "browser libraries", "claude", "codex", "uv", "Chromium", "~/.local/bin on PATH"]);
        assert_eq!(*action(&steps, "system packages"), Action::NeedsRoot("sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates build-essential unzip bubblewrap ffmpeg gh".into()));
        assert_eq!(*action(&steps, "Docker"), Action::NeedsRoot("curl -fsSL https://get.docker.com | sudo sh".into()));
        assert_eq!(*action(&steps, "docker group"), Action::NeedsRoot("sudo usermod -aG docker dev".into()));
        let Action::NeedsRoot(patience) = action(&steps, "memory pressure") else { panic!() };
        assert!(patience.contains("printf '[Service]\\nManagedOOMMemoryPressureLimit=90%%\\n' | sudo tee /etc/systemd/system/user@.service.d/90-agentboard.conf"), "{patience}");
        assert_eq!(
            *action(&steps, "micromamba"),
            Action::Download { url: "https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-64".into(), to: "/home/dev/.local/share/agentboard/tools/bin/micromamba".into() }
        );
        let Action::Run(toolchain) = action(&steps, "git, curl, nodejs, gh") else { panic!() };
        assert!(toolchain.contains("-c conda-forge git curl nodejs gh &&") && toolchain.contains("for program in git curl node npm npx gh;"), "{toolchain}");
        assert_eq!(*action(&steps, "browser libraries"), Action::NeedsRoot("sudo env \"PATH=$PATH\" npx -y playwright install-deps chromium".into()));
        assert_eq!(*action(&steps, "claude"), Action::Run("curl -fsSL https://claude.ai/install.sh | bash".into()));
        assert_eq!(*action(&steps, "codex"), Action::Run("npm install -g @openai/codex".into()));
        assert_eq!(*action(&steps, "Chromium"), Action::Run("npx -y playwright install chromium".into()));
        assert!(matches!(action(&steps, "~/.local/bin"), Action::Run(_)));

        let arm = plan(&Machine { architecture: "aarch64".into(), ..fresh() });
        assert!(matches!(action(&arm, "micromamba"), Action::Download { url, .. } if url.ends_with("/micromamba-linux-aarch64")));
        // Git already there: only Node comes from the toolchain, and nothing downloads twice.
        let partly = plan(&Machine { programs: vec!["git", "curl"], micromamba: true, ..fresh() });
        assert_eq!(*action(&partly, "micromamba"), Action::Ok);
        let Action::Run(toolchain) = action(&partly, "nodejs, gh") else { panic!() };
        assert!(toolchain.contains("-c conda-forge nodejs gh &&") && toolchain.contains("for program in node npm npx gh;"));
        // Every download and script is fetched over HTTPS.
        for step in &steps {
            let text = format!("{:?}", step.action);
            assert!(!text.contains("http://"), "{text}");
        }
    }

    #[test]
    fn with_sudo_the_system_installs_what_it_can_and_node_stays_private() {
        let steps = plan(&Machine { root: true, ..fresh() });
        assert_eq!(names(&steps), ["system packages", "Docker", "docker group", "worktree sandbox", "memory pressure", "micromamba", "nodejs", "browser libraries", "claude", "codex", "uv", "Chromium", "~/.local/bin on PATH"]);
        assert_eq!(*action(&steps, "system packages"), Action::Run("sudo -n apt-get update && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates build-essential unzip bubblewrap ffmpeg gh".into()));
        assert_eq!(*action(&steps, "Docker"), Action::Run("curl -fsSL https://get.docker.com | sudo -n sh".into()));
        assert_eq!(*action(&steps, "docker group"), Action::Run("sudo -n usermod -aG docker dev".into()));
        assert_eq!(*action(&steps, "browser libraries"), Action::Run("npx -y playwright install-deps chromium".into()));
        assert!(!steps.iter().any(|step| matches!(step.action, Action::NeedsRoot(_))));
    }

    #[test]
    fn through_sudo_only_the_systems_part_runs_for_the_user_who_asked() {
        let asked = Machine { root: true, superuser: true, user: "root".into(), sudo_user: Some("dev".into()), programs: vec!["node"], ..fresh() };
        let steps = plan(&asked);
        assert_eq!(names(&steps), ["system packages", "Docker", "docker group", "worktree sandbox", "memory pressure", "browser libraries"]);
        assert_eq!(*action(&steps, "system packages"), Action::Run("apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates build-essential unzip bubblewrap ffmpeg gh".into()));
        assert_eq!(*action(&steps, "docker group"), Action::Run("usermod -aG docker dev".into()));
        assert_eq!(*action(&steps, "browser libraries"), Action::Run("npx -y playwright install-deps chromium".into()));
        // Node is the user's to install first.
        assert!(matches!(action(&plan(&Machine { programs: vec![], ..asked }), "browser libraries"), Action::Skip(_)));

        // Logged in as root itself: everything, and root needs no docker group.
        let root = plan(&Machine { root: true, superuser: true, user: "root".into(), ..fresh() });
        assert_eq!(names(&root).len(), 13);
        assert_eq!(*action(&root, "docker group"), Action::Ok);
    }

    #[test]
    fn a_machine_already_set_up_has_nothing_to_do() {
        let done = Machine {
            missing_packages: vec![],
            programs: vec!["git", "curl", "node", "gh", "docker", "claude", "codex", "uv"],
            docker_group: true,
            sandbox: true,
            patient_oom: true,
            browser_libraries: true,
            chromium: true,
            profile_has_path: true,
            ..fresh()
        };
        for root in [false, true] {
            let steps = plan(&Machine { root, ..done.clone() });
            assert!(steps.iter().all(|step| step.action == Action::Ok), "{steps:?}");
            assert_eq!(names(&steps), ["system packages", "Docker", "docker group", "worktree sandbox", "memory pressure", "git, Node and gh", "browser libraries", "claude", "codex", "uv", "Chromium", "~/.local/bin on PATH"]);
        }
    }

    #[test]
    fn without_apt_the_user_level_setup_still_runs() {
        let steps = plan(&Machine { apt: false, ..fresh() });
        assert!(matches!(action(&steps, "system packages"), Action::Skip(_)));
        assert_eq!(names(&steps), ["system packages", "micromamba", "git, curl, nodejs, gh", "claude", "codex", "uv", "Chromium", "~/.local/bin on PATH"]);
    }
}
