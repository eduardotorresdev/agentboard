use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::time::Duration;

/// A new folder of this test's own. Short: Unix socket paths go in it.
pub fn temporary(name: &str) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let folder = std::env::temp_dir().join(format!("ab-{name}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
    std::fs::create_dir_all(&folder).unwrap();
    folder
}

/// One HTTP request, head and body.
pub fn read_request(stream: &mut TcpStream) -> String {
    let (mut request, mut buffer) = (Vec::new(), [0u8; 4096]);
    loop {
        let text = String::from_utf8_lossy(&request).to_string();
        if let Some((head, body)) = text.split_once("\r\n\r\n") {
            let length = head.lines().find_map(|line| line.to_lowercase().strip_prefix("content-length:").map(|value| value.trim().parse::<usize>().unwrap()));
            if body.len() >= length.unwrap_or(0) {
                return text;
            }
        }
        let count = stream.read(&mut buffer).unwrap();
        assert!(count > 0, "request cut short");
        request.extend_from_slice(&buffer[..count]);
    }
}

/// An HTTP server that answers each request with the next of `replies` (status, JSON body),
/// and reports each request it got.
pub fn http_stub(replies: Vec<(u16, String)>) -> (String, Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (requests, received) = channel();
    std::thread::spawn(move || {
        for (status, body) in replies {
            let mut stream = listener.accept().unwrap().0;
            let _ = requests.send(read_request(&mut stream));
            stream.write_all(format!("HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).unwrap();
        }
    });
    (url, received)
}

pub fn echo(mut stream: impl Read + Write) {
    let mut buffer = [0u8; 8192];
    while let Ok(count @ 1..) = stream.read(&mut buffer) {
        if stream.write_all(&buffer[..count]).is_err() {
            break;
        }
    }
}

/// An echo in place of the core, on a socket in `folder`: its path, a message each time a
/// connection to it closes, and how many it took.
pub fn echo_core(folder: &std::path::Path) -> (PathBuf, Receiver<()>, Arc<AtomicUsize>) {
    let path = folder.join("core.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let (closed, closes) = channel();
    let taken = Arc::new(AtomicUsize::new(0));
    let counted = taken.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            counted.fetch_add(1, Ordering::SeqCst);
            let closed = closed.clone();
            std::thread::spawn(move || {
                echo(stream.unwrap());
                let _ = closed.send(());
            });
        }
    });
    (path, closes, taken)
}

/// An echo on a loopback port, in place of what a runner serves.
pub fn echo_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || listener.incoming().for_each(|stream| drop(std::thread::spawn(move || echo(stream.unwrap())))));
    port
}

pub fn median(mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    samples[samples.len() / 2]
}
