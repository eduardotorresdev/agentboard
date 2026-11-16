import Foundation
import Testing
@testable import AgentBoard

/// The account server, answered in this process: each test registers what its own server (a
/// host name of its own) replies, so tests running side by side don't meet.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Call: Equatable {
        var method: String
        var path: String
        var authorization: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (Call) -> (Int, String)] = [:]
    nonisolated(unsafe) private static var seen: [String: [Call]] = [:]

    /// A server of its own, a session that reaches it, and the calls made to it so far.
    static func make(_ handler: @escaping (Call) -> (Int, String)) -> (server: URL, session: URLSession, calls: () -> [Call]) {
        let host = "account-\(UUID().uuidString.lowercased()).test"
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return (URL(string: "https://\(host)")!, URLSession(configuration: configuration), { lock.withLock { seen[host] ?? [] } })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!, host = url.host ?? ""
        let call = Call(method: request.httpMethod ?? "GET", path: url.path, authorization: request.value(forHTTPHeaderField: "Authorization"))
        let handler = Self.lock.withLock { () -> ((Call) -> (Int, String))? in
            Self.seen[host, default: []].append(call)
            return Self.handlers[host]
        }
        let (status, body) = handler?(call) ?? (404, "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Counts up under a lock: which answer a stubbed call is at.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

func accountFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("abaccount-\(UUID().uuidString)/account.json")
}

private func waitUntil(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
}

let hostsJSON = """
    [{"id":"0b6f0d6e-5f0a-4a55-9a37-0d5b8f1c2e11","name":"builder","platform":"linux","version":"0.1.0",
      "public_key":"\(String(repeating: "A", count: 43))=","online":true,"last_seen":1790000000},
     {"id":"7c1d2e3f-0a1b-4c2d-8e3f-4a5b6c7d8e9f","name":"laptop","platform":"linux","version":"0.1.0",
      "public_key":"\(String(repeating: "A", count: 43))=","online":false,"last_seen":null}]
    """

@MainActor @Test func signingInPollsAsTheServerAsksAndKeepsTheToken() async throws {
    let polls = Counter()
    let stub = StubServer.make { call in
        switch call.path {
        case "/v1/login/device":
            return (200, #"{"device_code":"dev","user_code":"WDJB-MJHT","verification_uri":"https://example.test/device","interval":1,"expires_in":900}"#)
        case "/v1/login/poll":
            switch polls.next() {
            case 1, 3: return (200, #"{"status":"pending"}"#)
            case 2: return (200, #"{"status":"slow_down"}"#)
            default: return (200, #"{"token":"secret","account":{"id":7,"login":"octo","name":"Octo Cat","avatar_url":null}}"#)
            }
        case "/v1/hosts": return (200, hostsJSON)
        default: return (404, "{}")
        }
    }
    let file = accountFile(), vault = TokenVault.memory()
    let store = AccountStore(server: stub.server, session: stub.session, file: file, vault: vault)
    var waits: [Double] = []
    var codes: [String?] = []
    store.pause = { @MainActor interval in
        waits.append(interval)
        codes.append(store.login?.userCode)
    }
    store.signIn()
    #expect(store.isSigningIn)
    try await waitUntil { store.account != nil }

    #expect(store.account == Account(login: "octo", name: "Octo Cat", avatarURL: nil))
    #expect(!store.isSigningIn && store.login == nil && store.error == nil)
    // The code showed while waiting; slow_down adds five seconds from then on.
    #expect(codes == ["WDJB-MJHT", "WDJB-MJHT", "WDJB-MJHT", "WDJB-MJHT"])
    #expect(waits == [1, 1, 6, 6])
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

    // The hosts come with the account, asked for with its token.
    try await waitUntil { store.hosts.count == 2 }
    #expect(store.hosts.map(\.name) == ["builder", "laptop"])
    #expect(store.hosts.map(\.online) == [true, false])
    #expect(store.hosts.map(\.lastSeen) == [1_790_000_000, nil])
    #expect(stub.calls().last { $0.path == "/v1/hosts" }?.authorization == "Bearer secret")
    #expect(store.channel(to: store.hosts[0].id)?.key.count == 32)
    #expect(store.channel(to: store.hosts[1].id) == nil, "an offline host isn't connected to")

    // The next launch is signed in from the file and the vault; the token is only in the vault.
    #expect(try !String(contentsOf: file, encoding: .utf8).contains("secret"))
    let again = AccountStore(server: stub.server, session: stub.session, file: file, vault: vault)
    #expect(again.account?.login == "octo" && again.token == "secret")
}

@MainActor @Test func aRefusedSignInSaysSoAndSignsNobodyIn() async throws {
    let stub = StubServer.make { call in
        call.path == "/v1/login/device"
            ? (200, #"{"device_code":"dev","user_code":"AAAA-BBBB","verification_uri":"https://example.test/device","interval":0,"expires_in":900}"#)
            : (200, #"{"status":"denied"}"#)
    }
    let file = accountFile()
    let store = AccountStore(server: stub.server, session: stub.session, file: file)
    store.pause = { _ in }
    store.signIn()
    try await waitUntil { store.error != nil }
    #expect(store.error != nil && store.isSigningIn && store.login == nil)
    #expect(store.account == nil && store.token == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    store.cancelSignIn()
    #expect(!store.isSigningIn && store.error == nil)
}

@MainActor @Test func signingOutForgetsTheAccountHereAndOnTheServer() async throws {
    let stub = StubServer.make { call in call.path == "/v1/hosts" ? (200, hostsJSON) : (200, "{}") }
    let file = accountFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"token":"secret","account":{"login":"octo"}}"#.utf8).write(to: file)
    let store = AccountStore(server: stub.server, session: stub.session, file: file)
    var signedOut = 0
    store.onSignOut = { signedOut += 1 }
    try await waitUntil { store.hosts.count == 2 }

    await store.signOut()
    #expect(store.account == nil && store.token == nil && store.hosts.isEmpty)
    #expect(signedOut == 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(stub.calls().contains(StubServer.Call(method: "POST", path: "/v1/logout", authorization: "Bearer secret")))
}

@MainActor @Test func aTokenTheServerNoLongerKnowsSignsOut() async throws {
    let stub = StubServer.make { _ in (401, #"{"error":"unauthorized"}"#) }
    let file = accountFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"token":"stale","account":{"login":"octo"}}"#.utf8).write(to: file)
    let store = AccountStore(server: stub.server, session: stub.session, file: file)
    #expect(store.account != nil)
    try await waitUntil { store.account == nil }
    #expect(store.token == nil && !FileManager.default.fileExists(atPath: file.path))
}
