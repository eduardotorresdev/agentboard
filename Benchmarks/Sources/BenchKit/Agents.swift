import Foundation

public enum FakeAgent {
    /// The FakeAgent executable, built next to the running suite (a dependency of it). From
    /// the executable's own path: under the benchmark plugin, `argv[0]` is relative.
    public static var path: String {
        Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("FakeAgent").path
    }
}
