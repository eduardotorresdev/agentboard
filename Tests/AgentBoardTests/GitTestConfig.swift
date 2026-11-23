import Foundation
@testable import AgentBoard
import Orchestration

/// Touch before running git in a test: from then on git reads a throwaway global config (just a
/// name and email) and no system config, so the developer's signing, hooks and aliases never
/// apply. Set once, lazily and thread-safely, for the whole test process.
let isolatedGitConfig: Void = {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-gitconfig-\(UUID().uuidString)")
    try? "[user]\n\tname = AgentBoard Tests\n\temail = tests@example.invalid\n".write(to: file, atomically: true, encoding: .utf8)
    // Nothing inherited from the shell running the tests (GIT_DIR, GIT_CONFIG_*, …) applies either.
    var environment = Git.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_GLOBAL"] = file.path
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    Git.environment = environment
}()
