import CryptoKit
import Foundation

/// One element of an Android screen, in the fields every simulator snapshot has (see
/// `SimulatorStore.format`); the frame is in display pixels.
struct AndroidElement: Sendable, Equatable {
    var role: String
    var depth: Int
    var frame: [Double]
    var label: String?
    var value: String?

    var dictionary: [String: Any] {
        var element: [String: Any] = ["role": role, "depth": depth, "frame": frame]
        if let label { element["label"] = label }
        if let value { element["value"] = value }
        return element
    }
}

/// Reads an Android screen's elements. First through the board's own dumper (ui-dumper.dex,
/// built from Android/ui-dumper): started once per device with app_process, it answers at once
/// on a `localabstract:` socket. Where it can't start (an Android version where the hidden API it
/// uses moved), through `uiautomator dump`, which waits for the UI to go idle (up to about 10 s)
/// and fails now and then, so it is retried. Which one answered goes to the log, not the agent.
final class AndroidSnapshotter: @unchecked Sendable {
    /// The bundled dex, and names that change with it: a dumper left running from an older
    /// build is never asked.
    static let dex = Bundle.module.url(forResource: "ui-dumper", withExtension: "dex").flatMap { try? Data(contentsOf: $0) }
    static let dexHash = dex.map { SHA256.hash(data: $0).prefix(4).map { String(format: "%02x", $0) }.joined() } ?? "none"
    static let dumperPath = "/data/local/tmp/agentboard-ui-dumper-\(dexHash).dex"
    static let socket = "agentboard-ui-\(dexHash)"

    let adb: AdbClient
    let serial: String
    private let lock = NSLock()
    /// The stream the dumper was started on: it runs while this is open.
    private var dumper: AdbStream?
    /// When the dumper last failed; it is tried again a minute later.
    private var dumperFailed: Date?
    private var lastSource = ""

    init(adb: AdbClient, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    deinit { dumper?.close() }

    func elements() throws -> [AndroidElement] {
        if lock.withLock({ dumperFailed.map { Date().timeIntervalSince($0) > 60 } ?? true }) {
            do {
                let elements = try dump()
                note("dumper")
                return elements
            } catch {
                NSLog("AgentBoard: the UI dumper on \(serial) failed (\(error.localizedDescription)); using uiautomator")
                lock.withLock { dumperFailed = Date() }
            }
        }
        let elements = try uiautomator()
        note("uiautomator")
        return elements
    }

    private func note(_ source: String) {
        let changed = lock.withLock { () -> Bool in defer { lastSource = source }; return lastSource != source }
        if changed { NSLog("AgentBoard: snapshots of \(serial) come from \(source)") }
    }

    /// Asks the dumper, starting it if it isn't listening (one left by an earlier board is reused).
    private func dump() throws -> [AndroidElement] {
        if let elements = try? ask() { return elements }
        // A device that just booted still kills processes to free memory: try once more.
        do { try start() } catch { try start() }
        return try ask()
    }

    private func ask() throws -> [AndroidElement] {
        let stream = try adb.open(serial, "localabstract:\(Self.socket)")
        defer { stream.close() }
        stream.timeout(15)
        return Self.parseDump(String(decoding: stream.readAll(), as: UTF8.self))
    }

    private func start() throws {
        let present = String(decoding: try adb.exec(serial, "[ -f \(Self.dumperPath) ] && echo yes", timeout: 15), as: UTF8.self)
        if !present.contains("yes") {
            guard let dex = Self.dex else {
                throw AdbClient.Failure(message: "The UI dumper is missing from the app.")
            }
            try adb.push(serial, dex, to: Self.dumperPath)
        }
        let stream = try adb.open(serial, "shell:CLASSPATH=\(Self.dumperPath) app_process / agentboard.UiDumper \(Self.socket) 2>&1")
        stream.timeout(20)
        // "ready" once it listens; anything else is why it couldn't.
        var output = Data()
        while !String(decoding: output, as: UTF8.self).contains("ready") {
            guard let byte = try? stream.read(1) else {
                stream.close()
                throw AdbClient.Failure(message: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).description)
            }
            output += byte
        }
        stream.timeout(0)
        lock.withLock {
            dumper?.close()
            dumper = stream
        }
    }

    /// The dumper's lines: depth, class, left, top, width, height, label, value, tab-separated.
    static func parseDump(_ text: String) -> [AndroidElement] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8, let depth = Int(fields[0]) else { return nil }
            let numbers = fields[2...5].compactMap { Double($0) }
            guard numbers.count == 4 else { return nil }
            return AndroidElement(role: fields[1], depth: depth, frame: numbers,
                                  label: fields[6].isEmpty ? nil : fields[6], value: fields[7].isEmpty ? nil : fields[7])
        }
    }

    private func uiautomator() throws -> [AndroidElement] {
        let file = "/data/local/tmp/agentboard-ui.xml"
        var last = ""
        for _ in 0..<3 {
            let output = try adb.exec(serial, "uiautomator dump --compressed \(file) >/dev/null 2>&1; cat \(file) 2>/dev/null; rm -f \(file)", timeout: 40)
            let text = String(decoding: output, as: UTF8.self)
            if text.contains("<hierarchy") { return Self.parse(text) }
            last = text
        }
        NSLog("AgentBoard: uiautomator gave no hierarchy on \(serial): \(last.prefix(200))")
        return []
    }

    /// uiautomator's XML as elements in document order, each node's depth its nesting.
    static func parse(_ xml: String) -> [AndroidElement] {
        let reader = Reader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        parser.parse()
        return reader.elements
    }

    /// "[x1,y1][x2,y2]" as [x, y, width, height].
    static func frame(_ bounds: String) -> [Double] {
        let numbers = bounds.split(whereSeparator: { "[],".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4 else { return [0, 0, 0, 0] }
        return [numbers[0], numbers[1], numbers[2] - numbers[0], numbers[3] - numbers[1]]
    }

    /// The class's own name: android.widget.Button → Button.
    static func role(_ className: String) -> String {
        String(className.split(separator: ".").last ?? "View")
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var elements: [AndroidElement] = []
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard name == "node" else { return }
            let text = attributes["text"] ?? "", description = attributes["content-desc"] ?? ""
            // The label is what a screen reader says; the text, when there is also a description, is the value.
            let label = description.isEmpty ? text : description
            let value = description.isEmpty || text == description ? nil : text
            elements.append(AndroidElement(role: AndroidSnapshotter.role(attributes["class"] ?? ""), depth: depth,
                                           frame: AndroidSnapshotter.frame(attributes["bounds"] ?? ""),
                                           label: label.isEmpty ? nil : label, value: value?.isEmpty == false ? value : nil))
            depth += 1
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "node" { depth -= 1 }
        }
    }
}
