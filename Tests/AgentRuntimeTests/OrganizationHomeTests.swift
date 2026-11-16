import Foundation
import Testing
@testable import AgentRuntime

// Never touches the real keychain: only the in-memory store is called.
struct OrganizationHomeTests {
    @Test func anIsolatedHomeNeverUsesTheLoginKeychain() {
        let isolated = ["AGENTBOARD_HOME": NSTemporaryDirectory() + UUID().uuidString]
        #expect(DataFolder.isIsolated(isolated))
        #expect(OrganizationHome.credentials(isolated) is InMemoryCredentials)
        #expect(!DataFolder.isIsolated([:]))
        #expect(OrganizationHome.credentials([:]) is KeychainCredentials)
    }

    @Test func aNewOrganizationCopiesTheLoginIntoTheGivenStore() {
        let store = InMemoryCredentials(["Claude Code-credentials": "token"])
        let directory = URL(fileURLWithPath: "/tmp/org-test/claude", isDirectory: true)
        OrganizationHome.inheritKeychainLogin(into: directory, credentials: store)
        let copied = store.services.filter { $0 != "Claude Code-credentials" }
        #expect(copied.count == 1)
        #expect(copied.first?.hasPrefix("Claude Code-credentials-") == true)
        #expect(store.secret(service: copied[0]) == "token")
    }

    /// Under tests the user's folders are refused however they are named; temporary ones pass.
    @Test func testsNeverResolveTheUsersFolder() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("abhome-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("ablink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: support.appendingPathComponent("AgentBoard"))
        defer { try? FileManager.default.removeItem(at: link) }
        func refused(_ environment: [String: String]) -> Bool {
            if case .refuse = DataFolder.resolve(environment, underTests: true) { true } else { false }
        }
        #expect(refused([:]))
        #expect(refused(["AGENTBOARD_HOME": support.appendingPathComponent("AgentBoard").path]))
        #expect(refused(["AGENTBOARD_HOME": support.appendingPathComponent("agentboard").path]))
        #expect(refused(["AGENTBOARD_HOME": support.appendingPathComponent("AgentBoard Dev").path]))
        #expect(refused(["AGENTBOARD_HOME": link.path]))
        #expect(!refused(["AGENTBOARD_HOME": temp.path]))
        #expect(DataFolder.resolve([:], underTests: false) == .folder(support.appendingPathComponent("AgentBoard", isDirectory: true)))
    }
}
