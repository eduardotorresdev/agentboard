import AgentRuntime
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
    /// The usage of the account the organization's agents are signed in to.
    static func fetch(organization: UUID) async throws -> ClaudeUsage {
        let service = OrganizationHome.keychainService(organization: organization)
        guard let token = token(service: service) else { throw URLError(.userAuthenticationRequired) }
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

    /// The freshest unexpired token stored under the organization's keychain service. Other
    /// services belong to other organizations' config folders and must not be mixed in.
    private static func token(service: String) -> String? {
        let now = Date().timeIntervalSince1970 * 1000
        return entries(service: service)
            .compactMap(credentials)
            .filter { $0.expiresAt > now }
            .max { $0.expiresAt < $1.expiresAt }?
            .token
    }

    /// The keychain entries Claude Code wrote, by service and account: one service can hold
    /// several accounts (an old login's entry beside the current one), and asking by service
    /// alone answers with whichever comes first. Reading attributes alone never prompts.
    private static func entries(service: String) -> [(service: String, account: String?)] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else {
            return [(service, nil)]
        }
        var seen: Set<String> = []
        return items.compactMap { item -> (service: String, account: String?)? in
            guard let name = item[kSecAttrService as String] as? String, name == service else { return nil }
            let account = item[kSecAttrAccount as String] as? String
            return seen.insert(name + "\u{0}" + (account ?? "")).inserted ? (name, account) : nil
        }
    }

    /// Read through `security`, the tool Claude Code stores them with, so the keychain doesn't ask.
    private static func credentials(_ entry: (service: String, account: String?)) -> (token: String, expiresAt: Double)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", entry.service] + (entry.account.map { ["-a", $0] } ?? []) + ["-w"]
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
