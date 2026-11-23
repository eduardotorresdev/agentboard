import AgentRuntime
import Foundation
@testable import Orchestration
import Testing

/// git reads a throwaway config here, never the developer's (signing, hooks, aliases).
private let isolatedGit: Void = {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("abmaker-gitconfig-\(UUID().uuidString)")
    try? "[user]\n\tname = Tests\n\temail = tests@example.invalid\n[commit]\n\tgpgsign = false\n".write(to: file, atomically: true, encoding: .utf8)
    var environment = Git.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_GLOBAL"] = file.path
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    Git.environment = environment
}()

private func scratch() throws -> URL {
    _ = isolatedGit
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abmaker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.resolvingSymlinksInPath()
}

/// The cases both cores check (`core/fixtures/projects/checks.json`): refused with the same
/// reason as the Rust core, or taken.
@Test func theSharedProjectChecksAreTakenOrRefusedAlike() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../core/fixtures/projects/checks.json"))
    let checks = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    for (list, check) in [("names", ProjectChecks.name), ("cloneURLs", ProjectChecks.cloneURL)] as [(String, (String) -> String?)] {
        for case let item as [String: String] in try #require(checks[list] as? [Any]) {
            let value = try #require(item["value"])
            #expect(check(value) == item["refused"], "\(list): \(value.debugDescription)")
        }
    }
    for case let item as [String: String] in try #require(checks["repositoryNames"] as? [Any]) {
        #expect(ProjectChecks.repositoryName(item["url"]!) == item["name"])
    }
}

@Test func pathsStayInsideTheProjectsFolder() throws {
    let root = try scratch()
    let projects = root.appendingPathComponent("projects")
    try FileManager.default.createDirectory(at: projects.appendingPathComponent("app"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("outside"))
    #expect(try ProjectChecks.inside(projects, projects.appendingPathComponent("app").path).get().path == projects.appendingPathComponent("app").path)
    #expect(try ProjectChecks.inside(projects, projects.path + "/new/deeper").get().path == projects.path + "/new/deeper")
    for path in [projects.path, root.path + "/outside", projects.path + "/../outside", projects.path + "/app/../../outside",
                 projects.path + "/link", projects.path + "/link/x", "app", "/etc"] {
        #expect(throws: ProjectRefusal.self, "\(path)") { try ProjectChecks.inside(projects, path).get() }
    }
}

@Test func aBoardHasTheCoreMakeProjectsAndWorktrees() async throws {
    let root = try scratch()
    let projects = root.appendingPathComponent("projects")
    let made = try await ProjectMaker.project(in: projects, name: "app", clone: nil).get()
    #expect(made == projects.appendingPathComponent("app").path)
    #expect(FileManager.default.fileExists(atPath: made + "/.git"))
    let worktree = try await ProjectMaker.worktree(in: projects, repository: made, branch: "fix/login").get()
    #expect(worktree == projects.appendingPathComponent("app-worktrees/fix-login").path)

    // The same refusals as the Rust core, and nothing made outside the folder.
    #expect(await ProjectMaker.project(in: projects, name: "..", clone: nil).failure == ProjectRefusal(ProjectChecks.name("..")!))
    #expect(await ProjectMaker.project(in: projects, name: nil, clone: "file:///etc").failure?.message.contains("https or ssh") == true)
    #expect(await ProjectMaker.project(in: projects, name: "app", clone: nil).failure?.message.contains("already exists") == true)
    #expect(await ProjectMaker.worktree(in: projects, repository: root.path, branch: "x").failure?.message.contains("isn't inside the projects folder") == true)
    #expect(await ProjectMaker.worktree(in: projects, repository: made, branch: "a..b").failure?.message.contains("valid branch") == true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    // A clone that fails leaves no folder.
    #expect(await ProjectMaker.project(in: projects, name: "gone", clone: "https://127.0.0.1:1/x.git").failure != nil)
    #expect(!FileManager.default.fileExists(atPath: projects.appendingPathComponent("gone").path))
}

/// Over the wire: a board (the phone) asks the core, and that board hears the answer.
@Test func theCoreAnswersTheBoardThatAsked() async throws {
    let root = try scratch()
    let core = try await MainActor.run { try Core() }
    await MainActor.run { core.orchestrator.projectsFolder = root.appendingPathComponent("projects") }
    let client = try await board(core)
    let inbox = Inbox()
    client.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
    func answer(_ request: UUID) -> (path: String?, error: String?)? {
        inbox.events.lazy.compactMap { event -> (path: String?, error: String?)? in
            if case .created(request, let path, let error) = event { (path, error) } else { nil }
        }.first
    }
    let request = UUID()
    client.send(.createProject(request: request, name: "shop", clone: nil))
    try await waitUntil { answer(request) != nil }
    #expect(answer(request)?.path == root.appendingPathComponent("projects/shop").path)
    let refused = UUID()
    client.send(.createWorktree(request: refused, project: "/etc", branch: "x"))
    try await waitUntil { answer(refused) != nil }
    #expect(answer(refused)?.path == nil && answer(refused)?.error?.contains("isn't inside the projects folder") == true)
    client.disconnect()
    await MainActor.run { core.stop() }
}

private extension Result {
    var failure: Failure? { if case .failure(let failure) = self { failure } else { nil } }
}
