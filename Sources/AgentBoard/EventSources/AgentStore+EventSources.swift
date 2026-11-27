import Foundation
import Orchestration

/// Event sources: local webhooks whose channels wake the agents they have lines to. The core
/// keeps them, makes their secrets and takes their events; the board shows them and sends what
/// the user changes.
extension AgentStore {
    func eventSources(in worktree: String) -> [EventSourceRecord] {
        eventSources.filter { $0.worktree == worktree && $0.organizationID == organizationID }
    }

    func eventSource(_ id: UUID) -> EventSourceRecord? {
        eventSources.first { $0.id == id }
    }

    /// The source a channel belongs to, and the channel.
    func eventChannel(_ id: UUID) -> (source: EventSourceRecord, channel: EventChannel)? {
        for source in eventSources { if let channel = source.channel(id) { return (source, channel) } }
        return nil
    }

    /// The core answers with the record, secret and URL included.
    func addEventSource(named name: String, to worktree: String, at origin: CGPoint) -> UUID {
        let record = EventSourceRecord(id: UUID(), worktree: worktree, name: name,
                                       frame: CGRect(origin: origin, size: EventSourceRecord.size), organization: organizationID)
        send(.addEventSource(record))
        return record.id
    }

    func removeEventSource(_ id: UUID) {
        forgetEventSource(id)
        send(.removeEventSource(id))
    }

    func forgetEventSource(_ id: UUID) {
        for channel in eventSource(id)?.channels ?? [] { dropConnections(touching: channel.id) }
        dropConnections(touching: id)
        eventSources.removeAll { $0.id == id }
    }

    func setEventSourceFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = eventSources.firstIndex(where: { $0.id == id }) else { return }
        eventSources[index].frame = frame
        if persist { send(.updateEventSource(eventSources[index])) }
    }

    func raiseEventSource(_ id: UUID) {
        guard let index = eventSources.firstIndex(where: { $0.id == id }), index != eventSources.count - 1 else { return }
        eventSources.append(eventSources.remove(at: index))
    }

    /// The old secret stops working at once; the core sends the new one back.
    func regenerateEventSecret(_ id: UUID) {
        send(.regenerateEventSecret(id))
    }

    func setEventRule(_ rule: EventRule, source: UUID, channel: UUID, agent: UUID) {
        if let index = eventSources.firstIndex(where: { $0.id == source }),
           let row = eventSources[index].channels.firstIndex(where: { $0.id == channel }) {
            eventSources[index].channels[row].rules[agent] = rule
        }
        send(.setEventRule(source: source, channel: channel, agent: agent, rule: rule))
    }
}
