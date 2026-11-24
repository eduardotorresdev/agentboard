//! Something an agent shows the developer and asks about: a few cards of evidence that end in
//! one ask. A port of `Decision.swift`; the wire form is the Swift types' `Codable` one, and
//! `DecisionDraft` refuses what `decision_open` is given for the same reasons, checked on the
//! shared cases in `core/fixtures/decisions/drafts.json`.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use connections::Uuid;

use crate::board_protocol::{only, BoardEvent, Unlabelled};
use crate::orchestrator::BoardView;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Waiting for the developer's answer.
    Open,
    /// Answered with something the agent must say back (a redirect, a choice given back).
    AwaitingEcho,
    /// Over: boards see it once, with its echo, and it is gone.
    Closed,
}

/// What a card shows, pointing at elements on the board.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Evidence {
    Image {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before: Option<Uuid>,
        after: Uuid,
    },
    Browser { id: Uuid },
    Video { id: Uuid },
    /// An SVG the agent drew, checked by `runtime::svg_diagram`.
    Diagram {
        svg: String,
        /// The diagram it replaces, shown behind the same divider as an image's.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before: Option<String>,
    },
}

/// A doubt at an exact place of the evidence, `x` and `y` from 0 to 1 from its top left.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Pin {
    pub x: f64,
    pub y: f64,
    pub question: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Card {
    pub claim: String,
    pub evidence: Evidence,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
    pub pins: Vec<Pin>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Variant {
    pub letter: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl Variant {
    pub fn title(&self) -> String {
        format!("{} - {}", self.letter, self.name)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Ask {
    Validation { question: String },
    Choice { question: String, variants: Vec<Variant> },
}

impl Ask {
    pub fn question(&self) -> &str {
        match self {
            Ask::Validation { question } | Ask::Choice { question, .. } => question,
        }
    }

    pub fn variants(&self) -> &[Variant] {
        match self {
            Ask::Choice { variants, .. } => variants,
            Ask::Validation { .. } => &[],
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Answer {
    Ok {},
    Option(Unlabelled<String>),
    UseRecommended {},
    Redirect(Unlabelled<String>),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Decision {
    pub id: Uuid,
    /// The agent that asked.
    pub agent: Uuid,
    pub worktree: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization: Option<Uuid>,
    /// `surface`, `flow` or `foundation`.
    pub family: String,
    /// One line: what the developer is about to evaluate.
    pub framing: String,
    pub cards: Vec<Card>,
    pub ask: Ask,
    pub verified: Vec<String>,
    /// The agent waits for the answer instead of carrying on with its own choice.
    pub blocking: bool,
    /// It closes the worktree's work, showing how the feature ended up.
    #[serde(rename = "final")]
    pub closing: bool,
    pub state: State,
    /// Seconds since 2001.
    pub since: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answer: Option<Answer>,
    /// What the agent understood from the answer, in one line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub echo: Option<String>,
}

impl Decision {
    /// Provisional decisions one worktree stacks before the next one blocks.
    pub const PROVISIONAL_LIMIT: usize = 3;

    /// The answer in words, as the agent and the balloon say it.
    pub fn title(&self, answer: &Answer) -> String {
        match answer {
            Answer::Ok {} => "OK".into(),
            Answer::Option(letter) => {
                self.ask.variants().iter().find(|variant| variant.letter == letter.value).map_or_else(|| letter.value.clone(), Variant::title)
            }
            Answer::UseRecommended {} => "Use Recommended".into(),
            Answer::Redirect(_) => "Redirect".into(),
        }
    }
}

/// What `decision_open` was given, checked. Evidence still names its elements as the agent
/// wrote them; the tool finds them on the board.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct DecisionDraft {
    pub family: String,
    pub framing: String,
    pub cards: Vec<DraftCard>,
    pub ask: Ask,
    pub verified: Vec<String>,
    pub blocking: bool,
    pub closing: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct DraftCard {
    pub claim: String,
    /// One of `KINDS`.
    pub kind: String,
    pub before: Option<String>,
    /// The image to evaluate, or a diagram's SVG.
    pub target: String,
    pub reference: Option<String>,
    pub pins: Vec<Pin>,
}

pub(crate) const MAX_CARDS: usize = 6;
pub(crate) const MAX_LABEL_WORDS: usize = 3;
pub(crate) const VARIANTS: (usize, usize) = (2, 4);
pub(crate) const FAMILIES: [&str; 3] = ["surface", "flow", "foundation"];
// shortcut: only images and diagrams have a renderer in the balloon; add browser and video here when they get one.
pub(crate) const KINDS: [&str; 2] = ["image", "diagram"];

fn text(value: Option<&Value>) -> Option<String> {
    let text = value.and_then(Value::as_str)?.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// An array of objects, or nothing (as Swift's `as? [[String: Any]]`).
fn objects(value: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

impl DecisionDraft {
    /// The draft in a `decision_open` call's arguments, or why it is refused.
    pub fn parse(arguments: &Map<String, Value>) -> Result<DecisionDraft, String> {
        let family = text(arguments.get("family")).filter(|family| FAMILIES.contains(&family.as_str())).ok_or(
            "Give `family`: surface (what a screen shows), flow (how the experience is walked through) or foundation (what the rest is built on).",
        )?;
        let framing = text(arguments.get("framing"))
            .filter(|framing| !framing.contains('\n'))
            .ok_or("Give `framing`: one line saying what the user is about to evaluate.")?;
        text(arguments.get("intent")).ok_or("Give `intent`: one line saying what the user should notice. It is your own check and is not shown.")?;
        let cards = objects(arguments.get("cards"))
            .filter(|cards| !cards.is_empty())
            .ok_or("Give `cards`: at least one, each with a claim and its evidence. A decision shows before it asks.")?;
        if cards.len() > MAX_CARDS {
            return Err(format!(
                "A decision takes at most {MAX_CARDS} cards; you gave {}. One card, one idea: cut, or split it into two decisions.",
                cards.len()
            ));
        }
        let cards = cards.iter().enumerate().map(|(index, card)| Self::card(index + 1, card)).collect::<Result<Vec<_>, _>>()?;
        if arguments.get("ask").is_some_and(Value::is_array) {
            return Err("One decision, one ask: `ask` is a single object. A second question is a second decision.".into());
        }
        let ask = arguments.get("ask").and_then(Value::as_object);
        let question = text(ask.and_then(|ask| ask.get("question")))
            .ok_or("Give `ask`: an object with the `question`, and `variants` when the user picks between alternatives.")?;
        let ask = match objects(ask.and_then(|ask| ask.get("variants"))) {
            Some(variants) => {
                if !(VARIANTS.0..=VARIANTS.1).contains(&variants.len()) {
                    return Err(format!(
                        "A choice takes {} to {} variants (three for something new); you gave {}. With one, ask for validation: leave `variants` out.",
                        VARIANTS.0,
                        VARIANTS.1,
                        variants.len()
                    ));
                }
                let variants = variants
                    .iter()
                    .enumerate()
                    .map(|(index, variant)| {
                        let name = text(variant.get("name")).filter(|name| name.split(' ').filter(|word| !word.is_empty()).count() <= MAX_LABEL_WORDS);
                        let name = name.ok_or_else(|| {
                            format!("Variant {} needs a `name` of at most {MAX_LABEL_WORDS} words, e.g. “Dense list”; the rest goes in `detail`.", index + 1)
                        })?;
                        Ok(Variant { letter: ((b'A' + index as u8) as char).to_string(), name, detail: text(variant.get("detail")) })
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                Ask::Choice { question, variants }
            }
            None => Ask::Validation { question },
        };
        let verified: Vec<String> =
            arguments.get("verified").and_then(Value::as_array).map(|lines| lines.iter().filter_map(|line| text(Some(line))).collect()).unwrap_or_default();
        if verified.is_empty() {
            return Err("Give `verified`: what you checked before asking, one line each. Nothing reaches the user unverified; what can't be verified is its own decision saying what stops you.".into());
        }
        Ok(DecisionDraft {
            family,
            framing,
            cards,
            ask,
            verified,
            blocking: arguments.get("blocking").and_then(Value::as_bool).unwrap_or(false),
            closing: arguments.get("final").and_then(Value::as_bool).unwrap_or(false),
        })
    }

    fn card(number: usize, card: &Map<String, Value>) -> Result<DraftCard, String> {
        if card.contains_key("ask") || card.contains_key("question") {
            return Err(format!(
                "Card {number} asks something. A decision has one ask, given once in `ask`; a doubt about a place on the evidence is a pin."
            ));
        }
        let claim = text(card.get("claim"))
            .ok_or_else(|| format!("Card {number} has no `claim`: say what the evidence shows, e.g. “The screen ended up like this”."))?;
        let evidence = card.get("evidence").and_then(Value::as_object);
        let kind = text(evidence.and_then(|evidence| evidence.get("type"))).filter(|kind| KINDS.contains(&kind.as_str()));
        let (Some(evidence), Some(kind)) = (evidence, kind) else {
            return Err(format!("Card {number} has no `evidence`: an object with `type` ({}) and the board element it shows.", KINDS.join(", ")));
        };
        let (target, before) = if kind == "diagram" {
            let svg = text(evidence.get("svg")).ok_or_else(|| format!("Card {number}: give the diagram's SVG in `svg`."))?;
            runtime::svg_diagram::check(&svg).map_err(|reason| format!("Card {number}: the diagram can't be drawn. {reason}"))?;
            let before = text(evidence.get("before"));
            if let Some(before) = &before {
                runtime::svg_diagram::check(before).map_err(|reason| format!("Card {number}: the `before` diagram can't be drawn. {reason}"))?;
            }
            (svg, before)
        } else {
            let after = text(evidence.get("after"))
                .ok_or_else(|| format!("Card {number}: give the image to evaluate in `after` (and the one it replaces in `before`)."))?;
            (after, text(evidence.get("before")))
        };
        let reference = text(card.get("reference"));
        if before.is_none() && reference.is_none() {
            return Err(format!("Card {number} is evaluated in a vacuum: give `before`, or a `reference` line with the justification or the alternative. Precedent is not a justification."));
        }
        let pins = objects(card.get("pins"))
            .unwrap_or_default()
            .iter()
            .map(|pin| {
                let unit = |key: &str| pin.get(key).and_then(Value::as_f64).filter(|value| (0.0..=1.0).contains(value));
                match (unit("x"), unit("y"), text(pin.get("question"))) {
                    (Some(x), Some(y), Some(question)) => Ok(Pin { x, y, question }),
                    _ => Err(format!("Card {number}: a pin takes `x` and `y` from 0 to 1 (from the evidence's top left) and its `question`.")),
                }
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(DraftCard { claim, kind, before, target, reference, pins })
    }
}

impl BoardView<'_> {
    /// Shows a new decision to the boards. One past the worktree's provisional limit blocks.
    pub(crate) fn open_decision(&mut self, mut decision: Decision) -> Decision {
        let stacked = self
            .decisions
            .iter()
            .filter(|other| other.state == State::Open && !other.blocking && other.worktree == decision.worktree && other.organization == decision.organization)
            .count();
        if stacked >= Decision::PROVISIONAL_LIMIT {
            decision.blocking = true;
        }
        self.decisions.push(decision.clone());
        self.broadcast_decisions();
        decision
    }

    fn broadcast_decisions(&self) {
        self.broadcast(&BoardEvent::Decisions(only(self.decisions.clone())), None);
    }

    /// The developer's answer, from a board: the agent hears it as a prompt. The decision stays
    /// open, holding the answer, until that prompt reaches the agent's terminal.
    pub(crate) fn answer_decision(&mut self, id: Uuid, answer: Answer) {
        let Some(index) = self.decisions.iter().position(|decision| decision.id == id && decision.state == State::Open && decision.answer.is_none()) else { return };
        if let Answer::Option(letter) = &answer {
            if !self.decisions[index].ask.variants().iter().any(|variant| variant.letter == letter.value) {
                return;
            }
        }
        self.decisions[index].answer = Some(answer);
        self.broadcast_decisions();
        let agent = self.decisions[index].agent;
        self.deliver_answers(agent);
    }

    /// Queues the answers `agent` hasn't heard yet. While its program isn't running nothing is
    /// queued: this is called again when it is back.
    pub(crate) fn deliver_answers(&mut self, agent: Uuid) {
        let answered: Vec<(Uuid, String)> = self
            .decisions
            .iter()
            .filter(|decision| decision.agent == agent && decision.state == State::Open)
            .filter_map(|decision| Some((decision.id, Self::answer_prompt(decision, decision.answer.as_ref()?))))
            .collect();
        for (id, text) in answered {
            self.tell(agent, text, Some(id));
        }
    }

    fn answer_prompt(decision: &Decision, answer: &Answer) -> String {
        let lead = format!("The user answered your decision “{}”", decision.framing);
        match answer {
            Answer::Ok {} => format!("{lead}: OK. Carry on."),
            Answer::Option(_) => format!("{lead}: {}. Make that one the real one and carry on.", decision.title(answer)),
            Answer::UseRecommended {} => {
                format!("{lead}: Use Recommended. The choice is yours: choose now, then call decision_echo with one line saying which you chose and why.")
            }
            Answer::Redirect(text) => format!(
                "{lead} with a redirect:\n\n{}\n\nIt applies to the work at hand only. Call decision_echo with one line saying what you understood, then act on it \
                 without waiting for confirmation. Then review your other open decisions: decision_withdraw the ones this made \
                 obsolete and redo the affected ones.",
                text.value
            ),
        }
    }

    /// The answer reached the agent's terminal: a redirect or a choice given back waits for the
    /// agent's echo; anything else closes the decision.
    pub(crate) fn answer_delivered(&mut self, id: Uuid) {
        let Some(index) = self.decisions.iter().position(|decision| decision.id == id && decision.state == State::Open) else { return };
        match self.decisions[index].answer {
            Some(Answer::UseRecommended {} | Answer::Redirect(_)) => {
                self.decisions[index].state = State::AwaitingEcho;
                self.broadcast_decisions();
            }
            _ => self.close_decision(id, None),
        }
    }

    /// Boards see the decision closed once (with the agent's echo, if any), then it is gone.
    pub(crate) fn close_decision(&mut self, id: Uuid, echo: Option<String>) {
        let Some(index) = self.decisions.iter().position(|decision| decision.id == id) else { return };
        self.decisions[index].state = State::Closed;
        self.decisions[index].echo = echo;
        self.broadcast_decisions();
        self.decisions.remove(index);
    }

    /// Takes decisions away without a word to the developer: withdrawn, or their agent is gone.
    pub(crate) fn withdraw_decisions(&mut self, matches: impl Fn(&Decision) -> bool) {
        if !self.decisions.iter().any(&matches) {
            return;
        }
        self.decisions.retain(|decision| !matches(decision));
        self.broadcast_decisions();
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use super::DecisionDraft;

    /// The drafts both cores check (also run by `DecisionTests.swift`): taken as the fixture
    /// says, or refused for the same reason.
    #[test]
    fn the_shared_drafts_are_taken_or_refused_alike() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/decisions/drafts.json");
        let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert!(cases.len() > 20);
        let mut wrong = Vec::new();
        for case in cases {
            let mut arguments = fixture["base"].as_object().unwrap().clone();
            for (key, value) in case["set"].as_object().unwrap() {
                if value.is_null() {
                    arguments.remove(key);
                } else {
                    arguments.insert(key.clone(), value.clone());
                }
            }
            let got = match DecisionDraft::parse(&arguments) {
                Err(reason) => json!({"refused": reason}),
                Ok(draft) => json!({"refused": null, "taken": {
                    "family": draft.family, "framing": draft.framing, "question": draft.ask.question(),
                    "variants": draft.ask.variants().iter().map(super::Variant::title).collect::<Vec<_>>(),
                    "verified": draft.verified, "blocking": draft.blocking, "final": draft.closing,
                    "cards": draft.cards.iter().map(|card| json!({
                        "claim": card.claim, "kind": card.kind, "before": card.before, "target": card.target,
                        "reference": card.reference, "pins": card.pins.iter().map(|pin| json!([pin.x, pin.y, pin.question])).collect::<Vec<_>>(),
                    })).collect::<Vec<_>>(),
                }}),
            };
            let expected = if case["refused"].is_null() { json!({"refused": null, "taken": case["taken"]}) } else { json!({"refused": case["refused"]}) };
            if !same(&got, &expected) {
                wrong.push(format!("{}: expected {expected}, got {got}", case["name"]));
            }
        }
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    }

    /// Equal, numbers by value (`1` and `1.0` alike, as the Swift side compares them).
    fn same(a: &Value, b: &Value) -> bool {
        match (a, b) {
            (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
            (Value::Array(a), Value::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b)),
            (Value::Object(a), Value::Object(b)) => a.len() == b.len() && a.iter().all(|(key, value)| b.get(key).is_some_and(|other| same(value, other))),
            _ => a == b,
        }
    }
}
