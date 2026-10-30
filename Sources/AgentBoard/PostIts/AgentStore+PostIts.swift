import Foundation
import Orchestration

/// Post-its: markdown notes that the user and the connected agents read and rewrite. The core
/// keeps them and runs the agents' post-it tools; the board shows them and sends what the user
/// writes.
extension AgentStore {
    func postIts(in worktree: String) -> [PostItRecord] {
        postIts.filter { $0.worktree == worktree }
    }

    func postIt(_ id: UUID) -> PostItRecord? {
        postIts.first { $0.id == id }
    }

    @discardableResult
    func addPostIt(to worktree: String, at origin: CGPoint) -> PostItRecord {
        let record = PostItRecord(id: UUID(), worktree: worktree, name: PostItRecord.uniqueName(L("Post-it"), among: postIts(in: worktree)),
                                  frame: CGRect(origin: origin, size: PostItRecord.size))
        postIts.append(record)
        send(.addPostIt(record))
        return record
    }

    func removePostIt(_ id: UUID) {
        postIts.removeAll { $0.id == id }
        dropConnections(touching: id)
        send(.removePostIt(id))
    }

    func setPostItFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = postIts.firstIndex(where: { $0.id == id }) else { return }
        postIts[index].frame = frame
        if persist { send(.updatePostIt(postIts[index])) }
    }

    /// Moves the post-it to the top of the post-it stack.
    func raisePostIt(_ id: UUID) {
        guard let index = postIts.firstIndex(where: { $0.id == id }), index != postIts.count - 1 else { return }
        postIts.append(postIts.remove(at: index))
    }

    /// The user rewrote the text.
    func writePostIt(_ text: String, on id: UUID) {
        guard let index = postIts.firstIndex(where: { $0.id == id }), postIts[index].text != text else { return }
        postIts[index].write(text, by: nil)
        send(.writePostIt(id: id, text: text))
    }
}
