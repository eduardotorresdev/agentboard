use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::Uuid;

/// What an agent posted, and to which of the server's paths.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestKind {
    /// `ToolServer::PATH`: a JSON-RPC message, for `ToolCatalog::respond`.
    Rpc,
    /// `ToolServer::CONTEXT_PATH`: a hook's input, for `ToolCatalog::context`.
    Context,
    /// `ToolServer::QUESTION_PATH`: the questions an agent is about to ask. The reply is the
    /// hook's output, once the developer answered; none leaves them to the agent's terminal.
    Question,
    /// `ToolServer::ATTENTION_PATH`: an attention hook's input. Already answered; nothing to reply.
    Attention,
}

/// One request from an authenticated element, handed to the server's handler. The agent's
/// connection waits until `reply` is called, however long that takes.
pub struct Request {
    pub caller: Uuid,
    pub kind: RequestKind,
    /// The body as posted: JSON-RPC, or a hook's input.
    pub body: Vec<u8>,
    reply: mpsc::Sender<Option<Vec<u8>>>,
}

impl Request {
    /// A request and where its reply arrives, as the server makes them.
    pub fn new(caller: Uuid, kind: RequestKind, body: Vec<u8>) -> (Request, mpsc::Receiver<Option<Vec<u8>>>) {
        let (reply, answer) = mpsc::channel();
        (Request { caller, kind, body, reply }, answer)
    }

    /// Answers with a JSON body. None is "no answer": 202 for a JSON-RPC notification, `{}`
    /// for a hook.
    pub fn reply(self, answer: Option<Vec<u8>>) {
        let _ = self.reply.send(answer);
    }
}

/// Called on a connection's thread for each request: pass it to the thread that owns the board
/// (through a channel) and return.
pub type Handler = Arc<dyn Fn(Request) + Send + Sync>;

/// Carries tool calls to agents over MCP's Streamable HTTP transport, on 127.0.0.1 only.
/// Each element gets its own bearer token, which is how a request says who is asking; a request
/// without a known token is refused. Answers are plain JSON. An agent's GET opens an event
/// stream, on which `notify_tools_changed` tells it to list the tools again.
///
/// Given a `secret`, tokens are derived from it and the element's id, and `start` tries the port
/// it had before: an agent launched by an earlier run of the core then reaches the new one with
/// the URL and token it was launched with.
///
/// One thread accepts, one per connection reads requests one at a time, one writes the events.
// shortcut: no hand-over to a replacing process (Swift's `drain`, `release`, `start(inheriting:)`), add when the Rust core updates in place.
pub struct ToolServer {
    shared: Arc<Shared>,
    running: Mutex<Option<Running>>,
}

struct Shared {
    handler: Handler,
    secret: Option<Vec<u8>>,
    on_request: Option<Arc<dyn Fn(String) + Send + Sync>>,
    keep_alive_interval: Duration,
    tokens: Mutex<Tokens>,
    /// Open connections by a number of their own, and whether each is an event stream.
    connections: Mutex<HashMap<u64, (TcpStream, bool)>>,
    next_connection: AtomicU64,
}

#[derive(Default)]
struct Tokens {
    callers: HashMap<String, Uuid>,
    tokens: HashMap<Uuid, String>,
}

struct Running {
    address: SocketAddr,
    stopped: Arc<AtomicBool>,
    accepting: JoinHandle<()>,
    /// Each send is a "tools changed" event to write; dropping it ends the events thread.
    events: mpsc::Sender<()>,
}

impl ToolServer {
    pub const PATH: &'static str = "/mcp";
    /// Where an agent's hooks fetch what it should have in context (see `ToolCatalog::context`).
    pub const CONTEXT_PATH: &'static str = "/mcp/context";
    /// Where an agent's hook posts the questions it is about to ask (AskUserQuestion) and waits
    /// for the developer's answers.
    pub const QUESTION_PATH: &'static str = "/mcp/question";
    /// Where an agent's hooks post that it waits on the developer, or works again.
    pub const ATTENTION_PATH: &'static str = "/mcp/attention";

    /// A stream with nothing on it this long is sent a comment, or clients time it out.
    const KEEP_ALIVE_INTERVAL: Duration = Duration::from_secs(25);
    /// A stream that takes no bytes for this long is gone.
    const STREAM_WRITE_TIMEOUT: Duration = Duration::from_secs(5);
    const MAXIMUM_HEADER: usize = 64 * 1024;
    const MAXIMUM_BODY: usize = 4 * 1024 * 1024;

    pub fn new(handler: Handler, secret: Option<Vec<u8>>) -> Self {
        Self::with(handler, secret, None, Self::KEEP_ALIVE_INTERVAL)
    }

    /// As `new`, hearing of each request (`<caller> <method>`) and stream opened, for a log.
    pub fn logging(handler: Handler, secret: Option<Vec<u8>>, on_request: Arc<dyn Fn(String) + Send + Sync>) -> Self {
        Self::with(handler, secret, Some(on_request), Self::KEEP_ALIVE_INTERVAL)
    }

    fn with(handler: Handler, secret: Option<Vec<u8>>, on_request: Option<Arc<dyn Fn(String) + Send + Sync>>, keep_alive_interval: Duration) -> Self {
        let shared = Shared {
            handler,
            secret,
            on_request,
            keep_alive_interval,
            tokens: Mutex::default(),
            connections: Mutex::default(),
            next_connection: AtomicU64::new(0),
        };
        Self { shared: Arc::new(shared), running: Mutex::new(None) }
    }

    /// Starts listening on `preferred_port`, or a free port when that one is taken. Returns the
    /// endpoint URL, or none if it couldn't start (or already runs).
    pub fn start(&self, preferred_port: Option<u16>) -> Option<String> {
        let mut running = self.running.lock().unwrap();
        if running.is_some() {
            return None;
        }
        // std sets SO_REUSEADDR and close-on-exec, as the Swift server does by hand.
        let listen = |port: u16| TcpListener::bind((Ipv4Addr::LOCALHOST, port)).ok();
        let listener = listen(preferred_port.unwrap_or(0)).or_else(|| preferred_port.and_then(|_| listen(0)))?;
        let address = listener.local_addr().ok()?;
        let stopped = Arc::new(AtomicBool::new(false));
        let (events, pending) = mpsc::channel();

        let (shared, stop) = (self.shared.clone(), stopped.clone());
        let accepting = thread::spawn(move || {
            for stream in listener.incoming() {
                if stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(stream) = stream else { continue };
                let shared = shared.clone();
                thread::spawn(move || shared.serve(stream));
            }
        });
        let shared = self.shared.clone();
        thread::spawn(move || shared.write_events(pending));

        *running = Some(Running { address, stopped, accepting, events });
        Some(format!("http://127.0.0.1:{}{}", address.port(), Self::PATH))
    }

    /// Stops listening and closes every connection. The port is free when this returns.
    pub fn stop(&self) {
        let Some(running) = self.running.lock().unwrap().take() else { return };
        running.stopped.store(true, Ordering::SeqCst);
        // The accept thread sleeps in `accept`: a connection wakes it to see it stopped.
        if TcpStream::connect(running.address).is_ok() {
            let _ = running.accepting.join();
        }
        for (stream, _) in self.shared.connections.lock().unwrap().values() {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }

    /// Tells every agent with a stream open to list the tools again.
    pub fn notify_tools_changed(&self) {
        if let Some(running) = &*self.running.lock().unwrap() {
            let _ = running.events.send(());
        }
    }

    /// The token `element` authenticates with; the same one every time until revoked.
    pub fn token(&self, element: Uuid) -> String {
        let mut all = self.shared.tokens.lock().unwrap();
        if let Some(token) = all.tokens.get(&element) {
            return token.clone();
        }
        let token = match &self.shared.secret {
            Some(secret) => {
                let mut code = Hmac::<Sha256>::new_from_slice(secret).expect("HMAC takes a key of any length");
                code.update(element.to_string().as_bytes());
                code.finalize().into_bytes().iter().map(|byte| format!("{byte:02x}")).collect()
            }
            None => format!("{}{}", Uuid::new(), Uuid::new()),
        };
        all.tokens.insert(element, token.clone());
        all.callers.insert(token.clone(), element);
        token
    }

    pub fn revoke(&self, element: Uuid) {
        let mut all = self.shared.tokens.lock().unwrap();
        if let Some(token) = all.tokens.remove(&element) {
            all.callers.remove(&token);
        }
    }
}

impl Drop for ToolServer {
    fn drop(&mut self) {
        self.stop();
    }
}

/// One whole HTTP request, taken off a connection's buffer.
#[derive(Debug, PartialEq)]
enum Parsed {
    /// More bytes are needed.
    Incomplete,
    /// Not a request this server takes: answered with this status, and the connection closed.
    Refused(u16, &'static str),
    Request { method: String, path: String, headers: HashMap<String, String>, body: Vec<u8> },
}

fn parse(buffer: &mut Vec<u8>) -> Parsed {
    let Some(header_end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") else {
        return if buffer.len() > ToolServer::MAXIMUM_HEADER { Parsed::Refused(431, "Request Header Fields Too Large") } else { Parsed::Incomplete };
    };
    let head = String::from_utf8_lossy(&buffer[..header_end]).into_owned();
    let mut lines = head.split("\r\n");
    let request_line: Vec<&str> = lines.next().unwrap_or("").split(' ').filter(|part| !part.is_empty()).collect();
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_lowercase(), value.trim().to_string());
        }
    }
    let length = headers.get("content-length").map_or(Some(0), |length| length.parse::<usize>().ok());
    let (Some(length), true) = (length.filter(|length| *length <= ToolServer::MAXIMUM_BODY), request_line.len() >= 2) else {
        return Parsed::Refused(400, "Bad Request");
    };
    let body_start = header_end + 4;
    if buffer.len() - body_start < length {
        return Parsed::Incomplete;
    }
    let body = buffer[body_start..body_start + length].to_vec();
    let method = request_line[0].to_string();
    let path = request_line[1].split('?').find(|part| !part.is_empty()).unwrap_or("").to_string();
    buffer.drain(..body_start + length);
    Parsed::Request { method, path, headers, body }
}

fn reply(stream: &mut TcpStream, status: u16, reason: &str, headers: &[(&str, &str)], body: &[u8], close: bool) -> io::Result<()> {
    let mut head = format!("HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\n", body.len());
    head += if close { "Connection: close\r\n" } else { "Connection: keep-alive\r\n" };
    for (name, value) in headers {
        head += &format!("{name}: {value}\r\n");
    }
    let mut bytes = (head + "\r\n").into_bytes();
    bytes.extend_from_slice(body);
    stream.write_all(&bytes)
}

const JSON: [(&str, &str); 1] = [("Content-Type", "application/json")];

impl Shared {
    fn caller(&self, authorization: Option<&String>) -> Option<Uuid> {
        let authorization = authorization?;
        // Matched on the bytes, so an odd header can't split a character.
        if !authorization.as_bytes().get(..7)?.eq_ignore_ascii_case(b"bearer ") {
            return None;
        }
        let token = authorization.get(7..)?.trim_matches(crate::is_inline_space);
        self.tokens.lock().unwrap().callers.get(token).copied()
    }

    /// One TCP connection: HTTP/1.1 requests read one at a time, kept alive between them.
    fn serve(&self, mut stream: TcpStream) {
        let id = self.next_connection.fetch_add(1, Ordering::Relaxed);
        if let Ok(copy) = stream.try_clone() {
            self.connections.lock().unwrap().insert(id, (copy, false));
        }
        let _ = self.exchange(&mut stream, id);
        self.connections.lock().unwrap().remove(&id);
        let _ = stream.shutdown(Shutdown::Both);
    }

    /// Answers the connection's requests until it closes; an error is the agent gone.
    fn exchange(&self, stream: &mut TcpStream, id: u64) -> io::Result<()> {
        let mut buffer = Vec::new();
        let mut chunk = vec![0; 65536];
        let mut peer_closed = false;
        loop {
            let (method, path, headers, body) = match parse(&mut buffer) {
                Parsed::Incomplete if peer_closed => return Ok(()),
                Parsed::Incomplete => {
                    match stream.read(&mut chunk) {
                        Ok(count) if count > 0 => buffer.extend_from_slice(&chunk[..count]),
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                        _ => peer_closed = true,
                    }
                    continue;
                }
                Parsed::Refused(status, reason) => return reply(stream, status, reason, &[], b"", true),
                Parsed::Request { method, path, headers, body } => (method, path, headers, body),
            };
            let close = headers.get("connection").is_some_and(|value| value.eq_ignore_ascii_case("close")) || peer_closed;
            let kind = match path.as_str() {
                ToolServer::PATH => Some(RequestKind::Rpc),
                ToolServer::CONTEXT_PATH => Some(RequestKind::Context),
                ToolServer::QUESTION_PATH => Some(RequestKind::Question),
                ToolServer::ATTENTION_PATH => Some(RequestKind::Attention),
                _ => None,
            };
            let caller = self.caller(headers.get("authorization"));
            match (kind, caller) {
                (None, _) => reply(stream, 404, "Not Found", &[], b"", close)?,
                (_, None) => reply(stream, 401, "Unauthorized", &[], b"", close)?,
                (Some(_), Some(caller)) if method == "GET" && headers.get("accept").is_some_and(|accept| accept.contains("text/event-stream")) => {
                    return self.stream(stream, id, caller);
                }
                (Some(_), Some(_)) if method != "POST" => reply(stream, 405, "Method Not Allowed", &[("Allow", "GET, POST")], b"", close)?,
                (Some(kind), Some(caller)) => {
                    if let (RequestKind::Rpc, Some(log)) = (kind, &self.on_request) {
                        let message: Option<serde_json::Value> = serde_json::from_slice(&body).ok();
                        let name = message.as_ref().and_then(|message| message.get("method")?.as_str()).unwrap_or("?");
                        log(format!("{caller} {name}"));
                    }
                    let (request, answer) = Request::new(caller, kind, body);
                    (self.handler)(request);
                    // An attention hook is heard, not waited for.
                    let answer = if kind == RequestKind::Attention { Ok(None) } else { answer.recv() };
                    match (kind, answer) {
                        (_, Ok(Some(answer))) => reply(stream, 200, "OK", &JSON, &answer, close)?,
                        (RequestKind::Rpc, Ok(None)) => reply(stream, 202, "Accepted", &[], b"", close)?,
                        // The owner dropped the call unanswered.
                        (RequestKind::Rpc, Err(_)) => return reply(stream, 500, "Internal Server Error", &[], b"", true),
                        _ => reply(stream, 200, "OK", &JSON, b"{}", close)?,
                    }
                }
            }
            if close {
                return Ok(());
            }
        }
    }

    /// Answers with an event stream that stays open: the head now, events as they come. Nothing
    /// more is expected from the agent on it; it ends when the agent goes.
    fn stream(&self, stream: &mut TcpStream, id: u64, caller: Uuid) -> io::Result<()> {
        if let Some(log) = &self.on_request {
            log(format!("{caller} opened a stream"));
        }
        stream.set_write_timeout(Some(ToolServer::STREAM_WRITE_TIMEOUT))?;
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n")?;
        // Only now may events be written to it: never before the head.
        if let Some(connection) = self.connections.lock().unwrap().get_mut(&id) {
            connection.1 = true;
        }
        let mut chunk = [0; 4096];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => return Ok(()),
                Err(error) if error.kind() != io::ErrorKind::Interrupted => return Err(error),
                _ => {}
            }
        }
    }

    /// Writes to every stream what `pending` asks for, and a comment every keep-alive interval,
    /// until the server stops. On a thread of its own, so a stream that stalls holds up no caller.
    fn write_events(&self, pending: mpsc::Receiver<()>) {
        let mut next_keep_alive = Instant::now() + self.keep_alive_interval;
        loop {
            let event: &[u8] = match pending.recv_timeout(next_keep_alive.saturating_duration_since(Instant::now())) {
                Ok(()) => b"data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n",
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    next_keep_alive += self.keep_alive_interval;
                    b": keep-alive\n\n"
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            };
            let streams: Vec<TcpStream> =
                self.connections.lock().unwrap().values().filter(|(_, is_stream)| *is_stream).filter_map(|(stream, _)| stream.try_clone().ok()).collect();
            for mut stream in streams {
                if stream.write_all(event).is_err() {
                    // Its connection's thread sees the end and forgets it.
                    let _ = stream.shutdown(Shutdown::Both);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_requests_one_at_a_time() {
        let mut buffer = b"POST /mcp?x=1 HTTP/1.1\r\nContent-Length: 2\r\nAUTHORIZATION:  Bearer t \r\n\r\n{}GET /mcp HT".to_vec();
        let Parsed::Request { method, path, headers, body } = parse(&mut buffer) else { panic!("no request") };
        assert_eq!((method.as_str(), path.as_str(), body.as_slice()), ("POST", "/mcp", b"{}".as_slice()));
        assert_eq!(headers["authorization"], "Bearer t");
        assert_eq!(parse(&mut buffer), Parsed::Incomplete);
        assert_eq!(buffer, b"GET /mcp HT");

        assert_eq!(parse(&mut b"POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".to_vec()), Parsed::Incomplete);
        assert_eq!(parse(&mut b"POST /mcp HTTP/1.1\r\nContent-Length: x\r\n\r\n".to_vec()), Parsed::Refused(400, "Bad Request"));
        assert_eq!(parse(&mut b"POST /mcp HTTP/1.1\r\nContent-Length: 4194305\r\n\r\n".to_vec()), Parsed::Refused(400, "Bad Request"));
        assert_eq!(parse(&mut b"POST\r\n\r\n".to_vec()), Parsed::Refused(400, "Bad Request"));
        assert_eq!(parse(&mut vec![b'a'; ToolServer::MAXIMUM_HEADER + 1]), Parsed::Refused(431, "Request Header Fields Too Large"));
    }

    /// An idle stream is sent a comment, so clients don't time it out.
    #[test]
    fn idle_streams_are_kept_alive() {
        let server = ToolServer::with(Arc::new(|_| {}), None, None, Duration::from_millis(50));
        let url = server.start(None).unwrap();
        let token = server.token(Uuid::new());
        let mut stream = TcpStream::connect(url.trim_start_matches("http://").trim_end_matches("/mcp")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        write!(stream, "GET /mcp HTTP/1.1\r\nAuthorization: Bearer {token}\r\nAccept: text/event-stream\r\n\r\n").unwrap();
        let mut received = Vec::new();
        let mut chunk = [0; 256];
        while !String::from_utf8_lossy(&received).contains("\r\n\r\n: keep-alive\n\n: keep-alive\n\n") {
            let count = stream.read(&mut chunk).unwrap();
            assert!(count > 0, "the stream closed");
            received.extend_from_slice(&chunk[..count]);
        }
    }
}
