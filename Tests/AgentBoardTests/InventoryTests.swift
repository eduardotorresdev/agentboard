@testable import AgentBoard
import XCTest

final class InventoryTests: XCTestCase {
    func testClaudeServersKeepKeysNotValues() {
        let json = """
        {"mcpServers": {"gh": {"command": "npx", "args": ["-y", "gh-mcp"], "env": {"GITHUB_TOKEN": "tok-123"}},
                        "web": {"type": "http", "url": "https://x.dev/mcp", "headers": {"Authorization": "Bearer s"}}},
         "projects": {"/p": {"mcpServers": {"local": {"command": "run"}}}}}
        """
        let user = Inventory.claudeServers(json: Data(json.utf8), source: "f")
        XCTAssertEqual(user.map(\.name), ["gh", "web"])
        XCTAssertEqual(user[0].target, "npx -y gh-mcp")
        XCTAssertEqual(user[0].secretKeys, ["GITHUB_TOKEN"])
        XCTAssertEqual(user[1].target, "https://x.dev/mcp")
        XCTAssertEqual(user[1].secretKeys, ["Authorization"])
        XCTAssertFalse("\(user)".contains("tok-123"))
        XCTAssertEqual(Inventory.claudeServers(json: Data(json.utf8), project: "/p", source: "f").map(\.name), ["local"])
        XCTAssertTrue(Inventory.claudeServers(json: Data("not json".utf8), source: "f").isEmpty)
    }

    func testCodexServers() {
        let toml = """
        model = "o3"
        [mcp_servers.github]
        command = "npx" # launcher
        args = ["-y", "@gh/mcp"]
        env = { GITHUB_TOKEN = "ghp_x", "OTHER" = "y" }

        [mcp_servers."my.http"]
        url = "https://h.dev/mcp"
        bearer_token_env_var = "H_TOKEN"

        [mcp_servers.github.env]
        EXTRA = "z"

        [profiles.x]
        command = "ignored"
        """
        let servers = Inventory.codexServers(toml: toml, source: "c")
        XCTAssertEqual(servers.map(\.name), ["github", "my.http"])
        XCTAssertEqual(servers[0].target, "npx -y @gh/mcp")
        XCTAssertEqual(servers[0].secretKeys, ["EXTRA", "GITHUB_TOKEN", "OTHER"])
        XCTAssertEqual(servers[1].target, "https://h.dev/mcp")
        XCTAssertEqual(servers[1].secretKeys, ["Authorization"])
        XCTAssertFalse("\(servers)".contains("ghp_x"))
    }

    func testSkillFrontmatter() {
        let skill = Inventory.skill(markdown: "---\nname: review\ndescription: \"Reviews code.\"\n---\nBody", folder: "r", source: "s")
        XCTAssertEqual(skill.name, "review")
        XCTAssertEqual(skill.summary, "Reviews code.")
        XCTAssertEqual(Inventory.skill(markdown: "No frontmatter", folder: "r", source: "s").name, "r")
    }
}
