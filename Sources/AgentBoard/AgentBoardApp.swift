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
        // Browsers load first so the agents keep their lines to them.
        let browsers = BrowserStore(database: store.database)
        let agents = AgentStore(database: store.database, elements: browsers.ids)
        browsers.attach(to: agents)
        _agents = State(initialValue: agents)
        _browsers = State(initialValue: browsers)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, agents: agents, browsers: browsers)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}

// A SwiftPM executable runs without an .app bundle: without this, macOS doesn't treat it
// as a foreground app (no Dock icon, window stays behind the terminal).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Light mode only: pin the appearance so sheets, panels, and menus match.
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate(ignoringOtherApps: true)
    }
}
