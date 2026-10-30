// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentBoard",
    defaultLocalization: "pt-BR",
    platforms: [.macOS(.v14)],
    products: [
        // Exposed so Benchmarks/ can measure them against the previous engine.
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "TerminalRenderer", targets: ["TerminalRenderer"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "Connections", targets: ["Connections"]),
        .library(name: "Orchestration", targets: ["Orchestration"]),
        // Loaded into Playwright's WebKit process, not linked by the app; see BrowserStore.
        .library(name: "BrowserInjection", type: .dynamic, targets: ["BrowserInjection"]),
    ],
    targets: [
        // Terminal emulation: parser, screen model, scrollback. No UI or platform code.
        .target(name: "TerminalCore"),
        // Draws TerminalCore screens with Metal: glyph atlas, GPU cell buffers, shaders, and a
        // presenter that renders each terminal into its own surface.
        .target(name: "TerminalRenderer", dependencies: ["TerminalCore"]),
        // Agent processes: what to launch (`AgentProvider`), the PTY, and the session that
        // feeds a terminal and tells the board when something visible changed.
        .target(name: "AgentRuntime", dependencies: ["TerminalCore"]),
        // Lines between board elements and the messages that travel along them: the graph, the
        // bus that delivers, the router that lays the lines out, and the MCP server agents use.
        .target(name: "Connections"),
        // Reports, from inside Playwright's WebKit process, which Core Animation context draws
        // each page, so browser cards can host the page's layers directly.
        .target(name: "BrowserInjection", linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("WebKit")]),
        // What the core keeps while no board runs: the cards, the lines between elements, the
        // agents' tools and the runners (see Orchestrator).
        .target(name: "Orchestration", dependencies: ["AgentRuntime", "Connections"], resources: [.process("Resources")]),
        // The process that owns the agents' PTYs, cards and tools, so they outlive the board
        // (see CoreServer and Orchestrator).
        .executableTarget(name: "AgentBoardCore", dependencies: ["AgentRuntime", "Orchestration"]),
        .executableTarget(
            name: "AgentBoard",
            dependencies: ["TerminalCore", "TerminalRenderer", "AgentRuntime", "Connections", "Orchestration"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
        .testTarget(name: "AgentRuntimeTests", dependencies: ["AgentRuntime", "TerminalCore"]),
        .testTarget(name: "ConnectionsTests", dependencies: ["Connections"]),
        .testTarget(name: "OrchestrationTests", dependencies: ["Orchestration", "AgentRuntime", "Connections"]),
        .testTarget(name: "TerminalRendererTests", dependencies: ["TerminalRenderer", "TerminalCore"]),
        .testTarget(name: "AgentBoardTests", dependencies: ["AgentBoard", "AgentRuntime", "Orchestration"]),
    ]
)
