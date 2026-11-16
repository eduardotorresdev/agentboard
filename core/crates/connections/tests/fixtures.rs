//! The golden files the Swift tests write (`swift test --filter ConnectionsFixtures`): what
//! crosses the wire and what agents read must be the same from this core.

use std::collections::HashMap;
use std::sync::mpsc;

use connections::*;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

fn fixture(name: &str) -> Value {
    let path = format!("{}/../../fixtures/connections/{name}.json", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{path}: {error}"))).unwrap()
}

/// Decodes the fixture and encodes it again: nothing lost, nothing added.
fn round_trip<T: DeserializeOwned + Serialize>(name: &str) -> T {
    let golden = fixture(name);
    let decoded: T = serde_json::from_value(golden.clone()).unwrap();
    assert_eq!(serde_json::to_value(&decoded).unwrap(), golden, "{name}");
    decoded
}

fn id(digit: u8) -> Uuid {
    Uuid::parse(&format!("0000000{digit}-ABCD-4EF0-8A1B-00000000000{digit}")).unwrap()
}

#[test]
fn wire_types_encode_as_swift_does() {
    assert_eq!(round_trip::<Vec<Side>>("sides"), Side::ALL);
    let drawn: Connection = round_trip("connection");
    assert_eq!(drawn, Connection { id: id(1), a: id(2), b: id(3), a_side: Some(Side::Right), b_side: Some(Side::Top) });
    let routed: Connection = round_trip("connection_without_sides");
    assert_eq!((routed.a_side, routed.b_side), (None, None));
    assert_eq!(round_trip::<Vec<Connection>>("connections").len(), 3);
    let message: Message = round_trip("message");
    assert_eq!((message.from, message.to, message.date), (id(2), id(3), 784_111_222.5));
    assert_eq!(message.text, "Run the tests:\n“all” of them, please/thanks ✅");
    // Swift writes ids in uppercase, and takes either case.
    assert_eq!(serde_json::to_string(&id(1)).unwrap(), "\"00000001-ABCD-4EF0-8A1B-000000000001\"");
    assert_eq!(serde_json::from_str::<Uuid>("\"00000001-abcd-4ef0-8a1b-000000000001\"").unwrap(), id(1));
    // An absent optional may also come as null.
    let with_null: Connection = serde_json::from_str(&format!(r#"{{"id":"{}","a":"{}","b":"{}","aSide":null}}"#, id(1), id(2), id(3))).unwrap();
    assert_eq!(with_null.a_side, None);
}

/// An agent launched by the Swift core keeps its token under this one.
#[test]
fn tokens_are_derived_as_swift_does() {
    let golden = fixture("token");
    let secret: Vec<u8> = serde_json::from_value(golden["secret"].clone()).unwrap();
    let element = Uuid::parse(golden["element"].as_str().unwrap()).unwrap();
    let server = ToolServer::new(std::sync::Arc::new(|_| {}), Some(secret));
    assert_eq!(server.token(element), golden["token"].as_str().unwrap());
    assert_eq!(server.token(element), "9f2133fefb3ad9bd569d45aa6b4f2139545f4c2e58bfda256ffcdb6a7e6c33af");
}

#[test]
fn names_are_cleaned_as_swift_does() {
    for entry in fixture("names").as_array().unwrap() {
        let input: String = entry["input"].as_array().unwrap().iter().map(|scalar| char::from_u32(scalar.as_u64().unwrap() as u32).unwrap()).collect();
        assert_eq!(BoardName::clean(&input).as_deref(), entry.get("clean").and_then(Value::as_str), "clean {input:?}");
        assert_eq!(BoardName::quoted(&input), entry["quoted"].as_str().unwrap(), "quoted {input:?}");
        assert_eq!(BoardName::named(&input, "Fallback"), entry["named"].as_str().unwrap(), "named {input:?}");
    }
}

/// The board `mcp.json` describes.
struct Sample {
    bus: MessageBus,
    elements: SampleElements,
}

struct SampleElements {
    all: Vec<Element>,
    queue_notes: HashMap<Uuid, String>,
}

impl Elements for SampleElements {
    fn elements(&self) -> Vec<Element> {
        self.all.clone()
    }
    fn receive(&mut self, _message: &Message, _sender: &Element) {}
    fn queue_note(&self, id: Uuid) -> Option<String> {
        self.queue_notes.get(&id).cloned()
    }
}

impl Board for Sample {
    fn board(&mut self) -> (&mut MessageBus, &mut dyn Elements) {
        (&mut self.bus, &mut self.elements)
    }
}

/// Instructions, tool listings, peer listings and every refusal: word for word what the Swift
/// core answers to the same requests on the same board.
#[test]
fn tools_answer_as_swift_does() {
    let golden = fixture("mcp");
    let uuid = |value: &Value| Uuid::parse(value.as_str().unwrap()).unwrap();
    let text = |value: &Value| value.as_str().map(str::to_string);
    let mut sample = Sample { bus: MessageBus::default(), elements: SampleElements { all: Vec::new(), queue_notes: HashMap::new() } };
    for element in golden["elements"].as_array().unwrap() {
        let id = uuid(&element["id"]);
        sample.elements.all.push(Element {
            detail: text(&element["detail"]),
            endpoint: element["endpoint"].as_bool().unwrap().then(|| Endpoint { unavailable_reason: text(&element["unavailable"]) }),
            ..Element::new(id, element["name"].as_str().unwrap(), ElementKind(element["kind"].as_str().unwrap().into()))
        });
        sample.elements.queue_notes.extend(text(&element["queueNote"]).map(|note| (id, note)));
    }
    for line in golden["connections"].as_array().unwrap() {
        sample.bus.connect(uuid(&line[0]), uuid(&line[1]), (None, None)).unwrap();
    }
    let mut catalog = ToolCatalog::new();
    catalog.add(MessagingTools);

    let exchanges = golden["exchanges"].as_array().unwrap();
    assert_eq!(exchanges.len(), 20);
    for exchange in exchanges {
        let (answered, answer) = mpsc::channel();
        let body = serde_json::to_vec(&exchange["request"]).unwrap();
        catalog.respond(&mut sample, &body, uuid(&exchange["caller"]), move |answer| answered.send(answer).unwrap());
        let response = answer.recv().unwrap().map_or(Value::Null, |answer| serde_json::from_slice(&answer).unwrap());
        assert_eq!(response, exchange["response"], "{}", exchange["request"]);
    }
}
