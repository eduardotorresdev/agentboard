// Control functions: C0 controls, ESC, CSI, OSC and DCS sequences.

private let esc = "\u{1b}"

private func code(_ character: Unicode.Scalar) -> UInt8 { UInt8(character.value) }
private func marker(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

extension Terminal {
    func execute(_ byte: UInt8) {
        switch byte {
        case 0x07: bell()
        case 0x08:
            // xterm: backspace from the wrap-pending position stays on the last column.
            if pendingWrap { pendingWrap = false } else if cursorX > 0 { cursorX -= 1 }
        case 0x09: tab(forward: 1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if modes.contains(.linefeedNewline) { cursorX = 0 }
        case 0x0D:
            cursorX = 0
            pendingWrap = false
        case 0x0E: activeCharset = 1
        case 0x0F: activeCharset = 0
        default: break
        }
    }

    func tab(forward count: Int) {
        pendingWrap = false
        for _ in 0..<count {
            var x = cursorX + 1
            while x < cols - 1, !tabStops[x] { x += 1 }
            cursorX = min(x, cols - 1)
        }
    }

    func tab(backward count: Int) {
        pendingWrap = false
        for _ in 0..<count {
            var x = cursorX - 1
            while x > 0, !tabStops[x] { x -= 1 }
            cursorX = max(0, x)
        }
    }

    // MARK: ESC

    func escDispatch(_ collected: UInt32, _ final: UInt8) {
        switch collected {
        case 0:
            switch final {
            case code("7"): saveCursor()
            case code("8"): restoreCursor()
            case code("D"): index()
            case code("E"):
                index()
                cursorX = 0
            case code("H"): tabStops[cursorX] = true
            case code("M"): reverseIndex()
            case code("c"): fullReset()
            case code("="): setMode(.applicationKeypad, true)
            case code(">"): setMode(.applicationKeypad, false)
            case code("Z"): respond("\(esc)[?62;22c")
            default: break
            }
        case marker("("), marker(")"):
            let charset: Charset = final == code("0") ? .decSpecialGraphics : .ascii
            charsets[collected == marker("(") ? 0 : 1] = charset
        case marker("#") where final == code("8"):
            // DECALN: fill the screen with E (alignment test).
            for y in 0..<rows {
                let row = grid.row(y)
                for x in 0..<cols { row[x] = Cell(content: 0x45, fg: 0, bg: 0) }
                grid.markDirty(y)
            }
        default:
            break
        }
    }

    // MARK: CSI

    func csiDispatch(_ p: CSIParams, _ collected: UInt32, _ final: UInt8) {
        switch collected {
        case 0: standardCSI(p, final)
        case marker("?"): privateCSI(p, final)
        case marker(">"):
            if final == code("c") { respond("\(esc)[>1;10;0c") }  // DA2
            // XTVERSION (q), modifyOtherKeys (m) and kitty keyboard (u) are not supported.
        case marker(" ") where final == code("q"):
            switch p[0] {
            case 3, 4: setCursorShape(.underline)
            case 5, 6: setCursorShape(.bar)
            default: setCursorShape(.block)
            }
        case marker("!") where final == code("p"):
            softReset()
        case marker("$") where final == code("p"):
            respond("\(esc)[\(p[0]);\(ansiModeState(p[0]))$y")
        case marker("?$") where final == code("p"):
            respond("\(esc)[?\(p[0]);\(decModeState(p[0]))$y")
        default:
            break
        }
    }

    private func standardCSI(_ p: CSIParams, _ final: UInt8) {
        let n = p.value(0, or: 1)
        switch final {
        case code("@"): insertBlanks(n)
        case code("A"): cursorUp(n)
        case code("B"), code("e"): cursorDown(n)
        case code("C"), code("a"):
            pendingWrap = false
            cursorX = min(cols - 1, cursorX + n)
        case code("D"):
            pendingWrap = false
            cursorX = max(0, cursorX - n)
        case code("E"):
            cursorDown(n)
            cursorX = 0
        case code("F"):
            cursorUp(n)
            cursorX = 0
        case code("G"), code("`"):
            pendingWrap = false
            cursorX = min(max(0, n - 1), cols - 1)
        case code("H"), code("f"):
            moveCursor(x: p.value(1, or: 1) - 1, y: p.value(0, or: 1) - 1)
        case code("I"): tab(forward: n)
        case code("J"): eraseDisplay(p[0])
        case code("K"): eraseLine(p[0])
        case code("L"): insertLines(n)
        case code("M"): deleteLines(n)
        case code("P"): deleteChars(n)
        case code("S"): scrollUp(n)
        case code("T") where p.count <= 1: scrollDown(n)
        case code("X"): eraseChars(n)
        case code("Z"): tab(backward: n)
        case code("b"):
            if lastPrinted != 0 { for _ in 0..<min(n, 65535) { print(lastPrinted) } }
        case code("c"):
            if p[0] == 0 { respond("\(esc)[?62;22c") }  // DA1: VT220 with ANSI color
        case code("d"):
            moveCursor(x: cursorX, y: p.value(0, or: 1) - 1)
        case code("g"):
            if p[0] == 0 { tabStops[cursorX] = false } else if p[0] == 3 { tabStops = Array(repeating: false, count: cols) }
        case code("h"), code("l"):
            for index in 0..<p.count {
                switch p[index] {
                case 4: setMode(.insert, final == code("h"))
                case 20: setMode(.linefeedNewline, final == code("h"))
                default: break
                }
            }
        case code("m"): selectGraphicRendition(p)
        case code("n"):
            if p[0] == 5 { respond("\(esc)[0n") }
            if p[0] == 6 { respond("\(esc)[\(reportedRow + 1);\(cursorX + 1)R") }
        case code("r"):
            let top = p.value(0, or: 1) - 1, bottom = p.value(1, or: rows) - 1
            if top < bottom, bottom < rows {
                scrollTop = top
                scrollBottom = bottom
                moveCursor(x: 0, y: 0)
            }
        case code("s"): saveCursor()
        case code("u"): restoreCursor()
        case code("t"):
            if p[0] == 18 { respond("\(esc)[8;\(rows);\(cols)t") }
        default:
            break
        }
    }

    private func privateCSI(_ p: CSIParams, _ final: UInt8) {
        switch final {
        case code("h"), code("l"):
            for index in 0..<p.count { setPrivateMode(p[index], final == code("h")) }
        case code("J"): eraseDisplay(p[0])
        case code("K"): eraseLine(p[0])
        case code("n"):
            if p[0] == 6 { respond("\(esc)[?\(reportedRow + 1);\(cursorX + 1)R") }
        default:
            // ?u (kitty keyboard query) gets no answer: the program falls back to legacy keys.
            break
        }
    }

    /// Cursor row as programs see it: relative to the scroll region in origin mode.
    private var reportedRow: Int { modes.contains(.origin) ? cursorY - scrollTop : cursorY }

    private func setPrivateMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: setMode(.applicationCursor, on)
        case 5:
            setMode(.reverseVideo, on)
            grid.markAllDirty()
        case 6:
            setMode(.origin, on)
            moveCursor(x: 0, y: 0)
        case 7: setMode(.autowrap, on)
        case 9: setMouse(tracking: on ? .x10 : MouseTracking.none)
        case 12: setMode(.cursorBlink, on)
        case 25: setMode(.cursorVisible, on)
        case 47:
            if on { enterAlternateScreen(clear: false) } else { leaveAlternateScreen() }
        case 66: setMode(.applicationKeypad, on)
        case 1000: setMouse(tracking: on ? .normal : MouseTracking.none)
        case 1002: setMouse(tracking: on ? .buttonEvent : MouseTracking.none)
        case 1003: setMouse(tracking: on ? .anyEvent : MouseTracking.none)
        case 1004: setMode(.focusEvents, on)
        case 1005: setMouse(encoding: on ? .utf8 : .x10)
        case 1006: setMouse(encoding: on ? .sgr : .x10)
        case 1007: setMode(.alternateScroll, on)
        case 1015: setMouse(encoding: on ? .urxvt : .x10)
        case 1016: setMouse(encoding: on ? .sgrPixels : .x10)
        case 1047:
            if on {
                enterAlternateScreen(clear: false)
            } else {
                if isAlternateScreen { for y in 0..<rows { grid.clear(row: y, background: pen.bg) } }
                leaveAlternateScreen()
            }
        case 1048:
            if on { saveCursor() } else { restoreCursor() }
        case 1049:
            if on {
                saveCursor()
                enterAlternateScreen(clear: true)
            } else {
                leaveAlternateScreen()
                restoreCursor()
            }
        case 2004: setMode(.bracketedPaste, on)
        case 2026: setMode(.synchronizedOutput, on)
        default: break
        }
    }

    /// DECRQM answer: 1 set, 2 reset, 0 not recognized.
    private func decModeState(_ mode: Int) -> Int {
        let flag: TerminalModes? = switch mode {
        case 1: .applicationCursor
        case 5: .reverseVideo
        case 6: .origin
        case 7: .autowrap
        case 12: .cursorBlink
        case 25: .cursorVisible
        case 66: .applicationKeypad
        case 1004: .focusEvents
        case 1007: .alternateScroll
        case 2004: .bracketedPaste
        case 2026: .synchronizedOutput
        default: nil
        }
        if let flag { return modes.contains(flag) ? 1 : 2 }
        switch mode {
        case 47, 1047, 1049: return isAlternateScreen ? 1 : 2
        case 1000: return mouseTracking == .normal ? 1 : 2
        case 1002: return mouseTracking == .buttonEvent ? 1 : 2
        case 1003: return mouseTracking == .anyEvent ? 1 : 2
        case 1006: return mouseEncoding == .sgr ? 1 : 2
        default: return 0
        }
    }

    private func ansiModeState(_ mode: Int) -> Int {
        switch mode {
        case 4: modes.contains(.insert) ? 1 : 2
        case 20: modes.contains(.linefeedNewline) ? 1 : 2
        default: 0
        }
    }

    private func softReset() {
        modes.remove([.insert, .origin, .applicationCursor, .applicationKeypad])
        modes.insert([.autowrap, .cursorVisible])
        pen = Pen()
        charsets = [.ascii, .ascii]
        activeCharset = 0
        scrollTop = 0
        scrollBottom = rows - 1
        savedMain = nil
        savedAlternate = nil
        pendingWrap = false
    }

    // MARK: SGR

    private func selectGraphicRendition(_ p: CSIParams) {
        var attributes = pen.attributes, fg = pen.foreground, bg = pen.background
        if p.count == 0 {
            pen = Pen()
            return
        }
        var index = 0
        while index < p.count {
            let value = p[index]
            switch value {
            case 0:
                attributes = []
                fg = .default
                bg = .default
            case 1: attributes.insert(.bold)
            case 2: attributes.insert(.dim)
            case 3: attributes.insert(.italic)
            case 4:
                attributes.subtract(.underlines)
                if p.isSubparameter(index + 1) {
                    switch p[index + 1] {
                    case 0: break
                    case 2: attributes.insert(.doubleUnderline)
                    case 3: attributes.insert(.curlyUnderline)
                    default: attributes.insert(.underline)
                    }
                } else {
                    attributes.insert(.underline)
                }
            case 5, 6: attributes.insert(.blink)
            case 7: attributes.insert(.inverse)
            case 8: attributes.insert(.invisible)
            case 9: attributes.insert(.strikethrough)
            case 21:
                attributes.subtract(.underlines)
                attributes.insert(.doubleUnderline)
            case 22: attributes.subtract([.bold, .dim])
            case 23: attributes.remove(.italic)
            case 24: attributes.subtract(.underlines)
            case 25: attributes.remove(.blink)
            case 27: attributes.remove(.inverse)
            case 28: attributes.remove(.invisible)
            case 29: attributes.remove(.strikethrough)
            case 30...37: fg = .palette(UInt8(value - 30))
            case 38:
                let (color, consumed) = extendedColor(p, at: index)
                if let color { fg = color }
                index += consumed
            case 39: fg = .default
            case 40...47: bg = .palette(UInt8(value - 40))
            case 48:
                let (color, consumed) = extendedColor(p, at: index)
                if let color { bg = color }
                index += consumed
            case 49: bg = .default
            case 53: attributes.insert(.overline)
            case 55: attributes.remove(.overline)
            case 58: index += extendedColor(p, at: index).consumed  // underline color: parsed, not drawn
            case 90...97: fg = .palette(UInt8(value - 90 + 8))
            case 100...107: bg = .palette(UInt8(value - 100 + 8))
            default: break
            }
            index += 1
            while index < p.count, p.isSubparameter(index) { index += 1 }
        }
        pen = Pen()
        pen.foreground = fg
        pen.background = bg
        pen.attributes = attributes
    }

    /// `38;5;n`, `38;2;r;g;b` and their colon forms (`38:5:n`, `38:2:[space]:r:g:b`). Returns
    /// how many semicolon-separated parameters it used; colon sub-parameters are skipped by
    /// the caller.
    private func extendedColor(_ p: CSIParams, at index: Int) -> (color: TerminalColor?, consumed: Int) {
        func byte(_ i: Int) -> UInt8 { UInt8(min(255, p[i])) }
        if p.isSubparameter(index + 1) {
            var subcount = 0
            while p.isSubparameter(index + 1 + subcount), index + 1 + subcount < p.count { subcount += 1 }
            switch (p[index + 1], subcount) {
            case (5, 2...): return (.palette(byte(index + 2)), 0)
            case (2, 5...): return (.rgb(byte(index + 3), byte(index + 4), byte(index + 5)), 0)
            case (2, 4): return (.rgb(byte(index + 2), byte(index + 3), byte(index + 4)), 0)
            default: return (nil, 0)
            }
        }
        switch p[index + 1] {
        case 5 where index + 2 < p.count: return (.palette(byte(index + 2)), 2)
        case 2 where index + 4 < p.count: return (.rgb(byte(index + 2), byte(index + 3), byte(index + 4)), 4)
        default: return (nil, max(0, min(p.count - index - 1, 1)))
        }
    }

    // MARK: OSC and DCS

    func oscDispatch(_ data: UnsafeBufferPointer<UInt8>, bellTerminated: Bool) {
        let separator = data.firstIndex(of: code(";")) ?? data.count
        guard let command = Int(String(decoding: UnsafeBufferPointer(rebasing: data[0..<separator]), as: UTF8.self)) else { return }
        let text = separator < data.count ? String(decoding: UnsafeBufferPointer(rebasing: data[(separator + 1)...]), as: UTF8.self) : ""
        let terminator = bellTerminated ? "\u{07}" : "\(esc)\\"
        switch command {
        case 0, 2: setTitle(text)
        case 7: setWorkingDirectory(text)
        case 9:
            // iTerm2 notifications; "9;4;…" is ConEmu's progress report, not a message.
            if !text.hasPrefix("4;") { notify(text) }
        case 10, 11, 12:
            guard text.hasPrefix("?") else { break }
            let color = command == 11 ? reportedBackground : reportedForeground
            func channel(_ shift: UInt32) -> String {
                let value = (color >> shift) & 0xFF
                let hex = String(value, radix: 16)
                let pair = hex.count == 1 ? "0" + hex : hex
                return pair + pair
            }
            respond("\(esc)]\(command);rgb:\(channel(16))/\(channel(8))/\(channel(0))\(terminator)")
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.first == "notify" { notify(parts.dropFirst().joined(separator: ": ")) }
        default:
            // 8 (hyperlinks), 52 (clipboard), 133 (shell marks) and the rest are ignored.
            break
        }
    }

    func dcsDispatch(_ params: CSIParams, _ collected: UInt32, _ final: UInt8, _ data: UnsafeBufferPointer<UInt8>) {
        // Answer "unsupported" to status and capability requests so programs don't wait.
        if collected == marker("$") && final == code("q") { respond("\(esc)P0$r\(esc)\\") }
        if collected == marker("+") && final == code("q") { respond("\(esc)P0+r\(esc)\\") }
    }
}
