//! The wire format against the golden files the Swift tests write (`ProtocolFixtures.swift`).

use std::collections::BTreeSet;
use std::path::PathBuf;

use runtime::core_protocol::{self, Versions};
use runtime::{CoreEvent, CoreRequest, SessionStatus, State, Uuid};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

fn fixtures(prefix: &str) -> Vec<(String, String)> {
    let folder = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/runtime");
    let mut files: Vec<_> = std::fs::read_dir(&folder).expect("run `swift test --filter ProtocolFixtures` first").flatten().map(|entry| entry.file_name().into_string().unwrap()).filter(|name| name.starts_with(prefix) && name.ends_with(".json")).collect();
    files.sort();
    files.into_iter().map(|name| (name.clone(), std::fs::read_to_string(folder.join(name)).unwrap())).collect()
}

/// Decodes every fixture, encodes it again and compares; returns the cases seen.
fn round_trip<Message: Serialize + DeserializeOwned>(prefix: &str) -> BTreeSet<String> {
    let mut cases = BTreeSet::new();
    for (name, text) in fixtures(prefix) {
        let swift: Value = serde_json::from_str(&text).unwrap();
        let message: Message = serde_json::from_str(&text).unwrap_or_else(|error| panic!("{name}: {error}"));
        cases.extend(swift.as_object().unwrap().keys().cloned());
        assert_eq!(serde_json::to_value(&message).unwrap(), swift, "{name}");
    }
    cases
}

#[test]
fn requests_match_swift() {
    let cases = round_trip::<CoreRequest>("request_");
    let all = ["annotate", "attach", "close", "hello", "observe", "resize", "run", "shutdown", "start", "stop", "subscribeHost", "subscribeStatuses", "takeOver", "terminate"];
    assert_eq!(cases.iter().map(String::as_str).collect::<Vec<_>>(), all);
}

#[test]
fn events_match_swift() {
    let cases = round_trip::<CoreEvent>("event_");
    assert_eq!(cases.iter().map(String::as_str).collect::<Vec<_>>(), ["host", "ran", "status", "welcome"]);

    let (_, text) = fixtures("event_welcome_sessions").remove(0);
    let CoreEvent::Welcome { sessions, service, .. } = serde_json::from_str(&text).unwrap() else { panic!() };
    assert_eq!(service, None);
    let id = |digit: u8| Uuid::parse(&format!("0000000{digit}-ABCD-4EF0-8A1B-00000000000{digit}")).unwrap();
    let status = |wanted: Uuid| sessions.iter().find(|(id, _)| *id == wanted).unwrap().1.clone();
    assert_eq!(sessions.len(), 3);
    assert_eq!(status(id(1)), SessionStatus { state: State::Running, process_id: Some(1), exit_code: None });
    assert_eq!(status(id(2)), SessionStatus { state: State::Exited, process_id: None, exit_code: Some(0) });
    assert_eq!(status(id(3)), SessionStatus { state: State::Stopped, process_id: None, exit_code: None });
}

#[test]
fn what_only_a_peer_writes_still_decodes() {
    let id = "00000001-abcd-4ef0-8a1b-000000000001";
    let decode = |text: String| serde_json::from_str::<CoreRequest>(&text);
    // A whole double, as Swift writes `3.0`; a lowercase id; a null where Swift leaves the key out.
    assert_eq!(decode(format!(r#"{{"terminate":{{"id":"{id}","grace":3}}}}"#)).unwrap(), CoreRequest::Terminate { id: Uuid::parse(id).unwrap(), grace: 3.0 });
    assert_eq!(decode(format!(r#"{{"close":{{"id":"{id}","grace":null}}}}"#)).unwrap(), CoreRequest::Close { id: Uuid::parse(id).unwrap(), grace: None });
    assert_eq!(decode(r#"{"hello":{"version":2}}"#.into()).unwrap(), CoreRequest::Hello { version: 2, oldest: None, answers_questions: None });
    // Keys a newer build added are dropped; a request this build doesn't know is an error the
    // server drops, never a panic.
    assert_eq!(decode(r#"{"hello":{"version":9,"oldest":2,"flavor":"new"}}"#.into()).unwrap(), CoreRequest::Hello { version: 9, oldest: Some(2), answers_questions: None });
    assert!(decode(r#"{"teleport":{}}"#.into()).is_err());
    assert!(decode("not json".into()).is_err());
    // The build before this one welcomed with an empty dictionary and no `oldest`.
    let old: CoreEvent = serde_json::from_str(r#"{"welcome":{"version":2,"sessions":[]}}"#).unwrap();
    assert_eq!(old, CoreEvent::Welcome { version: 2, oldest: None, sessions: vec![], service: None });
    // Ids go out uppercase, as Swift's do.
    assert_eq!(serde_json::to_string(&CoreRequest::Attach { id: Uuid::parse(id).unwrap() }).unwrap(), format!(r#"{{"attach":{{"id":"{}"}}}}"#, id.to_uppercase()));
}

#[test]
fn builds_agree_on_the_newest_version_both_speak() {
    let this = core_protocol::VERSIONS;
    assert_eq!((this.version, this.oldest), (10, 2));
    assert_eq!(this.agreed(Versions { version: 8, oldest: 2 }), Some(8));
    assert_eq!(this.agreed(Versions { version: 2, oldest: 2 }), Some(2));
    assert_eq!(this.agreed(Versions { version: 11, oldest: 7 }), Some(10));
    assert_eq!(this.agreed(Versions { version: 12, oldest: 11 }), None);
    assert_eq!(this.agreed(Versions { version: 1, oldest: 1 }), None);
}
