import AgentRuntime
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
        guard size?.isRegularFile == true, let bytes = size?.fileSize else { throw Failure.missing }
        guard bytes <= maximumBytes else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: source) else { throw Failure.missing }
        return try store(data, in: dataFolder)
    }

    /// Stores `data` (a pasted picture) under a new name, as it is.
    public static func store(_ data: Data, in dataFolder: URL) throws -> Stored {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              let pixelSize = pixelSize(of: source) else { throw Failure.notAnImage }
        let file = UUID().uuidString + "." + (type.preferredFilenameExtension ?? "img")
        try FileManager.default.createDirectory(at: folder(in: dataFolder), withIntermediateDirectories: true)
        try data.write(to: url(of: file, in: dataFolder))
        return Stored(file: file, pixelSize: pixelSize)
    }

    /// The first frame's size, upright, read from the header without decoding the bitmap.
    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // EXIF orientations 5–8 turn the picture a quarter.
        let turned = (properties[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    public static func remove(_ file: String, in dataFolder: URL) {
        try? FileManager.default.removeItem(at: url(of: file, in: dataFolder))
    }

    /// The picture for an agent: as stored when it is a PNG, JPEG, GIF or WebP no larger than
    /// `readSide` on its longer side, else scaled down to that and encoded as JPEG when the
    /// source is one and PNG otherwise. Nil when the file is gone or unreadable.
    public static func reading(_ file: String, in dataFolder: URL) -> (data: Data, mimeType: String)? {
        guard let data = try? Data(contentsOf: url(of: file, in: dataFolder)),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              let size = pixelSize(of: source) else { return nil }
        let passed: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg", .gif: "image/gif", .webP: "image/webp"]
        if let mimeType = passed[type], max(size.width, size.height) <= CGFloat(readSide) { return (data, mimeType) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(readSide, Int(max(size.width, size.height)))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output: UTType = type == .jpeg ? .jpeg : .png
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, output.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (encoded as Data, output == .jpeg ? "image/jpeg" : "image/png")
    }
}
