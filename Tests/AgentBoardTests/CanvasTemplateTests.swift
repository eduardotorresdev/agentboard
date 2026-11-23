import Connections
import CoreGraphics
import Foundation
import Testing
@testable import AgentBoard

struct CanvasTemplateTests {
    @Test func runnerFoldersFollowTheWorktree() {
        #expect(CanvasTemplate.relative("/p/a", to: "/p/a") == "")
        #expect(CanvasTemplate.relative("/p/a/web", to: "/p/a") == "web")
        // A sibling whose name only starts the same isn't inside.
        #expect(CanvasTemplate.relative("/p/ab", to: "/p/a") == "/p/ab")
        #expect(CanvasTemplate.resolve("", in: "/p/b") == "/p/b")
        #expect(CanvasTemplate.resolve("web", in: "/p/b") == "/p/b/web")
        #expect(CanvasTemplate.resolve("/p/ab", in: "/p/b") == "/p/ab")
    }

    @Test func linesKeepOnlyTheCardsOfTheTemplate() {
        let a = UUID(), b = UUID(), image = UUID()
        let lines = CanvasTemplate.lines([Connection(a: b, b: a, aSide: .left, bSide: nil), Connection(a: a, b: image)], among: [a, b])
        #expect(lines == [CanvasTemplate.Line(a: 1, b: 0, aSide: .left, bSide: nil)])
    }

    @Test func thumbnailFitsAndCenters() {
        let cards = [CGRect(x: -100, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
            .map { CanvasTemplate.Card(kind: .agent, name: "A", frame: $0) }
        let frames = CanvasTemplate(cards: cards, lines: []).thumbnail(in: CGSize(width: 170, height: 100), inset: 10)
        #expect(frames == [CGRect(x: 10, y: 25, width: 50, height: 50), CGRect(x: 110, y: 25, width: 50, height: 50)])
    }

    @Test func templatesAreKeptPerProject() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try Database(url: url)
        let card = CanvasTemplate.Card(kind: .runner, name: "Dev", frame: CGRect(x: 1, y: 2, width: 3, height: 4), command: "npm run dev", directory: "web")
        let first = CanvasTemplate(cards: [card], lines: [])
        let second = CanvasTemplate(cards: [card, card], lines: [CanvasTemplate.Line(a: 0, b: 1)])
        try database.saveTemplate(first, project: "/p")
        try database.saveTemplate(second, project: "/p")
        try database.saveTemplate(first.with(id: UUID()), project: "/other")
        #expect(try database.templates(project: "/p") == [second, first])
        // Renaming keeps its place in the list.
        var renamed = first
        renamed.name = "Web"
        try database.saveTemplate(renamed, project: "/p")
        #expect(try database.templates(project: "/p") == [second, renamed])
        try database.deleteTemplate(id: second.id)
        #expect(try database.templates(project: "/p") == [renamed])
        #expect(try database.templates(project: "/other").count == 1)
    }
}

private extension CanvasTemplate {
    func with(id: UUID) -> CanvasTemplate {
        var copy = self
        copy.id = id
        return copy
    }
}
