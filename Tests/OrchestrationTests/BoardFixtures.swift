import AgentRuntime
import Connections
import Foundation
import Testing
@testable import Orchestration

/// Writes the JSON of this module's wire types, and a database written by `CardDatabase`, to
/// `core/fixtures/orchestration`, where the Rust core's tests check that it decodes and encodes
/// them the same way (docs/hosts.md).
struct BoardFixtures {
    private static let ids = (1...9).map { UUID(uuidString: "0000000\($0)-ABCD-4EF0-8A1B-00000000000\($0)")! }
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/fixtures/orchestration")
    private static let date = Date(timeIntervalSinceReferenceDate: 784_111_222.5)

    private static var agent: AgentRecord {
        AgentRecord(id: ids[0], worktree: "/work/tree", providerID: "claude", name: "Ada", frame: CGRect(x: 12.5, y: -40, width: 640, height: 420),
                    organization: ids[7], orchestrates: true, conversation: ids[8])
    }
    private static var runner: AgentRecord {
        AgentRecord(id: ids[1], worktree: "/work/tree", providerID: AgentRecord.runnerProviderID, name: "web",
                    frame: CGRect(x: 716.5, y: -40, width: 600, height: 340),
                    runner: RunnerSpec(command: "npm run dev", directory: "/work/tree/app", owner: ids[0]))
    }
    private static var plain: AgentRecord {
        AgentRecord(id: ids[2], worktree: "/work/tree", providerID: "codex", name: "Bob", frame: CGRect(x: 0, y: 500, width: 640, height: 420))
    }
    private static var postIt: PostItRecord {
        PostItRecord(id: ids[3], worktree: "/work/tree", name: "Plan", frame: CGRect(x: 10, y: 20, width: 340, height: 320),
                     text: "# Plan\n\n- “first”\n- second ✅", editor: ids[0], editorName: "Ada", edited: date, organization: ids[7])
    }
    private static var emptyPostIt: PostItRecord {
        PostItRecord(id: ids[4], worktree: "/work/tree", name: "Post-it", frame: CGRect(x: 400, y: 20, width: 340, height: 320))
    }
    private static var image: ImageRecord {
        ImageRecord(id: ids[5], worktree: "/work/tree", name: "Login screen", frame: CGRect(x: 1, y: 2, width: 480, height: 302),
                    file: "0000000A-ABCD-4EF0-8A1B-00000000000A.png", pixelSize: CGSize(width: 1280, height: 720), organization: ids[7])
    }
    private static var video: ImageRecord {
        ImageRecord(id: ids[6], worktree: "/work/tree", name: "Signup flow", frame: CGRect(x: 1, y: 400, width: 480, height: 302),
                    file: "0000000B-ABCD-4EF0-8A1B-00000000000B.mp4", pixelSize: CGSize(width: 1920, height: 1080), duration: 12.25)
    }
    private static var fileTree: FileTreeRecord {
        FileTreeRecord(id: ids[8], worktree: "/work/tree", name: "Files", frame: CGRect(x: -1100, y: 0.5, width: 1040, height: 680), organization: ids[7])
    }
    private static var bareFileTree: FileTreeRecord {
        FileTreeRecord(id: ids[6], worktree: "/work/tree", name: "Files 2", frame: CGRect(x: 0, y: 800, width: 1040, height: 680))
    }
    private static var lines: [Connection] {
        [Connection(id: ids[7], a: ids[0], b: ids[1], aSide: .right, bSide: .left), Connection(id: ids[8], a: ids[0], b: ids[3])]
    }
    private static var attention: [AttentionRequest] {
        let questions = [
            AgentQuestion(question: "Which layout?", header: "Layout",
                          options: [.init(label: "Grid", description: "Rows and columns"), .init(label: "List")], multiSelect: true),
            AgentQuestion(question: "Ship it?", options: []),
        ]
        return [
            AttentionRequest(id: ids[0], reason: .turnEnded, since: date, context: "Done:\nall tests pass."),
            AttentionRequest(id: ids[2], reason: .said("Claude needs your permission to use Bash"), since: date, orchestrators: ["Ada"]),
            AttentionRequest(id: ids[1], reason: .waiting, since: date, questions: questions),
        ]
    }
    private static var decisions: [Decision] {
        [
            Decision(id: ids[4], agent: ids[0], worktree: "/work/tree", organization: ids[7], family: "surface", framing: "Validate the invite screen",
                     cards: [Decision.Card(claim: "The screen ended up like this", evidence: .image(before: ids[5], after: ids[6]),
                                           pins: [Decision.Pin(x: 0.25, y: 1, question: "Here?")]),
                             Decision.Card(claim: "Only after", evidence: .image(before: nil, after: ids[6]), reference: "Against the old one")],
                     ask: .validation(question: "Can it stay?"), verified: ["Opened it"], since: date),
            Decision(id: ids[5], agent: ids[0], worktree: "/work/tree", family: "foundation", framing: "Choose the path",
                     cards: [Decision.Card(claim: "The path", evidence: .diagram(svg: "<svg viewBox=\"0 0 9 9\"/>"), reference: "Before")],
                     ask: .choice(question: "Which?", variants: [Decision.Variant(letter: "A", name: "Core", detail: "Through the core"),
                                                                 Decision.Variant(letter: "B", name: "Direct")]),
                     verified: ["Drew it", "Checked it"], blocking: true, final: true, state: .awaitingEcho, since: date, answer: .useRecommended),
            Decision(id: ids[6], agent: ids[2], worktree: "/work/tree", family: "flow", framing: "Walk the signup",
                     cards: [Decision.Card(claim: "The page", evidence: .browser(id: ids[4]), reference: "r"),
                             Decision.Card(claim: "The clip", evidence: .video(id: ids[6]), reference: "r")],
                     ask: .validation(question: "Good?"), verified: ["Ran it"], state: .closed, since: date,
                     answer: .redirect("Make it shorter"), echo: "Cut a step"),
        ]
    }
    private static var runners: RunnerReport {
        var report = RunnerReport()
        report.stats = [ids[1]: RunnerStats(cpu: 12.5, memory: 104_857_600, processes: 3,
                                            ports: [ListeningPort(port: 3000, exposed: true), ListeningPort(port: 9229, exposed: false)])]
        report.starts = [ids[1]: date]
        report.networkAddress = "192.168.1.20"
        return report
    }

    @Test func writesWireSamples() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        func write(_ value: some Encodable, _ name: String) throws {
            try encoder.encode(value).write(to: Self.folder.appendingPathComponent(name + ".json"))
        }
        let ids = Self.ids
        let result = ToolResult([.text("Opened “page”"), .image(Data([0, 1, 2, 250, 255]), mimeType: "image/png")], isError: false)
        let element = ElementInfo(id: ids[4], name: "Desktop", kind: "browser", detail: "desktop, 1280 × 720", worktree: "/work/tree",
                                  frame: CGRect(x: 5, y: 6, width: 700, height: 500), organization: ids[7])
        let bare = ElementInfo(id: ids[5], name: "Files", kind: "filetree", detail: nil, worktree: "/work/tree",
                               frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        let requests: [(String, BoardRequest)] = [
            ("addCard", .addCard(Self.agent)),
            ("updateCard", .updateCard(Self.runner)),
            ("removeCard", .removeCard(ids[0])),
            ("connect", .connect(Self.lines[0])),
            ("disconnect", .disconnect(ids[7])),
            ("elements", .elements([element, bare])),
            ("open", .open(id: ids[0], cols: 120, rows: 40, start: true)),
            ("restart", .restart(id: ids[1], command: "npm run build")),
            ("restart_as_it_is", .restart(id: ids[1], command: nil)),
            ("startRunner", .startRunner(ids[1])),
            ("stopRunner", .stopRunner(ids[1])),
            ("toolResult", .toolResult(call: ids[8], result: WireToolResult(result))),
            ("toolResult_error", .toolResult(call: ids[8], result: WireToolResult(.error("No browser is connected to you.")))),
            ("addPostIt", .addPostIt(Self.postIt)),
            ("updatePostIt", .updatePostIt(Self.emptyPostIt)),
            ("removePostIt", .removePostIt(ids[3])),
            ("writePostIt", .writePostIt(id: ids[3], text: "rewritten\nby the user")),
            ("addImage", .addImage(Self.image)),
            ("updateImage", .updateImage(Self.video)),
            ("removeImage", .removeImage(ids[5])),
            ("dismissAttention", .dismissAttention(ids[0])),
            ("answerQuestions", .answerQuestions(id: ids[0], answers: ["Which layout?": "Grid"])),
            ("answerQuestions_in_the_terminal", .answerQuestions(id: ids[0], answers: nil)),
            ("deliver", .deliver(from: ids[4], text: "src/main.rs:12 rename this")),
            ("prompt", .prompt(id: ids[0], text: "run the tests")),
            ("deliverHeld", .deliverHeld(ids[0])),
            ("deliver_to_one", .deliver(from: ids[4], text: "1. Area 48, 486, 408, 132", to: ids[0])),
            ("answerDecision_ok", .answerDecision(id: ids[4], answer: .ok)),
            ("answerDecision_option", .answerDecision(id: ids[5], answer: .option("B"))),
            ("answerDecision_useRecommended", .answerDecision(id: ids[5], answer: .useRecommended)),
            ("answerDecision_redirect", .answerDecision(id: ids[6], answer: .redirect("Make it shorter"))),
            ("createProject", .createProject(request: ids[7], name: "shop", clone: nil)),
            ("createProject_clone", .createProject(request: ids[7], name: nil, clone: "git@github.com:owner/shop.git")),
            ("createWorktree", .createWorktree(request: ids[8], project: "/Users/me/agentboard/projects/shop", branch: "fix/login")),
            ("addFileTree", .addFileTree(Self.fileTree)),
            ("updateFileTree", .updateFileTree(Self.bareFileTree)),
            ("removeFileTree", .removeFileTree(ids[8])),
        ]
        for (name, request) in requests { try write(request, "request_" + name) }
        let message = Message(id: ids[8], from: ids[0], to: ids[2], text: "Run the tests", date: Self.date)
        let events: [(String, BoardEvent)] = [
            ("cardAdded", .cardAdded(Self.runner)),
            ("cardUpdated", .cardUpdated(Self.agent)),
            ("cardRemoved", .cardRemoved(ids[1])),
            ("connections", .connections(Self.lines)),
            ("message", .message(message)),
            ("runners", .runners(Self.runners)),
            ("runners_none", .runners(RunnerReport())),
            ("toolCall", .toolCall(call: ids[8], name: "browser_click", arguments: Data(#"{"target":"e12"}"#.utf8), caller: ids[0])),
            ("postItAdded", .postItAdded(Self.postIt)),
            ("postItUpdated", .postItUpdated(Self.emptyPostIt)),
            ("postItRemoved", .postItRemoved(ids[3])),
            ("imageAdded", .imageAdded(Self.image)),
            ("imageUpdated", .imageUpdated(Self.video)),
            ("imageRemoved", .imageRemoved(ids[5])),
            ("attention", .attention(Self.attention)),
            ("held", .held(id: ids[0], count: 2)),
            ("promptReturned", .promptReturned(id: ids[0], text: "run the tests", reason: "it exited")),
            ("elements", .elements([element, bare])),
            ("decisions", .decisions(Self.decisions)),
            ("created", .created(request: ids[7], path: "/Users/me/agentboard/projects/shop", error: nil)),
            ("created_refused", .created(request: ids[8], path: nil, error: "“a..b” isn't a valid branch name.")),
            ("fileTreeAdded", .fileTreeAdded(Self.fileTree)),
            ("fileTreeUpdated", .fileTreeUpdated(Self.bareFileTree)),
            ("fileTreeRemoved", .fileTreeRemoved(ids[8])),
        ]
        for (name, event) in events { try write(event, "event_" + name) }
        let state = BoardState(cards: [Self.agent, Self.runner, Self.plain], connections: Self.lines, runners: Self.runners,
                               postIts: [Self.postIt, Self.emptyPostIt], attention: Self.attention, images: [Self.image, Self.video],
                               decisions: Self.decisions, elements: [element], fileTrees: [Self.fileTree, Self.bareFileTree])
        try write(state, "state")
        // What a core that predates post-its, attention and images sends.
        var old = BoardState(cards: [Self.plain], connections: [], runners: RunnerReport())
        old.postIts = nil
        old.attention = nil
        old.images = nil
        old.fileTrees = nil
        old.eventSources = nil
        try write(old, "state_of_an_older_core")
    }

    /// A database as this core writes it: the Rust core must read the same cards and lines from it.
    @Test func writesADatabase() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let url = Self.folder.appendingPathComponent("agentboard.sqlite")
        try? FileManager.default.removeItem(at: url)
        let database = try CardDatabase(url: url)
        for card in [Self.agent, Self.runner, Self.plain] { try database.saveAgent(card) }
        for note in [Self.postIt, Self.emptyPostIt] { try database.savePostIt(note) }
        for image in [Self.image, Self.video] { try database.saveImage(image) }
        for tree in [Self.fileTree, Self.bareFileTree] { try database.saveFileTree(tree) }
        try database.saveConnections(Self.lines)
    }

    /// A database the Rust core wrote (its test `a_database_round_trips` leaves one in
    /// `core/target/tmp/rust.sqlite`): this core reads the same records from it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBOARD_RUST_DATABASE"] != nil))
    func readsADatabaseWrittenByRust() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AGENTBOARD_RUST_DATABASE"])
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("abrust-\(UUID().uuidString.prefix(8)).sqlite")
        try FileManager.default.copyItem(atPath: path, toPath: copy.path)
        defer { try? FileManager.default.removeItem(at: copy) }
        let database = try CardDatabase(url: copy)
        #expect(try database.agents() == [Self.agent, Self.runner, Self.plain])
        #expect(try database.postIts() == [Self.postIt, Self.emptyPostIt])
        #expect(try database.images() == [Self.image, Self.video])
        #expect(try database.fileTrees() == [Self.fileTree, Self.bareFileTree])
        #expect(try database.connections() == Self.lines)
    }
}
