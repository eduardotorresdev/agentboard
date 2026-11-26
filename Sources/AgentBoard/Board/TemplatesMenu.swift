import SwiftUI

/// The project's memorized canvases, in a dropdown that opens upward from above the view
/// toolbar: saves the canvas as one, lays one out again, removes one.
struct TemplatesMenu: View {
    let board: BoardController
    let database: Database?
    /// What the templates belong to: the project's folder, shared by all its worktrees.
    let project: String
    /// Nothing on the canvas to memorize.
    let isEmpty: Bool
    /// The project's templates, kept by the canvas, and how to read them again.
    let templates: [CanvasTemplate]
    let reload: () -> Void
    @State private var isOpen = false
    @State private var removing: CanvasTemplate?
    @State private var naming: CanvasTemplate?

    var body: some View {
        // Nothing to memorize, and nothing memorized or few enough to show on the empty canvas
        // itself (see `TemplateCards`): no button at all.
        ZStack {
            if !isEmpty || templates.count > TemplateCards.limit {
                Button { isOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(L("Templates"))
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(ToolbarButtonStyle(compact: true))
                .font(Theme.Font.label)
                .padding(4)
                .modifier(CanvasPill())
                .help(L("Canvases memorized for this project: lay one out here, or memorize this one."))
                .popover(isPresented: $isOpen, arrowEdge: .top) { list }
                .transition(.opacity)
            }
        }
        // Read again each time it opens, so the list never shows less than what is kept.
        .onChange(of: isOpen) { if isOpen { reload() } }
    }

    private var list: some View {
        VStack(spacing: 6) {
            if !templates.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(templates) { template in
                            TemplateRow(template: template) {
                                isOpen = false
                                board.apply(template)
                            } onRemove: { removing = template } onRename: { naming = template }
                        }
                    }
                }
                .frame(height: min(CGFloat(templates.count) * (TemplateRow.height + 6) - 6, 372))
            }
            if !isEmpty, let current = board.template(), !current.cards.isEmpty {
                Button { naming = current } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(Theme.Font.label).foregroundStyle(Theme.accentText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("Create new")).font(Theme.Font.label).foregroundStyle(Theme.ink)
                            // Counts beside each kind's symbol: all five kinds fit the row, where words were cut short.
                            HStack(spacing: 8) {
                                ForEach(current.counts, id: \.symbol) { part in
                                    HStack(spacing: 2) {
                                        Text(verbatim: "\(part.count)")
                                        Image(systemName: part.symbol)
                                    }
                                }
                            }
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize()
                            .accessibilityElement()
                            .accessibilityLabel(current.summary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.control))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(L("Memorizes this canvas: its cards, their places and lines, to reuse in this project's worktrees."))
            }
        }
        .padding(8)
        .frame(width: 220)
        .background(Theme.surfaceDeep)
        .animation(.snappy(duration: 0.3), value: templates)
        .modifier(TemplateRemoval(removing: $removing, database: database, reload: reload))
        .modifier(TemplateNaming(naming: $naming, database: database, project: project, reload: reload))
    }
}

/// The project's templates on an empty canvas, when they are few enough to show at once: a
/// click lays one out, without opening the dropdown first.
struct TemplateCards: View {
    /// More templates than this go in the dropdown instead.
    static let limit = 3

    let board: BoardController
    let database: Database?
    let project: String
    let templates: [CanvasTemplate]
    let reload: () -> Void
    @State private var removing: CanvasTemplate?
    @State private var naming: CanvasTemplate?

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(L("Or start from a template")).font(Theme.Font.label).foregroundStyle(Theme.ink)
                Text(L("Lays out its cards and lines on this canvas.")).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            }
            HStack(spacing: 8) {
                ForEach(templates) { template in
                    TemplateRow(template: template) { board.apply(template) } onRemove: { removing = template } onRename: { naming = template }
                        .frame(width: 204)
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: templates)
        .modifier(TemplateRemoval(removing: $removing, database: database, reload: reload))
        .modifier(TemplateNaming(naming: $naming, database: database, project: project, reload: reload))
    }
}

/// Asks for the name of the template in `naming` and saves it under that name: a new one, or
/// one being renamed. A name is required.
private struct TemplateNaming: ViewModifier {
    @Binding var naming: CanvasTemplate?
    let database: Database?
    let project: String
    let reload: () -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        content
            .alert(L("Name this template"), isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), presenting: naming) { template in
                TextField(L("Name"), text: $name)
                Button(L("Save")) {
                    var named = template
                    named.name = trimmed
                    do { try database?.saveTemplate(named, project: project) } catch { NSLog("AgentBoard: couldn't save the template: \(error)") }
                    reload()
                }
                .disabled(trimmed.isEmpty)
                Button(L("Cancel"), role: .cancel) {}
            } message: { _ in
                Text(L("Shown on the template, to tell it apart from the others."))
            }
            .onChange(of: naming) { name = naming?.name ?? "" }
    }
}

/// Asks before removing the template in `removing`.
private struct TemplateRemoval: ViewModifier {
    @Binding var removing: CanvasTemplate?
    let database: Database?
    let reload: () -> Void

    func body(content: Content) -> some View {
        content.alert(L("Remove this template?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { template in
            Button(L("Remove"), role: .destructive) {
                do { try database?.deleteTemplate(id: template.id) } catch { NSLog("AgentBoard: couldn't remove the template: \(error)") }
                reload()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("The canvases it was laid out on stay as they are. This can't be undone."))
        }
    }
}

/// A template, shown as its layout. A click lays it out; dragging it sideways uncovers the
/// button that removes it.
private struct TemplateRow: View {
    static let height: CGFloat = 96
    private static let reveal: CGFloat = 72

    let template: CanvasTemplate
    let onApply: () -> Void
    let onRemove: () -> Void
    let onRename: () -> Void
    @State private var offset: CGFloat = 0
    @State private var isRevealed = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onRemove) {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text(L("Remove")).font(Theme.Font.caption)
                }
                .foregroundStyle(Theme.onDanger)
                .frame(width: Self.reveal - 8)
                .frame(maxHeight: .infinity)
                .background(Theme.danger, in: .rect(cornerRadius: Theme.Radius.card))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Covered by the thumbnail until dragged; the context menu and VoiceOver remove without dragging.
            .accessibilityHidden(true)
            TemplateThumbnail(template: template)
                .overlay(alignment: .bottomLeading) {
                    Text(template.title)
                        .font(Theme.Font.caption)
                        .foregroundStyle(template.name == nil ? Theme.inkMuted : Theme.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.control))
                        .padding(6)
                }
                .offset(x: offset)
                .onTapGesture { if isRevealed { settle(false) } else { onApply() } }
                .gesture(DragGesture(minimumDistance: 6)
                    .onChanged { offset = min(0, max(-Self.reveal, (isRevealed ? -Self.reveal : 0) + $0.translation.width)) }
                    .onEnded { _ in settle(offset < -Self.reveal / 2) })
        }
        .frame(height: Self.height)
        .contextMenu {
            Button(L("Rename"), action: onRename)
            Button(L("Remove"), role: .destructive, action: onRemove)
        }
        .help(L("Replaces this canvas with the template. Drag it sideways to remove it."))
        .accessibilityElement()
        .accessibilityLabel(L("Template \(template.title) with \(template.cards.count) cards"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onApply)
        .accessibilityAction(named: Text(L("Rename")), onRename)
        .accessibilityAction(named: Text(L("Remove")), onRemove)
    }

    private func settle(_ revealed: Bool) {
        withAnimation(.snappy(duration: 0.25)) {
            isRevealed = revealed
            offset = revealed ? -Self.reveal : 0
        }
    }
}

/// The template's cards and lines in miniature, colored by what each card is.
private struct TemplateThumbnail: View {
    let template: CanvasTemplate

    var body: some View {
        Canvas { context, size in
            let frames = template.thumbnail(in: size)
            for line in template.lines where frames.indices.contains(line.a) && frames.indices.contains(line.b) {
                var path = Path()
                path.move(to: CGPoint(x: frames[line.a].midX, y: frames[line.a].midY))
                path.addLine(to: CGPoint(x: frames[line.b].midX, y: frames[line.b].midY))
                context.stroke(path, with: .color(Theme.inkMuted), lineWidth: 1)
            }
            for (card, frame) in zip(template.cards, frames) {
                let color = switch card.kind {
                case .agent: Theme.accent
                case .runner: Theme.deep
                case .postIt: Theme.color(Theme.Hex.blueLight)
                case .browser, .simulator, .fileTree: Theme.inkMuted
                }
                context.fill(Path(roundedRect: frame, cornerRadius: 2), with: .color(color))
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card))
        .contentShape(.rect)
    }
}
