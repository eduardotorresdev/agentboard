import Foundation
import Testing
@testable import AgentBoard
import AgentRuntime

/// Android emulator cards: the adb and scrcpy wire formats, how a screen's elements are read,
/// and what the database keeps.
struct AndroidTests {
    @Test func adbRequestsAreLengthPrefixedInHex() {
        #expect(AdbClient.request("host:devices") == Data("000chost:devices".utf8))
        #expect(AdbClient.parseDevices("emulator-5554\tdevice\nemulator-5556\toffline\n") == ["emulator-5554": "device", "emulator-5556": "offline"])
    }

    /// A push is SEND, DATA chunks of at most 64 KiB, then DONE, lengths little-endian.
    @Test func syncPushChunksTheFile() {
        let file = Data(repeating: 7, count: 65536 + 10)
        let packet = AdbClient.syncPush(file, to: "/data/local/tmp/x", mode: 0o644, modified: 1)
        let target = "/data/local/tmp/x,420"
        #expect(packet.prefix(4) == Data("SEND".utf8))
        #expect(AdbClient.littleEndian(packet.dropFirst(4).prefix(4)) == UInt32(target.utf8.count))
        let first = 8 + target.utf8.count
        #expect(packet[first..<first + 4] == Data("DATA".utf8))
        #expect(AdbClient.littleEndian(packet[(first + 4)...].prefix(4)) == 65536)
        let second = first + 8 + 65536
        #expect(AdbClient.littleEndian(packet[(second + 4)...].prefix(4)) == 10)
        #expect(packet.suffix(8) == Data("DONE".utf8) + AdbClient.littleEndian(1))
    }

    @Test func scrcpyHeadersSayWhatFollows() {
        let session = Data([0x80, 0, 0, 0, 0, 0, 0x01, 0xe6, 0, 0, 0x04, 0x38])
        #expect(ScrcpyStream.packet(session) == .session(CGSize(width: 486, height: 1080)))
        let config = Data([0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 33])
        #expect(ScrcpyStream.packet(config) == .config(33))
        let key = Data([0x20, 0, 0, 0, 0, 0, 0x30, 0x39, 0, 0, 0x10, 0])
        #expect(ScrcpyStream.packet(key) == .frame(size: 4096, key: true, pts: 12345))
        let plain = Data([0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 9])
        #expect(ScrcpyStream.packet(plain) == .frame(size: 9, key: false, pts: 1))
    }

    /// Control messages as scrcpy 5.0.1's ControlMessageReader reads them.
    @Test func controlMessagesMatchTheServer() {
        let touch = ScrcpyStream.touch(.down, at: CGPoint(x: 10, y: 20), video: CGSize(width: 486, height: 1080))
        #expect(touch.count == 32)
        #expect([UInt8](touch.prefix(2)) == [2, 0])
        #expect([UInt8](touch[2..<10]) == [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe])  // generic finger
        #expect([UInt8](touch[10..<22]) == [0, 0, 0, 10, 0, 0, 0, 20, 0x01, 0xe6, 0x04, 0x38])
        #expect([UInt8](touch[22..<24]) == [0xff, 0xff])  // full pressure while down
        #expect([UInt8](ScrcpyStream.touch(.up, at: .zero, video: CGSize(width: 1, height: 1))[22..<24]) == [0, 0])

        #expect([UInt8](ScrcpyStream.key(3, down: true, meta: 0x41)) == [0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0x41])
        #expect([UInt8](ScrcpyStream.text("hé")) == [1, 0, 0, 0, 3, 0x68, 0xc3, 0xa9])
        #expect([UInt8](ScrcpyStream.setClipboard("a", sequence: 2, paste: true)) == [9, 0, 0, 0, 0, 0, 0, 0, 2, 1, 0, 0, 0, 1, 0x61])
        let scroll = ScrcpyStream.scroll(at: .zero, video: CGSize(width: 2, height: 2), by: CGSize(width: 0, height: 16))
        #expect(scroll.count == 21)
        #expect([UInt8](scroll[13..<17]) == [0, 0, 0x7f, 0xff])
        #expect(ScrcpyStream.resetVideo() == Data([17]))
    }

    @Test func annexBSplitsIntoNALUnits() {
        let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5])
        #expect(ScrcpyStream.nalUnits(stream) == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5])])
    }

    /// Each node is an element at its nesting depth; a description is the label and the text,
    /// beside it, the value.
    @Test func uiautomatorDumpsBecomeElements() {
        let xml = """
            <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
            <node index="0" text="" class="android.widget.FrameLayout" content-desc="" bounds="[0,0][1080,2400]">\
            <node index="0" text="Search apps" class="android.widget.EditText" content-desc="" bounds="[42,120][1038,252]" />\
            <node index="1" text="Chrome" class="android.widget.TextView" content-desc="Open Chrome" bounds="[540,600][800,900]" />\
            </node></hierarchy>
            """
        let elements = AndroidSnapshotter.parse(xml)
        #expect(elements == [
            AndroidElement(role: "FrameLayout", depth: 0, frame: [0, 0, 1080, 2400]),
            AndroidElement(role: "EditText", depth: 1, frame: [42, 120, 996, 132], label: "Search apps"),
            AndroidElement(role: "TextView", depth: 1, frame: [540, 600, 260, 300], label: "Open Chrome", value: "Chrome"),
        ])
        let (text, refs) = SimulatorStore.format(elements.map(\.dictionary))
        #expect(text == """
            e1 frameLayout [0,0,1080,2400]
              e2 editText "Search apps" [42,120,996,132]
              e3 textView "Open Chrome" Chrome [540,600,260,300]
            """)
        #expect(SimulatorStore.point(of: "e3", in: refs) == CGPoint(x: 670, y: 750))
    }

    /// The dumper's tab-separated lines; a line it cut short is skipped.
    @Test func dumperLinesBecomeElements() {
        let dump = "0\tFrameLayout\t0\t0\t1080\t2400\t\t\n1\tTextView\t314\t1491\t205\t273\tGmail\t\n1\tImageView\t1\t2\t3\t4\tOpen\tInbox\n2\tView\t1\t2"
        #expect(AndroidSnapshotter.parseDump(dump) == [
            AndroidElement(role: "FrameLayout", depth: 0, frame: [0, 0, 1080, 2400]),
            AndroidElement(role: "TextView", depth: 1, frame: [314, 1491, 205, 273], label: "Gmail"),
            AndroidElement(role: "ImageView", depth: 1, frame: [1, 2, 3, 4], label: "Open", value: "Inbox"),
        ])
    }

    @Test func keysBecomeAndroidKeycodes() {
        #expect(AndroidKeys.keycode(forUsage: 0x04) == 29)   // A
        #expect(AndroidKeys.keycode(forUsage: 0x1d) == 54)   // Z
        #expect(AndroidKeys.keycode(forUsage: 0x1e) == 8)    // 1
        #expect(AndroidKeys.keycode(forUsage: 0x27) == 7)    // 0
        #expect(AndroidKeys.keycode(forUsage: 0x28) == 66)   // Enter
        #expect(AndroidKeys.keycode(forUsage: 0x2a) == 67)   // Backspace
        #expect(AndroidKeys.keycode(forUsage: 0x52) == 19)   // Up
        #expect(AndroidKeys.buttons["back"] == 4)
        #expect(AndroidKeys.buttons["recents"] == 187)
        // Every Mac key the board forwards has an Android key.
        for code in UInt16(0)...127 {
            if let usage = SimulatorKeys.usage(forKeyCode: code), usage != 0x64 { #expect(AndroidKeys.keycode(forUsage: usage) != nil, "usage \(usage)") }
        }
    }

    @Test func probesSayWhatTheMachineHas() {
        let probe = AndroidEmulators.parseProbe("""
            sdk=/home/a/Android/Sdk
            os=Linux
            arch=x86_64
            memory=3048
            kvm=yes
            image=android-30/default/x86_64/
            image=android-35/google_apis_playstore/x86_64/
            image=android-35/google_apis/x86_64/
            image=android-36/google_apis/arm64-v8a/
            """)
        #expect(probe.sdk == "/home/a/Android/Sdk")
        #expect(probe.memory == 3048)
        #expect(probe.image == "android-35/google_apis/x86_64")
        #expect(probe.runtime == "Android API 35")
        #expect(AndroidEmulators.parseWindowSize("Physical size: 1080x2400\nOverride size: 720x1600\n") == CGSize(width: 720, height: 1600))
        #expect(AndroidEmulators.parseWindowSize("Physical size: 1080x2400\n") == CGSize(width: 1080, height: 2400))
    }

    @Test func deviceTypesTakePhoneTabletOrAName() {
        #expect(AndroidEmulators.deviceType(named: "tablet").name == "Pixel Tablet")
        #expect(AndroidEmulators.deviceType(named: "phone").name == "Pixel 7")
        #expect(AndroidEmulators.deviceType(named: "pixel_tablet").name == "Pixel Tablet")
        #expect(AndroidEmulators.avdName(for: UUID(uuidString: "2D2D375D-133B-43D1-B13B-A820FF038E7A")!) == "agentboard_2d2d375d")
    }

    @Test func recordsKeepTheirPlatformAndHost() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abandroid-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try Database(url: url)
        let record = SimulatorRecord(id: UUID(), worktree: "/w", name: "Pixel 7", udid: "agentboard_1234abcd", deviceType: "Pixel 7",
                                     frame: CGRect(x: 1, y: 2, width: 300, height: 600), platform: .android, host: UUID())
        try database.saveSimulator(record)
        #expect(try Database(url: url).simulators() == [record])
    }
}

/// The real SDK, found where the user keeps it (the safe test run gives the tests a home of
/// their own, so it is looked up by the account's home), with a system image for this Mac.
private let androidSDK: String? = {
    guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir.map({ String(cString: $0) }) else { return nil }
    let fm = FileManager.default
    for sdk in [ProcessInfo.processInfo.environment["ANDROID_HOME"], home + "/Library/Android/sdk", home + "/Android/Sdk"].compactMap({ $0 }) {
        let images = (try? fm.subpathsOfDirectory(atPath: sdk + "/system-images")) ?? []
        if fm.isExecutableFile(atPath: sdk + "/emulator/emulator"), images.contains(where: { $0.hasSuffix("arm64-v8a/system.img") }) { return sdk }
    }
    return nil
}()

/// An emulator on this Mac through the whole card path: boot, first frame, snapshot, typing,
/// screenshot, close. Needs the Android SDK, an arm64 system image and AGENTBOARD_EMULATOR_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_EMULATOR_TESTS"] == "1", "Boots an emulator: set AGENTBOARD_EMULATOR_TESTS=1 to run it."),
       .enabled(if: androidSDK != nil, "No Android SDK with an arm64 system image."), .serialized)
@MainActor
struct AndroidEmulatorTests {
    @Test(.timeLimit(.minutes(10))) func drivesAnEmulator() async throws {
        setenv("ANDROID_HOME", androidSDK!, 1)
        let emulators = AndroidEmulators()
        emulators.machine = { _ in .local }
        var content: SimulatorScreen.Content?
        var size: CGSize?
        emulators.onScreen = { _, shown, screen in content = shown; size = screen }
        let record = SimulatorRecord(id: UUID(), worktree: "/w", name: "Pixel 7", udid: nil, deviceType: "Pixel 7", frame: .zero, platform: .android)
        let avd = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.android/avd/\(AndroidEmulators.avdName(for: record.id)).avd"
        var closed = false
        defer { if !closed { Task { await emulators.close(record, deleting: true) } } }

        let opened = try await emulators.open(record, pixels: 1200)
        #expect(opened.address.hasPrefix("emulator-"))
        #expect(opened.persistent == AndroidEmulators.avdName(for: record.id))
        #expect(FileManager.default.fileExists(atPath: avd))
        guard case .layer? = content else { Issue.record("no video layer"); return }
        #expect(size == CGSize(width: 1080, height: 2400))

        // A frame decodes: the screenshot comes from the video.
        let shot = NSTemporaryDirectory() + "/\(record.id).jpg"
        defer { try? FileManager.default.removeItem(atPath: shot) }
        let jpeg = try await emulators.screenshot(record.id, to: shot)
        #expect(jpeg.count > 1000)

        // The launcher's app list: its search field takes pasted text.
        try emulators.button(record.id, "home")
        try await Task.sleep(for: .seconds(2))
        try await emulators.connect(record.id)
        emulators.touch(record.id, "down", at: CGPoint(x: 540, y: 2000))
        for step in 1...15 {
            try await Task.sleep(for: .milliseconds(16))
            emulators.touch(record.id, "move", at: CGPoint(x: 540, y: 2000 - CGFloat(step) * 90))
        }
        emulators.touch(record.id, "up", at: CGPoint(x: 540, y: 650))
        // The app list's search: a field, or until tapped a view that says "Search".
        var field: CGPoint?
        var seen: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(90)
        while field == nil, Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            seen = try await emulators.snapshot(record.id)
            // A starved guest shows "… isn't responding": wait for it, as a person would.
            if seen.contains(where: { ($0["label"] as? String)?.contains("isn't responding") == true }),
               let wait = seen.first(where: { $0["label"] as? String == "Wait" })?["frame"] as? [Double] {
                let point = CGPoint(x: wait[0] + wait[2] / 2, y: wait[1] + wait[3] / 2)
                emulators.touch(record.id, "down", at: point)
                emulators.touch(record.id, "up", at: point)
                continue
            }
            field = seen.first { $0["role"] as? String == "EditText" || ($0["label"] as? String)?.localizedCaseInsensitiveContains("search") == true }.flatMap { element in
                (element["frame"] as? [Double]).map { CGPoint(x: $0[0] + $0[2] / 2, y: $0[1] + $0[3] / 2) }
            }
        }
        let tap = try #require(field, "no search field in the app list: \(seen.map { "\($0["role"] ?? "") \($0["label"] ?? "")" })")
        emulators.touch(record.id, "down", at: tap)
        try await Task.sleep(for: .milliseconds(60))
        emulators.touch(record.id, "up", at: tap)
        try await Task.sleep(for: .seconds(1))
        try await emulators.type(record.id, "Clock é")
        var typed = false
        let typing = Date().addingTimeInterval(60)
        while !typed, Date() < typing {
            try await Task.sleep(for: .seconds(1))
            typed = try await emulators.snapshot(record.id).contains { ($0["label"] as? String ?? "").contains("Clock é") || ($0["value"] as? String ?? "").contains("Clock é") }
        }
        #expect(typed, "the pasted text isn't in the search field")

        await emulators.close(record, deleting: true)
        closed = true
        #expect(!FileManager.default.fileExists(atPath: avd))
    }
}
