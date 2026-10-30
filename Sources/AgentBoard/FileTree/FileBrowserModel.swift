import Foundation
import Observation

/// One entry in a folder.
struct FileEntry: Identifiable, Hashable {
    /// Relative to the worktree.
    let path: String
    let isFolder: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// What a file tree card shows: which folders are open, the file open beside them, and the
/// worktree's git status.
@MainActor
@Observable
final class FileBrowserModel {
    /// What the open file holds.
    enum Content: Equatable {
        case lines([String])
        case binary
        case tooLarge
        case unreadable
    }

    let root: String
    private(set) var expanded: Set<String> = []
    private(set) var children: [String: [FileEntry]] = [:]
    /// Git's letter per changed path (M, A, D, U for untracked), and the folders holding one.
    private(set) var status: [String: Character] = [:]
    private(set) var openFile: String?
    private(set) var content: Content?
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    private(set) var matches: [FileEntry] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    static let maxFileSize = 4 * 1024 * 1024
    /// Folders search doesn't walk into.
    private static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData"]

    init(root: String) {
        self.root = root
        children[""] = Self.list("", in: root)
        refreshStatus()
    }

    /// The visible rows, folders first, with how deep each sits.
    var rows: [(entry: FileEntry, depth: Int)] {
        var result: [(FileEntry, Int)] = []
        func walk(_ path: String, _ depth: Int) {
            for entry in children[path] ?? [] {
                result.append((entry, depth))
                if entry.isFolder, expanded.contains(entry.path) { walk(entry.path, depth + 1) }
            }
        }
        walk("", 0)
        return result
    }

    func toggle(_ folder: String) {
        if expanded.remove(folder) == nil {
            expanded.insert(folder)
            if children[folder] == nil { children[folder] = Self.list(folder, in: root) }
        }
    }

    /// Reads the folders again, and git's status.
    func reload() {
        for path in [""] + expanded { children[path] = Self.list(path, in: root) }
        if let openFile { open(openFile) }
        refreshStatus()
    }

    func open(_ path: String) {
        openFile = path
        content = Self.read(URL(fileURLWithPath: root).appendingPathComponent(path))
    }

    func closeFile() {
        openFile = nil
        content = nil
    }

    private static func list(_ path: String, in root: String) -> [FileEntry] {
        let url = path.isEmpty ? URL(fileURLWithPath: root) : URL(fileURLWithPath: root).appendingPathComponent(path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0 != ".git" && $0 != ".DS_Store" }.map { name in
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isFolder)
            return FileEntry(path: path.isEmpty ? name : path + "/" + name, isFolder: isFolder.boolValue)
        }
        .sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Text files only: a NUL byte in the first few kilobytes marks a binary.
    private static func read(_ url: URL) -> Content {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .unreadable }
        guard size <= maxFileSize else { return .tooLarge }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if data.prefix(8000).contains(0) { return .binary }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return .lines(lines)
    }

    private func refreshStatus() {
        let root = root
        Task {
            let output = await Task.detached { Self.git(["-C", root, "status", "--porcelain", "-uall"]) }.value
            var status: [String: Character] = [:]
            for line in output.split(separator: "\n") where line.count > 3 {
                let code = line.prefix(2)
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                if path.hasPrefix("\""), path.hasSuffix("\""), path.count > 1 { path = String(path.dropFirst().dropLast()) }
                let letter: Character = code == "??" ? "U" : code.contains("D") ? "D" : code.contains("A") ? "A" : "M"
                status[path] = letter
                // Folders show the change they hold.
                var folder = (path as NSString).deletingLastPathComponent
                while !folder.isEmpty {
                    if status[folder] == nil { status[folder] = letter == "U" ? "U" : "M" }
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
            self.status = status
        }
    }

    private func search() {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            matches = []
            return
        }
        let root = root
        searchTask = Task {
            let found = await Task.detached { Self.find(query, in: root) }.value
            guard !Task.isCancelled else { return }
            matches = found
        }
    }

    nonisolated private static func find(_ query: String, in root: String, limit: Int = 300) -> [FileEntry] {
        let rootURL = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var result: [FileEntry] = []
        let prefix = rootURL.standardizedFileURL.path.count + 1
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isFolder, url.lastPathComponent.lowercased().contains(query) else { continue }
            result.append(FileEntry(path: String(url.standardizedFileURL.path.dropFirst(prefix)), isFolder: false))
            if result.count >= limit { break }
        }
        return result
    }

    nonisolated private static func git(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
