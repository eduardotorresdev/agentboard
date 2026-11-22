import AgentRuntime
import CryptoKit
import Foundation
import Observation
import Security

/// Where the account's token is kept between launches.
struct TokenVault: Sendable {
    let read: @Sendable () -> String?
    /// Keeps the token (nil removes it); false when it couldn't.
    let write: @Sendable (String?) -> Bool
    /// Whether the last `read` found a token it wasn't let read (another build of the app
    /// saved it, and the Keychain wants the user's word).
    var unreadable: @Sendable () -> Bool = { false }

    /// Kept only while the process lives: tests, and a token given by `AGENTBOARD_ACCOUNT`.
    static func memory(_ token: String? = nil) -> TokenVault {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var token: String?
        }
        let box = Box()
        box.token = token
        return TokenVault(read: { box.lock.withLock { box.token } }, write: { new in box.lock.withLock { box.token = new }; return true })
    }

    /// A generic password of the macOS Keychain under `service`: readable after the first
    /// unlock, never synced or restored to another device, and only by the app that saved it.
    static func keychain(service: String) -> TokenVault {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "token"]
        final class Last: @unchecked Sendable {
            let lock = NSLock()
            var refused = false
        }
        let last = Last()
        return TokenVault(read: {
            var found: CFTypeRef?
            // Never a dialog at launch: a token that needs one counts as unreadable, and the app says so.
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }
            let query = item.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            last.lock.withLock { last.refused = status != errSecSuccess && status != errSecItemNotFound }
            guard status == errSecSuccess, let data = found as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }, write: { token in
            let removed = SecItemDelete(item as CFDictionary)
            guard let token else { return removed == errSecSuccess || removed == errSecItemNotFound }
            let new = item.merging([kSecValueData: Data(token.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
            return SecItemAdd(new as CFDictionary, nil) == errSecSuccess
        }, unreadable: { last.lock.withLock { last.refused } })
    }

    /// A file only its owner reads.
    static func file(_ url: URL) -> TokenVault {
        TokenVault(read: { (try? String(contentsOf: url, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 } }, write: { token in
            try? FileManager.default.removeItem(at: url)
            guard let token else { return true }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        })
    }

    /// Where this data folder's token goes: its own Keychain item (an installed app and a build
    /// of the checkout, or any `AGENTBOARD_HOME`, each have theirs) when the app is signed with
    /// an identity. A build signed with none (what `./run` and `./install` make today) is another
    /// program to the Keychain after every rebuild, and could never read what the last one
    /// saved: its token stays in `account.token` of the data folder.
    // shortcut: unsigned builds keep the token in a file, until `install` and `./run` sign with a stable identity; nothing here changes then.
    static var standard: TokenVault { standard("account", file: "account.token") }

    /// The same place, for this Mac's own key (see "Board identity" in docs/hosts.md).
    static var standardBoardKey: TokenVault { standard("board key", file: "board.key") }

    /// And for the key of the account's vault (see "The vault" in docs/hosts.md).
    static var standardVaultKey: TokenVault { standard("vault key", file: "vault.key") }

    private static func standard(_ what: String, file name: String) -> TokenVault {
        isSignedWithAnIdentity ? keychain(service: "AgentBoard \(what) (\(DataFolder.url.path))") : file(DataFolder.url.appendingPathComponent(name))
    }

    /// Whether this program's signature names who made it (not ad hoc, not missing).
    static var isSignedWithAnIdentity: Bool {
        var running: SecCode?, onDisk: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &onDisk) == errSecSuccess, let onDisk,
              SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let flags = (information as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue == 0
    }
}

/// Who is signed in, as the account server knows them (see docs/hosts.md).
struct Account: Codable, Equatable {
    var login: String
    var name: String?
    var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
    }
}

/// A machine signed in to the account that runs agents.
struct Host: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var platform: String
    var version: String
    /// Its identity key (Ed25519, base64): what a channel to it is checked against.
    var publicKey: String
    var online: Bool
    /// Unix seconds; nil until it first came online.
    var lastSeen: Double?
    /// Where a board may reach it directly, as "address:port"; a server that doesn't say has none.
    var directAddresses: [String]?
    var addresses: [String] { directAddresses ?? [] }

    enum CodingKeys: String, CodingKey {
        case id, name, platform, version, online
        case directAddresses = "addresses"
        case publicKey = "public_key"
        case lastSeen = "last_seen"
    }
}

/// The account this Mac is signed in to and its hosts. Signing in is GitHub's device flow, run
/// by the account server: a code shown here, confirmed on any device.
@MainActor
@Observable
final class AccountStore {
    /// The code to confirm, while signing in.
    struct Login: Equatable {
        var userCode: String
        var verificationURL: URL
    }

    private(set) var account: Account?
    private(set) var hosts: [Host] = []
    /// Signing in is under way, or stopped with `error`: until it succeeds or `cancelSignIn`.
    private(set) var isSigningIn = false
    private(set) var login: Login?
    /// Why signing in stopped, until the next try.
    private(set) var error: String?
    @ObservationIgnored private(set) var token: String?
    /// Called after the account is gone from here, signed out or refused by the server.
    @ObservationIgnored var onSignOut: (() -> Void)?
    /// Called after the hosts, or what they are held to, changed.
    @ObservationIgnored var onHosts: (() -> Void)?
    /// Waits between polls of a login; replaced in tests.
    @ObservationIgnored var pause: (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }

    @ObservationIgnored let server: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let vault: TokenVault
    @ObservationIgnored private let boardVault: TokenVault
    @ObservationIgnored private let database: Database?
    /// This Mac's own key, which hosts decide by: made at the first sign-in, kept like the
    /// token, never sent anywhere. Signing out keeps it: hosts that trust this Mac still do.
    private(set) var boardKey: Curve25519.Signing.PrivateKey?
    /// What this computer calls itself to a host.
    @ObservationIgnored var boardName = Foundation.Host.current().localizedName ?? "Mac"

    /// This Mac as a host sees it.
    var board: HostChannel.Board? { boardKey.map { HostChannel.Board(key: $0, name: boardName) } }
    /// This Mac's public key, base64: what `agentboard trust` takes on a host.
    var boardPublicKey: String? { boardKey?.publicKey.rawRepresentation.base64EncodedString() }

    private func loadBoardKey() {
        guard boardKey == nil else { return }
        if let kept = boardVault.read().flatMap({ Data(base64Encoded: $0) }).flatMap({ try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }) {
            return boardKey = kept
        }
        // One it wasn't let read is not replaced: hosts trust that one.
        guard !boardVault.unreadable() else { return }
        let made = Curve25519.Signing.PrivateKey()
        // A vault that refuses leaves the key for this launch only.
        _ = boardVault.write(made.rawRepresentation.base64EncodedString())
        boardKey = made
    }
    /// What each host is held to: the identity key it had when this Mac first saw it (or that
    /// the user accepted since), and whether the user allowed syncing to the host with that key.
    private(set) var pins: [UUID: Pin] = [:]

    struct Pin: Equatable {
        var key: String
        var syncAllowed = false
        /// The host, with that key, let this Mac in at least once.
        var trustedHere = false
    }
    @ObservationIgnored private var signingIn: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    /// The deployed account server.
    static let deployedServer = URL(string: "https://agentboard.eduardotorres.dev")!
    static let serverKey = "accountServer"

    /// `AGENTBOARD_SERVER`, else the `accountServer` preference, else the deployed server.
    static var defaultServer: URL {
        let named = ProcessInfo.processInfo.environment["AGENTBOARD_SERVER"] ?? AppDefaults.shared.string(forKey: serverKey)
        return named.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? deployedServer
    }

    /// `file`: who is signed in (`account.json` in the data folder by default). `vault`: where
    /// the token is kept (the Keychain by default; memory when a `file` is given, as tests do).
    /// `database`: where the hosts' pinned keys are kept; without one they last this launch.
    /// For a build under test, `AGENTBOARD_ACCOUNT=<file>` (JSON with `token` and `account`)
    /// signs in from that file, which is only read, and keeps the token in memory; this Mac's
    /// key is then `board.key` beside that file. `boardVault`: where the key is kept otherwise
    /// (as the token; memory when a `file` is given).
    init(server: URL? = nil, session: URLSession = .shared, file: URL? = nil, vault: TokenVault? = nil, boardVault: TokenVault? = nil,
         database: Database? = nil) {
        self.server = server ?? Self.defaultServer
        self.session = session
        self.file = file ?? DataFolder.url.appendingPathComponent("account.json")
        self.database = database
        pins = ((try? database?.hostPins()) ?? [:]).mapValues { Pin(key: $0.key, syncAllowed: $0.syncAllowed, trustedHere: $0.trustedHere) }
        let read = { (url: URL) in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
        if file == nil, vault == nil, let given = ProcessInfo.processInfo.environment["AGENTBOARD_ACCOUNT"].flatMap({ read(URL(fileURLWithPath: $0)) }) {
            self.vault = .memory(given.token)
            self.boardVault = .file(URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTBOARD_ACCOUNT"] ?? "").deletingLastPathComponent().appendingPathComponent("board.key"))
            account = given.account
        } else {
            self.vault = vault ?? (file == nil ? .standard : .memory())
            self.boardVault = boardVault ?? (file == nil ? .standardBoardKey : .memory())
            let saved = read(self.file)
            // A file from before the token moved to the vault: moved once, then gone from the file.
            vaultAllowed = saved?.vault == true
            if let old = saved?.token, let account = saved?.account, self.vault.write(old) { save(account) }
            account = saved?.account
        }
        token = account == nil ? nil : self.vault.read()
        if token != nil {
            loadBoardKey()
            keepHostsFresh()
            return
        }
        if account != nil, self.vault.unreadable() {
            // Said where signing in shows, with a way to sign in again: not a silent sign-out.
            error = L("Couldn't read the saved sign-in from the Keychain. Sign in again.")
            isSigningIn = true
        }
        account = nil
    }

    private struct Saved: Codable {
        var token: String?
        var account: Account
        var vault: Bool?
    }

    /// Whether the user said yes, for this account, to keeping skills, servers and the GitHub
    /// login in its vault (asked once: see `HostStores.vaultQuestion`).
    var vaultAllowed = false {
        didSet { if vaultAllowed != oldValue, let account { save(account) } }
    }

    private func save(_ account: Account) {
        guard let data = try? JSONEncoder().encode(Saved(token: nil, account: account, vault: vaultAllowed ? true : nil)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    // MARK: Signing in

    /// Starts the device flow: `login` holds the code until the user confirmed it on the
    /// sign-in page, it expired, or `cancelSignIn`.
    func signIn() {
        guard account == nil else { return }
        signingIn?.cancel()
        isSigningIn = true
        login = nil
        error = nil
        signingIn = Task {
            do {
                let device: Device = try await call("POST", "v1/login/device")
                guard let url = URL(string: device.verificationURI) else { throw URLError(.badServerResponse) }
                login = Login(userCode: device.userCode, verificationURL: url)
                var interval = device.interval ?? 5
                let expires = Date().addingTimeInterval(device.expiresIn ?? 900)
                while !Task.isCancelled {
                    await pause(interval)
                    guard !Task.isCancelled else { return }
                    guard Date() < expires else { throw LoginFailure.expired }
                    let poll: Poll = try await call("POST", "v1/login/poll", body: ["device_code": device.deviceCode])
                    if let token = poll.token, let account = poll.account {
                        return signedIn(token: token, account: account)
                    }
                    switch poll.status {
                    case "pending": break
                    // The server asks for more time between polls from here on.
                    case "slow_down": interval += 5
                    case "denied": throw LoginFailure.denied
                    default: throw LoginFailure.expired
                    }
                }
            } catch {
                // Cancelled: whoever cancelled already set what shows.
                guard !Task.isCancelled else { return }
                login = nil
                switch error as? LoginFailure {
                case .denied: self.error = L("The sign-in was refused on the sign-in page.")
                case .expired: self.error = L("The code expired before it was confirmed. Try again.")
                case nil: self.error = L("Couldn't reach the account server: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelSignIn() {
        signingIn?.cancel()
        isSigningIn = false
        login = nil
        error = nil
    }

    private enum LoginFailure: Error { case expired, denied }

    private struct Device: Decodable {
        var deviceCode: String
        var userCode: String
        var verificationURI: String
        var interval: Double?
        var expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case interval
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
        }
    }

    private struct Poll: Decodable {
        var status: String?
        var token: String?
        var account: Account?
    }

    private func signedIn(token: String, account: Account) {
        self.token = token
        self.account = account
        isSigningIn = false
        login = nil
        // A vault that refuses keeps the account for this launch only.
        if vault.write(token) { save(account) }
        loadBoardKey()
        keepHostsFresh()
    }

    /// Forgets the account here and tells the server to forget the token.
    func signOut() async {
        guard let token else { return }
        forget()
        let _: Empty? = try? await call("POST", "v1/logout", token: token)
    }

    /// Has the server forget every board signed in to the account, this one included (hosts
    /// stay signed in), then forgets the account here. False, and still signed in, when the
    /// server didn't do it.
    func signOutEverywhere() async -> Bool {
        guard let token else { return false }
        guard let _: Empty = try? await call("POST", "v1/logout/boards", token: token) else { return false }
        if self.token == token { forget() }
        return true
    }

    private func forget() {
        refreshing?.cancel()
        refreshing = nil
        token = nil
        account = nil
        vaultAllowed = false
        hosts = []
        _ = vault.write(nil)
        try? FileManager.default.removeItem(at: file)
        onSignOut?()
    }

    // MARK: Hosts

    /// Asks the server for the account's hosts now; they are asked for again every 15 seconds.
    func refreshHosts() async {
        guard let token else { return }
        do {
            // This Mac as a host of the account is this board's own core, not another host.
            let itself = MacHost.hostID
            let listed: [Host] = try await call("GET", "v1/hosts", token: token)
            let fresh = listed.filter { $0.id != itself }
            // Signed out, or in again as someone else, while the answer was on its way.
            guard self.token == token else { return }
            if hosts != fresh { hosts = fresh }
            // Trust on first use: a host is held to the key it had when first seen here.
            for host in fresh where pins[host.id] == nil { pin(host.id, to: Pin(key: host.publicKey)) }
            onHosts?()
        } catch Failure.status(401) {
            // The server no longer knows the token: signed out from elsewhere.
            if self.token == token { forget() }
        } catch {}
    }

    private func keepHostsFresh() {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refreshHosts()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Where a host may be reached directly: what it registered (another in tests).
    @ObservationIgnored var directAddresses: (Host) -> [String] = { $0.addresses }

    /// A key (base64) as people compare it, the same way the host prints its own and each
    /// board's: see `HostChannel.fingerprint`.
    nonisolated static func fingerprint(of key: String) -> String {
        HostChannel.fingerprint(of: Data(base64Encoded: key) ?? Data())
    }

    /// What a channel to `host` needs, checked against its pinned key; nil when signed out, the
    /// host is unknown or offline, or the server now gives another key for it (`identityChanged`).
    func channel(to host: UUID) -> (server: URL, token: String, key: Data, addresses: [String], board: HostChannel.Board)? {
        guard let token, let board, let known = hosts.first(where: { $0.id == host }), known.online,
              let pin = pins[host], pin.key == known.publicKey, let key = Data(base64Encoded: pin.key) else { return nil }
        return (server, token, key, directAddresses(known), board)
    }

    /// Whether `host`, as it is pinned, ever let this Mac in.
    func wasTrusted(by host: UUID) -> Bool { pins[host]?.trustedHere == true && !identityChanged(host) }

    func noteTrusted(by host: UUID) {
        guard var pin = pins[host], !pin.trustedHere, !identityChanged(host) else { return }
        pin.trustedHere = true
        self.pin(host, to: pin)
    }

    /// The server gives `host` a key other than the pinned one: a reinstalled host, or someone
    /// in its place. Nothing connects to it until `acceptIdentity`.
    func identityChanged(_ host: UUID) -> Bool {
        guard let known = hosts.first(where: { $0.id == host }), let pin = pins[host] else { return false }
        return pin.key != known.publicKey
    }

    static var identityChangedNote: String {
        L("This host's identity changed. If you reinstalled it, trust the new identity in its dialog, under Compute; otherwise something else is answering in its place.")
    }

    /// Holds `host` to the key the server gives now. What was allowed for the old key isn't
    /// for the new one.
    func acceptIdentity(of host: UUID) {
        guard let known = hosts.first(where: { $0.id == host }) else { return }
        pin(host, to: Pin(key: known.publicKey))
        onHosts?()
    }

    private func pin(_ host: UUID, to pin: Pin?) {
        pins[host] = pin
        try? database?.setHostPin(pin?.key, syncAllowed: pin?.syncAllowed ?? false, trustedHere: pin?.trustedHere ?? false, host: host)
    }

    /// Removes `host` from the account: it must sign in again to come back. Its pinned key and
    /// what was allowed for it go too. False when the server didn't do it.
    func forgetHost(_ host: UUID) async -> Bool {
        guard let token else { return false }
        do {
            let _: Empty = try await call("DELETE", "v1/hosts/\(host.uuidString.lowercased())", token: token)
        } catch Failure.status(404) {
            // Already gone there.
        } catch {
            return false
        }
        hosts.removeAll { $0.id == host }
        pin(host, to: nil)
        return true
    }

    // MARK: Calls

    private enum Failure: Error { case status(Int) }
    private struct Empty: Decodable {}

    private func call<Reply: Decodable>(_ method: String, _ path: String, token: String? = nil, body: [String: String]? = nil) async throws -> Reply {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}
