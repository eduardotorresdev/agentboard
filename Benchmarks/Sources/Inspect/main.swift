import BenchKit
import ClaudeSim
import CoreGraphics
import Foundation

// inspect: renders and prints things to look at; measures nothing.
//   inspect screen   [--engine core] [--seconds 12] [--mode mixed] [--seed 1]   the 120x40 screen after a session
//   inspect snapshot [--engine core] [--source sim|real] [--out card.png]       one card rendered offscreen
//   inspect layers   [--out layers.png]          cards showing a SharedSurface through Core Animation

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst(2).makeIterator()
while let key = arguments.next(), key.hasPrefix("--") { options[String(key.dropFirst(2))] = arguments.next() ?? "" }
let engine = Engines.named(options["engine"] ?? "core") ?? { fatalError("--engine legacy|core") }()
let mode = ClaudeSim.Mode(rawValue: options["mode"] ?? "mixed") ?? { fatalError("--mode mixed|stream|spinner") }()
let seconds = Double(options["seconds"] ?? "12") ?? 12, seed = UInt64(options["seed"] ?? "1") ?? 1

switch CommandLine.arguments.dropFirst().first {
case "screen":
    let bytes = ClaudeSim.dump(seconds: seconds, cols: Terminal.cols, rows: Terminal.rows, mode: mode, seed: seed)
    let terminal = engine.terminal.init(cols: Terminal.cols, rows: Terminal.rows, scrollback: Terminal.scrollback)
    feedInChunks(bytes) { terminal.feed($0) }
    for (index, line) in terminal.screenText().enumerated() { print(String(format: "%2d|", index + 1) + line) }
    print("bytes: \(bytes.count), cursor: \(terminal.cursor)")

case "snapshot":
    let card = CGRect(x: 40, y: 40, width: 1000, height: 820)
    let offscreen = Offscreen(width: Int((card.maxX + 40) * 2), height: Int((card.maxY + 40) * 2))
    let board = engine.board.init(offscreen: offscreen, cards: [card], scale: 2, scrollback: Terminal.scrollback)
    let size = board.gridSize(card: 0)
    let bytes = options["source"] == "real"
        ? Recording.claudeStartup
        : ClaudeSim.dump(seconds: seconds, cols: size.cols, rows: size.rows, mode: mode, seed: seed)
    feedInChunks(bytes) { board.feed(card: 0, $0) }
    board.renderSnapshot().waitUntilCompleted()
    let out = URL(fileURLWithPath: options["out"] ?? "\(engine.name)-snapshot.png")
    offscreen.writePNG(to: out)
    print("\(size.cols)x\(size.rows) -> \(out.path)")

case "layers":
    let out = URL(fileURLWithPath: options["out"] ?? "layers.png")
    renderLayers(to: out)
    print("layers -> \(out.path)")

default:
    print("usage: inspect screen|snapshot|layers [--engine legacy|core] [--mode mixed|stream|spinner] [--seconds N] [--seed N] [--source sim|real] [--out PATH]")
    exit(2)
}
