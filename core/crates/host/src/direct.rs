//! "The direct path" in docs/hosts.md: boards that can reach this host connect to it straight,
//! each with a ticket the account server gave it and told this host on its line.

use std::collections::VecDeque;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, TcpListener};
use std::os::fd::{FromRawFd, OwnedFd};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ed25519_dalek::SigningKey;
use subtle::ConstantTimeEq;

use crate::wire::Wire;

pub const PORT: u16 = 47470;
const MOST_TICKETS: usize = 64;
const MOST_CONNECTIONS: usize = 64;
/// Connections not yet known to be a trusted board's: no ticket, or no proof the host takes.
const MOST_STRANGERS: usize = 32;
const MOST_ADDRESSES: usize = 8;

/// The tickets heard and not yet used, oldest first.
pub struct Tickets {
    life: Duration,
    held: Mutex<VecDeque<([u8; 32], Instant)>>,
    heard: std::sync::Condvar,
    /// How long a ticket not heard yet is waited for: on a LAN the board gets here before the
    /// server's word of its ticket does.
    pub patience: Duration,
}

impl Tickets {
    pub fn new(life: Duration) -> Tickets {
        Tickets { life, held: Mutex::new(VecDeque::new()), heard: std::sync::Condvar::new(), patience: Duration::from_secs(2) }
    }

    pub fn add(&self, ticket: [u8; 32]) {
        let mut held = self.held.lock().unwrap();
        held.retain(|(_, heard)| heard.elapsed() < self.life);
        if held.len() >= MOST_TICKETS {
            held.pop_front();
        }
        held.push_back((ticket, Instant::now()));
        self.heard.notify_all();
    }

    /// Whether `ticket` is one heard within its life and not used before; it is used now.
    pub fn take(&self, ticket: &[u8]) -> bool {
        let deadline = Instant::now() + self.patience;
        let mut held = self.held.lock().unwrap();
        loop {
            held.retain(|(_, heard)| heard.elapsed() < self.life);
            // Each comparison takes the same time whatever differs.
            if let Some(at) = held.iter().position(|(known, _)| bool::from(known[..].ct_eq(ticket))) {
                return held.remove(at).is_some();
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            held = self.heard.wait_timeout(held, left).unwrap().0;
        }
    }
}

/// A listening socket on every address of one family. IPv6 takes IPv6 only, so both families
/// can share a port.
fn listener(v6: bool, port: u16) -> io::Result<TcpListener> {
    // SAFETY: plain socket calls on a descriptor owned from the moment it exists; the address
    // structures are zeroed plain data of the size passed along.
    unsafe {
        let fd = libc::socket(if v6 { libc::AF_INET6 } else { libc::AF_INET }, libc::SOCK_STREAM, 0);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let socket = OwnedFd::from_raw_fd(fd);
        let (one, size) = (1 as libc::c_int, std::mem::size_of::<libc::c_int>() as libc::socklen_t);
        // Not for the agents this process starts.
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, (&raw const one).cast(), size);
        let bound = if v6 {
            libc::setsockopt(fd, libc::IPPROTO_IPV6, libc::IPV6_V6ONLY, (&raw const one).cast(), size);
            let mut address: libc::sockaddr_in6 = std::mem::zeroed();
            address.sin6_family = libc::AF_INET6 as libc::sa_family_t;
            address.sin6_port = port.to_be();
            libc::bind(fd, (&raw const address).cast(), std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t)
        } else {
            let mut address: libc::sockaddr_in = std::mem::zeroed();
            address.sin_family = libc::AF_INET as libc::sa_family_t;
            address.sin_port = port.to_be();
            libc::bind(fd, (&raw const address).cast(), std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t)
        };
        if bound != 0 || libc::listen(fd, 64) != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(TcpListener::from(socket))
    }
}

/// Listens for boards on `PORT`, or on a free port when it is taken, on IPv4 and, where the
/// machine has it, IPv6.
pub fn listeners() -> io::Result<(Vec<TcpListener>, u16)> {
    let v4 = listener(false, PORT).or_else(|_| listener(false, 0))?;
    let port = v4.local_addr()?.port();
    let mut listeners = vec![v4];
    listeners.extend(listener(true, port));
    Ok((listeners, port))
}

/// What a direct connection is served with.
pub struct Door {
    pub identity: SigningKey,
    pub core: PathBuf,
    /// The folder of the list of boards this host trusts.
    pub boards: PathBuf,
    pub tickets: Arc<Tickets>,
    /// For the handshake, the ticket and what the channel carries.
    pub patience: Duration,
}

/// Serves the boards that connect to `listener`, each on a thread, forever.
pub fn serve(listener: TcpListener, door: Arc<Door>) {
    // Counted apart: strangers holding connections open must not keep the boards out.
    let (strangers, boards) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
    for stream in listener.incoming() {
        let Ok(stream) = stream else {
            // Out of descriptors, most likely: not a loop to spin in.
            std::thread::sleep(Duration::from_millis(100));
            continue;
        };
        if strangers.fetch_add(1, Ordering::SeqCst) >= MOST_STRANGERS || boards.load(Ordering::SeqCst) >= MOST_CONNECTIONS {
            strangers.fetch_sub(1, Ordering::SeqCst);
            continue;
        }
        let (door, strangers, boards) = (door.clone(), strangers.clone(), boards.clone());
        std::thread::spawn(move || {
            let admitted = std::cell::Cell::new(false);
            // Nothing is logged: anything can connect here, and until it is trusted it is nobody.
            if let Ok(wire) = Wire::direct(stream, Instant::now() + door.patience) {
                let admit = || {
                    admitted.set(true);
                    strangers.fetch_sub(1, Ordering::SeqCst);
                    boards.fetch_add(1, Ordering::SeqCst);
                };
                let _ = crate::relay::serve(wire, &door.identity, Some((&door.tickets, &admit)), &door.core, &door.boards);
            }
            if admitted.get() { &boards } else { &strangers }.fetch_sub(1, Ordering::SeqCst);
        });
    }
}

/// Whether a board could reach this host at `address` of the interface `name`.
fn reachable(name: &str, address: IpAddr) -> bool {
    // Containers' and virtual machines' bridges: addresses only this machine sees.
    if ["docker", "br-", "veth", "virbr"].iter().any(|prefix| name.starts_with(prefix)) {
        return false;
    }
    match address {
        IpAddr::V4(address) => !(address.is_loopback() || address.is_link_local() || address.is_unspecified()),
        // Global unicast (2000::/3): link-local ones need a scope a board doesn't have.
        IpAddr::V6(address) => address.segments()[0] & 0xe000 == 0x2000,
    }
}

fn interfaces() -> Vec<(String, IpAddr)> {
    let mut found = Vec::new();
    // SAFETY: getifaddrs gives a list valid until freeifaddrs; every pointer is checked before
    // it is read, and an address is read as the structure its family says it is.
    unsafe {
        let mut list = std::ptr::null_mut();
        if libc::getifaddrs(&mut list) != 0 {
            return found;
        }
        let mut entry = list;
        while !entry.is_null() {
            let interface = &*entry;
            entry = interface.ifa_next;
            if interface.ifa_addr.is_null() || interface.ifa_flags & libc::IFF_UP as libc::c_uint == 0 {
                continue;
            }
            let address = match (*interface.ifa_addr).sa_family as libc::c_int {
                libc::AF_INET => IpAddr::V4(Ipv4Addr::from(u32::from_be((*interface.ifa_addr.cast::<libc::sockaddr_in>()).sin_addr.s_addr))),
                libc::AF_INET6 => IpAddr::V6(Ipv6Addr::from((*interface.ifa_addr.cast::<libc::sockaddr_in6>()).sin6_addr.s6_addr)),
                _ => continue,
            };
            found.push((std::ffi::CStr::from_ptr(interface.ifa_name).to_string_lossy().into_owned(), address));
        }
        libc::freeifaddrs(list);
    }
    found
}

fn registered(interfaces: Vec<(String, IpAddr)>, port: u16) -> Vec<String> {
    let mut addresses: Vec<IpAddr> = interfaces.into_iter().filter(|(name, address)| reachable(name, *address)).map(|(_, address)| address).collect();
    // IPv4 first: the LAN's, which is the one that most often answers.
    addresses.sort_by_key(|address| address.is_ipv6());
    addresses.dedup();
    addresses.truncate(MOST_ADDRESSES);
    addresses.iter().map(|address| std::net::SocketAddr::new(*address, port).to_string()).collect()
}

/// Where boards may reach this host, as it registers them: `address:port`.
pub fn addresses(port: u16) -> Vec<String> {
    registered(interfaces(), port)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::boards::{self, Verdict};
    use crate::channel::tests::Board;
    use crate::channel::{CHUNK, TAG};
    use crate::test_support::{echo_core, echo_port, median, temporary};
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::sync::mpsc::Receiver;

    /// A host's door on a loopback port, with an echoing core and an echoing port behind it.
    struct Host {
        address: std::net::SocketAddr,
        identity: SigningKey,
        tickets: Arc<Tickets>,
        /// Where the host keeps its list of boards.
        folder: PathBuf,
        /// A board the host trusts.
        board: SigningKey,
        port: u16,
        core_closed: Receiver<()>,
        /// How many connections the core took.
        core_taken: Arc<AtomicUsize>,
    }

    fn host(ticket_life: Duration, patience: Duration) -> Host {
        let folder = temporary("direct");
        let board = SigningKey::from_bytes(&[5; 32]);
        boards::open_window(&folder, u64::MAX).unwrap();
        assert_eq!(boards::admit(&folder, board.verifying_key().as_bytes(), b"Test Mac", boards::now()), Ok(Verdict::Trusted));
        let (core, core_closed, core_taken) = echo_core(&folder);
        let identity = SigningKey::from_bytes(&[3; 32]);
        let tickets = Arc::new(Tickets::new(ticket_life));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let door = Arc::new(Door { identity: identity.clone(), core, boards: folder.clone(), tickets: tickets.clone(), patience });
        std::thread::spawn(move || serve(listener, door));
        Host { address, identity, tickets, folder, board, port: echo_port(), core_closed, core_taken }
    }

    fn usual() -> Host {
        host(Duration::from_secs(30), Duration::from_secs(5))
    }

    // The board's framing, written from the spec: 4 bytes of length, big-endian, then the message.
    fn send(stream: &mut TcpStream, message: &[u8]) {
        stream.write_all(&[&(message.len() as u32).to_be_bytes()[..], message].concat()).unwrap();
    }

    fn receive(stream: &mut TcpStream) -> Option<Vec<u8>> {
        let mut length = [0u8; 4];
        stream.read_exact(&mut length).ok()?;
        let mut message = vec![0u8; u32::from_be_bytes(length) as usize];
        stream.read_exact(&mut message).ok()?;
        Some(message)
    }

    impl Host {
        fn ticket(&self) -> [u8; 32] {
            let mut ticket = [0u8; 32];
            getrandom::getrandom(&mut ticket).unwrap();
            self.tickets.add(ticket);
            ticket
        }

        /// The board the host trusts connects and does the handshake.
        fn connect(&self) -> (TcpStream, Board) {
            self.connect_as(Board::of(self.board.clone()))
        }

        fn connect_as(&self, mut board: Board) -> (TcpStream, Board) {
            let mut stream = TcpStream::connect(self.address).unwrap();
            stream.set_nodelay(true).unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            send(&mut stream, &board.key());
            assert!(board.finish(&receive(&mut stream).unwrap(), &self.identity.verifying_key()));
            (stream, board)
        }

        /// The handshake, the ticket and the proof: the host's verdict comes next, if any.
        fn present(&self, ticket: &[u8], board: Board) -> (TcpStream, Board) {
            let (mut stream, mut board) = self.connect_as(board);
            send(&mut stream, &board.seal(ticket));
            send(&mut stream, &board.prove("Test Mac"));
            (stream, board)
        }

        fn channel(&self, ticket: &[u8], carrying: &str) -> (TcpStream, Board) {
            let (mut stream, mut board) = self.present(ticket, Board::of(self.board.clone()));
            assert_eq!(board.open(&receive(&mut stream).expect("a verdict")).unwrap(), b"trusted");
            send(&mut stream, &board.seal(carrying.as_bytes()));
            (stream, board)
        }
    }

    fn round_trip(stream: &mut TcpStream, board: &mut Board, bytes: &[u8]) {
        for chunk in bytes.chunks(CHUNK) {
            send(stream, &board.seal(chunk));
        }
        let mut back = Vec::new();
        while back.len() < bytes.len() {
            let message = receive(stream).expect("the host answers");
            assert!(message.len() <= CHUNK + TAG);
            back.extend(board.open(&message).expect("sealed by the host, in order"));
        }
        assert!(back == bytes);
    }

    /// The host closed the connection without sending anything more: an end, or a reset when
    /// it left something of ours unread. Not a timeout.
    fn assert_closed(stream: &mut TcpStream) {
        let closed = match stream.read(&mut [0u8; 1]) {
            Ok(count) => count == 0,
            Err(error) => error.kind() == io::ErrorKind::ConnectionReset,
        };
        assert!(closed, "the host closes the connection");
    }

    #[test]
    fn a_board_with_a_ticket_reaches_the_core_and_loopback_ports() {
        let host = usual();
        let (mut stream, mut board) = host.channel(&host.ticket(), "core");
        round_trip(&mut stream, &mut board, b"hello");
        let large: Vec<u8> = (0..300 * 1024).map(|at| (at % 251) as u8).collect();
        round_trip(&mut stream, &mut board, &large);

        let samples = (0..2000).map(|_| {
            let start = Instant::now();
            round_trip(&mut stream, &mut board, b"k");
            start.elapsed()
        });
        let echo = median(samples.collect());
        println!("1-byte echo on the direct path, median of 2000: {echo:?} (seal, TCP, open, core socket, and back)");
        assert!(echo < Duration::from_millis(5), "{echo:?}");

        drop(stream);
        host.core_closed.recv_timeout(Duration::from_secs(5)).expect("the core hears the board left");

        let (mut stream, mut board) = host.channel(&host.ticket(), &format!("tcp:{}", host.port));
        round_trip(&mut stream, &mut board, b"GET / HTTP/1.1\r\n\r\n");
        round_trip(&mut stream, &mut board, &large);
        assert_eq!(host.core_taken.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn nothing_reaches_the_core_without_a_ticket_of_its_own() {
        let host = usual();
        let good = host.ticket();

        // Not a ticket; a ticket's bytes unsealed; the kind where the ticket goes.
        let (mut stream, _) = host.present(&[9; 32], Board::of(host.board.clone()));
        assert_closed(&mut stream);
        let (mut stream, _) = host.connect();
        send(&mut stream, &good);
        assert_closed(&mut stream);
        let (mut stream, mut board) = host.connect();
        send(&mut stream, &board.seal(b"core"));
        assert_closed(&mut stream);

        // Used once: the second board with it is turned away, while the first goes on.
        let (mut first, mut first_board) = host.channel(&good, "core");
        round_trip(&mut first, &mut first_board, b"first");
        let (mut second, _) = host.present(&good, Board::of(host.board.clone()));
        assert_closed(&mut second);
        round_trip(&mut first, &mut first_board, b"still first");

        // A ticket is no pass for anything: what it carries is checked as on the relay.
        for refused in ["shell", "tcp:0", "tcp:65536"] {
            let (mut stream, _) = host.channel(&host.ticket(), refused);
            assert_closed(&mut stream);
        }
        assert_eq!(host.core_taken.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_ticket_alone_opens_nothing() {
        let host = usual();
        let pending = || boards::load(&host.folder).unwrap().pending.len();

        // A board the host never saw, with a good ticket: told it waits, and recorded.
        let (mut stream, mut board) = host.present(&host.ticket(), Board::new());
        // What it would say next, were it trusted.
        send(&mut stream, &board.seal(b"core"));
        assert_eq!(board.open(&receive(&mut stream).expect("a verdict")).unwrap(), b"pending 1");
        assert_closed(&mut stream);
        assert_eq!(pending(), 1);

        // The ticket, then what the channel carries with no proof before it.
        let (mut stream, mut board) = host.connect();
        send(&mut stream, &board.seal(&host.ticket()));
        send(&mut stream, &board.seal(b"core"));
        assert_closed(&mut stream);
        // The trusted board's key over a signature for another host: no verdict, no record.
        let (mut stream, mut board) = host.connect();
        board.transcript[64] ^= 1;
        send(&mut stream, &board.seal(&host.ticket()));
        send(&mut stream, &board.prove("Test Mac"));
        assert_closed(&mut stream);
        assert_eq!(pending(), 1);
        assert_eq!(host.core_taken.load(Ordering::SeqCst), 0);

        // An empty list inside its first-use window: the first board to prove itself is in,
        // the next one waits.
        boards::clear(&host.folder).unwrap();
        boards::open_window(&host.folder, boards::now() + 60).unwrap();
        let (mut stream, mut board) = host.present(&host.ticket(), Board::new());
        assert_eq!(board.open(&receive(&mut stream).expect("a verdict")).unwrap(), b"trusted");
        send(&mut stream, &board.seal(b"core"));
        round_trip(&mut stream, &mut board, b"first");
        let (mut stream, mut board) = host.present(&host.ticket(), Board::new());
        assert_eq!(board.open(&receive(&mut stream).expect("a verdict")).unwrap(), b"pending 1");
        assert_closed(&mut stream);
    }

    #[test]
    fn a_late_ticket_is_no_ticket() {
        let host = host(Duration::from_millis(60), Duration::from_secs(5));
        let ticket = host.ticket();
        std::thread::sleep(Duration::from_millis(120));
        let (mut stream, _) = host.present(&ticket, Board::of(host.board.clone()));
        assert_closed(&mut stream);
        // In time, the same host takes one.
        let (mut stream, mut board) = host.channel(&host.ticket(), "core");
        round_trip(&mut stream, &mut board, b"in time");
        assert_eq!(host.core_taken.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn frames_over_the_limit_close_the_connection() {
        let host = usual();
        let over = ((CHUNK + TAG + 1) as u32).to_be_bytes();
        // As the very first thing said.
        let mut stream = TcpStream::connect(host.address).unwrap();
        stream.write_all(&over).unwrap();
        assert_closed(&mut stream);
        assert_eq!(host.core_taken.load(Ordering::SeqCst), 0);
        // And on a channel that was fine until then.
        let (mut stream, mut board) = host.channel(&host.ticket(), "core");
        round_trip(&mut stream, &mut board, b"fine so far");
        stream.write_all(&over).unwrap();
        assert_closed(&mut stream);
        host.core_closed.recv_timeout(Duration::from_secs(5)).expect("the core's connection closes too");
        // The largest allowed still passes.
        let (mut stream, mut board) = host.channel(&host.ticket(), "core");
        round_trip(&mut stream, &mut board, &vec![5; CHUNK]);
    }

    #[test]
    fn a_handshake_not_finished_in_time_is_dropped() {
        let host = host(Duration::from_secs(30), Duration::from_millis(300));
        let ticket = host.ticket();
        // Silent; trickling a frame in; and done with the handshake but showing no ticket.
        let mut silent = TcpStream::connect(host.address).unwrap();
        let mut trickling = TcpStream::connect(host.address).unwrap();
        let (mut waiting, _) = host.connect();
        let start = Instant::now();
        for stream in [&mut silent, &mut trickling, &mut waiting] {
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        }
        for _ in 0..4 {
            let _ = trickling.write_all(&[0]);
            std::thread::sleep(Duration::from_millis(100));
        }
        for stream in [&mut silent, &mut trickling, &mut waiting] {
            assert_closed(stream);
        }
        let took = start.elapsed();
        assert!(took >= Duration::from_millis(250) && took < Duration::from_secs(2), "{took:?}");
        assert_eq!(host.core_taken.load(Ordering::SeqCst), 0);

        // A channel set up in time outlives the deadline: an idle terminal says nothing for long.
        let (mut stream, mut board) = host.channel(&ticket, "core");
        std::thread::sleep(Duration::from_millis(500));
        round_trip(&mut stream, &mut board, b"after a pause");
    }

    #[test]
    fn tickets_are_few_and_single_use() {
        let mut tickets = Tickets::new(Duration::from_secs(30));
        tickets.patience = Duration::ZERO;
        for number in 0..=MOST_TICKETS as u8 {
            tickets.add([number; 32]);
        }
        assert_eq!(tickets.held.lock().unwrap().len(), MOST_TICKETS);
        assert!(!tickets.take(&[0; 32]), "the oldest made room");
        assert!(tickets.take(&[1; 32]) && !tickets.take(&[1; 32]));
        assert!(!tickets.take(&[2; 31]) && !tickets.take(&[]) && tickets.take(&[2; 32]));
    }

    #[test]
    fn registers_only_addresses_a_board_could_reach() {
        let interface = |name: &str, address: &str| (name.to_string(), address.parse::<IpAddr>().unwrap());
        let found = vec![
            interface("lo", "127.0.0.1"),
            interface("lo", "::1"),
            interface("eth0", "2804:14c:1::5"),
            interface("eth0", "fe80::1"),
            interface("eth0", "fd00::1"),
            interface("eth0", "192.168.1.20"),
            interface("eth0", "169.254.3.4"),
            interface("docker0", "172.17.0.1"),
            interface("br-1a2b3c", "172.18.0.1"),
            interface("veth9f", "10.9.0.1"),
            interface("virbr0", "192.168.122.1"),
            interface("wlan0", "10.0.0.7"),
            interface("wlan0", "10.0.0.7"),
        ];
        assert_eq!(registered(found, 47470), ["192.168.1.20:47470", "10.0.0.7:47470", "[2804:14c:1::5]:47470"]);
        let many = (1..=20).map(|at| interface("eth0", &format!("10.0.0.{at}"))).collect();
        assert_eq!(registered(many, 1).len(), MOST_ADDRESSES);
        // What this machine has passes the server's check ("address:port").
        for address in addresses(47470) {
            assert!(address.parse::<std::net::SocketAddr>().is_ok_and(|parsed| parsed.port() == 47470), "{address}");
        }
    }

    #[test]
    fn listens_on_a_port_for_both_families_and_falls_back_when_it_is_taken() {
        let (first, port) = listeners().unwrap();
        // Whatever holds 47470 on this machine, a second call can't have the same port.
        let (second, other) = listeners().unwrap();
        assert!(port != 0 && other != 0 && port != other);
        for (listeners, port) in [(&first, port), (&second, other)] {
            assert!(listeners.iter().all(|listener| listener.local_addr().unwrap().port() == port));
            assert!(TcpStream::connect(("127.0.0.1", port)).is_ok());
        }
    }
}
