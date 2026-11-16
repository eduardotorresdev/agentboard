import SwiftUI

/// What one kind of thing (MCP servers or skills) exists today, by agent and scope.
struct InventoryPanel: View {
    enum Kind: String, CaseIterable, Identifiable {
        case mcps, skills
        var id: String { rawValue }
        var title: String { self == .mcps ? L("MCPs") : L("Skills") }
        var help: String {
            self == .mcps ? L("MCP servers the agents have configured") : L("Skills the agents have installed")
        }
    }

    let kind: Kind
    let organization: UUID
    let project: String?
    @State private var agent: Inventory.Agent = .claude
    @State private var snapshot: Inventory.Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(Theme.Font.headline).tracking(Theme.Font.headlineTracking).foregroundStyle(Theme.ink)
            Picker("", selection: $agent) {
                ForEach(Inventory.Agent.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let snapshot {
                        ForEach(Inventory.Scope.allCases) { scope in
                            section(scope, snapshot[agent]?[scope])
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: .infinity, minHeight: 460, idealHeight: 560, maxHeight: .infinity, alignment: .topLeading)
        .paperSurface()
        .task(id: "\(organization)\(project ?? "")") {
            let organization = organization, project = project
            let loaded = await Task.detached(priority: .userInitiated) {
                Inventory.load(organization: organization, project: project)
            }.value
            withAnimation(.snappy(duration: 0.3)) { snapshot = loaded }
        }
    }

    private func section(_ scope: Inventory.Scope, _ entry: Inventory.Entry?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title(scope)).font(Theme.Font.title).tracking(Theme.Font.titleTracking).foregroundStyle(Theme.ink)
            Text(caption(scope)).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
            let rows = rows(entry)
            if scope == .project && project == nil {
                empty(L("Open a worktree to see its project."))
            } else if rows.isEmpty {
                empty(kind == .mcps ? L("No MCP servers.") : L("No skills."))
            } else {
                ForEach(rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(Theme.Font.heading).foregroundStyle(Theme.ink)
                        if !row.detail.isEmpty {
                            Text(row.detail).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).lineLimit(2)
                        }
                        if !row.secrets.isEmpty {
                            Text(row.secrets).font(Theme.Font.label.monospaced()).foregroundStyle(Theme.onSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.cream, in: .rect(cornerRadius: Theme.Radius.control))
                        }
                        Text(row.source).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.control))
                }
            }
        }
    }

    private struct Row { var id, name, detail, secrets, source: String }

    private func rows(_ entry: Inventory.Entry?) -> [Row] {
        guard let entry else { return [] }
        switch kind {
        case .mcps:
            return entry.servers.map {
                Row(id: $0.id, name: $0.name, detail: $0.target,
                    secrets: $0.secretKeys.map { "\($0) = ••••" }.joined(separator: "  "), source: $0.source)
            }
        case .skills:
            return entry.skills.map { Row(id: $0.id, name: $0.name, detail: $0.summary, secrets: "", source: $0.source) }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
    }

    private func title(_ scope: Inventory.Scope) -> String {
        switch scope {
        case .machine: L("Machine")
        case .organization: L("Organization")
        case .project: L("Project")
        }
    }

    private func caption(_ scope: Inventory.Scope) -> String {
        switch scope {
        case .machine: L("Every agent on this Mac.")
        case .organization: L("Only this organization's agents.")
        case .project: L("Only agents in the open project.")
        }
    }
}
