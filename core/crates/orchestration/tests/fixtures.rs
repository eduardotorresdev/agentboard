//! The golden files the Swift tests write (`swift test --filter BoardFixtures`): what crosses
//! the wire, and the database both cores keep the cards in, must be the same from this core.

use std::path::PathBuf;

use connections::{Connection, Rect, Side, Size, Uuid};
use orchestration::*;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

fn folder() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/orchestration")
}

/// Whether two JSON values say the same: Swift writes a whole `Double` without its fraction
/// (`640`), which reads back as the same number.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        (Value::Array(a), Value::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b)),
        (Value::Object(a), Value::Object(b)) => a.len() == b.len() && a.iter().all(|(key, value)| b.get(key).is_some_and(|other| same(value, other))),
        _ => a == b,
    }
}

/// Decodes the fixture and encodes it again: nothing lost, nothing added.
fn round_trip<T: DeserializeOwned + Serialize>(name: &str) -> T {
    let path = folder().join(format!("{name}.json"));
    let golden: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))).unwrap();
    let decoded: T = serde_json::from_value(golden.clone()).unwrap_or_else(|error| panic!("{name}: {error}"));
    let encoded = serde_json::to_value(&decoded).unwrap();
    assert!(same(&encoded, &golden), "{name}:\n{encoded:#}\nis not\n{golden:#}");
    decoded
}

fn id(digit: u8) -> Uuid {
    Uuid::parse(&format!("0000000{digit}-ABCD-4EF0-8A1B-00000000000{digit}")).unwrap()
}

const DATE: f64 = 784_111_222.5;

fn agent() -> AgentRecord {
    AgentRecord { organization: Some(id(8)), orchestrates: Some(true), conversation: Some(id(9)), ..AgentRecord::new(id(1), "/work/tree", "claude", "Ada", Rect::new(12.5, -40.0, 640.0, 420.0)) }
}

fn runner() -> AgentRecord {
    let spec = RunnerSpec { command: "npm run dev".into(), directory: "/work/tree/app".into(), owner: Some(id(1)) };
    AgentRecord { runner: Some(spec), ..AgentRecord::new(id(2), "/work/tree", "runner", "web", Rect::new(716.5, -40.0, 600.0, 340.0)) }
}

fn plain() -> AgentRecord {
    AgentRecord::new(id(3), "/work/tree", "codex", "Bob", Rect::new(0.0, 500.0, 640.0, 420.0))
}

fn post_it() -> PostItRecord {
    PostItRecord {
        text: "# Plan\n\n- “first”\n- second ✅".into(),
        editor: Some(id(1)),
        editor_name: "Ada".into(),
        edited: Some(DATE),
        organization: Some(id(8)),
        ..PostItRecord::new(id(4), "/work/tree", "Plan", Rect::new(10.0, 20.0, 340.0, 320.0))
    }
}

fn empty_post_it() -> PostItRecord {
    PostItRecord::new(id(5), "/work/tree", "Post-it", Rect::new(400.0, 20.0, 340.0, 320.0))
}

fn image() -> ImageRecord {
    ImageRecord {
        id: id(6),
        worktree: "/work/tree".into(),
        name: "Login screen".into(),
        frame: Rect::new(1.0, 2.0, 480.0, 302.0),
        file: "0000000A-ABCD-4EF0-8A1B-00000000000A.png".into(),
        pixel_size: Size::new(1280.0, 720.0),
        organization: Some(id(8)),
        duration: None,
    }
}

fn video() -> ImageRecord {
    ImageRecord {
        id: id(7),
        worktree: "/work/tree".into(),
        name: "Signup flow".into(),
        frame: Rect::new(1.0, 400.0, 480.0, 302.0),
        file: "0000000B-ABCD-4EF0-8A1B-00000000000B.mp4".into(),
        pixel_size: Size::new(1920.0, 1080.0),
        organization: None,
        duration: Some(12.25),
    }
}

fn lines() -> Vec<Connection> {
    vec![Connection { id: id(8), a: id(1), b: id(2), a_side: Some(Side::Right), b_side: Some(Side::Left) }, Connection { id: id(9), a: id(1), b: id(4), a_side: None, b_side: None }]
}

#[test]
fn requests_encode_as_swift_does() {
    let names = [
        "addCard", "updateCard", "removeCard", "connect", "disconnect", "elements", "open", "restart", "restart_as_it_is", "startRunner", "stopRunner", "toolResult", "toolResult_error",
        "addPostIt", "updatePostIt", "removePostIt", "writePostIt", "addImage", "updateImage", "removeImage", "dismissAttention", "answerQuestions", "answerQuestions_in_the_terminal", "deliver",
        "prompt", "deliverHeld", "deliver_to_one", "answerDecision_ok", "answerDecision_option", "answerDecision_useRecommended", "answerDecision_redirect",
        "createProject", "createProject_clone", "createWorktree",
    ];
    let requests: Vec<BoardRequest> = names.iter().map(|name| round_trip(&format!("request_{name}"))).collect();
    let created = names.iter().position(|name| *name == "createProject").unwrap();
    assert_eq!(requests[created], BoardRequest::CreateProject { request: id(8), name: Some("shop".into()), clone: None });
    assert_eq!(requests[created + 1], BoardRequest::CreateProject { request: id(8), name: None, clone: Some("git@github.com:owner/shop.git".into()) });
    assert_eq!(requests[created + 2], BoardRequest::CreateWorktree { request: id(9), project: "/Users/me/agentboard/projects/shop".into(), branch: "fix/login".into() });
    assert_eq!(requests[0], BoardRequest::AddCard(only(agent())));
    assert_eq!(requests[1], BoardRequest::UpdateCard(only(runner())));
    assert_eq!(requests[3], BoardRequest::Connect(only(lines().remove(0))));
    assert_eq!(requests[6], BoardRequest::Open { id: id(1), cols: 120, rows: 40, start: true });
    assert_eq!(requests[7], BoardRequest::Restart { id: id(2), command: Some("npm run build".into()) });
    assert_eq!(requests[8], BoardRequest::Restart { id: id(2), command: None });
    let BoardRequest::ToolResult { call, result } = requests[11].clone() else { panic!("not a tool result") };
    let result = result.result();
    assert_eq!((call, result.is_error), (id(9), false));
    assert_eq!(result.content, [connections::ToolContent::Text("Opened “page”".into()), connections::ToolContent::Image { data: vec![0, 1, 2, 250, 255], mime_type: "image/png".into() }]);
    assert_eq!(requests[13], BoardRequest::AddPostIt(only(post_it())));
    assert_eq!(requests[17], BoardRequest::AddImage(only(image())));
    assert_eq!(requests[18], BoardRequest::UpdateImage(only(video())));
    assert_eq!(requests[21], BoardRequest::AnswerQuestions { id: id(1), answers: Some([("Which layout?".to_string(), "Grid".to_string())].into()) });
    assert_eq!(requests[22], BoardRequest::AnswerQuestions { id: id(1), answers: None });
    assert_eq!(requests[25], BoardRequest::DeliverHeld(only(id(1))));
    assert_eq!(requests[26], BoardRequest::Deliver { from: id(5), text: "1. Area 48, 486, 408, 132".into(), to: Some(id(1)) });
    assert_eq!(requests[27], BoardRequest::AnswerDecision { id: id(5), answer: Answer::Ok {} });
    assert_eq!(requests[28], BoardRequest::AnswerDecision { id: id(6), answer: Answer::Option(only("B".into())) });
    assert_eq!(requests[29], BoardRequest::AnswerDecision { id: id(6), answer: Answer::UseRecommended {} });
    assert_eq!(requests[30], BoardRequest::AnswerDecision { id: id(7), answer: Answer::Redirect(only("Make it shorter".into())) });
    // An absent optional may also come as null, and a request of a newer board is no request.
    let null = format!(r#"{{"restart":{{"id":"{}","command":null}}}}"#, id(2));
    assert_eq!(BoardRequest::decode(null.as_bytes()), Some(requests[8].clone()));
    assert_eq!(BoardRequest::decode(br#"{"teleport":{"_0":"somewhere"}}"#), None);
}

#[test]
fn events_encode_as_swift_does() {
    let names = [
        "cardAdded", "cardUpdated", "cardRemoved", "connections", "message", "runners", "runners_none", "toolCall", "postItAdded", "postItUpdated", "postItRemoved", "imageAdded", "imageUpdated",
        "imageRemoved", "attention", "held", "promptReturned", "elements", "decisions", "created", "created_refused",
    ];
    let events: Vec<BoardEvent> = names.iter().map(|name| round_trip(&format!("event_{name}"))).collect();
    assert_eq!(events[0], BoardEvent::CardAdded(only(runner())));
    assert_eq!(events[3], BoardEvent::Connections(only(lines())));
    let BoardEvent::Runners(Unlabelled { value: report }) = &events[5] else { panic!("not a report") };
    assert_eq!(report.starts, [(id(2), DATE)].into());
    assert_eq!(report.network_address.as_deref(), Some("192.168.1.20"));
    let stats = &report.stats[&id(2)];
    assert_eq!((stats.cpu, stats.memory, stats.processes), (Some(12.5), 104_857_600, 3));
    assert_eq!(stats.ports, [ListeningPort { port: 3000, exposed: true }, ListeningPort { port: 9229, exposed: false }]);
    assert_eq!(events[6], BoardEvent::Runners(only(RunnerReport::default())));
    let BoardEvent::ToolCall { arguments, name, .. } = &events[7] else { panic!("not a tool call") };
    assert_eq!((name.as_str(), arguments.0.as_slice()), ("browser_click", br#"{"target":"e12"}"#.as_slice()));
    let BoardEvent::Attention(Unlabelled { value: queue }) = &events[14] else { panic!("not the queue") };
    assert_eq!(queue.iter().map(|request| request.reason.clone()).collect::<Vec<_>>(), [Reason::TurnEnded {}, Reason::Said(only("Claude needs your permission to use Bash".into())), Reason::Waiting {}]);
    assert_eq!((queue[0].since, queue[0].context.as_deref()), (DATE, Some("Done:\nall tests pass.")));
    assert_eq!(queue[1].orchestrators, Some(vec!["Ada".to_string()]));
    let questions = queue[2].questions.as_ref().unwrap();
    assert_eq!(questions[0], AgentQuestion { question: "Which layout?".into(), header: Some("Layout".into()), options: vec![QuestionOption { label: "Grid".into(), description: Some("Rows and columns".into()) }, QuestionOption { label: "List".into(), description: None }], multi_select: true });
    assert_eq!(events[15], BoardEvent::Held { id: id(1), count: 2 });
    let BoardEvent::Elements(Unlabelled { value: elements }) = &events[17] else { panic!("not the elements") };
    assert_eq!(elements.iter().map(|info| (info.id, info.kind.as_str())).collect::<Vec<_>>(), [(id(5), "browser"), (id(6), "filetree")]);
    let BoardEvent::Decisions(Unlabelled { value: decisions }) = &events[18] else { panic!("not the decisions") };
    assert_eq!(decisions[0].cards[0].evidence, Evidence::Image { before: Some(id(6)), after: id(7) });
    assert_eq!(decisions[0].cards[1].evidence, Evidence::Image { before: None, after: id(7) });
    assert_eq!((decisions[0].organization, decisions[0].since, decisions[0].state), (Some(id(8)), DATE, DecisionState::Open));
    assert_eq!(decisions[1].cards[0].evidence, Evidence::Diagram { svg: "<svg viewBox=\"0 0 9 9\"/>".into() });
    assert_eq!(decisions[1].ask.variants().iter().map(Variant::title).collect::<Vec<_>>(), ["A - Core", "B - Direct"]);
    assert_eq!((decisions[1].blocking, decisions[1].closing, decisions[1].state, decisions[1].answer.clone()), (true, true, DecisionState::AwaitingEcho, Some(Answer::UseRecommended {})));
    assert_eq!((decisions[2].cards[0].evidence.clone(), decisions[2].cards[1].evidence.clone()), (Evidence::Browser { id: id(5) }, Evidence::Video { id: id(7) }));
    assert_eq!((decisions[2].state, decisions[2].echo.as_deref()), (DecisionState::Closed, Some("Cut a step")));
}

#[test]
fn the_state_encodes_as_swift_does() {
    let state: BoardState = round_trip("state");
    assert_eq!(state.cards, [agent(), runner(), plain()]);
    assert_eq!(state.connections, lines());
    assert_eq!(state.post_its, Some(vec![post_it(), empty_post_it()]));
    assert_eq!(state.images, Some(vec![image(), video()]));
    assert_eq!(state.attention.map(|queue| queue.len()), Some(3));
    assert_eq!(state.elements.map(|list| list.iter().map(|info| info.id).collect::<Vec<_>>()), Some(vec![id(5)]));
    assert_eq!(state.decisions.map(|list| list.len()), Some(3));
    let old: BoardState = round_trip("state_of_an_older_core");
    assert_eq!((old.post_its, old.attention, old.images, old.elements), (None, None, None, None));
    assert_eq!(old.decisions, None);
}

/// A data folder the Swift core used serves this one.
#[test]
fn a_database_written_by_swift_reads() {
    let copy = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("swift.sqlite");
    std::fs::copy(folder().join("agentboard.sqlite"), &copy).unwrap();
    let database = CardDatabase::open(&copy).unwrap();
    assert_eq!(database.agents().unwrap(), [agent(), runner(), plain()]);
    assert_eq!(database.post_its().unwrap(), [post_it(), empty_post_it()]);
    assert_eq!(database.images().unwrap(), [image(), video()]);
    assert_eq!(database.connections().unwrap(), lines());
    assert!(database.browser_ids().unwrap().is_empty());
}

/// What this core writes it reads back; the file is left in `target/tmp/rust.sqlite` for the
/// Swift test that reads it (`AGENTBOARD_RUST_DATABASE`, `BoardFixtures.readsADatabaseWrittenByRust`).
#[test]
fn a_database_round_trips() {
    let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("rust.sqlite");
    let _ = std::fs::remove_file(&path);
    {
        let mut database = CardDatabase::open(&path).unwrap();
        [agent(), runner(), plain()].iter().for_each(|card| database.save_agent(card).unwrap());
        [post_it(), empty_post_it()].iter().for_each(|note| database.save_post_it(note).unwrap());
        [image(), video()].iter().for_each(|image| database.save_image(image).unwrap());
        database.save_connections(&lines()).unwrap();
    }
    let mut database = CardDatabase::open(&path).unwrap();
    assert_eq!(database.agents().unwrap(), [agent(), runner(), plain()]);
    assert_eq!(database.post_its().unwrap(), [post_it(), empty_post_it()]);
    assert_eq!(database.images().unwrap(), [image(), video()]);
    assert_eq!(database.connections().unwrap(), lines());

    let scratch = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("scratch.sqlite");
    std::fs::copy(&path, &scratch).unwrap();
    let mut database_copy = CardDatabase::open(&scratch).unwrap();
    database_copy.delete_agent(id(3)).unwrap();
    database_copy.delete_post_it(id(5)).unwrap();
    database_copy.delete_image(id(6)).unwrap();
    database_copy.save_connections(&lines()[1..]).unwrap();
    assert_eq!(database_copy.agents().unwrap(), [agent(), runner()]);
    assert_eq!(database_copy.post_its().unwrap(), [post_it()]);
    assert_eq!(database_copy.images().unwrap(), [video()]);
    assert_eq!(database_copy.connections().unwrap(), lines()[1..]);
    // The file for Swift is as the first block left it.
    database.save_connections(&lines()).unwrap();
}
