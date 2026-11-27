import AgentRuntime
import Connections
import Foundation

/// What the core keeps in memory about event sources' traffic.
struct EventTraffic {
    /// Webhook ids already taken, `<source> <webhook-id>`, while their timestamp is still accepted.
    var seen: [String: Date] = [:]
    /// Each source's requests in the last minute, for its rate limit.
    var requests: [UUID: [Date]] = [:]
    /// When each line (`<channel> <agent>`) woke its agent in the last hour.
    var triggers: [String: [Date]] = [:]
    /// Events waiting on a line: its window is closed, its hourly limit reached, or its agent isn't running.
    var held: [String: [EventPayload]] = [:]
    /// The events in the prompt still queued for a line's agent, which later ones join.
    var pending: [String: [EventPayload]] = [:]
    var timer: Timer?
}

extension Orchestrator {
    /// Requests one source takes a minute; past it, 429.
    static let hookRequestsPerMinute = 60
    /// Events one line holds at most; the oldest go first.
    static let heldEventLimit = 200

    var visibleEventSources: [EventSourceRecord] { eventSources.filter { $0.deleted != true }.map(withURL) }

    func eventSource(_ id: UUID) -> EventSourceRecord? { eventSources.first { $0.id == id && $0.deleted != true } }

    /// The source and channel a channel element is.
    func eventChannel(_ id: UUID) -> (source: EventSourceRecord, channel: EventChannel)? {
        for source in eventSources where source.deleted != true {
            if let channel = source.channel(id) { return (source, channel) }
        }
        return nil
    }

    func withURL(_ source: EventSourceRecord) -> EventSourceRecord {
        var source = source
        source.url = toolsURL?.port.map { "http://127.0.0.1:\($0)\(ToolServer.hooksPrefix)\(source.id.uuidString.lowercased())" }
        return source
    }

    func startEventSources() {
        for source in eventSources where source.deleted != true {
            bus.register(EventChannelElement(id: source.id, store: self))
            for channel in source.channels { bus.register(EventChannelElement(id: channel.id, store: self)) }
        }
        toolServer.onHook = { [weak self] source, headers, body in
            await self?.hook(source, headers: headers, body: body) ?? (404, [:])
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.flushHeldEvents() } }
        RunLoop.main.add(timer, forMode: .common)
        eventTraffic.timer = timer
    }

    // MARK: Board requests

    func addEventSource(_ record: EventSourceRecord) {
        guard !eventSources.contains(where: { $0.id == record.id }) else { return }
        var source = EventSourceRecord(id: record.id, worktree: record.worktree, name: record.name, frame: record.frame,
                                       organization: record.organization, secret: StandardWebhook.newSecret())
        source.countDay = EventSourceRecord.day(Date())
        eventSources.append(source)
        saveEventSource(source)
        bus.register(EventChannelElement(id: source.id, store: self))
        // The board that added it learns its secret here too.
        broadcast(.eventSourceAdded(withURL(source)))
    }

    func changeEventSource(_ id: UUID, from sender: CoreBoard? = nil, _ change: (inout EventSourceRecord) -> Void) {
        guard let index = eventSources.firstIndex(where: { $0.id == id && $0.deleted != true }) else { return }
        change(&eventSources[index])
        saveEventSource(eventSources[index])
        broadcast(.eventSourceUpdated(withURL(eventSources[index])), except: sender)
    }

    /// Keeps a tombstone, so its URL answers 410 instead of 404.
    func removeEventSource(_ id: UUID, from sender: CoreBoard? = nil) {
        guard let index = eventSources.firstIndex(where: { $0.id == id && $0.deleted != true }) else { return }
        bus.remove(element: id)
        for channel in eventSources[index].channels {
            bus.remove(element: channel.id)
            for key in eventTraffic.held.keys where key.hasPrefix(channel.id.uuidString) { eventTraffic.held[key] = nil }
        }
        let gone = EventSourceRecord(id: id, worktree: eventSources[index].worktree, name: eventSources[index].name, frame: .zero)
        eventSources[index] = gone
        eventSources[index].deleted = true
        saveEventSource(eventSources[index])
        broadcast(.eventSourceRemoved(id), except: sender)
    }

    func setEventRule(source: UUID, channel: UUID, agent: UUID, rule: EventRule, from sender: CoreBoard?) {
        var rule = rule
        rule.perHour = min(max(rule.perHour, 1), 600)
        if let start = rule.windowStart, let end = rule.windowEnd, (0..<1440).contains(start), (0..<1440).contains(end) {} else {
            rule.windowStart = nil
            rule.windowEnd = nil
        }
        changeEventSource(source, from: sender) { record in
            // `channel` is the source itself for a line from the source.
            if channel == source { return record.rules = (record.rules ?? [:]).merging([agent: rule]) { $1 } }
            guard let index = record.channels.firstIndex(where: { $0.id == channel }) else { return }
            record.channels[index].rules[agent] = rule
        }
        // A window that opened, or a higher limit, lets what waits go in.
        flushHeldEvents()
    }

    private func saveEventSource(_ source: EventSourceRecord) {
        do { try database?.saveEventSource(source) } catch { server.onLog?("couldn't save event source \(source.id): \(error)") }
    }

    // MARK: Webhooks

    /// Answers a webhook posted for `sourceID` (see docs/event-sources.md).
    func hook(_ sourceID: String, headers: [String: String], body: Data, now: Date = Date()) -> (status: Int, headers: [String: String]) {
        guard let id = UUID(uuidString: sourceID), let index = eventSources.firstIndex(where: { $0.id == id }) else { return (404, [:]) }
        guard eventSources[index].deleted != true else { return (410, [:]) }
        let recent = (eventTraffic.requests[id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        if recent.count >= Self.hookRequestsPerMinute, let oldest = recent.first {
            eventTraffic.requests[id] = recent
            return (429, ["Retry-After": String(max(1, Int((60 - now.timeIntervalSince(oldest)).rounded(.up))))])
        }
        eventTraffic.requests[id] = recent + [now]
        if let refusal = StandardWebhook.refusal(secret: eventSources[index].secret, id: headers["webhook-id"], timestamp: headers["webhook-timestamp"],
                                                 signature: headers["webhook-signature"], body: body, now: now) {
            noteEventError(id, refusal)
            return (401, [:])
        }
        let seenKey = "\(id) \(headers["webhook-id"] ?? "")"
        eventTraffic.seen = eventTraffic.seen.filter { now.timeIntervalSince($0.value) <= 2 * StandardWebhook.tolerance }
        // A retry of one already taken: fine, and not again.
        if eventTraffic.seen[seenKey] != nil { return (200, [:]) }
        let payload: EventPayload
        switch EventPayload.parse(body) {
        case .success(let parsed): payload = parsed
        case .failure(let invalid):
            noteEventError(id, invalid.reason)
            return (400, [:])
        }
        eventTraffic.seen[seenKey] = now
        receive(payload, for: id, now: now)
        return (202, [:])
    }

    private func noteEventError(_ id: UUID, _ error: String) {
        guard eventSource(id)?.lastError != error else { return }
        changeEventSource(id) { $0.lastError = error }
    }

    /// Records the event on its channel (made on its first one) and wakes the agents its lines reach.
    private func receive(_ payload: EventPayload, for id: UUID, now: Date) {
        guard var source = eventSource(id) else { return }
        let title = BoardName.clean(payload.title ?? "") ?? BoardName.named(payload.key, else: "Channel")
        let channelIndex: Int
        if let index = source.channels.firstIndex(where: { $0.key == payload.key }) {
            channelIndex = index
            if payload.title != nil { source.channels[index].title = title }
        } else {
            source.channels.append(EventChannel(key: payload.key, title: title))
            channelIndex = source.channels.count - 1
        }
        let channel = source.channels[channelIndex]
        let today = EventSourceRecord.day(now)
        source.todayCount = source.countDay == today ? source.todayCount + 1 : 1
        source.countDay = today
        source.lastEvent = now
        source.lastError = nil
        var names: [String] = []
        var errors: [String] = []
        for (agent, rule, line) in recipients(of: channel, in: source) {
            switch deliver([payload], source: source, channel: channel, to: agent, rule: rule, line: line, now: now) {
            case .delivered: names.append(agent.name)
            case .held: names.append("\(agent.name) (waiting)")
            case .notRunning:
                names.append("\(agent.name) (waiting)")
                errors.append("\(agent.name) isn't running; it gets the event once it is.")
            }
        }
        source.history.insert(EventLogEntry(date: now, channel: channel.title, summary: payload.headline, deliveredTo: names,
                                            error: errors.isEmpty ? nil : errors.joined(separator: " ")), at: 0)
        source.history = Array(source.history.prefix(EventSourceRecord.historyLimit))
        if !errors.isEmpty { source.lastError = errors.joined(separator: " ") }
        let isNew = bus.element(channel.id) == nil
        changeEventSource(id) { $0 = source }
        if isNew { bus.register(EventChannelElement(id: channel.id, store: self)) }
    }

    private func agents(on element: UUID) -> [AgentEndpoint] {
        bus.peers(of: element).compactMap { $0 as? AgentEndpoint }
    }

    /// The agents `channel`'s events reach, each with its line's rule and that line's end (the
    /// channel or the source): a channel's own line to an agent wins over the source's.
    func recipients(of channel: EventChannel, in source: EventSourceRecord) -> [(agent: AgentEndpoint, rule: EventRule, line: UUID)] {
        var seen = Set<UUID>()
        let own = agents(on: channel.id).filter { seen.insert($0.id).inserted }.map { ($0, channel.rule(for: $0.id), channel.id) }
        let all = agents(on: source.id).filter { seen.insert($0.id).inserted }.map { ($0, source.rules?[$0.id] ?? EventRule(), source.id) }
        return own + all
    }

    enum EventDelivery { case delivered, held, notRunning }

    /// Hands `events` (with any held for the channel) to the agent, joining the prompt still
    /// queued for it, or holds them while the rule's window is closed or its line's hourly limit
    /// is reached. `line` is the end of the line they come by: the channel or the whole source.
    @discardableResult
    func deliver(_ events: [EventPayload], source: EventSourceRecord, channel: EventChannel, to agent: AgentEndpoint, rule: EventRule,
                 line: UUID, now: Date) -> EventDelivery {
        let key = "\(channel.id) \(agent.id)"
        // The limit counts the line's wakes, all of its channels together.
        let lineKey = "\(line) \(agent.id)"
        let triggers = (eventTraffic.triggers[lineKey] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        eventTraffic.triggers[lineKey] = triggers
        let queued = agent.hasQueuedEvent(key)
        func hold() {
            eventTraffic.held[key] = Array(((eventTraffic.held[key] ?? []) + events).suffix(Self.heldEventLimit))
        }
        guard queued || (rule.isOpen(at: now) && triggers.count < rule.perHour) else {
            hold()
            return .held
        }
        let batch = (queued ? eventTraffic.pending[key] ?? [] : []) + (eventTraffic.held[key] ?? []) + events
        guard !batch.isEmpty else { return .delivered }
        let text = EventPayload.prompt(source: source.name, channel: channel.title, rule: rule, events: batch)
        guard agent.event(text, key: key) else {
            hold()
            return .notRunning
        }
        eventTraffic.held[key] = nil
        eventTraffic.pending[key] = batch
        if !queued { eventTraffic.triggers[lineKey] = triggers + [now] }
        broadcast(.message(Message(from: channel.id, to: agent.id, text: text, date: now)))
        return .delivered
    }

    /// Delivers what waits on lines whose window opened, whose hour freed up or whose agent runs again.
    func flushHeldEvents(now: Date = Date()) {
        for key in Array(eventTraffic.held.keys) {
            let parts = key.split(separator: " ")
            guard parts.count == 2, let channelID = UUID(uuidString: String(parts[0])), let agentID = UUID(uuidString: String(parts[1])),
                  let (source, channel) = eventChannel(channelID),
                  let recipient = recipients(of: channel, in: source).first(where: { $0.agent.id == agentID }) else {
                // The line or its ends are gone.
                eventTraffic.held[key] = nil
                continue
            }
            deliver([], source: source, channel: channel, to: recipient.agent, rule: recipient.rule, line: recipient.line, now: now)
        }
    }
}

/// A source, or one of its channels, as the bus sees it: lines start from it toward the agents it wakes.
@MainActor
final class EventChannelElement: BoardElement {
    let id: UUID
    private weak var store: Orchestrator?

    init(id: UUID, store: Orchestrator) {
        self.id = id
        self.store = store
    }

    var name: String {
        if let source = store?.eventSource(id) { return source.name }
        return store?.eventChannel(id).map { "\($0.source.name) · \($0.channel.title)" } ?? ""
    }
    var kind: ElementKind { .eventChannel }
    var detail: String? { store?.eventSource(id) != nil ? "event source" : "event channel" }
    var board: String? {
        guard let source = store?.eventSource(id) ?? store?.eventChannel(id)?.source else { return nil }
        return boardKey(source.worktree, source.organizationID)
    }
}
