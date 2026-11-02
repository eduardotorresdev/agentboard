import CoreGraphics
import Foundation
import Testing
import Connections

/// An element that records what it receives.
@MainActor
private final class Inbox: MessageEndpoint {
    let id = UUID()
    let name: String
    let kind = ElementKind.agent
    var unavailableReason: String?
    private(set) var received: [(Message, String)] = []

    init(_ name: String) { self.name = name }

    func receive(_ message: Message, from sender: any BoardElement) {
        received.append((message, sender.name))
    }
}

@MainActor
struct MessageBusTests {
    @Test func messagesTravelOnlyAlongLines() throws {
        let bus = MessageBus()
        let (planner, coder, tester) = (Inbox("Planner"), Inbox("Coder"), Inbox("Tester"))
        [planner, coder, tester].forEach(bus.register)
        bus.connect(planner.id, coder.id)

        try bus.send("Implement the parser", from: planner.id, to: "coder")
        try bus.send("Done", from: coder.id, to: "Planner")
        #expect(coder.received.map(\.0.text) == ["Implement the parser"])
        #expect(coder.received.map(\.1) == ["Planner"])
        #expect(planner.received.map(\.0.text) == ["Done"])

        #expect(throws: MessageError.notConnected(to: "Tester", peers: ["Coder"])) {
            try bus.send("Hi", from: planner.id, to: "Tester")
        }
        #expect(tester.received.isEmpty)
    }

    /// An element that takes no messages itself (a browser) can still send along its lines.
    @Test func anyConnectedElementCanDeliver() throws {
        final class Page: BoardElement {
            let id = UUID()
            let name = "Mobile"
            let kind = ElementKind.browser
        }
        let bus = MessageBus()
        let (page, agent, stranger) = (Page(), Inbox("Claude"), Inbox("Other"))
        bus.register(page)
        [agent, stranger].forEach(bus.register)
        bus.connect(page.id, agent.id)
        try bus.deliver("checkout clicked", from: page.id, to: agent.id)
        #expect(agent.received.map(\.1) == ["Mobile"])
        #expect(throws: MessageError.self) { try bus.deliver("hi", from: page.id, to: stranger.id) }
        #expect(throws: MessageError.notAnEndpoint(name: "Mobile")) { try bus.deliver("hi", from: agent.id, to: page.id) }
        #expect(stranger.received.isEmpty)
    }

    @Test func refusesUnavailableAndEmptyMessages() {
        let bus = MessageBus()
        let (a, b) = (Inbox("A"), Inbox("B"))
        [a, b].forEach(bus.register)
        bus.connect(a.id, b.id)
        b.unavailableReason = "it exited"
        #expect(throws: MessageError.unavailable(name: "B", reason: "it exited")) { try bus.send("Hi", from: a.id, to: "B") }
        b.unavailableReason = nil
        #expect(throws: MessageError.emptyMessage) { try bus.send("  \n", from: a.id, to: "B") }
        #expect(b.received.isEmpty)
    }

    @Test func removingAnElementDropsItsLines() {
        var changes: [ConnectionGraph] = []
        let bus = MessageBus()
        bus.onGraphChange = { changes.append($0) }
        let (a, b, c) = (Inbox("A"), Inbox("B"), Inbox("C"))
        [a, b, c].forEach(bus.register)
        bus.connect(a.id, b.id)
        bus.connect(b.id, c.id)
        #expect(bus.connect(b.id, a.id) == nil, "a line between the same two elements already exists")
        #expect(bus.connect(a.id, a.id) == nil)
        bus.remove(element: b.id)
        #expect(bus.graph.connections.isEmpty)
        #expect(changes.count == 3)
        #expect(bus.peers(of: a.id).isEmpty)
    }
}

@MainActor
struct MessagingToolsTests {
    private func call(_ tools: ToolCatalog, _ method: String, _ params: [String: Any] = [:], caller: UUID) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let answer = try #require(await tools.respond(to: body, caller: caller))
        return try #require(JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    private func text(_ response: [String: Any]) -> String? {
        ((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    @Test func sendsThroughTheBus() async throws {
        let bus = MessageBus()
        let (a, b) = (Inbox("Claude"), Inbox("Claude 2"))
        [a, b].forEach(bus.register)
        bus.connect(a.id, b.id)
        let tools = ToolCatalog([MessagingTools(bus: bus)])

        let initialize = try await call(tools, "initialize", ["protocolVersion": "2025-03-26"], caller: a.id)
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["instructions"] as? String)?.contains("You are Claude,") == true)
        #expect(b.received.isEmpty)

        let names = (try await call(tools, "tools/list", caller: a.id)["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(names?.compactMap { $0["name"] as? String } == ["list_peers", "send_message"])

        #expect(text(try await call(tools, "tools/call", ["name": "list_peers"], caller: a.id))?.contains("- Claude 2") == true)
        let sent = try await call(tools, "tools/call", ["name": "send_message", "arguments": ["to": "Claude 2", "message": "Run the tests"]], caller: a.id)
        #expect(((sent["result"] as? [String: Any])?["isError"] as? Bool) == false)
        #expect(b.received.map(\.0.text) == ["Run the tests"])

        let refused = try await call(tools, "tools/call", ["name": "send_message", "arguments": ["to": "Nobody", "message": "Hi"]], caller: a.id)
        #expect(((refused["result"] as? [String: Any])?["isError"] as? Bool) == true)
    }

    @Test func notificationsGetNoAnswer() async throws {
        let tools = ToolCatalog([MessagingTools(bus: MessageBus())])
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(await tools.respond(to: body, caller: UUID()) == nil)
    }

    /// A slow provider's call (a browser loading a page) doesn't hold up other requests, and
    /// images come back as MCP image content.
    @Test func providersPlugInAndRunConcurrently() async throws {
        final class Camera: ToolProvider {
            func tools(for caller: UUID) -> [ToolDefinition] { [ToolDefinition(name: "snap", description: "Takes a picture.")] }
            func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
                try? await Task.sleep(for: .milliseconds(200))
                return ToolResult([.image(Data([1, 2, 3]), mimeType: "image/png")])
            }
        }
        let tools = ToolCatalog([MessagingTools(bus: MessageBus()), Camera()])
        let caller = UUID()
        async let slow = call(tools, "tools/call", ["name": "snap"], caller: caller)
        let started = Date()
        _ = try await call(tools, "tools/call", ["name": "list_peers"], caller: caller)
        #expect(Date().timeIntervalSince(started) < 0.15)
        let image = ((try await slow)["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(image?.first?["type"] as? String == "image")
        #expect(image?.first?["data"] as? String == Data([1, 2, 3]).base64EncodedString())
    }
}

@MainActor
struct ToolServerTests {
    private func request(_ url: URL, method: String = "POST", token: String?, body: [String: Any]?) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test func servesToolsToTokenHolders() async throws {
        let bus = MessageBus()
        let (a, b) = (Inbox("A"), Inbox("B"))
        [a, b].forEach(bus.register)
        bus.connect(a.id, b.id)
        let server = ToolServer(catalog: ToolCatalog([MessagingTools(bus: bus)]))
        let url: URL? = await withCheckedContinuation { continuation in server.start { continuation.resume(returning: $0) } }
        let endpoint = try #require(url)
        defer { server.stop() }
        let token = server.token(for: a.id)
        #expect(server.token(for: a.id) == token)

        let call: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                   "params": ["name": "send_message", "arguments": ["to": "B", "message": "Hello"]]]
        let (status, data) = try await request(endpoint, token: token, body: call)
        #expect(status == 200)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int == 7)
        #expect(b.received.map(\.0.text) == ["Hello"])

        #expect(try await request(endpoint, token: nil, body: call).0 == 401)
        #expect(try await request(endpoint, token: "forged", body: call).0 == 401)
        #expect(try await request(endpoint, token: token, body: ["jsonrpc": "2.0", "method": "notifications/initialized"]).0 == 202)
        #expect(try await request(endpoint, method: "DELETE", token: token, body: nil).0 == 405)
        server.revoke(a.id)
        #expect(try await request(endpoint, token: token, body: call).0 == 401)
        #expect(b.received.count == 1)
    }

    /// With a secret, a server started later (the board relaunched) takes the same port and
    /// accepts the token an agent was launched with by the earlier one.
    @Test func secretKeepsLinksAcrossRestarts() async throws {
        let bus = MessageBus()
        let (a, b) = (Inbox("A"), Inbox("B"))
        [a, b].forEach(bus.register)
        bus.connect(a.id, b.id)
        let secret = Data((0..<32).map { UInt8($0) })
        let first = ToolServer(catalog: ToolCatalog([MessagingTools(bus: bus)]), secret: secret)
        let firstURL: URL? = await withCheckedContinuation { continuation in first.start { continuation.resume(returning: $0) } }
        let endpoint = try #require(firstURL)
        let token = first.token(for: a.id)
        first.stop()
        try await Task.sleep(for: .milliseconds(100))

        let second = ToolServer(catalog: ToolCatalog([MessagingTools(bus: bus)]), secret: secret)
        let secondURL: URL? = await withCheckedContinuation { continuation in
            second.start(preferredPort: UInt16(endpoint.port!)) { continuation.resume(returning: $0) }
        }
        defer { second.stop() }
        #expect(secondURL == endpoint)
        #expect(second.token(for: a.id) == token)
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": "send_message", "arguments": ["to": "B", "message": "Again"]]]
        #expect(try await request(endpoint, token: token, body: call).0 == 200)
        #expect(b.received.map(\.0.text) == ["Again"])
        // Another secret derives other tokens.
        let other = ToolServer(catalog: ToolCatalog([]), secret: Data(repeating: 9, count: 32))
        #expect(other.token(for: a.id) != token)
    }

    /// An agent's event stream: a TCP connection that asked for one, read with a deadline.
    private final class Stream {
        let fd: Int32
        private var received = ""

        init(port: Int, token: String?) throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            let authorization = token.map { "Authorization: Bearer \($0)\r\n" } ?? ""
            let head = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\(authorization)Accept: text/event-stream\r\n\r\n"
            _ = head.withCString { write(fd, $0, strlen($0)) }
        }

        deinit { close(fd) }

        /// Everything read until `text` turns up after what earlier calls consumed, or nil.
        func read(until text: String, timeout: Double = 3) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            while !received.contains(text) {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                guard left > 0, poll(&poller, 1, left) > 0 else { return nil }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                received += String(decoding: chunk[0..<count], as: UTF8.self)
            }
            let range = received.range(of: text)!
            defer { received = String(received[range.upperBound...]) }
            return String(received[..<range.upperBound])
        }
    }

    /// An agent's GET opens an event stream, on which the server says when the tools changed;
    /// a server taking over from it carries the stream on and says so there first, since it may
    /// serve other tools. Requests keep being answered meanwhile.
    @Test func streamsHearOfToolChanges() async throws {
        let bus = MessageBus()
        let a = Inbox("A")
        bus.register(a)
        // Shared, as the core's tool key is: the token stays good on the next server.
        let secret = Data(repeating: 3, count: 32)
        let first = ToolServer(catalog: ToolCatalog([MessagingTools(bus: bus)]), secret: secret)
        let firstURL: URL? = await withCheckedContinuation { continuation in first.start { continuation.resume(returning: $0) } }
        let endpoint = try #require(firstURL)
        let token = first.token(for: a.id)
        let changed = "notifications/tools/list_changed"

        #expect(try Stream(port: endpoint.port!, token: nil).read(until: "\r\n\r\n")?.hasPrefix("HTTP/1.1 401") == true)
        let stream = try Stream(port: endpoint.port!, token: token)
        let head = try #require(stream.read(until: "\r\n\r\n"))
        #expect(head.hasPrefix("HTTP/1.1 200"))
        #expect(head.contains("Content-Type: text/event-stream"))
        first.notifyToolsChanged()
        #expect(stream.read(until: "\n\n")?.contains(changed) == true)

        // Handed over, as a newer core takes it.
        await first.drain()
        let release = try #require(first.release())
        #expect(release.streams.count == 1)
        first.stop()
        let second = ToolServer(catalog: ToolCatalog([MessagingTools(bus: bus)]), secret: secret)
        let secondURL: URL? = await withCheckedContinuation { continuation in second.start(inheriting: release) { continuation.resume(returning: $0) } }
        defer { second.stop() }
        #expect(secondURL == endpoint)
        #expect(second.token(for: a.id) == token)
        #expect(stream.read(until: "\n\n")?.contains(changed) == true)
        second.notifyToolsChanged()
        #expect(stream.read(until: "\n\n")?.contains(changed) == true)
        let list: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        #expect(try await request(endpoint, token: token, body: list).0 == 200)
    }

    /// A taken preferred port falls back to a free one.
    @Test func takenPortFallsBack() async throws {
        let first = ToolServer(catalog: ToolCatalog([]))
        let firstURL: URL? = await withCheckedContinuation { continuation in first.start { continuation.resume(returning: $0) } }
        defer { first.stop() }
        let taken = try #require(firstURL?.port)
        let second = ToolServer(catalog: ToolCatalog([]))
        let secondURL: URL? = await withCheckedContinuation { continuation in
            second.start(preferredPort: UInt16(taken)) { continuation.resume(returning: $0) }
        }
        defer { second.stop() }
        #expect(secondURL != nil)
        #expect(secondURL?.port != taken)
    }
}

struct RopeTests {
    private let left = RopeAnchor(point: CGPoint(x: 300, y: 100), side: .right)
    private let right = RopeAnchor(point: CGPoint(x: 700, y: 100), side: .left)

    /// The rope's ends stay exactly on the handles it was tied to, wherever they move.
    @Test func endsStayOnTheirAnchors() {
        var rope = Rope(from: left, to: right)
        let moved = RopeAnchor(point: CGPoint(x: 650, y: 400), side: .top)
        rope.tie(left, moved)
        for _ in 0..<240 { rope.advance(by: 1.0 / 60) }
        #expect(rope.points.first == left.point)
        #expect(rope.points.last == moved.point)
    }

    /// Between level ends the rope sags below them, lowest near the middle.
    @Test func hangsUnderGravity() {
        let rope = Rope.resting(from: left, to: right)
        let lowest = rope.points.max { $0.y < $1.y }!
        #expect(lowest.y > left.point.y + 20)
        #expect(abs(lowest.x - 500) < 60)
    }

    /// Near a card the rope leaves straight out of the side it is plugged into.
    @Test func leavesStraightOutOfItsSide() {
        let top = RopeAnchor(point: CGPoint(x: 300, y: 100), side: .top)
        let rope = Rope.resting(from: top, to: right)
        #expect(rope.points[1].y < top.point.y)
        #expect(abs(rope.points[1].x - top.point.x) < 2)
    }

    /// Left alone, a swinging rope comes to rest; moving an end wakes it.
    @Test func comesToRestAndWakesWhenAnEndMoves() {
        var rope = Rope(from: left, to: right)
        for _ in 0..<1200 where !rope.isSettled { rope.advance(by: 1.0 / 60) }
        #expect(rope.isSettled)
        rope.tie(left, RopeAnchor(point: CGPoint(x: 720, y: 140), side: .left))
        #expect(!rope.isSettled)
        let before = rope.points
        rope.advance(by: 1.0 / 60)
        #expect(rope.points != before)
    }

    /// Pulled apart, the rope grows to keep a little slack instead of staying taut.
    @Test func growsWithItsEnds() {
        var rope = Rope.resting(from: left, to: right)
        let far = RopeAnchor(point: CGPoint(x: 1300, y: 100), side: .left)
        rope.tie(left, far)
        for _ in 0..<1200 where !rope.isSettled { rope.advance(by: 1.0 / 60) }
        #expect(rope.route.length > 1000)
        #expect(rope.points.contains { $0.y > 140 })
    }
}
