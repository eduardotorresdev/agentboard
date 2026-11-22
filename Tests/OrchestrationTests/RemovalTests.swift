import AgentRuntime
import Connections
import Foundation
import Testing
@testable import Orchestration

/// A board that answers every removal question with `answer`, and counts them.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var _questions: [[String: Any]] = []
    var questions: [[String: Any]] { lock.withLock { _questions } }

    func attach(to client: CoreClient, answer: String) {
        client.send(.elements([]))  // a board that runs board tools says which elements it has
        client.onService { [self] data in
            guard case .toolCall(let call, "board_confirm_removal", let arguments, _)? = BoardEvent(data) else { return }
            lock.withLock { _questions.append((try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]) }
            client.send(.toolResult(call: call, result: WireToolResult(.text(answer))))
        }
    }
}

@Suite(.serialized)
struct RemovalTests {
    @Test func oneOwnElementGoesAtOnceTheRestAsks() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), theirs = agent("Grace", in: folder)
        let client = try await board(core)
        let asked = Asked()
        asked.attach(to: client, answer: "refused")
        client.send(.addCard(a))
        client.send(.addCard(theirs))
        try await waitUntil { core.orchestrator.record(theirs.id) != nil }

        // A session that starts is told once to title its worktree.
        #expect(try await context("SessionStart", as: a.id, on: core)?.contains("worktree_set_title") == true)
        #expect(try await context("UserPromptSubmit", as: a.id, on: core)?.contains("worktree_set_title") != true)

        // A name already on the board is made unique, and the helper is listed as the caller's.
        let started = try await call("agent_start", ["agent": a.providerID, "name": "Grace"], as: a.id, on: core)
        #expect(started.text.hasPrefix("Started agent “Grace 2”"), "\(started.text)")
        for name in ["One", "Two"] { _ = try await call("postit_create", ["name": name], as: a.id, on: core) }
        let listed = try await call("list_peers", as: a.id, on: core)
        #expect(listed.text.contains("“Grace 2” (agent") && listed.text.contains("made by: you") && listed.text.contains("made by: the user"), "\(listed.text)")

        // Its own card: never.
        let own = try await call("element_remove", ["elements": ["Ada", "One"]], as: a.id, on: core)
        #expect(own.isError && own.text.contains("your own card"), "\(own.text)")
        // Not its own, not even connected: the user is asked, and refuses.
        let notMine = try await call("element_remove", ["elements": ["Grace"]], as: a.id, on: core)
        #expect(notMine.isError && notMine.text.contains("refused"), "\(notMine.text)")
        #expect(asked.questions.count == 1 && asked.questions[0]["asker"] as? String == "Ada")
        #expect((asked.questions[0]["items"] as? [[String: String]]) == [["kind": "agent", "name": "Grace"]])
        // Two of its own in one call: asked too.
        let batch = try await call("element_remove", ["elements": ["One", "Two"]], as: a.id, on: core)
        #expect(batch.isError && asked.questions.count == 2, "\(batch.text)")
        // A helper can't close what its starter made without asking either (the older tools follow the rule).
        let helper = try #require(await core.card(named: "Grace 2"))
        #expect(try await call("agent_close", as: helper.id, on: core).isError)
        #expect(asked.questions.count == 3)
        #expect(await core.orchestrator.postIts.count == 2)
        #expect(await core.orchestrator.cards.count == 3)

        // One of its own: at once, no question.
        let single = try await call("element_remove", ["elements": ["One"]], as: a.id, on: core)
        #expect(single.text == "Removed “One” (postit).")
        #expect(asked.questions.count == 3)

        // Allowed: everything named goes.
        asked.attach(to: client, answer: "allowed")
        let allowed = try await call("element_remove", ["elements": ["Two", theirs.id.uuidString, "Grace 2"]], as: a.id, on: core)
        #expect(!allowed.isError, "\(allowed.text)")
        #expect(await core.orchestrator.postIts.isEmpty)
        #expect(await core.orchestrator.cards.map(\.id) == [a.id])

        // No board open: nothing goes.
        _ = try await call("postit_create", ["name": "Three"], as: a.id, on: core)
        _ = try await call("postit_create", ["name": "Four"], as: a.id, on: core)
        client.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        let closed = try await call("element_remove", ["elements": ["Three", "Four"]], as: a.id, on: core)
        #expect(closed.isError && closed.text.hasPrefix("Nothing was removed."), "\(closed.text)")
        #expect(await core.orchestrator.postIts.count == 2)
    }

    @Test func linesAreDrawnFreelyAndRemovedOnlyWhenAllowed() async throws {
        let core = try await MainActor.run { try Core() }
        defer { Task { @MainActor in core.stop() } }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Grace", in: folder)
        let client = try await board(core)
        let asked = Asked()
        asked.attach(to: client, answer: "refused")
        client.send(.addCard(a))
        client.send(.addCard(b))
        try await waitUntil { core.orchestrator.record(b.id) != nil }
        _ = try await call("postit_create", ["name": "Plan"], as: a.id, on: core)

        // Neither end is the caller.
        let drawn = try await call("element_connect", ["a": "Grace", "b": "Plan"], as: a.id, on: core)
        #expect(drawn.text == "Connected “Grace” and “Plan”.")
        #expect(try await call("element_connect", ["a": "Plan", "b": "Grace"], as: a.id, on: core).text.contains("already connected"))
        #expect(try await call("element_connect", ["a": "Plan", "b": "Plan"], as: a.id, on: core).isError)
        #expect(asked.questions.isEmpty)

        // Even a line it drew itself: asked, and refused changes nothing.
        let pair = ["connections": [["a": "Grace", "b": "Plan"]]]
        let refused = try await call("element_disconnect", pair, as: a.id, on: core)
        #expect(refused.isError && asked.questions.count == 1, "\(refused.text)")
        #expect((asked.questions[0]["items"] as? [[String: String]]) == [["kind": "connection", "name": "Grace - Plan"]])
        #expect(await core.orchestrator.bus.graph.connections.count == 2)

        asked.attach(to: client, answer: "allowed")
        #expect(try await call("element_disconnect", pair, as: a.id, on: core).text == "Removed the line: Grace - Plan.")
        #expect(await core.orchestrator.bus.graph.connections.count == 1)
        #expect(try await call("element_disconnect", pair, as: a.id, on: core).text.contains("aren't connected"))
        client.disconnect()
    }
}
