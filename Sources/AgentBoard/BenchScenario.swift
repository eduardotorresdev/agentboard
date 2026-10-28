#if BENCH
import AppKit
import QuartzCore

/// Bench builds only (`swift build -Xswiftc -DBENCH`, done by Benchmarks/App): the scenario the
/// benchmark asks for through the environment. None of this is compiled into the shipped app.
enum BenchScenario {
    private static let environment = ProcessInfo.processInfo.environment

    /// The run's own database, so the user's data is never touched.
    static let database = environment["AGENTBOARD_BENCH_DB"].map { URL(fileURLWithPath: $0) }
    /// The worktree shown once the window is up, and the one switched to after `switchAfter` seconds.
    static let worktree = environment["AGENTBOARD_BENCH_WORKTREE"]
    static let switchTo = environment["AGENTBOARD_BENCH_SWITCH_TO"]
    static let switchAfter = environment["AGENTBOARD_BENCH_SWITCH_AFTER"].flatMap(Double.init)
    /// The window sits behind the others, lets clicks through, and the board draws while covered,
    /// so a run doesn't take the screen.
    static let background = environment["AGENTBOARD_BENCH_BACKGROUND"] == "1"
    /// Once the start screens are drawn, focus the first card still printing (the working agent).
    static let focusPrinting = environment["AGENTBOARD_BENCH_FOCUS"] == "printing"

    private static let launched = CACurrentMediaTime()
    private static var focused = false

    /// The card to focus now, once: the first one that changed, 8 s after launch.
    static func cardToFocus<ID>(among changed: Set<ID>) -> ID? {
        guard focusPrinting, !focused, CACurrentMediaTime() - launched > 8, let id = changed.first else { return nil }
        focused = true
        return id
    }

    @MainActor static func arrangeWindow() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        if let screen = window.screen { window.setFrame(screen.visibleFrame, display: true) }
        if background {
            window.ignoresMouseEvents = true
            window.orderBack(nil)
            NSApp.deactivate()
        }
    }
}
#endif
