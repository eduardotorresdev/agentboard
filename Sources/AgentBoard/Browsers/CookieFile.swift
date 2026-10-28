import Foundation

/// A profile's saved logins on disk, in Playwright's `storageState` shape: cookies and, per
/// origin, its local storage. Used to read an exported cookie file, merge it with what a profile
/// already has, and write it back for the sidecar to load.
struct CookieFile {
    var cookies: [[String: Any]]
    var origins: [[String: Any]]

    /// Reads a `storageState` file, or a bare array of cookies (what most "export cookies"
    /// browser extensions produce). Cookies are normalized to Playwright's field names.
    static func read(_ url: URL) throws -> CookieFile {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let rawCookies: [[String: Any]]
        var origins: [[String: Any]] = []
        if let state = object as? [String: Any] {
            rawCookies = (state["cookies"] as? [[String: Any]]) ?? []
            origins = (state["origins"] as? [[String: Any]]) ?? []
        } else if let array = object as? [[String: Any]] {
            rawCookies = array
        } else {
            throw BrowserStore.ImportError.unreadable
        }
        return CookieFile(cookies: rawCookies.compactMap(normalize), origins: origins)
    }

    /// A cookie in Playwright's shape (`name`, `value`, `domain`, `path`, …) from whatever an
    /// export used, or nil when it has no name or domain to place it by.
    private static func normalize(_ cookie: [String: Any]) -> [String: Any]? {
        guard let name = cookie["name"] as? String else { return nil }
        let host = (cookie["domain"] ?? cookie["host"] ?? cookie["hostKey"]) as? String
        guard let domain = host, !domain.isEmpty else { return nil }
        var result: [String: Any] = [
            "name": name,
            "value": cookie["value"] as? String ?? "",
            "domain": domain,
            "path": cookie["path"] as? String ?? "/",
        ]
        if let expires = expiry(cookie["expires"] ?? cookie["expirationDate"] ?? cookie["expiry"]) { result["expires"] = expires }
        result["httpOnly"] = asBool(cookie["httpOnly"]) ?? false
        result["secure"] = asBool(cookie["secure"]) ?? false
        if let sameSite = sameSite(cookie["sameSite"]) { result["sameSite"] = sameSite }
        return result
    }

    private static func expiry(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: number > 0 ? number : nil
        case let number as Int: number > 0 ? Double(number) : nil
        case let string as String: Double(string)
        default: nil
        }
    }

    private static func asBool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: bool
        case let number as Int: number != 0
        default: nil
        }
    }

    /// Playwright takes `Strict`, `Lax`, or `None`.
    private static func sameSite(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.lowercased() else { return nil }
        switch raw {
        case "strict": return "Strict"
        case "lax": return "Lax"
        case "none", "no_restriction", "unspecified": return "None"
        default: return nil
        }
    }

    /// `other`'s cookies and origins laid over these: a cookie or origin in both is replaced by
    /// `other`'s. Cookies are keyed by name, domain, and path, the way browsers identify them.
    func merging(_ other: CookieFile) -> CookieFile {
        func cookieKey(_ c: [String: Any]) -> String {
            "\(c["name"] as? String ?? "")\u{1}\(c["domain"] as? String ?? "")\u{1}\(c["path"] as? String ?? "/")"
        }
        var cookiesByKey = Dictionary(cookies.map { (cookieKey($0), $0) }, uniquingKeysWith: { _, last in last })
        for cookie in other.cookies { cookiesByKey[cookieKey(cookie)] = cookie }
        var originsByKey = Dictionary(origins.compactMap { origin -> (String, [String: Any])? in
            (origin["origin"] as? String).map { ($0, origin) }
        }, uniquingKeysWith: { _, last in last })
        for origin in other.origins where origin["origin"] is String {
            originsByKey[origin["origin"] as! String] = origin
        }
        return CookieFile(cookies: Array(cookiesByKey.values), origins: Array(originsByKey.values))
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state: [String: Any] = ["cookies": cookies, "origins": origins]
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: url, options: .atomic)
        // The file holds the profile's logins: keep it to this user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
