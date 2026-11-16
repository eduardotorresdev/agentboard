import AgentRuntime
import AppKit
import SwiftUI

@main
struct AgentBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: ProjectStore
    @State private var hosts: HostStores
    @State private var browsers: BrowserStore
    @State private var fileTrees: FileTreeStore

    init() {
        let store = ProjectStore()
        _store = State(initialValue: store)
        let browsers = BrowserStore(database: store.database)
        // A core in this process keeps the cards in the same file as the projects (a bench run's own).
        let agents = AgentStore(database: try? Database.defaultURL())
        browsers.attach(to: agents)
        let fileTrees = FileTreeStore(database: store.database)
        fileTrees.attach(to: agents)
        _fileTrees = State(initialValue: fileTrees)
        let hosts = HostStores(local: agents, account: AccountStore(database: store.database))
        hosts.prepare = { [unowned hosts] in
            $0.projectTools = ProjectTools(projects: store, agents: $0, hosts: hosts)
            // Another host's store gets the board's browsers and file trees as this Mac's did above.
            if $0.host != nil {
                browsers.attach(to: $0)
                fileTrees.attach(to: $0)
            }
        }
        hosts.syncHome = FileManager.default.homeDirectoryForCurrentUser
        hosts.vaultKeys = .standardVaultKey
        hosts.vaultState = DataFolder.url.appendingPathComponent("vault.base")
        hosts.githubLogin = { HostSync.githubLogin() }
        let account = hosts.account
        browsers.makeProxy = { HostProxy(account: account) }
        hosts.prepare?(agents)
        store.hosts = hosts
        AppDelegate.agents = agents
        _hosts = State(initialValue: hosts)
        _browsers = State(initialValue: browsers)
    }

    var body: some Scene {
        WindowGroup("AgentBoard") {
            ContentView(store: store, hosts: hosts, browsers: browsers, fileTrees: fileTrees)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}


/// What a build under test opens at launch, for screenshots: `AGENTBOARD_SHOW`, a list
/// separated by commas of `account-menu`, `sign-in`, `new-worktree` (of the first project) and
/// the path of a worktree to open (see docs/core.md).
enum DebugShow {
    static let items = Set((ProcessInfo.processInfo.environment["AGENTBOARD_SHOW"] ?? "").split(separator: ",").map(String.init))
    static var worktree: String? { items.first { $0.hasPrefix("/") } }
}

// A SwiftPM executable runs without an .app bundle: without this, macOS doesn't treat it
// as a foreground app (no Dock icon, window stays behind the terminal).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var agents: AgentStore?
    private var terminationSource: DispatchSourceSignal?
    private var screensSource: DispatchSourceSignal?
    private var shotsSource: DispatchSourceSignal?

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
        terminate.setEventHandler {
            MainActor.assumeIsolated { ComposerDrafts.flush() }
            exit(0)
        }
        terminate.resume()
        terminationSource = terminate
        if let path = ProcessInfo.processInfo.environment["AGENTBOARD_SCREENS"] { writeScreens(to: path) }
        if let folder = ProcessInfo.processInfo.environment["AGENTBOARD_SHOTS"] { writeShots(to: folder) }
    }

    /// For looking at a build under test: on SIGUSR2, writes a PNG of every window the app shows
    /// (menus, sheets and panels are windows too) into `folder`, then an empty `done`.
    private func writeShots(to folder: String) {
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let folder = URL(fileURLWithPath: folder)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("done"))
                for (index, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                    guard let image = Self.shot(of: window) else { continue }
                    let name = "\(index)-\(String(describing: type(of: window))).png"
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                }
                // All of them as the screen shows them together: a menu's glass over what is behind it.
                if let image = Self.shot(of: NSApp.windows.filter(\.isVisible)) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("together.png"))
                }
                FileManager.default.createFile(atPath: folder.appendingPathComponent("done").path, contents: nil)
            }
        }
        source.resume()
        shotsSource = source
    }

    /// The largest window with the app's other windows over it (a menu's glass over what is
    /// behind it), as the screen has them. Without Screen Recording permission the window
    /// server leaves other apps' windows out.
    @MainActor private static func shot(of windows: [NSWindow]) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let main = windows.max(by: { $0.frame.width < $1.frame.width }), let screen = NSScreen.screens.first,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        // The window server counts from the top of the first screen.
        let area = CGRect(x: main.frame.minX, y: screen.frame.maxY - main.frame.maxY, width: main.frame.width, height: main.frame.height)
        // On screen above this window, and the window itself.
        return unsafeBitCast(symbol, to: Capture.self)(area, 1 << 1 | 1 << 3, UInt32(main.windowNumber), 1 << 3)?.takeRetainedValue()
    }

    /// The window as the window server draws it (glass and Metal layers included), which needs
    /// no Screen Recording permission for the app's own windows; else what its views draw.
    @MainActor private static func shot(of window: NSWindow) -> CGImage? {
        // Looked up by name: the SDK no longer declares it.
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            // Only this window, without its shadow, at the screen's resolution.
            let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue()
            if let image, image.width > 1 { return image }
        }
        guard let view = window.contentView, let pixels = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: pixels)
        return pixels.cgImage
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
        MainActor.assumeIsolated {
            ComposerDrafts.flush()
            Self.agents?.quit()
        }
    }
}
