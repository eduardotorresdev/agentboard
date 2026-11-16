import AgentRuntime
import Connections
import Foundation
import Testing
@testable import Orchestration

/// A browser or file tree the board reports with its organization reaches only that
/// organization's agents in `list_peers`; one reported without (an older board) reaches all.
@MainActor
struct ElementOrganizationTests {
    @Test func elementsReachTheirOrganizationsAgents() async throws {
        let core = try Core()
        defer { core.stop() }
        let mine = UUID(), theirs = UUID()
        var a = agent("Ada", in: core.folder)
        a.organization = mine
        let link = try await board(core)
        link.send(.addCard(a))
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        link.send(.elements([
            ElementInfo(id: UUID(), name: "Ours", kind: "browser", detail: nil, worktree: a.worktree, frame: frame, organization: mine),
            ElementInfo(id: UUID(), name: "Theirs", kind: "browser", detail: nil, worktree: a.worktree, frame: frame, organization: theirs),
            ElementInfo(id: UUID(), name: "Legacy", kind: "filetree", detail: nil, worktree: a.worktree, frame: frame),
        ]))
        try await waitUntil { core.orchestrator.bus.elements(onBoardOf: a.id).count == 3 }
        let peers = try await call("list_peers", as: a.id, on: core)
        #expect(peers.text.contains("“Ours”") && peers.text.contains("“Legacy”"), "\(peers.text)")
        #expect(!peers.text.contains("“Theirs”"), "\(peers.text)")
    }
}
