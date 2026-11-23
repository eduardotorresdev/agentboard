use serde_json::{json, Map, Value};

use connections::{find_element, ElementKind, Reply, ToolDefinition, ToolProvider, ToolResult, Uuid};

use crate::board_protocol::now;
use crate::decision::{Card, Decision, DecisionDraft, Evidence, State, FAMILIES, KINDS, MAX_CARDS, MAX_LABEL_WORDS, VARIANTS};
use crate::orchestrator::Turn;

/// The decision tools: the only way an agent asks the developer something on the board. It
/// opens a decision and carries on; the answer reaches it later as a prompt. A port of
/// `DecisionTools.swift`.
pub(crate) struct DecisionTools;

const POINTER: &str = "To ask the user anything, open a decision with decision_open: a loose question in your terminal opens no balloon. \
     Read the guide first, once: decision_guide, or the Decisions section of the board skill.";

/// The board skill's section on decisions, served by `decision_guide` to agents no skill reaches.
pub(crate) fn guide() -> &'static str {
    let skill = runtime::BOARD_SKILL;
    let Some(start) = skill.find("## Decisions") else { return "" };
    let rest = &skill[start..];
    let end = rest[3..].find("\n## ").map_or(rest.len(), |at| at + 3);
    rest[..end].trim()
}

fn is_agent(turn: &Turn, caller: Uuid) -> bool {
    turn.record(caller).is_some_and(|record| record.runner.is_none())
}

impl<'a> ToolProvider<Turn<'a>> for DecisionTools {
    fn instructions(&self, turn: &mut Turn<'a>, caller: Uuid) -> Option<String> {
        is_agent(turn, caller).then(|| POINTER.to_string())
    }

    /// Agents that were running before these tools existed never read the instructions again:
    /// they get the pointer here, once, and again when their session starts over.
    fn context(&mut self, turn: &mut Turn<'a>, caller: Uuid, event: &str) -> Option<String> {
        if !is_agent(turn, caller) || !(event == "SessionStart" || !turn.pointed_at_decisions.contains(&caller)) {
            return None;
        }
        turn.pointed_at_decisions.insert(caller);
        Some(POINTER.to_string())
    }

    fn tools(&self, turn: &mut Turn<'a>, caller: Uuid) -> Vec<ToolDefinition> {
        if !is_agent(turn, caller) {
            return Vec::new();
        }
        let which = json!({"type": "string", "description": "The decision's id, as decision_open gave it. Needed only when you have several open."});
        let element = "by name or id (as list_peers shows it); it must be connected to you";
        vec![
            ToolDefinition::with_schema(
                "decision_guide",
                "How to ask the user: when to decide alone, the three families, evidence, the visual budget, verifying first. Read it once before your first decision_open.",
                json!({"type": "object", "properties": {}, "required": []}),
            ),
            ToolDefinition::with_schema(
                "decision_open",
                "Shows the user a decision as a balloon pointing at your card: cards of evidence, then one ask. The only way to ask the \
                 user something. Returns at once: carry on with your own choice (provisional) unless it is `blocking`; the answer \
                 arrives later as a message. Read decision_guide first. A malformed decision is refused with the reason.",
                json!({"type": "object", "properties": {
                    "family": {"type": "string", "enum": FAMILIES,
                               "description": "surface: what a screen shows. flow: how the experience is walked through. foundation: what the rest is built on or will follow."},
                    "framing": {"type": "string", "description": "One line: what the user is about to evaluate, e.g. `Validate the invite screen`."},
                    "intent": {"type": "string", "description": "One line: what the user should notice. Your own check; not shown."},
                    "cards": {"type": "array", "description": format!("1 to {MAX_CARDS} cards, one idea each."), "items": {
                        "type": "object", "properties": {
                            "claim": {"type": "string", "description": "What the evidence shows, e.g. `The screen ended up like this`."},
                            "evidence": {"type": "object", "description": format!("An image on the board, {element}; or a diagram you draw as SVG."), "properties": {
                                "type": {"type": "string", "enum": KINDS},
                                "svg": {"type": "string", "description": "A diagram's SVG (type diagram): the subset decision_guide describes, at most 64 KB."},
                                "after": {"type": "string", "description": "The image to evaluate (put a screenshot on the board with image_create)."},
                                "before": {"type": "string", "description": "The image it replaces, shown behind a draggable divider."},
                            }, "required": ["type"]},
                            "reference": {"type": "string", "description": "What to compare against when there is no `before`: the justification or the alternative. Never “we already do it this way”."},
                            "pins": {"type": "array", "description": "Doubts at an exact place of the evidence, within this decision's scope.", "items": {
                                "type": "object", "properties": {
                                    "x": {"type": "number", "description": "0 to 1 from the left."},
                                    "y": {"type": "number", "description": "0 to 1 from the top."},
                                    "question": {"type": "string"},
                                }, "required": ["x", "y", "question"]}},
                        }, "required": ["claim", "evidence"]}},
                    "ask": {"type": "object", "description": "The one question. Without `variants` the user validates (OK); with them the user picks one. Redirect is always there.", "properties": {
                        "question": {"type": "string", "description": "E.g. `Can the screen stay like this?`"},
                        "variants": {"type": "array", "description": format!("{} to {} alternatives, lettered A, B, C in order. Don't recommend one.", VARIANTS.0, VARIANTS.1), "items": {
                            "type": "object", "properties": {
                                "name": {"type": "string", "description": format!("At most {MAX_LABEL_WORDS} words, e.g. `Dense list`.")},
                                "detail": {"type": "string", "description": "One line: what choosing it means."},
                            }, "required": ["name"]}},
                    }, "required": ["question"]},
                    "verified": {"type": "array", "items": {"type": "string"}, "description": "What you checked before asking, one line each."},
                    "blocking": {"type": "boolean", "description": "True only when it can't be undone or you can't go on: you then wait for the answer."},
                    "final": {"type": "boolean", "description": "True for the decision that closes the worktree's work, showing how the feature ended up."},
                }, "required": ["family", "framing", "intent", "cards", "ask", "verified"]}),
            ),
            ToolDefinition::with_schema(
                "decision_echo",
                "Says back in one line what you understood from the user's answer (a redirect, a choice given back to you, or an answer typed in your terminal) and closes the decision. Don't wait for confirmation after it.",
                json!({"type": "object", "properties": {
                    "echo": {"type": "string", "description": "One line, e.g. `Went with B - Card grid: it keeps avatar and role in view.`"},
                    "decision": which,
                }, "required": ["echo"]}),
            ),
            ToolDefinition::with_schema(
                "decision_withdraw",
                "Takes back a decision of yours that is no longer worth the user's answer (obsolete after a redirect, or about to be redone). The user is not told.",
                json!({"type": "object", "properties": {"decision": which}, "required": []}),
            ),
        ]
    }

    fn call(&mut self, turn: &mut Turn<'a>, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        reply.send(answer(turn, name, arguments, caller))
    }
}

fn answer(turn: &mut Turn, name: &str, arguments: &Map<String, Value>, caller: Uuid) -> ToolResult {
    if !is_agent(turn, caller) {
        return ToolResult::error("Only agents on the board open decisions.");
    }
    match name {
        "decision_guide" => ToolResult::text(guide()),
        "decision_open" => open(turn, arguments, caller),
        "decision_echo" => {
            let Some(echo) = arguments.get("echo").and_then(Value::as_str).map(str::trim).filter(|echo| !echo.is_empty()) else {
                return ToolResult::error("Give `echo`: one line saying what you understood.");
            };
            match mine(turn, arguments.get("decision"), caller, true) {
                Err(refusal) => ToolResult::error(refusal),
                Ok(decision) => {
                    turn.board.close_decision(decision.id, Some(echo.to_string()));
                    ToolResult::text(format!("Shown to the user under “{}”, which is now closed. Carry on.", decision.framing))
                }
            }
        }
        "decision_withdraw" => match mine(turn, arguments.get("decision"), caller, false) {
            Err(refusal) => ToolResult::error(refusal),
            Ok(decision) => {
                turn.board.withdraw_decisions(|other| other.id == decision.id);
                ToolResult::text(format!("Withdrew “{}”.", decision.framing))
            }
        },
        _ => ToolResult::error(format!("Unknown tool “{name}”.")),
    }
}

fn open(turn: &mut Turn, arguments: &Map<String, Value>, caller: Uuid) -> ToolResult {
    // The next decision only comes after the echo of the last answer.
    if let Some(waiting) = turn.decisions.iter().find(|decision| decision.agent == caller && decision.state == State::AwaitingEcho) {
        return ToolResult::error(format!("The user answered “{}” and waits for what you understood: call decision_echo first.", waiting.framing));
    }
    let draft = match DecisionDraft::parse(arguments) {
        Ok(draft) => draft,
        Err(reason) => return ToolResult::error(format!("{reason} (decision_guide has the rules.)")),
    };
    let mut cards = Vec::new();
    for (index, card) in draft.cards.iter().enumerate() {
        if card.kind == "diagram" {
            cards.push(Card { claim: card.claim.clone(), evidence: Evidence::Diagram { svg: card.target.clone() }, reference: card.reference.clone(), pins: card.pins.clone() });
            continue;
        }
        let connected = turn.bus.peers_of_kind(caller, &ElementKind::image(), &turn.board);
        let find = |name: &str| {
            find_element(name, &connected).map(|found| found.id).ok_or_else(|| {
                let names = if connected.is_empty() { "none".to_string() } else { connected.iter().map(|element| element.name.as_str()).collect::<Vec<_>>().join(", ") };
                format!("Card {}: no {} named “{name}” is connected to you. Connected: {names}. Put a screenshot on the board with image_create first.", index + 1, card.kind)
            })
        };
        let before = match card.before.as_deref().map(find).transpose() {
            Ok(before) => before,
            Err(refusal) => return ToolResult::error(refusal),
        };
        match find(&card.target) {
            Err(refusal) => return ToolResult::error(refusal),
            Ok(after) => cards.push(Card { claim: card.claim.clone(), evidence: Evidence::Image { before, after }, reference: card.reference.clone(), pins: card.pins.clone() }),
        }
    }
    let Some(agent) = turn.record(caller).cloned() else { return ToolResult::error("Only agents on the board open decisions.") };
    let decision = turn.board.open_decision(Decision {
        id: Uuid::new(),
        agent: caller,
        worktree: agent.worktree,
        organization: agent.organization,
        family: draft.family,
        framing: draft.framing,
        cards,
        ask: draft.ask,
        verified: draft.verified,
        blocking: draft.blocking,
        closing: draft.closing,
        state: State::Open,
        since: now(),
        answer: None,
        echo: None,
    });
    let id = decision.id;
    if decision.blocking && !draft.blocking {
        return ToolResult::text(format!(
            "Opened decision {id}. It blocks: this worktree already has {} provisional decisions unanswered. Stop here and wait; the answer arrives as a message.",
            Decision::PROVISIONAL_LIMIT
        ));
    }
    ToolResult::text(if decision.blocking {
        format!("Opened decision {id}. It blocks: stop here and wait; the answer arrives as a message.")
    } else {
        format!("Opened decision {id}. Carry on with your own choice (provisional); the answer arrives as a message.")
    })
}

/// The caller's decision `given` names. Without a name: the one whose answer waits for its echo
/// when `echoing`, else its only one the user hasn't answered.
fn mine(turn: &Turn, given: Option<&Value>, caller: Uuid, echoing: bool) -> Result<Decision, String> {
    let mut mine: Vec<&Decision> = turn.decisions.iter().filter(|decision| decision.agent == caller).collect();
    if mine.is_empty() {
        return Err("You have no open decision.".into());
    }
    let list = |decisions: &[&Decision]| decisions.iter().map(|decision| format!("{} (“{}”)", decision.id, decision.framing)).collect::<Vec<_>>().join(", ");
    if let Some(text) = given.and_then(Value::as_str).map(|text| text.trim_matches(crate::orchestrator::is_inline_space)).filter(|text| !text.is_empty()) {
        return match mine.iter().find(|decision| Some(decision.id) == Uuid::parse(text)) {
            Some(found) => Ok((*found).clone()),
            None => Err(format!("You have no decision {text}. Yours: {}.", list(&mine))),
        };
    }
    if echoing {
        let waiting: Vec<&&Decision> = mine.iter().filter(|decision| decision.state == State::AwaitingEcho).collect();
        if let [only] = waiting.as_slice() {
            return Ok((**only).clone());
        }
    } else {
        mine.retain(|decision| decision.answer.is_none());
        if mine.is_empty() {
            return Err("You have no unanswered decision to withdraw.".into());
        }
    }
    match mine.as_slice() {
        [only] => Ok((*only).clone()),
        _ => Err(format!("You have several decisions open; say which with `decision`: {}.", list(&mine))),
    }
}
