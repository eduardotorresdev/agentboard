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
    /// A picture the user pasted, picked or dropped: the board stored its file with `ImageFiles`
    /// first. One whose file isn't there is ignored.
    case addImage(ImageRecord)
    /// Its name or frame changed; the core keeps its picture.
    case updateImage(ImageRecord)
    /// Forgets it and deletes its file.
    case removeImage(UUID)
    /// The developer dealt with the agent's attention request.
    case dismissAttention(UUID)
    /// The developer answered the questions the agent asked, keyed by question text; nil
    /// leaves them to the agent's terminal.
    case answerQuestions(id: UUID, answers: [String: String]?)
    /// The user sent `text` from one of the board's elements (a file tree's annotations) to
    /// every agent connected to it, or only to the connected agent `to` (an image's marks).
    case deliver(from: UUID, text: String, to: UUID? = nil)
    /// The user sent `text` from the agent card's composer: typed into its terminal as a
    /// prompt, queued behind messages so neither interrupts the other.
    case prompt(id: UUID, text: String)
    /// Delivers the messages held while the user had text on the agent's terminal line.
    case deliverHeld(UUID)
    /// The developer answered the agent's decision (after the board's undo window).
    case answerDecision(id: UUID, answer: Decision.Answer)
    /// This board serves card streams on the host's loopback (docs/streams.md); the core keeps
    /// it in memory, while the board stays, to answer `streamTicket`.
    case servesStreams(port: Int, token: String)
    /// Asks how to reach a card's stream: answered to this board alone with `streamTicket`.
    case streamTicket(card: UUID)
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
    /// The answer to a `streamTicket` request: the loopback port to open with the channel's
    /// `tcp:<port>` and the token to say first; nil when no board serves streams.
    case streamTicket(card: UUID, port: Int?, token: String?)
    case postItAdded(PostItRecord)
    /// Its name, frame or text changed.
    case postItUpdated(PostItRecord)
    case postItRemoved(UUID)
    case imageAdded(ImageRecord)
    /// Its name, frame or picture (`file`, `pixelSize`) changed.
    case imageUpdated(ImageRecord)
    case imageRemoved(UUID)
    /// Every attention request, oldest first, after any change.
    case attention([AttentionRequest])
    /// How many messages wait for the user to finish the line they typed in agent `id`'s terminal.
    case held(id: UUID, count: Int)
    /// A composer prompt agent `id` couldn't take (it stopped, or waits on the developer):
    /// back to the composer with why.
    case promptReturned(id: UUID, text: String, reason: String)
    /// Every decision, oldest first, after any change. One that closed comes once more, as
    /// `closed` with the agent's echo, and is gone from the next list.
    case decisions([Decision])
}

/// What a board gets with its welcome.
public struct BoardState: Codable, Sendable {
    public var cards: [AgentRecord]
    public var connections: [Connection]
    public var runners: RunnerReport
    /// The post-its; nil from a core that predates them.
    public var postIts: [PostItRecord]?
    /// The agents waiting on the developer; nil from a core that predates them.
    public var attention: [AttentionRequest]?
    /// The images; nil from a core that predates them.
    public var images: [ImageRecord]?
    /// The decisions waiting on the developer; nil when there are none or from a core that predates them.
    public var decisions: [Decision]?

    public init(cards: [AgentRecord], connections: [Connection], runners: RunnerReport, postIts: [PostItRecord] = [],
                attention: [AttentionRequest] = [], images: [ImageRecord] = [], decisions: [Decision] = []) {
        self.cards = cards
        self.connections = connections
        self.runners = runners
        self.postIts = postIts
        self.attention = attention
        self.images = images
        self.decisions = decisions.isEmpty ? nil : decisions
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

extension BoardRequest {
    /// The request with every name it carries made a valid one: one line of visible text, never
    /// an id. A rename to an invalid name becomes empty, which keeps the old name. The one place
    /// names from a board are cleaned on their way in.
    var withCleanNames: BoardRequest {
        func named(_ name: String, _ fallback: String) -> String { BoardName.named(name, else: fallback) }
        switch self {
        case .addCard(var record):
            record.name = named(record.name, record.runner == nil ? "Agent" : "Runner")
            return .addCard(record)
        case .updateCard(var record):
            record.name = named(record.name, "")
            return .updateCard(record)
        case .addPostIt(var record):
            record.name = named(record.name, "Post-it")
            return .addPostIt(record)
        case .updatePostIt(var record):
            record.name = named(record.name, "")
            return .updatePostIt(record)
        case .addImage(var record):
            record.name = named(record.name, record.isVideo ? "Video" : "Image")
            return .addImage(record)
        case .updateImage(var record):
            record.name = named(record.name, "")
            return .updateImage(record)
        case .elements(let list):
            return .elements(list.map { var info = $0; info.name = named(info.name, info.kind); return info })
        default:
            return self
        }
    }
}
