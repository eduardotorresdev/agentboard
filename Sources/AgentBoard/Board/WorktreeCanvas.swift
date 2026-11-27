import AgentRuntime
import Orchestration
import SwiftUI

/// A worktree's canvas: the Metal board with its agents, and the toolbars floating on top.
struct WorktreeCanvas: View {
    let agents: AgentStore
    let browsers: BrowserStore
    let simulators: SimulatorStore
    let fileTrees: FileTreeStore
    let worktree: Worktree
    let board: BoardController
    /// The user's own board shows its title where a worktree shows its branch, and has no files to browse.
    var title: String?
    /// Where templates are kept, and the project folder they are kept for.
    var database: Database?
    var project = ""
    /// Project and worktree, as decision balloons title themselves.
    var place = ProjectStore.Place(worktree: "")
    /// The project's templates, read again when the project changes and when they are opened or changed.
    @State private var templates: [CanvasTemplate] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            SkyCanvas()
            Board(store: agents, browsers: browsers, simulators: simulators, fileTrees: fileTrees, worktree: worktree.path, place: place, controller: board)
            if let notice {
                EmptyCanvas(symbol: "exclamationmark.triangle", title: L("Your agents can't be shown"), message: notice) { EmptyView() }
                    .padding(.leading, board.leadingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if isEmpty {
                VStack(spacing: 28) {
                    SkyBlobEmptyState().allowsHitTesting(false)
                    if !templates.isEmpty, templates.count <= TemplateCards.limit, !board.isZen {
                        TemplateCards(board: board, database: database, project: project, templates: templates, reload: reloadTemplates)
                            .transition(.opacity)
                    }
                }
                .padding(.leading, board.leadingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            // One row, so the side groups give way to the centered tools instead of overlapping them.
            HStack(alignment: .bottom, spacing: 12) {
                Color.clear.frame(width: 0, height: 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Narrow windows scroll the tools: nothing overlaps.
                ViewThatFits(in: .horizontal) {
                    CanvasToolbar(board: board, hasFiles: title == nil, onHost: worktree.host != nil)
                    ScrollView(.horizontal, showsIndicators: false) { CanvasToolbar(board: board, hasFiles: title == nil, onHost: worktree.host != nil) }
                }
                .layoutPriority(1)
                VStack(alignment: .trailing, spacing: 8) {
                    if !board.isZen {
                        TemplatesMenu(board: board, database: database, project: project, isEmpty: isEmpty,
                                      templates: templates, reload: reloadTemplates)
                            .transition(.opacity)
                    }
                    ViewToolbar(board: board)
                }
                // Never squeezed below its size, or the view toolbar slides under the centered tools.
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
                HStack(spacing: 8) {
                    BranchBadge(branch: worktree.branch, title: title)
                        .allowsHitTesting(false)
                    if let host = agents.host, let stats = agents.hostStats {
                        HostUsage(name: host.name, stats: stats, path: agents.hostPath)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 14)
                .padding(.leading, board.leadingInset + 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .task(id: project) { reloadTemplates() }
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
        .sheet(isPresented: Binding(get: { board.addingEventSource }, set: { board.addingEventSource = $0 })) {
            EventSourceDialog { board.addEventSource(named: $0) }
        }
        .sheet(item: Binding(get: { board.importRequest }, set: { board.importRequest = $0 })) { request in
            let profile: UUID = if case .browser(let id) = request.target { browsers.record(id)?.profile ?? BrowserProfile.defaultID } else { BrowserProfile.defaultID }
            BrowserImportDialog(browsers: browsers, initialProfile: profile) {}
        }
    }

    private func reloadTemplates() {
        do { templates = try database?.templates(project: project) ?? [] } catch { NSLog("AgentBoard: couldn't read the templates: \(error)") }
    }

    private var notice: String? {
        agents.agents(in: worktree.path).isEmpty ? agents.notice : nil
    }

    private var isEmpty: Bool {
        agents.isLoaded && agents.agents(in: worktree.path).isEmpty && agents.postIts(in: worktree.path).isEmpty
            && agents.images(in: worktree.path).isEmpty
            && browsers.browsers(in: worktree.path, on: worktree.host).isEmpty
            && simulators.simulators(in: worktree.path, on: worktree.host).isEmpty
            && fileTrees.trees(in: worktree.path, on: worktree.host).isEmpty
    }
}

/// The board's tools, floating at the bottom center, as icon buttons.
private struct CanvasToolbar: View {
    let board: BoardController
    var hasFiles = true
    /// On a host's worktree: iOS Simulators run on this Mac only, so only Android is offered.
    var onHost = false

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
            addSimulator
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add simulator"))
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
            Button { board.addingEventSource = true } label: { Image(systemName: "bolt") }
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add event source"))
                .help(L("A local webhook: programs on this Mac post events to it, and its channels wake the agents you draw lines to."))
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
        .modifier(CanvasPill())
    }

    /// An iOS Simulator or an Android emulator; a host's worktree only runs Android.
    @ViewBuilder private var addSimulator: some View {
        let android = L("An Android emulator on the worktree's machine, which you and the connected agents can use.")
        if onHost {
            Button { board.addSimulator(.android) } label: { Image(systemName: "iphone") }
                .help(android)
        } else {
            Menu {
                Button { board.addSimulator(.ios) } label: {
                    Text(L("iOS Simulator"))
                    Text(L("An iOS Simulator device you and the connected agents can use."))
                }
                Button { board.addSimulator(.android) } label: {
                    Text(L("Android emulator"))
                    Text(android)
                }
            } label: { Image(systemName: "iphone") }
                .menuIndicator(.hidden)
                .help(L("Add a phone or tablet: an iOS Simulator or an Android emulator."))
        }
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

/// The view toolbar: zoom, fit and organize, floating at the bottom-right corner. Zen is
/// entered from the sidebar, which zen hides: while it is on, the way out is here.
private struct ViewToolbar: View {
    let board: BoardController

    var body: some View {
        HStack(spacing: 2) {
            if board.isZen {
                Button { board.isZen = false } label: { Image(systemName: "figure.walk") }
                    .buttonStyle(ToolbarButtonStyle(compact: true))
                    .help(L("Leave zen mode: bring back the sidebar and the bars."))
                    .accessibilityLabel(L("Leave zen mode"))
            } else {
                zoomControls
            }
        }
        .font(Theme.Font.label)
        .padding(4)
        .modifier(CanvasPill())
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
        .modifier(CanvasPill())
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

/// The canvas toolbars' dark plate: a surface over the canvas, no glass, no shadow.
struct CanvasPill: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Ink controls on the dark plate; hover shows a lighter fill, and a control that is on fills
/// with the accent.
struct ToolbarButtonStyle: ButtonStyle {
    var compact = false
    /// A lone symbol in a square button.
    var icon = false
    /// On, for a control that toggles.
    var active = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        return configuration.label
            .foregroundStyle(active ? Theme.onAccent : Theme.ink.opacity(isEnabled ? 0.9 : 0.35))
            .padding(.horizontal, icon ? 0 : compact ? 8 : 12)
            .padding(.vertical, icon ? 0 : 6)
            .frame(width: icon ? 36 : nil, height: icon ? 36 : nil)
            .background(active ? Theme.accent : Theme.surfaceDeep.opacity(configuration.isPressed ? 1 : isHovered && isEnabled ? 0.7 : 0), in: shape)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.snappy(duration: 0.2), value: isHovered)
    }
}

/// What the worktree's host is using (CPU, memory, disk), beside the branch badge and as tall
/// as it, as its core reports it every couple of seconds.
private struct HostUsage: View {
    let name: String
    let stats: HostStats
    var path: HostChannel.Path?

    var body: some View {
        HStack(spacing: 0) {
            Label(name, systemImage: "icloud")
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .help(path.map(\.note) ?? "")
            item(L("CPU"), "cpu", stats.cpu.formatted(.percent.precision(.fractionLength(0))), isHigh: stats.cpu > 0.9,
                 help: L("Of every processor on \(name) together."))
            item(L("Memory"), "memorychip", Self.used(stats.memoryUsed, of: stats.memoryTotal), isHigh: stats.memoryUsed > stats.memoryTotal / 10 * 9,
                 help: L("Memory in use on \(name), of what it has."))
            item(L("Disk"), "internaldrive", Self.used(stats.diskUsed, of: stats.diskTotal), isHigh: stats.diskUsed > stats.diskTotal / 10 * 9,
                 help: L("Disk in use on \(name), of the volume its home folder is on."))
        }
        .font(Theme.Font.caption)
        // The branch badge's padding, so both sit at one height.
        .padding(.vertical, 4)
        .modifier(CanvasPill())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func item(_ title: String, _ symbol: String, _ value: String, isHigh: Bool, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(Theme.inkMuted).accessibilityHidden(true)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(isHigh ? Theme.danger : Theme.ink)
                .accessibilityLabel("\(title) \(value)")
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 6)
        .help(help)
    }

    /// "3.1 / 8 GB".
    private static func used(_ used: UInt64, of total: UInt64) -> String {
        let gigabytes = { (bytes: UInt64, digits: Int) in (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(digits))) }
        return "\(gigabytes(used, 1)) / \(gigabytes(total, 0)) GB"
    }
}
