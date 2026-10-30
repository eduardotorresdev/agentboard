import AgentRuntime
import Connections
import Foundation
import Observation
import Orchestration

/// The screen a browser card emulates: its size and density, whether it is a touch screen and a
/// mobile browser, and the user agent pages see. Built from one of Playwright's device presets,
/// as is or changed.
struct BrowserDevice: Hashable, Codable {
    /// What the card is named after ("Phone", "Custom").
    var title: String
    /// The Playwright preset it starts from; its user agent applies unless `userAgent` is set.
    var preset: String?
    /// Viewport, in CSS pixels.
    var width: Int
    var height: Int
    /// Device pixels per CSS pixel.
    var scale: Double
    /// Honors the page's viewport meta tag, like a phone's browser.
    var mobile: Bool
    var touch: Bool
    var userAgent: String?

    var viewport: CGSize { CGSize(width: width, height: height) }

    /// One line describing it, e.g. "iPhone 17 · 402 × 681 · 3× · touch".
    var summary: String {
        var parts = ["\(width) × \(height)", "\(scale.formatted())×"]
        if let preset { parts.insert(preset, at: 0) }
        if touch { parts.append(L("touch")) }
        return parts.joined(separator: " · ")
    }

    /// How the sidecar takes it.
    var wire: [String: Any] {
        var wire: [String: Any] = ["width": width, "height": height, "scale": scale, "mobile": mobile, "touch": touch]
        if let preset { wire["preset"] = preset }
        if let userAgent { wire["userAgent"] = userAgent }
        return wire
    }

    static let phone = BrowserDevice(title: "Phone", preset: "iPhone 17", width: 402, height: 681, scale: 3, mobile: true, touch: true)
    static let tablet = BrowserDevice(title: "Tablet", preset: "iPad Pro 11", width: 834, height: 1194, scale: 2, mobile: true, touch: true)
    static let desktop = BrowserDevice(title: "Desktop", preset: "Desktop Safari", width: 1280, height: 720, scale: 2, mobile: false, touch: false)
    static let presets = [phone, tablet, desktop]
    /// The title of a device the developer described themselves.
    static let customTitle = "Custom"

    /// What a preset gives, for the menus.
    var help: String {
        switch self {
        case .phone: L("iPhone 17 screen with touch, 402 × 681.")
        case .tablet: L("iPad Pro 11″ screen with touch, 834 × 1194.")
        case .desktop: L("Desktop Safari window, 1280 × 720.")
        default: summary
        }
    }

    /// A stored device: JSON, or the preset name cards were saved with before custom devices.
    init?(stored: String) {
        if let device = try? JSONDecoder().decode(BrowserDevice.self, from: Data(stored.utf8)) {
            self = device
        } else if let preset = Self.presets.first(where: { $0.preset == stored }) {
            self = preset
        } else {
            return nil
        }
    }

    init(title: String, preset: String?, width: Int, height: Int, scale: Double, mobile: Bool, touch: Bool, userAgent: String? = nil) {
        self.title = title
        self.preset = preset
        self.width = width
        self.height = height
        self.scale = scale
        self.mobile = mobile
        self.touch = touch
        self.userAgent = userAgent
    }

    var stored: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// A persisted browser card.
struct BrowserRecord: Identifiable, Hashable {
    let id: UUID
    let worktree: String
    /// How the card is titled and how connected agents address it; unique in its worktree.
    var name: String
    var device: BrowserDevice
    /// The last page it showed, reopened on launch.
    var url: String
    var frame: CGRect
    /// The profile it browses with (its logins); `BrowserProfile.defaultID` unless changed.
    var profile: UUID = BrowserProfile.defaultID
    /// The organization it was added in; older cards are in the default one.
    var organization: UUID = OrganizationHome.defaultID
}

/// A browser card's live page in the sidecar.
struct BrowserPage: Equatable {
    enum Phase: Equatable {
        case opening
        case open
        case failed(String)
    }

    var phase = Phase.opening
    /// The Core Animation context drawing the page, once WebKit reports it.
    var contextID: UInt32?
    /// The size WebKit draws the page at, in points.
    var surface: CGSize?
    var url = ""
    var title = ""
}

/// Owns every browser card and its page. Pages live in one shared sidecar (Playwright's WebKit,
/// one context per card); a page opens the first time its card is shown or an agent drives it.
@MainActor
@Observable
final class BrowserStore {
    private(set) var browsers: [BrowserRecord] = []
    @ObservationIgnored private(set) var pages: [UUID: BrowserPage] = [:]
    /// Called with the card's id when its page changed, so the board redraws it.
    @ObservationIgnored var onPageChange: ((UUID) -> Void)?

    @ObservationIgnored private let database: Database?
    @ObservationIgnored let host = BrowserHost()
    @ObservationIgnored private weak var agents: AgentStore?
    @ObservationIgnored private var opening: [UUID: Task<Void, Error>] = [:]
    /// Pointer moves waiting for the one in flight, per card: only the latest is sent.
    @ObservationIgnored private var pendingMoves: [UUID: [String: Any]] = [:]
    @ObservationIgnored private var movesInFlight: Set<UUID> = []

    /// Every profile cards can browse with, Default first.
    private(set) var profiles: [BrowserProfile] = [.defaultProfile]

    init(database: Database?) {
        self.database = database
        browsers = (try? database?.browsers()) ?? []
        let saved = (try? database?.browserProfiles()) ?? []
        profiles = [.defaultProfile] + saved.filter { !$0.isDefault }
        host.onEvent = { [weak self] event in self?.received(event) }
        host.onStateChange = { [weak self] state in self?.hostChanged(state) }
    }

    func profile(_ id: UUID) -> BrowserProfile {
        profiles.first { $0.id == id } ?? .defaultProfile
    }

    /// Where a profile keeps its cookies and local storage.
    private func profileState(_ id: UUID) -> URL {
        let folder = BrowserHost.folder.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString).json")
    }

    /// Adds a profile with a unique name and returns it.
    @discardableResult
    func addProfile(named name: String) -> BrowserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = BrowserProfile(id: UUID(), name: Self.uniqueProfileName(trimmed.isEmpty ? L("Profile") : trimmed, among: profiles))
        profiles.append(profile)
        try? database?.saveBrowserProfile(profile)
        return profile
    }

    /// Moves a card to another profile; its page reopens with that profile's logins.
    func setProfile(_ profileID: UUID, for id: UUID) {
        guard let index = browsers.firstIndex(where: { $0.id == id }), browsers[index].profile != profileID else { return }
        browsers[index].profile = profileID
        try? database?.saveBrowser(browsers[index])
        agents?.elementsChanged()
        guard pages[id] != nil, opening[id] == nil else { return }
        pages[id]?.phase = .opening
        pages[id]?.contextID = nil
        pages[id]?.surface = nil
        onPageChange?(id)
        let task = Task { @MainActor in
            defer { onPageChange?(id) }
            do {
                _ = try await host.request("setProfile", ["block": id.uuidString, "profileState": profileState(profileID).path])
                pages[id]?.phase = .open
            } catch {
                pages[id]?.phase = .failed(error.localizedDescription)
                throw error
            }
        }
        opening[id] = task
        Task { _ = try? await task.value; opening[id] = nil }
    }

    private static func uniqueProfileName(_ base: String, among others: [BrowserProfile]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    struct ImportResult: Sendable {
        let cookies: Int
        var origins: Int = 0
        /// Google sign-in cookies left out so the source browser stays signed in.
        var skippedGoogle: Int = 0
    }

    /// The profiles of every installed Chromium browser cookies can be imported from.
    func chromiumProfiles() -> [ChromiumProfile] {
        ChromiumImport.detect()
    }

    /// Reads and decrypts a Chromium profile's cookies and merges them into one of ours. The
    /// read blocks on the Keychain (macOS asks once), so it runs off the main thread.
    @discardableResult
    func importFromBrowser(_ source: ChromiumProfile, into profileID: UUID) async throws -> ImportResult {
        let path = profileState(profileID)
        let result = try await Task.detached(priority: .userInitiated) {
            let read = try ChromiumImport.read(source)
            guard !read.file.cookies.isEmpty else { throw ImportError.noCookies }
            let existing = (try? CookieFile.read(path)) ?? CookieFile(cookies: [], origins: [])
            try existing.merging(read.file).write(to: path)
            return ImportResult(cookies: read.file.cookies.count, skippedGoogle: read.skippedGoogle)
        }.value
        reloadProfile(profileID)
        return result
    }

    enum ImportError: LocalizedError {
        case unreadable
        case noCookies

        var errorDescription: String? {
            switch self {
            case .unreadable: L("That file isn't a cookie export AgentBoard can read.")
            case .noCookies: L("No cookies were found in that file.")
            }
        }
    }

    /// Imports cookies and local storage from an exported JSON file into a profile, merging them
    /// with what the profile already has. Accepts a Playwright `storageState` file or a bare
    /// array of cookies (what most "export cookies" extensions produce).
    @discardableResult
    func importCookieFile(_ url: URL, into profileID: UUID) throws -> ImportResult {
        let incoming = try CookieFile.read(url)
        guard !incoming.cookies.isEmpty || !incoming.origins.isEmpty else { throw ImportError.noCookies }
        let path = profileState(profileID)
        let existing = (try? CookieFile.read(path)) ?? CookieFile(cookies: [], origins: [])
        let merged = existing.merging(incoming)
        try merged.write(to: path)
        reloadProfile(profileID)
        return ImportResult(cookies: incoming.cookies.count, origins: incoming.origins.count)
    }

    /// Reopens every open card on a profile so it picks up the profile's new cookies.
    func reloadProfile(_ profileID: UUID) {
        for record in browsers where record.profile == profileID && pages[record.id] != nil && opening[record.id] == nil {
            pages[record.id]?.phase = .opening
            pages[record.id]?.contextID = nil
            onPageChange?(record.id)
            let id = record.id
            let task = Task { @MainActor in
                defer { onPageChange?(id) }
                do {
                    _ = try await host.request("setProfile", ["block": id.uuidString, "profileState": profileState(profileID).path])
                    pages[id]?.phase = .open
                } catch {
                    pages[id]?.phase = .failed(error.localizedDescription)
                    throw error
                }
            }
            opening[id] = task
            Task { _ = try? await task.value; opening[id] = nil }
        }
    }

    var ids: Set<UUID> { Set(browsers.map(\.id)) }

    /// Puts the cards on `agents`' board: lines can reach them and agents get the browser tools.
    func attach(to agents: AgentStore) {
        self.agents = agents
        agents.browserTools = BrowserTools(store: self, agents: agents)
        agents.elementSources[ElementKind.browser.rawValue] = { [weak self] in self?.elementInfos ?? [] }
        agents.elementsChanged()
    }

    /// The cards as the core keeps them: lines reach them, and agents see them in `list_peers`.
    private var elementInfos: [ElementInfo] {
        browsers.map { record in
            let element = BrowserElement(id: record.id, store: self)
            return ElementInfo(id: record.id, name: record.name, kind: ElementKind.browser.rawValue, detail: element.detail,
                               worktree: record.worktree, frame: record.frame)
        }
    }

    func browsers(in worktree: String) -> [BrowserRecord] {
        let organization = agents?.organizationID ?? OrganizationHome.defaultID
        return browsers.filter { $0.worktree == worktree && $0.organization == organization }
    }

    func record(_ id: UUID) -> BrowserRecord? {
        browsers.first { $0.id == id }
    }

    /// The card's frame for a page shown at `scale` of its viewport.
    static func frame(for device: BrowserDevice, at origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: (device.viewport.width * scale).rounded() + CardMetrics.inset * 2,
               height: (device.viewport.height * scale).rounded() + CardMetrics.titleHeight + CardMetrics.inset)
    }

    /// The scale a card shows its page at.
    static func scale(of record: BrowserRecord) -> CGFloat {
        CardMetrics.content(of: record.frame).width / record.device.viewport.width
    }

    /// The scale a new card shows its page at: actual size when it fits a laptop screen.
    static func initialScale(for device: BrowserDevice) -> CGFloat {
        min(1, 960 / device.viewport.width, 720 / device.viewport.height)
    }

    @discardableResult
    func add(_ device: BrowserDevice, to worktree: String, at origin: CGPoint, organization: UUID? = nil,
             named name: String? = nil) -> BrowserRecord {
        let organization = organization ?? agents?.organizationID ?? OrganizationHome.defaultID
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let siblings = browsers.filter { $0.worktree == worktree && $0.organization == organization }
        let record = BrowserRecord(id: UUID(), worktree: worktree,
                                   name: Self.uniqueName(trimmed.isEmpty ? device.title : trimmed, among: siblings),
                                   device: device, url: "",
                                   frame: Self.frame(for: device, at: origin, scale: Self.initialScale(for: device)),
                                   organization: organization)
        browsers.append(record)
        try? database?.saveBrowser(record)
        agents?.elementsChanged()
        return record
    }

    func remove(_ id: UUID) {
        agents?.dropConnections(touching: id)
        browsers.removeAll { $0.id == id }
        opening[id]?.cancel()
        opening[id] = nil
        if pages.removeValue(forKey: id) != nil { host.post("close", ["block": id.uuidString]) }
        try? database?.deleteBrowser(id: id)
        agents?.elementsChanged()
    }

    func raise(_ id: UUID) {
        guard let index = browsers.firstIndex(where: { $0.id == id }), index != browsers.count - 1 else { return }
        browsers.append(browsers.remove(at: index))
    }

    func setFrame(_ frame: CGRect, for id: UUID, persist: Bool) {
        guard let index = browsers.firstIndex(where: { $0.id == id }) else { return }
        browsers[index].frame = frame
        if persist {
            try? database?.saveBrowser(browsers[index])
            agents?.elementsChanged()
        }
    }

    /// Gives the card another device. The page moves to a new context with it, keeping its
    /// address, cookies and local storage; a card still named after its old device takes the new
    /// one's name.
    func setDevice(_ device: BrowserDevice, for id: UUID) {
        guard let index = browsers.firstIndex(where: { $0.id == id }), browsers[index].device != device else { return }
        let old = browsers[index]
        let scale = min(Self.scale(of: old), Self.initialScale(for: device))
        browsers[index].device = device
        browsers[index].frame = Self.frame(for: device, at: old.frame.origin, scale: scale)
        let named = old.name == old.device.title || old.name.range(of: "^\(NSRegularExpression.escapedPattern(for: old.device.title)) \\d+$",
                                                                     options: .regularExpression) != nil
        if named, device.title != old.device.title {
            browsers[index].name = Self.uniqueName(device.title, among: browsers(in: old.worktree).filter { $0.id != id })
        }
        try? database?.saveBrowser(browsers[index])
        agents?.elementsChanged()
        guard pages[id] != nil, opening[id] == nil else { return }
        pages[id]?.phase = .opening
        pages[id]?.contextID = nil
        pages[id]?.surface = nil
        onPageChange?(id)
        let task = Task { @MainActor in
            defer { onPageChange?(id) }
            do {
                _ = try await host.request("reconfigure", ["block": id.uuidString, "device": device.wire])
                pages[id]?.phase = .open
            } catch {
                pages[id]?.phase = .failed(error.localizedDescription)
                throw error
            }
        }
        opening[id] = task
        Task {
            _ = try? await task.value
            opening[id] = nil
        }
    }

    @ObservationIgnored private var playwrightDevices: [BrowserDevice]?

    /// Every Playwright device preset WebKit can emulate, to start a custom device from.
    func playwrightPresets() async -> [BrowserDevice] {
        if let playwrightDevices { return playwrightDevices }
        guard let list = (try? await host.request("devices", [:]))?["devices"] as? [[String: Any]] else { return Self.presetsFallback }
        let devices = list.compactMap { item -> BrowserDevice? in
            guard let name = item["name"] as? String, let width = item["width"] as? Int, let height = item["height"] as? Int else { return nil }
            return BrowserDevice(title: name, preset: name, width: width, height: height, scale: item["scale"] as? Double ?? 1,
                                 mobile: item["mobile"] as? Bool ?? false, touch: item["touch"] as? Bool ?? false,
                                 userAgent: item["userAgent"] as? String)
        }
        playwrightDevices = devices
        return devices
    }

    private static var presetsFallback: [BrowserDevice] {
        BrowserDevice.presets.map { var device = $0; device.title = $0.preset ?? $0.title; return device }
    }

    private static func uniqueName(_ base: String, among others: [BrowserRecord]) -> String {
        let taken = Set(others.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Pages

    /// Opens the card's page if it isn't open or opening.
    func show(_ id: UUID) {
        guard pages[id] == nil else { return }
        Task { try? await ready(id) }
    }

    /// Opens a page that failed or crashed again.
    func reopen(_ id: UUID) {
        guard case .failed = pages[id]?.phase else { return }
        host.retry()
        pages[id] = nil
        opening[id] = nil
        show(id)
    }

    /// Waits until the card's page is open, opening it if needed.
    func ready(_ id: UUID) async throws {
        if pages[id]?.phase == .open { return }
        if case .failed(let reason) = pages[id]?.phase { throw BrowserHost.Failure(message: reason) }
        if let task = opening[id] { return try await task.value }
        guard let record = record(id) else { throw BrowserHost.Failure(message: "This browser is no longer on the board.") }
        pages[id] = BrowserPage()
        onPageChange?(id)
        let task = Task { @MainActor in
            do {
                _ = try await host.request("open", ["block": id.uuidString, "device": record.device.wire, "url": record.url,
                                                     "profileState": profileState(record.profile).path])
                guard pages[id] != nil else { return }
                pages[id]?.phase = .open
                if pages[id]?.url.isEmpty == true { pages[id]?.url = record.url }
                onPageChange?(id)
            } catch {
                guard pages[id] != nil else { throw error }
                pages[id]?.phase = .failed(error.localizedDescription)
                onPageChange?(id)
                throw error
            }
        }
        opening[id] = task
        defer { opening[id] = nil }
        try await task.value
    }

    /// Goes to what the developer typed in the address field.
    func navigate(_ id: UUID, to address: String) {
        Task { _ = try? await call("navigate", on: id, ["url": address]) }
    }

    func go(_ action: String, on id: UUID) {
        Task { _ = try? await call("navigate", on: id, ["action": action]) }
    }

    /// Runs a sidecar method on the card's page, opening it first.
    func call(_ method: String, on id: UUID, _ params: [String: Any]) async throws -> [String: Any] {
        try await ready(id)
        var params = params
        params["block"] = id.uuidString
        return try await host.request(method, params)
    }

    /// The developer's pointer and keys on the card, in page coordinates.
    func input(_ id: UUID, _ params: [String: Any]) {
        guard pages[id]?.phase == .open else { return }
        var params = params
        params["block"] = id.uuidString
        let kind = params["kind"] as? String
        if kind == "move" || kind == "wheel" {
            // Moves and scrolls come faster than WebKit takes them: while one is in flight, keep
            // only the latest move, and add scrolls up.
            guard !movesInFlight.contains(id) else {
                if kind == "wheel", let waiting = pendingMoves[id], waiting["kind"] as? String == "wheel" {
                    for axis in ["dx", "dy"] {
                        params[axis] = (waiting[axis] as? CGFloat ?? 0) + (params[axis] as? CGFloat ?? 0)
                    }
                } else if kind == "move", pendingMoves[id]?["kind"] as? String == "wheel" {
                    return
                }
                pendingMoves[id] = params
                return
            }
            movesInFlight.insert(id)
            Task {
                _ = try? await host.request("input", params)
                movesInFlight.remove(id)
                if let next = pendingMoves.removeValue(forKey: id) { input(id, next) }
            }
            return
        }
        pendingMoves[id] = nil
        host.post("input", params)
    }

    /// The text selected on the card's page.
    func copySelection(_ id: UUID) async -> String? {
        guard pages[id]?.phase == .open else { return nil }
        return (try? await host.request("copySelection", ["block": id.uuidString]))?["text"] as? String
    }

    // MARK: Sidecar

    private func received(_ event: [String: Any]) {
        guard let block = (event["block"] as? String).flatMap(UUID.init(uuidString:)), pages[block] != nil else { return }
        switch event["event"] as? String {
        case "surface":
            pages[block]?.contextID = (event["contextID"] as? NSNumber)?.uint32Value
            if let width = event["width"] as? Double, let height = event["height"] as? Double {
                pages[block]?.surface = CGSize(width: width, height: height)
            }
        case "state":
            let url = event["url"] as? String ?? ""
            pages[block]?.url = url
            pages[block]?.title = event["title"] as? String ?? ""
            if let index = browsers.firstIndex(where: { $0.id == block }), browsers[index].url != url, !url.isEmpty, url != "about:blank" {
                browsers[index].url = url
                try? database?.saveBrowser(browsers[index])
            }
        case "crashed":
            pages[block]?.phase = .failed(L("The page crashed. Click to reload it."))
            pages[block]?.contextID = nil
        default:
            return
        }
        onPageChange?(block)
    }

    private func hostChanged(_ state: BrowserHost.State) {
        if case .failed(let reason) = state {
            for id in pages.keys {
                pages[id]?.phase = .failed(reason)
                pages[id]?.contextID = nil
            }
        }
        pages.keys.forEach { onPageChange?($0) }
    }

    /// What the card says over its page while it isn't showing one, or nil.
    func status(of id: UUID) -> String? {
        switch pages[id]?.phase {
        case .open: nil
        case .failed(let reason): reason
        case .opening, nil:
            if case .preparing(let step) = host.state { step } else { L("Opening…") }
        }
    }
}

/// A browser as the message bus sees it: reachable along lines, driven with the browser tools.
@MainActor
final class BrowserElement: BoardElement {
    let id: UUID
    private weak var store: BrowserStore?

    init(id: UUID, store: BrowserStore) {
        self.id = id
        self.store = store
    }

    var name: String { store?.record(id)?.name ?? "" }
    var kind: ElementKind { .browser }

    var detail: String? {
        guard let record = store?.record(id) else { return nil }
        let profile = store?.profile(record.profile)
        let suffix = profile.map { $0.isDefault ? "" : ", profile \($0.name)" } ?? ""
        return "\(record.device.title): \(record.device.summary)\(suffix)"
    }
}
