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
        #expect(try await request(endpoint, method: "GET", token: token, body: nil).0 == 405)
        server.revoke(a.id)
        #expect(try await request(endpoint, token: token, body: call).0 == 401)
        #expect(b.received.count == 1)
    }
}

struct ConnectorRouterTests {
    private let router = ConnectorRouter()

    private typealias Segment = (CGPoint, CGPoint)

    private func segments(_ route: Route) -> [Segment] {
        Array(zip(route.points, route.points.dropFirst()))
    }

    /// Length two axis-aligned segments run along each other.
    private func overlap(_ s: Segment, _ t: Segment) -> CGFloat {
        let sHorizontal = s.0.y == s.1.y, tHorizontal = t.0.y == t.1.y
        guard sHorizontal == tHorizontal else { return 0 }
        if sHorizontal {
            guard s.0.y == t.0.y else { return 0 }
            return min(max(s.0.x, s.1.x), max(t.0.x, t.1.x)) - max(min(s.0.x, s.1.x), min(t.0.x, t.1.x))
        }
        guard s.0.x == t.0.x else { return 0 }
        return min(max(s.0.y, s.1.y), max(t.0.y, t.1.y)) - max(min(s.0.y, s.1.y), min(t.0.y, t.1.y))
    }

    /// Whether a horizontal and a vertical segment cross (ends touching counts).
    private func cross(_ s: Segment, _ t: Segment) -> Bool {
        let (h, v) = s.0.y == s.1.y ? (s, t) : (t, s)
        guard h.0.y == h.1.y, v.0.x == v.1.x, h.0 != h.1, v.0 != v.1 else { return false }
        return (min(h.0.x, h.1.x)...max(h.0.x, h.1.x)).contains(v.0.x) && (min(v.0.y, v.1.y)...max(v.0.y, v.1.y)).contains(h.0.y)
    }

    private func onEdge(_ point: CGPoint, of rect: CGRect) -> Bool {
        rect.insetBy(dx: -0.5, dy: -0.5).contains(point) && !rect.insetBy(dx: 0.5, dy: 0.5).contains(point)
    }

    /// Every invariant the board relies on: straight segments, ends on the right cards, no line
    /// through a card, and no two lines along each other, across each other or sharing an end.
    private func check(_ connections: [Connection], _ cards: [UUID: CGRect]) {
        let routes = router.route(connections, around: cards)
        #expect(routes.count == connections.count)
        for connection in connections {
            guard let route = routes[connection.id], let first = route.points.first, let last = route.points.last else {
                Issue.record("missing route")
                continue
            }
            #expect(onEdge(first, of: cards[connection.a]!))
            #expect(onEdge(last, of: cards[connection.b]!))
            for segment in segments(route) {
                #expect(segment.0.x == segment.1.x || segment.0.y == segment.1.y, "segments are horizontal or vertical")
                let middle = CGPoint(x: (segment.0.x + segment.1.x) / 2, y: (segment.0.y + segment.1.y) / 2)
                for card in cards.values {
                    #expect(!card.insetBy(dx: 1, dy: 1).contains(middle), "no line runs through a card")
                }
            }
        }
        let all = connections.compactMap { routes[$0.id] }
        for (i, route) in all.enumerated() {
            for other in all[(i + 1)...] {
                for s in segments(route) {
                    for t in segments(other) {
                        #expect(overlap(s, t) <= 0, "lines never run along each other")
                        #expect(!cross(s, t), "lines never cross")
                    }
                }
                for end in [route.points.first, route.points.last] {
                    #expect(end != other.points.first && end != other.points.last, "lines never share an end")
                }
            }
        }
    }

    @Test func goesAroundACardInTheWay() {
        let (a, middle, b) = (UUID(), UUID(), UUID())
        let cards = [a: CGRect(x: 0, y: 0, width: 300, height: 200),
                     middle: CGRect(x: 400, y: -100, width: 300, height: 400),
                     b: CGRect(x: 800, y: 0, width: 300, height: 200)]
        check([Connection(a: a, b: b)], cards)
    }

    @Test func manyLinesBetweenFewCardsNeverOverlap() {
        let ids = (0..<4).map { _ in UUID() }
        let cards = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: CGFloat(index % 2) * 760, y: CGFloat(index / 2) * 540, width: 640, height: 420))
        })
        var connections: [Connection] = []
        for i in ids.indices { for j in ids.indices where j > i { connections.append(Connection(a: ids[i], b: ids[j])) } }
        check(connections, cards)
    }

    @Test func keepsToTheSidesTheUserPicked() {
        let (a, b) = (UUID(), UUID())
        let cards = [a: CGRect(x: 0, y: 0, width: 300, height: 200), b: CGRect(x: 500, y: 0, width: 300, height: 200)]
        let connection = Connection(a: a, b: b, aSide: .bottom, bSide: .top)
        check([connection], cards)
        let points = router.route([connection], around: cards)[connection.id]?.points ?? []
        #expect(points.first?.y == 200, "leaves from a's bottom")
        #expect(points.last?.y == 0, "arrives at b's top")
    }

    @Test func sketchReachesThePointerAroundExistingLines() {
        let (a, b) = (UUID(), UUID())
        let cards = [a: CGRect(x: 0, y: 0, width: 300, height: 200), b: CGRect(x: 500, y: 0, width: 300, height: 200)]
        let existing = Connection(a: a, b: b)
        let sketch = router.sketch([existing], around: cards, from: a, side: .bottom, to: CGPoint(x: 150, y: 400))
        let points = sketch?.points ?? []
        #expect(points.first?.y == 200)
        #expect(points.last.map { hypot($0.x - 150, $0.y - 400) <= 12 } == true)
        #expect(router.sketch([], around: cards, from: a, side: .right, to: CGPoint(x: 100, y: 100)) == nil, "inside a card")
    }

    @Test func cardsSideBySideGetAStraightLine() {
        let (a, b) = (UUID(), UUID())
        let connection = Connection(a: a, b: b)
        let routes = router.route([connection], around: [a: CGRect(x: 0, y: 0, width: 300, height: 200),
                                                         b: CGRect(x: 500, y: 0, width: 300, height: 200)])
        let points = routes[connection.id]?.points ?? []
        #expect(points.count == 2)
        #expect(points.first?.x == 300 && points.last?.x == 500)
    }
}
