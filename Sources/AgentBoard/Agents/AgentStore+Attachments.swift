import AppKit
import CryptoKit
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

    /// The largest file carried to a host.
    static let attachmentLimit = 1024 * 1024 * 1024

    /// Paths on this store's machine for `sources`: this Mac's files as they are, a picture
    /// without a file saved first; on another host, copies there. A copy is named by its
    /// content, so the same file pasted again is found there and not sent twice. While a file
    /// goes, `agent`'s composer shows how far along it is; what can't be brought (a folder, too
    /// large, host unreachable) is left out, and the composer says why.
    func attachmentPaths(_ sources: [ImageSource], for agent: UUID) async -> [String] {
        var paths: [String] = [], missed: [String] = []
        defer { if !missed.isEmpty { composerNotices[agent] = L("Couldn't attach \(missed.joined(separator: ", ")).") } }
        for source in sources {
            if host == nil, case .file(let url) = source {
                paths.append(url.path)
                continue
            }
            let shown: String = if case .file(let url) = source { url.lastPathComponent } else { L("the picture") }
            guard let (data, digest) = await Task.detached(operation: { Self.data(of: source).map { ($0, Self.digest(of: $0)) } }).value,
                  data.count <= Self.attachmentLimit else {
                missed.append(shown)
                continue
            }
            let file: String = if case .file(let url) = source { url.lastPathComponent } else { "pasted.png" }
            let name = digest + "-" + file
            if let files {
                guard let folder = await askHostDataFolder() else {
                    missed.append(shown)
                    continue
                }
                let path = folder + "/attachments/" + name
                if await files.exists(path) {
                    paths.append(path)
                    continue
                }
                let upload = Upload(name: shown)
                uploads[agent, default: []].append(upload)
                let sent = await files.write(data, to: path, piece: Self.attachmentPiece) { [weak self] share in
                    guard let self, let index = uploads[agent]?.firstIndex(where: { $0.id == upload.id }) else { return }
                    uploads[agent]?[index].progress = share
                }
                uploads[agent]?.removeAll { $0.id == upload.id }
                if uploads[agent]?.isEmpty == true { uploads[agent] = nil }
                if sent { paths.append(path) } else { missed.append(shown) }
            } else {
                let url = dataFolder.appendingPathComponent("attachments/" + name)
                let saved = await Task.detached {
                    if FileManager.default.fileExists(atPath: url.path) { return true }
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    return (try? data.write(to: url, options: .atomic)) != nil
                }.value
                if saved { paths.append(url.path) } else { missed.append(shown) }
            }
        }
        return paths
    }

    /// Pieces a file goes to a host in: small enough for its progress to move, large enough
    /// that a big file isn't hundreds of round trips.
    static let attachmentPiece = 4 * 1024 * 1024

    /// What names a copy: the first 16 hex digits of its SHA-256.
    nonisolated static func digest(of data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
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

/// A file on its way to a host, and the share of it sent.
struct Upload: Identifiable, Sendable {
    let id = UUID()
    let name: String
    var progress: Double = 0
}
