import Foundation
import Testing
@testable import AgentBoard
import AgentRuntime

/// Simulator cards: where a click lands on the device, how a snapshot names its elements, and
/// what the database keeps.
struct SimulatorTests {
    /// A click on the card lands on the same spot of the device screen at any card size, and
    /// a drag that leaves the card stays on the screen's edge.
    @Test func cardPointsBecomeDevicePoints() {
        let screen = CGSize(width: 402, height: 874)
        let content = CGRect(x: 100, y: 200, width: 201, height: 437)  // half size
        #expect(SimulatorStore.devicePoint(CGPoint(x: 100, y: 200), content: content, screen: screen) == .zero)
        #expect(SimulatorStore.devicePoint(CGPoint(x: 200.5, y: 418.5), content: content, screen: screen) == CGPoint(x: 201, y: 437))
        #expect(SimulatorStore.devicePoint(CGPoint(x: 50, y: 900), content: content, screen: screen) == CGPoint(x: 0, y: 874))
    }

    /// The card takes its device's shape: content proportional to the screen at the card's zoom.
    @Test func theCardFollowsTheScreen() {
        let frame = SimulatorStore.frame(for: CGSize(width: 402, height: 874), at: CGPoint(x: 10, y: 20), scale: 0.5)
        let content = CardMetrics.content(of: frame)
        #expect(frame.origin == CGPoint(x: 10, y: 20))
        #expect(content.width == 201)
        #expect(content.height == 437)
    }

    /// Each element gets a ref in reading order; a ref resolves to its element's center until the
    /// next snapshot, and an unknown one doesn't resolve.
    @Test func snapshotRefsResolveToCenters() {
        let elements: [[String: Any]] = [
            ["role": "AXApplication", "label": " ", "depth": 0, "frame": [0, 0, 402, 874]],
            ["role": "AXButton", "label": "Settings", "depth": 1, "frame": [306, 389, 68, 90.7]],
            ["role": "AXStaticText", "value": "18:25", "depth": 1, "frame": [51, 22, 45, 20]],
        ]
        let (text, refs) = SimulatorStore.format(elements)
        #expect(text == """
            e1 application [0,0,402,874]
              e2 button "Settings" [306,389,68,90.7]
              e3 staticText 18:25 [51,22,45,20]
            """)
        #expect(SimulatorStore.point(of: "e2", in: refs) == CGPoint(x: 340, y: 389 + 90.7 / 2))
        #expect(SimulatorStore.point(of: " e3 ", in: refs) == CGPoint(x: 73.5, y: 32))
        #expect(SimulatorStore.point(of: "e9", in: refs) == nil)
    }

    /// An app that hasn't loaded its accessibility yet gives no elements, and the agent is told
    /// to try again rather than handed an empty screen.
    @Test func anEmptyTreeSaysToRetry() {
        let (text, refs) = SimulatorStore.format([])
        #expect(text.contains("Try again"))
        #expect(refs.isEmpty)
    }

    @Test func downloadProgressReadsTheLastPercentage() {
        let output = "Downloading iOS 26.4 Simulator (23E244) (arm64): 4,1% (346,6 MB of 8,46 GB)Downloading iOS 26.4 Simulator (23E244) (arm64): 12.5% (1 GB of 8,46 GB)"
        #expect(SimulatorStore.progress(in: output) == "12.5%")
        #expect(SimulatorStore.progress(in: "Installing...") == nil)
    }

    /// Physical keys reach the device as HID usages: letters, digits, Return and the arrows.
    @Test func keysMapToHIDUsages() {
        #expect(SimulatorKeys.usage(forKeyCode: 0) == 0x04)   // a
        #expect(SimulatorKeys.usage(forKeyCode: 6) == 0x1d)   // z
        #expect(SimulatorKeys.usage(forKeyCode: 29) == 0x27)  // 0
        #expect(SimulatorKeys.usage(forKeyCode: 36) == 0x28)  // Return
        #expect(SimulatorKeys.usage(forKeyCode: 126) == 0x52) // Up
        #expect(SimulatorKeys.modifiers[56] == 0xe1)          // Shift
    }

    @Test func recordsSurviveTheDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absim-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try Database(url: url)
        let record = SimulatorRecord(id: UUID(), worktree: "/w", name: "iPhone 17", udid: nil, deviceType: "iPhone 17",
                                     frame: CGRect(x: 1, y: 2, width: 300, height: 600))
        try database.saveSimulator(record)
        var booted = record
        booted.udid = "2D2D375D-133B-43D1-B13B-A820FF038E7A"
        try database.saveSimulator(booted)
        #expect(try Database(url: url).simulators() == [booted])
        try database.deleteSimulator(id: record.id)
        #expect(try database.simulators().isEmpty)
    }
}

/// Whether an iOS runtime is installed, read once.
private let iOSRuntimeInstalled: Bool = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "list", "runtimes", "-j"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let runtimes = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["runtimes"] as? [[String: Any]] ?? []
    return runtimes.contains { $0["platform"] as? String == "iOS" && $0["isAvailable"] as? Bool == true }
}()

/// The sidecar against a real device: boots one headless, reads its screen, taps, types and
/// shuts it down. Needs an iOS runtime (`xcodebuild -downloadPlatform iOS`); skipped without one.
/// It uses (or creates) an iPhone in the default device set, like the app.
@Suite(.enabled(if: iOSRuntimeInstalled, "No iOS Simulator runtime is installed."), .serialized)
struct SimulatorHostTests {

    /// The sidecar speaking JSON lines, as `SimulatorHost` does.
    private final class Sidecar: @unchecked Sendable {
        let process = Process()
        private let input = Pipe(), output = Pipe()
        private var buffer = Data()
        private var nextID = 1

        init() throws {
            // Built next to the test bundle (AgentBoardTests depends on it).
            let folder = Bundle(for: Sidecar.self).bundleURL.deletingLastPathComponent()
            process.executableURL = folder.appendingPathComponent("simulator-host")
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            #expect(try line()["event"] as? String == "ready")
        }

        func line() throws -> [String: Any] {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    return try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
                buffer.append(chunk)
            }
        }

        func post(_ method: String, _ params: [String: Any]) throws {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["method": method, "params": params]) + Data("\n".utf8))
        }

        /// Sends a request and returns its reply, collecting the events that came before it.
        func request(_ method: String, _ params: [String: Any], events: inout [[String: Any]]) throws -> [String: Any] {
            let id = nextID
            nextID += 1
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data("\n".utf8))
            while true {
                let message = try line()
                if message["id"] as? Int == id { return message }
                events.append(message)
            }
        }

        func close() {
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }
    }

    @Test(.timeLimit(.minutes(5))) func drivesADevice() throws {
        let sidecar = try Sidecar()
        defer { sidecar.close() }
        var events: [[String: Any]] = []
        let card = UUID().uuidString

        let opened = try sidecar.request("open", ["card": card, "deviceType": "iPhone 17"], events: &events)
        let udid = try #require((opened["result"] as? [String: Any])?["udid"] as? String, "\(opened)")
        #expect(UUID(uuidString: udid) != nil)
        let surface = try #require(events.first { $0["event"] as? String == "surface" })
        #expect((surface["contextID"] as? Int ?? 0) != 0)
        let width = try #require(surface["width"] as? Double), height = try #require(surface["height"] as? Double)
        #expect(width > 300 && height > width)

        try sidecar.post("button", ["card": card, "name": "home"])
        // A freshly booted device draws the home screen's icons a while after it says it is up:
        // past 30 s on a loaded machine (a first boot, other suites running).
        var elements: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(90)
        while !elements.contains(where: { $0["role"] as? String == "AXButton" }), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            let snapshot = try sidecar.request("snapshot", ["card": card], events: &events)
            elements = try #require((snapshot["result"] as? [String: Any])?["elements"] as? [[String: Any]], "\(snapshot)")
        }
        #expect(elements.contains { $0["role"] as? String == "AXButton" }, "\(elements.prefix(12))")

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(card).jpg").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shot = try sidecar.request("screenshot", ["card": card, "path": path], events: &events)
        #expect(shot["error"] == nil, "\(shot)")
        #expect(FileManager.default.fileExists(atPath: path))

        // A tap and a typed line raise no error; their effect is checked by hand (see the card).
        try sidecar.post("touch", ["card": card, "phase": "down", "x": width / 2, "y": height / 2])
        try sidecar.post("touch", ["card": card, "phase": "up", "x": width / 2, "y": height / 2])
        #expect(try sidecar.request("type", ["card": card, "text": "Hi!"], events: &events)["error"] == nil)
        #expect(try sidecar.request("key", ["card": card, "name": "Home"], events: &events)["error"] == nil)

        #expect(try sidecar.request("close", ["card": card], events: &events)["error"] == nil)
    }
}
