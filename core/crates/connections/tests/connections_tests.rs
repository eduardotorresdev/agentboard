use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use connections::*;
use serde_json::{json, Map, Value};

/// A board whose agents record what they receive.
#[derive(Default)]
struct TestBoard {
    bus: MessageBus,
    inboxes: Inboxes,
    /// Calls a slow tool hasn't answered yet.
    developing: Vec<Reply>,
}

#[derive(Default)]
struct Inboxes {
    elements: Vec<Element>,
    /// Each message with its recipient's and its sender's name.
    received: Vec<(Message, String)>,
}

impl Elements for Inboxes {
    fn elements(&self) -> Vec<Element> {
        self.elements.clone()
    }

    fn receive(&mut self, message: &Message, sender: &Element) {
        self.received.push((message.clone(), sender.name.clone()));
    }
}

impl Board for TestBoard {
    fn board(&mut self) -> (&mut MessageBus, &mut dyn Elements) {
        (&mut self.bus, &mut self.inboxes)
    }
}

impl TestBoard {
    fn add(&mut self, element: Element) -> Uuid {
        self.inboxes.elements.push(element.clone());
        element.id
    }

    /// An agent that takes messages.
    fn inbox(&mut self, name: &str) -> Uuid {
        self.add(Element { endpoint: Some(Endpoint::default()), ..Element::new(Uuid::new(), name, ElementKind::agent()) })
    }

    fn connect(&mut self, x: Uuid, y: Uuid) -> Option<Connection> {
        self.bus.connect(x, y, (None, None))
    }

    fn send(&mut self, text: &str, from: Uuid, to: &str) -> Result<Message, MessageError> {
        self.bus.send(text, from, to, &mut self.inboxes)
    }

    fn deliver(&mut self, text: &str, from: Uuid, to: Uuid) -> Result<Message, MessageError> {
        self.bus.deliver(text, from, to, &mut self.inboxes)
    }

    fn set_unavailable(&mut self, id: Uuid, reason: Option<&str>) {
        let element = self.inboxes.elements.iter_mut().find(|element| element.id == id).unwrap();
        element.endpoint = Some(Endpoint { unavailable_reason: reason.map(str::to_string) });
    }

    /// The texts `id` received, and who sent them.
    fn received(&self, id: Uuid) -> Vec<(&str, &str)> {
        self.inboxes.received.iter().filter(|(message, _)| message.to == id).map(|(message, sender)| (message.text.as_str(), sender.as_str())).collect()
    }
}

// MessageBus

#[test]
fn messages_travel_only_along_lines() {
    let mut board = TestBoard::default();
    let (planner, coder, tester) = (board.inbox("Planner"), board.inbox("Coder"), board.inbox("Tester"));
    board.connect(planner, coder);

    board.send("Implement the parser", planner, "coder").unwrap();
    board.send("Done", coder, "Planner").unwrap();
    assert_eq!(board.received(coder), [("Implement the parser", "Planner")]);
    assert_eq!(board.received(planner), [("Done", "Coder")]);

    assert_eq!(board.send("Hi", planner, "Tester"), Err(MessageError::NotConnected { to: "Tester".into(), peers: vec!["Coder".into()] }));
    assert!(board.received(tester).is_empty());
}

/// An element that takes no messages itself (a browser) can still send along its lines.
#[test]
fn any_connected_element_can_deliver() {
    let mut board = TestBoard::default();
    let page = board.add(Element::new(Uuid::new(), "Mobile", ElementKind::browser()));
    let (agent, stranger) = (board.inbox("Claude"), board.inbox("Other"));
    board.connect(page, agent);
    board.deliver("checkout clicked", page, agent).unwrap();
    assert_eq!(board.received(agent), [("checkout clicked", "Mobile")]);
    assert!(matches!(board.deliver("hi", page, stranger), Err(MessageError::NotConnected { .. })));
    assert_eq!(board.deliver("hi", agent, page), Err(MessageError::NotAnEndpoint { name: "Mobile".into() }));
    assert!(board.received(stranger).is_empty());
}

#[test]
fn refuses_unavailable_and_empty_messages() {
    let mut board = TestBoard::default();
    let (a, b) = (board.inbox("A"), board.inbox("B"));
    board.connect(a, b);
    board.set_unavailable(b, Some("it exited"));
    assert_eq!(board.send("Hi", a, "B"), Err(MessageError::Unavailable { name: "B".into(), reason: "it exited".into() }));
    board.set_unavailable(b, None);
    assert_eq!(board.send("  \n", a, "B"), Err(MessageError::EmptyMessage));
    assert_eq!(board.send("Hi", Uuid::new(), "B"), Err(MessageError::UnknownSender));
    assert!(board.received(b).is_empty());
}

#[test]
fn removing_an_element_drops_its_lines() {
    let changes = Arc::new(Mutex::new(Vec::new()));
    let sent = Arc::new(Mutex::new(Vec::new()));
    let mut board = TestBoard::default();
    let (heard, seen) = (changes.clone(), sent.clone());
    board.bus.on_graph_change = Some(Box::new(move |graph| heard.lock().unwrap().push(graph.connections().len())));
    board.bus.on_message = Some(Box::new(move |message| seen.lock().unwrap().push(message.text.clone())));
    let (a, b, c) = (board.inbox("A"), board.inbox("B"), board.inbox("C"));
    board.connect(a, b);
    board.connect(b, c);
    assert_eq!(board.connect(b, a), None, "a line between the same two elements already exists");
    assert_eq!(board.connect(a, a), None);
    board.send("Hi", a, "b").unwrap();
    board.bus.remove(b);
    board.inboxes.elements.retain(|element| element.id != b);
    assert!(board.bus.graph().connections().is_empty());
    assert_eq!(*changes.lock().unwrap(), [1, 2, 0]);
    assert_eq!(*sent.lock().unwrap(), ["Hi"]);
    assert!(board.bus.peers(a, &board.inboxes).is_empty());
}

#[test]
fn lines_drawn_elsewhere_keep_their_id() {
    let mut board = TestBoard::default();
    let (a, b) = (board.inbox("A"), board.inbox("B"));
    let line = Connection { a_side: Some(Side::Left), ..Connection::new(a, b) };
    assert!(board.bus.add(line.clone()));
    assert!(!board.bus.add(Connection::new(b, a)));
    assert_eq!(board.bus.graph().connection_between(b, a), Some(&line));
    board.bus.disconnect(line.id);
    assert!(board.bus.graph().connections().is_empty());
}

// MessagingTools

fn catalog() -> ToolCatalog<TestBoard> {
    let mut catalog = ToolCatalog::new();
    catalog.add(MessagingTools);
    catalog
}

/// The answer to a JSON-RPC request, when it is there already.
fn call(tools: &mut ToolCatalog<TestBoard>, board: &mut TestBoard, method: &str, params: Value, caller: Uuid) -> Value {
    let answer = begin(tools, board, method, params, caller).try_recv().expect("answered at once");
    serde_json::from_slice(&answer.expect("an answer")).unwrap()
}

fn begin(tools: &mut ToolCatalog<TestBoard>, board: &mut TestBoard, method: &str, params: Value, caller: Uuid) -> mpsc::Receiver<Option<Vec<u8>>> {
    let body = serde_json::to_vec(&json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})).unwrap();
    let (answered, answer) = mpsc::channel();
    tools.respond(board, &body, caller, move |answer| answered.send(answer).unwrap());
    answer
}

fn text(response: &Value) -> &str {
    response["result"]["content"][0]["text"].as_str().unwrap_or("")
}

#[test]
fn sends_through_the_bus() {
    let mut board = TestBoard::default();
    let (a, b) = (board.inbox("Claude"), board.inbox("Claude 2"));
    board.connect(a, b);
    let mut tools = catalog();

    let initialize = call(&mut tools, &mut board, "initialize", json!({"protocolVersion": "2025-03-26"}), a);
    assert_eq!(initialize["result"]["protocolVersion"], "2025-03-26");
    assert!(initialize["result"]["instructions"].as_str().unwrap().contains("You are “Claude”,"));
    assert!(board.received(b).is_empty());

    let list = call(&mut tools, &mut board, "tools/list", json!({}), a);
    let names: Vec<&str> = list["result"]["tools"].as_array().unwrap().iter().map(|tool| tool["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["list_peers", "send_message"]);

    assert!(text(&call(&mut tools, &mut board, "tools/call", json!({"name": "list_peers"}), a)).contains("- “Claude 2”"));
    // As the listing quotes it: the quotes aren't part of the name.
    let arguments = json!({"name": "send_message", "arguments": {"to": "“Claude 2”", "message": "Run the tests"}});
    let sent = call(&mut tools, &mut board, "tools/call", arguments, a);
    assert_eq!(sent["result"]["isError"], false);
    assert_eq!(board.received(b), [("Run the tests", "Claude")]);

    let arguments = json!({"name": "send_message", "arguments": {"to": "Nobody", "message": "Hi"}});
    let refused = call(&mut tools, &mut board, "tools/call", arguments, a);
    assert_eq!(refused["result"]["isError"], true);
}

#[test]
fn notifications_get_no_answer() {
    let (mut tools, mut board) = (catalog(), TestBoard::default());
    let (answered, answer) = mpsc::channel();
    let body = br#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
    tools.respond(&mut board, body, Uuid::new(), move |answer| answered.send(answer).unwrap());
    assert_eq!(answer.recv().unwrap(), None);

    let (answered, answer) = mpsc::channel();
    tools.respond(&mut board, b"not json", Uuid::new(), move |answer| answered.send(answer).unwrap());
    let error: Value = serde_json::from_slice(&answer.recv().unwrap().unwrap()).unwrap();
    assert_eq!(error, json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}));
}

/// A provider whose tool answers later, and gives the caller context.
struct Camera;

impl ToolProvider<TestBoard> for Camera {
    fn tools(&self, _board: &mut TestBoard, _caller: Uuid) -> Vec<ToolDefinition> {
        vec![ToolDefinition::new("snap", "Takes a picture.")]
    }

    fn call(&mut self, board: &mut TestBoard, _name: &str, _arguments: &Map<String, Value>, _caller: Uuid, reply: Reply) {
        board.developing.push(reply);
    }

    fn context(&mut self, _board: &mut TestBoard, _caller: Uuid, event: &str) -> Option<String> {
        (event == "SessionStart").then(|| "The camera is ready.".to_string())
    }
}

/// A slow provider's call (a browser loading a page) doesn't hold up other requests, and
/// images come back as MCP image content.
#[test]
fn providers_plug_in_and_answer_when_they_can() {
    let (mut tools, mut board, caller) = (catalog(), TestBoard::default(), Uuid::new());
    tools.add(Camera);
    let slow = begin(&mut tools, &mut board, "tools/call", json!({"name": "snap"}), caller);
    assert!(text(&call(&mut tools, &mut board, "tools/call", json!({"name": "list_peers"}), caller)).starts_with("You are an agent."));
    assert!(slow.try_recv().is_err(), "still developing");

    let picture = ToolResult::new(vec![ToolContent::Image { data: vec![1, 2, 3], mime_type: "image/png".into() }]);
    board.developing.remove(0).send(picture);
    let image: Value = serde_json::from_slice(&slow.recv().unwrap().unwrap()).unwrap();
    assert_eq!(image["result"], json!({"content": [{"type": "image", "data": "AQID", "mimeType": "image/png"}], "isError": false}));

    let unknown = call(&mut tools, &mut board, "tools/call", json!({"name": "zoom"}), caller);
    assert_eq!((text(&unknown), &unknown["result"]["isError"]), ("Unknown tool “zoom”.", &json!(true)));
    let missing = call(&mut tools, &mut board, "tools/unlist", json!({}), caller);
    assert_eq!(missing["error"], json!({"code": -32601, "message": "Method not found: tools/unlist"}));
}

/// Providers' context reaches an agent as its hook's output.
#[test]
fn context_is_a_hooks_output() {
    let (mut tools, mut board, caller) = (catalog(), TestBoard::default(), Uuid::new());
    tools.add(Camera);
    let context: Value = serde_json::from_slice(&tools.context(&mut board, br#"{"hook_event_name":"SessionStart"}"#, caller)).unwrap();
    assert_eq!(context, json!({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "The camera is ready."}}));
    assert_eq!(tools.context(&mut board, br#"{"hook_event_name":"PostToolUse"}"#, caller), b"{}");
    assert_eq!(tools.context(&mut board, b"", caller), b"{}");
}

// ToolServer

/// What the board's thread does with the server's requests: the catalog answers what it can,
/// questions get the developer's answer, attention is noted.
struct Owner {
    server: ToolServer,
    port: u16,
    thread: thread::JoinHandle<(TestBoard, Vec<String>)>,
}

impl Owner {
    fn start(board: TestBoard, secret: Option<Vec<u8>>, preferred_port: Option<u16>) -> Owner {
        let (requests, incoming) = mpsc::channel::<Request>();
        // A Sender is Sync, but the lock keeps this independent of the Rust version.
        let requests = Mutex::new(requests);
        let server = ToolServer::new(Arc::new(move |request| requests.lock().unwrap().send(request).unwrap()), secret);
        let url = server.start(preferred_port).expect("the server starts");
        let port = url.strip_prefix("http://127.0.0.1:").and_then(|rest| rest.strip_suffix("/mcp")).expect("the endpoint URL").parse().unwrap();
        let thread = thread::spawn(move || {
            let (mut board, mut tools, mut attention) = (board, catalog(), Vec::new());
            for request in incoming {
                let Some(request) = tools.serve(&mut board, request) else { continue };
                let body = String::from_utf8_lossy(&request.body).into_owned();
                match request.kind {
                    RequestKind::Question => request.reply((body != "terminal").then(|| format!("{{\"answered\":{body}}}").into_bytes())),
                    _ => attention.push(format!("{} {body}", request.caller)),
                }
            }
            (board, attention)
        });
        Owner { server, port, thread }
    }

    /// Stops the server and gives back the board and the attention hooks heard.
    fn finish(self) -> (TestBoard, Vec<String>) {
        drop(self.server);
        self.thread.join().unwrap()
    }
}

/// One request on a connection of its own: the status and the body.
fn request(port: u16, method: &str, path: &str, token: Option<&str>, body: Option<&str>) -> (u16, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let authorization = token.map(|token| format!("Authorization: Bearer {token}\r\n")).unwrap_or_default();
    let body = body.unwrap_or("");
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\n\
         {authorization}Connection: close\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    )
    .unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    let (head, body) = response.split_once("\r\n\r\n").expect("a whole response");
    assert!(head.contains(&format!("Content-Length: {}", body.len())), "{head}");
    (head[9..12].parse().unwrap(), body.to_string())
}

fn post(port: u16, token: Option<&str>, body: Value) -> (u16, Value) {
    let (status, body) = request(port, "POST", "/mcp", token, Some(&body.to_string()));
    (status, serde_json::from_str(&body).unwrap_or(Value::Null))
}

fn send_message(id: u64, to: &str, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": "send_message", "arguments": {"to": to, "message": message}}})
}

#[test]
fn serves_tools_to_token_holders() {
    let mut board = TestBoard::default();
    let (a, b) = (board.inbox("A"), board.inbox("B"));
    board.connect(a, b);
    let owner = Owner::start(board, None, None);
    let (port, token) = (owner.port, owner.server.token(a));
    assert_eq!(owner.server.token(a), token);
    let token = Some(token.as_str());

    let (status, initialize) = post(port, token, json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}));
    assert_eq!(status, 200);
    assert_eq!(initialize["result"]["serverInfo"], json!({"name": "board", "version": "1.0"}));
    assert_eq!(initialize["result"]["capabilities"], json!({"tools": {"listChanged": true}}));
    assert!(initialize["result"]["instructions"].as_str().unwrap().starts_with("You are “A”, one of several coding agents"));

    let (status, list) = post(port, token, json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}));
    assert_eq!(status, 200);
    assert_eq!(list["result"]["tools"][1]["inputSchema"]["required"], json!(["to", "message"]));

    let (_, peers) = post(port, token, json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "list_peers"}}));
    assert_eq!(text(&peers), format!("You are “A”. On the board:\n- “B” (agent, id: {b}, made by: the user, connected: true)"));

    let (status, sent) = post(port, token, send_message(7, "B", "Hello"));
    assert_eq!((status, &sent["id"]), (200, &json!(7)));
    assert_eq!(text(&sent), "Delivered to “B”. Their reply, if any, arrives in your terminal as a message.");

    assert_eq!(post(port, None, send_message(8, "B", "No token")).0, 401);
    assert_eq!(post(port, Some("forged"), send_message(9, "B", "Forged")).0, 401);
    assert_eq!(post(port, token, json!({"jsonrpc": "2.0", "method": "notifications/initialized"})), (202, Value::Null));
    assert_eq!(request(port, "DELETE", "/mcp", token, None).0, 405);
    assert_eq!(request(port, "POST", "/elsewhere", token, Some("{}")).0, 404);
    assert_eq!(request(port, "POST", "/mcp?session=1", token, Some(r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)).0, 200);
    owner.server.revoke(a);
    assert_eq!(post(port, token, send_message(10, "B", "Revoked")).0, 401);

    let (board, _) = owner.finish();
    assert_eq!(board.received(b), [("Hello", "A")]);
}

/// A connection is kept between requests, and answers each in turn.
#[test]
fn connections_are_kept_alive() {
    let mut board = TestBoard::default();
    let a = board.inbox("A");
    let owner = Owner::start(board, None, None);
    let token = owner.server.token(a);
    let mut stream = TcpStream::connect(("127.0.0.1", owner.port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let ping = |id: u64| {
        let body = json!({"jsonrpc": "2.0", "id": id, "method": "ping"}).to_string();
        format!("POST /mcp HTTP/1.1\r\nauthorization: bearer {token}\r\nContent-Length: {}\r\n\r\n{body}", body.len())
    };
    // Two at once: the second waits in the buffer for the first's answer.
    stream.write_all((ping(1) + &ping(2)).as_bytes()).unwrap();
    let expected = |id: u64| {
        let body = json!({"jsonrpc": "2.0", "id": id, "result": {}}).to_string();
        format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: keep-alive\r\nContent-Type: application/json\r\n\r\n{body}", body.len())
    };
    let mut received = vec![0; (expected(1) + &expected(2)).len()];
    stream.read_exact(&mut received).unwrap();
    assert_eq!(String::from_utf8(received).unwrap(), expected(1) + &expected(2));
    owner.finish();
}

/// The hooks' paths: context from the catalog, questions answered by the owner when it can,
/// attention heard without the hook waiting.
#[test]
fn serves_the_agents_hooks() {
    let mut board = TestBoard::default();
    let a = board.inbox("A");
    let owner = Owner::start(board, None, None);
    let (port, token) = (owner.port, owner.server.token(a));
    let token = Some(token.as_str());

    assert_eq!(request(port, "POST", "/mcp/context", token, Some(r#"{"hook_event_name":"SessionStart"}"#)), (200, "{}".into()));
    assert_eq!(request(port, "POST", "/mcp/question", token, Some("[1]")), (200, r#"{"answered":[1]}"#.into()));
    assert_eq!(request(port, "POST", "/mcp/question", token, Some("terminal")), (200, "{}".into()));
    assert_eq!(request(port, "POST", "/mcp/attention", token, Some(r#"{"hook_event_name":"Stop"}"#)), (200, "{}".into()));
    assert_eq!(request(port, "POST", "/mcp/attention", None, Some("{}")).0, 401);

    let (_, attention) = owner.finish();
    assert_eq!(attention, [format!(r#"{a} {{"hook_event_name":"Stop"}}"#)]);
}

/// With a secret, a server started later (the core relaunched) takes the same port and
/// accepts the token an agent was launched with by the earlier one.
#[test]
fn secret_keeps_links_across_restarts() {
    let mut board = TestBoard::default();
    let (a, b) = (board.inbox("A"), board.inbox("B"));
    board.connect(a, b);
    let secret: Vec<u8> = (0..32).collect();
    let first = Owner::start(board, Some(secret.clone()), None);
    let (port, token) = (first.port, first.server.token(a));
    let (board, _) = first.finish();

    let second = Owner::start(board, Some(secret), Some(port));
    assert_eq!(second.port, port);
    assert_eq!(second.server.token(a), token);
    assert_eq!(post(port, Some(&token), send_message(1, "B", "Again")).0, 200);
    // Another secret derives other tokens.
    let other = ToolServer::new(Arc::new(|_| {}), Some(vec![9; 32]));
    assert_ne!(other.token(a), token);
    // Without one they are random, and as steady.
    let random = ToolServer::new(Arc::new(|_| {}), None);
    assert_eq!(random.token(a).len(), 72);
    assert_eq!(random.token(a), random.token(a));
    let (board, _) = second.finish();
    assert_eq!(board.received(b), [("Again", "A")]);
}

/// An agent's event stream: a TCP connection that asked for one, read with a deadline.
struct Stream {
    stream: TcpStream,
    received: String,
}

impl Stream {
    fn open(port: u16, token: Option<&str>) -> Stream {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        let authorization = token.map(|token| format!("Authorization: Bearer {token}\r\n")).unwrap_or_default();
        write!(stream, "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n{authorization}Accept: text/event-stream\r\n\r\n").unwrap();
        Stream { stream, received: String::new() }
    }

    /// Everything read until `text` turns up after what earlier calls consumed, or none.
    fn read_until(&mut self, text: &str, timeout: Duration) -> Option<String> {
        let deadline = Instant::now() + timeout;
        let mut chunk = [0; 4096];
        while !self.received.contains(text) {
            let left = deadline.checked_duration_since(Instant::now()).filter(|left| !left.is_zero())?;
            self.stream.set_read_timeout(Some(left)).unwrap();
            let count = self.stream.read(&mut chunk).ok().filter(|count| *count > 0)?;
            self.received += &String::from_utf8_lossy(&chunk[..count]);
        }
        let end = self.received.find(text).unwrap() + text.len();
        let rest = self.received.split_off(end);
        Some(std::mem::replace(&mut self.received, rest))
    }
}

/// An agent's GET opens an event stream, on which the server says when the tools changed.
/// Requests keep being answered meanwhile.
#[test]
fn streams_hear_of_tool_changes() {
    let mut board = TestBoard::default();
    let a = board.inbox("A");
    let owner = Owner::start(board, Some(vec![3; 32]), None);
    let (port, token) = (owner.port, owner.server.token(a));
    let changed = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n";
    let soon = Duration::from_secs(3);

    assert!(Stream::open(port, None).read_until("\r\n\r\n", soon).unwrap().starts_with("HTTP/1.1 401"));
    let mut stream = Stream::open(port, Some(&token));
    let head = stream.read_until("\r\n\r\n", soon).unwrap();
    assert_eq!(head, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n");
    let mut other = Stream::open(port, Some(&token));
    other.read_until("\r\n\r\n", soon).unwrap();

    owner.server.notify_tools_changed();
    assert_eq!(stream.read_until("\n\n", soon).as_deref(), Some(changed));
    assert_eq!(other.read_until("\n\n", soon).as_deref(), Some(changed));
    assert_eq!(post(port, Some(&token), json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})).0, 200);
    // One that went is forgotten; the other still hears.
    drop(other);
    owner.server.notify_tools_changed();
    assert_eq!(stream.read_until("\n\n", soon).as_deref(), Some(changed));
    assert_eq!(stream.read_until("\n\n", Duration::from_millis(200)), None, "nothing else was said");

    // Stopping ends the stream.
    owner.finish();
    assert_eq!(stream.stream.read(&mut [0; 16]).unwrap_or(0), 0);
}

/// A taken preferred port falls back to a free one.
#[test]
fn taken_port_falls_back() {
    let first = Owner::start(TestBoard::default(), None, None);
    let second = Owner::start(TestBoard::default(), None, Some(first.port));
    assert_ne!(second.port, first.port);
    assert_eq!(second.server.start(None), None, "it runs already");
    first.finish();
    second.finish();
}

// Rope

const LEFT: RopeAnchor = RopeAnchor { point: Point::new(300.0, 100.0), direction: Vector::new(1.0, 0.0) };
const RIGHT: RopeAnchor = RopeAnchor { point: Point::new(700.0, 100.0), direction: Vector::new(-1.0, 0.0) };

fn settle(rope: &mut Rope) {
    for _ in 0..1200 {
        rope.advance(1.0 / 60.0);
    }
}

/// The rope's ends stay exactly on the handles it was tied to, wherever they move.
#[test]
fn ends_stay_on_their_anchors() {
    let mut rope = Rope::new(LEFT, RIGHT);
    let moved = RopeAnchor::side(Point::new(650.0, 400.0), Side::Top);
    rope.tie(LEFT, moved);
    for _ in 0..240 {
        rope.advance(1.0 / 60.0);
    }
    assert_eq!(rope.points().first(), Some(&LEFT.point));
    assert_eq!(rope.points().last(), Some(&moved.point));
}

/// Between level ends the rope sags below them, lowest near the middle.
#[test]
fn hangs_under_gravity() {
    assert_eq!((LEFT, RIGHT), (RopeAnchor::side(LEFT.point, Side::Right), RopeAnchor::side(RIGHT.point, Side::Left)));
    let rope = Rope::resting(LEFT, RIGHT);
    let lowest = rope.points().into_iter().max_by(|a, b| a.y.total_cmp(&b.y)).unwrap();
    assert!(lowest.y > LEFT.point.y + 20.0);
    assert!((lowest.x - 500.0).abs() < 60.0);
}

/// Near a card the rope leaves straight out of the side it is plugged into.
#[test]
fn leaves_straight_out_of_its_side() {
    let top = RopeAnchor::side(Point::new(300.0, 100.0), Side::Top);
    let rope = Rope::resting(top, RIGHT);
    assert!(rope.points()[1].y < top.point.y);
    assert!((rope.points()[1].x - top.point.x).abs() < 2.0);
}

/// Left alone, a swinging rope comes to rest; moving an end wakes it.
#[test]
fn comes_to_rest_and_wakes_when_an_end_moves() {
    let mut rope = Rope::new(LEFT, RIGHT);
    settle(&mut rope);
    assert!(rope.is_settled());
    rope.tie(LEFT, RopeAnchor::side(Point::new(720.0, 140.0), Side::Left));
    assert!(!rope.is_settled());
    let before = rope.points();
    rope.advance(1.0 / 60.0);
    assert_ne!(rope.points(), before);
}

/// Pulled apart, the rope grows to keep a little slack instead of staying taut.
#[test]
fn grows_with_its_ends() {
    let mut rope = Rope::resting(LEFT, RIGHT);
    rope.tie(LEFT, RopeAnchor::side(Point::new(1300.0, 100.0), Side::Left));
    settle(&mut rope);
    let route = rope.route();
    assert!(route.length() > 1000.0);
    assert!(rope.points().iter().any(|point| point.y > 140.0));
    assert_eq!(route.point_at(0.0), LEFT.point);
    assert_eq!(route.reversed().point_at(0.0), Point::new(1300.0, 100.0));
    assert_eq!(route.distance_to(Point::new(300.0, 60.0)), 40.0);
}

// Board listing

/// list_peers shows the whole board, flagged by connection, and leaves other boards out.
#[test]
fn lists_every_element_on_the_board_with_connected_flag() {
    let mut board = TestBoard::default();
    let mut note = |name: &str, on: &str| board.add(Element { board: Some(on.into()), ..Element::new(Uuid::new(), name, ElementKind::post_it()) });
    let (me, near, far, _elsewhere) = (note("Me", "w1"), note("Near", "w1"), note("Far", "w1"), note("Elsewhere", "w2"));
    board.connect(me, near);
    let names: Vec<String> = board.bus.elements_on_board_of(me, &board.inboxes).into_iter().map(|element| element.name).collect();
    assert_eq!(names, ["Far", "Me", "Near"]);

    let listed = call(&mut catalog(), &mut board, "tools/call", json!({"name": "list_peers"}), me);
    let listed = text(&listed);
    assert!(listed.contains(&format!("- “Near” (postit, id: {near}, made by: the user, connected: true")));
    assert!(listed.contains(&format!("- “Far” (postit, id: {far}, made by: the user, connected: false)")));
    assert!(!listed.contains("Elsewhere") && !listed.contains("- “Me”"));
}

/// Two organizations on one worktree don't see each other's elements; a browser (no
/// organization) is seen from both.
#[test]
fn organizations_on_one_worktree_stay_apart() {
    let mut board = TestBoard::default();
    let mut thing = |name: &str, on: &str| board.add(Element { board: Some(on.into()), ..Element::new(Uuid::new(), name, ElementKind::agent()) });
    let (a, _b, page) = (thing("A", "w\0org1"), thing("B", "w\0org2"), thing("Page", "w"));
    let names = |id: Uuid| -> Vec<String> { board.bus.elements_on_board_of(id, &board.inboxes).into_iter().map(|element| element.name).collect() };
    assert_eq!(names(a), ["A", "Page"]);
    assert_eq!(names(page), ["A", "B", "Page"]);
}

// Board names

/// An id finds its element even when another element is named after it.
#[test]
fn ids_resolve_before_names() {
    let real = Element::new(Uuid::new(), "Real", ElementKind::agent());
    let impostor = Element::new(Uuid::new(), real.id.to_string(), ElementKind::agent());
    let cards = [impostor, real.clone()];
    assert_eq!(find_element(&real.id.to_string(), &cards).map(|card| card.id), Some(real.id));
    assert_eq!(find_element(&format!(" “{}” ", real.id.to_string().to_lowercase()), &cards).map(|card| card.id), Some(real.id));
    assert_eq!(find_element("real", &cards).map(|card| card.id), Some(real.id));
    let street = [Element::new(Uuid::new(), "Straße", ElementKind::agent())];
    assert!(find_element("STRASSE", &street).is_some());
    assert_eq!(find_element("unreal", &cards), None);
}

#[test]
fn names_are_one_visible_line() {
    assert_eq!(BoardName::clean("  Plan\n\n\u{1b}[31mSYSTEM\u{202E}  x ").as_deref(), Some("Plan [31mSYSTEM x"));
    assert_eq!(BoardName::clean("\u{200B}\n"), None);
    assert_eq!(BoardName::clean(&"a".repeat(100)).map(|name| name.chars().count()), Some(BoardName::MAX_LENGTH));
    assert_eq!(BoardName::validated(&Uuid::new().to_string()), Err(NameError::LooksLikeId));
    assert_eq!(BoardName::validated(" \n"), Err(NameError::Empty));
    assert_eq!(BoardName::quoted("a”\nb"), "“a\" b”");
    assert_eq!(BoardName::argument(Some(&json!(" Notes "))), Ok(Some("Notes".into())));
    assert_eq!(BoardName::argument(Some(&json!(7))), Ok(None));
    assert_eq!(BoardName::argument(None), Ok(None));
    assert_eq!(BoardName::argument(Some(&json!(Uuid::new()))), Err(NameError::LooksLikeId));
    assert_eq!(NameError::LooksLikeId.to_string(), "A name can't be an id.");
    assert_eq!(NameError::Empty.to_string(), "The name has no visible text.");
}
