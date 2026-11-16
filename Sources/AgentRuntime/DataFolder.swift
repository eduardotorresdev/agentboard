import Foundation

/// Where the board and the core keep their state: the database, the core's socket and log,
/// the tool server's key. `AGENTBOARD_HOME` points it elsewhere, so a second instance (a build
/// under test) runs with its own data, agents and core.
public enum DataFolder {
    public static var url: URL {
        switch resolve(ProcessInfo.processInfo.environment, underTests: runsUnderTests) {
        case .folder(let url): return url
        // Tests must never touch the user's data: a test core once swept their images.
        case .refuse(let reason): preconditionFailure(reason)
        }
    }

    public enum Resolution: Equatable {
        case folder(URL)
        case refuse(String)
    }

    /// The folder `environment` names; under tests, a refusal for the user's own folders (the
    /// default one or a real install's, through a symlink or in another case too).
    public static func resolve(_ environment: [String: String], underTests: Bool) -> Resolution {
        let folder = url(environment)
        guard underTests, isReal(folder) else { return .folder(folder) }
        return .refuse("AGENTBOARD_HOME must point to a temporary folder under tests, not \(folder.path)")
    }

    static func url(_ environment: [String: String]) -> URL { override(environment) ?? standard }

    private static func override(_ environment: [String: String]) -> URL? {
        guard let path = environment["AGENTBOARD_HOME"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The user's folders: this build's default and the dev build's.
    private static var realFolders: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["AgentBoard", "AgentBoard Dev"].map { support.appendingPathComponent($0, isDirectory: true) }
    }

    // The volume is case-insensitive: compare resolved paths without case.
    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }

    static func isReal(_ folder: URL) -> Bool { realFolders.map(key).contains(key(folder)) }

    private static var runsUnderTests: Bool {
        let name = ProcessInfo.processInfo.processName
        return ProcessInfo.processInfo.environment["AGENTBOARD_TEST"] == "1" || name.hasSuffix("xctest") || name.contains("swiftpm-testing-helper") || NSClassFromString("XCTestCase") != nil
    }

    private static var standard: URL { realFolders[0] }

    /// Whether this instance runs with data of its own (a build under test, a harness): it must
    /// then leave the user's shared state, like the login keychain, alone.
    public static func isIsolated(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !isReal(url(environment))
    }
}
