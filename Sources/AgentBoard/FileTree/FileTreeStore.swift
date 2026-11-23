import AgentRuntime
import Connections
import Foundation
import Observation
import Orchestration

/// A file tree card this Mac's database kept before the cores did, with the host it's on (nil:
/// this Mac). Each moves to its host's core the first time that core answers (see `migrate`).
struct StoredFileTree: Hashable {
    var record: FileTreeRecord
    var host: UUID?
}

/// A note the user left on some lines of a file.
struct FileAnnotation: Identifiable, Hashable {
    let id = UUID()
    /// Relative to the worktree.
    let path: String
    /// One-based and sorted; they need not be contiguous.
    let lines: [Int]
    let excerpt: String
    let comment: String
}

/// The file tree cards, kept by the core of their worktree's host like post-its, so every board
/// on it shows them; the board lists their files there. What they send travels along lines.
@MainActor
@Observable
final class FileTreeStore {
    /// Notes not sent yet, per card, in the order they were written.
    private(set) var annotations: [UUID: [FileAnnotation]] = [:]
    @ObservationIgnored private let database: Database?
    /// Cards only this Mac's database has: from before the cores kept them, or added while the
    /// host's core can't keep them (it predates them, or hasn't answered yet).
    private var stored: [StoredFileTree]
    /// The stores the cards are on, by their worktree's host (nil: this Mac's).
    private var boards: [UUID?: Board] = [:]
    /// What each card shows (folders open, file open), kept while the card is off screen.
    @ObservationIgnored private var browsers: [UUID: FileBrowserModel] = [:]

    init(database: Database?) {
        self.database = database
        stored = (try? database?.fileTrees()) ?? []
    }

    private struct Board { weak var store: AgentStore? }

    private func agents(_ host: UUID? = nil) -> AgentStore? { boards[host]?.store }

    func attach(to agents: AgentStore) {
        let host = agents.host?.id
        boards[host] = Board(store: agents)
        // Only what the core can't keep is listed to it as a board element.
        agents.elementSources[ElementKind.fileTree.rawValue] = { [weak self, weak agents] in
            guard let self, agents?.fileTrees == nil else { return [] }
            return stored.filter { $0.host == host }.map(\.record).map {
                ElementInfo(id: $0.id, name: $0.name, kind: ElementKind.fileTree.rawValue, detail: nil, worktree: $0.worktree, frame: $0.frame,
                            organization: $0.organizationID)
            }
        }
        agents.elementRemovers[ElementKind.fileTree.rawValue] = { [weak self] id in
            if self?.record(id) != nil { self?.remove(id) }
        }
        agents.onWelcome = { [weak self] in self?.migrate(host) }
        migrate(host)
        agents.elementsChanged()
    }

    /// Hands the cards only this Mac has to the host's core, once it keeps file trees. A card
    /// leaves this Mac's database only once the core listed it in a welcome, so one lost on the
    /// way is sent again next time.
    func migrate(_ host: UUID?) {
        guard let agents = agents(host), let kept = agents.fileTrees else { return }
        for card in stored where card.host == host {
            if kept.contains(where: { $0.id == card.record.id }) {
                try? database?.deleteFileTree(id: card.record.id)
                stored.removeAll { $0.record.id == card.record.id }
            } else {
                agents.fileTrees?.append(card.record)
                agents.send(.addFileTree(card.record))
            }
        }
    }

    /// The cards on the host, the core's first.
    private func cards(on host: UUID?) -> [FileTreeRecord] {
        let kept = agents(host)?.fileTrees ?? []
        return kept + stored.filter { card in card.host == host && !kept.contains { $0.id == card.record.id } }.map(\.record)
    }

    private func host(of id: UUID) -> UUID? {
        boards.keys.first { cards(on: $0).contains { $0.id == id } } ?? nil
    }

    func trees(in worktree: String, on host: UUID? = nil) -> [FileTreeRecord] {
        let organization = agents()?.organizationID ?? OrganizationHome.defaultID
        return cards(on: host).filter { $0.worktree == worktree && $0.organizationID == organization }
    }

    func record(_ id: UUID) -> FileTreeRecord? {
        for host in boards.keys { if let found = cards(on: host).first(where: { $0.id == id }) { return found } }
        return nil
    }

    func browser(for record: FileTreeRecord) -> FileBrowserModel {
        if let model = browsers[record.id] { return model }
        // Another host's files are read there, by whichever store is connected to it at the time.
        let files = host(of: record.id).map { host in
            HostFiles(run: { [weak self] executable, arguments, input in await self?.agents(host)?.run(executable, arguments, input: input) },
                      carry: { [weak self] executable, arguments, input, bulk, patience in
                          await self?.agents(host)?.run(executable, arguments, input: input, bulk: bulk, patience: patience)
                      })
        }
        let model = FileBrowserModel(root: record.worktree, files: files)
        browsers[record.id] = model
        return model
    }

    @discardableResult
    func add(to worktree: String, on host: UUID? = nil, at origin: CGPoint) -> FileTreeRecord {
        let organization = agents()?.organizationID ?? OrganizationHome.defaultID
        let taken = Set(trees(in: worktree, on: host).map { $0.name.lowercased() })
        let base = L("Files")
        var name = base
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        let record = FileTreeRecord(id: UUID(), worktree: worktree, name: name, frame: CGRect(origin: origin, size: FileTreeRecord.size),
                                    organization: organization)
        if let agents = agents(host), agents.fileTrees != nil {
            agents.fileTrees?.append(record)
            agents.send(.addFileTree(record))
        } else {
            stored.append(StoredFileTree(record: record, host: host))
            try? database?.saveFileTree(stored[stored.count - 1])
            agents(host)?.elementsChanged()
        }
        return record
    }

    func remove(_ id: UUID) {
        let agents = self.agents(host(of: id))
        agents?.dropConnections(touching: id)
        if agents?.fileTrees?.contains(where: { $0.id == id }) == true {
            agents?.fileTrees?.removeAll { $0.id == id }
            agents?.send(.removeFileTree(id))
        }
        // From this Mac's database too, or the next welcome would hand it back to the core.
        if stored.contains(where: { $0.record.id == id }) {
            stored.removeAll { $0.record.id == id }
            try? database?.deleteFileTree(id: id)
            agents?.elementsChanged()
        }
        annotations[id] = nil
        browsers[id] = nil
    }

    func raise(_ id: UUID) {
        guard let agents = agents(host(of: id)), var trees = agents.fileTrees, let index = trees.firstIndex(where: { $0.id == id }),
              index != trees.count - 1 else { return }
        trees.append(trees.remove(at: index))
        agents.fileTrees = trees
    }

    func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        let host = host(of: id)
        if let agents = agents(host), let index = agents.fileTrees?.firstIndex(where: { $0.id == id }) {
            agents.fileTrees?[index].frame = frame
            if persist, let tree = agents.fileTrees?[index] { agents.send(.updateFileTree(tree)) }
        } else if let index = stored.firstIndex(where: { $0.record.id == id }) {
            stored[index].record.frame = frame
            if persist {
                try? database?.saveFileTree(stored[index])
                agents(host)?.elementsChanged()
            }
        }
    }

    // MARK: Annotations

    func annotate(_ annotation: FileAnnotation, on id: UUID) {
        annotations[id, default: []].append(annotation)
    }

    func removeAnnotation(_ annotationID: UUID, from id: UUID) {
        annotations[id]?.removeAll { $0.id == annotationID }
        if annotations[id]?.isEmpty == true { annotations[id] = nil }
    }

    func clearAnnotations(of id: UUID) {
        annotations[id] = nil
    }

    /// The agents a line joins to the card, which its notes reach.
    func connectedAgents(of id: UUID) -> [AgentRecord] {
        guard let agents = self.agents(host(of: id)) else { return [] }
        let peers = Set(agents.connections.compactMap { $0.other(than: id) })
        return agents.agents.filter { peers.contains($0.id) && $0.runner == nil }
    }

    /// Sends the card's notes to every connected agent, as one message, and forgets them.
    func sendAnnotations(of id: UUID) {
        guard let notes = annotations[id], !notes.isEmpty, let agents = self.agents(host(of: id)), !connectedAgents(of: id).isEmpty else { return }
        agents.send(.deliver(from: id, text: Self.message(for: notes)))
        annotations[id] = nil
    }

    static func message(for notes: [FileAnnotation]) -> String {
        var text = "The user left notes on files in this worktree. Address each one:\n"
        for note in notes {
            let ranges = Self.ranges(of: note.lines).map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
            let lines = (note.lines.count == 1 ? "line " : "lines ") + ranges.joined(separator: ", ")
            text += "\n\(note.path), \(lines):\n```\n\(note.excerpt)\n```\n\(note.comment)\n"
        }
        return text
    }

    /// Sorted line numbers folded into runs: [1, 2, 3, 7] is 1...3 and 7...7.
    static func ranges(of lines: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for line in lines {
            if let last = result.last, last.upperBound + 1 == line {
                result[result.count - 1] = last.lowerBound...line
            } else {
                result.append(line...line)
            }
        }
        return result
    }
}
