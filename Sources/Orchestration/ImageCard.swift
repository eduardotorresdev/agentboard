import AgentRuntime
import Foundation

/// An image on the board: a picture the user pasted, picked or dropped, or one an agent made
/// (a screenshot, a chart). The core keeps it, so agents use it while no board runs. Agents
/// connected to it see its pixels with `image_read`.
public struct ImageRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let worktree: String
    /// How the image is titled and how connected agents address it; unique among the images of
    /// its worktree.
    public var name: String
    /// The whole card: `titleHeight` of title bar above the picture.
    public var frame: CGRect
    /// The picture's file name inside `ImageFiles.folder(in:)`. Replacing the picture gives it
    /// a new file name, which is how boards know to load it again.
    public var file: String
    /// The picture's size in pixels.
    public var pixelSize: CGSize
    /// The organization it was added in.
    public var organization: UUID?

    public init(id: UUID, worktree: String, name: String, frame: CGRect, file: String, pixelSize: CGSize,
                organization: UUID? = nil) {
        self.id = id
        self.worktree = worktree
        self.name = name
        self.frame = frame
        self.file = file
        self.pixelSize = pixelSize
        self.organization = organization
    }

    public var organizationID: UUID { organization ?? OrganizationHome.defaultID }

    /// The title bar above the picture.
    public static let titleHeight: CGFloat = 32
    /// The longer side of the picture on a new card.
    public static let initialSide: CGFloat = 480
    /// The narrowest a card gets.
    public static let minimumWidth: CGFloat = 160

    /// The size of a new card showing a picture of `pixelSize`: one point per pixel, scaled
    /// down so the longer side is at most `initialSide` and never scaled up, at least
    /// `minimumWidth` wide, plus the title bar.
    public static func cardSize(for pixelSize: CGSize) -> CGSize {
        cardSize(width: min(pixelSize.width, pixelSize.width * initialSide / max(pixelSize.width, pixelSize.height, 1)),
                 for: pixelSize)
    }

    /// The card `width` wide (at least `minimumWidth`) that shows a picture of `pixelSize`
    /// without bars: every resize goes through this, so the proportion never changes.
    public static func cardSize(width: CGFloat, for pixelSize: CGSize) -> CGSize {
        let width = max(width, minimumWidth)
        return CGSize(width: width, height: (width * pixelSize.height / max(pixelSize.width, 1)).rounded() + titleHeight)
    }

    /// `base`, or `base 2`, `base 3`… whichever no image in `others` is called.
    public static func uniqueName(_ base: String, among others: [ImageRecord]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

/// Where the pictures of the board's images live, and how one gets in: the board (paste, file
/// picker, drop) and the core (`image_create`, `image_replace`) both store through here, so
/// both refuse the same files.
public enum ImageFiles {
    /// The largest file taken.
    public static let maximumBytes = 20 * 1024 * 1024
    /// The longer side of what `image_read` gives an agent.
    public static let readSide = 1568

    public enum Failure: Error, Equatable {
        case missing
        case tooLarge
        case notAnImage
    }

    public struct Stored: Equatable, Sendable {
        public let file: String
        public let pixelSize: CGSize
    }

    public static func folder(in dataFolder: URL) -> URL {
        dataFolder.appendingPathComponent("images", isDirectory: true)
    }

    public static func url(of file: String, in dataFolder: URL) -> URL {
        folder(in: dataFolder).appendingPathComponent(file)
    }

    /// Copies the picture at `source` into the folder under a new name, as it is.
    public static func store(contentsOf source: URL, in dataFolder: URL) throws -> Stored {
        fatalError("contract stub: core track")
    }

    /// Stores `data` (a pasted picture) under a new name, as it is.
    public static func store(_ data: Data, in dataFolder: URL) throws -> Stored {
        fatalError("contract stub: core track")
    }

    public static func remove(_ file: String, in dataFolder: URL) {
        try? FileManager.default.removeItem(at: url(of: file, in: dataFolder))
    }

    /// The picture for an agent: as stored when it is a PNG, JPEG, GIF or WebP no larger than
    /// `readSide` on its longer side, else scaled down to that and encoded as JPEG when the
    /// source is one and PNG otherwise. Nil when the file is gone or unreadable.
    public static func reading(_ file: String, in dataFolder: URL) -> (data: Data, mimeType: String)? {
        fatalError("contract stub: core track")
    }
}
