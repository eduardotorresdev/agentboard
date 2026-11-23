import Foundation
import Testing

/// `scripts/assemble-app`, as ./install runs it, on stand-in programs in a temporary folder: the
/// app's executable stays the app's, and the host program sits beside it under its own name. On a
/// case-insensitive disk a host program named "agentboard" took the app's place once.
@Test func theAppBundleKeepsItsExecutableAndTheHostProgramApart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("assemble-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin"), app = root.appendingPathComponent("AgentBoard.app")
    try FileManager.default.createDirectory(at: bin.appendingPathComponent("AgentBoard_AgentBoard.bundle"), withIntermediateDirectories: true)
    for name in ["AgentBoard", "AgentBoardCore", "libBrowserInjection.dylib", "simulator-host"] {
        try Data("the \(name) program".utf8).write(to: bin.appendingPathComponent(name))
    }
    let host = root.appendingPathComponent("agentboard")
    try Data("the host program".utf8).write(to: host)

    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = repo.appendingPathComponent("scripts/assemble-app")
    process.arguments = [bin.path, host.path, app.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let programs = app.appendingPathComponent("Contents/MacOS")
    #expect(try String(contentsOf: programs.appendingPathComponent("AgentBoard"), encoding: .utf8) == "the AgentBoard program")
    #expect(try String(contentsOf: programs.appendingPathComponent("agentboard-host"), encoding: .utf8) == "the host program")
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("AgentBoard_AgentBoard.bundle").path))
}
