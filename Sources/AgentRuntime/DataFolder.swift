import Foundation

/// Where the board and the core keep their state: the database, the core's socket and log,
/// the tool server's key. `AGENTBOARD_HOME` points it elsewhere, so a second instance (a build
/// under test) runs with its own data, agents and core.
public enum DataFolder {
    public static var url: URL {
        if let path = ProcessInfo.processInfo.environment["AGENTBOARD_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AgentBoard", isDirectory: true)
    }
}
