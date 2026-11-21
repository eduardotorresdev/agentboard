import Foundation

/// What sort of element sits at the end of a line. Open-ended: each element family adds its own.
public struct ElementKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let agent = ElementKind(rawValue: "agent")
    public static let browser = ElementKind(rawValue: "browser")
    public static let runner = ElementKind(rawValue: "runner")
    public static let simulator = ElementKind(rawValue: "simulator")
    public static let postIt = ElementKind(rawValue: "postit")
    public static let fileTree = ElementKind(rawValue: "filetree")
    public static let image = ElementKind(rawValue: "image")
    public static let video = ElementKind(rawValue: "video")
}

/// Anything on the board a line can reach: an agent's terminal, a browser, a post-it and more.
@MainActor
public protocol BoardElement: AnyObject {
    var id: UUID { get }
    /// How peers address it. Unique among the elements of one board.
    var name: String { get }
    var kind: ElementKind { get }
    /// One short line peers see next to the name (a browser's device, …), or nil.
    var detail: String? { get }
    /// The board (canvas) it sits on, so `elements(onBoardOf:)` lists only its neighbours: a
    /// worktree path, optionally followed by NUL and the organization it belongs to. One without
    /// an organization (a browser) is on that worktree in every organization; nil is on every board.
    var board: String? { get }
}

public extension BoardElement {
    var detail: String? { nil }
    var board: String? { nil }
}

/// An element that takes messages, such as an agent typing them in as a prompt.
@MainActor
public protocol MessageEndpoint: BoardElement {
    /// Why it can't take a message right now (not running, …), or nil when it can.
    var unavailableReason: String? { get }
    /// Hands `message`, sent by `sender`, to the element.
    func receive(_ message: Message, from sender: any BoardElement)
    /// Why what it was last given waits instead of going in now, or nil once it went in.
    var queueNote: String? { get }
}

public extension MessageEndpoint {
    var queueNote: String? { nil }
}

public struct Message: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let from: UUID
    public let to: UUID
    public let text: String
    public let date: Date

    public init(id: UUID = UUID(), from: UUID, to: UUID, text: String, date: Date = Date()) {
        self.id = id
        self.from = from
        self.to = to
        self.text = text
        self.date = date
    }
}

public enum MessageError: Error, Equatable, CustomStringConvertible {
    case unknownSender
    case emptyMessage
    /// `to` names nothing connected to the sender; `peers` are the names that are.
    case notConnected(to: String, peers: [String])
    case unavailable(name: String, reason: String)
    /// `name` is connected but takes no messages (a browser: it has tools of its own instead).
    case notAnEndpoint(name: String)

    public var description: String {
        switch self {
        case .unknownSender:
            "This agent is no longer on the board."
        case .emptyMessage:
            "The message is empty."
        case .notConnected(let to, let peers) where peers.isEmpty:
            "No agent named “\(to)” is connected to you, and nothing is connected yet. The user connects agents by drawing lines between them on the board."
        case .notConnected(let to, let peers):
            "No agent named “\(to)” is connected to you. Connected: \(peers.joined(separator: ", "))."
        case .unavailable(let name, let reason):
            "\(name) can't receive messages: \(reason)."
        case .notAnEndpoint(let name):
            "\(name) doesn't take messages; use its own tools instead."
        }
    }
}

/// The board's switchboard: which elements are connected, and delivery between them. A message
/// only ever travels along a line; elements with no line between them can't reach each other.
/// Tool providers ask it the same question (`peers(of:)`) to decide what a caller may reach.
@MainActor
public final class MessageBus {
    public private(set) var graph: ConnectionGraph {
        didSet { if graph != oldValue { onGraphChange?(graph) } }
    }
    private var elements: [UUID: any BoardElement] = [:]

    /// Called after every change to the connections (to persist them, redraw the lines).
    public var onGraphChange: ((ConnectionGraph) -> Void)?
    /// Called after each delivered message (to show it travel along its line).
    public var onMessage: ((Message) -> Void)?

    public init(graph: ConnectionGraph = ConnectionGraph()) {
        self.graph = graph
    }

    public func register(_ element: any BoardElement) {
        elements[element.id] = element
    }

    public func element(_ id: UUID) -> (any BoardElement)? { elements[id] }

    @discardableResult
    public func connect(_ x: UUID, _ y: UUID, sides: (Side?, Side?) = (nil, nil)) -> Connection? {
        graph.connect(x, y, sides: sides)
    }

    /// Adds a line drawn elsewhere, keeping its id.
    @discardableResult
    public func add(_ connection: Connection) -> Bool {
        graph.add(connection)
    }

    public func disconnect(_ id: UUID) {
        graph.disconnect(id)
    }

    /// Takes an element off the board: its lines go with it.
    public func remove(element id: UUID) {
        elements[id] = nil
        graph.remove(element: id)
    }

    /// The registered elements connected to `id`, in connection order.
    public func peers(of id: UUID) -> [any BoardElement] {
        graph.peers(of: id).compactMap { elements[$0] }
    }

    /// Every registered element on the same board as `id`, connected or not, itself included,
    /// ordered by kind then name.
    public func elements(onBoardOf id: UUID) -> [any BoardElement] {
        let board = elements[id]?.board
        return elements.values
            .filter { Self.sameBoard(board, $0.board) }
            .sorted { ($0.kind.rawValue, $0.name.lowercased()) < ($1.kind.rawValue, $1.name.lowercased()) }
    }

    public static func sameBoard(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a != b else { return true }
        let (x, y) = (a.split(separator: "\u{0}", omittingEmptySubsequences: false), b.split(separator: "\u{0}", omittingEmptySubsequences: false))
        return (x.count == 1 || y.count == 1) && x[0] == y[0]
    }

    /// The connected elements of `kind`, e.g. the browsers a caller may drive.
    public func peers(of id: UUID, kind: ElementKind) -> [any BoardElement] {
        peers(of: id).filter { $0.kind == kind }
    }

    /// Sends `text` from `sender` to the connected peer named `address` (case-insensitive) or
    /// whose id it is.
    @discardableResult
    public func send(_ text: String, from sender: UUID, to address: String) throws -> Message {
        guard elements[sender] != nil else { throw MessageError.unknownSender }
        let peers = peers(of: sender)
        let wanted = address.trimmingCharacters(in: .whitespaces)
        guard let target = findElement(wanted, among: peers) else {
            throw MessageError.notConnected(to: wanted, peers: peers.map(\.name))
        }
        return try deliver(text, from: sender, to: target.id)
    }

    /// Sends `text` from any registered element (a browser relaying a page's call, …) to the
    /// connected element `recipient`, which must take messages.
    @discardableResult
    public func deliver(_ text: String, from sender: UUID, to recipient: UUID) throws -> Message {
        guard let source = elements[sender] else { throw MessageError.unknownSender }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MessageError.emptyMessage }
        guard graph.connection(between: sender, recipient) != nil, let target = elements[recipient] else {
            throw MessageError.notConnected(to: elements[recipient]?.name ?? recipient.uuidString, peers: peers(of: sender).map(\.name))
        }
        guard let target = target as? any MessageEndpoint else { throw MessageError.notAnEndpoint(name: target.name) }
        if let reason = target.unavailableReason { throw MessageError.unavailable(name: target.name, reason: reason) }
        let message = Message(from: sender, to: target.id, text: text)
        target.receive(message, from: source)
        onMessage?(message)
        return message
    }
}
