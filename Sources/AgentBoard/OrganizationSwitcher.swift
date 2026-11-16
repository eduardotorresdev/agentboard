import SwiftUI

/// The organizations by name in a segmented switch, styled like the other top bar controls. A
/// quiet thumb marks the current one; it
/// can be clicked or dragged, follows the pointer while dragged and switches on release to the
/// name under it. Holding a name (or its context menu) edits it; the plus adds an organization.
/// The pointer logic is `OrganizationSwitchGesture`; this view only feeds it and draws.
struct OrganizationSwitcher: View {
    let store: ProjectStore
    @State private var editing: UUID?
    /// Each name's frame in the track.
    @State private var frames: [UUID: CGRect] = [:]
    /// The thumb's edges. Moved by separate springs, so the edge in front leads and the thumb
    /// stretches while it travels and settles to the width of the name it lands on.
    @State private var leading: CGFloat = 0
    @State private var trailing: CGFloat = 0
    @State private var gesture = OrganizationSwitchGesture()
    @State private var hovered: UUID?
    @State private var isAddHovered = false
    /// Name under the pointer while dragging, scrolled into view.
    @State private var dragOver: UUID?
    @GestureState private var isPointerDown = false
    @FocusState private var isFocused: Bool

    /// Longer names truncate; the full name is in their tooltip.
    static let maxLabelWidth: CGFloat = 120
    /// Wider than this, the track scrolls sideways.
    static let maxTrackWidth: CGFloat = 440
    /// The thumb; with the inset, the rail is as tall as the other top bar controls (30).
    private static let height: CGFloat = 24
    /// Space between the rail's edge and the thumb.
    private static let inset: CGFloat = 3
    private static let holdDuration: Duration = .seconds(0.45)
    private static let space = "organizationTrack"
    /// Neutral fills matching the other top bar controls: the rail, and the darker thumb on it.
    private static let railFill = Theme.line.opacity(0.04)
    private static let thumbFill = Theme.line.opacity(0.1)

    private var organizations: [Organization] { store.organizations }

    private var segments: [OrganizationSwitchGesture.Segment] {
        organizations.compactMap { organization in
            frames[organization.id].map { .init(id: organization.id, minX: $0.minX, maxX: $0.maxX) }
        }
    }

    private var trackWidth: CGFloat { (segments.last?.maxX ?? 0) + Self.inset * 2 }

    private var isPressing: Bool {
        if case .pressed = gesture.phase { return true }
        return gesture.phase == .dragging
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    track.padding(Self.inset)
                }
                .frame(width: min(trackWidth, Self.maxTrackWidth), height: Self.height + Self.inset * 2)
                .onChange(of: store.organizationID) { _, id in
                    withAnimation(.smooth) { scroller.scrollTo(id, anchor: .center) }
                }
                .onChange(of: dragOver) { _, id in
                    if let id { withAnimation(.smooth) { scroller.scrollTo(id) } }
                }
                // Once the names are measured, the current one in view (it may be far right).
                .task(id: trackWidth > 0) { if trackWidth > 0 { scroller.scrollTo(store.organizationID, anchor: .center) } }
            }
            .background(Self.railFill, in: .rect(cornerRadius: Theme.Radius.control))
            .overlay {
                // Keyboard focus: the one place a stroke is needed.
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
                    .animation(.snappy(duration: 0.2), value: isFocused)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .onKeyPress(.escape) {
                guard gesture.isActive else { return .ignored }
                apply(gesture.cancel())
                return .handled
            }
            .accessibilityRepresentation {
                Picker(L("Organization"), selection: Binding(get: { store.organizationID }, set: select)) {
                    ForEach(organizations) { Text(OrganizationAvatar.displayName($0)).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .accessibilityActions {
                    ForEach(organizations) { organization in
                        Button(L("Edit \(OrganizationAvatar.displayName(organization))…")) { editing = organization.id }
                    }
                }
            }
            Button(action: add) {
                Image(systemName: "plus")
                    .font(Theme.Font.label)
                    .foregroundStyle(isAddHovered ? Theme.ink : Theme.inkMuted)
                    .frame(width: Self.height + Self.inset * 2, height: Self.height + Self.inset * 2)
                    .background(Theme.line.opacity(isAddHovered ? 0.08 : 0.04), in: .rect(cornerRadius: Theme.Radius.control))
                    .contentShape(.rect(cornerRadius: Theme.Radius.control))
            }
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(.snappy(duration: 0.2)) { isAddHovered = inside } }
            .help(L("New organization: its own projects and its own Claude login"))
            .accessibilityLabel(L("New Organization"))
        }
        .padding(.horizontal, 4)
        .onChange(of: organizations.map(\.id)) { _, ids in
            frames = frames.filter { ids.contains($0.key) }
        }
    }

    /// Names in muted ink, the thumb, then the same names in full ink clipped to the thumb, so the
    /// color changes exactly where the thumb is, without toggling anything.
    private var track: some View {
        let thumb = RoundedRectangle(cornerRadius: Theme.Radius.thumb)
            .frame(width: max(trailing - leading, 0), height: Self.height)
            .position(x: (leading + trailing) / 2, y: Self.height / 2)
        return ZStack(alignment: .topLeading) {
            interactiveLabels
            thumb.foregroundStyle(Self.thumbFill)
                .scaleEffect(y: isPressing ? 0.9 : 1)
                .animation(.bouncy(duration: 0.3), value: isPressing)
                .allowsHitTesting(false)
            highlightedLabels
                .mask { thumb.scaleEffect(y: isPressing ? 0.9 : 1).animation(.bouncy(duration: 0.3), value: isPressing) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .coordinateSpace(.named(Self.space))
        .contentShape(.rect)
        .gesture(drag)
        .onChange(of: isPointerDown) { _, down in if !down { apply(gesture.end()) } }
        .onChange(of: frames) { place(animated: false) }
        .onChange(of: store.organizationID) { place(animated: true) }
    }

    /// The names that measure, hover, edit and get scrolled to.
    private var interactiveLabels: some View {
        HStack(spacing: 0) {
            ForEach(organizations) { organization in
                let name = OrganizationAvatar.displayName(organization)
                label(organization, ink: hovered == organization.id ? Theme.ink : Theme.inkMuted)
                    .background(Theme.line.opacity(hovered == organization.id ? 0.04 : 0),
                                in: .rect(cornerRadius: Theme.Radius.thumb))
                    .animation(.snappy(duration: 0.2), value: hovered)
                    .id(organization.id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[organization.id] = $0 }
                    .onHover { inside in
                        if inside { hovered = organization.id } else if hovered == organization.id { hovered = nil }
                    }
                    .help(L("\(name) — hold to edit"))
                    .contextMenu { Button(L("Edit Organization…")) { editing = organization.id } }
                    .popover(isPresented: binding(for: organization.id), arrowEdge: .bottom) {
                        OrganizationEditor(store: store, id: organization.id, onDone: { editing = nil })
                    }
            }
        }
    }

    /// Drawing only: the same names in full ink, shown through the thumb.
    private var highlightedLabels: some View {
        HStack(spacing: 0) {
            ForEach(organizations) { label($0, ink: Theme.ink) }
        }
    }

    /// Name only: avatars in a quiet bar would fight it. The editor still shows the avatar.
    private func label(_ organization: Organization, ink: Color) -> some View {
        Text(OrganizationAvatar.displayName(organization))
            .font(Theme.Font.label)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.maxLabelWidth)
            .fixedSize()
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(height: Self.height)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($isPointerDown) { _, down, _ in down = true }
            .onChanged { value in
                if gesture.phase == .idle, let press = gesture.press(at: value.startLocation.x, in: segments) {
                    Task {
                        try? await Task.sleep(for: Self.holdDuration)
                        apply(gesture.holdTimeout(press: press))
                    }
                }
                apply(gesture.move(to: value.location.x, in: segments))
            }
            .onEnded { value in
                apply(gesture.release(at: value.location.x, in: segments, current: store.organizationID))
            }
    }

    private func apply(_ effect: OrganizationSwitchGesture.Effect) {
        switch effect {
        case .none:
            break
        case let .follow(minX, maxX, over):
            dragOver = over
            move(to: minX, maxX, front: .interactiveSpring(response: 0.18, dampingFraction: 0.8),
                 back: .interactiveSpring(response: 0.3, dampingFraction: 0.75))
        case .snap:
            dragOver = nil
            place(animated: true)
        case let .select(id):
            dragOver = nil
            select(id)
            place(animated: true)
        case let .openEditor(id):
            editing = id
        }
    }

    /// Settles the thumb on the current organization.
    private func place(animated: Bool) {
        guard gesture.phase != .dragging, let frame = frames[store.organizationID] else { return }
        if animated {
            move(to: frame.minX, frame.maxX, front: .bouncy(duration: 0.32, extraBounce: 0.1), back: .bouncy(duration: 0.48))
        } else {
            leading = frame.minX
            trailing = frame.maxX
        }
    }

    private func move(to newLeading: CGFloat, _ newTrailing: CGFloat, front: Animation, back: Animation) {
        let forward = newLeading > leading
        withAnimation(forward ? front : back) { trailing = newTrailing }
        withAnimation(forward ? back : front) { leading = newLeading }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let id = OrganizationSwitchGesture.step(from: store.organizationID, by: offset, in: organizations.map(\.id))
        else { return .ignored }
        select(id)
        return .handled
    }

    /// Exactly what the avatar switcher did.
    private func select(_ id: UUID) {
        withAnimation(.snappy(duration: 0.3)) { store.selectOrganization(id) }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { editing == id }, set: { if !$0 { editing = nil } })
    }

    private func add() {
        let number = organizations.count + 1
        let organization = store.addOrganization(named: L("Organization \(number)"))
        // Straight to naming it.
        editing = organization.id
    }
}
