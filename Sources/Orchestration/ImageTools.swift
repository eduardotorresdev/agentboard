import Connections
import Foundation

/// The image tools: agents put pictures on the board (a screenshot, a chart) and see the
/// pixels of the images connected to them. A second instance, for `.video`, gives the same
/// tools for videos (`video_create`…), which share the images' record and files.
@MainActor
final class ImageTools: ToolProvider {
    enum Medium {
        case image, video

        var kind: ElementKind { self == .image ? .image : .video }
        /// Tool prefix and argument name.
        var word: String { self == .image ? "image" : "video" }
        var title: String { self == .image ? "Image" : "Video" }
    }

    private unowned let store: Orchestrator
    private let medium: Medium
    /// Per agent, each connected image as it last reached its context: name and file.
    private var delivered: [UUID: [UUID: Delivered]] = [:]

    private struct Delivered: Equatable {
        let name: String
        let file: String
    }

    init(store: Orchestrator, medium: Medium = .image) {
        self.store = store
        self.medium = medium
    }

    func instructions(for caller: UUID) -> String? {
        if medium == .video {
            return """
            Videos are clips on the user's board (MP4, MOV or M4V), kept apart from images. You hear in your context \
            when one is connected to you, replaced or disconnected; video_read gives its size, length and \(ImageFiles.readFrames) \
            frames sampled evenly through it. video_create puts a video file you made (a screen recording) on the \
            board next to you, connected to you; video_replace swaps its clip, video_remove takes it off the board. \
            Give a file path; videos are never passed inline.
            """
        }
        return """
        Images are pictures on the user's board. You hear in your context when one is connected to you, replaced \
        or disconnected; see its pixels with image_read. image_create puts a picture file you made (a screenshot, \
        a chart) on the board next to you, connected to you; image_replace swaps the picture of a connected image, \
        image_remove takes one off the board. Give a file path; images are never passed inline. For videos use the \
        video_ tools.
        """
    }

    private var elementArgument: [String: Any] {
        ["type": "string",
         "description": "Which connected \(medium.word), by name or id (as list_peers shows it). Needed only when several are connected."]
    }

    private var pathArgument: [String: Any] {
        ["type": "string",
         "description": medium == .image
            ? "The picture file: absolute, with `~`, or relative to your worktree. Any image format, up to 20 MB."
            : "The video file: absolute, with `~`, or relative to your worktree. MP4, MOV or M4V, up to \(ImageFiles.maximumVideoBytes / 1024 / 1024) MB."]
    }

    func tools(for caller: UUID) -> [ToolDefinition] {
        let word = medium.word
        let picture = medium == .image
        return [
            ToolDefinition(
                name: "\(word)_create",
                description: picture ? "Puts a picture file on the board next to you, connected to you."
                    : "Puts a video file on the board next to you, connected to you. It never plays on its own.",
                inputSchema: ["type": "object", "properties": [
                    "path": pathArgument,
                    "name": ["type": "string", "description": "Its title, e.g. `\(picture ? "Login screen" : "Signup flow")`. “\(medium.title)” when left out."],
                ] as [String: Any], "required": ["path"]]),
            ToolDefinition(
                name: "\(word)_read",
                description: picture ? "Shows you the pixels of a connected image."
                    : "Gives a connected video's size and length and \(ImageFiles.readFrames) frames sampled evenly through it.",
                inputSchema: ["type": "object", "properties": [word: elementArgument], "required": [String]()]),
            ToolDefinition(
                name: "\(word)_replace",
                description: picture ? "Replaces the picture of a connected image with a file, keeping its card and name."
                    : "Replaces the clip of a connected video with a file, keeping its card and name.",
                inputSchema: ["type": "object", "properties": ["path": pathArgument, word: elementArgument] as [String: Any],
                              "required": ["path"]]),
            ToolDefinition(
                name: "\(word)_remove",
                description: "Takes a connected \(word) off the board.",
                inputSchema: ["type": "object", "properties": [word: elementArgument], "required": [String]()]),
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        let word = medium.word
        if name == "\(word)_create" { return await create(arguments, caller: caller) }
        let element: any BoardElement
        switch resolve(arguments[word] as? String, for: caller) {
        case .success(let found): element = found
        case .failure(let refusal): return .error(refusal.text)
        }
        guard let record = store.image(element.id) else { return .error("That \(word) is gone.") }
        switch name {
        case "video_read":
            guard let frames = await ImageFiles.readingVideo(record.file, in: store.dataFolder) else {
                return .error("The video \(record.name) can't be read.")
            }
            let length = String(format: "%.1f", record.duration ?? 0)
            var content: [ToolContent] = [.text("\(record.name), \(Int(record.pixelSize.width))×\(Int(record.pixelSize.height)) pixels, \(length) s. \(frames.count) frame\(frames.count == 1 ? "" : "s") follow\(frames.count == 1 ? "s" : ""), each after the second it shows.")]
            for frame in frames {
                content.append(.text(String(format: "At %.2f s:", frame.second)))
                content.append(.image(frame.jpeg, mimeType: "image/jpeg"))
            }
            return ToolResult(content)
        case "image_read":
            guard let picture = ImageFiles.reading(record.file, in: store.dataFolder) else {
                return .error("The picture of \(record.name) can't be read.")
            }
            return ToolResult([.text("\(record.name), \(Int(record.pixelSize.width))×\(Int(record.pixelSize.height)) pixels."),
                               .image(picture.data, mimeType: picture.mimeType)])
        case "\(word)_replace":
            let stored: ImageFiles.Stored
            switch await storeFile(arguments, caller: caller) {
            case .success(let found): stored = found
            case .failure(let refusal): return .error(refusal.text)
            }
            // Removed while the file was copied: the copy goes too.
            guard store.image(record.id) != nil else {
                ImageFiles.remove(stored.file, in: store.dataFolder)
                return .error("That \(word) is gone.")
            }
            store.updateImage(record.id) {
                $0.file = stored.file
                $0.pixelSize = stored.pixelSize
                $0.duration = stored.duration
                $0.frame.size = ImageRecord.cardSize(width: $0.frame.width, for: stored.pixelSize)
            }
            delivered[caller]?[record.id] = Delivered(name: record.name, file: stored.file)
            return .text("Replaced the \(medium == .image ? "picture" : "clip") of “\(record.name)”.")
        case "\(word)_remove":
            delivered[caller]?[record.id] = nil
            store.removeImage(record.id)
            return .text("Removed “\(record.name)” from the board.")
        default:
            return .error("Unknown tool “\(name)”.")
        }
    }

    private func create(_ arguments: [String: Any], caller: UUID) async -> ToolResult {
        guard store.record(caller) != nil else { return .error("Only agents on the board can add \(medium.word)s.") }
        // The name first: a refused name must not leave a copied file behind.
        let trimmed: String
        switch BoardName.argument(arguments["name"]) {
        case .success(let name): trimmed = name ?? ""
        case .failure(let error): return .error("\(error)")
        }
        let stored: ImageFiles.Stored
        switch await storeFile(arguments, caller: caller) {
        case .success(let found): stored = found
        case .failure(let refusal): return .error(refusal.text)
        }
        guard let agent = store.record(caller) else {
            ImageFiles.remove(stored.file, in: store.dataFolder)
            return .error("Only agents on the board can add \(medium.word)s.")
        }
        let siblings = store.images.filter { $0.worktree == agent.worktree && $0.organizationID == agent.organizationID }
        let size = ImageRecord.cardSize(for: stored.pixelSize)
        let record = ImageRecord(id: UUID(), worktree: agent.worktree,
                                 name: ImageRecord.uniqueName(trimmed.isEmpty ? medium.title : trimmed, among: siblings),
                                 frame: CGRect(origin: store.origin(near: agent, size: size), size: size),
                                 file: stored.file, pixelSize: stored.pixelSize, organization: agent.organization,
                                 duration: stored.duration)
        store.insertImage(record)
        store.bus.connect(caller, record.id)
        delivered[caller, default: [:]][record.id] = Delivered(name: record.name, file: record.file)
        return .text("Added \(medium.word) “\(record.name)” (\(Int(stored.pixelSize.width))×\(Int(stored.pixelSize.height))), connected to you.")
    }

    /// The file at `path`, stored with `ImageFiles`.
    private func storeFile(_ arguments: [String: Any], caller: UUID) async -> Result<ImageFiles.Stored, Refusal> {
        let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !path.isEmpty else { return .failure(Refusal(text: "Give the \(medium == .image ? "picture" : "video")'s file with `path`.")) }
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: store.record(caller)?.worktree ?? FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
        var video = medium == .video
        do {
            // Each medium takes only its own files, so the agent's choice of tool is the card it
            // gets. The kind comes from the resolved file, decided once.
            let file = try ImageFiles.inspect(url)
            video = file.kind == .video
            if video != (medium == .video) {
                return .failure(Refusal(text: video ? "\(url.path) is a video; put it on the board with video_create."
                    : "\(url.path) isn't a video; pictures go on the board with image_create."))
            }
            return .success(video ? try await ImageFiles.storeVideo(file, in: store.dataFolder)
                : try ImageFiles.storePicture(file, in: store.dataFolder))
        } catch ImageFiles.Failure.notAFile {
            return .failure(Refusal(text: "\(url.path) isn't a regular file (a folder, a device or a pipe)."))
        } catch ImageFiles.Failure.tooLarge {
            return .failure(Refusal(text: "\(url.path) is larger than \(video ? ImageFiles.maximumVideoBytes / 1024 / 1024 : 20) MB."))
        } catch ImageFiles.Failure.notPlayable {
            return .failure(Refusal(text: "\(url.path) isn't a video the board can play; use MP4, MOV or M4V."))
        } catch ImageFiles.Failure.notAnImage {
            return .failure(Refusal(text: "\(url.path) isn't an image."))
        } catch ImageFiles.Failure.missing {
            return .failure(Refusal(text: "There is no file at \(url.path)."))
        } catch {
            return .failure(Refusal(text: "\(url.path) couldn't be stored: \(error.localizedDescription)"))
        }
    }

    // MARK: Context

    /// One line per connected image the caller hasn't heard of as it is now: all of them when
    /// its session starts, then those connected, replaced or disconnected since. What the
    /// caller did itself isn't sent back.
    func context(for caller: UUID, event: String) -> String? {
        let fresh = event == "SessionStart"
        let before = fresh ? [:] : delivered[caller] ?? [:]
        var now: [UUID: Delivered] = [:]
        var parts: [String] = []
        let title = medium.title
        let read = "\(medium.word)_read"
        for element in store.bus.peers(of: caller, kind: medium.kind) {
            guard let record = store.image(element.id) else { continue }
            let current = Delivered(name: record.name, file: record.file)
            now[record.id] = current
            guard before[record.id] != current else { continue }
            let size = "\(Int(record.pixelSize.width))×\(Int(record.pixelSize.height))" + (record.duration.map { String(format: ", %.1f s", $0) } ?? "")
            if let old = before[record.id] {
                if old.file != current.file {
                    parts.append("\(title) “\(record.name)” has a new \(medium == .image ? "picture" : "clip") (\(size)); see it with \(read).")
                } else {
                    parts.append("\(title) “\(old.name)” is now called “\(record.name)”.")
                }
            } else {
                parts.append("\(title) “\(record.name)” (\(size)) is connected to you; see it with \(read).")
            }
        }
        for (id, gone) in before where now[id] == nil {
            parts.append("\(title) “\(gone.name)” is no longer connected to you.")
        }
        delivered[caller] = now
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: Resolving

    private var noneConnected: String {
        "No \(medium.word) is connected to you. Add one with \(medium.word)_create, or ask the user to connect one by drawing a line between it and your card."
    }

    private struct Refusal: Error {
        let text: String
    }

    private func resolve(_ name: String?, for caller: UUID) -> Result<any BoardElement, Refusal> {
        let images = store.bus.peers(of: caller, kind: medium.kind)
        guard !images.isEmpty else { return .failure(Refusal(text: noneConnected)) }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if let found = findElement(name, among: images) { return .success(found) }
            return .failure(Refusal(text: "No \(medium.word) named “\(name)” is connected to you. Connected: \(images.map(\.name).joined(separator: ", "))."))
        }
        guard images.count == 1, let only = images.first else {
            return .failure(Refusal(text: "Several \(medium.word)s are connected; say which with `\(medium.word)`: \(images.map(\.name).joined(separator: ", "))."))
        }
        return .success(only)
    }
}
