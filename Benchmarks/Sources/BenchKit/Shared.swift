import Foundation

/// State a benchmark builds in `setup` and drops in `teardown`.
public final class Box<Value> {
    public var value: Value?
    public init(_ value: Value? = nil) { self.value = value }
}

/// The terminal size and scrollback of the engine benchmarks.
public enum Terminal {
    public static let cols = 120, rows = 40, scrollback = 5000
}

extension Corpus {
    /// `corpus/` of this package.
    public static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("corpus")
}

extension Recording {
    /// The real Claude Code capture up to the typed prompt, before Ctrl+C leaves the alternate screen.
    public static var claudeStartup: [UInt8] {
        Recording(url: Corpus.directory.appendingPathComponent("claude-startup.rec")).chunks.filter { $0.time <= 9 }.flatMap(\.bytes)
    }
}
