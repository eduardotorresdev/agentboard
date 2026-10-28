import AppKit
import CommonCrypto
import Foundation
import Security
import SQLite3

/// An installed Chromium-based browser whose logins can be copied into a profile.
struct ChromiumBrowser: Hashable, Sendable {
    let id: String
    let label: String
    let bundleID: String
    /// Where the browser keeps its profiles, relative to `~/Library/Application Support`.
    let root: String
    /// The Keychain item holding the key that encrypts this browser's cookies.
    let keychainService: String
    let keychainAccount: String

    /// Computed rather than stored, so the struct stays `Sendable`.
    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static let known: [ChromiumBrowser] = [
        ChromiumBrowser(id: "chrome", label: "Google Chrome", bundleID: "com.google.Chrome",
                        root: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        ChromiumBrowser(id: "arc", label: "Arc", bundleID: "company.thebrowser.Browser",
                        root: "Arc/User Data", keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        ChromiumBrowser(id: "brave", label: "Brave", bundleID: "com.brave.Browser",
                        root: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        ChromiumBrowser(id: "edge", label: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                        root: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        ChromiumBrowser(id: "comet", label: "Comet", bundleID: "ai.perplexity.comet",
                        root: "Comet", keychainService: "Comet Safe Storage", keychainAccount: "Comet"),
        ChromiumBrowser(id: "vivaldi", label: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
                        root: "Vivaldi", keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi"),
        ChromiumBrowser(id: "chromium", label: "Chromium", bundleID: "org.chromium.Chromium",
                        root: "Chromium", keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
    ]
}

/// One profile of an installed browser, such as "Default" or "Profile 2".
struct ChromiumProfile: Identifiable, Hashable, Sendable {
    let browser: ChromiumBrowser
    /// The profile's folder name inside the browser's data directory.
    let directory: String
    /// The name the user gave the profile in the browser.
    let name: String
    /// The profile's cookie database.
    let cookies: URL

    var id: String { "\(browser.id)/\(directory)" }
    var title: String { "\(browser.label) (\(name))" }
}

/// Reads the logins of the user's own Chromium-based browsers, on this Mac, for copying into a
/// profile. Cookie values are encrypted with a key kept in the login Keychain; reading them makes
/// macOS ask once per browser.
enum ChromiumImport {
    /// Chromium's cookie-value prefix for AES-128-CBC encryption on macOS.
    private static let encryptedPrefix = Array("v10".utf8)
    /// Chromium 124+ prefixes each decrypted value with a SHA-256 of the cookie's host.
    private static let hostDigestLength = 32
    private static let salt = Array("saltysalt".utf8)
    private static let pbkdf2Rounds: UInt32 = 1003
    /// Google sign-in cookies. Copying them would sign the source browser out of Google.
    private static let googleSignInNames: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDCC", "__Secure-3PSIDCC", "__Secure-3PSIDTS", "__Secure-1PSIDTS",
        "SIDCC", "LSID", "ACCOUNT_CHOOSER", "__Host-GAPS", "OSID",
    ]

    private enum Failure: LocalizedError {
        case noKey(String)
        case denied(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noKey(let label): L("\(label) has no cookie key in the Keychain yet; open it once.")
            case .denied(let label): L("macOS didn't allow reading \(label)'s cookies.")
            case .unreadable(let label): L("Couldn't read \(label)'s cookie database.")
            }
        }
    }

    private static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// Every profile of every installed Chromium browser that has a cookie database, in each
    /// browser's own order.
    static func detect() -> [ChromiumProfile] {
        ChromiumBrowser.known.flatMap { browser -> [ChromiumProfile] in
            let root = applicationSupport.appendingPathComponent(browser.root, isDirectory: true)
            guard let state = localState(in: root),
                  let profiles = state["profile"] as? [String: Any],
                  let infoCache = profiles["info_cache"] as? [String: [String: Any]] else { return [] }
            let order = profiles["profiles_order"] as? [String] ?? []
            return ordered(Array(infoCache.keys), by: order).compactMap { directory in
                guard let cookies = cookieDatabase(in: root, directory: directory) else { return nil }
                let name = (infoCache[directory]?["name"] as? String) ?? directory
                return ChromiumProfile(browser: browser, directory: directory, name: name, cookies: cookies)
            }
        }
    }

    /// Reads and decrypts a profile's cookies, in Playwright's `addCookies` shape. Blocks on the
    /// Keychain, so call it off the main thread.
    static func read(_ profile: ChromiumProfile) throws -> (file: CookieFile, skippedGoogle: Int, undecryptable: Int) {
        let key = try cookieKey(for: profile.browser)

        // Work on a copy: the browser may hold its database open, and the copy must carry the
        // write-ahead log so recent cookies are included.
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBoard-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let copy = workDirectory.appendingPathComponent("Cookies")
        do {
            try copyDatabase(from: profile.cookies, to: copy)
        } catch {
            throw Failure.unreadable(profile.browser.label)
        }

        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(handle) }
        guard opened == SQLITE_OK, let db = handle else { throw Failure.unreadable(profile.browser.label) }

        let hasSameSite = hasColumn("samesite", in: "cookies", db: db)
        let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly"
            + (hasSameSite ? ", samesite" : "") + " FROM cookies"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.unreadable(profile.browser.label)
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [[String: Any]] = []
        var skippedGoogle = 0
        var undecryptable = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = text(statement, 0)
            let name = text(statement, 1)
            if isGoogleSignIn(host: host, name: name) {
                skippedGoogle += 1
                continue
            }
            guard let value = cookieValue(encrypted: blob(statement, 3), plain: text(statement, 2), key: key) else {
                undecryptable += 1
                continue
            }

            let storedPath = text(statement, 4)
            let expiresUTC = sqlite3_column_int64(statement, 5)
            var cookie: [String: Any] = [
                "name": name,
                "value": value,
                "domain": host,
                "path": storedPath.isEmpty ? "/" : storedPath,
                "httpOnly": sqlite3_column_int64(statement, 7) != 0,
                "secure": sqlite3_column_int64(statement, 6) != 0,
            ]
            // Chromium counts microseconds from 1601-01-01; 0 marks a session cookie.
            if expiresUTC != 0 {
                cookie["expires"] = Double(expiresUTC) / 1_000_000.0 - 11_644_473_600.0
            }
            if hasSameSite, let sameSite = sameSiteName(statement, 8) {
                cookie["sameSite"] = sameSite
            }
            cookies.append(cookie)
        }
        return (CookieFile(cookies: cookies, origins: []), skippedGoogle, undecryptable)
    }

    // MARK: - Detection

    private static func localState(in root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The browser's own profile order first, then any profile it left out, by name.
    private static func ordered(_ directories: [String], by order: [String]) -> [String] {
        let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        let listed = Set(order)
        return order.filter { directories.contains($0) } + directories.filter { !listed.contains($0) }.sorted(by: byName)
    }

    private static func cookieDatabase(in root: URL, directory: String) -> URL? {
        let profile = root.appendingPathComponent(directory, isDirectory: true)
        return [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Reading

    /// Copies the database and, when present, its write-ahead log and shared-memory index.
    private static func copyDatabase(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
    }

    private static func hasColumn(_ column: String, in table: String, db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return true }
        }
        return false
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        // The blob pointer must be read before its size.
        guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// Playwright takes `Strict`, `Lax`, or `None`; nil when Chromium doesn't know the policy.
    private static func sameSiteName(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        switch sqlite3_column_int64(statement, column) {
        case 0: return "None"
        case 1: return "Lax"
        case 2: return "Strict"
        default: return nil
        }
    }

    private static func isGoogleSignIn(host: String, name: String) -> Bool {
        let domain = host.lowercased()
        let isGoogle = domain == "google.com" || domain.hasSuffix(".google.com")
        return isGoogle && googleSignInNames.contains(name)
    }

    /// The cookie's plaintext value. nil when the value is encrypted and can't be decrypted.
    private static func cookieValue(encrypted: Data, plain: String, key: Data) -> String? {
        guard encrypted.starts(with: encryptedPrefix) else {
            // Unencrypted cookies keep their value in the plain column.
            if !plain.isEmpty { return plain }
            return encrypted.isEmpty ? "" : nil
        }
        guard let plaintext = decrypt(Data(encrypted.dropFirst(encryptedPrefix.count)), key: key) else { return nil }
        return cookieText(plaintext)
    }

    /// The value as UTF-8, with the host digest dropped when Chromium prepended one.
    private static func cookieText(_ plaintext: Data) -> String? {
        if let text = utf8String(plaintext) { return text }
        guard plaintext.count >= hostDigestLength else { return nil }
        return utf8String(Data(plaintext.dropFirst(hostDigestLength)))
    }

    /// A string only when the bytes are valid UTF-8. `String(decoding:)` would repair bad input,
    /// so the round trip has to match the original bytes.
    private static func utf8String(_ bytes: Data) -> String? {
        let string = String(decoding: bytes, as: UTF8.self)
        return Data(string.utf8) == bytes ? string : nil
    }

    // MARK: - Crypto

    /// The AES key Chromium derives from the browser's Keychain password.
    private static func cookieKey(for browser: ChromiumBrowser) throws -> Data {
        let password = try safeStoragePassword(for: browser)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), pbkdf2Rounds,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.denied(browser.label) }
        return key
    }

    private static func safeStoragePassword(for browser: ChromiumBrowser) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecAttrAccount as String: browser.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { throw Failure.denied(browser.label) }
            return data
        case errSecItemNotFound:
            throw Failure.noKey(browser.label)
        default:
            throw Failure.denied(browser.label)
        }
    }

    /// AES-128-CBC with PKCS#7 padding and a fixed IV of spaces. nil when the data doesn't decrypt.
    private static func decrypt(_ ciphertext: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, ciphertext.count,
                                outBytes.baseAddress, outBytes.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(written))
    }
}
