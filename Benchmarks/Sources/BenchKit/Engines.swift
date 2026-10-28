@_exported import EngineKit
import Baseline
import Current
import Foundation

public enum Engines {
    public static let all = [
        Engine(name: "legacy", terminal: LegacyTerminal.self, board: LegacyBoard.self),
        Engine(name: "core", terminal: CoreTerminal.self, board: CoreBoard.self),
    ]

    /// The engine a run measures: `BENCH_ENGINE=legacy|core`, `core` when unset. A run's
    /// baseline is named after it, so `baseline compare legacy core` is the before and after.
    public static let selected: Engine = {
        let name = ProcessInfo.processInfo.environment["BENCH_ENGINE"] ?? "core"
        guard let engine = all.first(where: { $0.name == name }) else {
            fatalError("BENCH_ENGINE=\(name): one of \(all.map(\.name).joined(separator: ", "))")
        }
        return engine
    }()

    public static func named(_ name: String) -> Engine? { all.first { $0.name == name } }
}
