import Foundation

/// A side of a card, where a line may attach.
public enum Side: Int, CaseIterable, Sendable, Codable {
    case top, right, bottom, left
}

/// A line between two board elements. Undirected: messages travel both ways.
public struct Connection: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let a: UUID
    public let b: UUID
    /// The sides the user drew the line from and to; nil lets the router pick.
    public let aSide: Side?
    public let bSide: Side?

    public init(id: UUID = UUID(), a: UUID, b: UUID, aSide: Side? = nil, bSide: Side? = nil) {
        self.id = id
        self.a = a
        self.b = b
        self.aSide = aSide
        self.bSide = bSide
    }

    public func touches(_ element: UUID) -> Bool { a == element || b == element }

    /// The element at the other end from `element`, or nil when it isn't an end.
    public func other(than element: UUID) -> UUID? {
        element == a ? b : element == b ? a : nil
    }

    public func joins(_ x: UUID, _ y: UUID) -> Bool { (a == x && b == y) || (a == y && b == x) }
}

/// Which elements are connected, in the order the connections were made (earlier ones get
/// first pick of the board's routes).
public struct ConnectionGraph: Hashable, Sendable {
    public private(set) var connections: [Connection]

    public init(_ connections: [Connection] = []) {
        self.connections = connections
    }

    public func connection(between x: UUID, _ y: UUID) -> Connection? {
        connections.first { $0.joins(x, y) }
    }

    /// Elements one line away from `element`, in connection order.
    public func peers(of element: UUID) -> [UUID] {
        connections.compactMap { $0.other(than: element) }
    }

    /// Adds a line between `x` and `y`, attached to the given sides. Returns nil for a
    /// self-connection or one that exists.
    @discardableResult
    public mutating func connect(_ x: UUID, _ y: UUID, sides: (Side?, Side?) = (nil, nil)) -> Connection? {
        guard x != y, connection(between: x, y) == nil else { return nil }
        let connection = Connection(a: x, b: y, aSide: sides.0, bSide: sides.1)
        connections.append(connection)
        return connection
    }

    /// Adds `connection` as it is (drawn elsewhere, with its id). Returns false for a
    /// self-connection or one between elements already connected.
    @discardableResult
    public mutating func add(_ connection: Connection) -> Bool {
        guard connection.a != connection.b, self.connection(between: connection.a, connection.b) == nil else { return false }
        connections.append(connection)
        return true
    }

    public mutating func disconnect(_ id: UUID) {
        connections.removeAll { $0.id == id }
    }

    /// Drops every line touching `element`.
    public mutating func remove(element: UUID) {
        connections.removeAll { $0.touches(element) }
    }
}
