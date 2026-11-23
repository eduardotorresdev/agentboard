import AppKit
import Foundation
import Testing
@testable import AgentBoard
@testable import AgentRuntime

struct PickerQueryTests {
    @Test func slashStartingTheDraftAsksForCommands() {
        #expect(PickerQuery.parse("/") == .command(""))
        #expect(PickerQuery.parse("/MoD") == .command("mod"))
        // Only before the first space, and only at the start of the draft.
        #expect(PickerQuery.parse("/model x") == nil)
        #expect(PickerQuery.parse("run /model") == nil)
    }

    @Test func atStartingAWordAsksForElements() {
        #expect(PickerQuery.parse("@") == .mention(at: 0, ""))
        #expect(PickerQuery.parse("see @Spec") == .mention(at: 4, "spec"))
        #expect(PickerQuery.parse("mail@host") == nil)
        #expect(PickerQuery.parse("@spec done") == nil)
    }

    @Test func doubleAtAsksForOtherProjects() {
        #expect(PickerQuery.parse("@@") == .place(at: 0, ""))
        #expect(PickerQuery.parse("ask @@Front") == .place(at: 4, "front"))
        #expect(PickerQuery.parse("@@@") == nil)
        #expect(PickerQuery.parse("x@@a") == nil)
    }

    @MainActor @Test func doubleAtEntersAModeWithAFreeQuery() {
        let view = ComposerTextView()
        view.insertText("ask @", replacementRange: view.selectedRange())
        view.insertText("@", replacementRange: view.selectedRange())
        #expect(view.chipRange != nil)
        #expect(view.otherProjectsQuery == "")
        view.insertText("front end", replacementRange: view.selectedRange())
        #expect(view.otherProjectsQuery == "front end")
        // Neither the chip nor the mode is sent: only the text.
        #expect(BoardMention.serialize(view.textStorage!) == "ask front end")
    }

    /// In a window, so the text is laid out as in the app: changing the text inside the text
    /// view's own edit left the layout behind and crashed on the next Backspace.
    @MainActor private func hosted() -> (ComposerTextView, NSWindow) {
        let view = ComposerTextView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 80)
        window.contentView = view
        window.makeFirstResponder(view)
        // As the card does: every change asks how many lines the text takes.
        view.onChange = { [unowned view] _ in _ = view.lineCount }
        return (view, window)
    }

    /// Real key events, through the input context as the app gets them.
    @MainActor private func type(_ text: String, in view: ComposerTextView) {
        for character in text { press(String(character), code: 0, in: view) }
    }

    @MainActor private func press(_ characters: String, code: UInt16, in view: ComposerTextView) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    @MainActor private func backspace(_ view: ComposerTextView) { press("\u{7F}", code: 51, in: view) }

    @MainActor @Test func backspaceOnAnEmptyQueryLeavesTheMode() {
        let (view, window) = hosted()
        defer { window.close() }
        type("@@x", in: view)
        _ = view.lineCount
        backspace(view)
        #expect(view.otherProjectsQuery == "")
        _ = view.lineCount
        backspace(view)
        _ = view.lineCount
        #expect(view.chipRange == nil)
        #expect(view.string.isEmpty)
    }

    @MainActor @Test func theModeSurvivesLosingFocus() {
        let (view, window) = hosted()
        defer { window.close() }
        type("@@", in: view)
        window.makeFirstResponder(nil)
        #expect(window.makeFirstResponder(view))
        type("api", in: view)
        _ = view.lineCount
        #expect(view.otherProjectsQuery == "api")
    }

    @MainActor @Test func escapeLeavesTheModeKeepingTheText() {
        let (view, window) = hosted()
        defer { window.close() }
        type("@@api", in: view)
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(view.chipRange == nil)
        #expect(view.string == "api")
        // The key itself, as the app gets it.
        type(" @@", in: view)
        #expect(view.chipRange != nil)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        #expect(view.chipRange == nil)
        #expect(view.string == "api ")
        _ = view.lineCount
    }

    @Test func aFolderGitNoLongerListsStillNamesItsProject() {
        #expect(RemoteAgent.project(ofFolder: "/Users/me/pbs-worktrees/fix-bugs") == "pbs")
        #expect(RemoteAgent.project(ofFolder: "/Users/me/iandara") == "iandara")
    }

    @Test func remoteAgentsMatchEveryWordAcrossTheirNames() {
        let agent = RemoteAgent(project: "Shop", worktree: "Checkout flow", isBoard: false,
                                agent: BoardMention(name: "Claude 2", type: "agent", id: UUID()))
        #expect(agent.matches(""))
        #expect(agent.matches("claude shop"))
        #expect(agent.matches("flow  2 sho"))
        #expect(!agent.matches("shop billing"))
        #expect(agent.shown == "Shop › Checkout flow › Claude 2")
    }

    /// Commands hand the keys to the terminal; a path at the start of a message isn't one.
    @Test func commandsAreTellFromPaths() {
        #expect(ComposerTextView.isCommand("/model"))
        #expect(ComposerTextView.isCommand("/review 42"))
        #expect(!ComposerTextView.isCommand("/Users/me/file.txt look"))
        #expect(!ComposerTextView.isCommand("/"))
        #expect(!ComposerTextView.isCommand("fix /model"))
    }

    @Test func commandKindComesFromWhereItIsDefined() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let skill = "skill-\(UUID().uuidString.prefix(8))", command = "command-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude/skills/\(skill)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude/commands"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".claude/commands/\(command).md"))
        let commands = ClaudeCode().commands(in: folder.path)
        #expect(commands.first { $0.name == "model" }?.kind == .builtin)
        #expect(commands.first { $0.name == skill }?.kind == .skill)
        #expect(commands.first { $0.name == command }?.kind == .command)
        #expect(PickerItem.command(commands.first { $0.name == skill }!).icon == .symbol("sparkles", color: Theme.Hex.inkMuted))
    }
}

@MainActor
struct ComposerPasteTests {
    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        board.clearContents()
        fill(board)
        return board
    }

    @Test func aPictureAloneIsAttached() {
        let board = pasteboard { $0.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png) }
        #expect(AgentStore.attachments(on: board) == [.data(Data([0x89, 0x50, 0x4E, 0x47]))])
        #expect(ComposerTextView.takesAttachment(from: board))
    }

    @Test func copiedFilesAreAttachedEvenWithTheirNames() {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        let board = pasteboard { $0.writeObjects([url as NSURL]); $0.setString("shot.png", forType: .string) }
        #expect(AgentStore.attachments(on: board) == [.file(url)])
        #expect(ComposerTextView.takesAttachment(from: board))
    }

    @Test func textStaysText() {
        #expect(!ComposerTextView.takesAttachment(from: pasteboard { $0.setString("hello", forType: .string) }))
        // A picture copied with its text (a web page) pastes the text.
        let both = pasteboard { $0.setData(Data([1]), forType: .png); $0.setString("caption", forType: .string) }
        #expect(!ComposerTextView.takesAttachment(from: both))
    }
}
