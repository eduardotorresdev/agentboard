import AppKit
import SwiftUI

/// Brings logins into a profile so a card (and the agents on it) start out signed in. The
/// developer picks the profile to fill, then imports a cookie file exported from a browser.
struct BrowserImportDialog: View {
    let browsers: BrowserStore
    /// The profile to preselect: the card's, when opened from a card.
    let initialProfile: UUID
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var profile: UUID
    @State private var newProfileName = ""
    @State private var addingProfile = false
    @State private var result: String?
    @State private var isError = false
    @State private var sources: [ChromiumProfile] = []
    @State private var importing: String?

    init(browsers: BrowserStore, initialProfile: UUID, onDone: @escaping () -> Void) {
        self.browsers = browsers
        self.initialProfile = initialProfile
        self.onDone = onDone
        _profile = State(initialValue: initialProfile)
    }

    var body: some View {
        AppDialog(title: L("Import data"),
                  subtitle: L("Bring your logins into a profile so cards on it start signed in.")) {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: L("Into"), message: L("Cards on this profile share these logins.")) {
                    if addingProfile {
                        HStack(spacing: 6) {
                            TextField("", text: $newProfileName, prompt: Text(L("Profile name")))
                                .onSubmit(commitNewProfile)
                            Button(L("Add"), action: commitNewProfile)
                                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        Picker("", selection: $profile) {
                            ForEach(browsers.profiles) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        Button(L("New profile…")) { addingProfile = true }
                            .buttonStyle(.link)
                    }
                }
                FormRow(label: L("From"),
                        message: L("Pick an installed browser to copy its logins, or import a cookie file (JSON).")) {
                    VStack(alignment: .leading, spacing: 0) {
                        if sources.isEmpty {
                            Text(L("No Chromium browser (Chrome, Arc, Edge…) found on this Mac."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(sources) { source in
                                        SourceRow(source: source, busy: importing == source.id) { importFrom(source) }
                                    }
                                }
                            }
                            .frame(maxHeight: sources.count > 5 ? 180 : .infinity)
                        }
                        Divider().padding(.vertical, 8)
                        Button(L("Import from a cookie file…"), action: chooseFile)
                            .buttonStyle(.link)
                        if let result {
                            Text(result)
                                .font(.callout)
                                .foregroundStyle(isError ? Color.red : Theme.accent)
                                .padding(.top, 6)
                        }
                    }
                }
                Text(L("Cards on this profile browse with these logins, and so do the agents connected to them."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Button(L("Done")) {
                onDone()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .task { sources = browsers.chromiumProfiles() }
    }

    private func importFrom(_ source: ChromiumProfile) {
        importing = source.id
        result = nil
        Task {
            defer { importing = nil }
            do {
                let imported = try await browsers.importFromBrowser(source, into: profile)
                isError = false
                var line = String(format: L("Imported %lld cookies from %@."), imported.cookies, source.title)
                if imported.skippedGoogle > 0 {
                    line += " " + String(format: L("Left out %lld Google sign-in cookies so %@ stays signed in."), imported.skippedGoogle, source.browser.label)
                }
                result = line
            } catch {
                isError = true
                result = error.localizedDescription
            }
        }
    }

    private func commitNewProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        profile = browsers.addProfile(named: name).id
        newProfileName = ""
        addingProfile = false
    }

    private func importFile(_ url: URL) {
        do {
            let imported = try browsers.importCookieFile(url, into: profile)
            isError = false
            result = imported.origins > 0
                ? String(format: L("Imported %lld cookies and %lld sites' data."), imported.cookies, imported.origins)
                : String(format: L("Imported %lld cookies."), imported.cookies)
        } catch {
            isError = true
            result = error.localizedDescription
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = L("Import")
        panel.message = L("Choose a cookie file to import into this profile.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }
}

/// One installed browser profile the developer can copy logins from.
private struct SourceRow: View {
    let source: ChromiumProfile
    let busy: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon = source.browser.icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "globe").frame(width: 22, height: 22).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.callout.weight(.medium))
                    Text(source.browser.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L("Import")).font(.callout).foregroundStyle(Theme.accent).opacity(isHovered ? 1 : 0.0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering in withAnimation(.snappy(duration: 0.15)) { isHovered = hovering } }
    }
}
