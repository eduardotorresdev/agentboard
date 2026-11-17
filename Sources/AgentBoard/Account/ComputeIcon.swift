import AppKit
import SwiftUI

/// The operating system a computer runs: whose home screen its icon shows.
enum HostSystem: Equatable {
    case mac, linux, windows

    /// From a host's platform, "linux-x86_64". One that says neither Linux nor Windows is a Mac.
    init(platform: String) {
        self = platform.hasPrefix("linux") ? .linux : platform.hasPrefix("windows") ? .windows : .mac
    }
}

/// A computer in the Compute menu: a monitor seen from the front, showing its system's home
/// screen. The more strained the computer, the more its picture tears and fills with static, like
/// an old set losing its signal. Off when the computer can't be reached.
struct ComputeIcon: View {
    let system: HostSystem
    /// 0 to 1; nil is a computer that can't be reached.
    let strain: Double?

    private static let monitor = Bundle.module.url(forResource: "ComputeMonitor", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    /// Where the screen is in the monitor's picture, each side from 0 to 1.
    static let screen = CGRect(x: 0.064, y: 0.136, width: 0.873, height: 0.523)
    private static let framesPerSecond = 12.0

    /// How much of the picture is lost, 0 to 1: none while the computer has room to spare.
    static func noise(strain: Double) -> Double { min(max((strain - 0.5) / 0.5, 0), 1) }

    var body: some View {
        Image(nsImage: Self.monitor ?? NSImage())
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let rect = Self.screen.applying(.init(scaleX: proxy.size.width, y: proxy.size.height))
                    picture
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(.rect(cornerRadius: rect.height * 0.05))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
    }

    @ViewBuilder private var picture: some View {
        if let strain {
            let noise = Self.noise(strain: strain)
            // A clean picture is drawn once; only a noisy one keeps redrawing.
            TimelineView(.animation(minimumInterval: 1 / Self.framesPerSecond, paused: noise == 0)) { timeline in
                Canvas { context, size in
                    Self.draw(&context, size: size, system: system, noise: noise, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            Theme.ink
        }
    }

    private static func draw(_ context: inout GraphicsContext, size: CGSize, system: HostSystem, noise: Double, time: Double) {
        var random = Static(state: UInt64(time * framesPerSecond))
        // Whole, so no seam shows between bands.
        guard noise > 0 else { return home(&context, size, system) }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.ink))
        // The picture in horizontal bands, each pushed sideways: a slow wave down the screen and
        // a jitter per band, both growing with the noise.
        let bands = 16
        let bandHeight = size.height / CGFloat(bands)
        for band in 0 ..< bands {
            var slice = context
            slice.clip(to: Path(CGRect(x: 0, y: CGFloat(band) * bandHeight, width: size.width, height: bandHeight + 0.5)))
            let push = sin(time * 5 + Double(band) * 0.9) * 0.12 + (random.unit() - 0.5) * 0.1
            slice.translateBy(x: size.width * push * noise, y: 0)
            home(&slice, size, system)
        }
        // Wavy stripes of interference over it.
        let stripes = 8
        let tones = [Theme.accent, Theme.deep, Theme.accentTint]
        for stripe in 0 ..< stripes {
            var path = Path()
            for step in 0 ... 12 {
                let y = size.height * CGFloat(step) / 12
                let x = size.width * (CGFloat(stripe) + 0.5) / CGFloat(stripes) + sin(Double(step) * 1.1 + time * 6 + Double(stripe)) * size.width * 0.04
                step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(tones[stripe % tones.count].opacity(noise * 0.5)), lineWidth: size.width / CGFloat(stripes) * 0.35)
        }
        // Snow.
        let grain = max(size.width / 48, 0.5)
        for _ in 0 ..< Int(noise * noise * 220) {
            let flake = CGRect(x: random.unit() * size.width, y: random.unit() * size.height, width: grain * 2, height: grain)
            context.fill(Path(flake), with: .color((random.unit() > 0.5 ? Theme.surface : Theme.ink).opacity(0.75)))
        }
    }

    /// The system's home screen, in the app's own palette: what tells them apart is where each
    /// system puts its bars. macOS: a menu bar and a floating Dock. Windows: a taskbar with its
    /// icons centered. Linux (GNOME): a dark top bar with the clock and a dock down the left.
    private static func home(_ context: inout GraphicsContext, _ size: CGSize, _ system: HostSystem) {
        let w = size.width, h = size.height
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color, radius: CGFloat = 0) {
            context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius), with: .color(color))
        }
        func oval(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color) {
            context.fill(Path(ellipseIn: CGRect(x: x * w, y: y * h, width: width * w, height: height * h)), with: .color(color))
        }
        let icon = h * 0.1
        let blueLight = Theme.color(Theme.Hex.blueLight)
        let tones = [Theme.accent, Theme.deep, Theme.inkMuted, blueLight]
        switch system {
        case .mac:
            box(0, 0, w, h, Theme.accent)
            oval(-0.3, 0.5, 1.1, 1, Theme.deep)
            oval(0.4, 0.6, 1, 0.9, Theme.accentTint)
            box(0, 0, w, h * 0.09, Theme.surface.opacity(0.7))
            let dock = icon * 4 + icon * 0.3 * 5
            box((w - dock) / 2, h * 0.8, dock, icon * 1.6, Theme.surface.opacity(0.7), radius: icon * 0.45)
            for index in 0 ..< 4 {
                box((w - dock) / 2 + icon * 0.3 + CGFloat(index) * icon * 1.3, h * 0.8 + icon * 0.3, icon, icon, tones[index], radius: icon * 0.25)
            }
        case .windows:
            box(0, 0, w, h, Theme.accentTint)
            oval(0.2, 0.15, 0.45, 0.75, Theme.accent)
            oval(0.38, 0.1, 0.45, 0.75, Theme.deep)
            box(0, h * 0.86, w, h * 0.14, Theme.surface)
            let start = (w - icon * 6.2) / 2, top = h * 0.93 - icon / 2, pane = icon * 0.45
            // Start: four panes.
            for index in 0 ..< 4 {
                box(start + CGFloat(index % 2) * icon * 0.55, top + CGFloat(index / 2) * icon * 0.55, pane, pane, Theme.accent)
            }
            for index in 1 ..< 5 {
                box(start + CGFloat(index) * icon * 1.3, top, icon, icon, tones[index % tones.count], radius: icon * 0.2)
            }
        case .linux:
            box(0, 0, w, h, Theme.deep)
            oval(0.35, 0.45, 0.9, 0.9, Theme.accent)
            box(0, 0, w, h * 0.09, Theme.ink)
            box(w * 0.43, h * 0.03, w * 0.14, h * 0.03, Theme.surface, radius: h * 0.015)
            box(0, h * 0.09, icon * 1.6, h * 0.91, Theme.ink.opacity(0.75))
            for index in 0 ..< 4 {
                box(icon * 0.3, h * 0.15 + CGFloat(index) * icon * 1.4, icon, icon, [Theme.surface, Theme.accentTint, blueLight, Theme.accent][index], radius: icon * 0.25)
            }
        }
    }
}

/// The static's dice: the same frame always draws the same snow.
private struct Static {
    var state: UInt64

    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 33) / Double(1 << 31)
    }
}
