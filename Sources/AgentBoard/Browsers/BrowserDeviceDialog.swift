import SwiftUI

/// Describes a device: start from any Playwright preset (which brings its user agent), then
/// change the size, density, touch, mobile behavior, or the user agent itself.
struct BrowserDeviceDialog: View {
    let browsers: BrowserStore
    let initial: BrowserDevice
    let isNew: Bool
    let onDone: (BrowserDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presets: [BrowserDevice] = []
    @State private var start = ""
    @State private var width = ""
    @State private var height = ""
    @State private var scale: Double = 2
    @State private var touch = false
    @State private var mobile = false
    @State private var userAgent = ""

    private static let sizes = 200...3840

    var body: some View {
        AppDialog(title: isNew ? L("New custom browser") : L("Change device"),
                  subtitle: L("Start from a device, then change what you need.")) {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: L("Start from"), message: L("Fills in everything below with that device's values.")) {
                    Picker("", selection: $start) {
                        if presets.isEmpty { Text(start.isEmpty ? L("Loading devices…") : start).tag(start) }
                        ForEach(presets, id: \.title) { Text($0.title).tag($0.title) }
                    }
                    .labelsHidden()
                    .onChange(of: start) { _, name in
                        if let preset = presets.first(where: { $0.title == name }) { fill(from: preset) }
                    }
                }
                FormRow(label: L("Size"), message: sizeMessage, isError: sizeInvalid) {
                    HStack(spacing: 6) {
                        TextField("", text: $width).frame(width: 70)
                        Text("×").foregroundStyle(.secondary)
                        TextField("", text: $height).frame(width: 70)
                    }
                }
                FormRow(label: L("Density"), message: L("Device pixels per CSS pixel: 2× and 3× are Retina screens.")) {
                    Picker("", selection: $scale) {
                        Text("1×").tag(1.0)
                        Text("2×").tag(2.0)
                        Text("3×").tag(3.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                FormRow(label: L("Touch"), message: L("Clicks become taps and dragging scrolls; nothing hovers.")) {
                    Toggle(L("Touch screen"), isOn: $touch)
                }
                FormRow(label: L("Mobile"), message: L("Follows the page's viewport meta tag, like a phone's browser.")) {
                    Toggle(L("Mobile browser"), isOn: $mobile)
                }
                FormRow(label: L("User agent"), message: L("What pages see in navigator.userAgent.")) {
                    TextField("", text: $userAgent, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.callout.monospaced())
                }
            }
        } footer: {
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? L("Add browser") : L("Apply")) {
                onDone(device)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(sizeInvalid)
        }
        .onAppear { fill(from: initial, start: initial.preset ?? "") }
        .task {
            presets = await browsers.playwrightPresets()
            if userAgent.isEmpty, let preset = presets.first(where: { $0.title == start }) { userAgent = preset.userAgent ?? "" }
        }
    }

    private var sizeInvalid: Bool {
        guard let width = Int(width), let height = Int(height) else { return true }
        return !Self.sizes.contains(width) || !Self.sizes.contains(height)
    }

    private var sizeMessage: String {
        sizeInvalid ? L("Width and height go from 200 to 3840.") : L("Viewport in CSS pixels, width × height.")
    }

    private var device: BrowserDevice {
        let agent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserDevice(title: BrowserDevice.customTitle, preset: start.isEmpty ? nil : start,
                             width: Int(width) ?? 1280, height: Int(height) ?? 720, scale: scale,
                             mobile: mobile, touch: touch, userAgent: agent.isEmpty ? nil : agent)
    }

    private func fill(from device: BrowserDevice, start name: String? = nil) {
        if let name { start = name }
        width = String(device.width)
        height = String(device.height)
        scale = [1, 2, 3].min { abs($0 - device.scale) < abs($1 - device.scale) } ?? 2
        touch = device.touch
        mobile = device.mobile
        userAgent = device.userAgent ?? presets.first { $0.title == device.preset }?.userAgent ?? ""
    }
}
