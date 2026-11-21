/// Mac virtual key codes (ANSI layout) as USB HID keyboard usages, which is what the simulator's
/// hardware keyboard takes: the card forwards physical keys, so the device's own keyboard
/// layout, shortcuts and key repeat behave as on a real keyboard.
enum SimulatorKeys {
    static func usage(forKeyCode code: UInt16) -> Int? { table[code] }

    /// The modifier keys, which arrive as `flagsChanged` rather than key down/up.
    static let modifiers: [UInt16: Int] = [
        56: 0xe1, 60: 0xe5,  // Shift
        59: 0xe0, 62: 0xe4,  // Control
        58: 0xe2, 61: 0xe6,  // Option
        55: 0xe3, 54: 0xe7,  // Command
        57: 0x39,            // Caps Lock
    ]

    private static let table: [UInt16: Int] = [
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0a, 4: 0x0b, 34: 0x0c, 38: 0x0d,
        40: 0x0e, 37: 0x0f, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17,
        32: 0x18, 9: 0x19, 13: 0x1a, 7: 0x1b, 16: 0x1c, 6: 0x1d,                      // a–z
        18: 0x1e, 19: 0x1f, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,  // 1–0
        36: 0x28, 53: 0x29, 51: 0x2a, 48: 0x2b, 49: 0x2c,                              // Return, Escape, Delete, Tab, Space
        27: 0x2d, 24: 0x2e, 33: 0x2f, 30: 0x30, 42: 0x31, 41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38,
        10: 0x64,                                                                      // ISO §
        117: 0x4c, 115: 0x4a, 119: 0x4d, 116: 0x4b, 121: 0x4e,                         // Forward Delete, Home, End, Page Up/Down
        124: 0x4f, 123: 0x50, 125: 0x51, 126: 0x52,                                    // arrows
        76: 0x58,                                                                      // keypad Enter
    ]
}
