//! What carries a channel's messages: a WebSocket on the account server (the relay), or a TCP
//! connection a board made straight to this host, each message behind its length.

use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use tungstenite::client::IntoClientRequest;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Connector, HandshakeError, Message, WebSocket};

use crate::channel::{CHUNK, TAG};

/// How long a connection or a write may take before the peer counts as gone, and a relayed
/// channel's setup.
pub const PATIENCE: Duration = Duration::from_secs(15);

pub trait Incoming: Send {
    /// The next message, waiting for it; None when the peer left, broke the framing, or the
    /// deadline passed.
    fn next(&mut self) -> Option<Vec<u8>>;
    /// Until when messages are waited for; None waits forever, as an idle terminal needs.
    fn patience(&mut self, deadline: Option<Instant>);
}

pub trait Outgoing: Send {
    fn send(&mut self, message: Vec<u8>) -> bool;
    /// Says goodbye, where the transport has a way to.
    fn finish(&mut self) {}
}

/// A channel's two directions, each used by one thread, and the stream under both: shutting
/// it down ends whichever of them is waiting.
pub struct Wire {
    pub incoming: Box<dyn Incoming>,
    pub outgoing: Box<dyn Outgoing>,
    pub tcp: TcpStream,
}

impl Wire {
    /// A board's direct connection: 4 bytes of length, big-endian, then the message.
    pub fn direct(tcp: TcpStream, deadline: Instant) -> io::Result<Wire> {
        tcp.set_nodelay(true)?;
        tcp.set_write_timeout(Some(PATIENCE * 4))?;
        keep_alive(&tcp);
        let incoming = Framed { stream: tcp.try_clone()?, deadline: Some(deadline) };
        let outgoing = Framing { stream: tcp.try_clone()?, frame: Vec::new() };
        Ok(Wire { incoming: Box::new(incoming), outgoing: Box::new(outgoing), tcp })
    }
}

/// A board that vanished (its network changed, its lid closed) is noticed in about half a
/// minute instead of never: its channel ends and what it held is let go.
fn keep_alive(tcp: &TcpStream) {
    use std::os::fd::AsRawFd;
    let set = |level, option, value: libc::c_int| {
        // SAFETY: setsockopt reads one int from `value`, which lives through the call.
        unsafe { libc::setsockopt(tcp.as_raw_fd(), level, option, (&value as *const libc::c_int).cast(), std::mem::size_of::<libc::c_int>() as libc::socklen_t) };
    };
    set(libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1);
    #[cfg(target_os = "linux")]
    {
        set(libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, 20);
        set(libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 5);
        set(libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 3);
    }
}

struct Framed {
    stream: TcpStream,
    deadline: Option<Instant>,
}

impl Framed {
    fn fill(&mut self, buffer: &mut [u8]) -> bool {
        let mut filled = 0;
        while filled < buffer.len() {
            // Per read, so trickling bytes in doesn't stretch the deadline.
            if let Some(deadline) = self.deadline {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() || self.stream.set_read_timeout(Some(left)).is_err() {
                    return false;
                }
            }
            match self.stream.read(&mut buffer[filled..]) {
                Ok(0) => return false,
                Ok(count) => filled += count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return false,
            }
        }
        true
    }
}

impl Incoming for Framed {
    fn next(&mut self) -> Option<Vec<u8>> {
        let mut length = [0u8; 4];
        if !self.fill(&mut length) {
            return None;
        }
        let length = u32::from_be_bytes(length) as usize;
        // Refused before it is allocated.
        if length > CHUNK + TAG {
            return None;
        }
        let mut message = vec![0u8; length];
        self.fill(&mut message).then_some(message)
    }

    fn patience(&mut self, deadline: Option<Instant>) {
        self.deadline = deadline;
        let _ = self.stream.set_read_timeout(None);
    }
}

struct Framing {
    stream: TcpStream,
    /// Length and message leave in one write, so in one packet.
    frame: Vec<u8>,
}

impl Outgoing for Framing {
    fn send(&mut self, message: Vec<u8>) -> bool {
        self.frame.clear();
        self.frame.extend_from_slice(&(message.len() as u32).to_be_bytes());
        self.frame.extend_from_slice(&message);
        self.stream.write_all(&self.frame).is_ok()
    }
}

/// The WebSocket's TCP stream. Blocking for the handshake; once `polled`, a read gives
/// `WouldBlock` instead of waiting, so one thread can wait in `poll` without holding the
/// WebSocket while another writes to it. Writes always block.
pub struct Tcp {
    stream: TcpStream,
    polled: Arc<AtomicBool>,
}

impl Read for Tcp {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if !self.polled.load(Ordering::Relaxed) {
            return self.stream.read(buffer);
        }
        loop {
            // SAFETY: recv writes at most `buffer.len()` bytes into `buffer`.
            let count = unsafe { libc::recv(self.stream.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len(), libc::MSG_DONTWAIT) };
            if count >= 0 {
                return Ok(count as usize);
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

impl Write for Tcp {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.stream.write(buffer)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}

pub type Socket = WebSocket<MaybeTlsStream<Tcp>>;

/// A WebSocket on the account server, already switched to reads that never wait.
pub struct Link {
    pub ws: Socket,
    pub tcp: TcpStream,
}

#[derive(Debug)]
pub enum Refused {
    Status(u16),
    Other(String),
}

fn tls() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            let builder = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()));
            Arc::new(builder.with_safe_default_protocol_versions().expect("ring's defaults").with_root_certificates(roots).with_no_client_auth())
        })
        .clone()
}

/// Opens a WebSocket on the account server as this host.
pub fn connect(server: &str, path: &str, token: &str) -> Result<Link, Refused> {
    let other = |error: &dyn std::fmt::Display| Refused::Other(error.to_string());
    let rest = server.strip_prefix("http").ok_or_else(|| other(&"the server's address must be http or https"))?;
    let mut request = format!("ws{rest}{path}").into_client_request().map_err(|error| other(&error))?;
    let bearer = format!("Bearer {token}").parse().map_err(|_| other(&"the token is not a header value"))?;
    request.headers_mut().insert("Authorization", bearer);
    let uri = request.uri();
    let port = uri.port_u16().unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
    let addresses = (uri.host().unwrap_or(""), port).to_socket_addrs().map_err(|error| other(&error))?;
    let mut tcp = Err(io::Error::other("no address"));
    for address in addresses {
        tcp = TcpStream::connect_timeout(&address, PATIENCE);
        if tcp.is_ok() {
            break;
        }
    }
    let tcp = tcp.map_err(|error| other(&error))?;
    // Keystrokes travel here: nothing waits for a fuller packet.
    tcp.set_nodelay(true).map_err(|error| other(&error))?;
    let _ = tcp.set_read_timeout(Some(PATIENCE));
    let _ = tcp.set_write_timeout(Some(PATIENCE * 4));
    let polled = Arc::new(AtomicBool::new(false));
    let stream = Tcp { stream: tcp.try_clone().map_err(|error| other(&error))?, polled: polled.clone() };
    // Nothing a host is sent is larger than a sealed chunk.
    let limits = WebSocketConfig { max_message_size: Some(CHUNK + TAG), max_frame_size: Some(CHUNK + TAG), ..Default::default() };
    match tungstenite::client_tls_with_config(request, stream, Some(limits), Some(Connector::Rustls(tls()))) {
        Ok((ws, _)) => {
            let _ = tcp.set_read_timeout(None);
            polled.store(true, Ordering::Relaxed);
            Ok(Link { ws, tcp })
        }
        Err(HandshakeError::Failure(tungstenite::Error::Http(response))) => Err(Refused::Status(response.status().as_u16())),
        Err(error) => Err(other(&error)),
    }
}

/// The next message already here, or None.
pub fn ready(ws: &mut Socket) -> Result<Option<Message>, tungstenite::Error> {
    match ws.read() {
        Ok(message) => Ok(Some(message)),
        Err(tungstenite::Error::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
        Err(error) => Err(error),
    }
}

/// Sleeps until the stream has something to read (or ended), or `limit` passed.
pub fn wait(tcp: &TcpStream, limit: Option<Duration>) {
    let mut entry = libc::pollfd { fd: tcp.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // Rounded up, so a wait shorter than a millisecond doesn't spin.
    let limit = limit.map_or(-1, |limit| limit.as_millis().min(60_000) as i32 + 1);
    // SAFETY: poll reads and writes the one entry given.
    unsafe { libc::poll(&mut entry, 1, limit) };
}

impl Link {
    /// The channel a board opened through the relay, to be set up by `deadline`.
    pub fn into_wire(self, deadline: Instant) -> io::Result<Wire> {
        let ws = Arc::new(Mutex::new(self.ws));
        let incoming = Relayed { ws: ws.clone(), tcp: self.tcp.try_clone()?, deadline: Some(deadline) };
        Ok(Wire { incoming: Box::new(incoming), outgoing: Box::new(Relaying(ws)), tcp: self.tcp })
    }
}

struct Relayed {
    ws: Arc<Mutex<Socket>>,
    tcp: TcpStream,
    deadline: Option<Instant>,
}

impl Incoming for Relayed {
    fn next(&mut self) -> Option<Vec<u8>> {
        loop {
            // Held for the read alone, which never waits.
            let message = ready(&mut self.ws.lock().unwrap());
            match message {
                Ok(Some(Message::Binary(message))) => return Some(message),
                Ok(Some(Message::Ping(_) | Message::Pong(_))) => continue,
                Ok(None) => {}
                _ => return None,
            }
            let left = self.deadline.map(|deadline| deadline.saturating_duration_since(Instant::now()));
            if left.is_some_and(|left| left.is_zero()) {
                return None;
            }
            wait(&self.tcp, left);
        }
    }

    fn patience(&mut self, deadline: Option<Instant>) {
        self.deadline = deadline;
    }
}

struct Relaying(Arc<Mutex<Socket>>);

impl Outgoing for Relaying {
    fn send(&mut self, message: Vec<u8>) -> bool {
        self.0.lock().unwrap().send(Message::Binary(message)).is_ok()
    }

    fn finish(&mut self) {
        let _ = self.0.lock().unwrap().close(None);
    }
}
