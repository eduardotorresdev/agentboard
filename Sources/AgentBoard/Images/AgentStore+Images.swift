import AgentRuntime
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
    /// unique). A video is checked and copied off the main thread. On another host the card
    /// shows at its size at once (`shown`), dimmed with a spinner while the file goes there, and
    /// joins the board once it has arrived; it goes again if the file can't be sent.
    @discardableResult
    func addImage(_ source: ImageSource, named name: String, to worktree: String, at origin: CGPoint,
                  shown: (ImageRecord) -> Void = { _ in }) async throws -> ImageRecord {
        let stored = switch source {
        case .file(let url): try await ImageFiles.storeMedia(contentsOf: url, in: dataFolder)
        case .data(let data): try ImageFiles.store(data, in: dataFolder)
        }
        // A file's name reaches agents: one line of visible text.
        let name = BoardName.clean(name) ?? (stored.duration == nil ? L("Image") : L("Video"))
        let record = ImageRecord(id: UUID(), worktree: worktree, name: ImageRecord.uniqueName(name, among: images(in: worktree)),
                                 frame: CGRect(origin: origin, size: ImageRecord.cardSize(for: stored.pixelSize)),
                                 file: stored.file, pixelSize: stored.pixelSize, organization: organizationID,
                                 duration: stored.duration)
        images.append(record)
        if let host {
            sendingMedia.insert(record.file)
            mediaNotes[record.file] = L("Sending to \(host.name)…")
            shown(record)
            // The host's core reads the picture from its own folder: it goes there first.
            do {
                try await upload(record.file) { [weak self] share in
                    self?.mediaNotes[record.file] = L("Sending to \(host.name)… \(Int(share * 100))%")
                    self?.onMediaNote?(record.file)
                }
            } catch {
                sendingMedia.remove(record.file)
                mediaNotes[record.file] = nil
                images.removeAll { $0.id == record.id }
                ImageFiles.remove(stored.file, in: dataFolder)
                throw error
            }
            sendingMedia.remove(record.file)
            mediaNotes[record.file] = nil
            // Moved, renamed or closed while it was sent: the board gets it as it is now.
            guard let current = image(record.id) else { return record }
            send(.addImage(current))
            onMediaNote?(record.file)
            return current
        }
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
    private func upload(_ file: String, progress: (Double) -> Void) async throws {
        let url = ImageFiles.url(of: file, in: dataFolder)
        guard let data = await Task.detached(operation: { try? Data(contentsOf: url, options: .mappedIfSafe) }).value,
              data.count <= HostMediaFailure.maximumBytes else { throw HostMediaFailure.tooLarge }
        guard let folder = await hostMediaFolder(), let files,
              await files.write(data, to: folder + "/" + file, piece: Self.attachmentPiece, progress: progress) else {
            throw HostMediaFailure.unreachable
        }
    }

    // MARK: Annotations

    /// The annotations on the image, started over when its picture was replaced.
    func marks(of record: ImageRecord) -> ImageMarks {
        if let state = imageMarks[record.id], state.file == record.file { return state }
        let state = ImageMarks(file: record.file, image: record.id)
        imageMarks[record.id] = state
        return state
    }

    /// Sends the image's annotations, with a copy of the picture that has them drawn on it, to
    /// `agent` alone (connected to the image first when it isn't), then clears them.
    func sendMarks(of id: UUID, to agent: UUID) async {
        guard let record = image(id), let state = imageMarks[id], !state.sending, let name = self.record(agent)?.name else { return }
        let marks = state.kept
        guard !marks.isEmpty else { return }
        state.failure = nil
        guard let picture = ImageCardLayer.cache[record.file], let data = ImageMarks.render(picture, marks: marks, pixelSize: record.pixelSize),
              let stored = try? ImageFiles.store(data, in: dataFolder) else {
            state.failure = L("Couldn't draw the marks on the picture. Nothing was sent.")
            return
        }
        if let host {
            state.sending = true
            defer { state.sending = false }
            // The host's core reads the marked copy from its own folder.
            do { try await upload(stored.file) { _ in } } catch {
                ImageFiles.remove(stored.file, in: dataFolder)
                state.failure = L("Couldn't send the picture to \(host.name). Nothing was sent.")
                return
            }
        }
        connect(id, agent)
        send(.deliver(from: id, text: ImageMarks.message(for: marks, on: BoardMention(name: record.name, type: ElementKind.image.rawValue, id: id),
                                                         pixelSize: record.pixelSize, marked: stored.file), to: agent))
        lastMarkedAgent = agent
        state.marks = []
        state.selected = nil
        state.marking = false
        state.sent = marks.count == 1 ? L("Sent 1 annotation to \(name)") : L("Sent \(marks.count) annotations to \(name)")
        onMediaNote?(record.file)
        try? await Task.sleep(for: .seconds(2.5))
        state.sent = nil
        onMediaNote?(record.file)
    }

    /// A sample picture with annotations on it, to look at them (`AGENTBOARD_SHOW=image-marks`,
    /// with an agent to send them to for `image-marks-agent`).
    func showSampleMarks(in worktree: String, agent: Bool) async {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(BoardPalette.card)
        context.fill(CGRect(x: 0, y: 0, width: 1440, height: 900))
        for (index, block) in [CGRect(x: 48, y: 282, width: 408, height: 132), CGRect(x: 48, y: 560, width: 900, height: 220), CGRect(x: 1000, y: 120, width: 380, height: 660)].enumerated() {
            context.setFillColor(BoardPalette.rgb(index == 0 ? BoardPalette.accent : BoardPalette.ink, index == 0 ? 1 : 0.08))
            context.fill(block)
        }
        guard let data = context.makeImage().flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }),
              let record = try? await addImage(.data(data), named: "checkout", to: worktree, at: CGPoint(x: 440, y: 60)) else { return }
        if agent, let provider = AgentCatalog.all.first { _ = add(provider, to: worktree, at: CGPoint(x: 1300, y: 60)) }
        let state = marks(of: record)
        state.marks = [ImageMark(area: CGRect(x: 48, y: 486, width: 408, height: 132), text: "The button should say “Pay $48.00”, not “Submit”."),
                       ImageMark(area: CGRect(x: 1000, y: 120, width: 380, height: 300), text: "Too much empty space."),
                       ImageMark(area: CGRect(x: 48, y: 120, width: 520, height: 160))]
        state.marking = true
        state.selected = state.marks[2].id
        onMediaNote?(record.file)
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
               let ran = await run("sh", ["-c", Self.fetchScript, "sh", folder + "/" + file, String(limit)], bulk: true, patience: HostFiles.patience(sending: limit)) {
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
        // One still on its way never reached the board.
        let unsent = image(id).map { sendingMedia.contains($0.file) } ?? false
        forgetHostMedia(of: id)
        imageMarks[id] = nil
        ImageMarks.forget(id)
        images.removeAll { $0.id == id }
        dropConnections(touching: id)
        if !unsent { send(.removeImage(id)) }
    }

    func setImageFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].frame = frame
        if persist, !sendingMedia.contains(images[index].file) { send(.updateImage(images[index])) }
    }

    func renameImage(_ id: UUID, to name: String) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = BoardName.clean(name) ?? ""
        guard !trimmed.isEmpty, trimmed != images[index].name else { return }
        images[index].name = ImageRecord.uniqueName(trimmed, among: images(in: images[index].worktree).filter { $0.id != id })
        if !sendingMedia.contains(images[index].file) { send(.updateImage(images[index])) }
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
