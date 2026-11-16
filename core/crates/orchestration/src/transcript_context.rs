use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::{Map, Value};

/// What a waiting agent asks the developer to decide on, read from the end of its Claude Code
/// conversation (JSONL, one content block per assistant line): the newest of its last turn's
/// text, a question it asked (AskUserQuestion), or a tool call waiting for permission.
pub struct TranscriptContext;

impl TranscriptContext {
    /// How much of the file's end is read: a turn's last blocks fit in far less.
    pub const TAIL_BYTES: u64 = 512 * 1024;
    pub const MAX_LENGTH: usize = 4000;

    /// What the agent last said in its turn, leaving out its tool calls: the words before the
    /// questions a form shows on their own.
    pub fn last_text(path: &Path) -> Option<String> {
        Self::last(path, true)
    }

    pub fn last_request(path: &Path) -> Option<String> {
        Self::last(path, false)
    }

    fn last(path: &Path, text_only: bool) -> Option<String> {
        let mut file = std::fs::File::open(path).ok()?;
        let size = file.seek(SeekFrom::End(0)).unwrap_or(0);
        file.seek(SeekFrom::Start(size.saturating_sub(Self::TAIL_BYTES))).ok()?;
        let mut data = Vec::new();
        file.read_to_end(&mut data).ok()?;
        // The first line may be cut by the seek; it fails to parse and is skipped.
        for line in String::from_utf8_lossy(&data).split('\n').rev() {
            let Ok(Value::Object(entry)) = serde_json::from_str::<Value>(line) else { continue };
            if entry.get("isSidechain") == Some(&Value::Bool(true)) || entry.get("isMeta") == Some(&Value::Bool(true)) {
                continue;
            }
            let Some(message) = entry.get("message").and_then(Value::as_object) else { continue };
            match entry.get("type").and_then(Value::as_str) {
                Some("assistant") => {
                    for block in objects(message.get("content")).into_iter().rev() {
                        if text_only && block.get("type").and_then(Value::as_str) != Some("text") {
                            continue;
                        }
                        if let Some(found) = describe(block) {
                            return Some(found);
                        }
                    }
                }
                // The developer's own prompt: the turn began here and said nothing worth showing.
                Some("user") if !is_tool_result(message) => return None,
                _ => {}
            }
        }
        None
    }

    pub fn trimmed(text: &str) -> Option<String> {
        let text = text.trim();
        if text.is_empty() {
            return None;
        }
        // Swift counts characters; scalars cut at the same place for all but long clusters.
        Some(if text.chars().count() > Self::MAX_LENGTH { text.chars().take(Self::MAX_LENGTH).collect::<String>() + "…" } else { text.to_string() })
    }
}

/// The objects of a JSON array; nothing when it isn't an array of objects.
pub(crate) fn objects(value: Option<&Value>) -> Vec<&Map<String, Value>> {
    value.and_then(Value::as_array).and_then(|items| items.iter().map(Value::as_object).collect()).unwrap_or_default()
}

fn is_tool_result(message: &Map<String, Value>) -> bool {
    objects(message.get("content")).iter().any(|block| block.get("type").and_then(Value::as_str) == Some("tool_result"))
}

fn describe(block: &Map<String, Value>) -> Option<String> {
    match block.get("type").and_then(Value::as_str) {
        Some("text") => block.get("text").and_then(Value::as_str).and_then(TranscriptContext::trimmed),
        Some("tool_use") => {
            let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
            let empty = Map::new();
            let input = block.get("input").and_then(Value::as_object).unwrap_or(&empty);
            if let (true, Some(questions)) = (name == "AskUserQuestion", input.get("questions").filter(|questions| questions.is_array())) {
                let asked: Vec<String> = objects(Some(questions))
                    .iter()
                    .map(|question| {
                        let options: Vec<String> = objects(question.get("options")).iter().filter_map(|option| option.get("label")?.as_str()).map(|label| format!("- {label}")).collect();
                        let text = question.get("question").and_then(Value::as_str).unwrap_or("");
                        if options.is_empty() { text.to_string() } else { format!("{text}\n{}", options.join("\n")) }
                    })
                    .collect();
                return TranscriptContext::trimmed(&asked.join("\n\n"));
            }
            // A call waiting for permission: the tool and what it would act on.
            let target = ["command", "file_path", "url", "path", "pattern", "description"].iter().find_map(|key| input.get(*key)?.as_str());
            TranscriptContext::trimmed(&format!("**{name}**{}", target.map(|target| format!("\n`{target}`")).unwrap_or_default()))
        }
        _ => None,
    }
}
