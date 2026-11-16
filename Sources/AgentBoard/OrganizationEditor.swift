import AppKit
import SwiftUI

/// Name, color and image of an organization, opened by holding its name in the switcher.
struct OrganizationEditor: View {
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
