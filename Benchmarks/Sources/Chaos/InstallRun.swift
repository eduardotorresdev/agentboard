import AgentRuntime
import Darwin
import Foundation

/// `./install`, first and again, while agents run: in a folder of its own (`INSTALL_DIR`) on a
/// data folder of its own. The first install takes the agents over from a checkout's core (as
/// the developer's are when they first install), the second updates the installed app in place.
/// Both times the installed core must take the agents over and the relaunched app show every
/// card; at the end the app's terminals and the core's must be exactly what each program
/// wrote, every message must have arrived once, every call answered, every program the same.
@MainActor
func installRun(agentCount: Int) async -> Bool {
    let bench: AppBench
    do { bench = try AppBench(core: coreBinary, agentCount: agentCount, seed: seed) } catch {
        say("Couldn't make a data folder: \(error)")
        return false
    }
    let apps = bench.instance.home.appendingPathComponent("Applications")
    // As its command line has it: the real path (/private/var, not /var).
    let installed = "/private" + apps.appendingPathComponent("AgentBoard.app/Contents/MacOS/AgentBoard").path
    say("install: \(agentCount) agents, installing into \(apps.path)")
    if let problem = await bench.prepare() {
        say("FAIL: \(problem)")
        return false
    }
    defer { _ = shell("defaults delete dev.agentboard.AgentBoard") }
    var failures: [String] = []
    var environment = bench.appEnvironment
    environment["INSTALL_DIR"] = apps.path
    let log = bench.instance.home.appendingPathComponent("install.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    func install() async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [repository.appendingPathComponent("install").path]
            process.environment = environment
            let output = try? FileHandle(forWritingTo: log)
            output?.seekToEndOfFile()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
    func appPID() -> Int32? { Int32(shellOutput("pgrep -f '^\(installed)$'").split(separator: "\n").first ?? "") }

    var previous: Int32?
    for (index, step) in ["first install", "update"].enumerated() {
        let start = Date()
        guard await install() else {
            failures.append("\(step): ./install failed; see \(log.path)")
            break
        }
        let took = Date().timeIntervalSince(start)
        guard let attached = await bench.coreLog.boardAttached(to: bench.ids, after: start, timeout: 60) else {
            failures.append("\(step): the installed app never showed every card")
            break
        }
        let pid = appPID()
        let tookOver = bench.coreLog.lines(after: start).contains { $0.contains("took over") && $0.contains("sessions") }
        say(String(format: "%@: ./install took %.1f s, every card shown %.1f s after it began, app pid %d%@", step, took,
                   attached.at.timeIntervalSince(start), pid ?? 0, tookOver ? ", agents taken over by the installed core" : ""))
        if !tookOver { failures.append("\(step): the installed core didn't take the agents over") }
        if pid == nil { failures.append("\(step): the installed app isn't running") }
        if index > 0, pid == previous { failures.append("\(step): the app wasn't relaunched") }
        previous = pid
        if index == 0 { bench.begin() }
        try? await Task.sleep(for: .seconds(index == 0 ? 5 : 15))
    }
    failures += await bench.finish(appPID: appPID())
    for failure in failures { say("FAIL: \(failure)") }
    if failures.isEmpty { say("PASS") } else { say("data kept in \(bench.instance.home.path)") }
    bench.remove(keeping: !failures.isEmpty)
    return failures.isEmpty
}
