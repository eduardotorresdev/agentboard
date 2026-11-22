import AppKit
import Foundation

/// Android emulators for simulator cards, on this Mac or a host (`Machine`): one AVD per card,
/// made by writing its two files, booted headless, found again by its AVD name, and shown and
/// driven through scrcpy-server over adb (`AdbClient`). Everything here runs the same way on
/// both kinds of machine.
@MainActor
final class AndroidEmulators: SimulatorBackend {
    var onScreen: ((UUID, SimulatorScreen.Content?, CGSize?) -> Void)?
    var onFailure: ((UUID, SimulatorHost.Failure) -> Void)?
    /// The machine a card's emulator runs on.
    var machine: ((SimulatorRecord) -> Machine?)?

    private final class Session {
        let machine: Machine
        let adb: AdbClient
        let sdk: String
        let serial: String
        let avd: String
        /// The display in pixels, what snapshots and the tools' points are in.
        let screen: CGSize
        var stream: ScrcpyStream?
        var starting = false
        /// Modifier keys held on the user's keyboard, as HID usages.
        var modifiers: Set<Int> = []
        let snapshotter: AndroidSnapshotter

        init(machine: Machine, sdk: String, serial: String, avd: String, screen: CGSize) {
            self.machine = machine
            adb = AdbClient(machine: machine)
            self.sdk = sdk
            self.serial = serial
            self.avd = avd
            self.screen = screen
            snapshotter = AndroidSnapshotter(adb: adb, serial: serial)
        }
    }

    private var sessions: [UUID: Session] = [:]
    /// The card size (in pixels on this Mac's screen) each stream is encoded near.
    private var wanted: [UUID: Int] = [:]
    /// Card streams (StreamServer) watching each card.
    let taps = StreamTaps()
    /// Cards the board hides while a stream watches them: their video stops when it ends.
    private var hidden: Set<UUID> = []

    struct DeviceType {
        let name: String
        let profile: String
        let size: CGSize
        let density: Int
    }

    /// The device types a card can be, the first the default. Tablets are landscape.
    nonisolated static let deviceTypes = [
        DeviceType(name: "Pixel 7", profile: "pixel_7", size: CGSize(width: 1080, height: 2400), density: 420),
        DeviceType(name: "Pixel Tablet", profile: "pixel_tablet", size: CGSize(width: 2560, height: 1600), density: 320),
    ]
    /// Guest memory, in MB, and what must stay free beside it for the machine not to swap.
    nonisolated static let guestMemory = 2048
    nonisolated static let memoryMargin = 1024
    /// How long a boot may take before the emulator is killed.
    nonisolated static let bootTimeout: TimeInterval = 300

    nonisolated static func deviceType(named name: String) -> DeviceType {
        let key = name.lowercased()
        if key == "tablet" { return deviceTypes[1] }
        return deviceTypes.first { $0.name.lowercased() == key || $0.profile == key } ?? deviceTypes[0]
    }

    func deviceTypes(for record: SimulatorRecord) async -> [String] { Self.deviceTypes.map(\.name) }

    /// The AVD a card owns.
    nonisolated static func avdName(for card: UUID) -> String {
        "agentboard_" + card.uuidString.prefix(8).lowercased()
    }

    // MARK: Opening

    func open(_ record: SimulatorRecord, pixels: Int) async throws -> SimulatorOpened {
        guard let machine = machine?(record) else {
            throw SimulatorHost.Failure(message: "The host this card is on isn't connected.", code: "unreachable")
        }
        wanted[record.id] = pixels
        let probe = try await Self.probe(machine)
        let type = Self.deviceType(named: record.deviceType)
        let avd = record.udid ?? Self.avdName(for: record.id)
        let session = try await Self.boot(avd: avd, type: type, probe: probe, machine: machine)
        sessions[record.id] = session
        try await startStream(record.id)
        return SimulatorOpened(device: type.name, runtime: probe.runtime, persistent: avd, address: session.serial)
    }

    /// Shows the card's screen again (after `hide`, or when the stream ended).
    func show(_ card: UUID) {
        hidden.remove(card)
        guard let session = sessions[card], session.stream == nil, !session.starting else { return }
        Task { try? await startStream(card) }
    }

    func connect(_ card: UUID) async throws {
        guard let session = sessions[card] else { return }
        let deadline = Date().addingTimeInterval(40)
        while session.starting, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if session.stream == nil { try await startStream(card) }
        // The first session packet says the video size the input is scaled to.
        while session.stream?.videoSize == .zero, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// Stops the card's video while nobody sees it; the emulator keeps running.
    func hide(_ card: UUID) {
        hidden.insert(card)
        guard !taps.watched(card) else { return }
        stopStream(card)
    }

    private func stopStream(_ card: UUID) {
        guard let session = sessions[card], let stream = session.stream else { return }
        session.stream = nil
        stream.onEnd = nil
        stream.stop()
        onScreen?(card, nil, session.screen)
    }

    private func startStream(_ card: UUID) async throws {
        guard let session = sessions[card] else { return }
        session.starting = true
        defer { session.starting = false }
        let stream = ScrcpyStream(adb: session.adb, serial: session.serial)
        stream.onVideo = { [taps] in taps.send(card, .video($0)) }
        let long = min(Int(max(session.screen.width, session.screen.height)), max(480, wanted[card] ?? 1280))
        stream.onEnd = { [weak self] error in
            Task { @MainActor in
                guard let self, let session = self.sessions[card], session.stream === stream else { return }
                session.stream = nil
                self.onScreen?(card, nil, session.screen)
                if let error { NSLog("AgentBoard: Android screen of \(session.serial) ended: \(error.localizedDescription)") }
            }
        }
        try await Self.offMain { try stream.start(maxSize: long - long % 8) }
        guard sessions[card] === session else { return stream.stop() }
        session.stream = stream
        onScreen?(card, .layer(stream.layer), session.screen)
    }

    /// Sends the card's screen to a card stream: H.264 as scrcpy encodes it, input in display pixels.
    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)? {
        guard let session = sessions[card] else { return nil }
        taps.send(card, .header(.init(kind: "h264", width: session.screen.width, height: session.screen.height, units: "pixels")))
        let id = taps.add(card, sink)
        // A new watcher needs the configuration and a keyframe: a reset sends both.
        if let stream = session.stream {
            stream.send(ScrcpyStream.resetVideo())
        } else {
            show(card)
            hidden.insert(card)
        }
        return { [weak self] in
            guard let self, self.taps.remove(card, id), self.hidden.contains(card) else { return }
            self.stopStream(card)
        }
    }

    func requestKeyFrame(_ card: UUID) { sessions[card]?.stream?.send(ScrcpyStream.resetVideo()) }

    func close(_ record: SimulatorRecord, deleting: Bool) async {
        let session = sessions.removeValue(forKey: record.id)
        wanted[record.id] = nil
        session?.stream?.stop()
        guard let machine = session?.machine ?? machine?(record) else { return }
        let avd = record.udid ?? Self.avdName(for: record.id)
        let serial = session?.serial
        let probe = try? await Self.probe(machine)
        guard let sdk = probe?.sdk ?? session?.sdk else { return }
        var script = ""
        if let serial { script += "\(Self.quote(sdk + "/platform-tools/adb")) -s \(serial) emu kill >/dev/null 2>&1; " }
        // Not running in a session of ours (a board that crashed): find it by its AVD name.
        script += "pkill -f -- '-av[d] \(avd) ' 2>/dev/null; "
        if deleting {
            script += "sleep 1; rm -rf \"$HOME/.android/avd/\(avd).avd\" \"$HOME/.android/avd/\(avd).ini\""
        }
        _ = await machine.sh(script)
    }

    /// Kills the emulators of this Mac, as the board quits; a host's keep running.
    func quit() {
        for (_, session) in sessions where session.machine.host == nil {
            session.stream?.stop()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: session.sdk + "/platform-tools/adb")
            process.arguments = ["-s", session.serial, "emu", "kill"]
            try? process.run()
            process.waitUntilExit()
        }
    }

    struct Probe: Sendable {
        var sdk: String?
        var os = ""
        var arch = ""
        /// MB the machine can give without swapping.
        var memory = 0
        var kvm = ""
        /// Installed system images, newest API first: "android-36/google_apis/arm64-v8a".
        var images: [String] = []

        var abi: String { arch == "x86_64" || arch == "amd64" ? "x86_64" : "arm64-v8a" }
        var image: String? { images.first { $0.hasSuffix("/" + abi) } }
        var runtime: String {
            guard let api = image?.split(separator: "/").first?.replacingOccurrences(of: "android-", with: "") else { return "Android" }
            return "Android API \(api)"
        }
    }

    /// What the machine has: the SDK, its system images, free memory and (on Linux) KVM.
    nonisolated static func probe(_ machine: Machine) async throws -> Probe {
        guard let ran = await machine.sh(probeScript) else {
            throw SimulatorHost.Failure(message: "\(machine.name.prefix(1).uppercased() + machine.name.dropFirst()) can't be reached.", code: "unreachable")
        }
        return parseProbe(String(decoding: ran.output, as: UTF8.self))
    }

    nonisolated static let probeScript = #"""
        for d in "$ANDROID_HOME" "$ANDROID_SDK_ROOT" "$HOME/.agentboard/android-sdk" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "$HOME/Android/sdk"; do
          if [ -n "$d" ] && [ -x "$d/emulator/emulator" ] && [ -x "$d/platform-tools/adb" ]; then echo "sdk=$d"; sdk="$d"; break; fi
        done
        echo "os=$(uname -s)"; echo "arch=$(uname -m)"
        if [ -r /proc/meminfo ]; then awk '/^MemAvailable:/ { print "memory=" int($2 / 1024) }' /proc/meminfo
        else vm_stat | awk -v page="$(pagesize)" '/^Pages (free|inactive|speculative|purgeable):/ { gsub(/\./, "", $NF); n += $NF } END { print "memory=" int(n * page / 1048576) }'
        fi
        if [ -e /dev/kvm ]; then if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then echo kvm=yes; else echo kvm=denied; fi; else echo kvm=none; fi
        if [ -n "$sdk" ]; then for i in "$sdk"/system-images/*/*/*/; do [ -f "$i/system.img" ] && echo "image=${i#$sdk/system-images/}"; done; fi
        """#

    nonisolated static func parseProbe(_ text: String) -> Probe {
        var probe = Probe()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals], value = String(line[line.index(after: equals)...])
            switch key {
            case "sdk": probe.sdk = value
            case "os": probe.os = value
            case "arch": probe.arch = value
            case "memory": probe.memory = Int(value) ?? 0
            case "kvm": probe.kvm = value
            case "image": probe.images.append(value.hasSuffix("/") ? String(value.dropLast()) : value)
            default: break
            }
        }
        // Newest API first; among one API, plain Google APIs before the Play Store's.
        func rank(_ image: String) -> (Int, Int) {
            let parts = image.split(separator: "/")
            let api = Int(parts.first?.replacingOccurrences(of: "android-", with: "") ?? "") ?? 0
            let tag = parts.count > 1 ? String(parts[1]) : ""
            return (api, tag == "google_apis" ? 2 : tag == "default" ? 1 : 0)
        }
        probe.images.sort { rank($0) > rank($1) }
        return probe
    }

    /// Finds the card's emulator running, or creates its AVD if needed and boots it; returns once
    /// Android has finished booting. Blocks.
    nonisolated private static func boot(avd: String, type: DeviceType, probe: Probe, machine: Machine) async throws -> Session {
        guard let sdk = probe.sdk else {
            throw SimulatorHost.Failure(message: "The Android SDK isn't on \(machine.name).", code: "noSDK")
        }
        if probe.os == "Linux", probe.kvm != "yes" {
            throw SimulatorHost.Failure(message: probe.kvm == "denied" ? "kvmDenied" : "kvmMissing", code: "noAcceleration")
        }
        guard let image = probe.image else {
            throw SimulatorHost.Failure(message: "No Android system image for \(probe.abi) is installed on \(machine.name).", code: "noSDK")
        }
        let adbPath = sdk + "/platform-tools/adb"
        _ = await machine.run(adbPath, ["start-server"])
        let adb = AdbClient(machine: machine)
        let devices = (try? await offMain { try adb.devices() }) ?? [:]
        // Already running (a host's emulator outlives the board): reattach.
        for (serial, state) in devices where serial.hasPrefix("emulator-") && state == "device" {
            if await offMain({ avdName(of: serial, adb: adb) }) == avd {
                return Session(machine: machine, sdk: sdk, serial: serial, avd: avd, screen: await offMain { screenSize(serial, adb: adb, fallback: type.size) })
            }
        }
        guard probe.memory >= guestMemory + memoryMargin else {
            throw SimulatorHost.Failure(message: "\(probe.memory)", code: "lowMemory")
        }
        let used = Set(devices.keys.compactMap { $0.hasPrefix("emulator-") ? Int($0.dropFirst(9)) : nil })
        guard let port = stride(from: 5554, through: 5682, by: 2).first(where: { !used.contains($0) && !used.contains($0 + 1) }) else {
            throw SimulatorHost.Failure(message: "Too many emulators are running on \(machine.name).")
        }
        let gpu = probe.os == "Darwin" ? "host" : "swiftshader_indirect"
        let launched = await machine.sh(launchScript(sdk: sdk, avd: avd, image: image, type: type, port: port, gpu: gpu, abi: probe.abi))
        guard let launched, launched.status == 0 else {
            let reason = String(decoding: launched?.error ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorHost.Failure(message: "The emulator didn't start\(reason.isEmpty ? "" : ": \(reason)").")
        }
        let serial = "emulator-\(port)"
        let deadline = Date().addingTimeInterval(bootTimeout)
        while true {
            if let booted = try? await offMain({ try adb.exec(serial, "getprop sys.boot_completed", timeout: 10) }),
               String(decoding: booted, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
            let alive = await machine.sh("pgrep -f -- '-av[d] \(avd) ' >/dev/null && echo yes")
            if String(decoding: alive?.output ?? Data(), as: UTF8.self).contains("yes") == false {
                let log = await machine.sh("tail -n 3 \"$HOME/.android/avd/\(avd).log\"")
                let last = String(decoding: log?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SimulatorHost.Failure(message: "The emulator stopped while starting\(last.isEmpty ? "" : ": \(last)").")
            }
            if Date() > deadline {
                _ = await machine.run(adbPath, ["-s", serial, "emu", "kill"])
                throw SimulatorHost.Failure(message: "The emulator didn't finish starting in \(Int(bootTimeout / 60)) minutes, so it was stopped.")
            }
            try await Task.sleep(for: .seconds(1))
        }
        return Session(machine: machine, sdk: sdk, serial: serial, avd: avd, screen: await offMain { screenSize(serial, adb: adb, fallback: type.size) })
    }

    /// Writes the AVD if it isn't there (its two files, what avdmanager would, without needing
    /// Java) and starts the emulator detached from the call.
    nonisolated static func launchScript(sdk: String, avd: String, image: String, type: DeviceType, port: Int, gpu: String, abi: String) -> String {
        let api = image.split(separator: "/").first.map(String.init) ?? ""
        let tag = image.split(separator: "/").dropFirst().first.map(String.init) ?? "google_apis"
        let config = """
            AvdId=\(avd)
            avd.ini.displayname=\(avd)
            avd.ini.encoding=UTF-8
            abi.type=\(abi)
            hw.cpu.arch=\(abi == "x86_64" ? "x86_64" : "arm64")
            hw.cpu.ncore=2
            hw.ramSize=\(guestMemory)
            hw.device.manufacturer=Google
            hw.device.name=\(type.profile)
            hw.lcd.width=\(Int(type.size.width))
            hw.lcd.height=\(Int(type.size.height))
            hw.lcd.density=\(type.density)
            hw.keyboard=yes
            hw.gpu.enabled=yes
            hw.audioInput=no
            hw.audioOutput=no
            image.sysdir.1=system-images/\(image)/
            tag.id=\(tag)
            PlayStore.enabled=false
            disk.dataPartition.size=6442450944
            showDeviceFrame=no
            """
        let arguments = ["-avd", avd, "-port", String(port), "-cores", "2", "-memory", String(guestMemory),
                         "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot", "-gpu", gpu]
        return """
            set -e
            home="$HOME/.android/avd"
            mkdir -p "$home"
            if [ ! -f "$home/\(avd).ini" ]; then
              mkdir -p "$home/\(avd).avd"
              cat > "$home/\(avd).avd/config.ini" <<'EOF'
            \(config)
            EOF
              printf 'avd.ini.encoding=UTF-8\\npath=%s\\npath.rel=avd/\(avd).avd\\ntarget=\(api)\\n' "$home/\(avd).avd" > "$home/\(avd).ini"
            fi
            export ANDROID_SDK_ROOT=\(quote(sdk)) ANDROID_HOME=\(quote(sdk)) ANDROID_AVD_HOME="$home"
            if command -v setsid >/dev/null 2>&1; then detach=setsid; else detach=nohup; fi
            $detach \(quote(sdk + "/emulator/emulator")) \(arguments.joined(separator: " ")) > "$home/\(avd).log" 2>&1 < /dev/null &
            """
    }

    nonisolated private static func avdName(of serial: String, adb: AdbClient) -> String? {
        for property in ["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"] {
            if let data = try? adb.exec(serial, "getprop \(property)", timeout: 10) {
                let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    /// The display's size in pixels (`wm size`: its override if set).
    nonisolated private static func screenSize(_ serial: String, adb: AdbClient, fallback: CGSize) -> CGSize {
        guard let data = try? adb.exec(serial, "wm size", timeout: 10) else { return fallback }
        return parseWindowSize(String(decoding: data, as: UTF8.self)) ?? fallback
    }

    nonisolated static func parseWindowSize(_ text: String) -> CGSize? {
        var size: CGSize?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let parts = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).split(separator: "x")
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { continue }
            if size == nil || line.hasPrefix("Override") { size = CGSize(width: width, height: height) }
        }
        return size
    }

    nonisolated static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs blocking work (adb's sockets) on a thread of its own, off Swift's shared pool.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Input

    /// `point` is in display pixels; the stream wants video pixels.
    private func video(_ point: CGPoint, _ session: Session, _ stream: ScrcpyStream) -> CGPoint {
        let video = stream.videoSize
        return CGPoint(x: point.x * video.width / max(1, session.screen.width), y: point.y * video.height / max(1, session.screen.height))
    }

    func touch(_ card: UUID, _ phase: String, at point: CGPoint) {
        guard let session = sessions[card], let stream = session.stream, stream.videoSize != .zero else { return }
        let action: ScrcpyStream.Action = phase == "down" ? .down : phase == "up" ? .up : .move
        stream.send(ScrcpyStream.touch(action, at: video(point, session, stream), video: stream.videoSize))
    }

    /// `delta` in display pixels of content movement; Android scrolls in notches.
    func scroll(_ card: UUID, at point: CGPoint, by delta: CGSize) {
        guard let session = sessions[card], let stream = session.stream, stream.videoSize != .zero else { return }
        let notch: CGFloat = 120
        stream.send(ScrcpyStream.scroll(at: video(point, session, stream), video: stream.videoSize,
                                        by: CGSize(width: -delta.width / notch, height: delta.height / notch)))
    }

    /// A key from the user's keyboard: printable characters as text (so any keyboard layout
    /// types what its keys say), the rest as Android keys with the modifiers held.
    func key(_ card: UUID, usage: Int, down: Bool, characters: String?) {
        guard let session = sessions[card], let stream = session.stream else { return }
        if AndroidKeys.modifierMeta[usage] != nil {
            if down { session.modifiers.insert(usage) } else { session.modifiers.remove(usage) }
        }
        let meta = session.modifiers.reduce(0) { $0 | (AndroidKeys.modifierMeta[$1] ?? 0) }
        let shortcut = session.modifiers.contains { [0xe0, 0xe4, 0xe3, 0xe7].contains($0) }
        if let characters, !shortcut, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f && !(0xf700...0xf8ff).contains($0.value) }) {
            if down { stream.send(ScrcpyStream.text(characters)) }
            return
        }
        guard let code = AndroidKeys.keycode(forUsage: usage) else { return }
        stream.send(ScrcpyStream.key(code, down: down, meta: meta))
    }

    /// home, back, recents, power, volumeUp, volumeDown.
    func button(_ card: UUID, _ name: String) throws {
        guard let code = AndroidKeys.buttons[name.lowercased()] else {
            throw SimulatorHost.Failure(message: "No button “\(name)” on Android: use home, back, recents, power, volumeUp or volumeDown, or a key name such as enter.")
        }
        guard let stream = sessions[card]?.stream else { throw SimulatorHost.Failure(message: "The emulator's screen isn't connected.") }
        stream.send(ScrcpyStream.key(code, down: true))
        stream.send(ScrcpyStream.key(code, down: false))
    }

    /// A few plain characters go in as typed text; anything longer or beyond ASCII through the
    /// clipboard and a paste, which keeps every character. A final newline presses Enter.
    func type(_ card: UUID, _ text: String) async throws {
        guard let stream = sessions[card]?.stream else { throw SimulatorHost.Failure(message: "The emulator's screen isn't connected.") }
        var text = text
        let submit = text.hasSuffix("\n")
        if submit { text.removeLast() }
        if !text.isEmpty {
            if text.count <= 3, text.allSatisfy({ $0.isASCII && !$0.isNewline }) {
                stream.send(ScrcpyStream.text(text))
            } else {
                stream.paste(text)
            }
        }
        if submit {
            try await Task.sleep(for: .milliseconds(150))
            stream.send(ScrcpyStream.key(66, down: true))
            stream.send(ScrcpyStream.key(66, down: false))
        }
    }

    // MARK: Agent view

    func snapshot(_ card: UUID) async throws -> [[String: Any]] {
        guard let session = sessions[card] else { throw SimulatorHost.Failure(message: "The emulator isn't running.") }
        let snapshotter = session.snapshotter
        return try await Self.offMain { try snapshotter.elements() }.map(\.dictionary)
    }

    func screenshot(_ card: UUID, to path: String) async throws -> Data {
        guard let session = sessions[card] else { throw SimulatorHost.Failure(message: "The emulator isn't running.") }
        var image = await session.stream?.capture()
        if image == nil {
            let adb = session.adb, serial = session.serial
            let png = try await Self.offMain { try adb.exec(serial, "screencap -p", timeout: 30) }
            image = NSBitmapImageRep(data: png)?.cgImage
        }
        guard let image else { throw SimulatorHost.Failure(message: "Couldn't capture the emulator's screen.") }
        // Half the display's pixels at most: enough to read, light to send.
        let scale = min(1, max(session.screen.width, session.screen.height) / 2 / CGFloat(max(image.width, image.height)))
        guard let jpeg = Self.jpeg(image, scale: scale) else { throw SimulatorHost.Failure(message: "Couldn't encode the screenshot.") }
        try jpeg.write(to: URL(fileURLWithPath: path))
        return jpeg
    }

    nonisolated static func jpeg(_ image: CGImage, scale: CGFloat) -> Data? {
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// The serial adb takes for the card's emulator (`adb -s`), once it runs.
    func address(of card: UUID) -> String? { sessions[card]?.serial }
}
