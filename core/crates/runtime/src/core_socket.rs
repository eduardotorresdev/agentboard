use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, Once};

use serde::Serialize;

use crate::core_protocol::{FrameKind, MAXIMUM_FRAME};
use crate::Uuid;

/// Splits a byte stream into frames, however the bytes arrive.
#[derive(Default)]
pub struct FrameParser {
    inbox: Vec<u8>,
    start: usize,
}

/// A frame length no peer of ours sends: the stream is corrupt, hang up.
#[derive(Debug, PartialEq, Eq)]
pub struct BadFrame;

impl FrameParser {
    /// Adds `bytes` and calls `on_frame` with every frame now complete. Frames of an unknown
    /// kind are dropped.
    pub fn push(&mut self, bytes: &[u8], on_frame: &mut dyn FnMut(FrameKind, &[u8])) -> Result<(), BadFrame> {
        self.inbox.extend_from_slice(bytes);
        while self.inbox.len() - self.start >= 5 {
            let head = &self.inbox[self.start..];
            let length = u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as usize;
            if !(1..=MAXIMUM_FRAME).contains(&length) {
                return Err(BadFrame);
            }
            if head.len() < 4 + length {
                break;
            }
            if let Some(kind) = FrameKind::from_raw(head[4]) {
                on_frame(kind, &head[5..4 + length]);
            }
            self.start += 4 + length;
        }
        if self.start == self.inbox.len() {
            if self.inbox.capacity() > 1024 * 1024 {
                self.inbox = Vec::new();
            }
            self.inbox.clear();
            self.start = 0;
        } else if self.start > 1024 * 1024 {
            self.inbox.drain(..self.start);
            self.start = 0;
        }
        Ok(())
    }
}

/// One end of a core connection: reads frames on a thread of its own and writes them without
/// ever blocking the sender. Sends are safe from any thread and keep their order.
///
/// A frame goes straight to the socket when nothing waits and the socket takes it (the usual
/// case: a keystroke's echo costs no thread hop); what it doesn't take is queued for the writer
/// thread. A peer that stops reading is dropped at the first frame sent while more than
/// `OUTBOX_LIMIT` bytes already wait for it, so a stuck board never stalls a session and costs
/// at most that much memory plus one frame (twice, counting what the writer holds).
#[derive(Clone)]
pub struct CoreSocket {
    inner: Arc<Inner>,
}

struct Inner {
    stream: UnixStream,
    outbox: Mutex<Outbox>,
    pending: Condvar,
}

#[derive(Default)]
struct Outbox {
    bytes: Vec<u8>,
    /// The writer thread took bytes it hasn't finished writing: nothing may overtake them.
    writing: bool,
    closed: bool,
}

/// A peer that stops reading is dropped once more than this is waiting for it.
const OUTBOX_LIMIT: usize = 64 * 1024 * 1024;

#[cfg(any(target_os = "linux", target_os = "android"))]
const SEND_FLAGS: libc::c_int = libc::MSG_NOSIGNAL;
#[cfg(not(any(target_os = "linux", target_os = "android")))]
const SEND_FLAGS: libc::c_int = 0;

/// A peer gone mid-write ends this process with SIGPIPE unless it is ignored.
pub(crate) fn ignore_sigpipe() {
    static ONCE: Once = Once::new();
    // SAFETY: setting a disposition to ignore is always sound.
    ONCE.call_once(|| unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    });
}

impl CoreSocket {
    pub fn new(stream: UnixStream) -> Self {
        ignore_sigpipe();
        // Non-blocking, so a send takes what fits and returns (macOS waits for room even with
        // MSG_DONTWAIT); the reader and writer threads wait with poll.
        let _ = stream.set_nonblocking(true);
        // Room for a full read of a PTY (64 KiB) in one go; macOS starts at 8 KiB.
        let size: libc::c_int = 256 * 1024;
        // SAFETY: the option's value is a c_int that outlives the call.
        unsafe { libc::setsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_SNDBUF, (&size as *const libc::c_int).cast(), 4) };
        Self { inner: Arc::new(Inner { stream, outbox: Mutex::default(), pending: Condvar::new() }) }
    }

    /// Starts reading: `on_frame` is called on the reader thread with each frame, `on_close`
    /// once, when the connection ends for any reason.
    pub fn start(&self, mut on_frame: impl FnMut(FrameKind, &[u8]) + Send + 'static, on_close: impl FnOnce() + Send + 'static) {
        let reader = self.clone();
        std::thread::spawn(move || {
            let mut parser = FrameParser::default();
            let mut buffer = vec![0u8; 256 * 1024];
            loop {
                match (&reader.inner.stream).read(&mut buffer) {
                    Ok(count) if count > 0 => {
                        if parser.push(&buffer[..count], &mut on_frame).is_err() {
                            break;
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => reader.wait(libc::POLLIN),
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    _ => break,
                }
            }
            reader.close();
            on_close();
        });
        let writer = self.clone();
        std::thread::spawn(move || writer.write_queued());
    }

    pub fn send(&self, kind: FrameKind, payload: &[u8]) {
        self.send_parts(kind, &[], payload);
    }

    /// A `data` or `snapshot` frame: the session's id, then `payload`.
    pub fn send_to(&self, kind: FrameKind, id: Uuid, payload: &[u8]) {
        self.send_parts(kind, id.as_bytes(), payload);
    }

    pub fn send_message<Message: Serialize>(&self, message: &Message) {
        if let Ok(json) = serde_json::to_vec(message) {
            self.send(FrameKind::Control, &json);
        }
    }

    fn send_parts(&self, kind: FrameKind, prefix: &[u8], payload: &[u8]) {
        let length = (1 + prefix.len() + payload.len()) as u32;
        let mut header = [0u8; 5];
        header[..4].copy_from_slice(&length.to_be_bytes());
        header[4] = kind as u8;
        let parts = [&header[..], prefix, payload];

        let mut outbox = self.inner.outbox.lock().unwrap();
        if outbox.closed {
            return;
        }
        // Checked before queueing, not after: one frame larger than the limit (a long `ran`)
        // still reaches a peer that is reading.
        if outbox.bytes.len() > OUTBOX_LIMIT {
            drop(outbox);
            return self.close();
        }
        let mut written = 0;
        if outbox.bytes.is_empty() && !outbox.writing {
            match self.send_now(&parts) {
                Some(count) => written = count,
                None => {
                    drop(outbox);
                    return self.close();
                }
            }
        }
        for part in parts {
            let skipped = written.min(part.len());
            outbox.bytes.extend_from_slice(&part[skipped..]);
            written -= skipped;
        }
        if !outbox.bytes.is_empty() {
            self.inner.pending.notify_one();
        }
    }

    /// Blocks until the socket is ready for `events`, or hung up.
    fn wait(&self, events: libc::c_short) {
        let mut fd = libc::pollfd { fd: self.inner.stream.as_raw_fd(), events, revents: 0 };
        // SAFETY: `fd` is one live pollfd.
        unsafe { libc::poll(&mut fd, 1, -1) };
    }

    /// Writes what the socket takes without waiting, and says how much; none when the
    /// connection is gone.
    fn send_now(&self, parts: &[&[u8]; 3]) -> Option<usize> {
        let vectors = parts.map(|part| libc::iovec { iov_base: part.as_ptr() as *mut libc::c_void, iov_len: part.len() });
        // SAFETY: an all-zero msghdr is valid; it points at `vectors`, which outlive the call
        // and describe live slices that sendmsg only reads.
        let sent = unsafe {
            let mut message: libc::msghdr = std::mem::zeroed();
            message.msg_iov = vectors.as_ptr() as *mut libc::iovec;
            message.msg_iovlen = vectors.len() as _;
            libc::sendmsg(self.inner.stream.as_raw_fd(), &message, SEND_FLAGS)
        };
        if sent >= 0 {
            return Some(sent as usize);
        }
        match io::Error::last_os_error().kind() {
            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted => Some(0),
            _ => None,
        }
    }

    /// The writer thread: writes what `send_parts` queued, waiting on the socket as long as
    /// it takes. `close` (the peer gone, or the outbox over its limit) ends its wait.
    fn write_queued(&self) {
        let mut buffer = Vec::new();
        let mut outbox = self.inner.outbox.lock().unwrap();
        loop {
            outbox.writing = false;
            while outbox.bytes.is_empty() && !outbox.closed {
                outbox = self.inner.pending.wait(outbox).unwrap();
            }
            if outbox.closed {
                return;
            }
            std::mem::swap(&mut outbox.bytes, &mut buffer);
            outbox.writing = true;
            drop(outbox);
            let mut written = 0;
            let mut failed = false;
            while written < buffer.len() && !failed {
                match (&self.inner.stream).write(&buffer[written..]) {
                    Ok(count) => written += count,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => self.wait(libc::POLLOUT),
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    Err(_) => failed = true,
                }
            }
            if buffer.capacity() > 1024 * 1024 {
                buffer = Vec::new();
            }
            buffer.clear();
            if failed {
                return self.close();
            }
            outbox = self.inner.outbox.lock().unwrap();
        }
    }

    /// Ends the connection; frames not written yet are dropped.
    pub fn close(&self) {
        let mut outbox = self.inner.outbox.lock().unwrap();
        if std::mem::replace(&mut outbox.closed, true) {
            return;
        }
        outbox.bytes = Vec::new();
        // Wakes the reader out of its read and the writer out of its write.
        let _ = self.inner.stream.shutdown(std::net::Shutdown::Both);
        self.inner.pending.notify_all();
    }
}

// MARK: Unix sockets

/// A socket connected to `path`.
pub fn connect(path: &str) -> io::Result<UnixStream> {
    let stream = UnixStream::connect(path)?;
    no_sigpipe(&stream);
    Ok(stream)
}

/// A socket listening at `path`, usable by this user only. Replaces a stale socket file, and
/// makes the folder (user-only) when it is missing.
pub fn listen(path: &str) -> io::Result<UnixListener> {
    if let Some(folder) = Path::new(path).parent().filter(|folder| !folder.as_os_str().is_empty()) {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(folder)?;
    }
    let _ = std::fs::remove_file(path);
    // The file must never exist with wider permissions, so the mask and not a chmod after.
    // SAFETY: umask only swaps the process's file mode mask.
    let previous = unsafe { libc::umask(0o077) };
    let listener = UnixListener::bind(path);
    // SAFETY: as above.
    unsafe { libc::umask(previous) };
    listener
}

pub(crate) fn no_sigpipe(stream: &UnixStream) {
    #[cfg(target_vendor = "apple")]
    {
        let on: libc::c_int = 1;
        // SAFETY: the option's value is a c_int that outlives the call.
        unsafe { libc::setsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_NOSIGPIPE, &on as *const _ as *const libc::c_void, 4) };
    }
    let _ = stream;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
        let mut bytes = ((payload.len() + 1) as u32).to_be_bytes().to_vec();
        bytes.push(kind);
        bytes.extend_from_slice(payload);
        bytes
    }

    #[test]
    fn frames_arrive_whole_however_the_bytes_are_split() {
        let stream = [frame(1, b"{}"), frame(2, &[7; 40]), frame(9, b"unknown kind"), frame(4, b""), frame(3, &[1; 70_000])].concat();
        for chunk in [1, 2, 3, 5, 7, 4096, stream.len()] {
            let mut parser = FrameParser::default();
            let mut got = Vec::new();
            for piece in stream.chunks(chunk) {
                parser.push(piece, &mut |kind, payload| got.push((kind, payload.to_vec()))).unwrap();
            }
            assert_eq!(got.len(), 4, "chunks of {chunk}");
            assert_eq!(got[0], (FrameKind::Control, b"{}".to_vec()));
            assert_eq!(got[1], (FrameKind::Data, vec![7; 40]));
            assert_eq!(got[2], (FrameKind::Service, vec![]));
            assert_eq!(got[3], (FrameKind::Snapshot, vec![1; 70_000]));
        }
    }

    #[test]
    fn oversized_and_empty_frames_are_refused() {
        let mut calls = 0;
        let too_long = ((MAXIMUM_FRAME + 1) as u32).to_be_bytes();
        assert_eq!(FrameParser::default().push(&[&too_long[..], &[1]].concat(), &mut |_, _| calls += 1), Err(BadFrame));
        assert_eq!(FrameParser::default().push(&[0, 0, 0, 0, 1], &mut |_, _| calls += 1), Err(BadFrame));
        // The largest allowed length is only waited for.
        let largest = (MAXIMUM_FRAME as u32).to_be_bytes();
        assert_eq!(FrameParser::default().push(&[&largest[..], &[1]].concat(), &mut |_, _| calls += 1), Ok(()));
        assert_eq!(calls, 0);
    }
}
