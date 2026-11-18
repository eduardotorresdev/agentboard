import Connections
import CoreGraphics
import Foundation

/// A memorized canvas: its cards, where they sit and the lines between them, to lay out again
/// on another worktree of the same project. Pictures and videos stay out: their files belong
/// to the cards that hold them.
struct CanvasTemplate: Identifiable, Codable, Equatable {
    struct Card: Codable, Equatable {
        enum Kind: String, Codable { case agent, runner, postIt, browser, fileTree }

        var kind: Kind
        var name: String
        var frame: CGRect
        /// Agents: which agent the card runs, and whether it coordinates the ones connected to it.
        var provider: String?
        var orchestrates: Bool?
        /// Runners: what they run, and where (see `relative`).
        var command: String?
        var directory: String?
        /// Post-its: what is written on them.
        var text: String?
        /// Browsers: the screen they emulate (`BrowserDevice.stored`), their page and profile.
        var device: String?
        var url: String?
        var profile: UUID?
    }

    /// A line between two cards, by their place in `cards`.
    struct Line: Codable, Equatable {
        var a: Int
        var b: Int
        var aSide: Side?
        var bSide: Side?
    }

    var id = UUID()
    var cards: [Card]
    var lines: [Line]

    /// The lines among the cards whose ids are `ids`, in the cards' order.
    static func lines(_ connections: [Connection], among ids: [UUID]) -> [Line] {
        connections.compactMap { connection in
            guard let a = ids.firstIndex(of: connection.a), let b = ids.firstIndex(of: connection.b) else { return nil }
            return Line(a: a, b: b, aSide: connection.aSide, bSide: connection.bSide)
        }
    }

    /// A runner's folder as the template keeps it: inside the worktree, the path from it, so
    /// another worktree runs it in its own copy of the folder; elsewhere, the folder itself.
    static func relative(_ directory: String, to worktree: String) -> String {
        if directory == worktree { return "" }
        return directory.hasPrefix(worktree + "/") ? String(directory.dropFirst(worktree.count + 1)) : directory
    }

    /// The folder `relative` kept, in `worktree`.
    static func resolve(_ directory: String, in worktree: String) -> String {
        if directory.isEmpty { return worktree }
        return directory.hasPrefix("/") ? directory : worktree + "/" + directory
    }

    /// What it holds, per kind of card it has: the kind's toolbar symbol, how many, and that in words.
    var counts: [(symbol: String, count: Int, label: String)] {
        func count(_ kinds: Card.Kind...) -> Int { cards.count { kinds.contains($0.kind) } }
        let parts: [(String, Int, String, String)] = [
            ("terminal", count(.agent), L("1 agent"), L("\(count(.agent)) agents")),
            ("play.circle", count(.runner), L("1 runner"), L("\(count(.runner)) runners")),
            ("note.text", count(.postIt), L("1 post-it"), L("\(count(.postIt)) post-its")),
            ("globe", count(.browser), L("1 browser"), L("\(count(.browser)) browsers")),
            ("folder", count(.fileTree), L("1 file tree"), L("\(count(.fileTree)) file trees")),
        ]
        return parts.filter { $0.1 > 0 }.map { ($0.0, $0.1, $0.1 == 1 ? $0.2 : $0.3) }
    }

    /// What it holds, in words: "2 agents, 1 runner".
    var summary: String { counts.map(\.label).joined(separator: ", ") }

    /// The cards' frames scaled to fit `size`, centered, `inset` from its edges.
    func thumbnail(in size: CGSize, inset: CGFloat = 10) -> [CGRect] {
        guard let first = cards.first?.frame else { return [] }
        let bounds = cards.dropFirst().reduce(first) { $0.union($1.frame) }
        let scale = min((size.width - inset * 2) / max(bounds.width, 1), (size.height - inset * 2) / max(bounds.height, 1))
        let x = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
        let y = (size.height - bounds.height * scale) / 2 - bounds.minY * scale
        return cards.map {
            CGRect(x: $0.frame.minX * scale + x, y: $0.frame.minY * scale + y, width: $0.frame.width * scale, height: $0.frame.height * scale)
        }
    }
}
