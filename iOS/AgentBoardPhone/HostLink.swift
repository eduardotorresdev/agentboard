import AgentRuntime
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
    private(set) var postIts: [PostIt] = []
    private(set) var media: [Media] = []
    private(set) var attention: [Attention] = []
    private(set) var decisions: [Decision] = []
    /// Pictures and videos brought from the host, by file name; nil while on their way or refused.
    private(set) var files: [String: Data] = [:]

    private var rawCards: [UUID: [String: Any]] = [:]
    /// The cards' sessions, mirroring the core's as the Mac's do (`AgentSession.host(on:id:)`).
    @ObservationIgnored private var sessions: [UUID: AgentSession] = [:]
    @ObservationIgnored private var client: CoreClient?
    private var account: Account?
    private var fetching: Set<String> = []
    private var opening = false
    private var dataFolder: String?

    init(host: Host) { self.host = host }

    // MARK: Connection

    /// Opens the channel; on a drop it opens it again by itself, keeping what the board showed.
    func connect(account: Account) {
        self.account = account
        guard !opening, client == nil else { return }
        guard let id = host.uuid, let key = Data(base64Encoded: host.public_key), let token = account.token else {
            phase = .failed("This host has no valid identity.")
            return
        }
        phase = .connecting
        let board = HostChannel.Board(key: account.boardKey, name: UIDevice.current.name)
        let addresses = host.addresses ?? []
        opening = true
        Task.detached { [weak self] in
            var took: HostChannel.Path?
            let opened = HostChannel.open(server: AccountServer.url, token: token, host: id, hostKey: key, board: board,
                                          addresses: addresses, took: { took = $0 })
            await self?.opened(opened, path: took)
        }
    }

    /// Coming back to the foreground: the channel may have died while the app slept.
    func resume() {
        guard let account else { return }
        if case .pending = phase { return }
        connect(account: account)
    }

    private func opened(_ opened: HostChannel.Opened, path: HostChannel.Path?) async {
        switch opened {
        case .pending(let trusted):
            opening = false
            phase = .pending(trusted: trusted)
        case .failed:
            opening = false
            dropped("The host didn't answer.")
        case .channel(let fd):
            self.path = path
            let result = await Task.detached { CoreClient.open(on: fd) }.value
            opening = false
            guard case .success(let client) = result else { return dropped("The host's core didn't answer.") }
            self.client = client
            client.onDisconnect = { [weak self, weak client] in
                guard let self, self.client === client else { return }
                self.dropped("Reconnecting…")
            }
            if let state = client.serviceState { welcomed(state) }
            client.onService { data in DispatchQueue.main.async { [weak self] in self?.serviced(data) } }
            phase = .connected
            // After a reconnect: the sessions shown before attach again, and get a fresh snapshot.
            for (id, session) in sessions { attach(id, session, on: client) }
        }
    }

    private func dropped(_ why: String) {
        client = nil
        phase = .failed(why)
        fetching.removeAll()
        // Tries again in a moment, while anyone still holds this link.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, case .failed = self.phase, let account = self.account,
                  UIApplication.shared.applicationState == .active else { return }
            self.connect(account: account)
        }
    }

    func disconnect() {
        account = nil
        client?.disconnect()
    }

    // MARK: Board

    var worktrees: [String] { Array(Set(cards.map(\.worktree) + postIts.map(\.worktree) + media.map(\.worktree))).sorted() }

    func cards(in worktree: String) -> [Card] { cards.filter { $0.worktree == worktree } }

    func move(_ id: UUID, to frame: CGRect) {
        guard let index = cards.firstIndex(where: { $0.id == id }), let raw = rawCards[id] else { return }
        cards[index].frame = frame
        send(BoardSay.move(raw, to: frame))
    }

    func send(_ request: Data) { client?.send(service: request) }

    /// The organization the worktree's cards belong to, so a new one lands on the same board.
    private func organization(in worktree: String) -> String? {
        rawCards.values.first { $0["worktree"] as? String == worktree }?["organization"] as? String
    }

    /// Right of everything already in the worktree.
    private func freeSpot(in worktree: String) -> CGPoint {
        let frames = cards(in: worktree).map(\.frame) + postIts.filter { $0.worktree == worktree }.map(\.frame)
            + media.filter { $0.worktree == worktree }.map(\.frame)
        let right = frames.map(\.maxX).max().map { $0 + 40 } ?? 0
        return CGPoint(x: right, y: frames.map(\.minY).min() ?? 0)
    }

    func addAgent(_ provider: any AgentProvider, to worktree: String) {
        let name = Self.unique(provider.title, among: cards(in: worktree).map(\.name))
        let id = UUID()
        send(BoardSay.addCard(id, worktree: worktree, providerID: provider.id, name: name,
                              frame: CGRect(origin: freeSpot(in: worktree), size: CGSize(width: 640, height: 420)),
                              organization: organization(in: worktree)))
        send(BoardSay.open(id, cols: 80, rows: 24, start: true))
    }

    func addRunner(_ command: String, to worktree: String) {
        let words = command.split(separator: " ").filter { !$0.contains("=") }
        let base = words.first.map { ($0 as NSString).lastPathComponent } ?? "terminal"
        let id = UUID()
        send(BoardSay.addCard(id, worktree: worktree, providerID: "runner", name: Self.unique(base, among: cards(in: worktree).map(\.name)),
                              frame: CGRect(origin: freeSpot(in: worktree), size: CGSize(width: 600, height: 340)),
                              command: command, organization: organization(in: worktree)))
        send(BoardSay.open(id, cols: 75, rows: 20, start: true))
    }

    /// Shown at once; the core's `postItUpdated` confirms it.
    func writePostIt(_ id: UUID, _ text: String) {
        if let index = postIts.firstIndex(where: { $0.id == id }) { postIts[index].text = text }
        send(BoardSay.writePostIt(id, text))
    }

    func addPostIt(_ text: String, to worktree: String) {
        let name = Self.unique("Post-it", among: postIts.filter { $0.worktree == worktree }.map(\.name))
        send(BoardSay.addPostIt(UUID(), worktree: worktree, name: name, frame: CGRect(origin: freeSpot(in: worktree), size: CGSize(width: 340, height: 320)),
                                text: text, organization: organization(in: worktree)))
    }

    /// `base`, or `base 2`, `base 3`…, as `AgentRecord.uniqueName` picks.
    nonisolated static func unique(_ base: String, among names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Programs on the host

    /// Runs a program on the host's machine: its exit status and what it printed; nil when the
    /// channel went away first.
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: Data)? {
        guard let client else { return nil }
        return await client.run(executable, arguments).map { ($0.status, $0.output) }
    }

    /// Brings a card's picture or video from the host (64 MiB at most), as the Mac does.
    func fetch(_ file: String) {
        // A plain file name inside the pictures folder, never a path out of it.
        guard files[file] == nil, !fetching.contains(file), !file.isEmpty, file != ".", file != "..",
              (file as NSString).lastPathComponent == file else { return }
        fetching.insert(file)
        Task {
            if dataFolder == nil, let ran = await run("agentboard", ["data-folder"]), ran.status == 0 {
                let path = String(decoding: ran.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("/") { dataFolder = path }
            }
            guard let folder = dataFolder else { return }
            let script = "n=$(wc -c < \"$1\") || exit 1; [ \"$n\" -le \"$2\" ] || exit 3; cat \"$1\""
            if let ran = await run("sh", ["-c", script, "sh", folder + "/images/" + file, String(64 * 1024 * 1024)]), ran.status == 0 {
                files[file] = ran.output
            }
        }
    }

    // MARK: Terminals

    /// The card's session, mirroring the core's; attached on first use.
    func session(_ id: UUID) -> AgentSession {
        if let session = sessions[id] { return session }
        let session = AgentSession(cols: 80, rows: 24)
        sessions[id] = session
        if let client { attach(id, session, on: client) }
        return session
    }

    /// Mirrors the core's session as it is; one the core doesn't have stays empty and stopped,
    /// and nothing is created there just because the phone looked.
    private func attach(_ id: UUID, _ session: AgentSession, on client: CoreClient) {
        session.host(on: client, id: id)
        session.attach()
    }

    /// The card opened full screen: an agent the core has no session for starts, as on the
    /// Mac's board; runners stay as they are (starting one is the developer's call). The size
    /// only matters for a session the core doesn't have yet.
    func open(_ id: UUID) {
        let card = cards.first { $0.id == id }
        _ = session(id)
        send(BoardSay.open(id, cols: Int((card?.frame.width ?? 640) / 8), rows: Int((card?.frame.height ?? 400) / 17),
                           start: card?.runner == nil))
    }

    func type(_ bytes: [UInt8], to id: UUID) {
        guard !bytes.isEmpty else { return }
        sessions[id]?.send(bytes)
    }

    private func welcomed(_ service: Data) {
        guard let state = try? JSONDecoder().decode(BoardSnapshot.self, from: service) else { return }
        let raw = (try? JSONSerialization.jsonObject(with: service) as? [String: Any])?["cards"] as? [[String: Any]] ?? []
        rawCards = [:]
        for card in raw { if let id = (card["id"] as? String).flatMap(UUID.init) { rawCards[id] = card } }
        cards = state.cards
        #if DEBUG
        for card in cards { DebugTerm.log("card \(card.id) runner=\(card.runner != nil) \(card.worktree) | \(card.name)") }
        #endif
        lines = state.connections
        postIts = state.postIts ?? []
        media = state.images ?? []
        attention = state.attention ?? []
        decisions = (state.decisions ?? []).filter { $0.state == .open }
    }

    private func serviced(_ data: Data) {
        guard let update = try? JSONDecoder().decode(BoardUpdate.self, from: data) else { return }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        func keepRaw(_ id: UUID) { rawCards[id] = (object?.values.first as? [String: Any])?["_0"] as? [String: Any] }
        func upsert<T: Identifiable>(_ item: T, in list: inout [T]) {
            if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item } else { list.append(item) }
        }
        switch update {
        case .cardAdded(let card), .cardUpdated(let card):
            keepRaw(card.id)
            upsert(card, in: &cards)
        case .cardRemoved(let id):
            cards.removeAll { $0.id == id }
            rawCards[id] = nil
            sessions[id]?.onChange = nil
            sessions[id] = nil
        case .connections(let lines): self.lines = lines
        case .attention(let list): attention = list
        case .decisions(let list): decisions = list.filter { $0.state == .open }
        case .postItAdded(let note), .postItUpdated(let note): upsert(note, in: &postIts)
        case .postItRemoved(let id): postIts.removeAll { $0.id == id }
        case .imageAdded(let item), .imageUpdated(let item): upsert(item, in: &media)
        case .imageRemoved(let id): media.removeAll { $0.id == id }
        }
    }
}
