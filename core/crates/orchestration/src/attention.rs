use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use connections::{Request, Uuid};
use runtime::AgentHook;

use crate::board_protocol::{now, only, BoardEvent, Unlabelled};
use crate::cards::AgentRecord;
use crate::orchestrator::Turn;
use crate::transcript_context::{objects, TranscriptContext};

/// An agent waiting on the developer, across every organization and worktree: one per card,
/// kept until the developer dismisses it or the agent is working again.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AttentionRequest {
    /// The card's id.
    pub id: Uuid,
    pub reason: Reason,
    /// When it started waiting (seconds since 2001); a newer signal while it waits doesn't move it.
    pub since: f64,
    /// What the developer is asked to decide on: the agent's last words, the question it asked,
    /// or the command it wants to run. None when its conversation can't be read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    /// Questions the agent asked (AskUserQuestion) that wait on the board's answers; none when
    /// it waits in its terminal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub questions: Option<Vec<AgentQuestion>>,
    /// The orchestrators coordinating the agent, when it waits on what only the developer can
    /// give (a permission prompt); none for an agent no orchestrator coordinates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub orchestrators: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    /// It ended its turn.
    TurnEnded {},
    /// It is waiting without saying on what.
    Waiting {},
    /// What it said.
    Said(Unlabelled<String>),
}

impl AttentionRequest {
    /// Whether the agent is blocked on the user (a prompt, a permission, its questions), not
    /// only done with its turn.
    pub fn needs_user(&self) -> bool {
        self.reason != Reason::TurnEnded {} || self.questions.as_ref().is_some_and(|questions| !questions.is_empty())
    }
}

/// One question an agent asks with AskUserQuestion: options to pick one of, or several of, and
/// always room for an answer of the developer's own.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentQuestion {
    pub question: String,
    /// A short tag for it, e.g. `Layout`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub options: Vec<QuestionOption>,
    pub multi_select: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    /// What picking it means.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

impl AgentQuestion {
    /// The questions of an AskUserQuestion call's input.
    pub fn parse(input: &Map<String, Value>) -> Vec<AgentQuestion> {
        let text = |object: &Map<String, Value>, key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
        objects(input.get("questions"))
            .into_iter()
            .filter_map(|question| {
                let asked = text(question, "question").filter(|asked| !asked.is_empty())?;
                let options = objects(question.get("options")).into_iter().filter_map(|option| Some(QuestionOption { label: text(option, "label")?, description: text(option, "description") })).collect();
                Some(AgentQuestion { question: asked, header: text(question, "header"), options, multi_select: question.get("multiSelect").and_then(Value::as_bool).unwrap_or(false) })
            })
            .collect()
    }
}

/// An agent's questions hook, waiting: what it asked, and how to let it go on.
pub(crate) struct PendingQuestions {
    /// The AskUserQuestion call's input, given back with the answers added.
    input: Map<String, Value>,
    /// The hook's connection, answered with its output.
    resume: Request,
}

impl PendingQuestions {
    /// Leaves the questions to the agent's terminal.
    fn no_answer(self) {
        self.resume.reply(Some(b"{}".to_vec()));
    }
}

/// Notifications that mean the agent waits on the developer. Others don't: idle at the
/// prompt repeats the end of the turn a minute later, and some only inform (auth_success).
const WAITING_NOTIFICATIONS: [&str; 2] = ["permission_prompt", "elicitation_dialog"];

impl Turn<'_> {
    /// An agent's program sent desktop notifications: its hooks (see `AgentHook`) raise or clear
    /// its request. Anything else is ignored: the hooks carry every notification Claude Code
    /// sends, with its type, so its own OSC 9 (launched from iTerm2, say) would only repeat one
    /// unfiltered. Runners' are ignored too.
    pub(crate) fn session_notified(&mut self, id: Uuid, notifications: &[String]) {
        for hook in notifications.iter().filter_map(|notification| AgentHook::from_notification(notification)) {
            self.hooked(id, hook);
        }
    }

    pub(crate) fn hooked(&mut self, id: Uuid, hook: AgentHook) {
        let Some(record) = self.record(id).filter(|record| record.runner.is_none()).cloned() else { return };
        // `/clear` moves the agent to a new conversation: relaunching resumes that one.
        if let Some(conversation) = hook.session_id.as_deref().and_then(Uuid::parse).filter(|conversation| *conversation != record.conversation.unwrap_or(record.id)) {
            self.update(id, None, |card| card.conversation = (conversation != card.id).then_some(conversation));
        }
        let last_request = |hook: &AgentHook| hook.transcript_path.as_deref().and_then(|path| TranscriptContext::last_request(Path::new(path)));
        match hook.hook_event_name.as_str() {
            "Stop" => {
                let context = hook.last_assistant_message.as_deref().and_then(TranscriptContext::trimmed).or_else(|| last_request(&hook));
                self.request_attention(id, Reason::TurnEnded {}, context, None);
            }
            "Notification" if hook.notification_type.as_deref().is_none_or(|kind| WAITING_NOTIFICATIONS.contains(&kind)) => {
                let reason = hook.message.clone().map_or(Reason::Waiting {}, |message| Reason::Said(only(message)));
                self.request_attention(id, reason, last_request(&hook), None);
            }
            "UserPromptSubmit" => self.dismiss_attention(id),
            _ => {}
        }
    }

    /// Queues the agent, or updates why it waits while keeping its place.
    pub(crate) fn request_attention(&mut self, id: Uuid, reason: Reason, context: Option<String>, questions: Option<Vec<AgentQuestion>>) {
        let Some(record) = self.record(id).cloned() else { return };
        let orchestrators = self.orchestrators(&record);
        if !orchestrators.is_empty() && reason == (Reason::TurnEnded {}) && questions.is_none() {
            // A finished turn goes to its orchestrators, which decide whether it needs the developer.
            let report = context.map_or("I finished my turn.".to_string(), |context| format!("I finished my turn. My last words:\n\n{context}"));
            for orchestrator in &orchestrators {
                let _ = self.deliver(&report, id, orchestrator.id);
            }
            return self.dismiss_attention(id);
        }
        let via = (!orchestrators.is_empty()).then(|| orchestrators.iter().map(|orchestrator| orchestrator.name.clone()).collect::<Vec<_>>());
        let waits_on_board = self.pending_questions.contains_key(&id);
        match self.attention.iter_mut().find(|request| request.id == id) {
            Some(request) => {
                let context = context.or_else(|| request.context.clone());
                let questions = if waits_on_board { questions.or_else(|| request.questions.clone()) } else { None };
                if request.reason == reason && request.context == context && request.questions == questions && request.orchestrators == via {
                    return;
                }
                (request.reason, request.context, request.questions, request.orchestrators) = (reason, context, questions, via);
            }
            None => self.attention.push(AttentionRequest { id, reason, since: now(), context, questions, orchestrators: via }),
        }
        self.board.release_held_messages();
        self.board.broadcast(&BoardEvent::Attention(only(self.attention.clone())), None);
    }

    /// The orchestrators connected to an agent that isn't one itself: an orchestrator answers
    /// to the developer, so two connected ones never pass turns back and forth.
    pub(crate) fn orchestrators(&self, record: &AgentRecord) -> Vec<AgentRecord> {
        if record.is_orchestrator() {
            return Vec::new();
        }
        self.bus.graph().peers(record.id).into_iter().filter_map(|peer| self.record(peer)).filter(|peer| peer.is_orchestrator()).cloned().collect()
    }

    // MARK: Questions

    /// The agent's questions hook posted what it is about to ask: queue it with the questions and
    /// wait for the developer. The hook's output: the call allowed with the answers in its input,
    /// or nothing (`{}`), which leaves the questions to the agent's terminal.
    pub(crate) fn ask(&mut self, mut request: Request) {
        let caller = request.caller;
        let hook: Value = serde_json::from_slice(&std::mem::take(&mut request.body)).unwrap_or_default();
        let input = hook.get("tool_input").and_then(Value::as_object).cloned().unwrap_or_default();
        let questions = AgentQuestion::parse(&input);
        if self.record(caller).is_none() || questions.is_empty() {
            return request.reply(Some(b"{}".to_vec()));
        }
        // A hook still waiting is from a call that's over.
        if let Some(over) = self.pending_questions.remove(&caller) {
            over.no_answer();
        }
        let context = hook.get("transcript_path").and_then(Value::as_str).and_then(|path| TranscriptContext::last_text(Path::new(path)));
        self.pending_questions.insert(caller, PendingQuestions { input, resume: request });
        self.board.release_held_messages();
        self.request_attention(caller, Reason::Waiting {}, context, Some(questions));
    }

    /// The developer's answers, keyed by question text; none sends the agent to ask in its terminal.
    pub(crate) fn answer_questions(&mut self, id: Uuid, answers: Option<std::collections::HashMap<String, String>>) {
        let Some(mut pending) = self.pending_questions.remove(&id) else { return };
        self.board.release_held_messages();
        let Some(answers) = answers else {
            pending.no_answer();
            // It now waits in its terminal: the card shows it.
            if let Some(request) = self.attention.iter_mut().find(|request| request.id == id) {
                request.questions = None;
                self.board.release_held_messages();
                self.board.broadcast(&BoardEvent::Attention(only(self.attention.clone())), None);
            }
            return;
        };
        pending.input.insert("answers".into(), json!(answers));
        let output = json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": pending.input}});
        pending.resume.reply(Some(serde_json::to_vec(&output).unwrap_or_else(|_| b"{}".to_vec())));
        self.dismiss_attention(id);
    }

    pub(crate) fn dismiss_attention(&mut self, id: Uuid) {
        // Questions dismissed unanswered go back to the agent's terminal.
        if let Some(pending) = self.pending_questions.remove(&id) {
            pending.no_answer();
            self.board.release_held_messages();
        }
        if !self.attention.iter().any(|request| request.id == id) {
            return;
        }
        self.attention.retain(|request| request.id != id);
        self.board.release_held_messages();
        self.board.broadcast(&BoardEvent::Attention(only(self.attention.clone())), None);
    }
}
