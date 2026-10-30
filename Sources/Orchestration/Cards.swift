import AgentRuntime
import Foundation

/// A persisted terminal card: an agent, or a runner (a command the board keeps running, such as
/// a dev server). Which worktree it belongs to and where it sits on the canvas.
public struct AgentRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let worktree: String
    /// `AgentProvider.id` of the agent this card runs; `AgentRecord.runnerProviderID` for runners.
    public let providerID: String
    /// How the card is titled and how connected agents address it; unique in its worktree.
    public var name: String
    public var frame: CGRect
    /// What the card runs when it is a runner; nil for agents.
    public var runner: RunnerSpec?
    /// The organization the card was added in; nil for cards made before organizations, which
    /// belong to the default one. Agents run signed in as it (see `OrganizationHome`).
    public var organization: UUID?

    public init(id: UUID, worktree: String, providerID: String, name: String, frame: CGRect, runner: RunnerSpec? = nil,
                organization: UUID? = nil) {
        self.id = id
        self.worktree = worktree
        self.providerID = providerID
        self.name = name
        self.frame = frame
        self.runner = runner
        self.organization = organization
    }

    /// The organization the card belongs to, with older cards in the default one.
    public var organizationID: UUID { organization ?? OrganizationHome.defaultID }

    public var provider: (any AgentProvider)? { AgentCatalog.provider(id: providerID) }

    public static let runnerProviderID = "runner"
    public static let runnerSize = CGSize(width: 600, height: 340)

    /// `base`, or `base 2`, `base 3`… whichever no card in `others` is called.
    public static func uniqueName(_ base: String, among others: [AgentRecord]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// A card name from a command: the script of `npm run dev` (dev), else the program's name.
    public static func runnerName(for command: String) -> String {
        let words = command.split(separator: " ").map(String.init).filter { !$0.contains("=") }
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return "Runner" }
        if ["npm", "pnpm", "yarn", "bun", "deno"].contains(first), words.count > 1 {
            let rest = words.dropFirst().filter { !$0.hasPrefix("-") }
            return (rest.first == "run" ? rest.dropFirst().first : rest.first) ?? first
        }
        return first
    }
}

/// What a runner card runs.
public struct RunnerSpec: Hashable, Codable, Sendable {
    /// A shell command line, run with the user's login shell.
    public var command: String
    /// The folder it runs in: the worktree or a folder inside it.
    public var directory: String
    /// The agent that started it, which may also close it; nil when the developer added it.
    public var owner: UUID?

    public init(command: String, directory: String, owner: UUID?) {
        self.command = command
        self.directory = directory
        self.owner = owner
    }
}

/// A board element that isn't a terminal card (a browser…), as the board tells the core about
/// it: lines reach it, and agents see it in `list_peers`.
public struct ElementInfo: Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    /// `ElementKind.rawValue`.
    public var kind: String
    public var detail: String?
    public var worktree: String
    public var frame: CGRect

    public init(id: UUID, name: String, kind: String, detail: String?, worktree: String, frame: CGRect) {
        self.id = id
        self.name = name
        self.kind = kind
        self.detail = detail
        self.worktree = worktree
        self.frame = frame
    }
}
