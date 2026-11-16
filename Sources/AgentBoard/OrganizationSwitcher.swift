import AppKit
import SwiftUI

/// The active organization's avatar in the top bar. A dot in its corner tells that another
/// organization has an agent waiting for the user (deep blue) or crashed (red). Clicking it opens
/// the organization menu, which lists them all with their status, switches, edits and adds.
struct OrganizationSwitcher: View {
    let store: ProjectStore
    let agents: AgentStore
    @State private var menu = OrganizationMenuPanel()
    @State private var isHovered = false

    private var active: Organization? { store.organizations.first { $0.id == store.organizationID } }

    private var attention: [UUID: OrganizationAttention] {
        OrganizationAttention.byOrganization(cards: agents.agents, status: agents.cardStatus, active: store.organizationID)
    }

    var body: some View {
        let others = attention
        let barStatus = OrganizationAttention.barStatus(others)
        Button { menu.toggle(store: store, attention: { attention }) } label: {
            if let active {
                OrganizationBarAvatar(organization: active, status: barStatus, isHovered: isHovered)
            }
        }
        .buttonStyle(.plain)
        .background(OrganizationMenuAnchor(panel: menu))
        .onHover { hovering in withAnimation(.snappy(duration: 0.2)) { isHovered = hovering } }
        .help(L("Organizations: switch, edit or add"))
        .accessibilityLabel(L("Organization: \(active.map(OrganizationAvatar.displayName) ?? "")"))
        .accessibilityValue(others.values.compactMap(\.summary).joined(separator: "; "))
        .accessibilityHint(L("Opens the list of organizations"))
    }
}

/// The bar's avatar, with the most pressing status of the other organizations in its corner.
struct OrganizationBarAvatar: View {
    let organization: Organization
    let status: CardStatus?
    var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            OrganizationAvatar(organization: organization, size: 22)
                .scaleEffect(isHovered ? 1.06 : 1)
            if let status {
                // A 2pt knockout ring in the bar's own white keeps the dot apart from the avatar.
                Circle().fill(status.color)
                    .frame(width: 8, height: 8)
                    .padding(2)
                    .background(Theme.surface, in: .circle)
                    .offset(x: 4, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 30, height: 30)
        .contentShape(.circle)
        .animation(.bouncy(duration: 0.35), value: status)
    }
}

/// Where the menu hangs from: the avatar's frame on screen.
private struct OrganizationMenuAnchor: NSViewRepresentable {
    let panel: OrganizationMenuPanel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        panel.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { panel.anchor = view }
}

/// The organization menu: an app-owned, borderless glass panel under the avatar. It closes on
/// Escape, on a click anywhere else (the panel stops being key) and after a choice.
@MainActor
final class OrganizationMenuPanel: NSObject, NSWindowDelegate {
    weak var anchor: NSView?
    private var panel: NSPanel?
    private let state = OrganizationMenuState()
    /// When it last closed: the click on the avatar that closes it must not reopen it.
    private var closedAt = Date.distantPast

    func toggle(store: ProjectStore, attention: @escaping () -> [UUID: OrganizationAttention]) {
        if panel != nil { return close() }
        guard Date().timeIntervalSince(closedAt) > 0.25, let anchor, let window = anchor.window else { return }
        let content = OrganizationMenu(store: store, attention: attention, state: state, close: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let below = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let panel = NSPanel(contentRect: CGRect(x: below.maxX - size.width + 8, y: below.minY - size.height - 6,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = host
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = false
        self.panel = panel
        state.editing = nil
        state.isShown = false
        panel.makeKeyAndOrderFront(nil)
        withAnimation(.snappy(duration: 0.28)) { state.isShown = true }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        closedAt = Date()
        withAnimation(.snappy(duration: 0.2)) { state.isShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { panel.orderOut(nil) }
    }

    /// A click outside makes another window key.
    func windowDidResignKey(_ notification: Notification) { close() }

    /// Grows or shrinks with its content (the editor is taller than the list), keeping its top.
    func fit() {
        guard let panel, let size = panel.contentView?.fittingSize else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }
}

@MainActor
@Observable
final class OrganizationMenuState {
    var isShown = false
    /// The organization being edited in place of the list.
    var editing: UUID?
}

/// The menu's content: each organization with its avatar, name and status, the active one marked;
/// then "New organization". Arrows move, Return chooses, Escape closes.
private struct OrganizationMenu: View {
    let store: ProjectStore
    let attention: () -> [UUID: OrganizationAttention]
    let state: OrganizationMenuState
    let close: () -> Void
    @State private var navigation: OrganizationMenuNavigation?
    @State private var hovered: OrganizationMenuNavigation.Item?
    @FocusState private var isFocused: Bool

    private static let width: CGFloat = 280
    private static let corner: CGFloat = 14

    var body: some View {
        Group {
            if let id = state.editing {
                OrganizationEditor(store: store, id: id, onDone: { withAnimation(.snappy(duration: 0.25)) { state.editing = nil } })
            } else {
                list
            }
        }
        .frame(width: Self.width)
        .modifier(MenuGlass(corner: Self.corner))
        .scaleEffect(state.isShown ? 1 : 0.94, anchor: .topTrailing)
        .opacity(state.isShown ? 1 : 0)
        .padding(1)
    }

    private var list: some View {
        let others = attention()
        let navigation = navigation ?? OrganizationMenuNavigation(organizations: store.organizations.map(\.id),
                                                                  active: store.organizationID)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(store.organizations) { organization in
                row(organization, attention: others[organization.id], highlighted: navigation.highlightedItem == .organization(organization.id))
            }
            Divider().padding(.vertical, 4).opacity(0) // spacing only: rows are separated by fill
            createRow(highlighted: navigation.highlightedItem == .create)
        }
        .padding(6)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            self.navigation = navigation
            isFocused = true
        }
        .onKeyPress(.upArrow) { press(.up) }
        .onKeyPress(.downArrow) { press(.down) }
        .onKeyPress(.return) { press(.enter) }
        .onKeyPress(.escape) { press(.escape) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Organizations"))
    }

    private func press(_ key: OrganizationMenuNavigation.Key) -> KeyPress.Result {
        guard var navigation else { return .ignored }
        let action = navigation.press(key, active: store.organizationID)
        withAnimation(.snappy(duration: 0.15)) { self.navigation = navigation }
        perform(action)
        return .handled
    }

    private func perform(_ action: OrganizationMenuNavigation.Action) {
        switch action {
        case .none: break
        case .close: close()
        case let .select(id):
            // Exactly what the switcher always did.
            withAnimation(.snappy(duration: 0.3)) { store.selectOrganization(id) }
            close()
        case .create:
            let number = store.organizations.count + 1
            let organization = store.addOrganization(named: L("Organization \(number)"))
            // Straight to naming it.
            withAnimation(.snappy(duration: 0.25)) { state.editing = organization.id }
        }
    }

    private func row(_ organization: Organization, attention: OrganizationAttention?, highlighted: Bool) -> some View {
        let isActive = organization.id == store.organizationID
        let item = OrganizationMenuNavigation.Item.organization(organization.id)
        let name = OrganizationAvatar.displayName(organization)
        return HStack(spacing: 10) {
            OrganizationAvatar(organization: organization, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(Theme.Font.body.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.deep : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let attention, let summary = attention.summary, let status = attention.status {
                    HStack(spacing: 5) {
                        CardStatusDot(status: status)
                        Text(summary).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
            Spacer(minLength: 4)
            if hovered == item || highlighted {
                Button { withAnimation(.snappy(duration: 0.25)) { state.editing = organization.id } } label: {
                    Image(systemName: "pencil")
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(L("Edit Organization…"))
                .accessibilityHidden(true)
                .transition(.opacity)
            }
            if isActive {
                Image(systemName: "checkmark")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Theme.accentTint : highlighted || hovered == item ? Theme.surfaceDeep : .clear,
                    in: .rect(cornerRadius: Theme.Radius.control))
        .contentShape(.rect(cornerRadius: Theme.Radius.control))
        .onHover { inside in hover(item, inside) }
        .onTapGesture { perform(isActive ? .close : .select(organization.id)) }
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(attention?.summary ?? "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { perform(isActive ? .close : .select(organization.id)) }
        .accessibilityAction(named: Text(L("Edit Organization…"))) { state.editing = organization.id }
    }

    private func createRow(highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(Theme.Font.label)
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.accentSoft, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("New Organization")).font(Theme.Font.body).foregroundStyle(Theme.ink)
                Text(L("Its own projects and its own agent login")).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(highlighted || hovered == .create ? Theme.surfaceDeep : .clear, in: .rect(cornerRadius: Theme.Radius.control))
        .contentShape(.rect(cornerRadius: Theme.Radius.control))
        .onHover { inside in hover(.create, inside) }
        .onTapGesture { perform(.create) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform(.create) }
    }

    private func hover(_ item: OrganizationMenuNavigation.Item, _ inside: Bool) {
        withAnimation(.snappy(duration: 0.15)) {
            if inside {
                hovered = item
                navigation?.highlight(item)
            } else if hovered == item {
                hovered = nil
            }
        }
    }
}

/// The chrome's material: Liquid Glass where the system has it, a translucent material before.
private struct MenuGlass: ViewModifier {
    let corner: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: corner))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: corner))
        }
    }
}
