import AgentRuntime
import SwiftUI

/// A worktree's canvas: the Metal board with its agents, and the toolbars floating on top.
struct WorktreeCanvas: View {
    let agents: AgentStore
    let browsers: BrowserStore
    let worktree: Worktree
    let board: BoardController

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.canvas
            Board(store: agents, browsers: browsers, worktree: worktree.path, controller: board)
            if let notice {
                EmptyCanvas(symbol: "exclamationmark.triangle", title: L("Your agents can't be shown"), message: notice) { EmptyView() }
                    .padding(.leading, board.leadingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if isEmpty {
                EmptyCanvas(
                    symbol: "terminal",
                    title: L("No agents yet"),
                    message: L("Add an agent from the bar below. It starts in this worktree's folder.")
                ) { EmptyView() }
                .padding(.leading, board.leadingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            CanvasToolbar(board: board)
                .padding(.bottom, 16)
                .padding(.leading, board.leadingInset)
            NavigationToolbar(board: board)
                .padding([.bottom, .trailing], 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .animation(.smooth(duration: 0.3), value: isEmpty)
        .animation(.smooth(duration: 0.3), value: notice)
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
            RunnerDialog(worktree: worktree.path) { command, name, directory in
                board.addRunner(command: command, name: name, directory: directory)
            }
        }
        .sheet(item: Binding(get: { board.importRequest }, set: { board.importRequest = $0 })) { request in
            let profile: UUID = if case .browser(let id) = request.target { browsers.record(id)?.profile ?? BrowserProfile.defaultID } else { BrowserProfile.defaultID }
            BrowserImportDialog(browsers: browsers, initialProfile: profile) {}
        }
    }

    /// Shown where the cards would be, when there are none to show.
    private var notice: String? {
        agents.agents(in: worktree.path).isEmpty ? agents.notice : nil
    }

    private var isEmpty: Bool {
        agents.isLoaded && agents.agents(in: worktree.path).isEmpty && agents.postIts(in: worktree.path).isEmpty
            && browsers.browsers(in: worktree.path).isEmpty
    }
}

/// The board's tools, floating at the bottom center, as icon buttons.
private struct CanvasToolbar: View {
    let board: BoardController

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
                .help(L("Keeps a command running, such as a dev server."))
            Button { board.addPostIt() } label: { Image(systemName: "note.text") }
                .buttonStyle(ToolbarButtonStyle(icon: true))
                .fixedSize()
                .accessibilityLabel(L("Add post-it"))
                .help(L("A new post-it in markdown: you and every agent connected to it read and write it."))
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
                    Button(provider.title) { board.add(provider) }
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

    var body: some View {
        HStack(spacing: 2) {
            Button(action: board.fitAgents) {
                Image(systemName: "viewfinder")
            }
            .buttonStyle(ToolbarButtonStyle(compact: true))
            .help(L("Fits every agent on screen."))

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
        .font(.callout.weight(.medium))
        .padding(4)
        .modifier(GlassCapsule())
    }
}

/// Liquid Glass where the system has it, a translucent material before that.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: .capsule)
                .shadow(color: Theme.line.opacity(0.10), radius: 12, y: 4)
        }
    }
}

/// Black controls on glass; hover and press show as a faint black fill.
private struct ToolbarButtonStyle: ButtonStyle {
    var compact = false
    /// A lone symbol in a round button.
    var icon = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black.opacity(isEnabled ? 0.85 : 0.3))
            .padding(.horizontal, icon ? 0 : compact ? 8 : 12)
            .padding(.vertical, icon ? 0 : 6)
            .frame(width: icon ? 40 : nil, height: icon ? 40 : nil)
            .background(.black.opacity(configuration.isPressed ? 0.12 : isHovered && isEnabled ? 0.06 : 0), in: .capsule)
            .contentShape(.capsule)
            .onHover { isHovered = $0 }
            .animation(.snappy(duration: 0.2), value: isHovered)
    }
}
