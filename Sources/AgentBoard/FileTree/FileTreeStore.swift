import AgentRuntime
import Connections
import Foundation
import Observation
import Orchestration

/// A file tree card: the worktree's files, one open beside them, and the user's notes on its
/// lines, which go to the agents connected to the card.
struct FileTreeRecord: Identifiable, Hashable {
    let id: UUID
    let worktree: String
    var name: String
    var frame: CGRect
    var organization: UUID

    static let size = CGSize(width: 1040, height: 680)
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

/// The file tree cards, kept in the board's database. The core only learns of them as elements
/// lines reach; what they send travels along those lines.
@MainActor
@Observable
final class FileTreeStore {
    private(set) var trees: [FileTreeRecord] = []
    /// Notes not sent yet, per card, in the order they were written.
    private(set) var annotations: [UUID: [FileAnnotation]] = [:]
    @ObservationIgnored private let database: Database?
    @ObservationIgnored private weak var agents: AgentStore?
    /// What each card shows (folders open, file open), kept while the card is off screen.
    @ObservationIgnored private var browsers: [UUID: FileBrowserModel] = [:]

    init(database: Database?) {
        self.database = database
        trees = (try? database?.fileTrees()) ?? []
    }

    func attach(to agents: AgentStore) {
        self.agents = agents
        agents.elementSources[ElementKind.fileTree.rawValue] = { [weak self] in
            self?.trees.map { ElementInfo(id: $0.id, name: $0.name, kind: ElementKind.fileTree.rawValue, detail: nil,
                                          worktree: $0.worktree, frame: $0.frame) } ?? []
        }
        agents.elementsChanged()
    }

    func trees(in worktree: String) -> [FileTreeRecord] {
        let organization = agents?.organizationID ?? OrganizationHome.defaultID
        return trees.filter { $0.worktree == worktree && $0.organization == organization }
    }

    func record(_ id: UUID) -> FileTreeRecord? {
        trees.first { $0.id == id }
    }

    func browser(for record: FileTreeRecord) -> FileBrowserModel {
        if let model = browsers[record.id] { return model }
        let model = FileBrowserModel(root: record.worktree)
        browsers[record.id] = model
        return model
    }

    @discardableResult
    func add(to worktree: String, at origin: CGPoint) -> FileTreeRecord {
        let organization = agents?.organizationID ?? OrganizationHome.defaultID
        let taken = Set(trees(in: worktree).map { $0.name.lowercased() })
        let base = L("Files")
        var name = base
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        let record = FileTreeRecord(id: UUID(), worktree: worktree, name: name, frame: CGRect(origin: origin, size: FileTreeRecord.size),
                                    organization: organization)
        trees.append(record)
        try? database?.saveFileTree(record)
        agents?.elementsChanged()
        return record
    }

    func remove(_ id: UUID) {
        agents?.dropConnections(touching: id)
        trees.removeAll { $0.id == id }
        annotations[id] = nil
        browsers[id] = nil
        try? database?.deleteFileTree(id: id)
        agents?.elementsChanged()
    }

    func raise(_ id: UUID) {
        guard let index = trees.firstIndex(where: { $0.id == id }), index != trees.count - 1 else { return }
        trees.append(trees.remove(at: index))
    }

    func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = trees.firstIndex(where: { $0.id == id }) else { return }
        trees[index].frame = frame
        if persist {
            try? database?.saveFileTree(trees[index])
            agents?.elementsChanged()
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
        guard let agents else { return [] }
        let peers = Set(agents.connections.compactMap { $0.other(than: id) })
        return agents.agents.filter { peers.contains($0.id) && $0.runner == nil }
    }

    /// Sends the card's notes to every connected agent, as one message, and forgets them.
    func sendAnnotations(of id: UUID) {
        guard let notes = annotations[id], !notes.isEmpty, let agents, !connectedAgents(of: id).isEmpty else { return }
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
