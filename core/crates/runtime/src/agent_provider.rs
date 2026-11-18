use std::cmp::Ordering;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use base64::Engine;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{data_folder, Uuid};

/// A coding agent the board can launch. Everything specific to one agent (its command, how it
/// starts or resumes a conversation, what it needs from the environment) lives behind this;
/// sessions, the terminal and the board only ever see a `LaunchSpec`.
pub trait AgentProvider: Send + Sync {
    /// Stable identifier stored with each card. Never change it once shipped.
    fn id(&self) -> &'static str;
    /// Name on the card and in the Add Agent menu.
    fn title(&self) -> &'static str;
    /// One line under the name in the Add Agent menu, saying what picking it gets.
    fn subtitle(&self) -> &'static str {
        ""
    }
    /// Command looked up in the user's PATH.
    fn executable(&self) -> &'static str;
    /// Shell command that installs `executable`, shown on the card when it is missing.
    fn install_command(&self) -> Option<&'static str> {
        None
    }
    /// The agent's brand color (sRGB hex) for its mark on the card; none draws it in ink.
    fn brand_color(&self) -> Option<u32> {
        None
    }
    /// Arguments that start the conversation bound to `session`, or resume it if it exists, with
    /// the board's tools available through `tools` when given.
    fn arguments(&self, session: Uuid, tools: Option<&ToolServerLink>) -> Vec<String>;
    /// Adjusts the environment inherited from the core.
    fn environment(&self, base: HashMap<String, String>) -> HashMap<String, String> {
        base
    }
}

/// Where an agent reaches the board's tools: an MCP server over HTTP, and the token that
/// identifies this agent to it.
#[derive(Clone, Debug)]
pub struct ToolServerLink {
    pub name: String,
    pub url: String,
    pub token: String,
}

/// The agents the app knows about. Adding one means adding a provider here.
pub struct AgentCatalog;

impl AgentCatalog {
    pub fn all() -> [&'static dyn AgentProvider; 3] {
        [&ClaudeCode, &Codex, &Copilot]
    }

    pub fn provider(id: &str) -> Option<&'static dyn AgentProvider> {
        Self::all().into_iter().find(|provider| provider.id() == id)
    }

    /// Where agent CLIs usually land, for when the login shell's PATH misses them.
    pub fn fallback_directories(home: &str) -> Vec<String> {
        let mut directories = vec!["/opt/homebrew/bin".to_string(), "/usr/local/bin".to_string()];
        directories.extend([".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin", ".claude/local"].map(|folder| format!("{home}/{folder}")));
        directories.extend(Self::nvm_directories(home));
        directories
    }

    /// nvm's node versions, newest first: a service never sources nvm, so its PATH is missing.
    fn nvm_directories(home: &str) -> Vec<String> {
        let root = format!("{home}/.nvm/versions/node");
        let mut versions: Vec<String> = std::fs::read_dir(&root).into_iter().flatten().flatten().map(|entry| entry.file_name().to_string_lossy().into_owned()).collect();
        versions.sort_by(|a, b| numeric_compare(b, a));
        versions.into_iter().map(|version| format!("{root}/{version}/bin")).collect()
    }

    /// The executable's path: as given when absolute, else the first match in `search_path`
    /// and then in `fallbacks`. None when it isn't installed.
    pub fn locate(name: &str, search_path: &str, fallbacks: &[String]) -> Option<String> {
        if name.starts_with('/') {
            return is_executable_file(name).then(|| name.to_string());
        }
        search_path.split(':').filter(|folder| !folder.is_empty()).chain(fallbacks.iter().map(String::as_str)).map(|folder| format!("{folder}/{name}")).find(|path| is_executable_file(path))
    }
}

fn is_executable_file(path: &str) -> bool {
    let Ok(c_path) = std::ffi::CString::new(path) else { return false };
    // SAFETY: access reads a NUL-terminated path that outlives the call.
    Path::new(path).is_file() && unsafe { libc::access(c_path.as_ptr(), libc::X_OK) } == 0
}

/// Orders text as Foundation's `.numeric` comparison does: runs of digits by their value.
fn numeric_compare(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let run = |text: &[u8], from: usize| text[from..].iter().take_while(|byte| byte.is_ascii_digit()).count();
            let (end_a, end_b) = (i + run(a, i), j + run(b, j));
            let significant = |digits: &[u8]| digits.iter().position(|digit| *digit != b'0').map_or(&digits[digits.len()..], |start| &digits[start..]).to_vec();
            let (number_a, number_b) = (significant(&a[i..end_a]), significant(&b[j..end_b]));
            let order = number_a.len().cmp(&number_b.len()).then_with(|| number_a.cmp(&number_b));
            if order != Ordering::Equal {
                return order;
            }
            (i, j) = (end_a, end_b);
        } else if a[i] != b[j] {
            return a[i].cmp(&b[j]);
        } else {
            (i, j) = (i + 1, j + 1);
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

/// Anthropic's Claude Code CLI.
pub struct ClaudeCode;

impl AgentProvider for ClaudeCode {
    fn id(&self) -> &'static str {
        "claude"
    }
    fn title(&self) -> &'static str {
        "Claude"
    }
    /// The orange of Claude's mark.
    fn brand_color(&self) -> Option<u32> {
        Some(0xD97757)
    }
    fn subtitle(&self) -> &'static str {
        "Anthropic's Claude Code"
    }
    fn executable(&self) -> &'static str {
        "claude"
    }
    fn install_command(&self) -> Option<&'static str> {
        Some("curl -fsSL https://claude.ai/install.sh | bash")
    }

    fn arguments(&self, session: Uuid, tools: Option<&ToolServerLink>) -> Vec<String> {
        let id = session.lowercased();
        // Agents run unattended on the board: they never stop to ask for a permission.
        let mut arguments = vec!["--dangerously-skip-permissions".to_string()];
        if let Some(tools) = tools {
            // Both options take several values: each is ended by the next option.
            arguments.extend(["--mcp-config".to_string(), Self::mcp_config(tools), "--allowedTools".to_string(), format!("mcp__{}", tools.name)]);
        }
        arguments.extend(["--settings".to_string(), Self::settings(tools)]);
        if let Some(plugin) = tools.and_then(|_| board_plugin()) {
            arguments.extend(["--plugin-dir".to_string(), plugin.to_string_lossy().into_owned()]);
        }
        let resume = Self::conversation_exists(&id, &data_folder::home_directory());
        arguments.extend([if resume { "--resume" } else { "--session-id" }.to_string(), id]);
        arguments
    }

    /// Drops markers inherited when the core itself was launched from Claude Code, so the child
    /// behaves like a top-level session (child sessions don't save transcripts, which would
    /// make them impossible to resume).
    fn environment(&self, mut base: HashMap<String, String>) -> HashMap<String, String> {
        base.retain(|key, _| !key.starts_with("CLAUDE_CODE") && key != "CLAUDECODE");
        base
    }
}

/// How to use the board's tools, as a skill (see `board_skill.md`).
pub const BOARD_SKILL: &str = include_str!("board_skill.md");

/// The board's skill as a plugin Claude Code loads for one launch (`--plugin-dir`), kept in the
/// data folder, never in the user's own config. None where no data folder may be used (tests
/// without their own) or it can't be written.
fn board_plugin() -> Option<PathBuf> {
    let data_folder::Resolution::Folder(folder) = data_folder::resolve(&std::env::vars().collect(), data_folder::runs_under_tests()) else { return None };
    write_board_plugin(&folder.join("agent-plugin")).ok()
}

/// Writes the plugin at `root` when it differs, so a launch rarely touches the disk.
fn write_board_plugin(root: &Path) -> std::io::Result<PathBuf> {
    let files = [(root.join(".claude-plugin/plugin.json"), r#"{"name": "agentboard"}"#), (root.join("skills/board/SKILL.md"), BOARD_SKILL)];
    for (path, contents) in files {
        if std::fs::read_to_string(&path).ok().as_deref() != Some(contents) {
            std::fs::create_dir_all(path.parent().unwrap())?;
            std::fs::write(&path, contents)?;
        }
    }
    Ok(root.to_path_buf())
}

impl ClaudeCode {
    /// The board's server as an inline `--mcp-config`. Its tools are allowed up front: they only
    /// reach agents the user connected.
    fn mcp_config(tools: &ToolServerLink) -> String {
        let server = json!({"type": "http", "url": tools.url, "headers": {"Authorization": format!("Bearer {}", tools.token)}});
        json!({"mcpServers": {tools.name.as_str(): server}}).to_string()
    }

    /// Hooks that tell the board when the agent waits on the developer (it ended its turn, or
    /// Claude Code notified) and when it works again (a prompt was submitted). Each forwards
    /// its payload untouched, base64 in a desktop notification (OSC 9) written to the agent's
    /// terminal, where the core reads it (see `AgentHook`). With the board's tools it posts to
    /// the board's server instead, since a hook may run without a terminal to write to.
    fn attention_hook(tools: Option<&ToolServerLink>) -> Value {
        match tools {
            None => json!({
                "type": "command",
                "command": format!(r#"printf '\033]9;{}%s\007' "$(base64 | tr -d '\n')" > /dev/tty 2>/dev/null || true"#, AgentHook::PREFIX),
            }),
            Some(tools) => json!({
                "type": "command", "timeout": 5,
                "command": format!("curl -s -m 3 -o /dev/null -X POST -H 'Authorization: Bearer {}' --data-binary @- '{}/attention' || true", tools.token, tools.url),
            }),
        }
    }

    /// A hook that hands its input to the board's server and prints what comes back: the
    /// context the agent should have before going on (connected post-its), which Claude Code
    /// adds to the conversation.
    fn context_hook(tools: &ToolServerLink) -> Value {
        json!({
            "type": "command", "timeout": 5,
            "command": format!("curl -s -m 3 -X POST -H 'Authorization: Bearer {}' --data-binary @- '{}/context' || true", tools.token, tools.url),
        })
    }

    /// A hook that hands the questions the agent is about to ask (AskUserQuestion) to the board
    /// and waits for the developer's answers, which it prints for Claude Code to take instead of
    /// asking in the terminal. When the board is gone, or the developer chooses the terminal, it
    /// prints nothing and Claude Code asks there as usual.
    fn question_hook(tools: &ToolServerLink) -> Value {
        json!({
            "type": "command", "timeout": 86400,
            "command": format!("curl -s -m 86400 -X POST -H 'Authorization: Bearer {}' --data-binary @- '{}/question' || true", tools.token, tools.url),
        })
    }

    /// The attention hooks, and the context and question hooks when the agent has the board's tools.
    fn settings(tools: Option<&ToolServerLink>) -> String {
        let entry = |hooks: Vec<Value>| json!([{ "hooks": hooks }]);
        let attention = Self::attention_hook(tools);
        let mut hooks = json!({"Stop": entry(vec![attention.clone()]), "Notification": entry(vec![attention.clone()])});
        match tools {
            None => hooks["UserPromptSubmit"] = entry(vec![attention]),
            Some(tools) => {
                let context = Self::context_hook(tools);
                hooks["UserPromptSubmit"] = entry(vec![attention, context.clone()]);
                hooks["SessionStart"] = entry(vec![context.clone()]);
                hooks["PostToolUse"] = entry(vec![context]);
                hooks["PreToolUse"] = json!([{"matcher": "AskUserQuestion", "hooks": [Self::question_hook(tools)]}]);
            }
        }
        // Fullscreen is where Claude takes the mouse: selecting and copying terminal text on the
        // card only works there, whatever the host's own settings say.
        json!({ "hooks": hooks, "tui": "fullscreen" }).to_string()
    }

    /// Claude Code writes each conversation to ~/.claude/projects/<escaped cwd>/<session>.jsonl
    /// only after the first message, so an agent that was never used must start fresh.
    fn conversation_exists(id: &str, home: &Path) -> bool {
        let name = format!("{id}.jsonl");
        std::fs::read_dir(home.join(".claude/projects")).into_iter().flatten().flatten().any(|folder| folder.path().join(&name).exists())
    }
}

/// OpenAI's Codex CLI. Its config is overridden per launch (`-c`), never in ~/.codex/config.toml.
pub struct Codex;

impl AgentProvider for Codex {
    fn id(&self) -> &'static str {
        "codex"
    }
    fn title(&self) -> &'static str {
        "Codex"
    }
    fn subtitle(&self) -> &'static str {
        "OpenAI's Codex CLI"
    }
    fn executable(&self) -> &'static str {
        "codex"
    }
    fn install_command(&self) -> Option<&'static str> {
        Some("npm install -g @openai/codex")
    }

    fn arguments(&self, session: Uuid, tools: Option<&ToolServerLink>) -> Vec<String> {
        // Agents run unattended on the board: they never stop to ask for a permission.
        let mut arguments = vec!["--dangerously-bypass-approvals-and-sandbox".to_string()];
        if let Some(tools) = tools {
            let server = format!("mcp_servers.{}", tools.name);
            arguments.extend([
                "-c".to_string(),
                format!("{server}.url={}", toml(&tools.url)),
                "-c".to_string(),
                format!("{server}.http_headers={{Authorization={}}}", toml(&format!("Bearer {}", tools.token))),
                "-c".to_string(),
                format!("notify={}", Self::notify(tools)),
            ]);
        }
        // Codex picks its own thread ids; the first turn's notify reports it (as `session_id`)
        // and the card keeps it as its conversation, so later launches resume it.
        let id = session.lowercased();
        let home = std::env::var("CODEX_HOME").unwrap_or_else(|_| data_folder::home_directory().join(".codex").to_string_lossy().into_owned());
        if Self::conversation_exists(&id, Path::new(&home)) {
            arguments.insert(0, "resume".to_string());
            arguments.push(id);
        }
        arguments
    }
}

impl Codex {
    /// Codex's `notify` program gets its payload as the last argument, keys in kebab-case; this
    /// renames the fields the board reads to Claude Code's hook names and posts it as an
    /// attention hook. Codex only notifies the end of a turn.
    fn notify(tools: &ToolServerLink) -> String {
        let script = format!(
            concat!(
                r#"printf '%s' "$1" | sed -e 's/"type":"agent-turn-complete"/"hook_event_name":"Stop"/' "#,
                r#"-e 's/"thread-id"/"session_id"/' -e 's/"last-assistant-message"/"last_assistant_message"/' "#,
                "| curl -s -m 3 -o /dev/null -X POST -H 'Authorization: Bearer {}' --data-binary @- '{}/attention'"
            ),
            tools.token, tools.url
        );
        format!("[{}]", ["sh", "-c", &script, "sh"].map(toml).join(","))
    }

    /// Codex keeps each thread in $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl.
    fn conversation_exists(id: &str, codex_home: &Path) -> bool {
        fn contains(folder: &Path, suffix: &str) -> bool {
            std::fs::read_dir(folder).into_iter().flatten().flatten().any(|entry| {
                let path = entry.path();
                path.to_string_lossy().ends_with(suffix) || (path.is_dir() && contains(&path, suffix))
            })
        }
        contains(&codex_home.join("sessions"), &format!("-{id}.jsonl"))
    }
}

/// A TOML basic string (JSON's escaping is valid TOML).
fn toml(value: &str) -> String {
    Value::from(value).to_string()
}

/// GitHub's Copilot CLI. The board's server joins its MCP config for this launch only
/// (`--additional-mcp-config`), never ~/.copilot/mcp-config.json.
// shortcut: no "waiting for you" state; the CLI shows no hook or notify option in --help (v1.0.61). Add one when it does.
pub struct Copilot;

impl AgentProvider for Copilot {
    fn id(&self) -> &'static str {
        "copilot"
    }
    fn title(&self) -> &'static str {
        "Copilot"
    }
    fn subtitle(&self) -> &'static str {
        "GitHub's Copilot CLI"
    }
    fn executable(&self) -> &'static str {
        "copilot"
    }
    fn install_command(&self) -> Option<&'static str> {
        Some("npm install -g @github/copilot")
    }

    fn arguments(&self, session: Uuid, tools: Option<&ToolServerLink>) -> Vec<String> {
        // Agents run unattended on the board: they never stop to ask for a permission.
        let mut arguments = vec!["--allow-all".to_string()];
        if let Some(tools) = tools {
            arguments.extend(["--additional-mcp-config".to_string(), Self::mcp_config(tools)]);
        }
        // `--session-id` starts a session with this id, or resumes it when it exists.
        arguments.extend(["--session-id".to_string(), session.lowercased()]);
        arguments
    }
}

impl Copilot {
    /// The board's server in the shape `copilot mcp add --transport http` writes. Keys are
    /// written in order, so the text doesn't depend on how serde_json keeps its maps.
    fn mcp_config(tools: &ToolServerLink) -> String {
        let server = json!({"headers": {"Authorization": format!("Bearer {}", tools.token)}, "tools": ["*"], "type": "http", "url": tools.url});
        json!({"mcpServers": {tools.name.as_str(): server}}).to_string()
    }
}

/// What an agent's hook forwards (see `ClaudeCode::attention_hook`): Claude Code's hook
/// input, of which only these fields matter.
#[derive(Clone, Debug, Deserialize)]
pub struct AgentHook {
    pub hook_event_name: String,
    /// The conversation the hook fired in; a new one after `/clear`.
    pub session_id: Option<String>,
    pub message: Option<String>,
    pub notification_type: Option<String>,
    /// The conversation so far, as Claude Code keeps it (JSONL).
    pub transcript_path: Option<String>,
    /// Stop only, from Claude Code versions that send it: what the agent said last.
    pub last_assistant_message: Option<String>,
}

impl AgentHook {
    /// Starts a notification that carries a hook's payload.
    pub const PREFIX: &'static str = "agentboard-hook:";

    /// The hook a notification carries; none for any other notification.
    pub fn from_notification(notification: &str) -> Option<Self> {
        let data = base64::engine::general_purpose::STANDARD.decode(notification.strip_prefix(Self::PREFIX)?).ok()?;
        serde_json::from_slice(&data).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn link() -> ToolServerLink {
        ToolServerLink { name: "board".into(), url: "http://127.0.0.1:9/mcp".into(), token: "secret".into() }
    }

    #[test]
    fn catalog_offers_codex_with_an_install_command() {
        let codex = AgentCatalog::provider("codex").unwrap();
        assert_eq!(codex.executable(), "codex");
        assert_eq!(codex.install_command(), Some("npm install -g @openai/codex"));
        assert_eq!(AgentCatalog::all().map(|provider| provider.id()), ["claude", "codex", "copilot"]);
        assert_eq!(AgentCatalog::provider("copilot").unwrap().title(), "Copilot");
    }

    #[test]
    fn locate_searches_path_then_fallbacks() {
        let folder = std::env::temp_dir().join(Uuid::new().to_string());
        std::fs::create_dir_all(&folder).unwrap();
        let tool = folder.join("fake-agent");
        std::fs::write(&tool, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&tool, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        let (folder_text, tool_text) = (folder.to_str().unwrap().to_string(), tool.to_str().unwrap().to_string());

        assert_eq!(AgentCatalog::locate("fake-agent", "/usr/bin:/bin", &[]), None);
        assert_eq!(AgentCatalog::locate("fake-agent", "/usr/bin:/bin", &[folder_text.clone()]), Some(tool_text.clone()));
        assert_eq!(AgentCatalog::locate("fake-agent", &folder_text, &[]), Some(tool_text.clone()));
        assert_eq!(AgentCatalog::locate("sh", "/bin", &[folder_text.clone()]), Some("/bin/sh".into()));
        assert_eq!(AgentCatalog::locate(&tool_text, "", &[]), Some(tool_text));
        assert_eq!(AgentCatalog::locate(&folder_text, "", &[]), None);
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn codex_gets_the_board_per_launch() {
        let arguments = Codex.arguments(Uuid::new(), Some(&link()));
        assert_eq!(arguments[0], "--dangerously-bypass-approvals-and-sandbox");
        assert!(arguments.contains(&r#"mcp_servers.board.url="http://127.0.0.1:9/mcp""#.to_string()));
        assert!(arguments.contains(&r#"mcp_servers.board.http_headers={Authorization="Bearer secret"}"#.to_string()));
        assert!(arguments.iter().any(|argument| argument.starts_with(r#"notify=["sh","-c","#) && argument.contains("/mcp/attention") && argument.ends_with(r#","sh"]"#)));
        // A conversation Codex never saved starts fresh.
        assert!(!arguments.contains(&"resume".to_string()));
        assert_eq!(Codex.arguments(Uuid::new(), None), ["--dangerously-bypass-approvals-and-sandbox"]);
    }

    #[test]
    fn codex_resumes_a_saved_conversation() {
        let home = std::env::temp_dir().join(Uuid::new().to_string());
        let day = home.join("sessions/2026/11/16");
        std::fs::create_dir_all(&day).unwrap();
        std::fs::write(day.join("rollout-2026-11-16T10-00-00-abc.jsonl"), "").unwrap();
        assert!(Codex::conversation_exists("abc", &home));
        assert!(!Codex::conversation_exists("abd", &home));
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn copilot_gets_the_board_per_launch() {
        let session = Uuid::new();
        let config = r#"{"mcpServers":{"board":{"headers":{"Authorization":"Bearer secret"},"tools":["*"],"type":"http","url":"http://127.0.0.1:9/mcp"}}}"#;
        assert_eq!(Copilot.arguments(session, Some(&link())), ["--allow-all", "--additional-mcp-config", config, "--session-id", &session.lowercased()]);
        assert_eq!(Copilot.arguments(session, None), ["--allow-all", "--session-id", &session.lowercased()]);
    }

    #[test]
    fn the_board_plugin_carries_the_skill_and_is_rewritten_only_when_stale() {
        let root = std::env::temp_dir().join(format!("board-plugin-{}", Uuid::new().lowercased()));
        let skill = root.join("skills/board/SKILL.md");
        write_board_plugin(&root).unwrap();
        assert_eq!(std::fs::read_to_string(&skill).unwrap(), BOARD_SKILL);
        assert!(std::fs::read_to_string(root.join(".claude-plugin/plugin.json")).unwrap().contains("agentboard"));
        std::fs::write(&skill, "old").unwrap();
        write_board_plugin(&root).unwrap();
        assert_eq!(std::fs::read_to_string(&skill).unwrap(), BOARD_SKILL);
        assert!(BOARD_SKILL.starts_with("---\nname: board\n"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn claude_gets_the_board_and_its_hooks() {
        let session = Uuid::new();
        let arguments = ClaudeCode.arguments(session, Some(&link()));
        assert_eq!(arguments[..2], ["--dangerously-skip-permissions", "--mcp-config"]);
        let config: Value = serde_json::from_str(&arguments[2]).unwrap();
        assert_eq!(config["mcpServers"]["board"], json!({"type": "http", "url": "http://127.0.0.1:9/mcp", "headers": {"Authorization": "Bearer secret"}}));
        assert_eq!(arguments[3..6], ["--allowedTools", "mcp__board", "--settings"]);
        let settings: Value = serde_json::from_str(&arguments[6]).unwrap();
        let hooks = settings["hooks"].as_object().unwrap();
        assert_eq!(hooks.keys().collect::<std::collections::BTreeSet<_>>().into_iter().collect::<Vec<_>>(), ["Notification", "PostToolUse", "PreToolUse", "SessionStart", "Stop", "UserPromptSubmit"]);
        assert_eq!(hooks["UserPromptSubmit"][0]["hooks"].as_array().unwrap().len(), 2);
        assert_eq!(hooks["PreToolUse"][0]["matcher"], "AskUserQuestion");
        assert!(hooks["Stop"][0]["hooks"][0]["command"].as_str().unwrap().contains("'http://127.0.0.1:9/mcp/attention'"));
        assert_eq!(arguments[arguments.len() - 2..], ["--session-id".to_string(), session.lowercased()]);

        // Without the board's tools only the attention hook, through the terminal.
        let alone = ClaudeCode.arguments(session, None);
        assert_eq!(alone[1], "--settings");
        let settings: Value = serde_json::from_str(&alone[2]).unwrap();
        assert_eq!(settings["hooks"].as_object().unwrap().len(), 3);
        assert_eq!(settings["hooks"]["Stop"][0]["hooks"][0]["command"], r#"printf '\033]9;agentboard-hook:%s\007' "$(base64 | tr -d '\n')" > /dev/tty 2>/dev/null || true"#);

        let environment = ClaudeCode.environment([("CLAUDECODE", "1"), ("CLAUDE_CODE_ENTRYPOINT", "cli"), ("PATH", "/bin")].map(|(key, value)| (key.to_string(), value.to_string())).into());
        assert_eq!(environment.keys().collect::<Vec<_>>(), ["PATH"]);
    }

    #[test]
    fn nvm_versions_are_searched_newest_first() {
        let home = std::env::temp_dir().join(Uuid::new().to_string()).to_string_lossy().into_owned();
        for version in ["v9.1.0", "v24.13.1", "v18.0.0"] {
            std::fs::create_dir_all(format!("{home}/.nvm/versions/node/{version}/bin")).unwrap();
        }
        let directories = AgentCatalog::fallback_directories(&home);
        assert_eq!(directories[directories.len() - 3..], ["v24.13.1", "v18.0.0", "v9.1.0"].map(|version| format!("{home}/.nvm/versions/node/{version}/bin")));
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_hook_travels_in_a_notification() {
        let payload = base64::engine::general_purpose::STANDARD.encode(r#"{"hook_event_name":"Stop","session_id":"s","extra":1}"#);
        let hook = AgentHook::from_notification(&format!("agentboard-hook:{payload}")).unwrap();
        assert_eq!((hook.hook_event_name.as_str(), hook.session_id.as_deref(), hook.message), ("Stop", Some("s"), None));
        assert!(AgentHook::from_notification("build finished").is_none());
    }
}
