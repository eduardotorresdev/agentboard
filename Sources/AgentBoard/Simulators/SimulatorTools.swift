import Connections
import Foundation
import Orchestration

/// The simulator tools: an agent drives the simulator cards connected to it by a line. The core
/// lists them to agents (`SimulatorRelay`) and hands each call to the board, which runs it here.
@MainActor
final class SimulatorTools {
    private let store: SimulatorStore
    private unowned let agents: AgentStore

    init(store: SimulatorStore, agents: AgentStore) {
        self.store = store
        self.agents = agents
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        if name == "simulator_list" { return .text(list(for: caller)) }
        if name == "simulator_open" { return await open(arguments, caller: caller) }
        let simulator: SimulatorElement
        switch resolve(arguments["simulator"] as? String, for: caller) {
        case .success(let found): simulator = found
        case .failure(let message): return .error(message.text)
        }
        let id = simulator.id
        do {
            let text: String
            switch name {
            case "simulator_close":
                store.remove(id)
                return .text("Closed “\(simulator.name)”, shut down its device and removed its card.")
            case "simulator_snapshot":
                text = try await store.snapshot(id)
            case "simulator_screenshot":
                try FileManager.default.createDirectory(at: SimulatorHost.folder, withIntermediateDirectories: true)
                let path = SimulatorHost.folder.appendingPathComponent("\(simulator.name)-\(Int(Date().timeIntervalSince1970)).jpg").path
                let image = try await store.screenshot(id, to: path)
                var content: [ToolContent] = [.text("\(simulator.name): saved to \(path).")]
                if !image.isEmpty { content.append(.image(image, mimeType: "image/jpeg")) }
                return ToolResult(content)
            case "simulator_tap":
                try await store.readyForInput(id)
                let point = try point(arguments, on: id)
                let hold = max(0, arguments["duration"] as? Int ?? 0)
                store.touch(id, "down", at: point)
                try await Task.sleep(for: .milliseconds(max(hold, 40)))
                store.touch(id, "up", at: point)
                text = hold > 0 ? "Pressed for \(hold) ms." : "Tapped."
            case "simulator_swipe":
                try await store.readyForInput(id)
                try await swipe(arguments, on: id)
                text = "Swiped."
            case "simulator_type":
                guard let typed = arguments["text"] as? String else { return .error("simulator_type needs `text`.") }
                try await store.typeForAgent(id, typed + (arguments["submit"] as? Bool == true ? "\n" : ""))
                text = "Typed."
            case "simulator_press":
                guard let button = arguments["button"] as? String, !button.isEmpty else { return .error("simulator_press needs `button`.") }
                try await store.press(id, button)
                text = "Pressed \(button)."
            case "simulator_wait":
                text = try await wait(arguments, on: id)
            default:
                return .error("Unknown tool “\(name)”.")
            }
            return .text("\(simulator.name): \(text)")
        } catch {
            return .error("\(simulator.name): \(error.localizedDescription)")
        }
    }

    private struct Refusal: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Where a tap or swipe starts: a ref's center, or x/y.
    private func point(_ arguments: [String: Any], on id: UUID) throws -> CGPoint {
        if let target = arguments["target"] as? String, !target.isEmpty {
            guard let point = store.point(of: target, on: id) else {
                throw Refusal(text: "No element “\(target)” in the latest snapshot. Take a new simulator_snapshot.")
            }
            return point
        }
        guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue else {
            throw Refusal(text: "Give `target` (a ref from simulator_snapshot) or `x` and `y`.")
        }
        return CGPoint(x: x, y: y)
    }

    /// A drag as moves 16 ms apart, the pace SimulatorKit takes them at (and smooth on Android).
    private func swipe(_ arguments: [String: Any], on id: UUID) async throws {
        let size = store.screenSize(of: id)
        var start = (arguments["target"] != nil || arguments["x"] != nil) ? try point(arguments, on: id)
            : CGPoint(x: size.width / 2, y: size.height / 2)
        let end: CGPoint
        if let x = (arguments["toX"] as? NSNumber)?.doubleValue, let y = (arguments["toY"] as? NSNumber)?.doubleValue {
            end = CGPoint(x: x, y: y)
        } else {
            let half = CGSize(width: size.width / 2, height: size.height / 2)
            switch arguments["direction"] as? String {
            case "up":
                if arguments["target"] == nil, arguments["y"] == nil { start.y = size.height * 0.75 }
                end = CGPoint(x: start.x, y: max(1, start.y - half.height))
            case "down":
                if arguments["target"] == nil, arguments["y"] == nil { start.y = size.height * 0.25 }
                end = CGPoint(x: start.x, y: min(size.height - 1, start.y + half.height))
            case "left":
                if arguments["target"] == nil, arguments["x"] == nil { start.x = size.width * 0.85 }
                end = CGPoint(x: max(1, start.x - half.width), y: start.y)
            case "right":
                if arguments["target"] == nil, arguments["x"] == nil { start.x = size.width * 0.15 }
                end = CGPoint(x: min(size.width - 1, start.x + half.width), y: start.y)
            default:
                throw Refusal(text: "Give `direction` (up, down, left, right) or `toX` and `toY`.")
            }
        }
        let duration = max(50, arguments["duration"] as? Int ?? 300)
        let steps = max(2, duration / 16)
        store.touch(id, "down", at: start)
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(16))
            let t = CGFloat(step) / CGFloat(steps)
            store.touch(id, "move", at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        store.touch(id, "up", at: end)
    }

    private func wait(_ arguments: [String: Any], on id: UUID) async throws -> String {
        if let ms = arguments["ms"] as? Int, arguments["text"] == nil, arguments["textGone"] == nil {
            try await Task.sleep(for: .milliseconds(min(max(ms, 0), 60_000)))
            return "Waited \(ms) ms."
        }
        let shows = arguments["text"] as? String, gone = arguments["textGone"] as? String
        guard shows != nil || gone != nil else { return "Give `text`, `textGone` or `ms`." }
        let deadline = Date().addingTimeInterval(Double(min(max(arguments["timeout"] as? Int ?? 15_000, 0), 120_000)) / 1000)
        while true {
            let tree = try await store.snapshot(id)
            if let shows, tree.localizedCaseInsensitiveContains(shows) { return "“\(shows)” is on screen." }
            if let gone, !tree.localizedCaseInsensitiveContains(gone) { return "“\(gone)” is gone." }
            guard Date() < deadline else {
                throw Refusal(text: shows.map { "“\($0)” didn't appear in time." } ?? "“\(gone ?? "")” didn't go away in time.")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Adds a simulator next to the calling agent, connected to it, and boots it.
    private func open(_ arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard let agent = agents.record(caller) else { return .error("Only agents on the board can add simulators.") }
        let host = agents.host
        let platform: SimulatorPlatform
        switch (arguments["platform"] as? String)?.lowercased() {
        case nil, "": platform = host == nil ? .ios : .android
        case "ios": platform = .ios
        case "android": platform = .android
        case let other?: return .error("Unknown platform “\(other)”: use ios or android.")
        }
        if platform == .ios, let host {
            return .error("iOS Simulators run only on the Mac the board is on, and your worktree is on \(host.name). Use platform android here, or a worktree on this Mac for iOS.")
        }
        var device = (arguments["device"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
        if platform == .ios, let asked = device?.lowercased(), asked == "phone" || asked == "tablet" {
            device = asked == "phone" ? SimulatorPlatform.ios.defaultDeviceType : await store.ios.types().first { $0.hasPrefix("iPad") }
        }
        let screen = platform == .android ? AndroidEmulators.deviceType(named: device ?? "").size : platform.defaultSize
        let size = SimulatorStore.frame(for: screen, at: .zero, scale: SimulatorStore.initialScale(for: screen)).size
        let record = store.add(platform, deviceType: device, to: agent.worktree, on: host?.id, at: origin(near: agent, size: size),
                               organization: agent.organizationID, named: try? BoardName.argument(arguments["name"]).get())
        agents.connect(caller, record.id)
        do {
            try await store.ready(record.id)
            let screen = store.screens[record.id]
            let address = platform == .ios ? "UDID \(screen?.address ?? "unknown")" : "serial \(screen?.address ?? "unknown") (for adb -s)"
            return .text("Added \(platform.title) “\(record.name)”, connected to you: \(screen?.device ?? record.deviceType), \(screen?.runtime ?? ""), \(address). Booted.")
        } catch {
            return .error("Added simulator “\(record.name)”, connected to you, but its device didn't start: \(error.localizedDescription)")
        }
    }

    /// In the column right of the agent's card, below the cards in the way (see `BoardLayout`).
    private func origin(near agent: AgentRecord, size: CGSize) -> CGPoint {
        let worktree = agent.worktree
        let items = agents.agents.filter { $0.worktree == worktree }.map { BoardLayout.Item(id: $0.id, frame: $0.frame, isHub: $0.runner == nil) }
            + agents.postIts.filter { $0.worktree == worktree }.map { BoardLayout.Item(id: $0.id, frame: $0.frame, isHub: false) }
            + agents.images.filter { $0.worktree == worktree }.map { BoardLayout.Item(id: $0.id, frame: $0.frame, isHub: false) }
            + store.simulators.filter { $0.worktree == worktree && $0.host == agents.host?.id }.map { BoardLayout.Item(id: $0.id, frame: $0.frame, isHub: false) }
        return BoardLayout.slot(for: size, parent: agent.id, among: items, connections: agents.connections)
            ?? CGPoint(x: agent.frame.maxX + BoardLayout.columnGap, y: agent.frame.minY)
    }

    /// The simulators connected to `caller`, in connection order.
    private func peers(of caller: UUID) -> [SimulatorElement] {
        agents.connections.compactMap { $0.other(than: caller) }
            .filter { store.record($0) != nil }
            .map { SimulatorElement(id: $0, store: store) }
    }

    private func resolve(_ name: String?, for caller: UUID) -> Result<SimulatorElement, Refusal> {
        let simulators = peers(of: caller)
        guard !simulators.isEmpty else {
            return .failure(Refusal(text: "No simulator is connected to you. Add one with simulator_open, or ask the user to connect one by drawing a line between your card and a simulator card."))
        }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if let found = findElement(name, among: simulators, id: \.id, name: \.name) { return .success(found) }
            return .failure(Refusal(text: "No simulator named “\(name)” is connected to you. Connected: \(simulators.map(\.name).joined(separator: ", "))."))
        }
        guard simulators.count == 1, let only = simulators.first else {
            return .failure(Refusal(text: "Several simulators are connected; say which with `simulator`: \(simulators.map(\.name).joined(separator: ", "))."))
        }
        return .success(only)
    }

    private func list(for caller: UUID) -> String {
        let simulators = peers(of: caller)
        guard !simulators.isEmpty else { return "No simulator is connected to you. Add one with simulator_open." }
        let lines = simulators.map { simulator -> String in
            let record = store.record(simulator.id)
            let screen = store.screens[simulator.id]
            let state: String = switch screen?.phase {
            case .open: "booted"
            case .opening: "booting"
            case .failed(let reason): "failed: \(reason)"
            case .noXcode: "Xcode isn't installed"
            case .noRuntime: "no iOS runtime installed"
            case .noSDK: "the Android SDK isn't installed"
            case .noAcceleration: "the machine can't run the emulator (no KVM)"
            case .lowMemory: "not enough free memory to start"
            case .unreachable: "its host can't be reached"
            case nil: "not started (any simulator tool boots it)"
            }
            let device = screen?.device.isEmpty == false ? screen!.device : record?.deviceType ?? ""
            let runtime = screen?.runtime.isEmpty == false ? ", \(screen!.runtime)" : ""
            let address = screen?.address.isEmpty == false ? screen!.address : nil
            let id = record?.platform == .android ? "serial \(address ?? "none until booted") (for adb -s)" : "UDID \(address ?? record?.udid ?? "not created yet")"
            return "- \(simulator.name): \(record?.platform.title ?? "") \(device)\(runtime), \(id), \(state)"
        }
        return "Connected simulators:\n" + lines.joined(separator: "\n")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
