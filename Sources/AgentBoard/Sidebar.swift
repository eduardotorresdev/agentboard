import SwiftUI

/// Projects and their worktrees, in a panel floating over the canvas. The canvas shows through
/// it blurred, so the board stays in view behind the list.
struct Sidebar: View {
    let store: ProjectStore
    let agents: AgentStore
    let browsers: BrowserStore
    @Binding var selection: WorktreeSelection?
    @Binding var renaming: Worktree?
    @State private var collapsed: Set<Project.ID> = []
    @Namespace private var selectionSpace

    static let width: CGFloat = 264

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(store.projects) { project in
                    group(for: project)
                }
            }
            // The same gap on both sides, so headers and chips sit evenly inside the panel.
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background { SidebarBackdrop() }
    }

    private func group(for project: Project) -> some View {
        let isCollapsed = collapsed.contains(project.id)
        let worktrees = store.worktrees[project.id]
        return VStack(alignment: .leading, spacing: 2) {
            ProjectHeader(name: project.name, count: worktrees?.count, isCollapsed: isCollapsed) {
                withAnimation(.snappy(duration: 0.28)) {
                    if isCollapsed { collapsed.remove(project.id) } else { collapsed.insert(project.id) }
                }
            }
            .contextMenu {
                Button(L("Remove Project"), role: .destructive) { store.removeProject(project) }
            }
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 2) {
                    if let worktrees {
                        ForEach(worktrees) { worktree in
                            row(for: worktree, in: project)
                        }
                    } else {
                        Label(L("Not a git repository"), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .padding(.leading, ProjectHeader.contentInset)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func row(for worktree: Worktree, in project: Project) -> some View {
        let tag = WorktreeSelection(projectID: project.id, worktree: worktree)
        return WorktreeRow(worktree: worktree, name: store.displayName(of: worktree), contents: contents(of: worktree),
                           isSelected: selection == tag, isRenaming: renaming == worktree,
                           selectionSpace: selectionSpace,
                           onSelect: { withAnimation(.snappy(duration: 0.3)) { selection = tag } },
                           onRename: { name in
                               store.rename(worktree, to: name)
                               renaming = nil
                           })
            .contextMenu {
                Button(L("Rename")) { renaming = worktree }
            }
    }

    /// What is on the worktree's canvas, and whether any of it is at work.
    private func contents(of worktree: Worktree) -> WorktreeContents {
        let cards = agents.agents(in: worktree.path)
        let runners = cards.filter { $0.runner != nil }
        return WorktreeContents(hasAgents: cards.contains { $0.runner == nil }, hasRunners: !runners.isEmpty,
                                runnerRunning: runners.contains { agents.runningRunners.contains($0.id) },
                                hasBrowsers: !browsers.browsers(in: worktree.path).isEmpty)
    }
}

/// A project's name over its worktrees; clicking it folds them away.
private struct ProjectHeader: View {
    let name: String
    /// Worktrees in the project, nil when it isn't a git repository.
    let count: Int?
    let isCollapsed: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    private static let badgeSize: CGFloat = 22
    private static let spacing: CGFloat = 9
    private static let padding: CGFloat = 6
    /// Where the text after the badge starts, so worktrees line up under the name.
    static let contentInset = padding + badgeSize + spacing

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Self.spacing) {
                Text(monogram)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Self.badgeSize, height: Self.badgeSize)
                    .background(Theme.accent.opacity(0.13), in: .rect(cornerRadius: 6, style: .continuous))
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let count, isCollapsed || isHovered {
                    Text(count, format: .number)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .opacity(isHovered || isCollapsed ? 1 : 0)
            }
            .padding(.horizontal, Self.padding)
            .frame(height: 32)
            .background(.black.opacity(isHovered ? 0.045 : 0), in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: isHovered)
        .accessibilityLabel(name)
        .accessibilityValue(isCollapsed ? L("Collapsed") : L("Expanded"))
    }

    /// The first letter or digit of the name, as the project's mark.
    private var monogram: String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
    }
}

/// A worktree: its name (alias or folder), and the branch underneath when it says something
/// the name doesn't. The open one sits on a raised white chip.
private struct WorktreeRow: View {
    let worktree: Worktree
    let name: String
    let contents: WorktreeContents
    let isSelected: Bool
    let isRenaming: Bool
    let selectionSpace: Namespace.ID
    let onSelect: () -> Void
    let onRename: (String) -> Void
    @State private var isHovered = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if contents.isEmpty {
                    Image(systemName: worktree.branch == nil ? "circle.dashed" : "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                } else {
                    WorktreeGlyph(contents: contents, isSelected: isSelected)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                title
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        // Lines the name up with the project's name; the chip itself spans the full row.
        .padding(.leading, ProjectHeader.contentInset - 14 - 8)
        .padding(.trailing, 8)
        .background { background }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }

    @ViewBuilder private var title: some View {
        if isRenaming {
            TextField(L("Name"), text: $draft, prompt: Text(worktree.name))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($fieldFocused)
                .onAppear {
                    draft = name
                    fieldFocused = true
                }
                .onSubmit { onRename(draft) }
                .onExitCommand { onRename(name) }
                .onChange(of: fieldFocused) { _, focused in if !focused { onRename(draft) } }
        } else {
            Text(name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.82)))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// The branch, unless it reads the same as the name.
    private var subtitle: String? {
        guard let branch = worktree.branch else { return L("Detached HEAD") }
        return branch == name ? nil : branch
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if isSelected {
            shape
                .fill(Theme.surface)
                .shadow(color: Theme.line.opacity(0.10), radius: 6, y: 2)
                .matchedGeometryEffect(id: "selection", in: selectionSpace)
        } else {
            shape.fill(.black.opacity(isHovered ? 0.045 : 0))
        }
    }
}

/// The canvas blurred behind the sidebar, tinted a step darker than the canvas so the panel
/// reads as its own surface without a border. A plain material, not Liquid Glass, whose rim
/// would outline the edge. A soft shadow falls on the canvas past the trailing edge.
private struct SidebarBackdrop: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Theme.line.opacity(0.07))
            .shadow(color: Theme.line.opacity(0.08), radius: 16, x: 4)
            .ignoresSafeArea()
    }
}
