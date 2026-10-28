import ClaudeSim
import Foundation

// Deterministic inputs: byte corpora and the real capture.

/// Byte streams fed to engines. All deterministic, around 4 MB each.
public enum Corpus: String, CaseIterable {
    /// Plain ASCII lines, like `cat` of a source file.
    case ascii
    /// Syntax-highlighted code: 256-color and truecolor SGR around most tokens.
    case sgr
    /// Accented Portuguese, CJK, emoji and box drawing.
    case unicode
    /// The Claude Code simulator, busy (streaming and tool calls back to back).
    case claude
    /// A captured real Claude Code startup, repeated.
    case claudeReal = "claude-real"

    public static let size = 4 << 20

    public func bytes(corpusDirectory: URL) -> [UInt8] {
        var rng = SplitMix64(seed: 42)
        var out: [UInt8] = []
        out.reserveCapacity(Self.size + 4096)
        switch self {
        case .ascii:
            while out.count < Self.size { out += Array((Self.codeLine(&rng) + "\r\n").utf8) }
        case .sgr:
            while out.count < Self.size { out += Array((Self.highlightedLine(&rng) + "\r\n").utf8) }
        case .unicode:
            let samples = ["atualização incremental não é só otimização", "终端渲染器使用图形处理器绘制", "🚀 deploy ✨ pronto 🔥",
                           "│ coluna │ valor ─┼─ total │", "ação → reação ⇒ ✓ ✗ ⏺ ⎿ ❯", "한국어 텍스트 렌더링", "e\u{301}clair nai\u{308}ve"]
            while out.count < Self.size {
                var line = ""
                while line.count < 70 { line += samples[rng.int(0...samples.count - 1)] + " " }
                out += Array((line + "\r\n").utf8)
            }
        case .claude:
            var seed: UInt64 = 1
            while out.count < Self.size {
                out += ClaudeSim.dump(seconds: 300, mode: .stream, seed: seed)
                seed += 1
            }
        case .claudeReal:
            let record = Recording(url: corpusDirectory.appendingPathComponent("claude-startup.rec"))
            let stream = record.chunks.flatMap(\.bytes)
            guard !stream.isEmpty else { return [] }
            while out.count < Self.size { out += stream }
        }
        return out
    }

    private static let keywords = ["func", "let", "var", "guard", "return", "if", "else", "for", "in", "struct", "final", "class"]
    private static let names = ["session", "terminal", "cells", "frame", "atlas", "row", "column", "scale", "bounds", "origin", "quads"]

    private static func codeLine(_ rng: inout SplitMix64) -> String {
        var line = String(repeating: "    ", count: rng.int(0...3))
        while line.count < rng.int(30...110) {
            line += rng.chance(0.3) ? keywords[rng.int(0...keywords.count - 1)] : names[rng.int(0...names.count - 1)]
            line += rng.chance(0.2) ? "(" : rng.chance(0.2) ? ") " : " "
        }
        return line
    }

    private static func highlightedLine(_ rng: inout SplitMix64) -> String {
        var line = String(repeating: "    ", count: rng.int(0...3))
        var visible = line.count
        while visible < rng.int(30...110) {
            let token: String
            if rng.chance(0.3) {
                token = keywords[rng.int(0...keywords.count - 1)]
                line += "\u{1b}[38;5;\(rng.int(160...231))m\(token)\u{1b}[39m"
            } else if rng.chance(0.3) {
                token = "\"\(names[rng.int(0...names.count - 1)])\""
                line += "\u{1b}[38;2;\(rng.int(0...255));\(rng.int(0...255));\(rng.int(0...255))m\(token)\u{1b}[0m"
            } else {
                token = names[rng.int(0...names.count - 1)]
                line += rng.chance(0.2) ? "\u{1b}[1m\(token)\u{1b}[22m" : token
            }
            line += " "
            visible += token.count + 1
        }
        return line
    }
}

/// A timed PTY capture: little-endian (milliseconds, length) headers, then the bytes.
public struct Recording {
    public struct Chunk { public let time: Double; public let bytes: [UInt8] }
    public let chunks: [Chunk]

    public init(url: URL) {
        let data = (try? Data(contentsOf: url)).map { [UInt8]($0) } ?? []
        var chunks: [Chunk] = []
        var index = 0
        func word(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        while index + 8 <= data.count {
            let time = word(index), length = word(index + 4)
            index += 8
            guard index + length <= data.count else { break }
            chunks.append(Chunk(time: Double(time) / 1000, bytes: Array(data[index..<index + length])))
            index += length
        }
        self.chunks = chunks
    }
}

/// Feeds `bytes` in PTY-sized pieces, the way a session receives them.
public func feedInChunks(_ bytes: [UInt8], chunk: Int = 1024, _ feed: (UnsafeRawBufferPointer) -> Void) {
    bytes.withUnsafeBytes { feedInChunks($0, chunk: chunk, feed) }
}

public func feedInChunks(_ all: UnsafeRawBufferPointer, chunk: Int = 1024, _ feed: (UnsafeRawBufferPointer) -> Void) {
    var offset = 0
    while offset < all.count {
        let end = min(all.count, offset + chunk)
        feed(UnsafeRawBufferPointer(rebasing: all[offset..<end]))
        offset = end
    }
}
