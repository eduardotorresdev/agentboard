import AppKit
import Connections
import Foundation
import Observation
import Orchestration

/// Lasting lines between agents of different worktrees or hosts, made when the user writes to
/// one with `@@`. Each agent's board shows the other as a relay card, connected to it by an
/// ordinary line; what an agent sends its relay (`send_message`), this board hears from its core
/// and carries to the other's core, delivered from the relay there. Cores never talk to each
/// other: while no board is open, relays say so.
@MainActor
@Observable
final class AgentLinks {
    /// One agent of a link, and the relay standing for the other one on its board.
    struct End: Codable, Hashable {
        let agent: UUID
        /// Where the agent's core runs; nil is this Mac.
        let host: UUID?
        let worktree: String
        /// The relay on this agent's board, standing for the other end's agent.
        let relay: UUID
        var frame: CGRect
        /// As last known, for when its host isn't connected: the agent's name, `Project ›
        /// Worktree`, and its host's name.
        var name: String
        var place: String
        var hostName: String
    }

    struct Link: Codable, Hashable, Identifiable {
        let id: UUID
        let organization: UUID
        var ends: [End]

        func other(than end: End) -> End? { ends.first { $0 != end } }
    }

    /// A relay card as the board draws it.
    struct Relay: Identifiable {
        let id: UUID
        let worktree: String
        let frame: CGRect
        /// The agent it stands for.
        let name: String
        let place: String
        let provider: String?
        let status: CardStatus?
    }

    static let family = "agentlink"
    static let relaySize = CGSize(width: 320, height: CardMetrics.titleHeight)

    private(set) var links: [Link] = []
    /// Lines some core has listed: only these can be taken away.
    @ObservationIgnored private var confirmedLines: Set<UUID> = []
    private let database: Database?
    @ObservationIgnored private weak var projects: ProjectStore?
    /// The store of a host in use (nil: this Mac), and every store in use; set by the app.
    @ObservationIgnored var store: (UUID?) -> AgentStore? = { _ in nil }
    @ObservationIgnored var stores: () -> [AgentStore] = { [] }

    init(database: Database?, projects: ProjectStore?) {
        self.database = database
        self.projects = projects
        links = (try? database?.agentLinks()) ?? []
    }

    /// Puts the relays on `agents`' board and carries what its agents send them.
    func attach(to agents: AgentStore) {
        let host = agents.host?.id
        agents.agentLinks = self
        agents.elementSources[Self.family] = { [weak self] in self?.elementInfos(on: host) ?? [] }
        agents.elementRemovers[Self.family] = { [weak self] id in self?.links.first { $0.ends.contains { $0.relay == id } }.map { self?.remove($0) } }
        agents.elementMovers[Self.family] = { [weak self] id, point in
            if let frame = self?.relay(id)?.frame { self?.setFrame(CGRect(origin: point, size: frame.size), for: id, persist: true) }
        }
        agents.onRelayMessage = { [weak self, weak agents] message in
            guard let self, let agents else { return }
            carry(message, heardBy: agents)
        }
        agents.onConnectionsChange = { [weak self, weak agents] old in
            guard let self, let agents else { return }
            linesChanged(in: agents, from: old)
        }
        agents.elementsChanged()
    }

    // MARK: Making and ending

    /// Links agent `a` (in `storeA`) with `b` (in `storeB`), once: the link already there, or
    /// a new one with a relay of each next to the other.
    @discardableResult
    func link(_ a: UUID, in storeA: AgentStore, with b: UUID, in storeB: AgentStore) -> Link? {
        if let existing = links.first(where: { Set($0.ends.map(\.agent)) == [a, b] }) { return existing }
        guard let recordA = storeA.record(a), let recordB = storeB.record(b), a != b else { return nil }
        let link = Link(id: UUID(), organization: recordA.organizationID,
                        ends: [end(recordA, in: storeA), end(recordB, in: storeB)])
        links.append(link)
        try? database?.saveAgentLink(link)
        refresh()
        return link
    }

    private func end(_ record: AgentRecord, in store: AgentStore) -> End {
        let host = store.host?.id
        // Below the relays it has, right of its card.
        let others = links.flatMap(\.ends).filter { $0.agent == record.id }.count
        let frame = CGRect(origin: CGPoint(x: record.frame.maxX + 48, y: record.frame.minY + CGFloat(others) * (Self.relaySize.height + 16)),
                           size: Self.relaySize)
        return End(agent: record.id, host: host, worktree: record.worktree, relay: UUID(), frame: frame, name: record.name,
                   place: place(of: record.worktree), hostName: store.host?.name ?? Foundation.Host.current().localizedName ?? "Mac")
    }

    /// `Project › Worktree`, as the composer's `@@` list shows it.
    func place(of worktree: String) -> String {
        guard let projects else { return (worktree as NSString).lastPathComponent }
        let place = projects.place(ofPath: worktree)
        return [place.project ?? RemoteAgent.project(ofFolder: worktree), place.worktree].compactMap(\.self).joined(separator: " › ")
    }

    /// Ends the link on both boards: the relays go, and their lines with them.
    func remove(_ link: Link) {
        links.removeAll { $0.id == link.id }
        try? database?.deleteAgentLink(id: link.id)
        for end in link.ends { store(end.host)?.dropConnections(touching: end.relay) }
        refresh()
    }

    func setFrame(_ frame: CGRect, for relay: UUID, persist: Bool) {
        guard let index = links.firstIndex(where: { $0.ends.contains { $0.relay == relay } }),
              let end = links[index].ends.firstIndex(where: { $0.relay == relay }) else { return }
        links[index].ends[end].frame = frame
        if persist {
            try? database?.saveAgentLink(links[index])
            refresh()
        }
    }

    // MARK: What boards see

    /// The name the relay for `end`'s other agent has on `end`'s board, as `list_peers` shows it.
    func relayName(on end: End, in link: Link) -> String {
        guard let other = link.other(than: end) else { return "" }
        let current = store(other.host)?.record(other.agent)?.name ?? other.name
        let elsewhere = other.host != end.host ? " on \(other.hostName)" : ""
        return "\(current) (\(other.place)\(elsewhere))"
    }

    /// The relays on `host`'s boards.
    func relays(on host: UUID?) -> [Relay] {
        links.flatMap { link in
            link.ends.filter { $0.host == host }.compactMap { end -> Relay? in
                guard let other = link.other(than: end) else { return nil }
                let record = store(other.host)?.record(other.agent)
                return Relay(id: end.relay, worktree: end.worktree, frame: end.frame, name: record?.name ?? other.name,
                             place: other.host != end.host ? "\(other.place) · \(other.hostName)" : other.place,
                             provider: record?.providerID, status: record.flatMap { store(other.host)?.cardStatus($0) })
            }
        }
    }

    func relay(_ id: UUID) -> Relay? {
        links.lazy.compactMap { link in link.ends.first { $0.relay == id }.map { (link, $0) } }.first.flatMap { _, end in
            relays(on: end.host).first { $0.id == id }
        }
    }

    private func elementInfos(on host: UUID?) -> [ElementInfo] {
        links.flatMap { link in
            link.ends.filter { $0.host == host }.compactMap { end -> ElementInfo? in
                guard let other = link.other(than: end) else { return nil }
                return ElementInfo(id: end.relay, name: relayName(on: end, in: link), kind: ElementKind.agent.rawValue,
                                   detail: "an agent in another worktree, reached through this board", worktree: end.worktree,
                                   frame: end.frame, organization: link.organization, relay: true, unavailable: unavailable(other))
            }
        }
    }

    /// Why a message for `end`'s agent couldn't get there now.
    private func unavailable(_ end: End) -> String? {
        guard let store = store(end.host), store.isLoaded else { return "its host isn't connected to this board" }
        return store.record(end.agent) == nil ? "it is no longer on its board" : nil
    }

    /// Every board lists its relays again, and has its lines to them.
    func refresh() {
        for store in stores() {
            store.elementsChanged()
            drawLines(in: store)
        }
    }

    private func drawLines(in store: AgentStore) {
        guard store.isLoaded else { return }
        for end in links.flatMap(\.ends) where end.host == store.host?.id && store.record(end.agent) != nil {
            store.connect(end.agent, end.relay)
        }
    }

    // MARK: Carrying

    /// What an agent sent its relay goes to the agent the relay stands for, from the relay
    /// standing for the sender there.
    func carry(_ message: Message, heardBy store: AgentStore) {
        guard let link = links.first(where: { $0.ends.contains { $0.relay == message.to && $0.host == store.host?.id } }),
              let end = link.ends.first(where: { $0.relay == message.to }), message.from == end.agent,
              let other = link.other(than: end), let there = self.store(other.host) else { return }
        there.send(.deliver(from: other.relay, text: message.text, to: other.agent))
    }

    /// A line to a relay that went (the user or an agent took it away) ends the link; one the
    /// core lacks (it started without it) is drawn again.
    private func linesChanged(in store: AgentStore, from old: [Connection]?) {
        let host = store.host?.id
        // A core just answered: relays elsewhere may be reachable now.
        guard let old else { return refresh() }
        do {
            let now = Set(store.connections.map(\.id))
            defer { confirmedLines.formUnion(now) }
            // Only a line the core already had can have been taken away: one just drawn here and not
            // yet in the core's list (the other end's, drawn right after) is still on its way.
            for gone in old where !now.contains(gone.id) && confirmedLines.contains(gone.id) {
                if let link = links.first(where: { $0.ends.contains { $0.host == host && gone.joins($0.agent, $0.relay) } }) {
                    remove(link)
                    return
                }
            }
        }
        drawLines(in: store)
    }

    // MARK: Lookup

    /// The store whose board has agent `id`.
    func store(of id: UUID) -> AgentStore? {
        stores().first { $0.record(id) != nil }
    }
}
