/// Receives what the parser recognizes. Implemented by `Terminal`; generic dispatch keeps the
/// calls static (no witness tables) in the hot loop.
protocol VTHandler: AnyObject {
    /// A run of printable ASCII (0x20–0x7E), the overwhelmingly common case.
    func printASCII(_ bytes: UnsafePointer<UInt8>, _ count: Int)
    func print(_ scalar: UInt32)
    func execute(_ byte: UInt8)
    func csiDispatch(_ params: CSIParams, _ collected: UInt32, _ final: UInt8)
    func escDispatch(_ collected: UInt32, _ final: UInt8)
    func oscDispatch(_ data: UnsafeBufferPointer<UInt8>, bellTerminated: Bool)
    func dcsDispatch(_ params: CSIParams, _ collected: UInt32, _ final: UInt8, _ data: UnsafeBufferPointer<UInt8>)
}

/// Numeric parameters of a CSI or DCS sequence. Missing parameters read as 0.
struct CSIParams {
    let values: UnsafePointer<UInt16>
    let count: Int
    /// Bit `i` set: parameter `i` followed a ':' (a sub-parameter of the one before).
    let colonMask: UInt64

    @inline(__always) subscript(index: Int) -> Int { index < count ? Int(values[index]) : 0 }

    /// The parameter, or `fallback` when it is missing or zero (cursor movement semantics).
    @inline(__always) func value(_ index: Int, or fallback: Int) -> Int {
        let value = self[index]
        return value == 0 ? fallback : value
    }

    @inline(__always) func isSubparameter(_ index: Int) -> Bool { index < 64 && colonMask & (1 << UInt64(index)) != 0 }
}

/// A DEC/ANSI escape sequence parser (Paul Williams' VT500 state machine) with UTF-8 decoding
/// in the ground state. Bytes may arrive split anywhere; all state carries across calls.
struct VTParser {
    private enum State: UInt8 {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case oscString
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case ignoreString  // SOS, PM, APC
    }

    private var state = State.ground
    private let params = UnsafeMutablePointer<UInt16>.allocate(capacity: Self.maxParams)
    private var paramCount = 0
    private var currentParam = 0
    private var hasParam = false
    private var colonMask: UInt64 = 0
    /// Private markers and intermediates, one byte each, oldest in the high bits.
    private var collected: UInt32 = 0
    private var stringBuffer: [UInt8] = []
    private var utf8Scalar: UInt32 = 0
    private var utf8Remaining = 0
    private var utf8Minimum: UInt32 = 0

    private static let maxParams = 32
    private static let maxString = 64 * 1024

    func deallocate() { params.deallocate() }

    mutating func advance<Handler: VTHandler>(_ input: UnsafeRawBufferPointer, _ handler: Handler) {
        guard var p = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let end = p + input.count
        while p < end {
            let byte = p.pointee
            if state == .ground {
                if utf8Remaining > 0 {
                    if byte & 0xC0 == 0x80 {
                        utf8Scalar = utf8Scalar << 6 | UInt32(byte & 0x3F)
                        utf8Remaining -= 1
                        if utf8Remaining == 0 {
                            let valid = utf8Scalar >= utf8Minimum && utf8Scalar <= 0x10FFFF && !(0xD800...0xDFFF).contains(utf8Scalar)
                            handler.print(valid ? utf8Scalar : 0xFFFD)
                        }
                        p += 1
                        continue
                    }
                    utf8Remaining = 0
                    handler.print(0xFFFD)  // truncated sequence; reprocess this byte
                }
                if byte >= 0x20 && byte < 0x7F {
                    var q = p + 1
                    while q < end && q.pointee >= 0x20 && q.pointee < 0x7F { q += 1 }
                    handler.printASCII(p, q - p)
                    p = q
                    continue
                }
                if byte < 0x20 {
                    if byte == 0x1B { enterEscape() } else { handler.execute(byte) }
                } else if byte >= 0x80 {
                    switch byte {
                    case 0xC2...0xDF: utf8Scalar = UInt32(byte & 0x1F); utf8Remaining = 1; utf8Minimum = 0x80
                    case 0xE0...0xEF: utf8Scalar = UInt32(byte & 0x0F); utf8Remaining = 2; utf8Minimum = 0x800
                    case 0xF0...0xF4: utf8Scalar = UInt32(byte & 0x07); utf8Remaining = 3; utf8Minimum = 0x10000
                    default: handler.print(0xFFFD)
                    }
                }
                p += 1
                continue
            }
            step(byte, handler)
            p += 1
        }
    }

    /// Everything outside the ground state's fast paths.
    private mutating func step<Handler: VTHandler>(_ byte: UInt8, _ handler: Handler) {
        // Transitions from anywhere.
        switch byte {
        case 0x18, 0x1A:
            finishString(handler, bell: false)
            state = .ground
            return
        case 0x1B:
            finishString(handler, bell: false)
            enterEscape()
            return
        default: break
        }

        switch state {
        case .ground:
            break

        case .escape:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x20...0x2F: collect(byte); state = .escapeIntermediate
            case 0x5B: enterParams(); state = .csiEntry
            case 0x5D: stringBuffer.removeAll(keepingCapacity: true); state = .oscString
            case 0x50: enterParams(); state = .dcsEntry
            case 0x58, 0x5E, 0x5F: state = .ignoreString
            case 0x7F: break
            default: state = .ground; handler.escDispatch(collected, byte)
            }

        case .escapeIntermediate:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x20...0x2F: collect(byte)
            case 0x7F: break
            default: state = .ground; handler.escDispatch(collected, byte)
            }

        case .csiEntry, .csiParam:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x30...0x39: digit(byte); state = .csiParam
            case 0x3A, 0x3B: separator(byte); state = .csiParam
            case 0x3C...0x3F:
                if state == .csiEntry { collect(byte); state = .csiParam } else { state = .csiIgnore }
            case 0x20...0x2F: collect(byte); state = .csiIntermediate
            case 0x40...0x7E: state = .ground; dispatchCSI(byte, handler)
            default: break
            }

        case .csiIntermediate:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x20...0x2F: collect(byte)
            case 0x30...0x3F: state = .csiIgnore
            case 0x40...0x7E: state = .ground; dispatchCSI(byte, handler)
            default: break
            }

        case .csiIgnore:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x40...0x7E: state = .ground
            default: break
            }

        case .oscString:
            if byte == 0x07 {
                finishString(handler, bell: true)
                state = .ground
            } else if byte >= 0x20, stringBuffer.count < Self.maxString {
                stringBuffer.append(byte)
            }

        case .dcsEntry, .dcsParam:
            switch byte {
            case 0x30...0x39: digit(byte); state = .dcsParam
            case 0x3A, 0x3B: separator(byte); state = .dcsParam
            case 0x3C...0x3F:
                if state == .dcsEntry { collect(byte); state = .dcsParam } else { state = .dcsIgnore }
            case 0x20...0x2F: collect(byte); state = .dcsIntermediate
            case 0x40...0x7E: stringBuffer.removeAll(keepingCapacity: true); collected = collected << 8 | UInt32(byte); state = .dcsPassthrough
            default: break
            }

        case .dcsIntermediate:
            switch byte {
            case 0x20...0x2F: collect(byte)
            case 0x30...0x3F: state = .dcsIgnore
            case 0x40...0x7E: stringBuffer.removeAll(keepingCapacity: true); collected = collected << 8 | UInt32(byte); state = .dcsPassthrough
            default: break
            }

        case .dcsPassthrough:
            if byte != 0x7F, stringBuffer.count < Self.maxString { stringBuffer.append(byte) }

        case .dcsIgnore, .ignoreString:
            break
        }
    }

    private mutating func enterEscape() {
        state = .escape
        collected = 0
        utf8Remaining = 0
    }

    private mutating func enterParams() {
        paramCount = 0
        currentParam = 0
        hasParam = false
        colonMask = 0
        collected = 0
    }

    @inline(__always) private mutating func collect(_ byte: UInt8) {
        collected = collected << 8 | UInt32(byte)
    }

    @inline(__always) private mutating func digit(_ byte: UInt8) {
        currentParam = min(currentParam * 10 + Int(byte - 0x30), 0xFFFF)
        hasParam = true
    }

    private mutating func separator(_ byte: UInt8) {
        pushParam()
        if byte == 0x3A, paramCount < 64 { colonMask |= 1 << UInt64(paramCount) }
        hasParam = true  // "CSI ;5H" has an empty first parameter
    }

    private mutating func pushParam() {
        if paramCount < Self.maxParams {
            params[paramCount] = UInt16(currentParam)
            paramCount += 1
        }
        currentParam = 0
    }

    private mutating func dispatchCSI<Handler: VTHandler>(_ final: UInt8, _ handler: Handler) {
        if hasParam { pushParam() }
        handler.csiDispatch(CSIParams(values: params, count: paramCount, colonMask: colonMask), collected, final)
    }

    /// Ends an OSC or DCS string when its terminator (BEL, ST, CAN, SUB) arrives.
    private mutating func finishString<Handler: VTHandler>(_ handler: Handler, bell: Bool) {
        switch state {
        case .oscString:
            stringBuffer.withUnsafeBufferPointer { handler.oscDispatch($0, bellTerminated: bell) }
        case .dcsPassthrough:
            if hasParam { pushParam() }
            let final = UInt8(collected & 0xFF)
            let params = CSIParams(values: params, count: paramCount, colonMask: colonMask)
            stringBuffer.withUnsafeBufferPointer { handler.dcsDispatch(params, collected >> 8, final, $0) }
        default:
            break
        }
    }
}
