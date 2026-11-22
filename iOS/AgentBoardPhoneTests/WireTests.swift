import Foundation
import TerminalCore
import XCTest
@testable import AgentBoardPhone
@testable import AgentRuntime

final class WireTests: XCTestCase {
    func testCtrlTurnsLettersIntoControlCodes() {
        XCTAssertEqual(ExtraKey.controlled("c"), [0x03])
        XCTAssertEqual(ExtraKey.controlled("C"), [0x03])
        XCTAssertEqual(ExtraKey.controlled("["), [0x1B])
        XCTAssertEqual(ExtraKey.controlled(" "), [0x00])
    }

    func testKeyRowSendsWhatTheProgramAskedFor() {
        let terminal = Terminal(cols: 10, rows: 2)
        XCTAssertEqual(terminal.encode(ExtraKey.up.key!), Array("\u{1b}[A".utf8))
        terminal.feed("\u{1b}[?1h") // application cursor keys
        XCTAssertEqual(terminal.encode(ExtraKey.up.key!), Array("\u{1b}OA".utf8))
        XCTAssertEqual(terminal.encode(ExtraKey.escape.key!), [0x1B])
    }

    /// The Mac's synthesized Codable: `{"case":{"_0":…}}` for unlabelled values.
    func testDecodesBoardEventsAsTheCoreWritesThem() throws {
        let id = UUID()
        let json = #"{"cardAdded":{"_0":{"id":"\#(id.uuidString)","worktree":"/w/p/main","providerID":"claude","name":"A","frame":[[10,20],[600,400]],"organization":"X"}}}"#
        guard case .cardAdded(let card) = try JSONDecoder().decode(BoardUpdate.self, from: Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(card.id, id)
        XCTAssertEqual(card.frame, CGRect(x: 10, y: 20, width: 600, height: 400))
        let said = #"{"attention":{"_0":[{"id":"\#(id.uuidString)","reason":{"said":{"_0":"hi"}},"since":0}]}}"#
        guard case .attention(let list) = try JSONDecoder().decode(BoardUpdate.self, from: Data(said.utf8)) else { return XCTFail() }
        XCTAssertEqual(list.first?.reason, .said("hi"))
    }

    func testMovingACardKeepsFieldsThePhoneDoesNotKnow() throws {
        let raw: [String: Any] = ["id": "A", "organization": "O", "frame": [[0, 0], [1, 1]]]
        let sent = try JSONSerialization.jsonObject(with: BoardSay.move(raw, to: CGRect(x: 5, y: 6, width: 7, height: 8))) as! [String: Any]
        let card = (sent["updateCard"] as! [String: Any])["_0"] as! [String: Any]
        XCTAssertEqual(card["organization"] as? String, "O")
        XCTAssertEqual(card["frame"] as? [[Double]], [[5, 6], [7, 8]])
    }

    func testDecisionAnswersAsSwiftEncodesThem() throws {
        let ok = try JSONSerialization.jsonObject(with: BoardSay.answerDecision(UUID(), "ok")) as! [String: [String: Any]]
        XCTAssertNotNil((ok["answerDecision"]?["answer"] as? [String: Any])?["ok"])
        let option = try JSONSerialization.jsonObject(with: BoardSay.answerDecision(UUID(), "B")) as! [String: [String: Any]]
        XCTAssertEqual(((option["answerDecision"]?["answer"] as? [String: Any])?["option"] as? [String: String])?["_0"], "B")
    }

    func testParsesHostWorktreesPerProject() {
        let output = "project app\nworktree /h/agentboard/projects/app\nHEAD 1\nbranch refs/heads/main\n\nworktree /h/w/feat\nHEAD 2\ndetached\n\n\nproject api\nworktree /h/agentboard/projects/api\nbranch refs/heads/dev\n\n"
        let list = AccountCatalog.parse(output)
        XCTAssertEqual(list.map(\.path), ["/h/agentboard/projects/app", "/h/w/feat", "/h/agentboard/projects/api"])
        XCTAssertEqual(list.map(\.project), ["app", "app", "api"])
        XCTAssertEqual(list.map(\.branch), ["main", nil, "dev"])
    }

    func testGroupsWorktreesByOrganizationThenProjectAcrossHosts() {
        let work = UUID(), home = UUID()
        let browse = Browse(
            organizations: [Organization(id: work, name: "Work"), Organization(id: home, name: "Home", color: 1)],
            worktrees: [
                Worktree(path: "/a/app", branch: "main", project: "app", organization: work, host: "h1"),
                Worktree(path: "/b/app", branch: "main", project: "app", organization: work, host: "h2"),
                Worktree(path: "/a/api", branch: "dev", project: "api", organization: work, host: "h1"),
                Worktree(path: "/a/blog", project: "blog", organization: home, host: "h1"),
                Worktree(path: "/b/loose", project: "loose", host: "h2"),
                Worktree(path: "/b/stray", organization: UUID(), host: "h2"),
            ])
        let groups = OrganizationGroup.group(browse)
        XCTAssertEqual(groups.map(\.organization.name), ["Work", "Home", "Default"])
        XCTAssertEqual(groups[0].projects.map(\.name), ["api", "app"])
        // The same branch on two hosts stays two worktrees.
        XCTAssertEqual(groups[0].projects[1].worktrees.map(\.host), ["h1", "h2"])
        XCTAssertEqual(Set(groups[0].projects[1].worktrees.map(\.id)).count, 2)
        XCTAssertEqual(groups[1].projects.map(\.name), ["blog"])
        XCTAssertEqual(groups[2].organization, .local)
        XCTAssertEqual(groups[2].projects.map(\.name), ["loose", "Other folders"])
    }

    func testNewCardNamesAreUnique() {
        XCTAssertEqual(HostLink.unique("Post-it", among: ["post-it", "Post-it 2"]), "Post-it 3")
        XCTAssertEqual(HostLink.unique("npm", among: []), "npm")
    }

    func testAddingARunnerWritesAnAgentRecord() throws {
        let data = BoardSay.addCard(UUID(), worktree: "/w", providerID: "runner", name: "npm", frame: .zero, command: "npm run dev", organization: nil)
        let card = (try JSONSerialization.jsonObject(with: data) as! [String: [String: [String: Any]]])["addCard"]!["_0"]!
        XCTAssertEqual((card["runner"] as? [String: String])?["directory"], "/w")
        XCTAssertNil(card["organization"])
    }

    /// `BoardRequest.writePostIt(id:text:)` as Swift's synthesized Codable writes it.
    func testEditingAPostItWritesItsText() throws {
        let id = UUID()
        let sent = try JSONSerialization.jsonObject(with: BoardSay.writePostIt(id, "# Plan\n- ship")) as! [String: [String: String]]
        XCTAssertEqual(sent, ["writePostIt": ["id": id.uuidString, "text": "# Plan\n- ship"]])
    }

    func testFingerprintIsFiveGroupsOfFour() {
        let print = HostChannel.fingerprint(of: Data(repeating: 0, count: 32))
        XCTAssertEqual(print.split(separator: " ").count, 5)
        XCTAssertTrue(print.split(separator: " ").allSatisfy { $0.count == 4 })
    }

    func testRestartAsSwiftEncodesIt() throws {
        let id = UUID()
        let object = try JSONSerialization.jsonObject(with: BoardSay.restart(id)) as? [String: [String: String]]
        XCTAssertEqual(object, ["restart": ["id": id.uuidString]])
    }

    func testRemoveCardAsSwiftEncodesIt() throws {
        let id = UUID()
        let object = try JSONSerialization.jsonObject(with: BoardSay.removeCard(id)) as? [String: [String: String]]
        XCTAssertEqual(object, ["removeCard": ["_0": id.uuidString]])
    }

    /// The core tells every board but the sender about an add, so the phone shows its own at once.
    @MainActor func testAddedCardsShowWithoutTheCoresEcho() throws {
        let link = HostLink(host: Host(id: UUID().uuidString, name: "h", platform: nil, public_key: "", online: true, addresses: nil))
        link.addAgent(try XCTUnwrap(AgentCatalog.all.first), to: "/w")
        link.addRunner("npm run dev", to: "/w")
        link.addPostIt("plan", to: "/w")
        XCTAssertEqual(link.cards(in: "/w").map { $0.runner == nil }, [true, false])
        XCTAssertEqual(link.postIts.map(\.text), ["plan"])
    }

    /// No catalog (or an empty one): every worktree is in the Mac's own Default organization.
    func testWithoutACatalogEverythingIsInTheLocalOrganization() {
        let groups = OrganizationGroup.group(Browse(organizations: [], worktrees: [
            Worktree(path: "/a/app", project: "app", host: "h1"),
            Worktree(path: "/b/api", project: "api", organization: UUID(), host: "h2"),
        ]))
        XCTAssertEqual(groups.map(\.organization), [.local])
        XCTAssertEqual(groups.first?.organization.id, OrganizationHome.defaultID)
        XCTAssertEqual(groups.first?.projects.map(\.name), ["api", "app"])
    }

    /// A banner for each agent that starts waiting, but not for one already waiting, nor for the
    /// one whose terminal is on screen.
    func testTheBannerIsForAgentsThatJustStartedWaitingElsewhere() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(WaitingBanner.arrived(before: [a], now: [a, b], viewing: nil), [b])
        XCTAssertEqual(WaitingBanner.arrived(before: [a], now: [a, b], viewing: b), [])
        XCTAssertEqual(WaitingBanner.arrived(before: [a, b], now: [a], viewing: nil), [])
        XCTAssertEqual(Set(WaitingBanner.arrived(before: [], now: [b, c], viewing: nil)), [b, c])
    }
}
