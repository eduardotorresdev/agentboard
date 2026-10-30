import Foundation

/// What a waiting agent asks the developer to decide on, read from the end of its Claude Code
/// conversation (JSONL, one content block per assistant line): the newest of its last turn's
/// text, a question it asked (AskUserQuestion), or a tool call waiting for permission.
enum TranscriptContext {
    /// How much of the file's end is read: a turn's last blocks fit in far less.
    static let tailBytes = 512 * 1024
    static let maxLength = 4000

    /// What the agent last said in its turn, leaving out its tool calls: the words before the
    /// questions a form shows on their own.
    static func lastText(in url: URL) -> String? {
        lastRequest(in: url, textOnly: true)
    }

    static func lastRequest(in url: URL, textOnly: Bool = false) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        // The first line may be cut by the seek; it fails to parse and is skipped.
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "assistant":
                let blocks = message["content"] as? [[String: Any]] ?? []
                for block in blocks.reversed() {
                    if textOnly, block["type"] as? String != "text" { continue }
                    if let found = describe(block) { return found }
                }
            case "user" where !isToolResult(message):
                // The developer's own prompt: the turn began here and said nothing worth showing.
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private static func isToolResult(_ message: [String: Any]) -> Bool {
        (message["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false
    }

    private static func describe(_ block: [String: Any]) -> String? {
        switch block["type"] as? String {
        case "text":
            return (block["text"] as? String).flatMap(trimmed)
        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            let input = block["input"] as? [String: Any] ?? [:]
            if name == "AskUserQuestion", let questions = input["questions"] as? [[String: Any]] {
                return trimmed(questions.map { question in
                    let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                    return (question["question"] as? String ?? "") + (options.isEmpty ? "" : "\n" + options.map { "- " + $0 }.joined(separator: "\n"))
                }.joined(separator: "\n\n"))
            }
            // A call waiting for permission: the tool and what it would act on.
            let target = ["command", "file_path", "url", "path", "pattern", "description"].lazy.compactMap { input[$0] as? String }.first
            return trimmed("**\(name)**" + (target.map { "\n`" + $0 + "`" } ?? ""))
        default:
            return nil
        }
    }

    static func trimmed(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }
}
