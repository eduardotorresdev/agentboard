import CoreGraphics
import Foundation
import Metal

// What a benchmark measures: an engine behind these protocols, so the same benchmark runs on
// the legacy engine and on the shipped one.

/// An engine under test, picked with `BENCH_ENGINE`.
public struct Engine {
    public let name: String
    public let terminal: TerminalUnderTest.Type
    public let board: BoardUnderTest.Type

    public init(name: String, terminal: TerminalUnderTest.Type, board: BoardUnderTest.Type) {
        self.name = name
        self.terminal = terminal
        self.board = board
    }
}

/// A terminal engine fed bytes directly (parse, memory and correctness benchmarks).
public protocol TerminalUnderTest: AnyObject {
    init(cols: Int, rows: Int, scrollback: Int)
    func feed(_ bytes: UnsafeRawBufferPointer)
    /// The visible screen as plain text, trailing spaces trimmed, for differential testing.
    func screenText() -> [String]
    /// Visible cells as (text, foreground, background, bold) strings, for differential testing.
    func screenStyles() -> [[String]]
    var cursor: (col: Int, row: Int) { get }
}

/// A whole board as the app draws it: cards with live sessions, rendered offscreen.
public protocol BoardUnderTest: AnyObject {
    /// How the board's terminals are given surfaces to draw into, as `--surface` names them;
    /// the first is what the app does.
    static var surfaces: [String] { get }
    init(offscreen: Offscreen, cards: [CGRect], scale: CGFloat, scrollback: Int, surface: String)
    /// Bytes straight into a card's terminal, as if they came from its PTY.
    func feed(card: Int, _ bytes: UnsafeRawBufferPointer)
    /// Starts a real process in a card's PTY.
    func launch(card: Int, executable: String, arguments: [String])
    /// True when the app would draw a frame now.
    var needsDisplay: Bool { get }
    /// Whether the cards' worktree is the one on screen (false simulates switching away).
    var cardsVisible: Bool { get set }
    /// Encodes one frame into the offscreen target and commits it.
    @discardableResult func render() -> MTLCommandBuffer
    func stop()
    /// Columns and rows of a card's terminal.
    func gridSize(card: Int) -> (cols: Int, rows: Int)
    /// Renders a frame that shows everything in the offscreen target, for looking at it.
    @discardableResult func renderSnapshot() -> MTLCommandBuffer
}

extension BoardUnderTest {
    public init(offscreen: Offscreen, cards: [CGRect], scale: CGFloat, scrollback: Int) {
        self.init(offscreen: offscreen, cards: cards, scale: scale, scrollback: scrollback, surface: Self.surfaces[0])
    }

    public func renderSnapshot() -> MTLCommandBuffer { render() }
}

/// Cards laid out like a user would with `count` agents on one canvas (a 4-wide grid of 640x420).
public func cardFrames(count: Int) -> [CGRect] {
    (0..<count).map { index in
        CGRect(x: 40 + CGFloat(index % 4) * 660, y: 80 + CGFloat(index / 4) * 440, width: 640, height: 420)
    }
}
