import AppKit
import Connections
import Orchestration
import UniformTypeIdentifiers

/// A picture or video the user gives the board: a file (picked or dropped), or pasted bytes
/// (pictures only; a copied video comes as its file).
enum ImageSource: Equatable {
    case file(URL)
    case data(Data)

    /// The picture on `pasteboard`: a copied image or video file, else PNG or TIFF data. A copied
    /// file that is neither gives nothing, not the icon Finder puts next to it.
    static func read(from pasteboard: NSPasteboard) -> ImageSource? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.first(where: isMediaFile).map(ImageSource.file) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return .data(data) }
        }
        return nil
    }

    /// Puts the stored picture itself, at its full size, on `pasteboard`.
    @discardableResult
    static func copy(_ record: ImageRecord, in dataFolder: URL, to pasteboard: NSPasteboard) -> Bool {
        if record.isVideo {
            // A video goes as its file, the way Finder copies one.
            pasteboard.clearContents()
            return pasteboard.writeObjects([ImageFiles.url(of: record.file, in: dataFolder) as NSURL])
        }
        guard let image = NSImage(contentsOf: ImageFiles.url(of: record.file, in: dataFolder)) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
    }

    /// A picture or a movie file (a movie AVFoundation can't play is refused when stored).
    static func isMediaFile(_ url: URL) -> Bool {
        isImageFile(url) || (url.isFileURL && ImageFiles.isVideoFile(url))
    }

    var isVideo: Bool {
        if case .file(let url) = self { return ImageFiles.isVideoFile(url) }
        return false
    }

    /// The card's name before it is made unique: the file's name, `Image` for pasted bytes.
    var baseName: String {
        switch self {
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .data: L("Image")
        }
    }
}

/// Why a picture couldn't be sent to another host.
enum HostMediaFailure: Error {
    case tooLarge
    case unreachable

    /// The most one `run` carries to or from a host in one piece (see docs/hosts.md).
    static let maximumBytes = 64 * 1024 * 1024
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

    /// Stores the picture or video and adds a card for it at `origin`, named `name` (made
    /// unique). A video is checked and copied off the main thread.
    @discardableResult
    func addImage(_ source: ImageSource, named name: String, to worktree: String, at origin: CGPoint) async throws -> ImageRecord {
        let stored = switch source {
        case .file(let url): try await ImageFiles.storeMedia(contentsOf: url, in: dataFolder)
        case .data(let data): try ImageFiles.store(data, in: dataFolder)
        }
        if host != nil {
            // The host's core reads the picture from its own folder: it goes there first.
            do { try await upload(stored.file) } catch {
                ImageFiles.remove(stored.file, in: dataFolder)
                throw error
            }
        }
        // A file's name reaches agents: one line of visible text.
        let name = BoardName.clean(name) ?? (stored.duration == nil ? L("Image") : L("Video"))
        let record = ImageRecord(id: UUID(), worktree: worktree, name: ImageRecord.uniqueName(name, among: images(in: worktree)),
                                 frame: CGRect(origin: origin, size: ImageRecord.cardSize(for: stored.pixelSize)),
                                 file: stored.file, pixelSize: stored.pixelSize, organization: organizationID,
                                 duration: stored.duration)
        images.append(record)
        send(.addImage(record))
        return record
    }

    // MARK: Another host's pictures

    /// The host's own data folder, asked once; nil when the host can't say.
    func askHostDataFolder() async -> String? {
        if hostDataFolder == nil, let printed = await files?.output("agentboard", ["data-folder"]) {
            let path = printed.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { hostDataFolder = path }
        }
        return hostDataFolder
    }

    /// The host's pictures folder, inside its data folder.
    private func hostMediaFolder() async -> String? {
        await askHostDataFolder().map { $0 + "/images" }
    }

    /// Copies a picture this Mac just stored (in its copy of the host's pictures) to the host.
    private func upload(_ file: String) async throws {
        let url = ImageFiles.url(of: file, in: dataFolder)
        guard let data = await Task.detached(operation: { try? Data(contentsOf: url, options: .mappedIfSafe) }).value,
              data.count <= HostMediaFailure.maximumBytes else { throw HostMediaFailure.tooLarge }
        guard let folder = await hostMediaFolder(), let files, await files.write(data, to: folder + "/" + file) else {
            throw HostMediaFailure.unreachable
        }
    }

    /// Prints the file when it is no larger than `$2` bytes; exits with 3 when it is.
    private static let fetchScript = "n=$(wc -c < \"$1\") || exit 1; [ \"$n\" -le \"$2\" ] || exit 3; cat \"$1\""

    /// Brings a picture kept on another host (one an agent made there) to this Mac's copy of
    /// that host's pictures, off the main thread, and says when it is here (`onMediaChange`).
    /// Does nothing for this Mac's own pictures, or one already here, on its way, or refused.
    func fetchMedia(_ record: ImageRecord, limit: Int = HostMediaFailure.maximumBytes) {
        let file = record.file
        // A plain file name inside the pictures folder, never a path out of it.
        guard let host, mediaNotes[file] == nil, !file.isEmpty, file != ".", file != "..",
              (file as NSString).lastPathComponent == file else { return }
        let destination = ImageFiles.url(of: file, in: dataFolder)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        mediaNotes[file] = L("Fetching from \(host.name)…")
        Task {
            var note: String? = L("Couldn't fetch this from \(host.name).")
            if let folder = await hostMediaFolder(),
               let ran = await run("sh", ["-c", Self.fetchScript, "sh", folder + "/" + file, String(limit)]) {
                if ran.status == 3 {
                    note = L("Larger than \(limit / 1024 / 1024) MB: too large to bring from \(host.name).")
                } else if ran.status == 0 {
                    let saved = await Task.detached {
                        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Whole or not at all: a card never loads half a picture.
                        return (try? ran.output.write(to: destination, options: .atomic)) != nil
                    }.value
                    if saved { note = nil }
                }
            }
            mediaNotes[file] = note
            onMediaChange?(file)
        }
    }

    /// A removed card's picture leaves this Mac's copy of the host's pictures too. This Mac's
    /// own pictures are its core's to remove.
    func forgetHostMedia(of id: UUID) {
        guard host != nil, let record = image(id) else { return }
        ImageFiles.remove(record.file, in: dataFolder)
        mediaNotes[record.file] = nil
    }

    func removeImage(_ id: UUID) {
        forgetHostMedia(of: id)
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
        let trimmed = BoardName.clean(name) ?? ""
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
