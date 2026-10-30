import Connections
import Foundation

/// The browser tools: an agent drives the browser cards connected to it by a line. The core
/// lists them to agents (`BrowserRelay`) and hands each call to the board, which runs it here.
@MainActor
final class BrowserTools {
    private let store: BrowserStore
    private unowned let agents: AgentStore

    init(store: BrowserStore, agents: AgentStore) {
        self.store = store
        self.agents = agents
    }

    func call(_ name: String, arguments: [String: Any], caller: UUID) async -> ToolResult {
        if name == "browser_list" { return .text(list(for: caller)) }
        guard name.hasPrefix("browser_") else { return .error("Unknown tool “\(name)”.") }
        let browser: BrowserElement
        switch resolve(arguments["browser"] as? String, for: caller) {
        case .success(let found): browser = found
        case .failure(let message): return .error(message.text)
        }
        var params = arguments
        params["browser"] = nil
        params["caller"] = caller.uuidString
        do {
            let result = try await store.call(String(name.dropFirst("browser_".count)), on: browser.id, params)
            var content: [ToolContent] = [.text("\(browser.name): " + (result["text"] as? String ?? "Done."))]
            if let image = (result["image"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                content.append(.image(image, mimeType: result["mimeType"] as? String ?? "image/png"))
            }
            return ToolResult(content)
        } catch {
            return .error("\(browser.name): \(error.localizedDescription)")
        }
    }

    /// The browsers connected to `caller`, in connection order.
    private func peers(of caller: UUID) -> [BrowserElement] {
        agents.connections.compactMap { $0.other(than: caller) }
            .filter { store.record($0) != nil }
            .map { BrowserElement(id: $0, store: store) }
    }

    private struct Refusal: Error {
        let text: String
    }

    private func resolve(_ name: String?, for caller: UUID) -> Result<BrowserElement, Refusal> {
        let browsers = peers(of: caller)
        guard !browsers.isEmpty else {
            return .failure(Refusal(text: "No browser is connected to you. The user connects one by drawing a line between your card and a browser card on the board."))
        }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if let found = browsers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return .success(found) }
            return .failure(Refusal(text: "No browser named “\(name)” is connected to you. Connected: \(browsers.map(\.name).joined(separator: ", "))."))
        }
        guard browsers.count == 1, let only = browsers.first else {
            return .failure(Refusal(text: "Several browsers are connected; say which with `browser`: \(browsers.map(\.name).joined(separator: ", "))."))
        }
        return .success(only)
    }

    private func list(for caller: UUID) -> String {
        let browsers = peers(of: caller)
        guard !browsers.isEmpty else {
            return "No browser is connected to you. The user connects one by drawing a line between your card and a browser card on the board."
        }
        let lines = browsers.map { browser -> String in
            let page = store.pages[browser.id]
            let showing = page.map { $0.url.isEmpty ? "blank page" : "\($0.url)\($0.title.isEmpty ? "" : " · \"\($0.title)\"")" } ?? "not opened yet"
            return "- \(browser.name) (\(browser.detail ?? "browser")): \(showing)"
        }
        return "Connected browsers:\n" + lines.joined(separator: "\n")
    }
}
