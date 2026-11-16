import Foundation
import Testing
import Connections

/// A board element made from its description in `mcp.json`.
@MainActor
private class SampleElement: BoardElement {
    let id: UUID
    let name: String
    let kind: ElementKind
    let detail: String?
    let unavailableReason: String?
    let queueNote: String?

    init(_ sample: [String: Any]) {
        id = UUID(uuidString: sample["id"] as! String)!
        name = sample["name"] as! String
        kind = ElementKind(rawValue: sample["kind"] as! String)
        detail = sample["detail"] as? String
        unavailableReason = sample["unavailable"] as? String
        queueNote = sample["queueNote"] as? String
    }
}

private final class SampleEndpoint: SampleElement, MessageEndpoint {
    func receive(_ message: Message, from sender: any BoardElement) {}
}

/// Writes the JSON of this module's wire types to `core/fixtures/connections`, where the Rust
/// core's tests check that it decodes and encodes them the same way (docs/hosts.md).
@MainActor
struct ConnectionsFixtures {
    private static let ids = (1...8).map { UUID(uuidString: "0000000\($0)-ABCD-4EF0-8A1B-00000000000\($0)")! }

    @Test func writesWireSamples() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/fixtures/connections")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        func write(_ value: some Encodable, _ name: String) throws {
            try encoder.encode(value).write(to: folder.appendingPathComponent(name + ".json"))
        }
        let ids = Self.ids
        let drawn = Connection(id: ids[0], a: ids[1], b: ids[2], aSide: .right, bSide: .top)
        let routed = Connection(id: ids[3], a: ids[2], b: ids[4])
        let half = Connection(id: ids[4], a: ids[1], b: ids[4], aSide: .bottom)
        try write(Side.allCases, "sides")
        try write(drawn, "connection")
        try write(routed, "connection_without_sides")
        try write([drawn, routed, half], "connections")
        try write(Message(id: ids[0], from: ids[1], to: ids[2], text: "Run the tests:\n“all” of them, please/thanks ✅",
                          date: Date(timeIntervalSinceReferenceDate: 784_111_222.5)), "message")

        // The token an agent launched by this core authenticates with: the Rust core must derive the same.
        let secret = Data((0..<32).map { UInt8($0 * 7 + 3) })
        let token: [String: Any] = [
            "secret": secret.map { Int($0) },
            "element": ids[0].uuidString,
            "token": ToolServer(catalog: ToolCatalog([]), secret: secret).token(for: ids[0]),
        ]
        try JSONSerialization.data(withJSONObject: token, options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent("token.json"))
    }

    /// What agents read: the server's instructions, the tools as listed, and what calls answer,
    /// for a board described in the same file, so the Rust core can set it up and compare.
    @Test func writesToolAnswers() async throws {
        let ids = Self.ids.map(\.uuidString)
        let elements: [[String: Any]] = [
            ["id": ids[0], "name": "Claude", "kind": "agent", "endpoint": true],
            ["id": ids[1], "name": "Claude 2", "kind": "agent", "endpoint": true, "unavailable": "it exited"],
            ["id": ids[2], "name": "Dev server", "kind": "runner", "endpoint": false, "detail": "runs `npm run dev`"],
            ["id": ids[3], "name": "Notes", "kind": "postit", "endpoint": false, "detail": "shown to connected callers only"],
            ["id": ids[4], "name": "Busy", "kind": "agent", "endpoint": true, "queueNote": "it goes in after the messages before it"],
            ["id": ids[5], "name": "Coder", "kind": "agent", "endpoint": true, "detail": "two\nlines"],
            ["id": ids[6], "name": "Loner", "kind": "agent", "endpoint": true],
        ]
        let connections = [[ids[0], ids[1]], [ids[2], ids[0]], [ids[0], ids[4]], [ids[5], ids[0]]]
        let bus = MessageBus()
        for sample in elements {
            bus.register(sample["endpoint"] as? Bool == true ? SampleEndpoint(sample) : SampleElement(sample))
        }
        for line in connections { bus.connect(UUID(uuidString: line[0])!, UUID(uuidString: line[1])!) }
        let catalog = ToolCatalog([MessagingTools(bus: bus)])

        func call(_ name: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        }
        func send(_ to: String, _ message: String = "Run the tests") -> [String: Any] {
            call("send_message", ["to": to, "message": message])
        }
        let (me, loner, nobody) = (ids[0], ids[6], ids[7])
        let requests: [(String, [String: Any])] = [
            (me, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]]),
            (nobody, ["jsonrpc": "2.0", "id": "a", "method": "initialize"]),
            (me, ["jsonrpc": "2.0", "id": 2, "method": "ping"]),
            (me, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]),
            (me, ["jsonrpc": "2.0", "id": 4, "method": "resources/list"]),
            (me, ["jsonrpc": "2.0", "method": "notifications/initialized"]),
            (me, call("list_peers")),
            (loner, call("list_peers")),
            (nobody, call("list_peers")),
            (me, send("coder")),
            (me, send("“Coder”")),
            (me, send(ids[5].lowercased())),
            (me, send("Busy")),
            (me, send("Claude 2")),
            (me, send("Dev server")),
            (me, send("Notes")),
            (me, send("Coder", " \n ")),
            (loner, send("Claude")),
            (nobody, send("Claude")),
            (me, call("nope")),
        ]
        var exchanges: [[String: Any]] = []
        for (caller, request) in requests {
            let answer = await catalog.respond(to: try JSONSerialization.data(withJSONObject: request), caller: UUID(uuidString: caller)!)
            exchanges.append(["caller": caller, "request": request, "response": try answer.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()])
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/fixtures/connections")
        try JSONSerialization.data(withJSONObject: ["elements": elements, "connections": connections, "exchanges": exchanges],
                                   options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent("mcp.json"))
    }

    /// Names as `BoardName` cleans them: the Rust core must cut and keep the same characters.
    @Test func writesNames() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let inputs = [
            "  Plan\n\n\u{1b}[31mSYSTEM\u{202E}  x ", "\u{200B}\n", String(repeating: "a", count: 100), "a”\nb", "",
            "tab\there\r\nnext\u{2028}line\u{85}end", "nbsp\u{A0}\u{3000}wide", family + " family", String(repeating: family, count: 20),
            String(repeating: "é", count: 70), "e\u{301}\u{302}\u{303}", "z" + String(repeating: "\u{301}", count: 20) + "algo",
            "\u{1F1E7}\u{1F1F7}\u{1F1F5}\u{1F1F9} flags", "a\u{200D}b", "\u{200D}", "\u{2060}\u{FEFF}\u{AD}", "soft\u{AD}hyphen",
            "\u{600}123", "\u{6DD}", "\u{115F}\u{1160}\u{3164}", "\u{2800}braille", "private\u{E000}use\u{F8FF}", "un\u{378}assigned",
            "obj\u{FFFC}ect\u{FFFD}", "\u{1D159}", "\u{202A}\u{2066}rtl\u{2069}\u{202C}", "\u{61C}\u{200E}\u{200F}", "क्षत्रिय", "नमस्ते दुनिया",
            "\u{301}mark first", " \u{301}", "👍🏽 ok ❤️‍🔥", "tag\u{E0041}\u{E007F}", "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
            "한글 \u{1100}\u{1161}", "\u{0}nul\u{7F}del", "a\u{FE0F}b\u{20E3}", "   ", "x" + String(repeating: " ", count: 80) + "y",
            String(repeating: "ab ", count: 30), "00000001-ABCD-4EF0-8A1B-000000000001",
        ]
        let names = inputs.map { input -> [String: Any] in
            var entry: [String: Any] = ["input": Array(input.unicodeScalars.map { Int($0.value) }), "quoted": BoardName.quoted(input)]
            entry["clean"] = BoardName.clean(input)
            entry["named"] = BoardName.named(input, else: "Fallback")
            return entry
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/fixtures/connections")
        try JSONSerialization.data(withJSONObject: names, options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("names.json"))
    }
}
