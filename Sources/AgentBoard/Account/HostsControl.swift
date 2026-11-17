import AgentRuntime
import AppKit
import SwiftUI

/// The computers in the top bar, beside the project actions: "Compute" and how many there are,
/// this Mac included. Opens the list of them, each with its stats, its health, its sync and its dialog.
struct HostsControl: View {
    let hosts: HostStores
    @State private var menu = OrganizationMenuPanel(leading: true)

    var body: some View {
        let count = hosts.account.hosts.count + 1
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").font(Theme.Font.label).foregroundStyle(Theme.ink)
                Text(L("Compute")).font(Theme.Font.label).foregroundStyle(Theme.ink)
                Text(verbatim: "\(count)")
                    .font(Theme.Font.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.deep)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accentTint, in: .capsule)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(.capsule)
            .modifier(HostsCapsule())
            // A computer is asking to use one of the hosts: waiting for you.
            .overlay(alignment: .topTrailing) {
                if hosts.boards.values.contains(where: { !$0.pending.isEmpty }) {
                    Circle().fill(Theme.deep).frame(width: 8, height: 8).offset(x: 2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .background(OrganizationMenuAnchor(panel: menu))
        .help(L("Compute: each computer's stats, health and sync, and its options"))
        .accessibilityLabel(L("Compute"))
        .accessibilityValue("\(count)")
        .onAppear {
            // For screenshots of a build under test (see docs/core.md).
            if DebugShow.items.contains("hosts-menu") { DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: toggle) }
        }
    }

    private func toggle() {
        menu.toggle { state, close in HostsMenu(hosts: hosts, state: state, close: close) }
    }
}

/// The button's own glass: the bar's shared one would join it to the project actions.
private struct HostsCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
        }
    }
}

/// How a host of the account stands with this Mac, for its row and its dialog.
struct HostStanding {
    /// Its identity key isn't the one this Mac knew.
    let changed: Bool
    /// It answers but doesn't trust this Mac yet: how many computers it trusts.
    let waiting: Int?
    let detail: String
    /// Online and trusting this Mac.
    let isUsable: Bool

    @MainActor init(_ host: Host, in hosts: HostStores) {
        changed = hosts.account.identityChanged(host.id)
        waiting = host.online && !changed ? hosts.waiting[host.id] : nil
        isUsable = host.online && !changed && waiting == nil
        detail = changed ? L("Identity changed") : waiting != nil ? L("Waiting for approval")
            : host.online ? hosts[host.id]?.hostPath?.note ?? L("Online") : Self.lastSeen(host)
    }

    /// "Last seen 3 hours ago", or that it never came online.
    private static func lastSeen(_ host: Host) -> String {
        guard let seen = host.lastSeen else { return L("Never online") }
        let ago = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: seen), relativeTo: Date())
        return L("Last seen \(ago)")
    }
}

extension HostStats {
    /// The most used of processor (its 1-minute load, which a burst doesn't move), memory and
    /// disk, 0 to 1.
    var strain: Double {
        let fraction = { (used: UInt64, total: UInt64) in total > 0 ? Double(used) / Double(total) : 0 }
        return min(max(load / Double(max(cores, 1)), fraction(memoryUsed, memoryTotal), fraction(diskUsed, diskTotal)), 1)
    }
}

/// This Mac's stats, sampled here while the hosts menu shows them: its own core doesn't report them.
struct LocalHostSampler {
    private var ticks: (busy: UInt64, total: UInt64)?

    /// The processor's share is of the time since the last sample: 0 on the first.
    mutating func sample() -> HostStats {
        let host = mach_host_self()
        var load = host_cpu_load_info()
        var loadCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) { _ = host_statistics(host, HOST_CPU_LOAD_INFO, $0, &loadCount) }
        }
        // User, system, idle, nice.
        let busy = UInt64(load.cpu_ticks.0) + UInt64(load.cpu_ticks.1) + UInt64(load.cpu_ticks.3)
        let now = (busy: busy, total: busy + UInt64(load.cpu_ticks.2))
        var cpu = 0.0
        if let ticks, now.total > ticks.total, now.busy >= ticks.busy { cpu = Double(now.busy - ticks.busy) / Double(now.total - ticks.total) }
        ticks = now

        var memory = vm_statistics64()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) { _ = host_statistics64(host, HOST_VM_INFO64, $0, &memoryCount) }
        }
        let used = (UInt64(memory.active_count) + UInt64(memory.wire_count) + UInt64(memory.compressor_page_count)) * UInt64(getpagesize())

        let volume = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = UInt64(max(volume?.volumeTotalCapacity ?? 0, 0))
        let free = min(UInt64(max(volume?.volumeAvailableCapacityForImportantUsage ?? 0, 0)), total)
        var average = [0.0]
        getloadavg(&average, 1)
        return HostStats(cpu: cpu, memoryUsed: used, memoryTotal: ProcessInfo.processInfo.physicalMemory, diskUsed: total - free, diskTotal: total,
                         load: average[0], cores: ProcessInfo.processInfo.activeProcessorCount)
    }
}

/// The hosts menu: this Mac, then the account's hosts. Each says how it is reached, what it is
/// using, how healthy that leaves it and where its sync stands, and has a button for its dialog.
struct HostsMenu: View {
    let hosts: HostStores
    let state: OrganizationMenuState
    let close: () -> Void
    private var account: AccountStore { hosts.account }
    @State private var localStats: HostStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(nil, name: L("This Mac"), system: .mac, detail: L("Online"), isOnline: true, isWrong: false, stats: localStats, note: hosts.vaultNote)
            ForEach(account.hosts) { host in
                let standing = HostStanding(host, in: hosts)
                row(host.id, name: host.name, system: HostSystem(platform: host.platform), detail: standing.detail, isOnline: standing.isUsable, isWrong: standing.changed,
                    stats: standing.isUsable ? hosts[host.id]?.hostStats : nil, note: hosts.syncNotes[host.id])
            }
        }
        .padding(6)
        .onExitCommand(perform: close)
        .task {
            await account.refreshHosts()
            hosts.showSample()
            // Whatever is out of date gets synced on its own, once the user allowed syncing.
            if account.vaultAllowed, hosts.syncStates[nil] != .syncing { Task { await hosts.syncVault() } }
            // Who each host trusts and who asks to be, while the menu is open.
            while !Task.isCancelled {
                for host in account.hosts where host.online && !account.identityChanged(host.id) && hosts[host.id]?.core == nil {
                    await hosts.listBoards(of: host.id)
                }
                for host in hosts.remote.keys where hosts[host]?.core != nil && hosts.boards[host] == nil { await hosts.listBoards(of: host) }
                // A host that trusts this Mac reports its stats once connected to.
                for host in account.hosts where HostStanding(host, in: hosts).isUsable { hosts.store(for: host.id) }
                try? await Task.sleep(for: .seconds(hosts.boardInterval))
            }
        }
        .task {
            var sampler = LocalHostSampler()
            _ = sampler.sample()
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                let stats = sampler.sample()
                withAnimation(.snappy(duration: 0.3)) { localStats = stats }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .modifier(MenuChrome(state: state, width: 360, anchor: .topLeading))
    }

    /// `id` nil is this Mac.
    private func row(_ id: UUID?, name: String, system: HostSystem, detail: String, isOnline: Bool, isWrong: Bool, stats: HostStats?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Its health is in its picture: a strained computer's fills with static.
                let strain = isOnline ? stats?.strain ?? 0 : nil
                let verdict = strain.map(HostHealth.verdict) ?? L("Offline")
                ComputeIcon(system: system, strain: strain)
                    .frame(width: 44, height: 44)
                    .opacity(isOnline ? 1 : 0.55)
                    .accessibilityElement()
                    .accessibilityLabel(L("Health"))
                    .accessibilityValue(verdict)
                    .help(L("\(verdict). The picture fills with static as the most used of processor, memory and storage fills up."))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name).font(Theme.Font.heading).foregroundStyle(Theme.ink).lineLimit(1)
                        if let sync = hosts.syncStates[id] { SyncBadge(state: sync, note: note) }
                    }
                    Text(detail).font(Theme.Font.caption).foregroundStyle(isWrong ? Theme.danger : Theme.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                HostRowButton(symbol: "pencil", title: L("Edit"), help: L("Opens \(name)'s options.")) {
                    hosts.editingHost = .init(id: id)
                    close()
                }
            }
            if let stats {
                HostHealth(stats: stats)
            } else if isOnline {
                // Holds the stats' place until the first ones arrive.
                HStack(spacing: 12) {
                    ForEach([52, 104, 112], id: \.self) { width in
                        RoundedRectangle(cornerRadius: Theme.Radius.thumb).fill(Theme.surfaceDeep).frame(width: width, height: 13)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

/// Where a computer's sync stands, beside its name; how it went is its tooltip.
private struct SyncBadge: View {
    let state: HostStores.SyncState
    let note: String?

    var body: some View {
        let title = switch state {
        case .syncing: L("Syncing")
        case .synced: L("Synced")
        case .failed: L("Not synced")
        }
        Text(title)
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(state == .failed ? Theme.danger : Theme.deep)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(state == .failed ? Theme.surfaceDeep : Theme.accentSoft, in: .rect(cornerRadius: Theme.Radius.thumb))
            .fixedSize()
            .contentTransition(.opacity)
            .animation(.snappy(duration: 0.2), value: state)
            .help(note ?? title)
    }
}

/// An icon button of a host's row, on its own fill.
private struct HostRowButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Font.label)
                .foregroundStyle(isHovered ? Theme.accent : Theme.ink)
                .frame(width: 26, height: 26)
                .background(isHovered ? Theme.accentSoft : Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.snappy(duration: 0.15)) { isHovered = inside } }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

/// What a host is using.
private struct HostHealth: View {
    let stats: HostStats

    /// What its strain says of its health.
    static func verdict(_ strain: Double) -> String {
        strain > 0.9 ? L("Critical") : strain > 0.75 ? L("Under load") : L("Healthy")
    }

    var body: some View {
        HStack(spacing: 12) {
            item(L("CPU"), stats.cpu.formatted(.percent.precision(.fractionLength(0))), isHigh: stats.cpu > 0.9)
            item(L("Memory"), Self.used(stats.memoryUsed, of: stats.memoryTotal), isHigh: stats.memoryUsed > stats.memoryTotal / 10 * 9)
            item(L("Storage"), Self.used(stats.diskUsed, of: stats.diskTotal), isHigh: stats.diskUsed > stats.diskTotal / 10 * 9)
        }
        .font(Theme.Font.caption)
        .animation(.snappy(duration: 0.3), value: stats)
    }

    private func item(_ title: String, _ value: String, isHigh: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.inkMuted)
            Text(value).monospacedDigit().foregroundStyle(isHigh ? Theme.danger : Theme.ink).contentTransition(.numericText())
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// "3.1 / 8 GB".
    private static func used(_ used: UInt64, of total: UInt64) -> String {
        let gigabytes = { (bytes: UInt64, digits: Int) in (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(digits))) }
        return "\(gigabytes(used, 1)) / \(gigabytes(total, 0)) GB"
    }
}

/// A host's dialog: what stands between it and this Mac (an approval, a changed identity, a
/// relayed connection), the computers it trusts, its MCP servers as a page of this same dialog,
/// and disconnecting it. This Mac's says how other computers recognize it.
struct HostDialog: View {
    let hosts: HostStores
    let editing: HostStores.Editing
    private var account: AccountStore { hosts.account }
    /// What was clicked once and is done on the next click.
    @State private var confirming: String?
    @State private var copiedKey = false
    @State private var isTryingDirect = false
    @State private var stillRelayed = false

    var body: some View {
        if let id = editing.id {
            if editing.servers {
                HostServersSheet(hosts: hosts, host: id)
            } else if let host = account.hosts.first(where: { $0.id == id }) {
                remote(host)
            }
        } else {
            local
        }
    }

    private var local: some View {
        AppDialog(title: L("This Mac"), subtitle: L("Online")) {
            VStack(alignment: .leading, spacing: 14) {
                if let key = account.boardPublicKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Fingerprint \(Self.whole(AccountStore.fingerprint(of: key)))")).foregroundStyle(Theme.ink).textSelection(.enabled)
                        note(L("What a host, or a computer it trusts, shows when this Mac asks to use it."))
                    }
                }
                note([hosts.vaultNote, L("This Mac's skills are kept in your account; other computers' additions reach your hosts, not this Mac.")]
                    .compactMap { $0 }.joined(separator: " "))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            done
        }
    }

    private func remote(_ host: Host) -> some View {
        let standing = HostStanding(host, in: hosts)
        return AppDialog(title: host.name, subtitle: standing.detail) {
            VStack(alignment: .leading, spacing: 16) {
                if standing.changed {
                    option(L("Trust new identity"), L("Only if `agentboard status` on the host shows \(AccountStore.fingerprint(of: host.publicKey)).")) {
                        account.acceptIdentity(of: host.id)
                    }
                }
                if let waiting = standing.waiting, let key = account.boardPublicKey {
                    approval(waiting: waiting, key: key, host: host)
                }
                if standing.isUsable {
                    if let listed = hosts.boards[host.id] { computers(listed, on: host) }
                    if case .relay = hosts[host.id]?.hostPath {
                        let when = L("Direct when this Mac and the host share a network, or the host's port 47470 is reachable.")
                        option(isTryingDirect ? L("Trying the direct connection…") : L("Try the direct connection now"),
                               stillRelayed ? L("The host didn't answer directly; still relayed.") + " " + when : when) {
                            guard !isTryingDirect else { return }
                            isTryingDirect = true
                            stillRelayed = false
                            Task {
                                let moved = await hosts.retryDirect(only: host.id)
                                isTryingDirect = false
                                stillRelayed = !moved
                            }
                        }
                    }
                    option(L("MCP servers"), L("What agents on this host are given, and what only it does differently.")) {
                        withAnimation(.snappy(duration: 0.25)) { hosts.editingHost?.servers = true }
                    }
                }
                confirmed("disconnect", title: L("Disconnect"), caption: L("Removes \(host.name) from your account and from this board.")) {
                    if await hosts.forget(host.id) { hosts.editingHost = nil }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            done
        }
    }

    private var done: some View {
        Button(L("Done")) { hosts.editingHost = nil }
            .buttonStyle(DialogButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
    }

    /// The host answers but doesn't trust this Mac yet: how to be approved.
    @ViewBuilder private func approval(waiting: Int, key: String, host: Host) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if waiting > 0, !account.wasTrusted(by: host.id) {
                Text(L("Another computer is already trusted by this host.")).foregroundStyle(Theme.ink)
            }
            note(L("Approve \(Self.whole(AccountStore.fingerprint(of: key))) on a computer this host already trusts. Or run `agentboard trust` with the key below on the host, which works even when that approval doesn't."))
            HStack(spacing: 8) {
                Text(key).font(Theme.Font.caption.monospaced()).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button(copiedKey ? L("Copied") : L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    withAnimation(.snappy(duration: 0.2)) { copiedKey = true }
                }
                .buttonStyle(DialogButtonStyle())
                .help(L("Copies this Mac's key, for `agentboard trust` on the host."))
            }
        }
    }

    /// The computers asking to use the host, and the other ones it trusts.
    @ViewBuilder private func computers(_ listed: HostStores.Boards, on host: Host) -> some View {
        ForEach(listed.pending) { board in
            confirmed("+\(board.key)", title: L("Approve a new computer"), prominent: true,
                      caption: board.name.isEmpty
                          ? L("\(Self.whole(board.fingerprint)) wants to use \(host.name). The same fingerprint shows in that computer's own dialog, under Compute.")
                          : L("\(Self.whole(board.fingerprint)) wants to use \(host.name). It calls itself “\(board.name)”. The same fingerprint shows in that computer's own dialog, under Compute.")) {
                _ = await hosts.changeBoard(board.key, on: host.id)
            }
        }
        ForEach(listed.trusted.filter { $0.key != account.boardPublicKey }) { board in
            confirmed("-\(board.key)", title: L("Forget a computer"),
                      caption: board.name.isEmpty ? L("\(Self.whole(board.fingerprint)) stops reaching \(host.name) until approved again.")
                          : L("\(Self.whole(board.fingerprint)), which calls itself “\(board.name)”, stops reaching \(host.name) until approved again.")) {
                _ = await hosts.changeBoard(board.key, on: host.id, forget: true)
            }
        }
    }

    /// A fingerprint that a line never breaks inside.
    private static func whole(_ fingerprint: String) -> String { fingerprint.replacingOccurrences(of: " ", with: "\u{A0}") }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
    }

    /// Something to do: one line on what it does, and its button.
    private func option(_ title: String, _ caption: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Text(caption).foregroundStyle(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(title, action: action).buttonStyle(DialogButtonStyle(prominent: prominent)).fixedSize()
        }
    }

    /// An option that is done on the second click.
    private func confirmed(_ id: String, title: String, prominent: Bool = false, caption: String, action: @escaping () async -> Void) -> some View {
        option(confirming == id ? L("\(title)? Click again") : title, caption, prominent: prominent) {
            guard confirming == id else { return confirming = id }
            confirming = nil
            Task { await action() }
        }
    }
}
