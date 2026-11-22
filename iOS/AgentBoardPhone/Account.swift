import CryptoKit
import Foundation
import Security

/// The phone's own secrets, in the iOS Keychain (this device only).
enum Keychain {
    static func read(_ name: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "agentboard",
                                    kSecAttrAccount as String: name, kSecReturnData as String: true]
        var found: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess ? found as? Data : nil
    }

    static func write(_ name: String, _ data: Data?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "agentboard",
                                    kSecAttrAccount as String: name]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// A host of the account, as `GET /v1/hosts` lists it.
struct Host: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let platform: String?
    let public_key: String
    let online: Bool
    let addresses: [String]?

    var uuid: UUID? { UUID(uuidString: id) }
}

/// The account server (docs/hosts.md, "Account server").
struct AccountServer {
    static let url = URL(string: ProcessInfo.processInfo.environment["AGENTBOARD_SERVER"]
        ?? "https://agentboard-account.agentboard-account-server.workers.dev")!

    var token: String?

    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let interval: Int
        let expires_in: Int
    }

    enum Poll { case pending, slowDown, token(String), failed(String) }

    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: Self.url.appendingPathComponent(path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ServerError(status: status, code: code ?? "http_\(status)")
        }
        return data
    }

    struct ServerError: Error, LocalizedError {
        let status: Int
        let code: String
        var errorDescription: String? { status == 401 ? "Signed out. Sign in again." : "The account server said \(code)." }
    }

    func startLogin() async throws -> DeviceCode {
        try JSONDecoder().decode(DeviceCode.self, from: await call("POST", "v1/login/device"))
    }

    func poll(_ code: String) async throws -> Poll {
        let object = try JSONSerialization.jsonObject(with: await call("POST", "v1/login/poll", body: ["device_code": code])) as? [String: Any] ?? [:]
        if let token = object["token"] as? String { return .token(token) }
        switch object["status"] as? String {
        case "pending": return .pending
        case "slow_down": return .slowDown
        case let other: return .failed(other ?? "unknown")
        }
    }

    func hosts() async throws -> [Host] {
        try JSONDecoder().decode([Host].self, from: await call("GET", "v1/hosts"))
    }
}

/// Who this phone is: the account token and its own board key, made on first sign-in and
/// kept after signing out (a host trusts boards by this key).
@MainActor @Observable final class Account {
    private(set) var token: String? = Keychain.read("token").map { String(decoding: $0, as: UTF8.self) }
    let boardKey: Curve25519.Signing.PrivateKey = {
        if let raw = Keychain.read("board.key"), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        Keychain.write("board.key", key.rawRepresentation)
        return key
    }()

    var server: AccountServer { AccountServer(token: token) }
    var fingerprint: String { HostChannel.fingerprint(of: boardKey.publicKey.rawRepresentation) }
    var publicKeyBase64: String { boardKey.publicKey.rawRepresentation.base64EncodedString() }

    func signedIn(_ token: String) {
        Keychain.write("token", Data(token.utf8))
        self.token = token
    }

    func signOut() {
        let server = server
        Task { _ = try? await server.call("POST", "v1/logout") }
        Keychain.write("token", nil)
        token = nil
    }
}
