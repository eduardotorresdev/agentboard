import AppKit
import SwiftUI

/// The organizations as round avatars in the toolbar: clicking one switches to it, holding one
/// edits it, and the last one adds an organization.
struct OrganizationSwitcher: View {
    let store: ProjectStore
    @State private var editing: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.organizations) { organization in
                OrganizationBubble(organization: organization,
                                   isSelected: organization.id == store.organizationID,
                                   onSelect: { withAnimation(.snappy(duration: 0.3)) { store.selectOrganization(organization.id) } },
                                   onEdit: { editing = organization.id })
                    .popover(isPresented: binding(for: organization.id), arrowEdge: .bottom) {
                        OrganizationEditor(store: store, id: organization.id, onDone: { editing = nil })
                    }
            }
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: OrganizationBubble.size, height: OrganizationBubble.size)
                    .background(Theme.accent.opacity(0.12), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(L("New organization: its own projects and its own Claude login"))
            .accessibilityLabel(L("New Organization"))
        }
        .padding(.horizontal, 4)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { editing == id }, set: { if !$0 { editing = nil } })
    }

    private func add() {
        let number = store.organizations.count + 1
        let organization = store.addOrganization(named: L("Organization \(number)"))
        // Straight to naming it.
        editing = organization.id
    }
}

/// One organization in the switcher. Held for a moment, it opens its editor.
private struct OrganizationBubble: View {
    let organization: Organization
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    @State private var isHovered = false
    @State private var isPressing = false

    static let size: CGFloat = 22

    var body: some View {
        OrganizationAvatar(organization: organization, size: Self.size)
            .saturation(isSelected || isHovered ? 1 : 0.15)
            .opacity(isSelected || isHovered ? 1 : 0.6)
            .scaleEffect(isPressing ? 0.86 : isSelected ? 1 : 0.9)
            .shadow(color: Theme.line.opacity(isSelected ? 0.22 : 0), radius: 3, y: 1.5)
            .contentShape(.circle)
            .onHover { hovering in withAnimation(.snappy(duration: 0.2)) { isHovered = hovering } }
            .onTapGesture(perform: onSelect)
            .onLongPressGesture(minimumDuration: 0.45, perform: onEdit) { pressing in
                withAnimation(.bouncy(duration: 0.35)) { isPressing = pressing }
            }
            .contextMenu { Button(L("Edit Organization…"), action: onEdit) }
            .animation(.snappy(duration: 0.3), value: isSelected)
            .help(L("\(OrganizationAvatar.displayName(organization)) — hold to edit"))
            .accessibilityElement()
            .accessibilityLabel(OrganizationAvatar.displayName(organization))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: Text(L("Edit Organization…")), onEdit)
    }
}

/// An organization's round avatar: its image, or its initial on its color.
struct OrganizationAvatar: View {
    let organization: Organization
    let size: CGFloat

    /// Avatar colors. No greens or teals; amber takes dark ink.
    static let palette: [(fill: Color, ink: Color)] = [
        (Theme.accent, .white),
        (Theme.secondary, .white),
        (Color(red: 0x00 / 255, green: 0x90 / 255, blue: 0xFF / 255), .white),
        (Color(red: 0xD6 / 255, green: 0x40 / 255, blue: 0x9F / 255), .white),
        (Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255), .white),
        (Color(red: 0x3E / 255, green: 0x63 / 255, blue: 0xDD / 255), .white),
        (Color(red: 0xFF / 255, green: 0xB2 / 255, blue: 0x24 / 255), Color(red: 0x4E / 255, green: 0x2A / 255, blue: 0x00 / 255)),
        (Color(red: 0xAD / 255, green: 0x7F / 255, blue: 0x58 / 255), .white),
    ]

    /// The stored name, with the default organization's translated until the user renames it.
    static func displayName(_ organization: Organization) -> String {
        organization.isDefault && organization.name == "Default" ? L("Default") : organization.name
    }

    var body: some View {
        let colors = Self.palette[organization.color % Self.palette.count]
        Group {
            if let path = organization.icon, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(Self.displayName(organization).first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(colors.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

/// Name, color and image of an organization, opened by holding its avatar.
private struct OrganizationEditor: View {
    let store: ProjectStore
    let id: UUID
    let onDone: () -> Void
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    private var organization: Organization? { store.organizations.first { $0.id == id } }

    var body: some View {
        if let organization {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    OrganizationAvatar(organization: organization, size: 44)
                        .animation(.snappy(duration: 0.25), value: organization)
                    TextField(L("Name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .onSubmit { commitName(organization); onDone() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Color")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        ForEach(OrganizationAvatar.palette.indices, id: \.self) { index in
                            swatch(index, in: organization)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button(L("Choose Image…")) { chooseImage(organization) }
                        if organization.icon != nil {
                            Button(L("Use Initial")) { store.clearIcon(of: organization) }
                        }
                    }
                    Text(L("An image replaces the initial and color."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !organization.isDefault {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(L("Remove Organization"), role: .destructive) {
                            onDone()
                            store.removeOrganization(organization)
                        }
                        Text(L("Its project list goes; the folders and its Claude login stay on disk."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(width: 280)
            .onAppear {
                name = OrganizationAvatar.displayName(organization)
                isNameFocused = true
            }
            .onDisappear { commitName(organization) }
        }
    }

    private func swatch(_ index: Int, in organization: Organization) -> some View {
        let isChosen = organization.color == index && organization.icon == nil
        return Button {
            var updated = organization
            updated.color = index
            store.updateOrganization(updated)
            if organization.icon != nil { store.clearIcon(of: updated) }
        } label: {
            Circle()
                .fill(OrganizationAvatar.palette[index].fill)
                .frame(width: 20, height: 20)
                .overlay {
                    if isChosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(OrganizationAvatar.palette[index].ink)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(isChosen ? 1.1 : 1)
                .animation(.bouncy(duration: 0.3), value: isChosen)
        }
        .buttonStyle(.plain)
    }

    private func commitName(_ organization: Organization) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != OrganizationAvatar.displayName(organization),
              let current = store.organizations.first(where: { $0.id == id }) else { return }
        var updated = current
        updated.name = trimmed
        store.updateOrganization(updated)
    }

    private func chooseImage(_ organization: Organization) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.prompt = L("Use Image")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setIcon(of: organization, from: url)
    }
}

extension NSImage {
    /// The image cropped to a centered square and scaled to `side` points, as PNG data.
    func squarePNG(side: CGFloat) -> Data? {
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let length = min(source.width, source.height)
        let crop = CGRect(x: (source.width - length) / 2, y: (source.height - length) / 2, width: length, height: length)
        guard let square = source.cropping(to: crop) else { return nil }
        let pixels = Int(side * 2)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        context.imageInterpolation = .high
        context.cgContext.draw(square, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return bitmap.representation(using: .png, properties: [:])
    }
}
