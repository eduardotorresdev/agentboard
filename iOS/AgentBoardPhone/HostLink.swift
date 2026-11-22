import CryptoKit
import Foundation
import TerminalCore
import UIKit

/// One host's core, reached over a sealed channel (`HostChannel`), and the board it serves: the
/// cards, the lines, who waits for the user, and the terminals the phone mirrors.
@MainActor @Observable final class HostLink {
    enum Phase: Equatable {
        case connecting
        case connected
        /// The host doesn't trust this phone yet; it trusts `trusted` other boards.
        case pending(trusted: Int)
        case failed(String)
    }

    let host: Host
    private(set) var phase: Phase = .connecting
    private(set) var path: HostChannel.Path?
    private(set) var cards: [Card] = []
    private(set) var lines: [Line] = []
    private(set) var attention: [Attention] = []
    private(set) var decisions: [Decision] = []
    /// Bumped whenever a mirrored terminal changed, so views redraw.
    private(set) var screens = 0

    private var rawCards: [UUID: [String: Any]] = [:]
    private var terminals: [UUID: Terminal] = [:]
    private var socket: CoreSocket?
    private let queue = DispatchQueue(label: "agentboard.phone.core")

    init(host: Host) { self.host = host }

    func connect(account: Account) {
        guard let id = host.uuid, let key = Data(base64Encoded: host.public_key), let token = account.token else {
            phase = .failed("This host has no valid identity.")
            return
        }
        phase = .connecting
        let board = HostChannel.Board(key: account.boardKey, name: UIDevice.current.name)
        let addresses = host.addresses ?? []
        Task.detached { [weak self] in
            var took: HostChannel.Path?
            let opened = HostChannel.open(server: AccountServer.url, token: token, host: id, hostKey: key, board: board,
                                          addresses: addresses, took: { took = $0 })
            await self?.opened(opened, path: took)
        }
    }

    private func opened(_ opened: HostChannel.Opened, path: HostChannel.Path?) {
        switch opened {
        case .pending(let trusted): phase = .pending(trusted: trusted)
        case .failed: phase = .failed("The host didn't answer.")
        case .channel(let fd):
            self.path = path
            let socket = CoreSocket(fd: fd, queue: queue)
            socket.onFrame = { kind, payload in
                let bytes = Array(payload)
                DispatchQueue.main.async { [weak self] in self?.received(kind, bytes) }
            }
            socket.onClose = { DispatchQueue.main.async { [weak self] in self?.phase = .failed("The connection ended.") } }
            socket.start()
            socket.send(CoreRequest.hello(version: CoreProtocol.version, oldest: CoreProtocol.oldest))
            self.socket = socket
        }
    }

    func disconnect() { socket?.close() }

    // MARK: Board

    var worktrees: [String] { Array(Set(cards.map(\.worktree))).sorted() }

    func cards(in worktree: String) -> [Card] { cards.filter { $0.worktree == worktree } }

    func move(_ id: UUID, to frame: CGRect) {
        guard let index = cards.firstIndex(where: { $0.id == id }), let raw = rawCards[id] else { return }
        cards[index].frame = frame
        send(BoardSay.move(raw, to: frame))
    }

    func send(_ request: Data) { socket?.send(.service, Array(request)) }

    // MARK: Terminals

    /// The card's terminal, attached to its session on first use.
    func terminal(_ id: UUID) -> Terminal {
        if let terminal = terminals[id] { return terminal }
        let card = cards.first { $0.id == id }
        let terminal = Terminal(cols: 80, rows: 24)
        terminals[id] = terminal
        // The size only matters for a session the core doesn't have yet; one it has keeps its own.
        send(BoardSay.open(id, cols: Int((card?.frame.width ?? 640) / 8), rows: Int((card?.frame.height ?? 400) / 17)))
        return terminal
    }

    func type(_ bytes: [UInt8], to id: UUID) {
        guard !bytes.isEmpty else { return }
        socket?.send(.data, id: id, bytes)
    }

    // MARK: Frames

    private func received(_ kind: FrameKind, _ payload: [UInt8]) {
        switch kind {
        case .control:
            guard let event = try? JSONDecoder().decode(CoreEvent.self, from: Data(payload)) else { return }
            if case .welcome(_, _, _, let service) = event {
                phase = .connected
                if let service { welcomed(service) }
            }
        case .service:
            serviced(Data(payload))
        case .snapshot:
            guard let id = UUID(bytes: payload[...]), let terminal = terminals[id] else { return }
            _ = terminal.restore(Array(payload.dropFirst(16)))
            screens += 1
        case .data:
            guard let id = UUID(bytes: payload[...]), let terminal = terminals[id] else { return }
            terminal.feed(Array(payload.dropFirst(16)))
            // The Mac board answers the program's queries; a mirror only shows.
            _ = terminal.takeOutput()
            screens += 1
        }
    }

    private func welcomed(_ service: Data) {
        guard let state = try? JSONDecoder().decode(BoardSnapshot.self, from: service) else { return }
        let raw = (try? JSONSerialization.jsonObject(with: service) as? [String: Any])?["cards"] as? [[String: Any]] ?? []
        for card in raw { if let id = (card["id"] as? String).flatMap(UUID.init) { rawCards[id] = card } }
        cards = state.cards
        lines = state.connections
        attention = state.attention ?? []
        decisions = state.decisions ?? []
    }

    private func serviced(_ data: Data) {
        guard let update = try? JSONDecoder().decode(BoardUpdate.self, from: data) else { return }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        func keepRaw(_ id: UUID) { rawCards[id] = (object?.values.first as? [String: Any])?["_0"] as? [String: Any] }
        switch update {
        case .cardAdded(let card):
            keepRaw(card.id)
            cards.append(card)
        case .cardUpdated(let card):
            keepRaw(card.id)
            if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card }
        case .cardRemoved(let id):
            cards.removeAll { $0.id == id }
            rawCards[id] = nil
            terminals[id] = nil
        case .connections(let lines): self.lines = lines
        case .attention(let list): attention = list
        case .decisions(let list): decisions = list.filter { $0.state == .open }
        }
    }
}

/// Where organizations, projects and worktrees come from. Screens read only this, so the
/// source can move (the Mac, the vault, each host) without touching them.
@MainActor protocol CatalogSource {
    func worktrees(on link: HostLink) -> [Worktree]
}

struct Worktree: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var title: String { (path as NSString).lastPathComponent }
    var project: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

/// shortcut: worktrees are the folders the host's cards live in; an empty worktree doesn't show.
/// Swap in a real catalog (organizations, projects) once one is reachable from the phone.
struct HostCardsCatalog: CatalogSource {
    func worktrees(on link: HostLink) -> [Worktree] { link.worktrees.map(Worktree.init) }
}
