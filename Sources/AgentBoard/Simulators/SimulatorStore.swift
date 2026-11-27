import AgentRuntime
import AppKit
import Connections
import Foundation
import Observation
import Orchestration

/// A persisted simulator card: an iOS Simulator device (this Mac only) or an Android emulator
/// (this Mac or the host its worktree is on).
struct SimulatorRecord: Identifiable, Hashable {
    let id: UUID
    let worktree: String
    /// How the card is titled and how connected agents address it; unique in its worktree.
    var name: String
    /// What finds its device again on the next launch: the iOS device's UDID, the Android
    /// emulator's AVD name; nil until it has one.
    var udid: String?
    /// The device type it asks for (“iPhone 17”, “Pixel 7”).
    var deviceType: String
    var frame: CGRect
    var organization: UUID = OrganizationHome.defaultID
    var platform: SimulatorPlatform = .ios
    /// The host its worktree is on (nil: this Mac), where an Android emulator runs.
    var host: UUID?
}

/// A simulator card's live device.
struct SimulatorScreen {
    enum Phase: Equatable {
        case opening
        case open
        case failed(String)
        /// Xcode isn't installed: nothing to do from here.
        case noXcode
        /// Xcode is, but no iOS runtime: the card offers to download one.
        case noRuntime
        /// No Android SDK (or system image) on the machine: the card offers to install it.
        case noSDK
        /// Linux without a usable /dev/kvm (`denied`: it exists but the user can't open it).
        case noAcceleration(denied: Bool)
        /// Too little free memory to boot without swapping, in MB.
        case lowMemory(Int)
        /// The host can't be reached.
        case unreachable
    }

    /// What shows the device's screen.
    enum Content {
        /// Another process's Core Animation context (the iOS sidecar's), hosted by id.
        case context(UInt32)
        /// A layer of this process (an Android video stream's).
        case layer(CALayer)
    }

    var phase = Phase.opening
    var content: Content?
    /// The screen in the device's units: points on iOS, pixels on Android.
    var size: CGSize?
    var device = ""
    var runtime = ""
    /// What command-line tools take: the UDID for simctl, the serial for `adb -s`.
    var address = ""
}

/// Owns every simulator card and its device. A card boots its device the first time it is
/// shown or an agent drives it, and shuts it down when it is closed. What drives a device is
/// its platform's backend; everything else here is shared.
@MainActor
@Observable
final class SimulatorStore {
    private(set) var simulators: [SimulatorRecord] = []
    @ObservationIgnored private(set) var screens: [UUID: SimulatorScreen] = [:]
    /// Called with the card's id when its screen changed, so the board redraws it.
    @ObservationIgnored var onScreenChange: ((UUID) -> Void)?
    /// The iOS runtime being downloaded, or the Android SDK installed on a machine (nil: this
    /// Mac), with its progress line.
    private(set) var downloading: String?
    private(set) var installing: [UUID?: String] = [:]

    @ObservationIgnored private let database: Database?
    @ObservationIgnored let ios = IOSSimulators()
    @ObservationIgnored let android = AndroidEmulators()
    /// Opens a stream to a port on a host's loopback (`HostProxy.opener`); set by the app.
    @ObservationIgnored var openStream: HostProxy.Open?
    /// The stores the cards are on, by their worktree's host (nil: this Mac's).
    @ObservationIgnored private var boards: [UUID?: Board] = [:]
    @ObservationIgnored private var opening: [UUID: Task<Void, Error>] = [:]
    /// Each card's refs from its latest snapshot: element frames in screen units.
    @ObservationIgnored private var refs: [UUID: [String: CGRect]] = [:]

    private struct Board { weak var store: AgentStore? }

    init(database: Database?) {
        self.database = database
        simulators = (try? database?.simulators()) ?? []
        for backend in [ios, android] as [SimulatorBackend] {
            backend.onScreen = { [weak self] card, content, size in self?.received(card, content: content, size: size) }
            backend.onFailure = { [weak self] card, failure in self?.failed(card, failure) }
        }
        android.machine = { [weak self] record in self?.machine(for: record) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.android.quit() }
        }
    }

    private func agents(_ host: UUID? = nil) -> AgentStore? { boards[host]?.store }

    func backend(_ platform: SimulatorPlatform) -> SimulatorBackend { platform == .ios ? ios : android }

    private func backend(of id: UUID) -> SimulatorBackend { backend(record(id)?.platform ?? .ios) }

    /// Where a card's Android emulator runs.
    func machine(for record: SimulatorRecord) -> Machine? {
        guard let host = record.host else { return .local }
        guard let store = agents(host), let open = openStream else { return nil }
        return Machine.host(host, name: store.host?.name ?? "the host",
                            run: { [weak store] executable, arguments in await store?.run(executable, arguments) }, open: open)
    }

    var ids: Set<UUID> { Set(simulators.map(\.id)) }

    /// Puts the cards on `agents`' board: lines reach the cards of its machine, and agents get the
    /// tools (on a host, for its Android emulators).
    func attach(to agents: AgentStore) {
        let host = agents.host?.id
        boards[host] = Board(store: agents)
        agents.simulatorTools = SimulatorTools(store: self, agents: agents)
        agents.elementSources[ElementKind.simulator.rawValue] = { [weak self] in self?.elementInfos(on: host) ?? [] }
        agents.elementRemovers[ElementKind.simulator.rawValue] = { [weak self] in self?.remove($0) }
        agents.elementMovers[ElementKind.simulator.rawValue] = { [weak self] id, point in
            if let frame = self?.record(id)?.frame { self?.setFrame(CGRect(origin: point, size: frame.size), for: id, persist: true) }
        }
        agents.elementsChanged()
    }

    private func elementInfos(on host: UUID?) -> [ElementInfo] {
        simulators.filter { $0.host == host }.map { record in
            ElementInfo(id: record.id, name: record.name, kind: ElementKind.simulator.rawValue,
                        detail: SimulatorElement(id: record.id, store: self).detail,
                        worktree: record.worktree, frame: record.frame, organization: record.organization)
        }
    }

    func simulators(in worktree: String, on host: UUID? = nil) -> [SimulatorRecord] {
        let organization = agents(host)?.organizationID ?? agents()?.organizationID ?? OrganizationHome.defaultID
        return simulators.filter { $0.worktree == worktree && $0.organization == organization && $0.host == host }
    }

    func record(_ id: UUID) -> SimulatorRecord? {
        simulators.first { $0.id == id }
    }

    // MARK: Layout

    /// The card's frame for a screen of `size` shown at `scale`.
    nonisolated static func frame(for size: CGSize, at origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: (size.width * scale).rounded() + CardMetrics.inset * 2,
               height: (size.height * scale).rounded() + CardMetrics.titleHeight + CardMetrics.inset)
    }

    /// The scale a new card shows its screen at: tall enough to use, short enough for a laptop.
    nonisolated static func initialScale(for size: CGSize) -> CGFloat {
        min(1, 640 / size.height, 720 / size.width)
    }

    /// The screen size a card lays out with: its device's, or its platform's default until known.
    func screenSize(of id: UUID) -> CGSize {
        screens[id]?.size ?? deviceSize(of: record(id))
    }

    private func deviceSize(of record: SimulatorRecord?) -> CGSize {
        guard let record else { return SimulatorPlatform.ios.defaultSize }
        return record.platform == .android ? AndroidEmulators.deviceType(named: record.deviceType).size : record.platform.defaultSize
    }

    /// Card points per screen unit.
    func zoom(of record: SimulatorRecord) -> CGFloat {
        CardMetrics.content(of: record.frame).width / max(1, screenSize(of: record.id).width)
    }

    /// A point in the card's content (board coordinates) as a point in screen units.
    nonisolated static func devicePoint(_ point: CGPoint, content: CGRect, screen: CGSize) -> CGPoint {
        let zoom = content.width / max(1, screen.width)
        return CGPoint(x: min(max((point.x - content.minX) / zoom, 0), screen.width),
                       y: min(max((point.y - content.minY) / zoom, 0), screen.height))
    }

    // MARK: Cards

    @discardableResult
    func add(_ platform: SimulatorPlatform = .ios, deviceType: String? = nil, to worktree: String, on host: UUID? = nil, at origin: CGPoint,
             organization: UUID? = nil, named name: String? = nil, udid: String? = nil, frame: CGRect? = nil) -> SimulatorRecord {
        let organization = organization ?? agents(host)?.organizationID ?? OrganizationHome.defaultID
        let deviceType = platform == .android ? AndroidEmulators.deviceType(named: deviceType ?? "").name : deviceType ?? platform.defaultDeviceType
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let siblings = simulators.filter { $0.worktree == worktree && $0.organization == organization && $0.host == host }
        let size = platform == .android ? AndroidEmulators.deviceType(named: deviceType).size : platform.defaultSize
        let record = SimulatorRecord(id: UUID(), worktree: worktree,
                                     name: Self.uniqueName(trimmed.isEmpty ? deviceType : trimmed, among: siblings),
                                     udid: udid, deviceType: deviceType,
                                     frame: frame ?? Self.frame(for: size, at: origin, scale: Self.initialScale(for: size)),
                                     organization: organization, platform: platform, host: host)
        simulators.append(record)
        try? database?.saveSimulator(record)
        agents(host)?.elementsChanged()
        return record
    }

    /// Takes the card off the board and shuts its device down. An iOS device stays installed;
    /// an Android card's AVD goes with it.
    func remove(_ id: UUID) {
        guard let record = record(id) else { return }
        agents(record.host)?.dropConnections(touching: id)
        simulators.removeAll { $0.id == id }
        opening[id]?.cancel()
        opening[id] = nil
        refs[id] = nil
        let backend = backend(record.platform)
        // An Android card may have made an AVD without being opened in this run.
        if screens.removeValue(forKey: id) != nil || record.platform == .android {
            Task { await backend.close(record, deleting: true) }
        }
        try? database?.deleteSimulator(id: id)
        agents(record.host)?.elementsChanged()
    }

    func raise(_ id: UUID) {
        guard let index = simulators.firstIndex(where: { $0.id == id }), index != simulators.count - 1 else { return }
        simulators.append(simulators.remove(at: index))
    }

    func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = simulators.firstIndex(where: { $0.id == id }) else { return }
        simulators[index].frame = frame
        if persist {
            try? database?.saveSimulator(simulators[index])
            agents(simulators[index].host)?.elementsChanged()
        }
    }

    /// Moves the card to another device type: the old device shuts down and one of the new type
    /// boots. A card still named after its old device takes the new one's name.
    func setDeviceType(_ deviceType: String, for id: UUID) {
        guard let index = simulators.firstIndex(where: { $0.id == id }), simulators[index].deviceType != deviceType else { return }
        let old = simulators[index]
        simulators[index].deviceType = deviceType
        simulators[index].udid = nil
        if old.name == old.deviceType || old.name.hasPrefix(old.deviceType + " ") {
            simulators[index].name = Self.uniqueName(deviceType, among: simulators(in: old.worktree, on: old.host).filter { $0.id != id })
        }
        try? database?.saveSimulator(simulators[index])
        agents(old.host)?.elementsChanged()
        guard screens[id] != nil || old.platform == .android else { return }
        let wasShown = screens[id] != nil
        opening[id]?.cancel()
        opening[id] = nil
        screens[id] = nil
        refs[id] = nil
        onScreenChange?(id)
        let backend = backend(old.platform)
        Task {
            await backend.close(old, deleting: old.platform == .android)
            if wasShown { show(id) }
        }
    }

    private static func uniqueName(_ base: String, among others: [SimulatorRecord]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// The device types the card's menu offers.
    func deviceTypes(for record: SimulatorRecord) async -> [String] {
        await backend(record.platform).deviceTypes(for: record)
    }

    // MARK: Devices

    /// Boots the card's device if it isn't open or opening, or brings its screen back.
    func show(_ id: UUID) {
        guard screens[id] == nil else { return backend(of: id).show(id) }
        Task { try? await ready(id) }
    }

    /// The card left the screen: a video stream stops until it is back.
    func hide(_ id: UUID) {
        guard screens[id]?.phase == .open else { return }
        backend(of: id).hide(id)
    }

    /// Tries a card that failed again.
    func reopen(_ id: UUID) {
        switch screens[id]?.phase {
        case .failed, .noXcode, .lowMemory, .unreachable, .noSDK: break
        default: return
        }
        screens[id] = nil
        opening[id] = nil
        show(id)
    }

    /// Waits until the card's device is booted and its screen is up, booting it if needed.
    func ready(_ id: UUID) async throws {
        switch screens[id]?.phase {
        case .open: return
        case .opening, nil: break
        case let phase?: throw SimulatorHost.Failure(message: Self.explanation(of: phase, record: record(id)))
        }
        if let task = opening[id] { return try await task.value }
        guard let record = record(id) else { throw SimulatorHost.Failure(message: "This simulator is no longer on the board.") }
        screens[id] = SimulatorScreen()
        onScreenChange?(id)
        let backend = backend(record.platform)
        let content = CardMetrics.content(of: record.frame)
        let pixels = Int(max(content.width, content.height) * (NSScreen.main?.backingScaleFactor ?? 2))
        let task = Task { @MainActor in
            do {
                let opened = try await backend.open(record, pixels: pixels)
                guard screens[id] != nil else { return }
                screens[id]?.phase = .open
                screens[id]?.device = opened.device
                screens[id]?.runtime = opened.runtime
                screens[id]?.address = opened.address
                if let persistent = opened.persistent, let index = simulators.firstIndex(where: { $0.id == id }), simulators[index].udid != persistent {
                    simulators[index].udid = persistent
                    try? database?.saveSimulator(simulators[index])
                }
                onScreenChange?(id)
                agents(record.host)?.elementsChanged()
            } catch {
                guard screens[id] != nil else { throw error }
                let failure = error as? SimulatorHost.Failure
                screens[id]?.phase = switch failure?.code {
                case "noXcode": .noXcode
                case "noRuntime": .noRuntime
                case "noSDK": .noSDK
                case "noAcceleration": .noAcceleration(denied: failure?.message == "kvmDenied")
                case "lowMemory": .lowMemory(Int(failure?.message ?? "") ?? 0)
                case "unreachable": .unreachable
                default: .failed(error.localizedDescription)
                }
                onScreenChange?(id)
                throw SimulatorHost.Failure(message: Self.explanation(of: screens[id]!.phase, record: record), code: failure?.code)
            }
        }
        opening[id] = task
        defer { opening[id] = nil }
        try await task.value
    }

    /// Why a card's device isn't up, for an agent.
    private static func explanation(of phase: SimulatorScreen.Phase, record: SimulatorRecord?) -> String {
        let place = record?.host == nil ? "this Mac" : "the host"
        return switch phase {
        case .failed(let reason): reason
        case .noXcode: "Xcode isn't installed on this Mac."
        case .noRuntime: "No iOS runtime is installed. The user can download one from the card."
        case .noSDK: "The Android SDK isn't installed on \(place). The user can install it from the card."
        case .noAcceleration: "The Android emulator can't run on \(place): it has no usable KVM (/dev/kvm)."
        case .lowMemory(let free): "Not enough free memory on \(place) to start the emulator (\(free) MB free, it needs \(AndroidEmulators.guestMemory + AndroidEmulators.memoryMargin) MB). Close something there, then try again."
        case .unreachable: "The host can't be reached."
        case .open, .opening: ""
        }
    }

    /// `ready`, and input reaches the device even if the card isn't on screen.
    func readyForInput(_ id: UUID) async throws {
        try await ready(id)
        try await backend(of: id).connect(id)
    }

    // MARK: Input

    /// A finger on the card at `point`, in screen units.
    func touch(_ id: UUID, _ phase: String, at point: CGPoint) {
        guard screens[id]?.phase == .open else { return }
        backend(of: id).touch(id, phase, at: point)
    }

    /// A wheel or trackpad scroll at `point`; `delta` is how far the content moves, in screen units.
    func scroll(_ id: UUID, at point: CGPoint, by delta: CGSize) {
        guard screens[id]?.phase == .open else { return }
        backend(of: id).scroll(id, at: point, by: delta)
    }

    /// A key going down or up, by HID usage, with the characters it types.
    func key(_ id: UUID, usage: Int, down: Bool, characters: String? = nil) {
        guard screens[id]?.phase == .open else { return }
        backend(of: id).key(id, usage: usage, down: down, characters: characters)
    }

    func button(_ id: UUID, _ name: String) {
        guard screens[id]?.phase == .open else { return }
        try? backend(of: id).button(id, name)
    }

    /// A key or button by name for an agent (`simulator_press`).
    func press(_ id: UUID, _ name: String) async throws {
        try await readyForInput(id)
        if record(id)?.platform == .ios { return try await ios.press(id, name) }
        try android.button(id, name)
    }

    func type(_ id: UUID, _ text: String) {
        guard screens[id]?.phase == .open else { return }
        let backend = backend(of: id)
        Task { try? await backend.type(id, text) }
    }

    func typeForAgent(_ id: UUID, _ text: String) async throws {
        try await readyForInput(id)
        try await backend(of: id).type(id, text)
    }

    // MARK: Agent view

    /// The screen's elements as text with fresh refs, which replace the card's old ones.
    func snapshot(_ id: UUID) async throws -> String {
        try await ready(id)
        let (text, refs) = Self.format(try await backend(of: id).snapshot(id))
        self.refs[id] = refs
        return text
    }

    func screenshot(_ id: UUID, to path: String) async throws -> Data {
        try await ready(id)
        return try await backend(of: id).screenshot(id, to: path)
    }

    /// The center of a ref from the card's latest snapshot.
    func point(of ref: String, on id: UUID) -> CGPoint? {
        refs[id].flatMap { Self.point(of: ref, in: $0) }
    }

    nonisolated static func point(of ref: String, in refs: [String: CGRect]) -> CGPoint? {
        refs[ref.trimmingCharacters(in: .whitespaces)].map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// One line per element, indented by depth: `e3 button "Settings" value [x,y,w,h]`.
    nonisolated static func format(_ elements: [[String: Any]]) -> (text: String, refs: [String: CGRect]) {
        guard !elements.isEmpty else {
            return ("The app on screen is still starting and has nothing to read yet. Try again in a few seconds.", [:])
        }
        var lines: [String] = []
        var refs: [String: CGRect] = [:]
        for (index, element) in elements.enumerated() {
            let ref = "e\(index + 1)"
            let numbers = (element["frame"] as? [Double]) ?? (element["frame"] as? [NSNumber])?.map(\.doubleValue) ?? []
            let frame = numbers.count == 4 ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : .zero
            refs[ref] = frame
            var role = (element["role"] as? String ?? "")
            if role.hasPrefix("AX") { role.removeFirst(2) }
            role = role.prefix(1).lowercased() + role.dropFirst()
            var line = String(repeating: "  ", count: element["depth"] as? Int ?? 0) + "\(ref) \(role.isEmpty ? "element" : role)"
            if let label = element["label"] as? String, !label.trimmingCharacters(in: .whitespaces).isEmpty { line += " \"\(label)\"" }
            if let value = element["value"] as? String, !value.isEmpty { line += " \(value)" }
            line += " [\([frame.minX, frame.minY, frame.width, frame.height].map { Self.number($0) }.joined(separator: ","))]"
            lines.append(line)
        }
        return (lines.joined(separator: "\n"), refs)
    }

    private nonisolated static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Backends

    private func received(_ card: UUID, content: SimulatorScreen.Content?, size: CGSize?) {
        guard screens[card] != nil else { return }
        screens[card]?.content = content
        if let size {
            if screens[card]?.size != size, let record = record(card) {
                // The card takes the device's shape, keeping its width.
                let zoom = CardMetrics.content(of: record.frame).width / size.width
                setFrame(Self.frame(for: size, at: record.frame.origin, scale: zoom), for: card, persist: true)
            }
            screens[card]?.size = size
        }
        onScreenChange?(card)
    }

    private func failed(_ card: UUID, _ failure: SimulatorHost.Failure) {
        guard screens[card] != nil else { return }
        screens[card]?.phase = .failed(failure.message)
        screens[card]?.content = nil
        onScreenChange?(card)
    }

    /// What the card says over its screen while it isn't showing one, or nil.
    func status(of id: UUID) -> String? {
        let android = record(id)?.platform == .android
        let starting = android ? L("Starting the emulator…") : L("Starting the simulator…")
        return switch screens[id]?.phase {
        case .open: screens[id]?.content == nil ? starting : nil
        case .failed(let reason): reason
        case .noXcode: L("Install Xcode from the App Store to run simulators.")
        case .noRuntime: downloading ?? L("No iOS runtime is installed. Click to download it (about 8 GB).")
        case .noSDK: installing[record(id)?.host] ?? L("The Android SDK isn't on this machine. Click to install it (about 4 GB).")
        case .noAcceleration(let denied): denied
            ? L("The emulator needs access to /dev/kvm on this machine: add your user to the kvm group, then reopen the card.")
            : L("This machine can't run the emulator: it has no hardware virtualization (/dev/kvm).")
        case .lowMemory: L("Not enough free memory on this machine to start the emulator. Click to try again.")
        case .unreachable: L("The host can't be reached. Click to try again.")
        case .opening, nil: starting
        }
    }

    /// Downloads the iOS runtime with `xcodebuild -downloadPlatform iOS`, then opens the cards
    /// that were waiting for it.
    func downloadRuntime() {
        guard downloading == nil else { return }
        downloading = L("Downloading iOS…")
        screens.keys.forEach { onScreenChange?($0) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild", "-downloadPlatform", "iOS"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let percent = Self.progress(in: text) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.downloading = L("Downloading iOS… \(percent)")
                self.screens.keys.forEach { self.onScreenChange?($0) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.downloading = nil
                for id in self.screens.keys where self.screens[id]?.phase == .noRuntime {
                    if status == 0 {
                        self.screens[id] = nil
                        self.show(id)
                    } else {
                        self.screens[id]?.phase = .failed(L("The iOS download failed (status \(Int(status))). Click to try again."))
                    }
                    self.onScreenChange?(id)
                }
            }
        }
        do {
            try process.run()
        } catch {
            downloading = nil
        }
    }

    /// Installs the Android SDK on the card's machine with the bundled script, run detached
    /// there; its log is read every two seconds for progress. Then opens the cards waiting.
    func installAndroidSDK(for id: UUID) {
        guard let record = record(id), installing[record.host] == nil, let machine = machine(for: record) else { return }
        guard let url = Bundle.module.url(forResource: "android-sdk", withExtension: "sh"), let script = try? String(contentsOf: url, encoding: .utf8) else { return }
        let host = record.host
        installing[host] = L("Installing the Android SDK…")
        screens.keys.forEach { onScreenChange?($0) }
        Task {
            let folder = "$HOME/.agentboard"
            let start = """
                mkdir -p "\(folder)" && cat > "\(folder)/android-sdk.sh" <<'AGENTBOARD_EOF'
                \(script)
                AGENTBOARD_EOF
                nohup sh "\(folder)/android-sdk.sh" > "\(folder)/android-sdk.log" 2>&1 < /dev/null &
                echo $!
                """
            let pid = (await machine.sh(start)).map { String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            var log = ""
            while !pid.isEmpty {
                try? await Task.sleep(for: .seconds(2))
                guard let ran = await machine.sh("tail -c 2000 \"\(folder)/android-sdk.log\"; kill -0 \(pid) 2>/dev/null && echo AGENTBOARD_RUNNING") else { continue }
                log = String(decoding: ran.output, as: UTF8.self)
                let step = log.split(whereSeparator: \.isNewline).last { $0.hasPrefix("progress=") }.map { String($0.dropFirst(9)) }
                let percent = Self.progress(in: log)
                installing[host] = [step ?? L("Installing the Android SDK…"), percent].compactMap { $0 }.joined(separator: " ")
                screens.keys.forEach { onScreenChange?($0) }
                if !log.contains("AGENTBOARD_RUNNING") { break }
            }
            installing[host] = nil
            let done = log.split(whereSeparator: \.isNewline).contains { $0 == "done" }
            for card in screens.keys where self.record(card)?.host == host && self.record(card)?.platform == .android && screens[card]?.phase == .noSDK {
                if done {
                    screens[card] = nil
                    show(card)
                } else {
                    let reason = log.split(whereSeparator: \.isNewline).last { !$0.hasPrefix("progress=") && !$0.contains("AGENTBOARD_RUNNING") }
                    screens[card]?.phase = .failed(L("Installing the Android SDK failed: \(String(reason ?? "")). Click to try again."))
                }
                onScreenChange?(card)
            }
        }
    }

    /// The last percentage in a download's output (“…: 12,5% (1 GB of 8 GB)”).
    nonisolated static func progress(in text: String) -> String? {
        guard let percent = try? Regex(#"\d+([.,]\d+)?%"#) else { return nil }
        return text.matches(of: percent).last.map { String(text[$0.range]) }
    }
}

/// A simulator as the message bus sees it: reachable along lines, driven with the simulator tools.
@MainActor
final class SimulatorElement: BoardElement {
    let id: UUID
    private weak var store: SimulatorStore?

    init(id: UUID, store: SimulatorStore) {
        self.id = id
        self.store = store
    }

    var name: String { store?.record(id)?.name ?? "" }
    var kind: ElementKind { .simulator }

    var detail: String? {
        guard let record = store?.record(id) else { return nil }
        let screen = store?.screens[id]
        let runtime = screen?.runtime.isEmpty == false ? ", \(screen!.runtime)" : ""
        return "\(record.platform.title): \(screen?.device.isEmpty == false ? screen!.device : record.deviceType)\(runtime)"
    }
}
