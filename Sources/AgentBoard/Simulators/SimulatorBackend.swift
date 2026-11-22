import Foundation
import QuartzCore

enum SimulatorPlatform: String, Sendable, CaseIterable {
    case ios, android

    var title: String { self == .ios ? "iOS Simulator" : "Android emulator" }
    var defaultDeviceType: String { self == .ios ? "iPhone 17" : AndroidEmulators.deviceTypes[0].name }
    /// A screen size to lay a card out with before its device reports its own: points on iOS,
    /// pixels on Android.
    var defaultSize: CGSize { self == .ios ? CGSize(width: 402, height: 874) : AndroidEmulators.deviceTypes[0].size }
}

/// A device a card opened.
struct SimulatorOpened {
    var device: String
    var runtime: String
    /// What finds the same device on the next launch (a UDID, an AVD name), kept in the record.
    var persistent: String?
    /// What command-line tools take for it: the UDID for simctl, the serial for `adb -s`.
    var address: String
}

/// What drives a card's device: the iOS sidecar (`IOSSimulators`) or an Android emulator
/// (`AndroidEmulators`). Points are in the device's screen units (points on iOS, pixels on
/// Android), as snapshots give them.
@MainActor
protocol SimulatorBackend: AnyObject {
    /// The card's screen content changed (nil: none for now) or its size did.
    var onScreen: ((UUID, SimulatorScreen.Content?, CGSize?) -> Void)? { get set }
    /// Something the card can't recover from by itself went wrong after it opened.
    var onFailure: ((UUID, SimulatorHost.Failure) -> Void)? { get set }

    /// Boots the card's device, or finds it running; `pixels` is the card's size on this Mac's
    /// screen, which a video stream is encoded near.
    func open(_ record: SimulatorRecord, pixels: Int) async throws -> SimulatorOpened
    /// Shuts the device down; `deleting` also removes what the card made for it.
    func close(_ record: SimulatorRecord, deleting: Bool) async
    /// The card is on screen again, or isn't any more: a stream can stop meanwhile.
    func show(_ card: UUID)
    func hide(_ card: UUID)
    /// Makes sure input reaches the open device even while its card isn't shown.
    func connect(_ card: UUID) async throws
    func touch(_ card: UUID, _ phase: String, at point: CGPoint)
    /// `delta` is how far the content moves.
    func scroll(_ card: UUID, at point: CGPoint, by delta: CGSize)
    /// A key of the user's keyboard by HID usage, with the characters it types if any.
    func key(_ card: UUID, usage: Int, down: Bool, characters: String?)
    func button(_ card: UUID, _ name: String) throws
    func type(_ card: UUID, _ text: String) async throws
    /// The screen's elements: role, depth, frame [x, y, w, h], label, value.
    func snapshot(_ card: UUID) async throws -> [[String: Any]]
    /// Saves a JPEG of the screen to `path` and returns it.
    func screenshot(_ card: UUID, to path: String) async throws -> Data
    func deviceTypes(for record: SimulatorRecord) async -> [String]
    /// The board is quitting.
    func quit()
}

/// iOS Simulator devices through the `simulator-host` sidecar, on this Mac only.
@MainActor
final class IOSSimulators: SimulatorBackend {
    var onScreen: ((UUID, SimulatorScreen.Content?, CGSize?) -> Void)?
    var onFailure: ((UUID, SimulatorHost.Failure) -> Void)?
    let host = SimulatorHost()
    var cards: Set<UUID> = []
    /// Watched cards the sidecar was asked to stream; a restarted one forgets them, and is
    /// asked again once the card's screen is back.
    private(set) var streaming: Set<UUID> = []
    private var types: [String] = []
    /// Card streams (StreamServer) watching each card.
    let taps = StreamTaps()

    init() {
        host.onEvent = { [weak self] event in self?.received(event) }
        host.onStateChange = { [weak self] state in
            guard let self else { return }
            if state != .running { self.sidecarEnded() }
            guard case .failed(let reason) = state else { return }
            for card in self.cards { self.onFailure?(card, SimulatorHost.Failure(message: reason)) }
        }
    }

    func open(_ record: SimulatorRecord, pixels: Int) async throws -> SimulatorOpened {
        if case .failed = host.state { host.retry() }
        var params: [String: Any] = ["card": record.id.uuidString, "deviceType": record.deviceType]
        if let udid = record.udid { params["udid"] = udid }
        cards.insert(record.id)
        let result = try await host.request("open", params)
        let udid = result["udid"] as? String ?? record.udid ?? ""
        return SimulatorOpened(device: result["deviceType"] as? String ?? record.deviceType, runtime: result["runtime"] as? String ?? "",
                               persistent: udid, address: udid)
    }

    func close(_ record: SimulatorRecord, deleting: Bool) async {
        cards.remove(record.id)
        _ = try? await host.request("close", ["card": record.id.uuidString])
    }

    func show(_ card: UUID) {}
    func hide(_ card: UUID) {}
    func connect(_ card: UUID) async throws {}

    func touch(_ card: UUID, _ phase: String, at point: CGPoint) {
        host.post("touch", ["card": card.uuidString, "phase": phase, "x": point.x, "y": point.y])
    }

    func scroll(_ card: UUID, at point: CGPoint, by delta: CGSize) {
        host.post("scroll", ["card": card.uuidString, "x": point.x, "y": point.y, "dx": delta.width, "dy": delta.height])
    }

    func key(_ card: UUID, usage: Int, down: Bool, characters: String?) {
        host.post("key", ["card": card.uuidString, "usage": usage, "down": down])
    }

    func button(_ card: UUID, _ name: String) throws {
        host.post("button", ["card": card.uuidString, "name": name])
    }

    func type(_ card: UUID, _ text: String) async throws {
        _ = try await host.request("type", ["card": card.uuidString, "text": text])
    }

    /// A named key or button for `simulator_press`, which the sidecar checks.
    func press(_ card: UUID, _ name: String) async throws {
        _ = try await host.request("key", ["card": card.uuidString, "name": name])
    }

    func snapshot(_ card: UUID) async throws -> [[String: Any]] {
        try await host.request("snapshot", ["card": card.uuidString])["elements"] as? [[String: Any]] ?? []
    }

    func screenshot(_ card: UUID, to path: String) async throws -> Data {
        let result = try await host.request("screenshot", ["card": card.uuidString, "path": path])
        return (result["image"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
    }

    func deviceTypes(for record: SimulatorRecord) async -> [String] { await types() }

    /// The device types the installed runtime supports, read once.
    func types() async -> [String] {
        if types.isEmpty, let list = (try? await host.request("devices", [:]))?["deviceTypes"] as? [[String: Any]] {
            types = list.compactMap { $0["name"] as? String }
        }
        return types
    }

    func quit() {}

    /// Sends the card's screen to a card stream: H.264 from the sidecar, input in points.
    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)? {
        guard cards.contains(card) else { return nil }
        let id = taps.add(card, sink)
        requestKeyFrame(card)
        return { [weak self] in
            guard let self, self.taps.remove(card, id) else { return }
            self.streaming.remove(card)
            self.host.post("stream", ["card": card.uuidString, "on": false])
        }
    }

    /// Asks the sidecar to stream the card, which also sends a keyframe now.
    func requestKeyFrame(_ card: UUID) {
        streaming.insert(card)
        host.post("stream", ["card": card.uuidString, "on": true])
    }

    /// The sidecar stopped: its screens and their encoders are gone.
    func sidecarEnded() {
        for card in streaming { taps.reset(card) }
        streaming.removeAll()
    }

    func received(_ event: [String: Any]) {
        guard let card = (event["card"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        if event["event"] as? String == "video" {
            if let data = (event["data"] as? String).flatMap({ Data(base64Encoded: $0) }) { taps.send(card, .video(data)) }
            return
        }
        guard event["event"] as? String == "surface", let context = (event["contextID"] as? NSNumber)?.uint32Value else { return }
        let size = (event["width"] as? Double).flatMap { width in (event["height"] as? Double).map { CGSize(width: width, height: $0) } }
        if let size { taps.send(card, .header(.init(kind: "h264", width: size.width, height: size.height, units: "points"))) }
        // The screen is back after the sidecar restarted: stream it again.
        if taps.watched(card), !streaming.contains(card) { requestKeyFrame(card) }
        onScreen?(card, .context(context), size)
    }
}
