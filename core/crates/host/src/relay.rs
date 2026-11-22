//! The host's standing line to the account server, and the channels boards open through it
//! or straight to this host (docs/hosts.md): each one a sealed byte stream bridged to the
//! core's socket or to a port on this machine's loopback.

use std::sync::atomic::{AtomicBool, Ordering};
use std::fs::File;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::SigningKey;
use tungstenite::Message;
use zeroize::Zeroizing;

use crate::account::Api;
use crate::boards::{self, Verdict};
use crate::channel::{self, Accepted, Carrying, Sealed, CHUNK, TAG};
use crate::config::{self, Config};
use crate::direct::{self, Door, Tickets};
use crate::wire::{connect, ready, wait, Refused, Wire, PATIENCE};

pub struct Timing {
    /// The server reads a host silent for 150 seconds as offline.
    pub alive: Duration,
    pub ping: Duration,
    pub backoff: Duration,
    pub backoff_cap: Duration,
    /// A line that stayed up this long starts over from the first backoff when it drops.
    pub stable: Duration,
}

impl Default for Timing {
    fn default() -> Timing {
        Timing { alive: Duration::from_secs(60), ping: Duration::from_secs(25), backoff: Duration::from_secs(1), backoff_cap: Duration::from_secs(60), stable: Duration::from_secs(30) }
    }
}

/// Why the line stopped, until the account on disk changes (or because it did).
#[derive(Debug, PartialEq, Eq)]
pub enum Stop {
    SignedOut,
    Forgotten,
    Changed,
}

enum Ended {
    Stop(Stop),
    Retry(String),
}

fn log(message: &str) {
    eprintln!("relay[{}] {message}", std::process::id());
}

struct Line<'a> {
    server: &'a str,
    config: &'a Config,
    token: &'a str,
    core: &'a Path,
    /// The folder of the list of boards this host trusts.
    boards: &'a Path,
    timing: &'a Timing,
    /// Told whether the line is up.
    up: &'a (dyn Fn(bool) + Sync),
    /// Where boards may reach this host directly, asked again with every `alive`.
    addresses: &'a (dyn Fn() -> Vec<String> + Sync),
    /// Where the tickets the server announces go.
    tickets: &'a Tickets,
    /// Whether the account on disk is no longer `config`: a new login.
    changed: &'a (dyn Fn() -> bool + Sync),
}

/// Keeps the line open, reconnecting when it drops, until the server says this host is
/// signed out or forgotten, or the account changed.
fn run(line: &Line) -> Stop {
    let mut backoff = line.timing.backoff;
    loop {
        let started = Instant::now();
        let ended = listen(line);
        (line.up)(false);
        match ended {
            Ended::Stop(stop) => return stop,
            Ended::Retry(why) => log(&format!("the line to the account server is down ({why}); trying again")),
        }
        if started.elapsed() >= line.timing.stable {
            backoff = line.timing.backoff;
        }
        // Between half and all of it, so hosts cut off together don't come back together.
        let mut random = [0u8; 1];
        let _ = getrandom::getrandom(&mut random);
        std::thread::sleep(backoff / 2 + (backoff / 2).mul_f64(random[0] as f64 / 255.0));
        backoff = (backoff * 2).min(line.timing.backoff_cap);
    }
}

fn status(status: u16) -> Option<Ended> {
    match status {
        401 => Some(Ended::Stop(Stop::SignedOut)),
        404 => Some(Ended::Stop(Stop::Forgotten)),
        _ => None,
    }
}

/// Connections kept open on the relay ahead of any board: a board that connects is through
/// at once, where opening one for it (address lookup, TLS, the server's checks) takes this
/// host half a second.
const SPARES: usize = 2;
/// A spare is replaced at this age (the relay stops handing one out a little before).
const SPARE_LIFE: Duration = Duration::from_secs(120);

struct Spares(Arc<AtomicBool>);

impl Drop for Spares {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// Keeps one spare open while `wanted`, serving the board that takes it on a thread of its own.
fn spare(server: &str, token: &str, host: &str, identity: &SigningKey, core: &Path, boards: &Path, wanted: &AtomicBool) {
    while wanted.load(Ordering::SeqCst) {
        let opened = connect(server, &format!("/v1/hosts/{host}/spare/{}", uuid::Uuid::new_v4()), token).and_then(|link| link.into_wire(Instant::now() + SPARE_LIFE).map_err(|error| Refused::Other(error.to_string())));
        let Ok(mut wire) = opened else {
            // A server without spares, or no network: boards still get in the slower way.
            std::thread::sleep(Duration::from_secs(30));
            continue;
        };
        let Some(first) = wire.incoming.next() else { continue };
        wire.incoming.patience(Some(Instant::now() + PATIENCE));
        wire.incoming = Box::new(Primed { first: Some(first), rest: wire.incoming });
        let (identity, core, boards) = (identity.clone(), core.to_path_buf(), boards.to_path_buf());
        std::thread::spawn(move || {
            if let Err(error) = serve(wire, &identity, None, &core, &boards) {
                log(&format!("channel closed: {error}"));
            }
        });
    }
}

/// A wire whose first message was already read.
struct Primed {
    first: Option<Vec<u8>>,
    rest: Box<dyn crate::wire::Incoming>,
}

impl crate::wire::Incoming for Primed {
    fn next(&mut self) -> Option<Vec<u8>> {
        self.first.take().or_else(|| self.rest.next())
    }

    fn patience(&mut self, deadline: Option<Instant>) {
        self.rest.patience(deadline);
    }
}

/// One life of the line: registers, listens, and hands each board that connects to a thread.
fn listen(line: &Line) -> Ended {
    // On every start, so the account shows this build's version and the current name.
    let api = Api::new(line.server);
    let mut addresses = (line.addresses)();
    if let Err(failed) = api.register(line.config, line.token, &addresses) {
        return status(failed.status).unwrap_or(Ended::Retry(failed.to_string()));
    }
    let identity = match line.config.identity() {
        Ok(identity) => identity,
        Err(error) => return Ended::Retry(error),
    };
    let mut link = match connect(line.server, &format!("/v1/hosts/{}/listen", line.config.id), line.token) {
        Ok(link) => link,
        Err(Refused::Status(code)) => return status(code).unwrap_or(Ended::Retry(format!("the server said {code}"))),
        Err(Refused::Other(error)) => return Ended::Retry(error),
    };
    (line.up)(true);
    // Until this life of the line ends.
    let spares = Spares(Arc::new(AtomicBool::new(true)));
    for _ in 0..SPARES {
        let (server, token, host) = (line.server.to_string(), Zeroizing::new(line.token.to_string()), line.config.id.clone());
        let (identity, core, boards, wanted) = (identity.clone(), line.core.to_path_buf(), line.boards.to_path_buf(), spares.0.clone());
        std::thread::spawn(move || spare(&server, &token, &host, &identity, &core, &boards, &wanted));
    }

    let start = Instant::now();
    let (mut ping_at, mut alive_at, mut unanswered) = (start + line.timing.ping, start + line.timing.alive, 0);
    loop {
        loop {
            match ready(&mut link.ws) {
                Ok(None) => break,
                Ok(Some(Message::Text(text))) if text == "pong" => unanswered = 0,
                Ok(Some(Message::Text(text))) => {
                    let notice: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
                    // Checked to be an id: it goes into the address the channel opens.
                    if let Some(channel) = notice["connect"].as_str().and_then(|id| uuid::Uuid::parse_str(id).ok()) {
                        let (server, token, host) = (line.server.to_string(), Zeroizing::new(line.token.to_string()), line.config.id.clone());
                        let (identity, core, boards) = (identity.clone(), line.core.to_path_buf(), line.boards.to_path_buf());
                        std::thread::spawn(move || {
                            let served = connect(&server, &format!("/v1/hosts/{host}/accept/{channel}"), &token)
                                .map_err(|refused| format!("could not accept ({refused:?})"))
                                .and_then(|link| link.into_wire(Instant::now() + PATIENCE).map_err(|error| error.to_string()))
                                .and_then(|wire| serve(wire, &identity, None, &core, &boards));
                            if let Err(error) = served {
                                log(&format!("channel closed: {error}"));
                            }
                        });
                    }
                    let mut ticket = Zeroizing::new([0u8; 32]);
                    if notice["ticket"].as_str().is_some_and(|text| text.len() == 44 && STANDARD.decode_slice(text, &mut *ticket) == Ok(32)) {
                        line.tickets.add(*ticket);
                    }
                }
                Ok(Some(Message::Close(frame))) => {
                    let code = frame.map_or(1005, |frame| u16::from(frame.code));
                    return if code == 4404 { Ended::Stop(Stop::Forgotten) } else { Ended::Retry(format!("the server closed it, {code}")) };
                }
                Ok(Some(_)) => {}
                Err(error) => return Ended::Retry(error.to_string()),
            }
        }
        let now = Instant::now();
        let mut say = |text: &str| link.ws.send(Message::Text(text.into()));
        if now >= ping_at {
            if unanswered >= 2 {
                return Ended::Retry("the server stopped answering".into());
            }
            unanswered += 1;
            ping_at = now + line.timing.ping;
            if let Err(error) = say("ping") {
                return Ended::Retry(error.to_string());
            }
        }
        if now >= alive_at {
            alive_at = now + line.timing.alive;
            if let Err(error) = say("alive") {
                return Ended::Retry(error.to_string());
            }
            if (line.changed)() {
                return Ended::Stop(Stop::Changed);
            }
            // The machine changed networks: boards must hear where it is now.
            let current = (line.addresses)();
            if current != addresses {
                match api.register(line.config, line.token, &current) {
                    Ok(()) => addresses = current,
                    // Anything else is tried again with the next `alive`.
                    Err(failed) => {
                        if let Some(ended) = status(failed.status) {
                            return ended;
                        }
                    }
                }
            }
        }
        wait(&link.tcp, Some(ping_at.min(alive_at).saturating_duration_since(now)));
    }
}

/// One board's channel, from the handshake to either side leaving. With `tickets`, the board
/// came straight to this host and must show one before anything else is done for it. Nothing
/// is carried for a board that isn't on the list in `boards` ("Board identity").
pub fn serve(mut wire: Wire, identity: &SigningKey, tickets: Option<(&Tickets, &dyn Fn())>, core: &Path, boards: &Path) -> Result<(), String> {
    let next = |wire: &mut Wire| wire.incoming.next().ok_or("the board left before the channel was set up");
    let Accepted { answer, ephemerals, mut from_board, mut to_board } = channel::accept(identity, &next(&mut wire)?)?;
    if !wire.outgoing.send(answer.to_vec()) {
        return Err("the board left before the channel was set up".into());
    }
    if let Some((tickets, _)) = tickets {
        let mut ticket = Zeroizing::new(next(&mut wire)?);
        from_board.open(&mut ticket)?;
        if !tickets.take(&ticket) {
            return Err("not a ticket this host was told of".into());
        }
    }
    let mut proof = next(&mut wire)?;
    from_board.open(&mut proof)?;
    // No verdict, no record and no log for what proves nothing: anybody the server lets
    // through can send it, as often as they like.
    let Some((board, name)) = channel::proven(&proof, &ephemerals, &identity.verifying_key()) else { return Ok(()) };
    let verdict = boards::admit(boards, &board, name, boards::now())?;
    // The host's first sealed message.
    let mut text = match verdict {
        Verdict::Trusted => "trusted".to_string(),
        Verdict::Pending(trusted) => format!("pending {trusted}"),
    }
    .into_bytes();
    to_board.seal(&mut text)?;
    if !wire.outgoing.send(text) || verdict != Verdict::Trusted {
        // A board says what it wants without waiting for the verdict: read that before closing,
        // or closing with it unread could reset the connection under the verdict.
        wire.incoming.patience(Some(Instant::now() + Duration::from_secs(2)));
        let _ = wire.incoming.next();
        wire.outgoing.finish();
        return Ok(());
    }
    if let Some((_, admitted)) = tickets {
        admitted();
    }
    let mut kind = next(&mut wire)?;
    from_board.open(&mut kind)?;
    let carrying = Carrying::parse(&kind).ok_or("the board asked for something this host doesn't carry")?;
    let caller = STANDARD.encode(board);
    if carrying == Carrying::Boards {
        wire.incoming.patience(None);
        return manage(wire, from_board, to_board, &|request| boards::answer(boards, &caller, request, boards::now()));
    }
    if carrying == Carrying::Vault {
        wire.incoming.patience(None);
        // Asked again each time: a board forgotten meanwhile gets no key.
        let trusted = || boards::load(boards).is_ok_and(|list| list.trusted.iter().any(|board| board.key == caller));
        return manage(wire, from_board, to_board, &|request| trusted().then(|| crate::vault::answer(boards, request)));
    }
    let target = match carrying {
        Carrying::Boards | Carrying::Vault => unreachable!("handled above"),
        Carrying::Core => UnixStream::connect(core).map(OwnedFd::from).map_err(|error| format!("no core to connect to: {error}"))?,
        // Loopback only: a board reaches what runs on this host, never what this host can reach.
        Carrying::Tcp(port) => {
            // Either loopback: a dev server may listen on `::1` alone.
            let stream = TcpStream::connect_timeout(&SocketAddr::from((Ipv4Addr::LOCALHOST, port)), PATIENCE)
                .or_else(|_| TcpStream::connect_timeout(&SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, port)), PATIENCE))
                .map_err(|error| format!("port {port}: {error}"))?;
            let _ = stream.set_nodelay(true);
            OwnedFd::from(stream)
        }
    };
    wire.incoming.patience(None);
    bridge(wire, File::from(target), from_board, to_board);
    Ok(())
}

/// A channel carrying `boards` or `vault`: one JSON line per request and per reply, answered
/// here by `answer` (None ends the channel). The core never learns who a board is.
fn manage(mut wire: Wire, mut from_board: Sealed, mut to_board: Sealed, answer: &dyn Fn(&[u8]) -> Option<String>) -> Result<(), String> {
    let mut unread = Vec::new();
    while let Some(mut message) = wire.incoming.next() {
        from_board.open(&mut message)?;
        unread.extend(message);
        while let Some(end) = unread.iter().position(|byte| *byte == b'\n') {
            let request: Vec<u8> = unread.drain(..=end).collect();
            // None: the board was forgotten since, by itself or at the host's terminal.
            let Some(reply) = answer(&request[..end]) else {
                wire.outgoing.finish();
                return Ok(());
            };
            for chunk in reply.as_bytes().chunks(CHUNK) {
                let mut message = chunk.to_vec();
                to_board.seal(&mut message)?;
                if !wire.outgoing.send(message) {
                    return Ok(());
                }
            }
        }
        if unread.len() > CHUNK {
            return Err("a request with no end".into());
        }
    }
    Ok(())
}

/// Pipes `target` to the board and back until either side ends, which ends the other: the
/// core learns the board left by its connection closing.
fn bridge(wire: Wire, target: File, mut from_board: Sealed, mut to_board: Sealed) {
    let Wire { mut incoming, mut outgoing, tcp } = wire;
    let (tcp, target) = (&tcp, &target);
    std::thread::scope(|scope| {
        scope.spawn(move || {
            let mut chunk = vec![0u8; CHUNK];
            loop {
                let count = match (&*target).read(&mut chunk) {
                    Ok(0) => break,
                    Ok(count) => count,
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                // The transport takes its message whole, so each one is allocated: once.
                let mut message = Vec::with_capacity(count + TAG);
                message.extend_from_slice(&chunk[..count]);
                if to_board.seal(&mut message).is_err() || !outgoing.send(message) {
                    break;
                }
            }
            outgoing.finish();
            // Wakes the other direction, waiting on this stream.
            let _ = tcp.shutdown(Shutdown::Both);
        });
        while let Some(mut message) = incoming.next() {
            if from_board.open(&mut message).is_err() || (&*target).write_all(&message).is_err() {
                break;
            }
        }
        // Ends the other direction's read, and its write if it is in one.
        // SAFETY: shutdown only takes a descriptor, open for as long as `target` lives.
        unsafe { libc::shutdown(target.as_raw_fd(), libc::SHUT_RDWR) };
        let _ = tcp.shutdown(Shutdown::Both);
    });
}

pub fn status_file(folder: &Path) -> PathBuf {
    folder.join("relay.status")
}

/// Runs inside the daemon, forever: keeps this host online for its account and serves the
/// boards that connect, through the relay or straight to this host, bridging each to the core
/// on `core_socket`.
pub fn serve_relay(core_socket: &Path) -> ! {
    let folder = config::data_folder();
    let up = |up: bool| {
        // `agentboard status` reads this; the process id tells a stale file from a live daemon.
        let _ = std::fs::write(status_file(&folder), format!("{} {}\n", if up { "up" } else { "down" }, std::process::id()));
    };
    let written = || std::fs::metadata(folder.join("host.json")).and_then(|file| file.modified()).ok();
    let tickets = Arc::new(Tickets::new(Duration::from_secs(30)));
    // The port boards connect to directly, once this host has an identity to answer them with.
    let mut port = None;
    loop {
        up(false);
        let before = written();
        match Config::load(&folder) {
            Ok(config) => {
                if port.is_none() {
                    port = config.identity().ok().and_then(|identity| open_door(identity, core_socket, &folder, tickets.clone()));
                }
                match config.token.clone().map(Zeroizing::new) {
                    Some(token) => {
                        // A file made by this very load is not a change.
                        let before = before.or_else(written);
                        let addresses = || port.map(direct::addresses).unwrap_or_default();
                        let line = Line { server: &config::server(), config: &config, token: &token, core: core_socket, boards: &folder, timing: &Timing::default(), up: &up, addresses: &addresses, tickets: &tickets, changed: &|| written() != before };
                        match run(&line) {
                            Stop::SignedOut => log("the account server no longer takes this host's token: run `agentboard login`"),
                            Stop::Forgotten => log("this host was removed from the account: run `agentboard login` to add it again"),
                            Stop::Changed => continue,
                        }
                    }
                    None => log("not signed in: run `agentboard login`"),
                }
            }
            Err(error) => log(&error),
        }
        // Nothing to try again until a login rewrites the account.
        while written() == before {
            std::thread::sleep(Duration::from_secs(5));
        }
    }
}

/// Starts serving boards that connect directly; the port, or None when none could be had (the
/// relay still works).
fn open_door(identity: SigningKey, core: &Path, boards: &Path, tickets: Arc<Tickets>) -> Option<u16> {
    let (listeners, port) = direct::listeners().map_err(|error| log(&format!("no port for direct connections: {error}"))).ok()?;
    let door = Arc::new(Door { identity, core: core.to_path_buf(), boards: boards.to_path_buf(), tickets, patience: Duration::from_secs(5) });
    for listener in listeners {
        let door = door.clone();
        std::thread::spawn(move || direct::serve(listener, door));
    }
    Some(port)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channel::tests::Board;
    use crate::test_support::{echo, echo_core, echo_port, median, read_request, temporary};
    use std::io;
    use std::net::TcpListener;
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Mutex;
    use tungstenite::WebSocket;
    use std::sync::mpsc::{channel, Receiver, Sender};
    use tungstenite::handshake::server::{ErrorResponse, Request, Response};
    use tungstenite::protocol::frame::coding::CloseCode;
    use tungstenite::protocol::CloseFrame;

    const TOKEN: &str = "good-token";
    const SOON: Duration = Duration::from_secs(5);

    enum Command {
        Say(String),
        Close(u16),
        Drop,
    }

    /// The server's end of a `listen` socket, served by a thread of the stub.
    struct Listen {
        path: String,
        commands: Sender<Command>,
        alive: Arc<AtomicUsize>,
        pings: Arc<AtomicUsize>,
        answers: Arc<AtomicBool>,
    }

    /// The account server as a host sees it: `PUT /v1/hosts/:id`, `listen` and `accept`.
    struct Stub {
        url: String,
        listens: Receiver<Listen>,
        accepts: Receiver<(String, WebSocket<TcpStream>)>,
        registrations: Arc<AtomicUsize>,
        /// The `addresses` of each registration.
        registered: Arc<Mutex<Vec<serde_json::Value>>>,
    }

    fn stub() -> Stub {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (listens, listened) = channel();
        let (accepts, accepted) = channel();
        let registrations = Arc::new(AtomicUsize::new(0));
        let counted = registrations.clone();
        let registered = Arc::new(Mutex::new(Vec::new()));
        let bodies = registered.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let (mut stream, listens, accepts, counted, bodies) = (stream.unwrap(), listens.clone(), accepts.clone(), counted.clone(), bodies.clone());
                std::thread::spawn(move || {
                    let mut start = [0u8; 4];
                    stream.peek(&mut start).unwrap();
                    if &start == b"PUT " {
                        let request = read_request(&mut stream);
                        let known = request.contains(&format!("authorization: bearer {TOKEN}\r\n")) || request.contains(&format!("Authorization: Bearer {TOKEN}\r\n"));
                        let reply = if known { "200 OK\r\nContent-Length: 2\r\n\r\n{}" } else { "401 Unauthorized\r\nContent-Length: 24\r\n\r\n{\"error\":\"unauthorized\"}" };
                        let body: serde_json::Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
                        bodies.lock().unwrap().push(body["addresses"].clone());
                        counted.fetch_add(1, Ordering::SeqCst);
                        stream.write_all(format!("HTTP/1.1 {reply}").as_bytes()).unwrap();
                        return;
                    }
                    stream.set_nodelay(true).unwrap();
                    let mut path = String::new();
                    let check = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
                        path = request.uri().path().to_string();
                        let known = request.headers().get("Authorization").is_some_and(|value| value.to_str().unwrap() == format!("Bearer {TOKEN}"));
                        // No spares here, as on an older server: boards come in by the notice.
                        if path.contains("/spare/") {
                            return Err(Response::builder().status(404).body(None).unwrap());
                        }
                        if known { Ok(response) } else { Err(Response::builder().status(401).body(None).unwrap()) }
                    };
                    let Ok(mut ws) = tungstenite::accept_hdr(stream, check) else { return };
                    if !path.ends_with("/listen") {
                        ws.get_ref().set_read_timeout(Some(SOON)).unwrap();
                        accepts.send((path, ws)).unwrap();
                        return;
                    }
                    let (commands, commanded) = channel();
                    let (alive, pings, answers) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)), Arc::new(AtomicBool::new(true)));
                    listens.send(Listen { path, commands, alive: alive.clone(), pings: pings.clone(), answers: answers.clone() }).unwrap();
                    ws.get_ref().set_read_timeout(Some(Duration::from_millis(5))).unwrap();
                    loop {
                        match ws.read() {
                            Ok(Message::Text(text)) if text == "ping" => {
                                pings.fetch_add(1, Ordering::SeqCst);
                                if answers.load(Ordering::SeqCst) {
                                    ws.send(Message::Text("pong".into())).unwrap();
                                }
                            }
                            Ok(Message::Text(text)) if text == "alive" => drop(alive.fetch_add(1, Ordering::SeqCst)),
                            Ok(other) => panic!("unexpected on listen: {other:?}"),
                            Err(tungstenite::Error::Io(error)) if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
                            Err(_) => return,
                        }
                        for command in commanded.try_iter() {
                            match command {
                                Command::Say(text) => ws.send(Message::Text(text)).unwrap(),
                                Command::Close(code) => {
                                    let _ = ws.close(Some(CloseFrame { code: CloseCode::from(code), reason: "".into() }));
                                    let _ = ws.flush();
                                }
                                Command::Drop => return,
                            }
                        }
                    }
                });
            }
        });
        Stub { url, listens: listened, accepts: accepted, registrations, registered }
    }

    /// A host running against the stub, with an echoing core and an echoing loopback port.
    struct Host {
        stub: Stub,
        id: String,
        identity: SigningKey,
        /// Where the host keeps its list of boards.
        folder: PathBuf,
        /// A board the host trusts.
        board: SigningKey,
        port: u16,
        /// One message each time the core's side of a channel closes.
        core_closed: Receiver<()>,
        up: Arc<Mutex<Vec<bool>>>,
        stopped: Receiver<Stop>,
        tickets: Arc<Tickets>,
        addresses: Arc<Mutex<Vec<String>>>,
        changed: Arc<AtomicBool>,
    }

    fn host(token: &'static str) -> Host {
        let stub = stub();
        let folder = temporary("relay");
        let config = Config::load(&folder).unwrap();
        let (id, identity) = (config.id.clone(), config.identity().unwrap());

        let board = SigningKey::from_bytes(&[5; 32]);
        boards::open_window(&folder, u64::MAX).unwrap();
        assert_eq!(boards::admit(&folder, board.verifying_key().as_bytes(), b"Test Mac", boards::now()), Ok(Verdict::Trusted));
        let (core, core_closed, _) = echo_core(&folder);
        let port = echo_port();
        let tickets = Arc::new(Tickets::new(Duration::from_secs(30)));
        let addresses = Arc::new(Mutex::new(vec!["192.0.2.7:47470".to_string()]));
        let changed = Arc::new(AtomicBool::new(false));

        let up = Arc::new(Mutex::new(Vec::new()));
        let (stop, stopped) = channel();
        let (server, seen, held, places, renewed, list) = (stub.url.clone(), up.clone(), tickets.clone(), addresses.clone(), changed.clone(), folder.clone());
        std::thread::spawn(move || {
            let timing = Timing { alive: Duration::from_millis(100), ping: Duration::from_millis(40), backoff: Duration::from_millis(10), backoff_cap: Duration::from_millis(40), stable: Duration::ZERO };
            let line = Line { server: &server, config: &config, token, core: &core, boards: &list, timing: &timing, up: &move |up| seen.lock().unwrap().push(up), addresses: &move || places.lock().unwrap().clone(), tickets: &held, changed: &move || renewed.load(Ordering::SeqCst) };
            let _ = stop.send(run(&line));
        });
        Host { stub, id, identity, folder, board, port, core_closed, up, stopped, tickets, addresses, changed }
    }

    impl Host {
        /// What the line said of itself so far; it says "up" a moment after the server sees it.
        fn up_is(&self, expected: &[bool]) {
            let deadline = Instant::now() + SOON;
            while *self.up.lock().unwrap() != expected && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
            assert_eq!(*self.up.lock().unwrap(), expected);
        }

        fn listen(&self) -> Listen {
            let listen = self.stub.listens.recv_timeout(SOON).expect("the host listens");
            assert_eq!(listen.path, format!("/v1/hosts/{}/listen", self.id));
            listen
        }

        /// A board the host trusts connects: the notice, the host's accept, the handshake,
        /// its proof, and what the channel carries.
        fn channel(&self, listen: &Listen, carrying: &str) -> (WebSocket<TcpStream>, Board) {
            let (mut ws, mut board) = self.proved(listen, Board::of(self.board.clone()));
            assert_eq!(board.open(&ws.read().unwrap().into_data()).unwrap(), b"trusted");
            ws.send(Message::Binary(board.seal(carrying.as_bytes()))).unwrap();
            (ws, board)
        }

        /// `board` connects and proves itself: the host's verdict comes next.
        fn proved(&self, listen: &Listen, mut board: Board) -> (WebSocket<TcpStream>, Board) {
            let (mut ws, _) = self.accepted(listen);
            ws.send(Message::Binary(board.key().to_vec())).unwrap();
            let answer = ws.read().unwrap().into_data();
            assert!(board.finish(&answer, &self.identity.verifying_key()));
            ws.send(Message::Binary(board.prove("Test Mac"))).unwrap();
            (ws, board)
        }

        fn accepted(&self, listen: &Listen) -> (WebSocket<TcpStream>, Board) {
            let channel = uuid::Uuid::new_v4().to_string();
            listen.commands.send(Command::Say(format!(r#"{{"connect":"{channel}"}}"#))).unwrap();
            let (path, ws) = self.stub.accepts.recv_timeout(SOON).expect("the host accepts");
            assert_eq!(path, format!("/v1/hosts/{}/accept/{channel}", self.id));
            (ws, Board::of(self.board.clone()))
        }
    }

    fn round_trip(ws: &mut WebSocket<TcpStream>, board: &mut Board, bytes: &[u8]) {
        for chunk in bytes.chunks(CHUNK) {
            ws.send(Message::Binary(board.seal(chunk))).unwrap();
        }
        let mut back = Vec::new();
        while back.len() < bytes.len() {
            let message = ws.read().unwrap().into_data();
            assert!(message.len() <= CHUNK + TAG);
            back.extend(board.open(&message).expect("sealed by the host, in order"));
        }
        assert!(back == bytes);
    }

    fn assert_closed(ws: &mut WebSocket<TcpStream>) {
        assert!(matches!(ws.read(), Err(_) | Ok(Message::Close(_))), "the host closes the channel");
    }

    #[test]
    fn bridges_boards_to_the_core_and_to_loopback_ports() {
        let host = host(TOKEN);
        let listen = host.listen();
        assert_eq!(host.stub.registrations.load(Ordering::SeqCst), 1);
        host.up_is(&[true]);

        let (mut ws, mut board) = host.channel(&listen, "core");
        round_trip(&mut ws, &mut board, b"hello");
        let large: Vec<u8> = (0..300 * 1024).map(|at| (at % 251) as u8).collect();
        round_trip(&mut ws, &mut board, &large);

        // What the channel adds to a keystroke and its echo: against the core's socket alone.
        let direct = {
            let folder = temporary("echo");
            let listener = UnixListener::bind(folder.join("s")).unwrap();
            std::thread::spawn(move || echo(listener.accept().unwrap().0));
            let mut stream = UnixStream::connect(folder.join("s")).unwrap();
            median((0..2000).map(|_| {
                let (start, mut byte) = (Instant::now(), [0u8; 1]);
                stream.write_all(b"k").unwrap();
                stream.read_exact(&mut byte).unwrap();
                start.elapsed()
            }).collect())
        };
        let sealed = median((0..2000).map(|_| {
            let start = Instant::now();
            round_trip(&mut ws, &mut board, b"k");
            start.elapsed()
        }).collect());
        println!("1-byte echo, median of 2000: {sealed:?} through the channel (seal, WebSocket, open, core socket, and back), {direct:?} on the core socket alone: {:?} added", sealed.saturating_sub(direct));
        // Loose: catches a 40 ms Nagle stall or a polling sleep, not a busy machine.
        assert!(sealed < Duration::from_millis(5), "{sealed:?}");

        // The board leaving closes the core's connection.
        drop(ws);
        host.core_closed.recv_timeout(SOON).expect("the core hears the board left");

        let (mut ws, mut board) = host.channel(&listen, &format!("tcp:{}", host.port));
        round_trip(&mut ws, &mut board, b"GET / HTTP/1.1\r\n\r\n");
        round_trip(&mut ws, &mut board, &large);
        // Two channels at once, each with its own keys.
        let (mut second, mut second_board) = host.channel(&listen, "core");
        round_trip(&mut second, &mut second_board, b"second");
        round_trip(&mut ws, &mut board, b"first");
    }

    #[test]
    fn closes_channels_that_break_the_contract() {
        let host = host(TOKEN);
        let listen = host.listen();

        let closed_port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        for refused in ["shell", "tcp:0", "tcp:65536", "tcp:example.com:80", &format!("tcp:{closed_port}")] {
            let (mut ws, _) = host.channel(&listen, refused);
            assert_closed(&mut ws);
        }

        // A board key of low order gets no answer.
        let (mut ws, _) = host.accepted(&listen);
        ws.send(Message::Binary(vec![0; 32])).unwrap();
        assert_closed(&mut ws);

        // A first message sealed with other keys.
        let (mut ws, mut board) = host.accepted(&listen);
        ws.send(Message::Binary(board.key().to_vec())).unwrap();
        assert_eq!(ws.read().unwrap().into_data().len(), 96);
        ws.send(Message::Binary(board.seal(b"core"))).unwrap();
        assert_closed(&mut ws);

        // Later: an altered message, one out of order, text, and one over the size limit.
        let breaks: [fn(&mut WebSocket<TcpStream>, &mut Board); 4] = [
            |ws, board| {
                let mut message = board.seal(b"x");
                message[0] ^= 1;
                ws.send(Message::Binary(message)).unwrap();
            },
            |ws, board| {
                let (_skipped, second) = (board.seal(b"1"), board.seal(b"2"));
                ws.send(Message::Binary(second)).unwrap();
            },
            |ws, _| ws.send(Message::Text("core".into())).unwrap(),
            |ws, board| {
                // Sealed properly, so only its size is wrong.
                let message = board.seal(&vec![0; CHUNK + 1]);
                ws.send(Message::Binary(message)).unwrap();
            },
        ];
        for broken in breaks {
            let (mut ws, mut board) = host.channel(&listen, "core");
            round_trip(&mut ws, &mut board, b"fine so far");
            broken(&mut ws, &mut board);
            assert_closed(&mut ws);
            host.core_closed.recv_timeout(SOON).expect("the core's connection closes too");
        }
        // The line itself is untouched by any of it.
        let (mut ws, mut board) = host.channel(&listen, "core");
        round_trip(&mut ws, &mut board, b"still here");
        assert!(host.stub.listens.try_recv().is_err());
    }

    #[test]
    fn only_boards_the_host_trusts_get_a_channel() {
        let host = host(TOKEN);
        let listen = host.listen();
        let pending = || boards::load(&host.folder).unwrap().pending;

        // A board the host never saw: told it waits, recorded, and nothing more.
        let stranger = SigningKey::from_bytes(&[6; 32]);
        let (mut ws, mut board) = host.proved(&listen, Board::of(stranger.clone()));
        assert_eq!(board.open(&ws.read().unwrap().into_data()).unwrap(), b"pending 1");
        assert_closed(&mut ws);
        assert_eq!(pending().len(), 1);
        assert_eq!(pending()[0].key, STANDARD.encode(stranger.verifying_key().as_bytes()));

        // Asking to be trusted while waiting never gets that far: the same verdict, and out.
        let (mut ws, mut board) = host.proved(&listen, Board::of(stranger.clone()));
        let _ = ws.send(Message::Binary(board.seal(b"boards")));
        let _ = ws.send(Message::Binary(board.seal(format!("{{\"trust\":{{\"key\":\"{}\"}}}}\n", pending()[0].key).as_bytes())));
        assert_eq!(board.open(&ws.read().unwrap().into_data()).unwrap(), b"pending 1");
        assert_closed(&mut ws);
        assert_eq!((pending().len(), boards::load(&host.folder).unwrap().trusted.len()), (1, 1));

        // A proof that proves nothing gets no verdict and leaves no trace: one signed for
        // another host, and one for other ephemeral keys, both with the trusted board's key.
        let breaks: [fn(&mut Board); 2] = [|board| board.transcript[64] ^= 1, |board| board.transcript[0] ^= 1];
        for broken in breaks {
            let (mut ws, mut board) = host.accepted(&listen);
            ws.send(Message::Binary(board.key().to_vec())).unwrap();
            assert!(board.finish(&ws.read().unwrap().into_data(), &host.identity.verifying_key()));
            broken(&mut board);
            ws.send(Message::Binary(board.prove("Test Mac"))).unwrap();
            assert_closed(&mut ws);
        }
        // No proof at all: what the channel carries, where the proof goes.
        let (mut ws, mut board) = host.accepted(&listen);
        ws.send(Message::Binary(board.key().to_vec())).unwrap();
        assert!(board.finish(&ws.read().unwrap().into_data(), &host.identity.verifying_key()));
        ws.send(Message::Binary(board.seal(b"core"))).unwrap();
        assert_closed(&mut ws);
        assert_eq!(pending().len(), 1);
        assert!(host.core_closed.try_recv().is_err(), "none of them reached the core");
    }

    #[test]
    fn an_untrusted_board_reaches_neither_the_core_nor_a_port() {
        let host = host(TOKEN);
        let listen = host.listen();
        let port = TcpListener::bind("127.0.0.1:0").unwrap();
        port.set_nonblocking(true).unwrap();
        let stranger = SigningKey::from_bytes(&[7; 32]);
        for carrying in ["core".to_string(), format!("tcp:{}", port.local_addr().unwrap().port())] {
            // Asked for at once, without waiting for the verdict, as a board does.
            let (mut ws, mut board) = host.proved(&listen, Board::of(stranger.clone()));
            let _ = ws.send(Message::Binary(board.seal(carrying.as_bytes())));
            assert_eq!(board.open(&ws.read().unwrap().into_data()).unwrap(), b"pending 1");
            assert_closed(&mut ws);
        }
        assert!(host.core_closed.recv_timeout(Duration::from_millis(200)).is_err(), "the core was never reached");
        assert!(port.accept().is_err(), "the port was never reached");
        assert_eq!(boards::load(&host.folder).unwrap().trusted.len(), 1);
    }

    #[test]
    fn a_trusted_board_keeps_the_list_over_a_channel() {
        let host = host(TOKEN);
        let listen = host.listen();
        let waiting = SigningKey::from_bytes(&[6; 32]);
        let (mut ws, _) = host.proved(&listen, Board::of(waiting.clone()));
        assert!(ws.read().is_ok());
        let (mine, other) = (STANDARD.encode(host.board.verifying_key().as_bytes()), STANDARD.encode(waiting.verifying_key().as_bytes()));

        let (mut ws, mut board) = host.channel(&listen, "boards");
        let ask = |ws: &mut WebSocket<TcpStream>, board: &mut Board, request: String| -> serde_json::Value {
            // In two messages: a line is a line however it is cut.
            let (start, end) = request.split_at(request.len() / 2);
            ws.send(Message::Binary(board.seal(start.as_bytes()))).unwrap();
            ws.send(Message::Binary(board.seal(format!("{end}\n").as_bytes()))).unwrap();
            let reply = board.open(&ws.read().unwrap().into_data()).unwrap();
            assert_eq!(reply.last(), Some(&b'\n'));
            serde_json::from_slice(&reply).unwrap()
        };
        let listed = ask(&mut ws, &mut board, r#"{"list":{}}"#.into());
        assert_eq!((listed["trusted"][0]["key"].as_str(), listed["pending"][0]["key"].as_str()), (Some(&mine[..]), Some(&other[..])));
        assert_eq!(listed["pending"][0]["name"], "Test Mac");
        assert_eq!(ask(&mut ws, &mut board, format!(r#"{{"trust":{{"key":"{mine}"}}}}"#)), serde_json::json!({ "error": "not_pending" }));
        assert_eq!(ask(&mut ws, &mut board, format!(r#"{{"trust":{{"key":"{other}"}}}}"#)), serde_json::json!({ "ok": true }));
        // The one just trusted gets a channel now.
        let (mut second, mut second_board) = host.proved(&listen, Board::of(waiting.clone()));
        assert_eq!(second_board.open(&second.read().unwrap().into_data()).unwrap(), b"trusted");
        second.send(Message::Binary(second_board.seal(b"core"))).unwrap();
        round_trip(&mut second, &mut second_board, b"second");

        // A board may forget itself, the last one too: its next request ends the channel,
        // and from then on everybody waits.
        assert_eq!(ask(&mut ws, &mut board, format!(r#"{{"forget":{{"key":"{other}"}}}}"#)), serde_json::json!({ "ok": true }));
        assert_eq!(ask(&mut ws, &mut board, format!(r#"{{"forget":{{"key":"{mine}"}}}}"#)), serde_json::json!({ "ok": true }));
        ws.send(Message::Binary(board.seal(b"{\"list\":{}}\n"))).unwrap();
        assert_closed(&mut ws);
        let (mut ws, mut board) = host.proved(&listen, Board::of(host.board.clone()));
        assert_eq!(board.open(&ws.read().unwrap().into_data()).unwrap(), b"pending 0");
        assert_closed(&mut ws);
    }

    #[test]
    fn a_trusted_board_gets_and_sets_the_vault_key_over_a_channel() {
        let host = host(TOKEN);
        let listen = host.listen();
        let (mut ws, mut board) = host.channel(&listen, "vault");
        let mut ask = |request: String| -> serde_json::Value {
            ws.send(Message::Binary(board.seal(format!("{request}\n").as_bytes()))).unwrap();
            serde_json::from_slice(&board.open(&ws.read().unwrap().into_data()).unwrap()).unwrap()
        };
        let (key, other) = (STANDARD.encode([1u8; 32]), STANDARD.encode([2u8; 32]));
        assert_eq!(ask(r#"{"get":{}}"#.into()), serde_json::json!({ "error": "no_key" }));
        assert_eq!(ask(format!(r#"{{"set":{{"key":"{key}"}}}}"#)), serde_json::json!({ "ok": true }));
        assert_eq!(ask(format!(r#"{{"set":{{"key":"{other}"}}}}"#)), serde_json::json!({ "error": "different_key" }));
        assert_eq!(ask(r#"{"get":{}}"#.into()), serde_json::json!({ "key": key }));

        // Forgotten, a board's next request ends the channel, with no key.
        assert_eq!(boards::answer(&host.folder, &STANDARD.encode(host.board.verifying_key().as_bytes()), format!(r#"{{"forget":{{"key":"{}"}}}}"#, STANDARD.encode(host.board.verifying_key().as_bytes())).as_bytes(), boards::now()), Some("{\"ok\":true}\n".into()));
        ws.send(Message::Binary(board.seal(b"{\"get\":{}}\n"))).unwrap();
        assert_closed(&mut ws);
    }

    #[test]
    fn says_alive_pings_and_comes_back_when_the_line_drops() {
        let host = host(TOKEN);
        let listen = host.listen();
        std::thread::sleep(Duration::from_millis(450));
        // Every 100 ms and every 40 ms, on a machine that may be busy.
        let (alive, pings) = (listen.alive.load(Ordering::SeqCst), listen.pings.load(Ordering::SeqCst));
        assert!((2..=5).contains(&alive), "{alive} alive");
        assert!((5..=12).contains(&pings), "{pings} pings");
        assert!(host.stub.listens.try_recv().is_err(), "answered pings keep the line");

        // The server stops answering: after two unanswered pings the host starts over.
        listen.answers.store(false, Ordering::SeqCst);
        let second = host.listen();
        assert_eq!(host.stub.registrations.load(Ordering::SeqCst), 2, "registers on every start");

        // The server drops the socket.
        second.commands.send(Command::Drop).unwrap();
        let third = host.listen();
        // A newer listen replaced this one (4409): the host comes back as well.
        third.commands.send(Command::Close(4409)).unwrap();
        let fourth = host.listen();
        host.up_is(&[true, false, true, false, true, false, true]);
        let (mut ws, mut board) = host.channel(&fourth, "core");
        round_trip(&mut ws, &mut board, b"after reconnecting");

        // The host was forgotten (4404): it stops for good.
        fourth.commands.send(Command::Close(4404)).unwrap();
        assert_eq!(host.stopped.recv_timeout(SOON), Ok(Stop::Forgotten));
        std::thread::sleep(Duration::from_millis(150));
        assert!(host.stub.listens.try_recv().is_err());
        assert_eq!(host.stub.registrations.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn hears_tickets_and_registers_where_it_is() {
        let host = host(TOKEN);
        let listen = host.listen();
        assert_eq!(*host.stub.registered.lock().unwrap(), [serde_json::json!(["192.0.2.7:47470"])]);

        let ticket = [7u8; 32];
        listen.commands.send(Command::Say(format!(r#"{{"ticket":"{}"}}"#, STANDARD.encode(ticket)))).unwrap();
        // Not tickets: too short, and not base64.
        listen.commands.send(Command::Say(r#"{"ticket":"AAAA"}"#.into())).unwrap();
        listen.commands.send(Command::Say(format!(r#"{{"ticket":"{}"}}"#, "!".repeat(44)))).unwrap();
        let deadline = Instant::now() + SOON;
        while !host.tickets.take(&ticket) {
            assert!(Instant::now() < deadline, "the host keeps the ticket it heard");
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!host.tickets.take(&ticket) && !host.tickets.take(&[0; 32]));

        // The machine moved: the next `alive` registers the new addresses, once.
        *host.addresses.lock().unwrap() = vec!["198.51.100.4:47470".into(), "[2001:db8::1]:47470".into()];
        let deadline = Instant::now() + SOON;
        while host.stub.registered.lock().unwrap().len() < 2 {
            assert!(Instant::now() < deadline, "the host registers again");
            std::thread::sleep(Duration::from_millis(5));
        }
        std::thread::sleep(Duration::from_millis(250));
        assert_eq!(*host.stub.registered.lock().unwrap(), [serde_json::json!(["192.0.2.7:47470"]), serde_json::json!(["198.51.100.4:47470", "[2001:db8::1]:47470"])]);
        assert!(host.stub.listens.try_recv().is_err(), "on the same line");

        // A new login on disk: the line ends, to start over with it.
        host.changed.store(true, Ordering::SeqCst);
        assert_eq!(host.stopped.recv_timeout(SOON), Ok(Stop::Changed));
    }

    #[test]
    fn stops_when_the_token_is_refused() {
        let host = host("old-token");
        assert_eq!(host.stopped.recv_timeout(SOON), Ok(Stop::SignedOut));
        assert_eq!(host.stub.registrations.load(Ordering::SeqCst), 1);
        assert_eq!(*host.up.lock().unwrap(), [false]);
        // The WebSocket's own 401, which a token ended between the two calls gets.
        let refused = connect(&host.stub.url, &format!("/v1/hosts/{}/listen", host.id), "old-token");
        assert!(matches!(refused, Err(Refused::Status(401))));
        assert!(matches!(status(401), Some(Ended::Stop(Stop::SignedOut))) && matches!(status(404), Some(Ended::Stop(Stop::Forgotten))));
    }
}
