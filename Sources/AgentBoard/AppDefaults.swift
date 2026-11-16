import AgentRuntime
import CryptoKit
import Foundation

/// The board's preferences. An instance with data of its own (`AGENTBOARD_HOME`: a build under
/// test, a harness) keeps them in a suite named after that folder, never in the user's.
enum AppDefaults {
    static let shared: UserDefaults = {
        guard DataFolder.isIsolated() else { return .standard }
        let digest = SHA256.hash(data: Data(DataFolder.url.standardizedFileURL.path.utf8))
        let suite = "AgentBoard.home." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return UserDefaults(suiteName: suite) ?? .standard
    }()
}
