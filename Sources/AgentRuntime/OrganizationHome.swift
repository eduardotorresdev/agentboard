import CryptoKit
import Foundation

/// Where an organization's agents keep their Claude Code login. Each organization other than the
/// default one gets its own config folder (`CLAUDE_CONFIG_DIR`), so `/login` in one of its agents
/// signs in that organization only. Everything else in `~/.claude` (skills, commands, agents,
/// settings, transcripts…) is linked in, so it stays shared. The default organization uses
/// `~/.claude` itself.
public enum OrganizationHome {
    /// The organization every install starts with, and the one cards made before organizations
    /// belong to.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// What stays per organization: the login.
    private static let ownEntries: Set<String> = [".credentials.json", ".claude.json"]

    private static var userClaude: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The organization's own folder in the data folder (its icon lives there too).
    public static func folder(_ id: UUID) -> URL {
        DataFolder.url.appendingPathComponent("organizations", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// The `CLAUDE_CONFIG_DIR` of the organization's agents, nil for the default one.
    public static func claudeDirectory(_ id: UUID?) -> URL? {
        guard let id, id != defaultID else { return nil }
        return folder(id).appendingPathComponent("claude", isDirectory: true)
    }

    /// Creates the organization's config folder the first time, signed in as `~/.claude` is, and
    /// links in whatever `~/.claude` gained since. Returns the folder, nil for the default one.
    @discardableResult
    public static func prepare(_ id: UUID?) -> URL? {
        guard let directory = claudeDirectory(id) else { return nil }
        let files = FileManager.default
        let isNew = !files.fileExists(atPath: directory.path)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        linkShared(into: directory)
        if isNew { inheritLogin(into: directory) }
        return directory
    }

    /// Links each entry of `~/.claude` that isn't the login, leaving alone what the folder
    /// already has (its own files win).
    private static func linkShared(into directory: URL) {
        let files = FileManager.default
        let entries = (try? files.contentsOfDirectory(atPath: userClaude.path)) ?? []
        for name in entries where !ownEntries.contains(name) {
            let link = directory.appendingPathComponent(name)
            // `fileExists` follows links, so a dangling one is checked separately.
            guard (try? files.attributesOfItem(atPath: link.path)) == nil else { continue }
            try? files.createSymbolicLink(at: link, withDestinationURL: userClaude.appendingPathComponent(name))
        }
    }

    /// Copies the user's Claude Code login into a new organization: the account file, the
    /// credentials file when there is one, and on macOS the keychain item Claude Code reads for
    /// a custom config folder. Anything that fails just leaves the organization signed out:
    /// `/login` in one of its agents fixes it.
    private static func inheritLogin(into directory: URL) {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let account = home.appendingPathComponent(".claude.json")
        try? files.copyItem(at: account, to: directory.appendingPathComponent(".claude.json"))
        try? files.copyItem(at: userClaude.appendingPathComponent(".credentials.json"),
                            to: directory.appendingPathComponent(".credentials.json"))
        inheritKeychainLogin(into: directory, credentials: credentials())
    }

    /// Copies the default login's keychain item to the one Claude Code reads for `directory`.
    static func inheritKeychainLogin(into directory: URL, credentials: any CredentialStore) {
        guard let secret = credentials.secret(service: keychainService(nil)) else { return }
        credentials.save(secret, service: keychainService(directory), account: NSUserName())
    }

    /// The login keychain, except for an isolated instance, which gets one of its own in memory:
    /// a harness adding organizations must never write the user's keychain.
    static func credentials(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> any CredentialStore {
        DataFolder.isIsolated(environment) ? isolatedCredentials : KeychainCredentials()
    }

    private static let isolatedCredentials = InMemoryCredentials()

    /// The keychain item Claude Code keeps an organization's login in.
    public static func keychainService(organization id: UUID?) -> String {
        keychainService(claudeDirectory(id))
    }

    /// The keychain item Claude Code keeps its login in: a suffix of the config folder's hash
    /// tells custom folders apart.
    private static func keychainService(_ directory: URL?) -> String {
        guard let directory else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }

    fileprivate static func security(_ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }
}

/// Where logins' secrets are kept, by keychain service name.
protocol CredentialStore: Sendable {
    func secret(service: String) -> String?
    func save(_ secret: String, service: String, account: String)
}

/// The user's login keychain, through `security`, the tool Claude Code stores logins with.
struct KeychainCredentials: CredentialStore {
    func secret(service: String) -> String? {
        OrganizationHome.security(["find-generic-password", "-s", service, "-w"])
    }

    func save(_ secret: String, service: String, account: String) {
        _ = OrganizationHome.security(["add-generic-password", "-U", "-a", account, "-s", service, "-w", secret])
    }
}

/// Secrets kept in memory, for isolated instances and tests.
final class InMemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    init(_ secrets: [String: String] = [:]) { self.secrets = secrets }

    var services: [String] { lock.withLock { Array(secrets.keys) } }

    func secret(service: String) -> String? { lock.withLock { secrets[service] } }

    func save(_ secret: String, service: String, account: String) { lock.withLock { secrets[service] = secret } }
}
