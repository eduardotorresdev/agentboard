import Foundation
import Security

/// The Claude plan's rate limits: how much of the 5-hour session and of the week is used, and
/// when each resets. Read with the OAuth token Claude Code keeps in the keychain.
struct ClaudeUsage: Equatable {
    struct Window: Equatable {
        /// Percent used, 0 to 100.
        var used: Double
        var resetsAt: Date?
        var remaining: Double { max(0, 100 - used) }
    }

    /// Nil when no session is open: the next message starts one with the whole window.
    var session: Window?
    var week: Window?
}

enum ClaudeUsageClient {
    private static let service = "Claude Code-credentials"

    static func fetch() async throws -> ClaudeUsage {
        guard let token = token() else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return ClaudeUsage(session: window(body["five_hour"]), week: window(body["seven_day"]))
    }

    private static func window(_ value: Any?) -> ClaudeUsage.Window? {
        guard let value = value as? [String: Any], let used = value["utilization"] as? Double else { return nil }
        return ClaudeUsage.Window(used: used, resetsAt: (value["resets_at"] as? String).flatMap(parseDate))
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// The freshest unexpired token among Claude Code's credential entries (one per config folder).
    private static func token() -> String? {
        let now = Date().timeIntervalSince1970 * 1000
        return accounts()
            .compactMap(credentials)
            .filter { $0.expiresAt > now }
            .max { $0.expiresAt < $1.expiresAt }?
            .token
    }

    /// Names of the keychain entries Claude Code wrote; reading attributes alone never prompts.
    private static func accounts() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else {
            return [service]
        }
        let services = items.compactMap { $0[kSecAttrService as String] as? String }.filter { $0.hasPrefix(service) }
        return Array(Set(services))
    }

    /// Read through `security`, the tool Claude Code stores them with, so the keychain doesn't ask.
    private static func credentials(service: String) -> (token: String, expiresAt: Double)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return nil }
        return (token, oauth["expiresAt"] as? Double ?? .greatestFiniteMagnitude)
    }
}
