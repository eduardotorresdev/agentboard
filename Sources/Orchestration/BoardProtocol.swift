import AgentRuntime
import Connections
import Foundation

// What the board and the core's `Orchestrator` say to each other, in the core socket's
// `service` frames (JSON). The core owns the cards and the lines; a board mirrors them, sends
// the user's changes, and runs the tools only it can (browsers).

/// Board → core.
public enum BoardRequest: Codable, Sendable {
    case addCard(AgentRecord)
    /// Its name, frame or runner changed.
    case updateCard(AgentRecord)
    /// Ends its program and forgets it.
    case removeCard(UUID)
    case connect(Connection)
    case disconnect(UUID)
    /// Every other element the board has (browsers): lines to any it no longer lists go.
    case elements([ElementInfo])
    /// Attaches the board to the card's session (status, snapshot, output). A session the core
    /// doesn't have yet is created at `cols`×`rows`, and its program started when `start`
    /// (shown as stopped otherwise); one it has is left as it is.
    case open(id: UUID, cols: Int, rows: Int, start: Bool)
    /// Runs the card's program again: an agent that ended, or a runner (stopped first), with
    /// `command` from now on when given.
    case restart(id: UUID, command: String?)
    case startRunner(UUID)
    case stopRunner(UUID)
    case toolResult(call: UUID, result: WireToolResult)
    case addPostIt(PostItRecord)
    /// Its name or frame changed; the core keeps its text.
    case updatePostIt(PostItRecord)
    case removePostIt(UUID)
    /// The user rewrote its text.
    case writePostIt(id: UUID, text: String)
}

/// Core → board.
public enum BoardEvent: Codable, Sendable {
    case cardAdded(AgentRecord)
    case cardUpdated(AgentRecord)
    case cardRemoved(UUID)
    /// Every line, after any change.
    case connections([Connection])
    /// A message travelled along a line.
    case message(Message)
    case runners(RunnerReport)
    /// A tool only the board can run (the browser tools): answer with `toolResult`.
    case toolCall(call: UUID, name: String, arguments: Data, caller: UUID)
    case postItAdded(PostItRecord)
    /// Its name, frame or text changed.
    case postItUpdated(PostItRecord)
    case postItRemoved(UUID)
}

/// What a board gets with its welcome.
public struct BoardState: Codable, Sendable {
    public var cards: [AgentRecord]
    public var connections: [Connection]
    public var runners: RunnerReport
    /// The post-its; nil from a core that predates them.
    public var postIts: [PostItRecord]?

    public init(cards: [AgentRecord], connections: [Connection], runners: RunnerReport, postIts: [PostItRecord] = []) {
        self.cards = cards
        self.connections = connections
        self.runners = runners
        self.postIts = postIts
    }
}

/// What the running runners serve and cost, and when each started.
public struct RunnerReport: Codable, Equatable, Sendable {
    public var stats: [UUID: RunnerStats] = [:]
    public var starts: [UUID: Date] = [:]
    /// This Mac's address on the local network, for ports other devices can reach.
    public var networkAddress: String?

    public init() {}
}

/// A `ToolResult` on the wire.
public struct WireToolResult: Codable, Sendable {
    enum Item: Codable {
        case text(String)
        case image(Data, mimeType: String)
    }

    var items: [Item]
    var isError: Bool

    public init(_ result: ToolResult) {
        items = result.content.map {
            switch $0 {
            case .text(let text): .text(text)
            case .image(let data, let mimeType): .image(data, mimeType: mimeType)
            }
        }
        isError = result.isError
    }

    public var result: ToolResult {
        ToolResult(items.map {
            switch $0 {
            case .text(let text): .text(text)
            case .image(let data, let mimeType): .image(data, mimeType: mimeType)
            }
        }, isError: isError)
    }
}

extension BoardRequest {
    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public init?(_ data: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
}

extension BoardEvent {
    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public init?(_ data: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
}

extension BoardState {
    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public init?(_ data: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
}

extension CoreClient {
    public func send(_ request: BoardRequest) { send(service: request.encoded) }
}
