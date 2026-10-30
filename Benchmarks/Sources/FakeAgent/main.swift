import ClaudeSim
import Darwin
import Foundation

// fake-agent: plays a Claude Code–like session on its terminal in real time, so benchmarks can
// run ten "agents" without a model. Usage:
//   fake-agent [--mode mixed|stream|spinner|idle] [--seed N] [--speed X] [--tee PATH] [--until PATH]
//   idle: draws the start screen, then waits for input like an agent nobody has prompted yet.
//   --tee: also appends every byte written to PATH, for a reference of what the terminal got.
//   --until: stops writing once PATH exists (and then only drains input).
//   fake-agent --dump SECONDS [--cols N --rows N --mode M --seed N] > corpus

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let key = arguments.next(), key.hasPrefix("--") { options[String(key.dropFirst(2))] = arguments.next() ?? "" }

let idle = options["mode"] == "idle"
let mode = ClaudeSim.Mode(rawValue: options["mode"] ?? "mixed") ?? .mixed
let seed = UInt64(options["seed"] ?? "1") ?? 1
let speed = Double(options["speed"] ?? "1") ?? 1
let tee = options["tee"].map { open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600) } ?? -1
let until = options["until"]

func writeAll(_ bytes: [UInt8], to fd: Int32 = STDOUT_FILENO) {
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written > 0 { offset += written } else if errno != EINTR && errno != EAGAIN { exit(0) }
    }
    // Written to the terminal first: the copy never holds a byte the terminal can't have.
    if fd == STDOUT_FILENO, tee >= 0 { writeAll(bytes, to: tee) }
}

if let seconds = options["dump"].flatMap(Double.init) {
    let cols = Int(options["cols"] ?? "120") ?? 120, rows = Int(options["rows"] ?? "40") ?? 40
    writeAll(ClaudeSim.dump(seconds: seconds, cols: cols, rows: rows, mode: mode, seed: seed))
    exit(0)
}

// Raw mode like a real TUI, so the terminal's replies to our probes are not echoed back.
var settings = termios()
if tcgetattr(STDIN_FILENO, &settings) == 0 {
    cfmakeraw(&settings)
    tcsetattr(STDIN_FILENO, TCSANOW, &settings)
}

func windowSize() -> (cols: Int, rows: Int) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return (120, 40) }
    return (Int(size.ws_col), Int(size.ws_row))
}

let size = windowSize()
var sim = ClaudeSim(cols: size.cols, rows: size.rows, mode: mode, seed: seed)
let queue = DispatchQueue(label: "fake-agent")

signal(SIGWINCH, SIG_IGN)
let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
resize.setEventHandler {
    let size = windowSize()
    writeAll(sim.resize(cols: size.cols, rows: size.rows))
}
resize.resume()

// Drain input (keys, the terminal's replies) so the PTY never fills up.
let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
input.setEventHandler {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(STDIN_FILENO, &buffer, buffer.count)
    if count == 0 { exit(0) }
    if buffer[0..<max(0, count)].contains(3) { exit(0) }  // Ctrl+C in raw mode
}
input.resume()

func step() {
    if let until, FileManager.default.fileExists(atPath: until) { return }
    let chunk = sim.next()
    if idle {
        writeAll(chunk.bytes)
        return
    }
    queue.asyncAfter(deadline: .now() + chunk.delay / speed) {
        writeAll(chunk.bytes)
        step()
    }
}
queue.async { step() }
dispatchMain()
