import Foundation

/// Paths as dialogs show them: short and readable. Display only: actions and tooltips keep the
/// full path.
enum DisplayPath {
    /// - Inside `base` (a project or worktree folder): "storefront › web"; inside its
    ///   `-worktrees` folder: "storefront worktrees › fix-login".
    /// - Inside the home folder: "~/agentboard/projects".
    /// - Longer than `maxLength`: the middle folders become "…", keeping the start and the last
    ///   folder ("~/…/fix-login").
    static func short(_ path: String, base: String? = nil, home: String = NSHomeDirectory(), maxLength: Int = 48) -> String {
        let path = trimmed(path)
        if let base = base.map(trimmed), !base.isEmpty {
            let name = (base as NSString).lastPathComponent
            if path == base { return name }
            for (root, label) in [(base, name), (base + "-worktrees", name + " worktrees")] {
                if let rest = relative(path, to: root) { return label + " › " + middle(rest, maxLength: maxLength - label.count - 3) }
            }
        }
        let home = trimmed(home)
        if path == home { return "~" }
        if let rest = relative(path, to: home) { return middle("~/" + rest, maxLength: maxLength) }
        return middle(path, maxLength: maxLength)
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func relative(_ path: String, to root: String) -> String? {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    /// "a/b/c/d" → "a/…/d" when too long; a single long name stays whole.
    private static func middle(_ path: String, maxLength: Int) -> String {
        guard path.count > max(maxLength, 1) else { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // An absolute path keeps its first folder: "/Volumes/…/r", not "/…/r".
        let head = parts.first == "" ? 2 : 1
        guard parts.count > head + 1, let last = parts.last else { return path }
        return (parts.prefix(head) + ["…", last]).joined(separator: "/")
    }
}
