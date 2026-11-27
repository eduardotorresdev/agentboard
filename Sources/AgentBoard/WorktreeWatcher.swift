import CoreServices
import Foundation

/// Tells when a worktree is added to or removed from one of the repositories, by watching their
/// `.git/worktrees` folders: git run from a terminal inside the board leaves the app active, so
/// it never relists on its own. Lives as long as the app's project store, so it never stops for good.
@MainActor
final class WorktreeWatcher {
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) { self.changed = changed }

    /// Watches the repositories at `paths` (their main checkouts), replacing what was watched.
    func watch(_ paths: [String]) {
        // A checkout whose `.git` is a file (itself a worktree) has its list elsewhere: skipped.
        let gitFolders = paths.map { ($0 as NSString).appendingPathComponent(".git") }.filter {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue
        }.sorted()
        guard gitFolders != watched else { return }
        stop()
        watched = gitFolders
        guard !gitFolders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let changedPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // The index and refs change on every git command; only the worktrees folder counts.
            guard changedPaths.contains(where: { $0.contains("/.git/worktrees") }) else { return }
            MainActor.assumeIsolated { watcher.changed() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, gitFolders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
