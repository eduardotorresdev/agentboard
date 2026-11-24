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
        // Titled as the Mac's sidebar: never the branch.
        XCTAssertEqual(list.map(\.title), ["Main", "Feat", "Main"])
        var named = list[1]
        named.name = "Login fix"
        XCTAssertEqual(named.title, "Login fix")
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

    /// Projects and worktrees in the order the Mac's sidebar has them; what it never placed after, by name.
    func testProjectsAndWorktreesFollowTheMacsOrder() {
        let groups = OrganizationGroup.group(Browse(organizations: [], worktrees: [
            Worktree(path: "/a/app", project: "app", host: "h1", position: 1, projectPosition: 1),
            Worktree(path: "/a/app-zed", project: "app", host: "h1", position: 0, projectPosition: 1),
            Worktree(path: "/a/app-new", project: "app", host: "h1", projectPosition: 1),
            Worktree(path: "/b/web", project: "web", host: "h1", position: 0, projectPosition: 0),
            Worktree(path: "/c/api", project: "api", host: "h2"),
        ]))
        XCTAssertEqual(groups.first?.projects.map(\.name), ["web", "app", "api"])
        XCTAssertEqual(groups.first?.projects[1].worktrees.map(\.path), ["/a/app-zed", "/a/app", "/a/app-new"])
    }

    /// A banner for each agent that starts waiting, but not for one already waiting, nor for one
    /// the user sees (its terminal or its board on screen).
    func testTheBannerIsForAgentsThatJustStartedWaitingElsewhere() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(WaitingBanner.arrived(before: [a], now: [a, b], shown: []), [b])
        XCTAssertEqual(WaitingBanner.arrived(before: [a], now: [a, b], shown: [b]), [])
        XCTAssertEqual(WaitingBanner.arrived(before: [a, b], now: [a], shown: []), [])
        XCTAssertEqual(Set(WaitingBanner.arrived(before: [], now: [b, c], shown: [c])), [b])
    }

    /// An agent's questions come with its attention, and are answered as the Mac answers them.
    func testAgentQuestionsDecodeAndAnswerAsTheMacDoes() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../core/fixtures/orchestration/event_attention.json"))
        guard case .attention(let list) = try JSONDecoder().decode(BoardUpdate.self, from: data) else { return XCTFail("not attention") }
        let questions = try XCTUnwrap(list.first { $0.questions != nil }?.questions)
        XCTAssertEqual(questions.map(\.question), ["Which layout?", "Ship it?"])
        XCTAssertEqual(questions[0].header, "Layout")
        XCTAssertTrue(questions[0].multiSelect)
        XCTAssertEqual(questions[0].options.map(\.label), ["Grid", "List"])
        // Checked options in the order shown, then what was written; single: what was written wins.
        XCTAssertEqual(questions[0].answer(picked: ["List", "Grid"], written: " Cards "), "Grid, List, Cards")
        XCTAssertEqual(questions[1].answer(picked: [], written: "  "), nil)
        let single = AgentQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")])
        XCTAssertEqual(single.answer(picked: ["B"], written: ""), "B")
        XCTAssertEqual(single.answer(picked: ["B"], written: "Neither"), "Neither")
    }

    /// Answering sends the Mac's request: the answers by question, or none for the terminal.
    func testAnsweringQuestionsSendsTheMacsRequest() throws {
        let id = UUID(uuidString: "00000001-ABCD-4EF0-8A1B-000000000001")!
        for (name, answers) in [("request_answerQuestions", ["Which layout?": "Grid"]), ("request_answerQuestions_in_the_terminal", nil)] as [(String, [String: String]?)] {
            let fixture = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../core/fixtures/orchestration/\(name).json"))
            let sent = try JSONSerialization.jsonObject(with: BoardSay.answerQuestions(id, answers)) as? NSDictionary
            XCTAssertEqual(sent, try JSONSerialization.jsonObject(with: fixture) as? NSDictionary, name)
        }
    }

    /// The canvas card and the full-screen page show one session: each gets its changes whichever
    /// was configured last, and one going away leaves the other live (the page opened straight
    /// from a launch drew nothing, its redraws taken by the card behind it).
    @MainActor func testEveryTerminalShowingASessionRedrawsOnItsChanges() {
        let session = AgentSession(cols: 80, rows: 24)
        let page = MetalTerminalView(), card = MetalTerminalView()
        page.configure(session: session, live: true, zoom: 1, showsCursor: true)
        card.configure(session: session, live: true, zoom: 1, showsCursor: false)
        session.onChange?()
        XCTAssertEqual([page.changes, card.changes], [1, 1])
        card.configure(session: nil, live: false, zoom: 1, showsCursor: false)
        session.onChange?()
        XCTAssertEqual([page.changes, card.changes], [2, 1])
        XCTAssertTrue(session.isObserved)
        page.configure(session: nil, live: false, zoom: 1, showsCursor: false)
        XCTAssertNil(session.onChange)
        XCTAssertFalse(session.isObserved)
    }

    /// Making projects and worktrees: the requests as the Mac's core reads them, and its answer.
    func testCreatingSpeaksTheCoresFixtures() throws {
        func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../core/fixtures/orchestration/\(name).json"))
        }
        let project = UUID(uuidString: "00000008-ABCD-4EF0-8A1B-000000000008")!
        let worktree = UUID(uuidString: "00000009-ABCD-4EF0-8A1B-000000000009")!
        for (name, sent) in [("request_createProject", BoardSay.createProject(project, name: "shop", clone: nil)),
                             ("request_createProject_clone", BoardSay.createProject(project, name: nil, clone: "git@github.com:owner/shop.git")),
                             ("request_createWorktree", BoardSay.createWorktree(worktree, project: "/Users/me/agentboard/projects/shop", branch: "fix/login"))] {
            XCTAssertEqual(try JSONSerialization.jsonObject(with: sent) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: fixture(name)) as? NSDictionary, name)
        }
        guard case .created(project, "/Users/me/agentboard/projects/shop", nil) = try JSONDecoder().decode(BoardUpdate.self, from: fixture("event_created")) else { return XCTFail("created") }
        guard case .created(worktree, nil, let error?) = try JSONDecoder().decode(BoardUpdate.self, from: fixture("event_created_refused")) else { return XCTFail("refused") }
        XCTAssertTrue(error.contains("a..b"))
    }

    /// A decision's cards come with it: a diagram's SVG, an image's ids, a reference; the
    /// diagram draws on the phone with the shared renderer, arrowhead included.
    func testDecisionCardsDecodeAndTheirDiagramDraws() throws {
        let svg = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../core/fixtures/diagrams/guide.svg"), encoding: .utf8)
        let id = UUID(), after = UUID()
        let json: [String: Any] = ["decisions": ["_0": [[
            "id": id.uuidString, "agent": id.uuidString, "framing": "Validate", "state": "open",
            "ask": ["validation": ["question": "Ship?"]],
            "cards": [["claim": "Flow", "evidence": ["diagram": ["svg": svg, "before": svg]], "reference": "Why", "pins": []],
                      ["claim": "Screen", "evidence": ["image": ["after": after.uuidString]], "pins": []],
                      ["claim": "Page", "evidence": ["browser": ["id": after.uuidString]], "pins": []]],
        ]]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        guard case .decisions(let list) = try JSONDecoder().decode(BoardUpdate.self, from: data) else { return XCTFail("not decisions") }
        let cards = try XCTUnwrap(list.first?.cards)
        XCTAssertEqual(cards.map(\.claim), ["Flow", "Screen", "Page"])
        XCTAssertEqual(cards[0].evidence.diagram?.svg, svg)
        XCTAssertEqual(cards[0].evidence.diagram?.before, svg)
        XCTAssertEqual(cards[0].reference, "Why")
        XCTAssertEqual(cards[1].evidence.image?.after, after)
        XCTAssertNil(cards[2].evidence.image ?? nil)
        XCTAssertNil(cards[2].evidence.diagram)

        // Drawn at 3x on iOS: the arrowhead's dark pixels sit just before the right box.
        let image = try XCTUnwrap(try SVGDiagram(svg).image(size: CGSize(width: 320, height: 120), scale: 3))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let row = Int(57.5 * 3), column = 200 * 3, offset = row * image.bytesPerRow + column * 4
        XCTAssertLessThan(Int(pixels[offset]), 80)
        XCTAssertGreaterThan(Int(pixels[offset + 3]), 200)
    }

    /// An agent is on the open board when its folder and host are the board's; any other board, or none, isn't.
    func testAnAgentIsOnTheOpenBoardOnlyWhenFolderAndHostMatch() {
        let board = Worktree(path: "/w/phone-test-a", host: "abc")
        XCTAssertTrue(WaitingBanner.onBoard(card: "/w/phone-test-a", host: "ABC", board))
        XCTAssertFalse(WaitingBanner.onBoard(card: "/w/phone-test-b", host: "abc", board))
        XCTAssertFalse(WaitingBanner.onBoard(card: "/w/phone-test-a", host: "other", board))
        XCTAssertFalse(WaitingBanner.onBoard(card: "/w/phone-test-a", host: "abc", nil))
    }

    /// Every answer a decision offers, as full-size buttons: OK for a validation, each variant
    /// and Use Recommended for a choice.
    func testADecisionOffersItsAnswers() {
        let id = UUID()
        let validation = Decision(id: id, agent: id, framing: "f", ask: .validation(question: "Ship?"), state: .open)
        XCTAssertEqual(validation.answers.map(\.value), ["ok"])
        let choice = Decision(id: id, agent: id, framing: "f", ask: .choice(question: "Which?", variants: [.init(letter: "A", name: "List"), .init(letter: "B", name: "Grid")]), state: .open)
        XCTAssertEqual(choice.answers.map(\.value), ["A", "B", "useRecommended"])
        XCTAssertEqual(choice.answers.map(\.title), ["A. List", "B. Grid", "Use Recommended"])
    }
}
