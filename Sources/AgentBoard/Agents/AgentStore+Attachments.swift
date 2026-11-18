import AppKit
import Foundation

/// Files the user pastes or drops into a terminal, handed to its program as paths it can open
/// (agents attach a pasted picture's path as an image).
extension AgentStore {
    /// What the pasteboard holds for a terminal: copied files, else a copied picture.
    static func attachments(on pasteboard: NSPasteboard) -> [ImageSource] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map(ImageSource.file) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [.data(data)] }
        }
        return []
    }

    /// Paths on this store's machine for `sources`: this Mac's files as they are, a picture
    /// without a file saved first; on another host, copies there. What can't be brought (too
    /// large, host unreachable) is left out.
    func attachmentPaths(_ sources: [ImageSource]) async -> [String] {
        var paths: [String] = []
        for source in sources {
            if host == nil, case .file(let url) = source {
                paths.append(url.path)
                continue
            }
            let name = UUID().uuidString.prefix(8) + "-" + {
                if case .file(let url) = source { return url.lastPathComponent }
                return "pasted.png"
            }()
            guard let data = await Task.detached(operation: { Self.data(of: source) }).value else { continue }
            if let files {
                guard data.count <= HostMediaFailure.maximumBytes, let folder = await askHostDataFolder() else { continue }
                let path = folder + "/attachments/" + name
                if await files.write(data, to: path) { paths.append(path) }
            } else {
                let url = dataFolder.appendingPathComponent("attachments/" + name)
                let saved = await Task.detached {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    return (try? data.write(to: url, options: .atomic)) != nil
                }.value
                if saved { paths.append(url.path) }
            }
        }
        return paths
    }

    /// The bytes to carry; a TIFF picture as PNG, which agents read.
    nonisolated private static func data(of source: ImageSource) -> Data? {
        switch source {
        case .file(let url): return try? Data(contentsOf: url, options: .mappedIfSafe)
        case .data(let data):
            guard NSImage(data: data) != nil, data.prefix(4) != Data([0x89, 0x50, 0x4E, 0x47]) else { return data }
            return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        }
    }

    /// Paths as a shell takes them, the way a terminal types a dropped file: special
    /// characters escaped, separated by spaces.
    nonisolated static func typed(_ paths: [String]) -> String {
        paths.map { path in
            path.unicodeScalars.map { " \\'\"()[]{}&;|<>$`!*?#~".unicodeScalars.contains($0) ? "\\" + String($0) : String($0) }.joined()
        }.joined(separator: " ") + (paths.isEmpty ? "" : " ")
    }
}
