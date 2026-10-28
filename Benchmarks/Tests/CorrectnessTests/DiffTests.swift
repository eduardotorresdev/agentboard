import BenchKit
import ClaudeSim
import Testing

/// The same bytes through the legacy engine (SwiftTerm, the reference) and the shipped one,
/// comparing text, colors, bold and cursor every 32 KB along the way, not just at the end, so
/// transient divergence shows up too.
///
/// One difference is known and on purpose: a line as wide as the screen followed by `ESC[K`.
/// xterm erases the last cell (the cursor sits on it with a wrap pending); SwiftTerm keeps it.
/// The core follows xterm (TerminalTests.eraseLineWithPendingWrapClearsTheLastColumn), so style
/// differences in the last column are left out.
struct DiffTests {
    struct Source: CustomTestStringConvertible, Sendable {
        let name: String
        let bytes: @Sendable () -> [UInt8]
        var testDescription: String { name }
    }

    static let sources: [Source] = {
        var sources: [Source] = []
        for mode in ClaudeSim.Mode.allCases {
            for seed in 1...3 {
                sources.append(Source(name: "sim-\(mode.rawValue)-\(seed)") {
                    ClaudeSim.dump(seconds: 15, cols: Terminal.cols, rows: Terminal.rows, mode: mode, seed: UInt64(seed))
                })
            }
        }
        sources.append(Source(name: "claude-real") { Recording.claudeStartup })
        for corpus in [Corpus.sgr, .unicode] {
            sources.append(Source(name: corpus.rawValue) { Array(corpus.bytes(corpusDirectory: Corpus.directory).prefix(256 * 1024)) })
        }
        return sources
    }()

    @Test(arguments: sources)
    func coreShowsWhatLegacyShows(_ source: Source) throws {
        let reference = try #require(Engines.named("legacy")), shipped = try #require(Engines.named("core"))
        let a = reference.terminal.init(cols: Terminal.cols, rows: Terminal.rows, scrollback: Terminal.scrollback)
        let b = shipped.terminal.init(cols: Terminal.cols, rows: Terminal.rows, scrollback: Terminal.scrollback)
        var differences: [String] = []
        func compare(at offset: Int) {
            let ta = a.screenText(), tb = b.screenText()
            for row in 0..<min(ta.count, tb.count) where ta[row] != tb[row] {
                differences.append("at \(offset) B, row \(row)\n  legacy: \(ta[row])\n  core:   \(tb[row])")
            }
            let sa = a.screenStyles(), sb = b.screenStyles()
            for row in 0..<min(sa.count, sb.count) {
                for column in 0..<min(sa[row].count, sb[row].count) - 1 where sa[row][column] != sb[row][column] {
                    differences.append("at \(offset) B, cell \(column),\(row): \(sa[row][column]) vs \(sb[row][column])")
                }
            }
            if a.cursor != b.cursor { differences.append("at \(offset) B, cursor \(a.cursor) vs \(b.cursor)") }
        }
        var fed = 0
        feedInChunks(source.bytes()) { chunk in
            a.feed(chunk)
            b.feed(chunk)
            fed += chunk.count
            if fed % (32 * 1024) < chunk.count { compare(at: fed) }
        }
        compare(at: fed)
        #expect(differences.isEmpty, "\(differences.count) differences, first: \(differences.prefix(4).joined(separator: "\n"))")
    }
}
