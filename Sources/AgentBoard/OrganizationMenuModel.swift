import Foundation
import Orchestration

/// What waits on the user in an organization: its agents waiting for a reply or crashed.
struct OrganizationAttention: Equatable {
    var waiting = 0
    var crashed = 0

    var isEmpty: Bool { waiting == 0 && crashed == 0 }

    /// The dot to show, in the card status language: waiting outranks crashed, as on cards.
    var status: CardStatus? { waiting > 0 ? .waiting : crashed > 0 ? .crashed : nil }

    /// "2 waiting for you", "1 crashed", or both.
    var summary: String? {
        let parts = [waiting > 0 ? L("\(waiting) waiting for you") : nil, crashed > 0 ? L("\(crashed) crashed") : nil]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Per organization, from every agent card (in every organization, shown or not) and the rule
    /// the cards themselves use (`AgentStore.cardStatus`). Runners don't count, the active
    /// organization is left out (its board shows it), and organizations with nothing pending are
    /// absent.
    static func byOrganization(cards: [AgentRecord], status: (AgentRecord) -> CardStatus,
                               active: UUID) -> [UUID: OrganizationAttention] {
        var result: [UUID: OrganizationAttention] = [:]
        for card in cards where card.runner == nil && card.organizationID != active {
            switch status(card) {
            case .waiting: result[card.organizationID, default: .init()].waiting += 1
            case .crashed: result[card.organizationID, default: .init()].crashed += 1
            case .running, .stopped: break
            }
        }
        return result
    }

    /// The bar's dot: the most pressing status among the other organizations.
    static func barStatus(_ all: [UUID: OrganizationAttention]) -> CardStatus? {
        all.values.compactMap(\.status).max()
    }
}

/// Keyboard navigation in the organization dropdown: arrows move a highlight over the
/// organizations and the final "New organization" item; only Return acts.
struct OrganizationMenuNavigation: Equatable {
    enum Item: Equatable {
        case organization(UUID)
        case create
    }

    enum Key { case up, down, enter, escape }

    enum Action: Equatable {
        case none
        case select(UUID)
        case create
        case close
    }

    let items: [Item]
    private(set) var highlighted: Int

    /// Starts on the active organization.
    init(organizations: [UUID], active: UUID) {
        items = organizations.map(Item.organization) + [.create]
        highlighted = organizations.firstIndex(of: active) ?? 0
    }

    var highlightedItem: Item { items[highlighted] }

    mutating func highlight(_ item: Item) {
        if let index = items.firstIndex(of: item) { highlighted = index }
    }

    /// `active` is the organization shown: choosing it only closes the menu.
    mutating func press(_ key: Key, active: UUID) -> Action {
        switch key {
        case .up:
            highlighted = max(highlighted - 1, 0)
            return .none
        case .down:
            highlighted = min(highlighted + 1, items.count - 1)
            return .none
        case .escape:
            return .close
        case .enter:
            switch highlightedItem {
            case .create: return .create
            case let .organization(id): return id == active ? .close : .select(id)
            }
        }
    }
}
