import AppKit
import Foundation
import Testing
@testable import AgentBoard

struct MentionTests {
    @Test func serializesTokensWithNameTypeAndID() {
        let id = UUID()
        let mention = BoardMention(name: "Spec [v2]", type: "postit", id: id)
        let draft = NSMutableAttributedString(string: "Read ")
        draft.append(NSAttributedString(string: "@Spec [v2]", attributes: [BoardMention.attribute: mention]))
        draft.append(NSAttributedString(string: " and @plain"))
        #expect(BoardMention.serialize(draft) == "Read @[Spec (v2)](postit:\(id.uuidString)) and @plain")
    }
}
