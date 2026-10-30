import AgentRuntime
import Foundation

/// A board's line to the core: connects, and when the core goes away (it crashed, was killed,
/// or a new build replaced it) connects again on its own, launching one if none answers.
/// Requests sent meanwhile wait and go out once it is back, after the new state arrived.
@MainActor
public final class CoreLink {
    public private(set) var client: CoreClient?
    private let connect: @Sendable () -> Result<CoreClient, CoreClient.Failure>
    /// The versions of the incompatible core last reported, so each is reported once.
    private var reportedIncompatible: CoreProtocol.Versions?
    private var pending: [BoardRequest] = []
    private var connecting = false
    private var closed = false
    private var lostSince: Date?
    private var reportedDown = false

    /// Called on each connection, the first and every one after a loss, with the core's state
    /// and the requests still waiting to go (sent right after this returns).
    public var onConnect: ((CoreClient, BoardState, [BoardRequest]) -> Void)?
    public var onEvent: ((BoardEvent) -> Void)?
    /// Called once when the core has been gone for `patience` seconds; connecting goes on.
    public var onDown: (() -> Void)?
    /// Called when the core answering speaks no protocol version this build does (another
    /// build's), with the ones it speaks; connecting goes on, for when it is replaced.
    public var onIncompatible: ((CoreProtocol.Versions) -> Void)?
    /// How long a loss may last before `onDown`.
    public var patience: Double = 10
    /// How long between attempts to reconnect.
    public var retryInterval: Double = 0.25

    /// `connect` finds or launches a core; it blocks, and runs off the main thread.
    public init(connect: @escaping @Sendable () -> Result<CoreClient, CoreClient.Failure>) {
        self.connect = connect
    }

    public var isConnected: Bool { client != nil }

    /// Connects; false if it couldn't, in which case nothing retries. When no core answers,
    /// `fallback` may start one and give its socket (a core inside this process). A core of
    /// another build is reported, and retried.
    public func start(fallback: (() -> String?)? = nil) async -> Bool {
        let connect = self.connect
        switch await Task.detached(priority: .userInitiated, operation: { connect() }).value {
        case .success(let client):
            adopt(client)
            return true
        case .failure(.incompatible(let core)):
            incompatible(core)
            lostSince = Date()
            reconnect()
            return true
        case .failure(.noCore):
            break
        }
        guard let path = fallback?() else { return false }
        guard let client = await Task.detached(priority: .userInitiated, operation: { CoreClient.connect(socketPath: path) }).value else {
            return false
        }
        adopt(client)
        return true
    }

    /// Hangs up for good, as a board that quits.
    public func close() {
        closed = true
        pending.removeAll()
        let client = self.client
        self.client = nil
        client?.disconnect()
    }

    public func send(_ request: BoardRequest) {
        guard !closed else { return }
        if let client { client.send(request) } else { pending.append(request) }
    }

    private func adopt(_ client: CoreClient) {
        guard !closed else { return client.disconnect() }
        let state = client.serviceState.flatMap(BoardState.init) ?? BoardState(cards: [], connections: [], runners: RunnerReport())
        self.client = client
        lostSince = nil
        reportedDown = false
        reportedIncompatible = nil
        client.onDisconnect = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.lost()
        }
        let waiting = pending
        pending.removeAll()
        onConnect?(client, state, waiting)
        client.onService { [weak self] data in
            guard let event = BoardEvent(data) else { return }
            DispatchQueue.main.async { self?.onEvent?(event) }
        }
        waiting.forEach(client.send)
    }

    private func incompatible(_ core: CoreProtocol.Versions) {
        guard reportedIncompatible != core else { return }
        reportedIncompatible = core
        // Said already, more plainly than "gone".
        reportedDown = true
        onIncompatible?(core)
    }

    private func lost() {
        client = nil
        lostSince = lostSince ?? Date()
        reconnect()
    }

    private func reconnect() {
        guard !connecting, client == nil, !closed else { return }
        connecting = true
        let connect = self.connect
        Task {
            let found = await Task.detached(priority: .userInitiated, operation: { connect() }).value
            connecting = false
            switch found {
            case .success(let client): return adopt(client)
            case .failure(.incompatible(let core)): incompatible(core)
            case .failure(.noCore): break
            }
            if !reportedDown, let lostSince, Date().timeIntervalSince(lostSince) >= patience {
                reportedDown = true
                onDown?()
            }
            try? await Task.sleep(for: .seconds(retryInterval))
            reconnect()
        }
    }
}

extension BoardState {
    /// The cards and lines with `requests` applied, as a board that sent them sees them before
    /// the core has.
    public func applying(_ requests: [BoardRequest]) -> BoardState {
        var state = self
        for request in requests {
            switch request {
            case .addCard(let record) where !state.cards.contains { $0.id == record.id }:
                state.cards.append(record)
            case .updateCard(let record):
                if let index = state.cards.firstIndex(where: { $0.id == record.id }) { state.cards[index] = record }
            case .removeCard(let id), .removeNotes(let id):
                state.cards.removeAll { $0.id == id }
                state.notes?.removeAll { $0.id == id }
                state.connections.removeAll { $0.touches(id) }
            case .addNotes(let record) where state.notes?.contains { $0.id == record.id } != true:
                state.notes = (state.notes ?? []) + [record]
            case .updateNotes(let record):
                if let index = state.notes?.firstIndex(where: { $0.id == record.id }) {
                    state.notes?[index].name = record.name
                    state.notes?[index].frame = record.frame
                }
            case .writeNote(let notes, let entry):
                if let index = state.notes?.firstIndex(where: { $0.id == notes }) { state.notes?[index].write(entry) }
            case .deleteNote(let notes, let entry):
                if let index = state.notes?.firstIndex(where: { $0.id == notes }) { state.notes?[index].entries.removeAll { $0.id == entry } }
            case .connect(let connection) where !state.connections.contains { $0.joins(connection.a, connection.b) }:
                state.connections.append(connection)
            case .disconnect(let id):
                state.connections.removeAll { $0.id == id }
            default:
                break
            }
        }
        return state
    }
}
