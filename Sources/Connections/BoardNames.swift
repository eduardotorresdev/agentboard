import Foundation

/// Names of board elements and worktree titles: what agents and the user call things. They reach
/// agents' prompts and tool listings, so they are cut to one line of visible text.
public enum BoardName {
    public static let maxLength = 60
    public static let maxBytes = 240

    /// One line of visible text within the caps; nil when nothing visible is left (see `DisplayText`).
    public static func clean(_ name: String, maxLength: Int = maxLength, maxBytes: Int = maxBytes) -> String? {
        DisplayText.clean(name, maxLength: maxLength, maxBytes: maxBytes)
    }

    /// `name` cleaned, or why it can't be one: empty, or an id, which would shadow the element
    /// that has it.
    public static func validated(_ name: String) -> Result<String, NameError> {
        guard let clean = clean(name) else { return .failure(.empty) }
        guard UUID(uuidString: clean) == nil else { return .failure(.looksLikeID) }
        return .success(clean)
    }

    /// A tool's optional `name` argument: nil when none was given (or nothing visible), so a
    /// default applies; a failure for an id.
    public static func argument(_ value: Any?) -> Result<String?, NameError> {
        guard let value = value as? String, let clean = clean(value) else { return .success(nil) }
        return validated(clean).map { $0 }
    }

    public enum NameError: Error, CustomStringConvertible {
        case empty, looksLikeID
        public var description: String {
            switch self {
            case .empty: "The name has no visible text."
            case .looksLikeID: "A name can't be an id."
            }
        }
    }

    /// `name` as a valid name, else `fallback`: what a name from outside becomes on its way in.
    public static func named(_ name: String, else fallback: String) -> String {
        (try? validated(name).get()) ?? fallback
    }

    /// For listings: cleaned, quoted, so a name can't pass for list syntax.
    public static func quoted(_ name: String) -> String {
        "“" + (clean(name) ?? "?").replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"") + "”"
    }
}

/// The element `address` names among `elements`: by id first, so a name can't hijack an id, then
/// by name, case-insensitively.
@MainActor
public func findElement<E>(_ address: String, among elements: [E], id: (E) -> UUID, name: (E) -> String) -> E? {
    let given = address.trimmingCharacters(in: .whitespaces)
    let unquoted = given.trimmingCharacters(in: CharacterSet(charactersIn: "“”\""))
    if let uuid = UUID(uuidString: unquoted), let found = elements.first(where: { id($0) == uuid }) { return found }
    // The name as given (it may hold quotes of its own), then without the quotes listings add.
    return elements.first { name($0).caseInsensitiveCompare(given) == .orderedSame }
        ?? elements.first { name($0).caseInsensitiveCompare(unquoted) == .orderedSame }
}

@MainActor
public func findElement(_ address: String, among elements: [any BoardElement]) -> (any BoardElement)? {
    findElement(address, among: elements, id: \.id, name: \.name)
}
