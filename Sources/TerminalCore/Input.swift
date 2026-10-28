// Encoding user input (keys, paste, focus, mouse) the way the running program asked for it.

import Foundation

public enum TerminalKey: Equatable, Sendable {
    case enter, tab, backspace, escape, delete, insert
    case up, down, left, right, home, end, pageUp, pageDown
    case function(Int)
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)

    /// xterm's modifier parameter: 1 + shift + 2·alt + 4·control.
    var xtermParameter: Int {
        1 + (contains(.shift) ? 1 : 0) + (contains(.option) ? 2 : 0) + (contains(.control) ? 4 : 0)
    }
}

public struct MouseEvent: Sendable {
    public enum Kind: Sendable { case press, release, drag, motion, scrollUp, scrollDown, scrollLeft, scrollRight }

    public var kind: Kind
    /// 0 left, 1 middle, 2 right.
    public var button: Int
    /// Zero-based cell coordinates.
    public var column: Int
    public var row: Int
    public var modifiers: KeyModifiers

    public init(kind: Kind, button: Int = 0, column: Int, row: Int, modifiers: KeyModifiers = []) {
        self.kind = kind
        self.button = button
        self.column = column
        self.row = row
        self.modifiers = modifiers
    }
}

extension Terminal {
    public func encode(_ key: TerminalKey, modifiers: KeyModifiers = []) -> [UInt8] {
        let esc = "\u{1b}"
        let modified = !modifiers.subtracting(.shift).isEmpty || (modifiers.contains(.shift) && key.isNavigation)
        let text: String
        switch key {
        case .enter: text = modifiers.contains(.shift) || modifiers.contains(.option) ? "\(esc)\r" : "\r"
        case .tab: text = modifiers.contains(.shift) ? "\(esc)[Z" : "\t"
        case .backspace: text = modifiers.contains(.option) ? "\(esc)\u{7f}" : modifiers.contains(.control) ? "\u{08}" : "\u{7f}"
        case .escape: text = esc
        case .delete: text = modified ? "\(esc)[3;\(modifiers.xtermParameter)~" : "\(esc)[3~"
        case .insert: text = modified ? "\(esc)[2;\(modifiers.xtermParameter)~" : "\(esc)[2~"
        case .pageUp: text = modified ? "\(esc)[5;\(modifiers.xtermParameter)~" : "\(esc)[5~"
        case .pageDown: text = modified ? "\(esc)[6;\(modifiers.xtermParameter)~" : "\(esc)[6~"
        case .up, .down, .left, .right, .home, .end:
            let final = switch key {
            case .up: "A"
            case .down: "B"
            case .right: "C"
            case .left: "D"
            case .home: "H"
            default: "F"
            }
            // Option+←/→ move by word, as in Terminal.app.
            if modifiers == .option, key == .left { text = "\(esc)b" }
            else if modifiers == .option, key == .right { text = "\(esc)f" }
            else if modified { text = "\(esc)[1;\(modifiers.xtermParameter)\(final)" }
            else { text = modes.contains(.applicationCursor) ? "\(esc)O\(final)" : "\(esc)[\(final)" }
        case .function(let number):
            let ss3 = ["P", "Q", "R", "S"]
            let tilde = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
            if (1...4).contains(number) {
                text = modified ? "\(esc)[1;\(modifiers.xtermParameter)\(ss3[number - 1])" : "\(esc)O\(ss3[number - 1])"
            } else if let code = tilde[number] {
                text = modified ? "\(esc)[\(code);\(modifiers.xtermParameter)~" : "\(esc)[\(code)~"
            } else {
                text = ""
            }
        }
        return Array(text.utf8)
    }

    /// Pasted text, bracketed when the program asked for it. Line breaks become CR, and an
    /// embedded end-of-paste marker is removed so pasted text can't escape the bracket.
    public func encodePaste(_ text: String) -> [UInt8] {
        var body = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        guard modes.contains(.bracketedPaste) else { return Array(body.utf8) }
        body = body.replacingOccurrences(of: "\u{1b}[201~", with: "")
        return Array("\u{1b}[200~\(body)\u{1b}[201~".utf8)
    }

    /// Focus in/out report, when the program enabled focus events.
    public func encodeFocus(_ focused: Bool) -> [UInt8]? {
        modes.contains(.focusEvents) ? Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8) : nil
    }

    /// True when the program wants mouse input instead of the host handling it.
    public var wantsMouse: Bool { mouseTracking != .none }

    /// The report for `event`, or nil when the current tracking mode doesn't include it.
    public func encodeMouse(_ event: MouseEvent) -> [UInt8]? {
        var code: Int
        switch (event.kind, mouseTracking) {
        case (_, .none): return nil
        case (.press, _): code = event.button
        case (.release, .x10): return nil
        case (.release, _): code = mouseEncoding == .sgr || mouseEncoding == .sgrPixels ? event.button : 3
        case (.drag, .buttonEvent), (.drag, .anyEvent): code = event.button + 32
        case (.motion, .anyEvent): code = 3 + 32
        case (.scrollUp, _): code = 64
        case (.scrollDown, _): code = 65
        case (.scrollLeft, _): code = 66
        case (.scrollRight, _): code = 67
        default: return nil
        }
        if mouseTracking == .x10, event.kind != .press { return nil }
        if event.modifiers.contains(.shift) { code += 4 }
        if event.modifiers.contains(.option) { code += 8 }
        if event.modifiers.contains(.control) { code += 16 }
        let x = max(0, event.column) + 1, y = max(0, event.row) + 1
        switch mouseEncoding {
        case .sgr, .sgrPixels:
            return Array("\u{1b}[<\(code);\(x);\(y)\(event.kind == .release ? "m" : "M")".utf8)
        case .urxvt:
            return Array("\u{1b}[\(code + 32);\(x);\(y)M".utf8)
        case .utf8:
            var bytes: [UInt8] = [0x1B, 0x5B, 0x4D]
            for value in [code + 32, x + 32, y + 32] { bytes += Array(String(Character(Unicode.Scalar(UInt32(min(value, 2047))) ?? " ")).utf8) }
            return bytes
        case .x10:
            guard x + 32 < 256, y + 32 < 256 else { return nil }
            return [0x1B, 0x5B, 0x4D, UInt8(code + 32), UInt8(x + 32), UInt8(y + 32)]
        }
    }
}

private extension TerminalKey {
    var isNavigation: Bool {
        switch self {
        case .up, .down, .left, .right, .home, .end, .pageUp, .pageDown, .delete, .insert, .function: true
        default: false
        }
    }
}
