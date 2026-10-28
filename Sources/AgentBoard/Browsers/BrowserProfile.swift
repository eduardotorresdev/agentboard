import Foundation

/// A set of logins a browser card browses with. Each profile keeps its cookies and local storage
/// in one file on disk; cards on the same profile share them, and they survive relaunches.
///
/// A card always has a profile; there is one built-in `Default`, and the developer can add named
/// ones to keep separate logins (a work account and a personal one, two tenants of the same app).
struct BrowserProfile: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String

    /// The profile every card starts on, and the one cards from before profiles existed fall to.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-0000000D0FA1")!
    static let defaultName = "Default"

    static var defaultProfile: BrowserProfile { BrowserProfile(id: defaultID, name: defaultName) }
    var isDefault: Bool { id == Self.defaultID }
}
