// The simulator sidecar: one process for every simulator card, and the only code that touches
// Apple's private simulator frameworks (loaded at runtime from the selected Xcode), so an Xcode
// change or a crash here never takes the app down.
//
// JSON lines on stdin/stdout, like the browser sidecar. Requests carry an `id` and get
// `{id, result}` or `{id, error, code}`; input (`touch`, `scroll`, `key`, `button`) comes
// without an id and gets no answer. Events: `ready`, and `surface {card, contextID, width,
// height, scale}` once a card's screen can be hosted with CALayerHost; `video {card, data, key}`
// (H.264 Annex B, base64) for each frame while `stream {card, on}` has a card stream on.
//
// The method names say nothing about iOS, so another platform's backend can speak them.
import AppKit
import CoreImage
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

// MARK: Wire

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

struct Failure: Error {
    let message: String
    /// Lets the card show the right state: `noXcode`, `noRuntime`.
    var code: String?
}

// MARK: Private API surface

@objc protocol ServiceContextClass { func sharedServiceContextForDeveloperDir(_ dir: String, error: NSErrorPointer) -> AnyObject? }
@objc protocol ServiceContext { func defaultDeviceSetWithError(_ error: NSErrorPointer) -> AnyObject? }
@objc protocol DeviceSet { var devices: [AnyObject] { get } }
@objc protocol SimDevice {
    var UDID: NSUUID { get }
    var io: AnyObject? { get }
    var deviceType: AnyObject? { get }
    func sendAccessibilityRequestAsync(_ request: AnyObject, completionQueue: DispatchQueue, completionHandler: @escaping (AnyObject?) -> Void)
}
@objc protocol DeviceType { var mainScreenScale: Float { get } }
@objc protocol IOClient { var ioPorts: [AnyObject] { get } }
@objc protocol IOPort { var descriptor: AnyObject? { get } }
@objc protocol DisplayState { var displayClass: UInt16 { get } }
@objc protocol Display {
    var state: AnyObject? { get }
    func registerScreenCallbacksWithUUID(_ uuid: NSUUID, callbackQueue: DispatchQueue,
                                         frameCallback: @escaping () -> Void,
                                         surfacesChangedCallback: @escaping (IOSurface?, IOSurface?) -> Void,
                                         propertiesChangedCallback: @escaping (AnyObject?) -> Void)
    func unregisterScreenCallbacksWithUUID(_ uuid: NSUUID)
}
@objc protocol HIDClientInit { func initWithDevice(_ device: AnyObject, error: NSErrorPointer) -> AnyObject? }
@objc protocol HIDClient {
    func sendWithMessage(_ message: UnsafeMutableRawPointer, freeWhenDone: Bool, completionQueue: DispatchQueue?, completion: ((NSError?) -> Void)?)
}
@objc protocol Translator {
    func frontmostApplicationWithDisplayId(_ displayId: UInt32, bridgeDelegateToken token: String) -> AnyObject?
    func macPlatformElementFromTranslation(_ translation: AnyObject) -> AnyObject?
}
@objc protocol CAContextClass { func remoteContextWithOptions(_ options: [String: Any]?) -> AnyObject }
@objc protocol RemoteContext { var layer: CALayer? { get set }; var contextId: UInt32 { get } }

func cast<T>(_ object: AnyObject, _: T.Type) -> T { unsafeBitCast(object, to: T.self) }

typealias MouseMessage = @convention(c) (UnsafePointer<CGPoint>?, UnsafePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32) -> UnsafeMutableRawPointer?
typealias ButtonMessage = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
typealias KeyMessage = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?

/// The frameworks, loaded once from the selected Xcode.
struct Frameworks {
    let developer: String
    let deviceSet: DeviceSet
    let mouse: MouseMessage
    let button: ButtonMessage
    let key: KeyMessage
    let hidClass: NSObject.Type
    let translator: NSObject

    static func load() throws -> Frameworks {
        guard let developer = run("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              FileManager.default.fileExists(atPath: developer + "/Library/PrivateFrameworks/SimulatorKit.framework") else {
            throw Failure(message: "Xcode isn't installed.", code: "noXcode")
        }
        let kitPath = developer + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        for path in ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", kitPath,
                     "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"] {
            guard dlopen(path, RTLD_NOW) != nil else {
                throw Failure(message: "Couldn't load \(path): \(String(cString: dlerror()))", code: "noXcode")
            }
        }
        let kit = dlopen(kitPath, RTLD_NOW)
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(kit, name) else { throw Failure(message: "This Xcode has no \(name).") }
            return unsafeBitCast(pointer, to: T.self)
        }
        var error: NSError?
        guard let contextClass = NSClassFromString("SimServiceContext"),
              let context = cast(contextClass, ServiceContextClass.self).sharedServiceContextForDeveloperDir(developer, error: &error),
              let set = cast(context, ServiceContext.self).defaultDeviceSetWithError(&error) else {
            throw Failure(message: "The simulator service didn't start: \(error?.localizedDescription ?? "unknown error").")
        }
        guard let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") as? NSObject.Type,
              let translatorClass = NSClassFromString("AXPTranslator") as? NSObject.Type,
              let translator = translatorClass.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject else {
            throw Failure(message: "This Xcode's simulator frameworks aren't the ones this app knows.")
        }
        translator.setValue(AccessibilityBridge.shared, forKey: "bridgeTokenDelegate")
        translator.setValue(true, forKey: "supportsDelegateTokens")
        translator.setValue(true, forKey: "accessibilityEnabled")
        return Frameworks(developer: developer, deviceSet: cast(set, DeviceSet.self),
                          mouse: try symbol("IndigoHIDMessageForMouseNSEvent", MouseMessage.self),
                          button: try symbol("IndigoHIDMessageForButton", ButtonMessage.self),
                          key: try symbol("IndigoHIDMessageForKeyboardArbitrary", KeyMessage.self),
                          hidClass: hidClass, translator: translator)
    }

    func device(_ udid: String) -> AnyObject? {
        deviceSet.devices.first { cast($0, SimDevice.self).UDID.uuidString == udid }
    }
}

/// Answers the accessibility translator's requests by asking the device they're for.
final class AccessibilityBridge: NSObject {
    static let shared = AccessibilityBridge()
    private let lock = NSLock()
    private var devices: [String: AnyObject] = [:]
    private let queue = DispatchQueue(label: "accessibility-replies")

    func register(_ device: AnyObject, token: String) { lock.withLock { devices[token] = device } }
    func forget(_ token: String) { _ = lock.withLock { devices.removeValue(forKey: token) } }

    @objc func accessibilityTranslationDelegateBridgeCallbackWithToken(_ token: NSString) -> Any {
        let device = lock.withLock { devices[token as String] }
        let queue = self.queue
        let callback: @convention(block) (AnyObject) -> AnyObject? = { request in
            guard let device else { return nil }
            let done = DispatchSemaphore(value: 0)
            var response: AnyObject?
            cast(device, SimDevice.self).sendAccessibilityRequestAsync(request, completionQueue: queue) { response = $0; done.signal() }
            return done.wait(timeout: .now() + 5) == .timedOut ? nil : response
        }
        return callback
    }

    @objc func accessibilityTranslationConvertPlatformFrameToSystem(_ rect: CGRect, withToken token: NSString) -> CGRect { rect }
    @objc func accessibilityTranslationRootParentWithToken(_ token: NSString) -> AnyObject? { nil }
}

// MARK: Shell

@discardableResult
func run(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

func simctl(_ arguments: [String]) throws -> String {
    guard let output = run("/usr/bin/xcrun", ["simctl"] + arguments) else {
        throw Failure(message: "simctl \(arguments.first ?? "") failed.")
    }
    return output
}

// MARK: Devices

/// What `simctl list -j` says is installed.
struct Catalog {
    struct Runtime { let identifier: String; let name: String; let version: String }
    struct Kind { let identifier: String; let name: String }
    struct Device { let udid: String; let name: String; let kind: String; let runtime: String; let state: String }

    var runtimes: [Runtime] = []
    var kinds: [Kind] = []
    var devices: [Device] = []

    static func read() throws -> Catalog {
        let data = Data(try simctl(["list", "-j", "devicetypes", "runtimes", "devices"]).utf8)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(message: "simctl list gave no JSON.") }
        var catalog = Catalog()
        for item in json["runtimes"] as? [[String: Any]] ?? [] where item["isAvailable"] as? Bool == true && item["platform"] as? String == "iOS" {
            guard let identifier = item["identifier"] as? String else { continue }
            catalog.runtimes.append(Runtime(identifier: identifier, name: item["name"] as? String ?? identifier, version: item["version"] as? String ?? ""))
        }
        catalog.runtimes.sort { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        let supported = Set(((json["runtimes"] as? [[String: Any]]) ?? [])
            .filter { $0["identifier"] as? String == catalog.runtimes.first?.identifier }
            .flatMap { ($0["supportedDeviceTypes"] as? [[String: Any]] ?? []).compactMap { $0["identifier"] as? String } })
        for item in json["devicetypes"] as? [[String: Any]] ?? [] {
            guard let identifier = item["identifier"] as? String, let name = item["name"] as? String,
                  supported.isEmpty || supported.contains(identifier), item["productFamily"] as? String != "Apple Watch" else { continue }
            if let family = item["productFamily"] as? String, family != "iPhone", family != "iPad" { continue }
            catalog.kinds.append(Kind(identifier: identifier, name: name))
        }
        for (runtime, list) in json["devices"] as? [String: [[String: Any]]] ?? [:] {
            for item in list where item["isAvailable"] as? Bool == true {
                guard let udid = item["udid"] as? String else { continue }
                catalog.devices.append(Device(udid: udid, name: item["name"] as? String ?? "", kind: item["deviceTypeIdentifier"] as? String ?? "",
                                              runtime: runtime, state: item["state"] as? String ?? ""))
            }
        }
        return catalog
    }
}

// MARK: Cards

/// One card's device: its screen in a remote layer context, and its input client.
final class Screen {
    let card: String
    let udid: String
    let device: AnyObject
    let scale: CGFloat
    let hid: HIDClient
    let bootedHere: Bool
    private let callbacks = NSUUID()
    private var display: Display?
    private let layer = CALayer()
    private var context: RemoteContext?
    /// Full-rectangle screen, for screenshots; the card shows the masked one (rounded corners).
    private(set) var unmasked: IOSurface?
    private(set) var size = CGSize.zero  // points

    // Drags faster than ~60 Hz come back NULL from SimulatorKit: keep the newest and send it when allowed.
    private var pendingMove: CGPoint?
    private var moveTimer: DispatchWorkItem?
    /// Made, off the main queue, once the screen's size is known and kept while the card is
    /// open: starting one takes about 2 s, which a card stream would otherwise wait.
    private var encoder: VideoEncoder?
    private var warming = false
    /// A card stream watches this screen.
    private var streaming = false

    init(card: String, udid: String, device: AnyObject, hid: HIDClient, bootedHere: Bool) {
        self.card = card
        self.udid = udid
        self.device = device
        self.hid = hid
        self.bootedHere = bootedHere
        let deviceType = cast(device, SimDevice.self).deviceType
        scale = CGFloat(deviceType.map { cast($0, DeviceType.self).mainScreenScale } ?? 0).nonZero ?? 3
        layer.contentsGravity = .resize
        layer.anchorPoint = .zero
    }

    /// Finds the main display among the device's IO ports and starts following its surfaces.
    func attach() throws {
        let deadline = Date().addingTimeInterval(10)
        while display == nil {
            if let io = cast(device, SimDevice.self).io {
                display = cast(io, IOClient.self).ioPorts.lazy.compactMap { port -> Display? in
                    guard let descriptor = cast(port, IOPort.self).descriptor,
                          descriptor.responds(to: #selector(getter: Display.state)),
                          descriptor.responds(to: #selector(Display.registerScreenCallbacksWithUUID(_:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:))),
                          let state = cast(descriptor, Display.self).state,
                          cast(state, DisplayState.self).displayClass == 0 else { return nil }
                    return cast(descriptor, Display.self)
                }.first
            }
            if display == nil {
                guard Date() < deadline else { throw Failure(message: "The simulator's screen didn't come up.") }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let context = cast(cast(NSClassFromString("CAContext")!, CAContextClass.self).remoteContextWithOptions([:]), RemoteContext.self)
        context.layer = layer
        self.context = context
        display?.registerScreenCallbacksWithUUID(callbacks, callbackQueue: .main, frameCallback: { [weak self] in
            self?.layer.perform(NSSelectorFromString("setContentsChanged"))
            if let self, self.streaming, let unmasked = self.unmasked { self.encode(unmasked) }
        }, surfacesChangedCallback: { [weak self] masked, unmasked in
            self?.show(masked ?? unmasked, unmasked: unmasked ?? masked)
        }, propertiesChangedCallback: { _ in })
    }

    private func show(_ surface: IOSurface?, unmasked: IOSurface?) {
        // Both go nil for a moment while the screen reconfigures; keep showing the last one.
        guard let surface, let context else { return }
        self.unmasked = unmasked
        size = CGSize(width: CGFloat(surface.width) / scale, height: CGFloat(surface.height) / scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        layer.bounds = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        emit(["event": "surface", "card": card, "contextID": context.contextId,
              "width": size.width, "height": size.height, "scale": scale])
        warmEncoder()
    }

    /// Encodes a frame if the session fits its size; one of a new size (a rotation) waits for a
    /// session made off the main queue, so the screen and input never stall, and clients keep
    /// the last picture meanwhile.
    private func encode(_ surface: IOSurface) {
        guard let encoder, encoder.fits(width: surface.width, height: surface.height) else { return warmEncoder() }
        encoder.encode(surface)
    }

    private func warmEncoder() {
        guard !warming, let unmasked, encoder?.fits(width: unmasked.width, height: unmasked.height) != true else { return }
        warming = true
        let card = card, width = unmasked.width, height = unmasked.height
        DispatchQueue.global(qos: .utility).async {
            let encoder = VideoEncoder { data, key in
                DispatchQueue.main.async { emit(["event": "video", "card": card, "data": data.base64EncodedString(), "key": key]) }
            }
            encoder.prepare(width: width, height: height)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.context != nil else { return encoder.invalidate() }
                self.encoder?.invalidate()
                self.encoder = encoder
                self.warming = false
                // The size changed again while this one was made.
                if let unmasked = self.unmasked, !encoder.fits(width: unmasked.width, height: unmasked.height) { return self.warmEncoder() }
                if self.streaming { self.stream(true) }
            }
        }
    }

    /// Starts or stops encoding the screen for card streams; on again asks for a keyframe now,
    /// which a still screen would otherwise not send.
    func stream(_ on: Bool) {
        streaming = on
        guard on else { return }
        encoder?.requestKeyFrame()
        if let unmasked { encode(unmasked) }
    }

    func detach() {
        streaming = false
        encoder?.invalidate()
        encoder = nil
        display?.unregisterScreenCallbacksWithUUID(callbacks)
        moveTimer?.cancel()
        context?.layer = nil
        context = nil
    }

    // MARK: Input

    private func send(_ message: UnsafeMutableRawPointer?) {
        guard let message else { return }
        hid.sendWithMessage(message, freeWhenDone: true, completionQueue: nil, completion: nil)
    }

    /// A finger at `point` (device points): down, move or up.
    func touch(_ phase: String, _ point: CGPoint, _ kit: Frameworks) {
        guard size != .zero else { return }
        switch phase {
        case "down":
            pendingMove = nil
            moveTimer?.cancel()
            sendTouch(point, .leftMouseDown, kit)
        case "move":
            if moveTimer == nil, sendTouch(point, .leftMouseDragged, kit) { return }
            pendingMove = point
            scheduleMove(kit)
        default:
            // The up carries the final point, so a move still waiting can go.
            pendingMove = nil
            moveTimer?.cancel()
            moveTimer = nil
            sendTouch(point, .leftMouseUp, kit)
        }
    }

    @discardableResult
    private func sendTouch(_ point: CGPoint, _ type: NSEvent.EventType, _ kit: Frameworks) -> Bool {
        var point = point
        guard let message = kit.mouse(&point, nil, 0x32, type.rawValue, size, 0) else { return false }
        send(message)
        return true
    }

    private func scheduleMove(_ kit: Frameworks) {
        guard moveTimer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            moveTimer = nil
            guard let point = pendingMove else { return }
            if sendTouch(point, .leftMouseDragged, kit) { pendingMove = nil } else { scheduleMove(kit) }
        }
        moveTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(17), execute: work)
    }

    func key(_ usage: UInt32, down: Bool, _ kit: Frameworks) {
        send(kit.key(usage, down ? 1 : 2))
    }

    /// A wheel or trackpad scroll, as a one-finger drag that ends when the wheel stops: what
    /// SimulatorKit's own scroll message does to the screen isn't usable (it blanks it).
    private var scrollPoint: CGPoint?
    private var scrollEnd: DispatchWorkItem?

    func scroll(_ point: CGPoint, dx: Double, dy: Double, _ kit: Frameworks) {
        if scrollPoint == nil {
            scrollPoint = point
            touch("down", point, kit)
        }
        guard var current = scrollPoint else { return }
        // dx/dy say how far the content moves (AppKit's scrolling deltas), and content follows
        // the finger. The finger stays on the screen.
        current.x = min(max(current.x + dx, 1), size.width - 1)
        current.y = min(max(current.y + dy, 1), size.height - 1)
        scrollPoint = current
        touch("move", current, kit)
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self, let last = scrollPoint else { return }
            scrollPoint = nil
            touch("up", last, kit)
        }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80), execute: end)
    }

    static let buttons: [String: UInt32] = ["home": 0x0, "lock": 0x1, "side": 0xbb8, "siri": 0x400002]
    static let volume: [String: UInt32] = ["volumeup": 0x80, "volumedown": 0x81]  // keyboard page Volume Up/Down

    func button(_ name: String, _ kit: Frameworks) throws {
        let name = name.lowercased()
        if let source = Self.buttons[name] {
            send(kit.button(source, 1, 0x33))
            send(kit.button(source, 2, 0x33))
        } else if let usage = Self.volume[name] {
            // shortcut: volume goes in as keyboard-page keys, unverified on a device; upgrade to the
            // consumer page if it does nothing.
            key(usage, down: true, kit)
            key(usage, down: false, kit)
        } else {
            throw Failure(message: "No button “\(name)”. Buttons: home, lock, siri, volumeUp, volumeDown.")
        }
    }

    /// Types `text` key by key; characters with no key go in by pasting.
    func type(_ text: String, _ kit: Frameworks) {
        var pasteRun = ""
        func flushPaste() {
            guard !pasteRun.isEmpty else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "pbcopy", udid]
            let pipe = Pipe()
            process.standardInput = pipe
            try? process.run()
            pipe.fileHandleForWriting.write(Data(pasteRun.utf8))
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            for (usage, down) in [(UInt32(0xe3), true), (0x19, true), (0x19, false), (0xe3, false)] { key(usage, down: down, kit) }
            Thread.sleep(forTimeInterval: 0.05)
            pasteRun = ""
        }
        for character in text {
            guard let (usage, shift) = Keyboard.usage(for: character) else { pasteRun.append(character); continue }
            flushPaste()
            if shift { key(0xe1, down: true, kit) }
            key(usage, down: true, kit)
            key(usage, down: false, kit)
            if shift { key(0xe1, down: false, kit) }
            Thread.sleep(forTimeInterval: 0.008)
        }
        flushPaste()
    }

    // MARK: Agent view

    /// The frontmost app's accessibility tree, flattened in reading order. Empty while a freshly
    /// launched app is still loading its accessibility (that takes several seconds).
    func elements(_ kit: Frameworks, limit: Int = 1500) -> [[String: Any]] {
        let token = "\(udid)/\(UUID().uuidString)"  // a fresh token: the translator caches per token
        AccessibilityBridge.shared.register(device, token: token)
        defer { AccessibilityBridge.shared.forget(token) }
        let translator = cast(kit.translator, Translator.self)
        guard let translation = translator.frontmostApplicationWithDisplayId(0, bridgeDelegateToken: token) as? NSObject else { return [] }
        translation.setValue(token, forKey: "bridgeDelegateToken")
        guard let root = translator.macPlatformElementFromTranslation(translation) as? NSObject else { return [] }
        var list: [[String: Any]] = []
        func walk(_ element: NSObject, _ depth: Int) {
            guard list.count < limit else { return }
            (element.value(forKey: "translation") as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
            let frame = (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            var item: [String: Any] = ["role": element.value(forKey: "accessibilityRole") as? String ?? "",
                                       "depth": depth,
                                       "frame": [frame.minX, frame.minY, frame.width, frame.height].map { ($0 * 10).rounded() / 10 }]
            if let label = element.value(forKey: "accessibilityLabel") as? String, !label.isEmpty { item["label"] = label }
            if let value = element.value(forKey: "accessibilityValue").map({ "\($0)" }), !value.isEmpty { item["value"] = value }
            list.append(item)
            for child in element.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] { walk(child, depth + 1) }
        }
        walk(root, 0)
        // Only the app element, with no size: the app hasn't loaded its accessibility yet.
        if list.count <= 1, (list.first?["frame"] as? [CGFloat])?[2] == 0 { return [] }
        return list
    }

    /// The screen at 1 pixel per point, as JPEG.
    func screenshot() throws -> Data {
        guard let surface = unmasked else { throw Failure(message: "The screen isn't up yet.") }
        let image = CIImage(ioSurface: surface).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let context = CIContext()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: image, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]) else {
            throw Failure(message: "Couldn't encode the screenshot.")
        }
        return data
    }
}

extension CGFloat {
    var nonZero: CGFloat? { self == 0 ? nil : self }
}

/// US keyboard HID usages, which is what the simulator's hardware keyboard reads.
enum Keyboard {
    static func usage(for character: Character) -> (UInt32, Bool)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return character == "\r\n" ? (0x28, false) : nil
        }
        let value = scalar.value
        switch value {
        case 0x61...0x7a: return (0x04 + value - 0x61, false)   // a-z
        case 0x41...0x5a: return (0x04 + value - 0x41, true)    // A-Z
        case 0x31...0x39: return (0x1e + value - 0x31, false)   // 1-9
        case 0x30: return (0x27, false)
        default: break
        }
        let table: [Character: (UInt32, Bool)] = [
            "\n": (0x28, false), "\t": (0x2b, false), " ": (0x2c, false),
            "-": (0x2d, false), "_": (0x2d, true), "=": (0x2e, false), "+": (0x2e, true),
            "[": (0x2f, false), "{": (0x2f, true), "]": (0x30, false), "}": (0x30, true),
            "\\": (0x31, false), "|": (0x31, true), ";": (0x33, false), ":": (0x33, true),
            "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false), "~": (0x35, true),
            ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
            "/": (0x38, false), "?": (0x38, true),
            "!": (0x1e, true), "@": (0x1f, true), "#": (0x20, true), "$": (0x21, true), "%": (0x22, true),
            "^": (0x23, true), "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
        ]
        return table[character]
    }

    /// Named keys agents and the board press.
    static let named: [String: UInt32] = [
        "enter": 0x28, "return": 0x28, "escape": 0x29, "backspace": 0x2a, "delete": 0x2a, "tab": 0x2b, "space": 0x2c,
        "arrowright": 0x4f, "arrowleft": 0x50, "arrowdown": 0x51, "arrowup": 0x52,
    ]
}

// MARK: Host

final class Host {
    private var kit: Result<Frameworks, Failure>?
    private var screens: [String: Screen] = [:]
    private let work = DispatchQueue(label: "requests", attributes: .concurrent)

    func frameworks() throws -> Frameworks {
        if kit == nil {
            do { kit = .success(try Frameworks.load()) } catch let failure as Failure { kit = .failure(failure) } catch {
                kit = .failure(Failure(message: error.localizedDescription))
            }
        }
        return try kit!.get()
    }

    func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        let card = params["card"] as? String ?? ""
        guard let id = message["id"] else {
            // Input: no answer, applied in order on the main queue.
            guard let screen = screens[card], let kit = try? frameworks() else { return }
            let point = CGPoint(x: params["x"] as? Double ?? 0, y: params["y"] as? Double ?? 0)
            switch method {
            case "touch": screen.touch(params["phase"] as? String ?? "up", point, kit)
            case "scroll": screen.scroll(point, dx: params["dx"] as? Double ?? 0, dy: params["dy"] as? Double ?? 0, kit)
            case "key": screen.key(UInt32(params["usage"] as? Int ?? 0), down: params["down"] as? Bool ?? true, kit)
            case "button": try? screen.button(params["name"] as? String ?? "", kit)
            case "stream": screen.stream(params["on"] as? Bool ?? false)
            default: break
            }
            return
        }
        // Slow requests (boot, snapshot, typing) run off the main queue, which keeps input and
        // screen callbacks flowing.
        work.async { [self] in
            do {
                let result = try respond(method, card: card, params)
                emit(["id": id, "result": result])
            } catch let failure as Failure {
                var reply: [String: Any] = ["id": id, "error": failure.message]
                if let code = failure.code { reply["code"] = code }
                emit(reply)
            } catch {
                emit(["id": id, "error": error.localizedDescription])
            }
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T { try DispatchQueue.main.sync(execute: body) }

    private func screen(_ card: String) throws -> Screen {
        guard let screen = onMain({ screens[card] }) else { throw Failure(message: "This simulator isn't running.") }
        return screen
    }

    private func respond(_ method: String, card: String, _ params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "devices":
            _ = try onMain { try frameworks() }
            let catalog = try Catalog.read()
            guard let runtime = catalog.runtimes.first else { throw Failure(message: "No iOS runtime is installed.", code: "noRuntime") }
            return ["runtime": runtime.name, "deviceTypes": catalog.kinds.map { ["name": $0.name, "identifier": $0.identifier] }]
        case "open": return try open(card, params)
        case "close":
            guard let screen = onMain({ screens.removeValue(forKey: card) }) else { return [:] }
            onMain { screen.detach() }
            _ = try? simctl(["shutdown", screen.udid])
            return [:]
        case "snapshot":
            let screen = try screen(card), kit = try onMain { try frameworks() }
            // A just-launched app has no tree for a few seconds: wait a little here rather than
            // make the agent ask again.
            let deadline = Date().addingTimeInterval(params["retry"] as? Double ?? 3)
            var elements = screen.elements(kit)
            while elements.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
                elements = screen.elements(kit)
            }
            return ["elements": elements, "width": screen.size.width, "height": screen.size.height]
        case "screenshot":
            let screen = try screen(card)
            let data = try onMain { try screen.screenshot() }
            let path = params["path"] as? String ?? NSTemporaryDirectory() + "simulator-\(card).jpg"
            try data.write(to: URL(fileURLWithPath: path))
            return ["path": path, "image": data.base64EncodedString(), "mimeType": "image/jpeg"]
        case "type":
            let screen = try screen(card), kit = try onMain { try frameworks() }
            screen.type(params["text"] as? String ?? "", kit)
            return [:]
        case "key":
            let screen = try screen(card), kit = try onMain { try frameworks() }
            let name = (params["name"] as? String ?? "").lowercased()
            if let usage = Keyboard.named[name] {
                onMain { screen.key(usage, down: true, kit); screen.key(usage, down: false, kit) }
            } else {
                try onMain { try screen.button(params["name"] as? String ?? "", kit) }
            }
            return [:]
        default:
            throw Failure(message: "Unknown method \(method).")
        }
    }

    /// Finds or creates the device in the default device set, boots it headless, and shows its screen.
    private func open(_ card: String, _ params: [String: Any]) throws -> [String: Any] {
        let kit = try onMain { try frameworks() }
        if let screen = onMain({ screens[card] }) { return describe(screen, try Catalog.read()) }
        var catalog = try Catalog.read()
        guard let runtime = catalog.runtimes.first else { throw Failure(message: "No iOS runtime is installed.", code: "noRuntime") }
        let taken = onMain { Set(screens.values.map(\.udid)) }
        var udid = (params["udid"] as? String).flatMap { wanted in catalog.devices.first { $0.udid == wanted }?.udid }
        if udid == nil {
            let wanted = params["deviceType"] as? String
            guard let kind = catalog.kinds.first(where: { $0.name == wanted || $0.identifier == wanted })
                    ?? catalog.kinds.first(where: { $0.name.hasPrefix("iPhone") }) ?? catalog.kinds.first else {
                throw Failure(message: "No iOS device type is installed.", code: "noRuntime")
            }
            udid = catalog.devices.first { $0.kind == kind.identifier && $0.runtime == runtime.identifier && !taken.contains($0.udid) }?.udid
            if udid == nil {
                udid = try simctl(["create", kind.name, kind.identifier, runtime.identifier]).trimmingCharacters(in: .whitespacesAndNewlines)
                catalog = try Catalog.read()
            }
        }
        guard let udid else { throw Failure(message: "Couldn't find or create a device.") }
        guard !taken.contains(udid) else { throw Failure(message: "That device is already on another card.") }
        let wasBooted = catalog.devices.first { $0.udid == udid }?.state == "Booted"
        // Boots headless if needed and returns once the system has finished starting.
        _ = try simctl(["bootstatus", udid, "-b"])
        guard let device = onMain({ kit.device(udid) }) else { throw Failure(message: "The device \(udid) disappeared.") }
        var error: NSError?
        guard let hidObject = (kit.hidClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()).flatMap({
            cast($0, HIDClientInit.self).initWithDevice(device, error: &error)
        }) else {
            throw Failure(message: "Couldn't connect input to the simulator: \(error?.localizedDescription ?? "unknown error").")
        }
        let screen = Screen(card: card, udid: udid, device: device, hid: cast(hidObject, HIDClient.self), bootedHere: !wasBooted)
        try onMain {
            try screen.attach()
            screens[card] = screen
        }
        return describe(screen, try Catalog.read())
    }

    private func describe(_ screen: Screen, _ catalog: Catalog) -> [String: Any] {
        let device = catalog.devices.first { $0.udid == screen.udid }
        return ["udid": screen.udid, "name": device?.name ?? "",
                "deviceType": catalog.kinds.first { $0.identifier == device?.kind }?.name ?? device?.name ?? "",
                "runtime": catalog.runtimes.first { $0.identifier == device?.runtime }?.name ?? "",
                "state": device?.state ?? ""]
    }

    /// The app went away: shut down what this process booted.
    func shutdown() {
        for screen in screens.values {
            screen.detach()
            if screen.bootedHere { _ = try? simctl(["shutdown", screen.udid]) }
        }
        exit(0)
    }
}

// MARK: Main

let host = Host()
let app = NSApplication.shared  // a window-server connection, which remote layer contexts need
app.setActivationPolicy(.prohibited)

let reader = Thread {
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { DispatchQueue.main.async { host.shutdown() }; return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            DispatchQueue.main.async { host.handle(message) }
        }
    }
}
reader.start()
for name in [SIGTERM, SIGINT] {
    signal(name, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: name, queue: .main)
    source.setEventHandler { host.shutdown() }
    source.resume()
    _ = Unmanaged.passRetained(source)
}
emit(["event": "ready"])
app.run()
