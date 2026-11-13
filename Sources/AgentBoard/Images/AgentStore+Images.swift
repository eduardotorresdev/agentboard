import AppKit
import Orchestration
import UniformTypeIdentifiers

/// A picture the user gives the board: a file (picked or dropped), or pasted bytes.
enum ImageSource: Equatable {
    case file(URL)
    case data(Data)

    /// The picture on `pasteboard`: a copied image file, else PNG or TIFF data. A copied file
    /// that isn't an image gives nothing, not the icon Finder puts next to it.
    static func read(from pasteboard: NSPasteboard) -> ImageSource? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.first(where: isImageFile).map(ImageSource.file) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return .data(data) }
        }
        return nil
    }

    /// Puts the stored picture itself, at its full size, on `pasteboard`.
    @discardableResult
    static func copy(_ record: ImageRecord, in dataFolder: URL, to pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(contentsOf: ImageFiles.url(of: record.file, in: dataFolder)) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
    }

    /// The card's name before it is made unique: the file's name, `Image` for pasted bytes.
    var baseName: String {
        switch self {
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .data: L("Image")
        }
    }
}

/// Images: pictures on the board, which connected agents see with `image_read`. The core keeps
/// them; the board stores the file the user gives, shows them and sends the user's changes.
extension AgentStore {
    func images(in worktree: String) -> [ImageRecord] {
        images.filter { $0.worktree == worktree && $0.organizationID == organizationID }
    }

    func image(_ id: UUID) -> ImageRecord? {
        images.first { $0.id == id }
    }

    /// Stores the picture and adds a card for it at `origin`, named `name` (made unique).
    @discardableResult
    func addImage(_ source: ImageSource, named name: String, to worktree: String, at origin: CGPoint) throws -> ImageRecord {
        let stored = switch source {
        case .file(let url): try ImageFiles.store(contentsOf: url, in: dataFolder)
        case .data(let data): try ImageFiles.store(data, in: dataFolder)
        }
        let record = ImageRecord(id: UUID(), worktree: worktree, name: ImageRecord.uniqueName(name, among: images(in: worktree)),
                                 frame: CGRect(origin: origin, size: ImageRecord.cardSize(for: stored.pixelSize)),
                                 file: stored.file, pixelSize: stored.pixelSize, organization: organizationID)
        images.append(record)
        send(.addImage(record))
        return record
    }

    func removeImage(_ id: UUID) {
        images.removeAll { $0.id == id }
        dropConnections(touching: id)
        send(.removeImage(id))
    }

    func setImageFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].frame = frame
        if persist { send(.updateImage(images[index])) }
    }

    func renameImage(_ id: UUID, to name: String) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != images[index].name else { return }
        images[index].name = ImageRecord.uniqueName(trimmed, among: images(in: images[index].worktree).filter { $0.id != id })
        send(.updateImage(images[index]))
    }

    /// Moves the image to the top of the image stack.
    func raiseImage(_ id: UUID) {
        guard let index = images.firstIndex(where: { $0.id == id }), index != images.count - 1 else { return }
        images.append(images.remove(at: index))
    }
}

/// Resizing an image card: from any edge or corner, always through `ImageRecord.cardSize`, so
/// the picture keeps its proportion; the opposite edge or corner stays put.
enum ImageResize {
    struct Edges: OptionSet, Equatable {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    /// The edges within `reach` of `point` (world points), inside the card.
    static func edges(at point: CGPoint, in frame: CGRect, reach: CGFloat) -> Edges {
        guard frame.contains(point) else { return [] }
        var edges: Edges = []
        if point.x < frame.minX + reach { edges.insert(.left) } else if point.x > frame.maxX - reach { edges.insert(.right) }
        if point.y < frame.minY + reach { edges.insert(.top) } else if point.y > frame.maxY - reach { edges.insert(.bottom) }
        return edges
    }

    /// `frame` with `edges` dragged by `delta`.
    static func frame(resizing frame: CGRect, edges: Edges, by delta: CGSize, pixelSize: CGSize) -> CGRect {
        let ratio = pixelSize.width / max(pixelSize.height, 1)
        let dx = edges.contains(.left) ? -delta.width : edges.contains(.right) ? delta.width : 0
        let dy = edges.contains(.top) ? -delta.height : edges.contains(.bottom) ? delta.height : 0
        let fromWidth = frame.width + dx
        let fromHeight = (frame.height - ImageRecord.titleHeight + dy) * ratio
        let width = switch (edges.intersection([.left, .right]).isEmpty, edges.intersection([.top, .bottom]).isEmpty) {
        case (false, true): fromWidth
        case (true, false): fromHeight
        default: max(fromWidth, fromHeight)
        }
        let size = ImageRecord.cardSize(width: width.rounded(), for: pixelSize)
        return CGRect(x: edges.contains(.left) ? frame.maxX - size.width : frame.minX,
                      y: edges.contains(.top) ? frame.maxY - size.height : frame.minY,
                      width: size.width, height: size.height)
    }
}
