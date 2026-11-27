import Connections
import Foundation

/// An organizational group: images and videos kept in one column or one row, snapped to the
/// group's grid, on a light panel of a palette color. Only pictures join one, each at most one.
/// The core lays the members out, so agents and every board see the same places.
public struct ImageGroup: Identifiable, Hashable, Codable, Sendable {
    public enum Direction: String, Codable, Sendable, CaseIterable {
        /// One column: every card as wide as the group's `extent`.
        case vertical
        /// One row: every picture as tall as the group's `extent`.
        case horizontal
    }

    public let id: UUID
    /// How agents address it; unique among the groups.
    public var name: String
    public var direction: Direction
    /// One of `colors`.
    public var color: String
    /// The first member's top left corner; nil until the core places the group around its members.
    public var origin: CGPoint?
    /// The grid's cell: the cards' width in a column, the pictures' height in a row. Nil until
    /// the core takes it from the first member (again after the direction changes).
    public var extent: CGFloat?
    /// The images and videos, in the order they are laid out.
    public var members: [UUID]

    public init(id: UUID = UUID(), name: String = "", direction: Direction, color: String = ImageGroup.colors[0],
                origin: CGPoint? = nil, extent: CGFloat? = nil, members: [UUID]) {
        self.id = id
        self.name = name
        self.direction = direction
        self.color = color
        self.origin = origin
        self.extent = extent
        self.members = members
    }

    /// The palette a group's panel is picked from (the board has the colors, see `Theme.Hex.group`).
    public static let colors = ["blue", "amber", "rose", "violet", "gray"]
    /// The space between two members.
    public static let gap: CGFloat = 16
    /// The panel around the members.
    public static let padding: CGFloat = 16

    /// Where each member goes, given the pictures' pixel sizes in member order.
    public func frames(for pixelSizes: [CGSize]) -> [CGRect] {
        var point = origin ?? .zero
        let extent = extent ?? ImageRecord.minimumWidth
        return pixelSizes.map { pixels in
            let width = direction == .vertical ? extent : (extent * pixels.width / max(pixels.height, 1)).rounded()
            let frame = CGRect(origin: point, size: ImageRecord.cardSize(width: width, for: pixels))
            if direction == .vertical { point.y = frame.maxY + Self.gap } else { point.x = frame.maxX + Self.gap }
            return frame
        }
    }
}

extension Orchestrator {
    static func imageGroupsFile(in folder: URL) -> URL { folder.appendingPathComponent("image-groups.json") }

    func imageGroup(of image: UUID) -> ImageGroup? { imageGroups.first { $0.members.contains(image) } }

    /// The groups whose pictures are on `caller`'s board.
    func imageGroups(onBoardOf caller: UUID) -> [ImageGroup] {
        let onBoard = Set(bus.elements(onBoardOf: caller).map(\.id))
        return imageGroups.filter { $0.members.contains(where: onBoard.contains) }
    }

    /// Makes or changes a group: keeps only the pictures of its first member's board, takes them
    /// out of any other group, fills what is nil from the members, and lays everything out.
    /// A group left without members goes.
    func setImageGroup(_ wanted: ImageGroup) {
        var group = wanted
        var records: [ImageRecord] = []
        for record in group.members.compactMap({ image($0) }) where !records.contains(record) {
            if let first = records.first, first.worktree != record.worktree || first.organizationID != record.organizationID { continue }
            records.append(record)
        }
        guard !records.isEmpty else { return removeImageGroup(group.id) }
        let old = imageGroups.first { $0.id == group.id }
        if old == nil {
            // A new group reads in the order the pictures already sit along its direction.
            records.sort { group.direction == .vertical ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        }
        group.members = records.map(\.id)
        if !ImageGroup.colors.contains(group.color) { group.color = old?.color ?? ImageGroup.colors[0] }
        if old.map({ $0.direction != group.direction }) == true { group.extent = nil }
        group.extent = group.extent ?? (group.direction == .vertical ? records[0].frame.width : records[0].frame.height - ImageRecord.titleHeight)
        group.origin = group.origin ?? CGPoint(x: records.map(\.frame.minX).min() ?? 0, y: records.map(\.frame.minY).min() ?? 0)
        group.name = BoardName.clean(group.name) ?? old?.name ?? {
            var number = 1
            while imageGroups.contains(where: { $0.name == "Group \(number)" }) { number += 1 }
            return "Group \(number)"
        }()
        for index in imageGroups.indices where imageGroups[index].id != group.id {
            imageGroups[index].members.removeAll(where: group.members.contains)
        }
        if let index = imageGroups.firstIndex(where: { $0.id == group.id }) { imageGroups[index] = group } else { imageGroups.append(group) }
        imageGroups.removeAll { $0.members.isEmpty }
        imageGroupsChanged()
    }

    /// Forgets the group; its pictures stay where they are.
    func removeImageGroup(_ id: UUID) {
        guard imageGroups.contains(where: { $0.id == id }) else { return }
        imageGroups.removeAll { $0.id == id }
        imageGroupsChanged()
    }

    /// A removed picture leaves its group.
    func imageLeftBoard(_ id: UUID) {
        guard imageGroup(of: id) != nil else { return }
        for index in imageGroups.indices { imageGroups[index].members.removeAll { $0 == id } }
        imageGroups.removeAll { $0.members.isEmpty }
        imageGroupsChanged()
    }

    /// A grouped picture was moved or resized on its own (dragged on a board, `element_move`,
    /// `image_resize`): the whole group follows, so the grid holds. Moving it moves the group;
    /// resizing it resizes the grid's cell.
    func imageFrameChanged(_ id: UUID, from before: CGRect) {
        guard let index = imageGroups.firstIndex(where: { $0.members.contains(id) }), let now = image(id)?.frame, now != before else { return }
        if let origin = imageGroups[index].origin {
            imageGroups[index].origin = CGPoint(x: origin.x + now.minX - before.minX, y: origin.y + now.minY - before.minY)
        }
        if now.size != before.size {
            imageGroups[index].extent = imageGroups[index].direction == .vertical ? now.width : now.height - ImageRecord.titleHeight
        }
        imageGroupsChanged()
    }

    /// Puts every grouped picture on its group's grid; every board hears of the ones that moved.
    func layoutImageGroups() {
        for group in imageGroups {
            let records = group.members.compactMap { image($0) }
            for (record, frame) in zip(records, group.frames(for: records.map(\.pixelSize))) {
                updateImage(record.id) { $0.frame = frame }
            }
        }
    }

    private func imageGroupsChanged() {
        try? JSONEncoder().encode(imageGroups).write(to: Self.imageGroupsFile(in: dataFolder), options: .atomic)
        layoutImageGroups()
        broadcast(.imageGroups(imageGroups))
    }
}
