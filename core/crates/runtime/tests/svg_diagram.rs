//! The diagram cases both cores check (`core/fixtures/diagrams/cases.json`, also run by
//! `SVGDiagramTests.swift`): drawn or refused alike, for the same reason.

use runtime::svg_diagram;
use serde_json::Value;

#[test]
fn the_shared_cases_are_drawn_or_refused_alike() {
    let folder = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/diagrams/");
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(format!("{folder}cases.json")).unwrap()).unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() > 40);
    let mut wrong = Vec::new();
    for case in cases {
        let text = if let Some(file) = case["file"].as_str() {
            std::fs::read_to_string(format!("{folder}{file}")).unwrap()
        } else if let Some(parts) = case["parts"].as_array() {
            parts.iter().map(|part| part[0].as_str().unwrap().repeat(part[1].as_u64().unwrap() as usize)).collect()
        } else {
            case["svg"].as_str().unwrap().to_string()
        };
        let got = svg_diagram::check(&text).err();
        if got.as_deref() != case["refused"].as_str() {
            wrong.push(format!("{}: expected {:?}, got {:?}", case["name"], case["refused"], got));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}
