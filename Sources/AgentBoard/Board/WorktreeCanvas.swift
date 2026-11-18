import AgentRuntime
import Orchestration
import SwiftUI

/// A worktree's canvas: the Metal board with its agents, and the toolbars floating on top.
struct WorktreeCanvas: View {
    let agents: AgentStore
    let browsers: BrowserStore
    let fileTrees: FileTreeStore
    let worktree: Worktree
    let board: BoardController
    /// The user's own board shows its title where a worktree shows its branch, and has no files to browse.
    var title: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            SkyCanvas()
            Board(store: agents, browsers: browsers, fileTrees: fileTrees, worktree: worktree.path, controller: board)
            if let notice {
                EmptyCanvas(symbol: "exclamationmark.triangle", title: L("Your agents can't be shown"), message: notice) { EmptyView() }
                    .padding(.leading, board.leadingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if isEmpty {
                SkyBlobEmptyState()
                .padding(.leading, board.leadingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            // One row, so the side groups give way to the centered tools instead of overlapping them.
            HStack(alignment: .bottom, spacing: 12) {
                // Narrow windows drop the usage first, then scroll the tools: nothing overlaps.
                ViewThatFits(in: .horizontal) {
                    if !board.isZen {
                        usage(compact: false)
                        // Narrower, the labels become glyphs before the host's name goes.
                        usage(compact: true)
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    CanvasToolbar(board: board, hasFiles: title == nil)
                    ScrollView(.horizontal, showsIndicators: false) { CanvasToolbar(board: board, hasFiles: title == nil) }
                }
                .layoutPriority(1)
                VStack(alignment: .trailing, spacing: 8) {
                    AppUsage()
                    NavigationToolbar(board: board)
                }
                // Never squeezed below its size, or the zoom bar slides under the centered tools.
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.bottom, 16)
            .padding(.leading, board.leadingInset + 16)
            .padding(.trailing, 16)
            .frame(maxHeight: .infinity, alignment: .bottom)
            if let format = board.postItFormat {
                PostItFormatToolbar(board: board, format: format)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
            if !board.isZen {
                BranchBadge(branch: worktree.branch, title: title)
                    .padding(.top, 14)
                    .padding(.leading, board.leadingInset + 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: isEmpty)
        .animation(.snappy(duration: 0.25), value: board.postItFormat != nil)
        .animation(.snappy(duration: 0.32), value: board.isZen)
        .animation(.smooth(duration: 0.3), value: notice)
        .animation(.smooth(duration: 0.3), value: agents.hostStats == nil)
        // Content centers on the canvas the sidebar leaves uncovered, following it as it slides.
        .animation(.snappy(duration: 0.32), value: board.leadingInset)
        .clipped()
        .sheet(item: Binding(get: { board.deviceRequest }, set: { board.deviceRequest = $0 })) { request in
            let current: BrowserDevice? = if case .browser(let id) = request.target { browsers.record(id)?.device } else { nil }
            BrowserDeviceDialog(browsers: browsers, initial: current ?? .desktop, isNew: request.target == .new) { device in
                board.apply(device, to: request.target)
            }
        }
        .sheet(isPresented: Binding(get: { board.addingRunner }, set: { board.addingRunner = $0 })) {
            RunnerDialog(worktree: worktree.path, files: agents.files) { command, name, directory in
                board.addRunner(command: command, name: name, directory: directory)
            }
        }
        .sheet(item: Binding(get: { board.importRequest }, set: { board.importRequest = $0 })) { request in
            let profile: UUID = if case .browser(let id) = request.target { browsers.record(id)?.profile ?? BrowserProfile.defaultID } else { BrowserProfile.defaultID }
            BrowserImportDialog(browsers: browsers, initialProfile: profile) {}
        }
    }

    /// Shown where the cards would be, when there are none to show.
    /// The host's stats above the agent's usage; `compact` names each number with a glyph.
    private func usage(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = agents.host, let stats = agents.hostStats {
                HostUsage(name: host.name, stats: stats, path: agents.hostPath, compact: compact)
                    .transition(.opacity)
            }
            ClaudeUsageToolbar(organization: agents.organizationID)
        }
        .transition(.opacity)
    }

    private var notice: String? {
        agents.agents(in: worktree.path).isEmpty ? agents.notice : nil
    }

    private var isEmpty: Bool {
        agents.isLoaded && agents.agents(in: worktree.path).isEmpty && agents.postIts(in: worktree.path).isEmpty
            && agents.images(in: worktree.path).isEmpty
            && browsers.browsers(in: worktree.path, on: worktree.host).isEmpty
            && fileTrees.trees(in: worktree.path, on: worktree.host).isEmpty
    }
}

/// The board's tools, floating at the bottom center, as icon buttons.
private struct CanvasToolbar: View {
    let board: BoardController
    var hasFiles = true

    var body: some View {
        HStack(spacing: 2) {
            addAgent
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add agent"))
            addBrowser
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add browser"))
            // A command kept running on the board: a dev server, a watcher, a worker.
            addRunner
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add runner"))
                .help(L("Keeps a command running, such as a dev server, or opens a plain terminal."))
            Button { board.addPostIt() } label: { Image(systemName: "note.text") }
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add post-it"))
                .help(L("A new post-it in markdown: you and every agent connected to it read and write it."))
            addMedia
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add media"))
                .help(L("Puts pictures or videos from your files on the board; agents connected to one see it."))
            if hasFiles {
                Button { board.addFileTree() } label: { Image(systemName: "folder") }
                    .buttonStyle(ToolbarButtonStyle(icon: true))
                    .fixedSize()
                    .accessibilityLabel(L("Add file tree"))
                    .help(L("Browse the worktree's files and leave notes on their lines for the connected agents."))
            }
        }
        .font(.system(size: 18, weight: .medium))
        .padding(5)
        .modifier(GlassCapsule())
    }

    /// A browser emulates one screen; the menu says what each gives.
    private var addBrowser: some View {
        Menu {
            ForEach(BrowserDevice.presets, id: \.self) { device in
                Button { board.add(device) } label: {
                    Text(L(String.LocalizationValue(device.title)))
                    Text(device.help)
                }
            }
            Divider()
            Button { board.editDevice(.new) } label: {
                Text(L("Custom…"))
                Text(L("Choose the size, density, touch, and user agent."))
            }
            Divider()
            Button { board.importData(into: .new) } label: {
                Text(L("Import data…"))
                Text(L("Bring logins from your browser into a profile."))
            }
        } label: { Image(systemName: "globe") }
        .menuStyle(.button)
        .menuIndicator(.hidden)
    }

    /// Pictures and videos are different cards; the menu says what each gives.
    private var addMedia: some View {
        Menu {
            Button { board.addImages() } label: {
                Text(L("Image"))
                Text(L("A picture from your files; connected agents see its pixels."))
            }
            Button { board.addVideos() } label: {
                Text(L("Video"))
                Text(L("An MP4, MOV or M4V clip that plays on the card, muted until you turn the sound on."))
            }
        } label: { Image(systemName: "photo.on.rectangle") }
        .menuStyle(.button)
        .menuIndicator(.hidden)
    }

    private var addRunner: some View {
        Button { board.addingRunner = true } label: { Image(systemName: "play.circle") }
    }

    /// One agent kind adds it straight away; several ask which.
    @ViewBuilder private var addAgent: some View {
        // An agent lives in a terminal on the board; same symbol as the empty canvas.
        let icon = Image(systemName: "terminal")
        if AgentCatalog.all.count == 1, let provider = AgentCatalog.all.first {
            Button { board.add(provider) } label: { icon }
        } else {
            Menu {
                ForEach(AgentCatalog.all, id: \.id) { provider in
                    Button { board.add(provider) } label: {
                        Text(provider.title)
                        Text(provider.subtitle)
                    }
                }
            } label: { icon }
            .menuStyle(.button)
            .menuIndicator(.hidden)
        }
    }
}

/// Zoom and navigation, floating at the bottom-right corner.
private struct NavigationToolbar: View {
    let board: BoardController
    private let caffeinate = Caffeinate.shared

    var body: some View {
        HStack(spacing: 2) {
            if !board.isZen { zoomControls }
            Button { board.isZen.toggle() } label: {
                Image(systemName: board.isZen ? "figure.walk" : "figure.mind.and.body")
                    .foregroundStyle(board.isZen ? Theme.deep : Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .help(board.isZen ? L("Leave zen mode: bring back the sidebar and the bars.") : L("Zen mode: hides everything but the canvas, its tools, and Needs you."))
            .accessibilityLabel(board.isZen ? L("Leave zen mode") : L("Zen mode"))

            Button { caffeinate.isOn.toggle() } label: {
                Image(systemName: caffeinate.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(caffeinate.isOn ? Theme.deep : Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
                    .overlay(alignment: .top) {
                        if caffeinate.isOn {
                            CaffeinateSteam(color: Theme.deep)
                                .offset(y: -12)
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth, value: caffeinate.isOn)
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .help(caffeinate.isOn ? L("Caffeinate on: the Mac and its display stay awake. Click to let them sleep.") : L("Caffeinate: keeps the Mac and its display awake while agents work."))
            .accessibilityLabel(L("Caffeinate"))
            .accessibilityValue(caffeinate.isOn ? L("On") : L("Off"))
        }
        .font(Theme.Font.label)
        .padding(4)
        .modifier(GlassCapsule())
    }

    @ViewBuilder private var zoomControls: some View {
            Button(action: board.fitAgents) {
                Image(systemName: "viewfinder")
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .help(L("Fits every agent on screen."))

            Button(action: board.organize) {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .help(L("Organize: lays each agent out with what it's connected to on its right, and packs the groups in rows."))
            .accessibilityLabel(L("Organize"))

            Button(action: board.zoomOut) {
                Image(systemName: "minus")
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .disabled(board.zoom <= BoardView.zoomRange.lowerBound)
            .help(L("Zoom out (⌘−)"))

            Button(action: board.resetZoom) {
                Text(board.zoom, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .help(L("Back to actual size (⌘0)"))

            Button(action: board.zoomIn) {
                Image(systemName: "plus")
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .disabled(board.zoom >= BoardView.zoomRange.upperBound)
            .help(L("Zoom in (⌘+)"))
    }
}

/// The style of the post-it text being written, floating at the canvas's right edge while it is.
private struct PostItFormatToolbar: View {
    let board: BoardController
    let format: PostItFormat

    var body: some View {
        VStack(spacing: 2) {
            size(1, L("Title"), L("Title: the largest text, for the note's name."))
            size(2, L("Heading"), L("Heading: large text that opens a section."))
            size(3, L("Subheading"), L("Subheading: slightly larger text for a part of a section."))
            size(nil, L("Text"), L("Text: the normal size, for paragraphs."))
            Button { board.togglePostItBold() } label: { Image(systemName: "bold") }
                .buttonStyle(ToolbarButtonStyle(icon: true, active: format.bold))
                .disabled(format.heading != nil)
                .accessibilityLabel(L("Bold"))
                .help(L("Bold: makes the selected text, or what you type next, heavier."))
                .padding(.top, 8)
            Button { board.togglePostItUnderline() } label: { Image(systemName: "underline") }
                .buttonStyle(ToolbarButtonStyle(icon: true, active: format.underline))
                .accessibilityLabel(L("Underline"))
                .help(L("Underline: draws a line under the selected text, or what you type next."))
        }
        .font(.system(size: 16, weight: .medium))
        .padding(5)
        .modifier(GlassCapsule())
    }

    /// One paragraph size, shown as a letter in the note's handwriting at that size.
    private func size(_ level: Int?, _ name: String, _ help: String) -> some View {
        Button { board.setPostItHeading(level) } label: {
            Text(verbatim: "A").font(Font(Theme.Font.hand(size: MarkdownText.size(heading: level), bold: level != nil)))
        }
        .buttonStyle(ToolbarButtonStyle(icon: true, active: format.heading == level))
        .accessibilityLabel(name)
        .help(help)
    }
}

/// Liquid Glass where the system has it, a translucent material before that.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: .capsule)
        }
    }
}

/// Black controls on glass; hover and press show as a faint black fill.
private struct ToolbarButtonStyle: ButtonStyle {
    var compact = false
    /// A lone symbol in a round button.
    var icon = false
    /// On, for a control that toggles.
    var active = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black.opacity(isEnabled ? 0.85 : 0.3))
            .padding(.horizontal, icon ? 0 : compact ? 8 : 12)
            .padding(.vertical, icon ? 0 : 6)
            .frame(width: icon ? 40 : nil, height: icon ? 40 : nil)
            .background(.black.opacity(configuration.isPressed || active ? 0.12 : isHovered && isEnabled ? 0.06 : 0), in: .capsule)
            .contentShape(.capsule)
            .onHover { isHovered = $0 }
            .animation(.snappy(duration: 0.2), value: isHovered)
    }
}

/// What the board itself uses, the app and its core together (not the agents they run),
/// sampled every two seconds.
private struct AppUsage: View {
    @State private var stats: RunnerStats?

    var body: some View {
        Group {
            if let stats {
                HStack(spacing: 10) {
                    Label(stats.cpu.map { String(format: "%.0f%%", $0) } ?? "–", systemImage: "cpu")
                    Label(ByteCountFormatter.string(fromByteCount: Int64(stats.memory), countStyle: .memory), systemImage: "memorychip")
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.line.opacity(0.5))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .modifier(GlassCapsule())
                .help(L("CPU and memory the board uses, without its agents."))
                .transition(.opacity)
            }
        }
        .task {
            var previous: ProcessInspector.Sample?
            let core = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentBoardCore")
            while !Task.isCancelled {
                let sample = await Task.detached {
                    let pids = [getpid()] + (core.map(ProcessInspector.processes(running:)) ?? [])
                    return ProcessInspector.sample(processes: pids, previous: previous)
                }.value
                previous = sample
                withAnimation(.smooth(duration: 0.3)) { stats = sample.stats }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// What the worktree's host is using (CPU, memory, disk), above the agent usage, as its core
/// reports it every couple of seconds.
private struct HostUsage: View {
    let name: String
    let stats: HostStats
    var path: HostChannel.Path?
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            Label(name, systemImage: "server.rack")
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .help(path.map(\.note) ?? "")
            item(L("CPU"), "cpu", stats.cpu.formatted(.percent.precision(.fractionLength(0))), isHigh: stats.cpu > 0.9,
                 help: L("Of every processor on \(name) together."))
            item(L("Memory"), "memorychip", Self.used(stats.memoryUsed, of: stats.memoryTotal), isHigh: stats.memoryUsed > stats.memoryTotal / 10 * 9,
                 help: L("Memory in use on \(name), of what it has."))
            item(L("Disk"), "internaldrive", Self.used(stats.diskUsed, of: stats.diskTotal), isHigh: stats.diskUsed > stats.diskTotal / 10 * 9,
                 help: L("Disk in use on \(name), of the volume its home folder is on."))
        }
        .font(Theme.Font.label)
        .padding(4)
        .modifier(GlassCapsule())
        .accessibilityElement(children: .combine)
    }

    private func item(_ title: String, _ symbol: String, _ value: String, isHigh: Bool, help: String) -> some View {
        HStack(spacing: 6) {
            // Narrower, a glyph still tells memory from disk.
            if compact { Image(systemName: symbol).foregroundStyle(Theme.inkMuted).accessibilityHidden(true) } else { Text(title).foregroundStyle(Theme.inkMuted) }
            Text(value)
                .monospacedDigit()
                .foregroundStyle(isHigh ? Theme.danger : Theme.ink)
                .accessibilityLabel("\(title) \(value)")
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .help(help)
    }

    /// "3.1 / 8 GB".
    private static func used(_ used: UInt64, of total: UInt64) -> String {
        let gigabytes = { (bytes: UInt64, digits: Int) in (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(digits))) }
        return "\(gigabytes(used, 1)) / \(gigabytes(total, 0)) GB"
    }
}

/// What is left of the Claude plan's 5-hour session and week, and when each resets, floating
/// at the bottom-left corner. Refreshed every minute.
private struct ClaudeUsageToolbar: View {
    let organization: UUID
    @State private var usage: ClaudeUsage?
    /// Claude's official symbol.
    private static let symbol = Bundle.module.url(forResource: "ClaudeSymbol", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        ZStack {
            if let usage {
                HStack(spacing: 2) {
                    Self.symbol.map { Image(nsImage: $0).resizable().scaledToFit() }
                        .frame(width: 16, height: 16)
                        .padding(.leading, 8)
                        .accessibilityLabel(L("Agent usage"))
                    // Plans without a 5-hour limit get no session from the API: only the week shows.
                    if let session = usage.session {
                        item(L("5h"), session, help: L("Left of the current 5-hour session."), relative: true)
                    }
                    item(L("Week"), usage.week, help: L("Left of this week's limit across every model."), relative: false)
                }
                .font(Theme.Font.label)
                .padding(4)
                .modifier(GlassCapsule())
                .transition(.opacity)
            }
        }
        // Each organization is signed in to its own account: switching restarts the polling.
        .task(id: organization) {
            withAnimation(.smooth(duration: 0.3)) { usage = nil }
            while !Task.isCancelled {
                do {
                    let fresh = try await ClaudeUsageClient.fetch(organization: organization)
                    withAnimation(.smooth(duration: 0.3)) { usage = fresh }
                } catch {
                    NSLog("Claude usage unavailable: %@", String(describing: error))
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func item(_ title: String, _ window: ClaudeUsage.Window?, help: String, relative: Bool) -> some View {
        let remaining = window?.remaining ?? 100
        return HStack(spacing: 6) {
            Text(title).foregroundStyle(Theme.inkMuted)
            Text(remaining / 100, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(remaining < 20 ? Theme.danger : Theme.ink)
                .contentTransition(.numericText())
            if let reset = window?.resetsAt {
                Text(resetText(reset, relative: relative))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .help(help)
    }

    /// The session counts down; the week names the day and time.
    private func resetText(_ date: Date, relative: Bool) -> String {
        if relative {
            let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
            return minutes >= 60 ? L("resets in \(minutes / 60)h \(minutes % 60)m") : L("resets in \(minutes)m")
        }
        return L("resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
    }
}

