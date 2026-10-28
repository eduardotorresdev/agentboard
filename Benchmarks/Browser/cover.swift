// An opaque window covering a screen region, standing in for the board's window.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
let window = NSWindow(contentRect: NSRect(x: a[0], y: a[1], width: a[2], height: a[3]), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "cover (spike)"
window.backgroundColor = .systemGray
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
