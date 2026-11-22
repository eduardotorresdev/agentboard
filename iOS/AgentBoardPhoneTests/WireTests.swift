import Foundation
import TerminalCore
import XCTest
@testable import AgentBoardPhone

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

    func testFingerprintIsFiveGroupsOfFour() {
        let print = HostChannel.fingerprint(of: Data(repeating: 0, count: 32))
        XCTAssertEqual(print.split(separator: " ").count, 5)
        XCTAssertTrue(print.split(separator: " ").allSatisfy { $0.count == 4 })
    }
}
