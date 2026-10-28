// swift-tools-version:5.9
import PackageDescription

// Benchmarks for the terminal engine and the app, on package-benchmark. Kept out of the app
// package: the baseline links SwiftTerm (the engine we replaced) so the before/after numbers
// stay reproducible, and the app never does.
//
// Suites are the executable targets in this directory's top level (Engine, Pacing, App), which
// is where package-benchmark looks for them: `swift package --disable-sandbox benchmark`.
let suite: [Target.Dependency] = [
    "BenchKit", "SuiteKit",
    .product(name: "Benchmark", package: "package-benchmark"),
]
let plugins: [Target.PluginUsage] = [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]

let package = Package(
    name: "Benchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/package-benchmark", exact: "1.9.2"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1"),
        .package(name: "AgentBoard", path: ".."),
    ],
    targets: [
        // Inputs: a Claude Code-like session, and that session played on a PTY as `claude`.
        .target(name: "ClaudeSim"),
        .executableTarget(name: "FakeAgent", dependencies: ["ClaudeSim"]),
        // What suites, tests and tools share: corpora, the engines and the selected one.
        .target(name: "BenchKit", dependencies: ["ClaudeSim", "Baseline", "Current"]),
        // The metrics no built-in one covers. Apart from BenchKit because package-benchmark
        // brings jemalloc, which must not be loaded into a test runner already running.
        .target(name: "SuiteKit", dependencies: [.product(name: "Benchmark", package: "package-benchmark")]),
        // The engines under test: `legacy` (SwiftTerm, before) and `core` (shipped).
        .target(name: "Baseline", dependencies: ["EngineKit", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "Current", dependencies: [
            "EngineKit",
            .product(name: "TerminalCore", package: "AgentBoard"),
            .product(name: "TerminalRenderer", package: "AgentBoard"),
            .product(name: "AgentRuntime", package: "AgentBoard"),
        ]),
        .target(name: "EngineKit"),

        // FakeAgent is a dependency so it is built next to the suite, which launches it.
        .executableTarget(name: "Engine", dependencies: suite + ["ClaudeSim", "FakeAgent"], path: "Engine", plugins: plugins),
        .executableTarget(name: "Pacing", dependencies: suite + ["ClaudeSim", .product(name: "TerminalRenderer", package: "AgentBoard")],
                          path: "Pacing", plugins: plugins),
        .executableTarget(name: "App", dependencies: suite + ["FakeAgent"], path: "App", plugins: plugins),

        // Not benchmarks: renders and prints things to look at.
        .executableTarget(name: "Inspect", dependencies: [
            "BenchKit", "ClaudeSim",
            .product(name: "TerminalCore", package: "AgentBoard"),
            .product(name: "TerminalRenderer", package: "AgentBoard"),
        ]),
        // Correctness: the same bytes through both engines.
        .testTarget(name: "CorrectnessTests", dependencies: ["BenchKit", "ClaudeSim"]),
    ]
)
