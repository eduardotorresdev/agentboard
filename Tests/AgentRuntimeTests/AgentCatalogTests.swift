import Foundation
import Testing
import AgentRuntime

struct AgentCatalogTests {
    @Test func catalogOffersCodexWithAnInstallCommand() throws {
        let codex = try #require(AgentCatalog.provider(id: "codex"))
        #expect(codex.executable == "codex")
        #expect(codex.installCommand == "npm install -g @openai/codex")
        #expect(AgentCatalog.all.map(\.id) == ["claude", "codex"])
    }

    @Test func locateSearchesPathThenFallbacks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("fake-agent")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(AgentCatalog.locate("fake-agent", in: "/usr/bin:/bin", fallbacks: []) == nil)
        #expect(AgentCatalog.locate("fake-agent", in: "/usr/bin:/bin", fallbacks: [folder.path]) == tool.path)
        #expect(AgentCatalog.locate("fake-agent", in: folder.path, fallbacks: []) == tool.path)
        #expect(AgentCatalog.locate("sh", in: "/bin", fallbacks: [folder.path]) == "/bin/sh")
    }

    @Test func codexGetsTheBoardPerLaunch() throws {
        let link = ToolServerLink(name: "board", url: URL(string: "http://127.0.0.1:9/mcp")!, token: "secret")
        let arguments = Codex().arguments(session: UUID(), tools: link)
        #expect(arguments.first == "--dangerously-bypass-approvals-and-sandbox")
        #expect(arguments.contains(#"mcp_servers.board.url="http://127.0.0.1:9/mcp""#))
        #expect(arguments.contains(#"mcp_servers.board.http_headers={Authorization="Bearer secret"}"#))
        #expect(arguments.contains { $0.hasPrefix("notify=[\"sh\",\"-c\",") && $0.contains("/mcp/attention") })
        // A conversation Codex never saved starts fresh.
        #expect(!arguments.contains("resume"))
        #expect(Codex().arguments(session: UUID(), tools: nil) == ["--dangerously-bypass-approvals-and-sandbox"])
    }
}
