import AppKit
import SwiftUI

@main
struct AgentBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: ProjectStore
    @State private var agents: AgentStore
    @State private var browsers: BrowserStore

    init() {
        let store = ProjectStore()
        _store = State(initialValue: store)
        let browsers = BrowserStore(database: store.database)
        // A core in this process keeps the cards in the same file as the projects (a bench run's own).
        let agents = AgentStore(database: try? Database.defaultURL())
        browsers.attach(to: agents)
        AppDelegate.agents = agents
        _agents = State(initialValue: agents)
        _browsers = State(initialValue: browsers)
    }

    var body: some Scene {
        WindowGroup("AgentBoard") {
            ContentView(store: store, agents: agents, browsers: browsers)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
                .modifier(DevBuildToolbar())
        }
    }
}

/// A build of the checkout (`./run`) paints the window's toolbar violet, so it reads apart from
/// the installed app beside it while keeping the same title and layout.
private struct DevBuildToolbar: ViewModifier {
    private let isDevBuild = Bundle.main.bundleURL.pathExtension != "app"

    func body(content: Content) -> some View {
        if isDevBuild {
            content
                .toolbarBackground(Theme.accent, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .toolbarColorScheme(.dark, for: .windowToolbar)
        } else {
            content
        }
    }
}

// A SwiftPM executable runs without an .app bundle: without this, macOS doesn't treat it
// as a foreground app (no Dock icon, window stays behind the terminal).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var agents: AgentStore?
    private var terminationSource: DispatchSourceSignal?
    private var screensSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Light mode only: pin the appearance so sheets, panels, and menus match.
        NSApp.appearance = NSAppearance(named: .aqua)
        // A board under test (`AGENTBOARD_BACKGROUND=1`) stays behind: keys typed elsewhere
        // must not reach its agents.
        if ProcessInfo.processInfo.environment["AGENTBOARD_BACKGROUND"] != "1" { NSApp.activate(ignoringOtherApps: true) }
        // SIGTERM is how `./run --watch` replaces the app: leave right away, agents untouched.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { exit(0) }
        terminate.resume()
        terminationSource = terminate
        if let path = ProcessInfo.processInfo.environment["AGENTBOARD_SCREENS"] { writeScreens(to: path) }
    }

    /// For tests: on SIGUSR1, writes every card's terminal (`Terminal.snapshot()`, base64, by
    /// card id) to `path`, so they can be checked against what the programs wrote.
    private func writeScreens(to path: String) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            let screens = MainActor.assumeIsolated { Self.agents?.sessions ?? [:] }
                .reduce(into: [String: String]()) { $0[$1.key.uuidString] = Data($1.value.withTerminal { $0.snapshot() }).base64EncodedString() }
            let data = (try? JSONSerialization.data(withJSONObject: screens)) ?? Data()
            try? data.write(to: URL(fileURLWithPath: path + ".part"))
            rename(path + ".part", path)
        }
        source.resume()
        screensSource = source
    }

    /// Quitting ends the agents, as closing a terminal would. Being killed (a rebuild) doesn't:
    /// they stay on the core for the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.agents?.quit() }
    }
}
