import AppKit
import Testing
@testable import AgentBoard

struct PostItMarkdownTests {
    /// Rendered text goes back to the markdown it came from (bold is always written outside underline).
    @Test func renderedMarkdownIsWrittenBackAsItWas() {
        let markdown = """
        # Title

        Plain **bold** and <u>under</u> **<u>both</u>**, *slanted*, ~~gone~~, `code` and [a link](https://example.com).

        ## Section

        - one
        - two
            - nested
        - [x] done

        1. first
        2. second

        > quoted
        >
        > again

        ```swift
        let a = 1

        let b = 2
        ```

        | Name | Value |
        | --- | --- |
        | a | 1 |

        ---

        snake_case, 2 \\* 3 and a \\<tag>
        """
        #expect(MarkdownText.markdown(from: MarkdownText.render(markdown)) == markdown)
    }

    @Test func typedTextThatLooksLikeMarkdownStaysText() {
        let typed = NSAttributedString(string: "# not a heading\n1. not a list\n*plain*", attributes: MarkdownText.attributes(heading: nil))
        let markdown = MarkdownText.markdown(from: typed)
        #expect(markdown == "\\# not a heading\n\n1\\. not a list\n\n\\*plain\\*")
        #expect(MarkdownText.render(markdown).string == typed.string)
    }

    @Test func boldEndingInASpaceStillParses() {
        let text = NSMutableAttributedString(string: "bold ", attributes: [.font: MarkdownText.font(size: 15, bold: true)])
        text.append(NSAttributedString(string: "plain", attributes: MarkdownText.attributes(heading: nil)))
        #expect(MarkdownText.markdown(from: text) == "**bold** plain")
    }

    @Test func handwritingFontIsInstalled() {
        #expect(Theme.Font.hand(size: 15).familyName == "Board Hand")
    }

    @MainActor @Test func headingAndUnderlineFromTheToolbarReachTheMarkdown() {
        let editor = PostItEditor()
        var written = ""
        editor.onWrite = { written = $0 }
        editor.show("first\n\nsecond")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
        editor.setHeading(2)
        editor.textView.setSelectedRange(NSRange(location: 6, length: 6))
        editor.toggleUnderline()
        editor.toggleBold()
        editor.flush()
        #expect(written == "## first\n\n**<u>second</u>**")
    }
}
