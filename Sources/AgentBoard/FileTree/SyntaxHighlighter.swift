import SwiftUI

/// A small, language-agnostic highlighter: comments, strings, numbers, keywords, and markup tags.
/// It reads a line at a time, carrying block comments over from the lines before.
enum SyntaxHighlighter {
    private enum Palette {
        static let keyword = Theme.accent
        static let string = Color(red: 0xC2 / 255, green: 0x55 / 255, blue: 0x0A / 255)
        static let number = Color(red: 0x2B / 255, green: 0x5C / 255, blue: 0xD6 / 255)
        static let comment = Color(red: 0x8A / 255, green: 0x86 / 255, blue: 0x99 / 255)
        static let tag = Theme.accent
        static let attribute = Color(red: 0xB0 / 255, green: 0x36 / 255, blue: 0x8C / 255)
        static let plain = Color(red: 0x24 / 255, green: 0x20 / 255, blue: 0x33 / 255)
    }

    private struct Language {
        var line: [String] = []
        var block: [(open: String, close: String)] = []
        var markup = false
    }

    /// Past this many lines a file shows plain, to keep opening it quick.
    static let maxLines = 20_000

    private static let keywords: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def", "default", "defer", "del",
        "do", "elif", "else", "enum", "export", "extends", "extension", "false", "fileprivate", "final", "fn", "for",
        "from", "func", "function", "go", "guard", "if", "impl", "implements", "import", "in", "init", "interface",
        "internal", "is", "lambda", "let", "match", "mod", "mut", "new", "nil", "None", "not", "null", "of", "open",
        "or", "and", "override", "package", "pass", "private", "protected", "protocol", "pub", "public", "raise",
        "return", "self", "Self", "static", "struct", "super", "switch", "this", "throw", "throws", "trait", "true",
        "True", "False", "try", "type", "typeof", "undefined", "use", "var", "void", "where", "while", "with", "yield",
        "some", "any", "lazy", "weak", "inout", "typealias", "select", "chan", "range", "echo", "then", "fi", "esac",
    ]

    static func highlight(_ lines: [String], fileName: String) -> [AttributedString] {
        let language = language(for: fileName)
        var openBlock: String?
        return lines.map { highlight($0, language, &openBlock) }
    }

    private static func language(for name: String) -> Language {
        let cLike = Language(line: ["//"], block: [("/*", "*/")])
        let hash = Language(line: ["#"])
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm", "xml", "svg", "svelte", "vue", "astro", "plist", "xib", "storyboard":
            return Language(line: ["//"], block: [("<!--", "-->"), ("/*", "*/")], markup: true)
        case "css", "scss", "less": return Language(block: [("/*", "*/")])
        case "py", "sh", "bash", "zsh", "rb", "yml", "yaml", "toml", "r", "pl", "conf", "env", "gitignore", "dockerfile",
             "makefile", "mk":
            return hash
        case "sql", "lua", "hs": return Language(line: ["--"], block: [("/*", "*/")])
        case "md", "txt", "json", "csv", "lock": return Language()
        case "": return ["Makefile", "Dockerfile", "Gemfile", "Podfile"].contains(name) ? hash : Language()
        default: return cLike
        }
    }

    private static func highlight(_ text: String, _ language: Language, _ openBlock: inout String?) -> AttributedString {
        let chars = Array(text)
        var result = AttributedString()
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            var run = AttributedString(plain)
            run.foregroundColor = Palette.plain
            result += run
            plain = ""
        }
        func emit(_ piece: String, _ color: Color, italic: Bool = false) {
            flush()
            var run = AttributedString(piece)
            run.foregroundColor = color
            if italic { run.font = .system(size: 12, design: .monospaced).italic() }
            result += run
        }
        func matches(_ token: String, at index: Int) -> Bool {
            let token = Array(token)
            guard index + token.count <= chars.count else { return false }
            return Array(chars[index..<(index + token.count)]) == token
        }
        func closing(_ close: String, from index: Int) -> Int? {
            var j = index
            while j < chars.count {
                if matches(close, at: j) { return j + close.count }
                j += 1
            }
            return nil
        }

        var i = 0
        if let close = openBlock {
            if let end = closing(close, from: 0) {
                emit(String(chars[0..<end]), Palette.comment, italic: true)
                openBlock = nil
                i = end
            } else {
                emit(text, Palette.comment, italic: true)
                return result
            }
        }
        var inTag = false
        while i < chars.count {
            let c = chars[i]
            if let block = language.block.first(where: { matches($0.open, at: i) }) {
                if let end = closing(block.close, from: i + block.open.count) {
                    emit(String(chars[i..<end]), Palette.comment, italic: true)
                    i = end
                } else {
                    emit(String(chars[i...]), Palette.comment, italic: true)
                    openBlock = block.close
                    return result
                }
                continue
            }
            if !inTag, let token = language.line.first(where: { matches($0, at: i) }),
               token != "//" || i == 0 || chars[i - 1] != ":" {
                emit(String(chars[i...]), Palette.comment, italic: true)
                return result
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c {
                    j += chars[j] == "\\" ? 2 : 1
                }
                let end = min(j + 1, chars.count)
                emit(String(chars[i..<end]), Palette.string)
                i = end
                continue
            }
            if language.markup, c == "<", i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "/" {
                var j = i + 1
                if chars[j] == "/" { j += 1 }
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || "-_:.".contains(chars[j]) { j += 1 }
                emit(String(chars[i..<j]), Palette.tag)
                inTag = true
                i = j
                continue
            }
            if inTag, c == ">" || (c == "/" && i + 1 < chars.count && chars[i + 1] == ">") {
                let end = c == ">" ? i + 1 : i + 2
                emit(String(chars[i..<end]), Palette.tag)
                inTag = false
                i = end
                continue
            }
            if c.isLetter || c == "_" || c == "$" || c == "@" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || (inTag && chars[j] == "-") {
                    j += 1
                }
                let word = String(chars[i..<j])
                if inTag {
                    emit(word, Palette.attribute)
                } else if keywords.contains(word) || c == "@" {
                    emit(word, Palette.keyword)
                } else if j < chars.count, chars[j] == "(", word.first?.isUppercase == false {
                    emit(word, Palette.number)
                } else if word.first?.isUppercase == true {
                    emit(word, Palette.attribute)
                } else {
                    plain += word
                }
                i = j
                continue
            }
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i + 1
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x" || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), Palette.number)
                i = j
                continue
            }
            plain.append(c)
            i += 1
        }
        flush()
        return result
    }
}
