import Darwin
import Foundation

/// A child process attached to a pseudo-terminal. Output is read on `queue` with a dispatch
/// source (no thread per process); writes are non-blocking and queued if the PTY is full.
final class PseudoTerminal {
    enum LaunchError: Error, CustomStringConvertible {
        case forkFailed(Int32)
        var description: String {
            switch self {
            case .forkFailed(let code): String(cString: strerror(code))
            }
        }
    }

    private let queue: DispatchQueue
    private var master: Int32 = -1
    /// The running program, 0 when none. Read and written on `queue`.
    private(set) var pid: pid_t = 0
    private var reader: DispatchSourceRead?
    /// The reader is paused between reads (see `minimumReadInterval`); a suspended source must be
    /// resumed before it is cancelled or released.
    private var readerSuspended = false
    private var writer: DispatchSourceWrite?
    private var exitWatcher: DispatchSourceProcess?
    private var pendingWrite: [UInt8] = []
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)

    /// The least time between two reads, set on `queue`. A program that writes in many small
    /// pieces would otherwise wake a thread for each one; when output comes faster than this,
    /// reading pauses so the pieces pile up in the PTY and arrive in one read. Output after a
    /// quiet spell is read at once, and heavy output (a large read) is never held back.
    var minimumReadInterval: Double = 0
    private var lastRead: UInt64 = 0
    private static let heavyRead = 4096

    /// Called on `queue` with each chunk the program writes.
    var onOutput: ((UnsafeRawBufferPointer) -> Void)?
    /// Called on `queue` once the program has exited, with its exit status.
    var onExit: ((Int32) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        if readerSuspended { reader?.resume() }
        readBuffer.deallocate()
    }

    /// Starts `executable`. Must be called on `queue`.
    func start(executable: String, arguments: [String], environment: [String: String], directory: String,
               cols: Int, rows: Int) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        // Everything the child needs is prepared before fork: between fork and exec only
        // async-signal-safe calls are allowed.
        let path = strdup(executable)
        let cwd = strdup(directory)
        let argvList = ([executable] + arguments).map { strdup($0) } + [nil]
        let envpList = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argvList.count)
        argv.initialize(from: argvList, count: argvList.count)
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envpList.count)
        envp.initialize(from: envpList, count: envpList.count)
        defer {
            free(path)
            free(cwd)
            argvList.forEach { free($0) }
            envpList.forEach { free($0) }
            argv.deallocate()
            envp.deallocate()
        }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)

        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { throw LaunchError.forkFailed(errno) }
        if child == 0 {
            // Don't pass the app's signal dispositions or mask on to the program.
            var signal: Int32 = 1
            while signal < NSIG {
                if signal != SIGKILL && signal != SIGSTOP { sigaction(signal, &defaultAction, nil) }
                signal += 1
            }
            sigprocmask(SIG_SETMASK, &emptyMask, nil)
            chdir(cwd)
            execve(path, argv, envp)
            _exit(127)
        }

        master = fd
        pid = child
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        self.reader = reader

        let exitWatcher = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exitWatcher.setEventHandler { [weak self] in self?.reap() }
        exitWatcher.resume()
        self.exitWatcher = exitWatcher
    }

    private func readAvailable() {
        var total = 0
        while true {
            let count = read(master, readBuffer.baseAddress, readBuffer.count)
            if count > 0 {
                total += count
                onOutput?(UnsafeRawBufferPointer(rebasing: readBuffer[0..<count]))
                if count < readBuffer.count { break }
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                break
            } else {
                // EOF or EIO: the slave side closed. The exit watcher reports the status.
                cancelReader()
                return
            }
        }
        guard total > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let resume = lastRead + UInt64(minimumReadInterval * 1e9)
        lastRead = now
        // Only a program writing faster than the interval is paused; a slow one costs no timer.
        guard now < resume, total < Self.heavyRead, let reader, !readerSuspended else { return }
        reader.suspend()
        readerSuspended = true
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: resume)) { [weak self] in
            guard let self, self.readerSuspended, let reader = self.reader else { return }
            self.readerSuspended = false
            reader.resume()
        }
    }

    private func cancelReader() {
        guard let reader else { return }
        if readerSuspended {
            readerSuspended = false
            reader.resume()
        }
        reader.cancel()
        self.reader = nil
    }

    private func reap() {
        var status: Int32 = 0
        guard pid > 0, waitpid(pid, &status, WNOHANG) == pid else { return }
        pid = 0
        exitWatcher?.cancel()
        exitWatcher = nil
        // Drain whatever the program wrote last, then stop reading.
        if reader != nil { readAvailable() }
        cancelReader()
        writer?.cancel()
        writer = nil
        pendingWrite.removeAll()
        onExit?(status)
    }

    /// Queues bytes for the program. Safe from any thread.
    func write(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, self.pid > 0 else { return }
            self.pendingWrite += bytes
            self.flush()
        }
    }

    private func flush() {
        while !pendingWrite.isEmpty {
            let written = pendingWrite.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if written > 0 {
                pendingWrite.removeFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        if pendingWrite.isEmpty {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            // The PTY buffer is full: resume when it drains.
            let writer = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
            writer.setEventHandler { [weak self] in self?.flush() }
            writer.resume()
            self.writer = writer
        }
    }

    /// Tells the program its window changed size (it receives SIGWINCH).
    func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, self.pid > 0 else { return }
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.master, TIOCSWINSZ, &size)
        }
    }

    func terminate() {
        queue.async { [weak self] in
            guard let self, self.pid > 0 else { return }
            kill(self.pid, SIGHUP)
        }
    }

    /// Sends `signal` to the program and every process in its group (what it started, unless
    /// those made groups of their own), when the program running is still `expected`.
    func signalGroup(_ signal: Int32, ifStill expected: pid_t) {
        queue.async { [self] in
            guard pid > 0, pid == expected else { return }
            // forkpty made the program a session leader, so its group id is its pid.
            kill(-pid, signal)
        }
    }
}
