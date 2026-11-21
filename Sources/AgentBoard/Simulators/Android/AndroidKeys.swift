/// HID keyboard usages (what the board sends for a Mac key, see `SimulatorKeys`) as Android
/// `KeyEvent.KEYCODE_*`, and the device buttons by name.
enum AndroidKeys {
    static func keycode(forUsage usage: Int) -> Int? {
        switch usage {
        case 0x04...0x1d: return 29 + usage - 0x04          // A–Z
        case 0x1e...0x26: return 8 + usage - 0x1e           // 1–9
        case 0x27: return 7                                 // 0
        default: return table[usage]
        }
    }

    private static let table: [Int: Int] = [
        0x28: 66, 0x29: 111, 0x2a: 67, 0x2b: 61, 0x2c: 62,  // Enter, Escape, Backspace (DEL), Tab, Space
        0x2d: 69, 0x2e: 70, 0x2f: 71, 0x30: 72, 0x31: 73, 0x33: 74, 0x34: 75, 0x35: 68, 0x36: 55, 0x37: 56, 0x38: 76,
        0x4c: 112, 0x4a: 122, 0x4d: 123, 0x4b: 92, 0x4e: 93,  // Forward delete, Home, End, Page up/down
        0x4f: 22, 0x50: 21, 0x51: 20, 0x52: 19,             // arrows
        0x58: 160,                                          // keypad Enter
        0xe1: 59, 0xe5: 60, 0xe0: 113, 0xe4: 114, 0xe2: 57, 0xe6: 58, 0xe3: 117, 0xe7: 118, 0x39: 115,
    ]

    /// Each held modifier's bits in `KeyEvent`'s meta state.
    static let modifierMeta: [Int: Int] = [
        0xe1: 0x41, 0xe5: 0x81,          // Shift left/right
        0xe0: 0x3000, 0xe4: 0x5000,      // Control
        0xe2: 0x12, 0xe6: 0x22,          // Alt (Option)
        0xe3: 0x30000, 0xe7: 0x50000,    // Meta (Command)
    ]

    /// What `simulator_press` and the card's buttons take.
    static let buttons: [String: Int] = [
        "home": 3, "back": 4, "recents": 187, "power": 26, "volumeup": 24, "volumedown": 25,
        "enter": 66, "return": 66, "escape": 111, "backspace": 67, "delete": 67, "tab": 61, "space": 62,
        "arrowup": 19, "arrowdown": 20, "arrowleft": 21, "arrowright": 22, "up": 19, "down": 20, "left": 21, "right": 22,
    ]
}
