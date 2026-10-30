import AgentRuntime
import Orchestration
import Darwin
import Foundation

// The core: runs the agents' programs on behalf of the board, and keeps the cards, the lines
// between them and the agents' tools, so all of it survives the board quitting, crashing or
// being rebuilt. The board launches it when none answers on the socket.
//
// `--take-over` replaces a running core (a newer build) without ending its programs: it takes
// every session, the socket and the lock from it (see `CoreHandoff`). Run from a terminal, it
// starts the new core detached and returns once that one serves, with status 0, or 1 if it
// couldn't take over. `--socket-path` prints where the core serves.

let socketPath = CoreProtocol.socketPath
let arguments = CommandLine.arguments.dropFirst()
// `--socket-path`: where this data folder's core serves, so a script can find that core.
if arguments.contains("--socket-path") {
    print(socketPath)
    exit(0)
}
let folder = (socketPath as NSString).deletingLastPathComponent
try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let takingOver = arguments.contains("--take-over")
/// Where the core tells the process that started it (`--take-over` from a terminal) it serves.
let readyFD = ProcessInfo.processInfo.environment["AGENTBOARD_CORE_READY_FD"].flatMap(Int32.init)

private let logTime: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(logTime.string(from: Date())) core[\(getpid())] \(message)\n".utf8))
}

/// Tells the process that started this one how it went: 0 failed, 1 serving, 2 serving what an
/// older core handed over.
func ready(_ ok: Bool) {
    guard let readyFD else { return }
    var byte: UInt8 = !ok ? 0 : inheritance == nil ? 1 : 2
    _ = write(readyFD, &byte, 1)
    close(readyFD)
}

/// Whether `pid` still runs: a zombie, which whoever launched it hasn't reaped yet, doesn't.
func isRunning(_ pid: pid_t) -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
    return info.kp_proc.p_stat != SZOMB
}

/// Runs this executable again with `--take-over` in its own session, logging where a core
/// launched by the board would, and waits for it to serve.
func takeOverDetached() -> Never {
    var pipeFDs: [Int32] = [0, 0]
    guard pipe(&pipeFDs) == 0 else { exit(1) }
    let log = DataFolder.url.appendingPathComponent("core.log").path
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], 3)
    var environment = ProcessInfo.processInfo.environment
    environment["AGENTBOARD_CORE_DETACHED"] = "1"
    environment["AGENTBOARD_CORE_READY_FD"] = "3"
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("--take-over"), nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0
    close(pipeFDs[1])
    guard spawned else {
        FileHandle.standardError.write(Data("Couldn't start the new core.\n".utf8))
        exit(1)
    }
    var byte: UInt8 = 0
    let got = read(pipeFDs[0], &byte, 1)
    guard got == 1, byte != 0 else {
        FileHandle.standardError.write(Data("The new core couldn't take over; see \(log).\n".utf8))
        exit(1)
    }
    print(byte == 2 ? "The new core (pid \(pid)) took over; every agent kept running." : "No core was running; started one (pid \(pid)).")
    exit(0)
}

if takingOver, ProcessInfo.processInfo.environment["AGENTBOARD_CORE_DETACHED"] != "1" { takeOverDetached() }

// One core per socket: a second one (two boards launching at once) leaves quietly, unless it
// was started to take over.
var lockFD = open(socketPath + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
var inheritance: Inheritance?
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    guard takingOver else {
        log("another core already serves \(socketPath)")
        exit(0)
    }
    if lockFD >= 0 { close(lockFD) }
    guard let inherited = CoreHandoff.takeOver(socketPath: socketPath, log: { log("taking over: \($0)") }) else {
        log("the running core didn't hand over")
        ready(false)
        exit(1)
    }
    inheritance = inherited
    lockFD = inherited.lock
    log("took over \(inherited.sessions.count) sessions from core[\(inherited.processID)]")
    // It exits right away; until then it would still answer a board that slipped in.
    let deadline = Date().addingTimeInterval(5)
    while isRunning(inherited.processID), Date() < deadline { usleep(2_000) }
}

// A board that goes away mid-write must not kill the core.
signal(SIGPIPE, SIG_IGN)

let server = CoreServer(socketPath: socketPath, queue: .main)
server.lock = lockFD
server.onLog = log
if let inheritance { server.adopt(inheritance.sessions) }
let orchestrator = MainActor.assumeIsolated { Orchestrator(server: server, inheriting: inheritance?.service, descriptors: inheritance?.serviceDescriptors ?? []) }
server.service = orchestrator
server.onExit = {
    log("exiting")
    unlink(socketPath)
    exit(0)
}
server.onHandedOff = {
    log("handed over to a newer core")
    exit(0)
}
do {
    try server.start(listening: inheritance?.listener)
} catch {
    log("could not listen on \(socketPath): \(error)")
    ready(false)
    exit(1)
}
log("listening on \(socketPath)")
ready(true)
// The run loop, not just the main queue: the runner monitor is a timer.
RunLoop.main.run()
