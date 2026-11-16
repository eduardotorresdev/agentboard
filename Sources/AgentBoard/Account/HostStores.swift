import AgentRuntime
import Foundation
import Observation
import Orchestration

/// One `AgentStore` per host: this Mac's, and one for each of the account's hosts in use, made
/// the first time something of that host is needed and connected through the account server's
/// relay (see docs/hosts.md).
@MainActor
@Observable
final class HostStores {
    let local: AgentStore
    let account: AccountStore
    private(set) var remote: [UUID: AgentStore] = [:]
    /// Gives a new host's store what the app gave this Mac's (its tools).
    @ObservationIgnored var prepare: ((AgentStore) -> Void)?
    /// Each host's home folder, asked once (tests give their own).
    @ObservationIgnored var homes: [UUID: String] = [:]
    /// The home whose skills and MCP servers go to each host the first time it answers after
    /// launch (see `HostSync`); nil copies nothing unasked.
    @ObservationIgnored var syncHome: URL?
    @ObservationIgnored private var synced: Set<UUID> = []
    /// How the sync to each host is going or went, for its row in the account menu.
    private(set) var syncNotes: [UUID: String] = [:]
    /// The host whose first sync waits for the user's word (see `answerSync`).
    private(set) var syncQuestion: UUID?
    @ObservationIgnored private let connect: (UUID) -> @Sendable () -> Result<CoreClient, CoreClient.Failure>
    @ObservationIgnored private let channels = Channels()
    /// Opens a channel to a host straight to it, or gives nothing: what `retryDirect` tries.
    @ObservationIgnored var openDirect: (UUID) async -> Int32? = { _ in nil }
    @ObservationIgnored private var retrying: Task<Void, Never>?
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// Opens a channel to a host as this Mac, carrying what is named.
    typealias Opener = @Sendable (UUID, HostChannel.Carrying) -> HostChannel.Opened
    @ObservationIgnored private let open: Opener
    /// The hosts that answer but don't trust this Mac's key yet, and how many boards each trusts.
    private(set) var waiting: [UUID: Int] = [:]
    /// Each host's trusted and pending boards, as last listed by a host that trusts this Mac.
    private(set) var boards: [UUID: Boards] = [:]
    /// Seconds between a waiting board's tries, and between listings (see "Board identity").
    var boardInterval: Double {
        get { channels.lock.withLock { channels.interval } }
        set { channels.lock.withLock { channels.interval = newValue } }
    }

    struct Boards: Equatable {
        struct Board: Equatable, Identifiable {
            var key: String
            /// What that computer calls itself: anyone's words, shown without control characters.
            var name: String
            var id: String { key }
            var fingerprint: String { AccountStore.fingerprint(of: key) }
        }
        var trusted: [Board] = []
        var pending: [Board] = []

        /// From a host's answer to `{"list":{}}`.
        init?(_ answer: Data?) {
            guard let answer, let lists = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
                  let trusted = lists["trusted"] as? [[String: Any]], let pending = lists["pending"] as? [[String: Any]] else { return nil }
            let boards = { (entries: [[String: Any]]) in
                entries.compactMap { entry in (entry["key"] as? String).map { Board(key: $0, name: Self.shown(entry["name"] as? String ?? "")) } }
            }
            self.trusted = boards(trusted)
            self.pending = boards(pending)
        }

        /// A name as it may be shown: no control or invisible formatting characters, 64 at most.
        static func shown(_ name: String) -> String {
            String(String.UnicodeScalarView(name.unicodeScalars.filter { ![.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }).prefix(64))
        }

        /// One request on a `boards` channel: `list`, or `trust`/`forget` with a key.
        static func request(_ verb: String, key: String? = nil) -> Data {
            (try? JSONSerialization.data(withJSONObject: [verb: key.map { ["key": $0] } ?? [:]])) ?? Data()
        }
    }

    /// What the threads that connect share with the main actor.
    private final class Channels: @unchecked Sendable {
        let lock = NSLock()
        /// Channels `retryDirect` opened, for the next connection to each host.
        var ready: [UUID: Int32] = [:]
        var took: (@Sendable (UUID, HostChannel.Path) -> Void)?
        /// When each host last said it doesn't trust this Mac yet.
        var refused: [UUID: Date] = [:]
        var interval: Double = 30
        var heard: (@Sendable (UUID, HostChannel.Opened) -> Void)?
    }

    /// `connect` gives how a host's core is reached (through `open` by default; another in
    /// tests), and `open` how a channel to a host is opened (`HostChannel.open` as the account
    /// says by default).
    init(local: AgentStore, account: AccountStore,
         connect: ((UUID) -> @Sendable () -> Result<CoreClient, CoreClient.Failure>)? = nil, open: Opener? = nil) {
        self.local = local
        self.account = account
        let channels = channels
        let opener: Opener = open ?? { [weak account] host, carrying in
            // Read at each attempt: the token and the host's key and presence change.
            let target = DispatchQueue.main.sync { MainActor.assumeIsolated { account?.channel(to: host) } }
            guard let target else { return .failed }
            return HostChannel.open(server: target.server, token: target.token, host: host, hostKey: target.key, board: target.board, carrying: carrying,
                                    addresses: target.addresses, took: { path in if case .core = carrying { channels.took?(host, path) } })
        }
        // Whatever a host says of this Mac is heard, whoever asked.
        self.open = { host, carrying in
            let opened = opener(host, carrying)
            channels.lock.withLock { if case .pending = opened { channels.refused[host] = Date() } else if opened != .failed { channels.refused[host] = nil } }
            channels.heard?(host, opened)
            return opened
        }
        let asking = self.open
        let given = connect ?? { host in
            {
                // A waiting board asks again every 30 seconds, not as often as a lost one reconnects.
                if let refused = channels.lock.withLock({ channels.refused[host] }), refused.timeIntervalSinceNow > -channels.lock.withLock({ channels.interval }) { return .failure(.noCore) }
                guard let channel = asking(host, .core).channel else { return .failure(.noCore) }
                return CoreClient.open(on: channel)
            }
        }
        self.connect = { host in
            let connect = given(host)
            return {
                // A direct channel opened meanwhile is the one to use.
                guard let direct = channels.lock.withLock({ channels.ready.removeValue(forKey: host) }) else { return connect() }
                channels.took?(host, .direct)
                return CoreClient.open(on: direct)
            }
        }
        channels.took = { [weak self] host, path in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remote[host]?.hostPath = path } }
        }
        channels.heard = { [weak self] host, opened in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(opened, from: host) } }
        }
        listing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(channels.lock.withLock { channels.interval }))
                guard let self else { return }
                for (host, store) in remote where store.core != nil { await listBoards(of: host) }
            }
        }
        account.onSignOut = { [weak self] in
            self?.remote.values.forEach { $0.quit() }
            self?.waiting = [:]
            self?.knocked = [:]
            self?.boards = [:]
            self?.remote = [:]
            self?.homes = [:]
            self?.synced = []
            self?.syncNotes = [:]
            self?.syncQuestion = nil
        }
        account.onHosts = { [weak self] in
            self?.remote.values.forEach { $0.explainDown() }
            self?.knock()
        }
        guard connect == nil else { return }
        openDirect = { [weak account] host in
            guard let target = account?.channel(to: host), !target.addresses.isEmpty else { return nil }
            return await Task.detached {
                var path: HostChannel.Path?
                // shortcut: a try that fails opens (and drops) a relayed channel, as `open` falls back to it; a direct-only `open` would spare that.
                guard let channel = HostChannel.open(server: target.server, token: target.token, host: host, hostKey: target.key, board: target.board,
                                                     addresses: target.addresses, timeout: 5, took: { path = $0 }).channel else { return nil }
                if case .direct = path { return channel }
                close(channel)
                return nil
            }.value
        }
        retrying = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.retryDirect()
            }
        }
    }

    deinit {
        retrying?.cancel()
        listing?.cancel()
    }

    /// When each host was last asked, unprompted, whether it trusts this Mac.
    @ObservationIgnored private var knocked: [UUID: Date] = [:]

    /// Pairing without the menu or a worktree: a host online that never let this Mac in is
    /// asked once, so this Mac shows there as waiting, and again every `boardInterval` while it
    /// waits. Called whenever the hosts were refreshed; a host with a store asks by itself.
    private func knock() {
        for host in account.hosts {
            guard host.online, !account.identityChanged(host.id) else {
                // Gone: no more asking, and once more when it is back.
                knocked[host.id] = nil
                if waiting[host.id] != nil { waiting[host.id] = nil }
                continue
            }
            let due = waiting[host.id] != nil ? knocked[host.id].map { $0.timeIntervalSinceNow <= 1 - boardInterval } ?? true
                : knocked[host.id] == nil && !account.wasTrusted(by: host.id)
            guard due, remote[host.id] == nil else { continue }
            knocked[host.id] = Date()
            Task { await listBoards(of: host.id) }
        }
    }

    private func heard(_ opened: HostChannel.Opened, from host: UUID) {
        switch opened {
        case .pending(let trusted):
            if waiting[host] != trusted { waiting[host] = trusted }
            boards[host] = nil
        case .channel:
            if waiting[host] != nil { waiting[host] = nil }
            account.noteTrusted(by: host)
        case .failed: return
        }
        remote[host]?.explainDown()
    }

    /// For screenshots of a build under test (see docs/core.md): what only a host's answer
    /// causes, on the account's first host.
    func showSample() {
        guard let host = account.hosts.first?.id, let own = account.boardPublicKey else { return }
        if DebugShow.items.contains("host-waiting") { waiting[host] = 1 }
        if DebugShow.items.contains("host-approval") {
            let other = Data(repeating: 7, count: 32).base64EncodedString(), asking = Data(repeating: 9, count: 32).base64EncodedString()
            boards[host] = Boards(try? JSONSerialization.data(withJSONObject: [
                "trusted": [["key": own, "name": account.boardName], ["key": other, "name": "Studio"]], "pending": [["key": asking, "name": "MacBook Air"]]]))
        }
    }

    /// One request to `host` about its boards (see `Boards.request`), on a channel of its own;
    /// nil when the host doesn't trust this Mac or doesn't answer.
    // shortcut: a channel per request (a handshake each); keep one open per host if listing every 30 seconds ever shows up as load.
    private func ask(_ host: UUID, _ request: Data) async -> Data? {
        let open = open
        return await Task.detached {
            guard let channel = open(host, .boards).channel else { return nil }
            defer { close(channel) }
            var patience = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(channel, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
            let line = request + Data([10])
            guard line.withUnsafeBytes({ write(channel, $0.baseAddress, $0.count) }) == line.count else { return nil }
            var answer = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
            // One line; a host's list of 8 pending boards and its trusted ones is far below this.
            while answer.last != 10, answer.count < 256 * 1024 {
                let count = read(channel, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return nil }
                answer.append(contentsOf: buffer[..<count])
            }
            return answer
        }.value
    }

    /// Asks `host` for its boards: `boards` when it trusts this Mac, `waiting` when it doesn't.
    func listBoards(of host: UUID) async {
        guard let listed = Boards(await ask(host, Boards.request("list"))) else { return }
        if boards[host] != listed { boards[host] = listed }
    }

    /// Lets the pending board with `key` use `host`, or (`forget`) stops a trusted one. False
    /// when the host didn't do it.
    func changeBoard(_ key: String, on host: UUID, forget: Bool = false) async -> Bool {
        let answer = await ask(host, Boards.request(forget ? "forget" : "trust", key: key))
        let done = (answer.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["ok"] as? Bool == true
        // Forgetting this Mac's own key ends the list for it: the next try says "pending".
        if forget, key == account.boardPublicKey { boards[host] = nil } else { await listBoards(of: host) }
        return done
    }

    /// Signs out, first (`removingKey`) having each online host that trusts this Mac forget its key.
    func signOut(removingKey: Bool) async {
        if removingKey { await removeThisMac() }
        await account.signOut()
    }

    /// Has each online host that trusts this Mac forget its key.
    func removeThisMac() async {
        guard let key = account.boardPublicKey else { return }
        for host in account.hosts where host.online && !account.identityChanged(host.id) && waiting[host.id] == nil {
            _ = await changeBoard(key, on: host.id, forget: true)
        }
    }

    /// For each host reached through the relay, tries the direct path again; a store whose
    /// host answers there reconnects onto it. One that doesn't is left as it is.
    func retryDirect() async {
        for (host, store) in remote where store.core != nil {
            guard case .relay = store.hostPath, let channel = await openDirect(host) else { continue }
            if let stale = channels.lock.withLock({ channels.ready.updateValue(channel, forKey: host) }) { close(stale) }
            store.reconnect()
        }
    }

    /// The user's answer to `syncQuestion`: yes syncs now and lets later syncs to that host
    /// run by themselves.
    func answerSync(_ allowed: Bool) {
        guard let host = syncQuestion else { return }
        syncQuestion = nil
        guard allowed, let syncHome else { return }
        Task { await sync(host, from: syncHome) }
    }

    /// Removes `host` from the account (see `AccountStore.forgetHost`) and from this board.
    func forget(_ host: UUID) async -> Bool {
        guard await account.forgetHost(host) else { return false }
        remote.removeValue(forKey: host)?.quit()
        homes[host] = nil
        synced.remove(host)
        syncNotes[host] = nil
        if syncQuestion == host { syncQuestion = nil }
        return true
    }

    /// The organization shown, in every store.
    var organizationID: UUID {
        get { local.organizationID }
        set { ([local] + remote.values).forEach { $0.organizationID = newValue } }
    }

    /// The store of the host a worktree lives on (nil: this Mac), if it is in use.
    subscript(host: UUID?) -> AgentStore? {
        guard let host else { return local }
        return remote[host]
    }

    /// The same, connecting to the host on first use. Not from a view's body: it changes state.
    @discardableResult
    func store(for host: UUID?) -> AgentStore {
        guard let host else { return local }
        if let store = remote[host] { return store }
        let name = account.hosts.first { $0.id == host }?.name ?? L("the host")
        let store = AgentStore(connect: connect(host), host: (host, name))
        store.organizationID = local.organizationID
        prepare?(store)
        store.downReason = { [weak self, weak account] in
            if account?.identityChanged(host) == true { return AccountStore.identityChangedNote }
            return self?.waiting[host] == nil ? nil : L("\(name) is waiting to approve this Mac. The account menu says how.")
        }
        store.onConnect = { [weak self] in
            guard let self, let syncHome, synced.insert(host).inserted else { return }
            // Skills and keys go to a host only after the user said so once.
            guard account.isSyncAllowed(to: host) else { return syncQuestion = host }
            Task { await self.sync(host, from: syncHome) }
        }
        remote[host] = store
        return store
    }

    /// Copies `home`'s skills and MCP servers to `host` (see `HostSync`), saying how it went
    /// in `syncNotes`. Called for the user (the menu's row, or their yes to `syncQuestion`):
    /// later syncs to the host, as it is pinned, then run by themselves.
    func sync(_ host: UUID, from home: URL) async {
        account.allowSync(to: host)
        let store = store(for: host)
        syncNotes[host] = L("Syncing…")
        do {
            guard let files = store.files, let dataFolder = await store.askHostDataFolder() else {
                throw HostSync.Failure(message: L("Couldn't reach \(store.host?.name ?? L("the host")). It may be offline."))
            }
            syncNotes[host] = try await HostSync.run(from: home, to: files, dataFolder: dataFolder).note(on: store.host?.name ?? L("the host"))
        } catch {
            syncNotes[host] = L("Not synced: \(error.localizedDescription)")
        }
    }

    /// This Mac's store and those of the hosts that answer.
    var connected: [AgentStore] {
        [local] + remote.values.filter { $0.isLoaded && $0.notice == nil }
    }

    /// The store that has the card.
    func store(of card: UUID) -> AgentStore? {
        connected.first { $0.record(card) != nil }
    }

    /// Agents waiting on the developer, on every host that answers, oldest first.
    var attention: [AttentionRequest] {
        let stores = connected
        return stores.count == 1 ? local.attention : stores.flatMap(\.attention).sorted { $0.since < $1.since }
    }

    /// Git on `host`, through its core; nil when the host doesn't answer within a few seconds.
    func git(on host: UUID) async -> GitHost? {
        let store = store(for: host)
        let deadline = Date().addingTimeInterval(8)
        while store.core == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard let client = store.core, let name = store.host?.name else { return nil }
        if homes[host] == nil, let ran = await client.run("sh", ["-c", "printf %s \"$HOME\""]), ran.status == 0 {
            let home = String(decoding: ran.output, as: UTF8.self)
            if home.hasPrefix("/") { homes[host] = home }
        }
        return homes[host].map { GitHost(name: name, home: $0, store: store) }
    }
}

extension GitHost {
    /// Git on the machine `store` mirrors, through whatever connection the store has when asked:
    /// one made before the store reconnected (onto the direct path, say) keeps working.
    init(name: String, home: String, store: AgentStore) {
        self.init(name: name, home: home) { executable, arguments in
            // Callers are synchronous and off the main thread; the core answers on its own queue.
            let done = DispatchSemaphore(value: 0)
            let result = Answer()
            Task.detached { [weak store] in
                let ran = await store?.run(executable, arguments)
                result.lock.withLock { result.value = ran }
                done.signal()
            }
            // The host stops a program after 15 minutes; an answer that takes longer isn't coming.
            guard done.wait(timeout: .now() + GitHost.patience) == .success else {
                return (1, Data(), Data(L("\(name) took too long to answer and was given up on.").utf8))
            }
            return result.lock.withLock { result.value }.map { ($0.status, $0.output, $0.error) }
        }
    }

    /// How long a program on a host is waited for, in seconds.
    nonisolated(unsafe) static var patience: Double = 16 * 60

    private final class Answer: @unchecked Sendable {
        let lock = NSLock()
        var value: CoreClient.Ran?
    }
}
