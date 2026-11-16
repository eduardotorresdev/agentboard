use serde_json::{json, Map, Value};

use crate::{Request, RequestKind, Uuid};

/// A tool an element can call, as MCP describes it.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    /// JSON Schema of the arguments (an `object` schema).
    pub input_schema: Value,
}

impl ToolDefinition {
    /// A tool that takes no arguments.
    pub fn new(name: &str, description: &str) -> Self {
        Self::with_schema(name, description, json!({"type": "object", "properties": {}}))
    }

    pub fn with_schema(name: &str, description: &str, input_schema: Value) -> Self {
        Self { name: name.to_string(), description: description.to_string(), input_schema }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ToolContent {
    Text(String),
    /// Raw image bytes (sent base64-encoded), e.g. a screenshot.
    Image { data: Vec<u8>, mime_type: String },
}

#[derive(Clone, Debug, PartialEq)]
pub struct ToolResult {
    pub content: Vec<ToolContent>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn new(content: Vec<ToolContent>) -> Self {
        Self { content, is_error: false }
    }

    pub fn text(text: impl Into<String>) -> Self {
        Self::new(vec![ToolContent::Text(text.into())])
    }

    pub fn error(text: impl Into<String>) -> Self {
        Self { content: vec![ToolContent::Text(text.into())], is_error: true }
    }
}

/// Where a tool call's result goes. Answer now, or keep it and answer when the result is there
/// (a call relayed to the board, a runner settling): the caller's connection waits, and the
/// owner's thread is free meanwhile. Dropped unanswered, the call fails with HTTP 500.
pub struct Reply(Box<dyn FnOnce(ToolResult) + Send>);

impl Reply {
    pub fn new(send: impl FnOnce(ToolResult) + Send + 'static) -> Self {
        Self(Box::new(send))
    }

    pub fn send(self, result: ToolResult) {
        (self.0)(result)
    }
}

/// A family of tools offered to board elements (messaging, a browser…). Keep the list stable for
/// a caller: clients read it once, so a tool that needs a line the caller doesn't have should
/// still be listed and explain that when called.
///
/// Every method runs on the thread that owns `state` (the board: its bus, cards, sessions).
pub trait ToolProvider<S> {
    fn tools(&self, state: &mut S, caller: Uuid) -> Vec<ToolDefinition>;

    /// Runs `name`, one of the tools this provider listed for `caller`, and gives `reply` its
    /// result. Must not block: a call that takes its time keeps `reply` for later.
    fn call(&mut self, state: &mut S, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply);

    /// What the caller should know about these tools, added to the server's instructions.
    fn instructions(&self, _state: &mut S, _caller: Uuid) -> Option<String> {
        None
    }

    /// What the caller should have in its context without asking, given before `event` (a
    /// Claude Code hook: `SessionStart`, `UserPromptSubmit`, `PostToolUse`). None when nothing
    /// is new for it.
    fn context(&mut self, _state: &mut S, _caller: Uuid, _event: &str) -> Option<String> {
        None
    }
}

/// Every provider's tools behind one MCP server (JSON-RPC 2.0). Transport-free: `ToolServer`
/// carries the requests, this answers them, on the thread that owns `S`.
pub struct ToolCatalog<S> {
    providers: Vec<Box<dyn ToolProvider<S>>>,
}

impl<S> Default for ToolCatalog<S> {
    fn default() -> Self {
        Self { providers: Vec::new() }
    }
}

impl<S> ToolCatalog<S> {
    /// The MCP server name agents see; their tools are `mcp__<name>__<tool>`.
    pub const SERVER_NAME: &'static str = "board";
    const FALLBACK_PROTOCOL_VERSION: &'static str = "2025-06-18";

    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&mut self, provider: impl ToolProvider<S> + 'static) {
        self.providers.push(Box::new(provider));
    }

    /// Answers what the tool server received when it is the catalog's to answer (a JSON-RPC
    /// message, a context hook). A question or attention hook is given back, for the owner.
    pub fn serve(&mut self, state: &mut S, mut request: Request) -> Option<Request> {
        match request.kind {
            RequestKind::Rpc => {
                let body = std::mem::take(&mut request.body);
                self.respond(state, &body, request.caller, move |answer| request.reply(answer));
            }
            RequestKind::Context => {
                let answer = self.context(state, &request.body, request.caller);
                request.reply(Some(answer));
            }
            RequestKind::Question | RequestKind::Attention => return Some(request),
        }
        None
    }

    /// Every provider's context for `caller` before `event`, as a Claude Code hook's output
    /// (empty object when there is none).
    pub fn context(&mut self, state: &mut S, hook: &[u8], caller: Uuid) -> Vec<u8> {
        let input: Value = serde_json::from_slice(hook).unwrap_or_default();
        let event = input.get("hook_event_name").and_then(Value::as_str).unwrap_or("");
        let parts: Vec<String> = self.providers.iter_mut().filter_map(|provider| provider.context(state, caller, event)).collect();
        let text = parts.join("\n\n");
        if text.is_empty() {
            return b"{}".to_vec();
        }
        encode(&json!({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}))
    }

    /// Answers one JSON-RPC message from the element `caller`: `reply` gets the answer, or none
    /// for notifications, which get no answer. A tool call may answer after this returns.
    pub fn respond(&mut self, state: &mut S, body: &[u8], caller: Uuid, reply: impl FnOnce(Option<Vec<u8>>) + Send + 'static) {
        let Ok(Value::Object(request)) = serde_json::from_slice::<Value>(body) else {
            return reply(Some(encode(&json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}))));
        };
        let Some(id) = request.get("id").filter(|id| !id.is_null()).cloned() else { return reply(None) };
        let method = request.get("method").and_then(Value::as_str).unwrap_or("");
        let empty = Map::new();
        let params = request.get("params").and_then(Value::as_object).unwrap_or(&empty);
        let result = match method {
            "initialize" => {
                let instructions: Vec<String> = self.providers.iter().filter_map(|provider| provider.instructions(state, caller)).collect();
                json!({
                    "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or(Self::FALLBACK_PROTOCOL_VERSION),
                    "capabilities": {"tools": {"listChanged": true}},
                    "serverInfo": {"name": Self::SERVER_NAME, "version": "1.0"},
                    "instructions": instructions.join("\n\n"),
                })
            }
            "ping" => json!({}),
            "tools/list" => {
                let tools: Vec<Value> = self
                    .providers
                    .iter()
                    .flat_map(|provider| provider.tools(state, caller))
                    .map(|tool| json!({"name": tool.name, "description": tool.description, "inputSchema": tool.input_schema}))
                    .collect();
                json!({"tools": tools})
            }
            "tools/call" => {
                let name = params.get("name").and_then(Value::as_str).unwrap_or("");
                let arguments = params.get("arguments").and_then(Value::as_object).unwrap_or(&empty);
                let answer = Reply::new(move |result| reply(Some(encode(&json!({"jsonrpc": "2.0", "id": id, "result": encode_result(&result)})))));
                let provider = self.providers.iter_mut().find(|provider| provider.tools(state, caller).iter().any(|tool| tool.name == name));
                match provider {
                    Some(provider) => provider.call(state, name, arguments, caller, answer),
                    None => answer.send(ToolResult::error(format!("Unknown tool “{name}”."))),
                }
                return;
            }
            _ => {
                let error = json!({"code": -32601, "message": format!("Method not found: {method}")});
                return reply(Some(encode(&json!({"jsonrpc": "2.0", "id": id, "error": error}))));
            }
        };
        reply(Some(encode(&json!({"jsonrpc": "2.0", "id": id, "result": result}))))
    }
}

fn encode_result(result: &ToolResult) -> Value {
    let content: Vec<Value> = result
        .content
        .iter()
        .map(|content| match content {
            ToolContent::Text(text) => json!({"type": "text", "text": text}),
            ToolContent::Image { data, mime_type } => json!({"type": "image", "data": base64(data), "mimeType": mime_type}),
        })
        .collect();
    json!({"content": content, "isError": result.is_error})
}

fn encode(value: &Value) -> Vec<u8> {
    serde_json::to_vec(value).expect("a JSON value encodes")
}

/// Standard base64, padded.
pub(crate) fn base64(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let bits = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for index in 0..4 {
            let sextet = (bits >> (18 - 6 * index)) & 63;
            text.push(if index <= chunk.len() { ALPHABET[sextet as usize] as char } else { '=' });
        }
    }
    text
}

#[cfg(test)]
mod tests {
    #[test]
    fn base64_pads() {
        let cases = [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy")];
        for (plain, encoded) in cases {
            assert_eq!(super::base64(plain.as_bytes()), encoded);
        }
        assert_eq!(super::base64(&[0xfb, 0xff, 0xfe]), "+//+");
    }
}
