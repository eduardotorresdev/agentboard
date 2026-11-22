import AgentRuntime
import Foundation

/// The connections watching each card, so a backend fans frames out without knowing them.
/// Thread-safe: frames arrive on video threads.
final class StreamTaps: @unchecked Sendable {
    typealias Sink = @Sendable (StreamWire.Out) -> Void
    private var sinks: [UUID: [UUID: Sink]] = [:]
    private var headers: [UUID: StreamWire.Header] = [:]
    private let lock = NSLock()

    /// Adds `sink` to `card`; the returned id removes it. The last header goes out at once.
    func add(_ card: UUID, _ sink: @escaping Sink) -> UUID {
        let id = UUID()
        let header = lock.withLock { () -> StreamWire.Header? in
            sinks[card, default: [:]][id] = sink
            return headers[card]
        }
        if let header { sink(.header(header)) }
        return id
    }

    /// True when it was the card's last one.
    @discardableResult
    func remove(_ card: UUID, _ id: UUID) -> Bool {
        lock.withLock {
            sinks[card]?[id] = nil
            if sinks[card]?.isEmpty == true { sinks[card] = nil }
            return sinks[card] == nil
        }
    }

    func watched(_ card: UUID) -> Bool { lock.withLock { sinks[card] != nil } }

    /// Forgets the card's header, so the next one goes out even if unchanged: a restarted
    /// source's clients learn to start over.
    func reset(_ card: UUID) { lock.withLock { headers[card] = nil } }

    /// Sends to every sink of `card`; a header is also kept for those added later, and only
    /// sent when it changed.
    func send(_ card: UUID, _ out: StreamWire.Out) {
        let targets = lock.withLock { () -> [Sink] in
            if case .header(let header) = out {
                guard headers[card] != header else { return [] }
                headers[card] = header
            }
            return sinks[card].map { Array($0.values) } ?? []
        }
        targets.forEach { $0(out) }
    }
}
