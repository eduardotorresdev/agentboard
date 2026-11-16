import AppKit
import Connections
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

    /// A saved draft comes back with its tokens; a name with a line break stays on one line.
    @Test func parsesWhatItSerializes() {
        let id = UUID()
        let text = BoardMention(name: "Two\nlines", type: "image", id: id).serialized + " see @[x](agent:nope)"
        #expect(text.hasPrefix("@[Two lines](image:"))
        #expect(BoardMention.parse(text) == [.mention(BoardMention(name: "Two lines", type: "image", id: id)),
                                             .text(" see @[x](agent:nope)")])
    }
}
