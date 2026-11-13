import Connections
import Foundation

/// The image tools: agents put pictures on the board (a screenshot, a chart) and see the
/// pixels of the images connected to them.
@MainActor
final class ImageTools: ToolProvider {
    private unowned let store: Orchestrator
    /// Per agent, each connected image as it last reached its context: name and file.
    private var delivered: [UUID: [UUID: Delivered]] = [:]

    private struct Delivered: Equatable {
        let name: String
        let file: String
    }

    init(store: Orchestrator) {
        self.store = store
    }

    func instructions(for caller: UUID) -> String? {
        """
        Images are pictures on the user's board. You hear in your context when one is connected to you, replaced \
        or disconnected; see its pixels with image_read. image_create puts a picture file you made (a screenshot, \
        a chart) on the board next to you, connected to you; image_replace swaps the picture of a connected image, \
        image_remove takes one off the board. Give a file path; images are never passed inline.
        """
    }

    private static let imageArgument: [String: Any] = [
        "type": "string",
        "description": "Which connected image, by name. Needed only when several are connected.",
    ]

    private static let pathArgument: [String: Any] = [
        "type": "string",
        "description": "The picture file: absolute, with `~`, or relative to your worktree. Any image format, up to 20 MB.",
    ]

    func tools(for caller: UUID) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "image_create",
                description: "Puts a picture file on the board next to you, connected to you.",
                inputSchema: ["type": "object", "properties": [
                    "path": Self.pathArgument,
                    "name": ["type": "string", "description": "Its title, e.g. `Login screen`. “Image” when left out."],
                ] as [String: Any], "required": ["path"]]),
            ToolDefinition(
                name: "image_read",
                description: "Shows you the pixels of a connected image.",
                inputSchema: ["type": "object", "properties": ["image": Self.imageArgument], "required": [String]()]),
            ToolDefinition(
                name: "image_replace",
                description: "Replaces the picture of a connected image with a file, keeping its card and name.",
                inputSchema: ["type": "object", "properties": ["path": Self.pathArgument, "image": Self.imageArgument] as [String: Any],
                              "required": ["path"]]),
            ToolDefinition(
                name: "image_remove",
                description: "Takes a connected image off the board.",
                inputSchema: ["type": "object", "properties": ["image": Self.imageArgument], "required": [String]()]),
        ]
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        if name == "image_create" { return create(arguments, caller: caller) }
        let element: any BoardElement
        switch resolve(arguments["image"] as? String, for: caller) {
        case .success(let found): element = found
        case .failure(let refusal): return .error(refusal.text)
        }
        guard let record = store.image(element.id) else { return .error("That image is gone.") }
        switch name {
        case "image_read":
            guard let picture = ImageFiles.reading(record.file, in: store.dataFolder) else {
                return .error("The picture of \(record.name) can't be read.")
            }
            return ToolResult([.text("\(record.name), \(Int(record.pixelSize.width))×\(Int(record.pixelSize.height)) pixels."),
                               .image(picture.data, mimeType: picture.mimeType)])
        case "image_replace":
            let stored: ImageFiles.Stored
            switch storeFile(arguments, caller: caller) {
            case .success(let found): stored = found
            case .failure(let refusal): return .error(refusal.text)
            }
            store.updateImage(record.id) {
                $0.file = stored.file
                $0.pixelSize = stored.pixelSize
                $0.frame.size = ImageRecord.cardSize(width: $0.frame.width, for: stored.pixelSize)
            }
            delivered[caller]?[record.id] = Delivered(name: record.name, file: stored.file)
            return .text("Replaced the picture of “\(record.name)”.")
        case "image_remove":
            delivered[caller]?[record.id] = nil
            store.removeImage(record.id)
            return .text("Removed “\(record.name)” from the board.")
        default:
            return .error("Unknown tool “\(name)”.")
        }
    }

    private func create(_ arguments: [String: Any], caller: UUID) -> ToolResult {
        guard let agent = store.record(caller) else { return .error("Only agents on the board can add images.") }
        let stored: ImageFiles.Stored
        switch storeFile(arguments, caller: caller) {
        case .success(let found): stored = found
        case .failure(let refusal): return .error(refusal.text)
        }
        let trimmed = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let siblings = store.images.filter { $0.worktree == agent.worktree && $0.organizationID == agent.organizationID }
        let size = ImageRecord.cardSize(for: stored.pixelSize)
        let record = ImageRecord(id: UUID(), worktree: agent.worktree,
                                 name: ImageRecord.uniqueName(trimmed.isEmpty ? "Image" : trimmed, among: siblings),
                                 frame: CGRect(origin: store.origin(near: agent, size: size), size: size),
                                 file: stored.file, pixelSize: stored.pixelSize, organization: agent.organization)
        store.insertImage(record)
        store.bus.connect(caller, record.id)
        delivered[caller, default: [:]][record.id] = Delivered(name: record.name, file: record.file)
        return .text("Added image “\(record.name)” (\(Int(stored.pixelSize.width))×\(Int(stored.pixelSize.height))), connected to you.")
    }

    /// The file at `path`, stored with `ImageFiles`.
    private func storeFile(_ arguments: [String: Any], caller: UUID) -> Result<ImageFiles.Stored, Refusal> {
        let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !path.isEmpty else { return .failure(Refusal(text: "Give the picture's file with `path`.")) }
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: store.record(caller)?.worktree ?? FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
        do {
            return .success(try ImageFiles.store(contentsOf: url, in: store.dataFolder))
        } catch ImageFiles.Failure.tooLarge {
            return .failure(Refusal(text: "\(url.path) is larger than 20 MB."))
        } catch ImageFiles.Failure.notAnImage {
            return .failure(Refusal(text: "\(url.path) isn't an image."))
        } catch {
            return .failure(Refusal(text: "There is no file at \(url.path)."))
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
        for element in store.bus.peers(of: caller, kind: .image) {
            guard let record = store.image(element.id) else { continue }
            let current = Delivered(name: record.name, file: record.file)
            now[record.id] = current
            guard before[record.id] != current else { continue }
            let size = "\(Int(record.pixelSize.width))×\(Int(record.pixelSize.height))"
            if let old = before[record.id] {
                if old.file != current.file {
                    parts.append("Image “\(record.name)” has a new picture (\(size)); see it with image_read.")
                } else {
                    parts.append("Image “\(old.name)” is now called “\(record.name)”.")
                }
            } else {
                parts.append("Image “\(record.name)” (\(size)) is connected to you; see it with image_read.")
            }
        }
        for (id, gone) in before where now[id] == nil {
            parts.append("Image “\(gone.name)” is no longer connected to you.")
        }
        delivered[caller] = now
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: Resolving

    private static let noneConnected = "No image is connected to you. Add one with image_create, or ask the user to connect one by drawing a line between it and your card."

    private struct Refusal: Error {
        let text: String
    }

    private func resolve(_ name: String?, for caller: UUID) -> Result<any BoardElement, Refusal> {
        let images = store.bus.peers(of: caller, kind: .image)
        guard !images.isEmpty else { return .failure(Refusal(text: Self.noneConnected)) }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if let found = images.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return .success(found) }
            return .failure(Refusal(text: "No image named “\(name)” is connected to you. Connected: \(images.map(\.name).joined(separator: ", "))."))
        }
        guard images.count == 1, let only = images.first else {
            return .failure(Refusal(text: "Several images are connected; say which with `image`: \(images.map(\.name).joined(separator: ", "))."))
        }
        return .success(only)
    }
}
