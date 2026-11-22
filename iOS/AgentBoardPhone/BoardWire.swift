import Connections
import Foundation

// The parts of BoardProtocol (Sources/Orchestration/BoardProtocol.swift) the phone reads, decoded
// from the same JSON. Unknown events and keys are dropped. Cards keep their raw JSON too, so a
// change the phone sends back (a card moved) carries every field the phone doesn't know.
// shortcut: mirrors instead of the real types until Orchestration builds for iOS.

struct Card: Decodable, Identifiable, Equatable {
    struct Runner: Decodable, Equatable { let command: String }
    let id: UUID
    let worktree: String
    let providerID: String
    var name: String
    var frame: CGRect
    let runner: Runner?
}

struct Line: Decodable, Identifiable, Equatable {
    let id: UUID
    let a: UUID
    let b: UUID
    /// The card sides the line was drawn between, when it was drawn by hand.
    var aSide: Side?
    var bSide: Side?
}

struct PostIt: Decodable, Identifiable, Equatable {
    let id: UUID
    let worktree: String
    var name: String
    var frame: CGRect
    var text: String
}

/// A picture or a video; its file lives in the host's data folder, under `images/`.
struct Media: Decodable, Identifiable, Equatable {
    let id: UUID
    let worktree: String
    var name: String
    var frame: CGRect
    var file: String
    var isVideo: Bool { ["mp4", "mov", "m4v"].contains((file as NSString).pathExtension.lowercased()) }
}

struct Attention: Decodable, Identifiable, Equatable {
    enum Reason: Decodable, Equatable { case turnEnded, waiting, said(String) }
    let id: UUID
    let reason: Reason
    let context: String?
}

struct Decision: Decodable, Identifiable, Equatable {
    struct Variant: Decodable, Equatable { let letter: String; let name: String }
    enum Ask: Decodable, Equatable {
        case validation(question: String)
        case choice(question: String, variants: [Variant])
        var question: String { switch self { case .validation(let q), .choice(let q, _): q } }
        var variants: [Variant] { if case .choice(_, let v) = self { v } else { [] } }
    }
    enum State: String, Decodable { case open, awaitingEcho, closed }
    let id: UUID
    let agent: UUID
    let framing: String
    let ask: Ask
    let state: State
}

struct BoardSnapshot: Decodable {
    let cards: [Card]
    let connections: [Line]
    let postIts: [PostIt]?
    let images: [Media]?
    let attention: [Attention]?
    let decisions: [Decision]?
}

enum BoardUpdate: Decodable {
    case cardAdded(Card)
    case cardUpdated(Card)
    case cardRemoved(UUID)
    case connections([Line])
    case attention([Attention])
    case decisions([Decision])
    case postItAdded(PostIt)
    case postItUpdated(PostIt)
    case postItRemoved(UUID)
    case imageAdded(Media)
    case imageUpdated(Media)
    case imageRemoved(UUID)
}

/// Board → core requests, written as Swift's synthesized Codable writes `BoardRequest`.
enum BoardSay {
    static func open(_ id: UUID, cols: Int, rows: Int, start: Bool = false) -> Data {
        json(["open": ["id": id.uuidString, "cols": cols, "rows": rows, "start": start]])
    }

    /// An agent card (`command` nil) or a runner card, as `AgentRecord` encodes.
    static func addCard(_ id: UUID, worktree: String, providerID: String, name: String, frame: CGRect,
                        command: String? = nil, organization: String?) -> Data {
        var card: [String: Any] = ["id": id.uuidString, "worktree": worktree, "providerID": providerID, "name": name,
                                   "frame": rect(frame)]
        if let command { card["runner"] = ["command": command, "directory": worktree] }
        if let organization { card["organization"] = organization }
        return json(["addCard": ["_0": card]])
    }

    static func addPostIt(_ id: UUID, worktree: String, name: String, frame: CGRect, text: String, organization: String?) -> Data {
        var record: [String: Any] = ["id": id.uuidString, "worktree": worktree, "name": name, "frame": rect(frame),
                                     "text": text, "editorName": ""]
        if let organization { record["organization"] = organization }
        return json(["addPostIt": ["_0": record]])
    }

    /// The user rewrote the post-it's text (`BoardRequest.writePostIt`).
    static func writePostIt(_ id: UUID, _ text: String) -> Data { json(["writePostIt": ["id": id.uuidString, "text": text]]) }

    static func prompt(_ id: UUID, _ text: String) -> Data { json(["prompt": ["id": id.uuidString, "text": text]]) }

    static func dismissAttention(_ id: UUID) -> Data { json(["dismissAttention": ["_0": id.uuidString]]) }

    /// `answer`: "ok", "useRecommended", or a variant's letter.
    /// Starts a stopped agent again, or restarts a runner, as the Mac's restart does.
    static func restart(_ id: UUID) -> Data {
        json(["restart": ["id": id.uuidString]])
    }

    static func answerDecision(_ id: UUID, _ answer: String) -> Data {
        let value: Any = ["ok", "useRecommended"].contains(answer) ? [answer: [String: Any]()] : ["option": ["_0": answer]]
        return json(["answerDecision": ["id": id.uuidString, "answer": value]])
    }

    /// The card as the core sent it, with `frame` replaced: nothing the phone doesn't know is lost.
    static func move(_ raw: [String: Any], to frame: CGRect) -> Data {
        var card = raw
        card["frame"] = rect(frame)
        return json(["updateCard": ["_0": card]])
    }

    static func rect(_ r: CGRect) -> [[Double]] { [[r.origin.x, r.origin.y], [r.width, r.height]] }

    static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
}
