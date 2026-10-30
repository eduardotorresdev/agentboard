import Foundation
import Orchestration

/// Notes blocks: shared pages where connected agents say where they work and on what, and keep
/// notes. The core keeps them and runs the agents' notes tools; the board shows them and sends
/// what the user writes.
extension AgentStore {
    func notes(in worktree: String) -> [NotesRecord] {
        notes.filter { $0.worktree == worktree }
    }

    func notesRecord(_ id: UUID) -> NotesRecord? {
        notes.first { $0.id == id }
    }

    @discardableResult
    func addNotes(to worktree: String, at origin: CGPoint) -> NotesRecord {
        let record = NotesRecord(id: UUID(), worktree: worktree, name: NotesRecord.uniqueName(L("Notes"), among: notes(in: worktree)),
                                 frame: CGRect(origin: origin, size: NotesRecord.size))
        notes.append(record)
        send(.addNotes(record))
        return record
    }

    func removeNotes(_ id: UUID) {
        notes.removeAll { $0.id == id }
        dropConnections(touching: id)
        send(.removeNotes(id))
    }

    func setNotesFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].frame = frame
        if persist { send(.updateNotes(notes[index])) }
    }

    /// Moves the block to the top of the notes stack.
    func raiseNotes(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), index != notes.count - 1 else { return }
        notes.append(notes.remove(at: index))
    }

    /// Adds a note the user wrote, or rewrites one.
    func writeNote(_ entry: NoteEntry, on id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].write(entry)
        send(.writeNote(notes: id, entry: entry))
    }

    func deleteNote(_ entry: UUID, on id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].entries.removeAll { $0.id == entry }
        send(.deleteNote(notes: id, entry: entry))
    }
}
