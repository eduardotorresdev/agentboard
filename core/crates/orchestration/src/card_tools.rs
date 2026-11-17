use serde_json::{json, Map, Value};

use connections::{find_element, BoardName, Element, ElementKind, Reply, ToolDefinition, ToolProvider, ToolResult, Uuid};

use crate::cards::AgentRecord;
use crate::orchestrator::{is_inline_space, Turn};

/// Cards the other tools don't add or close: an agent starts agents and plain terminals next
/// to it, and closes the agents, post-its and browsers connected to it.
pub(crate) struct CardTools;

fn schema(properties: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": properties, "required": required})
}

fn which(word: &str) -> Value {
    json!({"type": "string", "description": format!("Which connected {word}, by name or id (as list_peers shows it). Needed only when several are connected.")})
}

impl<'a> ToolProvider<Turn<'a>> for CardTools {
    fn tools(&self, turn: &mut Turn<'a>, _caller: Uuid) -> Vec<ToolDefinition> {
        let ids: Vec<&str> = turn.providers.iter().map(|provider| provider.id()).collect();
        let agents = turn.providers.iter().map(|provider| format!("{} ({})", provider.id(), provider.title())).collect::<Vec<_>>().join(", ");
        vec![
            ToolDefinition::with_schema(
                "agent_start",
                "Adds an agent card to the board next to you, in your worktree, connected to you, and starts it. Tell it what to do with send_message.",
                schema(
                    json!({
                        "agent": {"type": "string", "enum": ids, "description": format!("Which agent to run: {agents}.")},
                        "name": {"type": "string", "description": "Card name, which is how you address it. Named after the agent when left out."},
                    }),
                    &["agent"],
                ),
            ),
            ToolDefinition::with_schema(
                "agent_close",
                "Ends an agent connected to you and removes its card from the board. Whatever it was doing stops; close only agents you no longer need.",
                schema(json!({"agent": which("agent")}), &[]),
            ),
            ToolDefinition::with_schema(
                "terminal_open",
                "Adds a plain terminal (the user's login shell, no command) as a runner card next to you, connected to you. Type into it with runner_input, read it with runner_logs, remove it with runner_close.",
                schema(json!({"name": {"type": "string", "description": "Card name. “terminal” when left out."}}), &[]),
            ),
            ToolDefinition::with_schema("postit_remove", "Takes a connected post-it off the board, with its text.", schema(json!({"postit": which("post-it")}), &[])),
            ToolDefinition::with_schema("browser_close", "Closes a connected browser and removes its card from the board. Needs the board open.", schema(json!({"browser": which("browser")}), &[])),
        ]
    }

    fn call(&mut self, turn: &mut Turn<'a>, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        if name == "browser_close" {
            return turn.relay(name, arguments, caller, reply);
        }
        reply.send(answer(turn, name, arguments, caller).map_or_else(ToolResult::error, ToolResult::text))
    }
}

fn answer(turn: &mut Turn, name: &str, arguments: &Map<String, Value>, caller: Uuid) -> Result<String, String> {
    match name {
        "agent_start" | "terminal_open" => {
            let me = turn.record(caller).filter(|me| me.runner.is_none()).cloned().ok_or("Only agents on the board can add cards.")?;
            let card_name = BoardName::argument(arguments.get("name")).map_err(|error| error.to_string())?;
            if name == "terminal_open" {
                let origin = turn.origin(&me, AgentRecord::RUNNER_SIZE);
                let record = turn.add_runner("", card_name.as_deref(), None, Some(caller), &me.worktree, origin);
                return Ok(format!("Opened terminal “{}”, connected to you.", record.name));
            }
            let wanted = arguments.get("agent").and_then(Value::as_str).unwrap_or("").trim_matches(is_inline_space);
            let provider = turn.providers.iter().find(|provider| provider.id() == wanted).or_else(|| turn.providers.iter().find(|provider| provider.title().eq_ignore_ascii_case(wanted))).copied();
            let Some(provider) = provider else {
                let ids = turn.providers.iter().map(|provider| provider.id()).collect::<Vec<_>>().join(", ");
                return Err(format!("No agent “{wanted}”. Give `agent` one of: {ids}."));
            };
            let record = turn.add_agent(provider, card_name.as_deref(), &me);
            Ok(format!("Started agent “{}”, connected to you. Tell it what to do with send_message.", record.name))
        }
        "agent_close" => {
            let element = connected(turn, &ElementKind::agent(), "agent", arguments.get("agent"), caller)?;
            turn.remove(element.id, None);
            Ok(format!("Ended {} and removed its card.", element.name))
        }
        "postit_remove" => {
            let element = connected(turn, &ElementKind::post_it(), "post-it", arguments.get("postit"), caller)?;
            turn.remove_post_it(element.id, None);
            Ok(format!("Removed “{}” from the board.", element.name))
        }
        _ => Err(format!("Unknown tool “{name}”.")),
    }
}

/// The `kind` element connected to `caller` that `address` names, or the only one.
fn connected(turn: &Turn, kind: &ElementKind, word: &str, address: Option<&Value>, caller: Uuid) -> Result<Element, String> {
    let found = turn.bus.peers_of_kind(caller, kind, &turn.board);
    if found.is_empty() {
        return Err(format!("No {word} is connected to you."));
    }
    let names = || found.iter().map(|element| element.name.as_str()).collect::<Vec<_>>().join(", ");
    if let Some(address) = address.and_then(Value::as_str).map(|address| address.trim_matches(is_inline_space)).filter(|address| !address.is_empty()) {
        return find_element(address, &found).cloned().ok_or_else(|| format!("No {word} named “{address}” is connected to you. Connected: {}.", names()));
    }
    match found.as_slice() {
        [only] => Ok(only.clone()),
        _ => Err(format!("Several are connected; say which: {}.", names())),
    }
}
