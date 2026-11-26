import SwiftUI

/// The empty canvas: the blob hopping on it, with what to do next.
struct SkyBlobEmptyState: View {
    var title = L("Our sky is still empty")
    var message = L("Add your first agent or card from the bar below.")

    var body: some View {
        VStack(spacing: 14) {
            OwnGraph { SkyBlob() }.frame(width: 170, height: 160)
            Text(title)
                .font(Theme.Font.headline)
                .tracking(Theme.Font.headlineTracking)
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A SwiftUI graph of its own for a view that animates without end: inside the window's graph,
/// each of its frames has the whole window laid out, rendered and committed. Built once: what
/// it shows doesn't follow later changes of the view that holds it.
struct OwnGraph<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSView {
        // A plain view around the hosting view, so its updates never mark the window's graph.
        let container = Passthrough()
        let host = NSHostingView(rootView: content)
        // Sized by its frame: its ideal sizes are never asked for.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Passthrough: NSView {
        // Clicks go to what is under it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One appearance of the blob. The essence never changes (a round blue body, the same eyes,
/// the same hop); the outfit does. Adding an accessory, shape or silhouette is one more case.
struct BlobStyle: Equatable {
    /// Features on top of the seed's own blob outline.
    enum Silhouette: CaseIterable { case plain, tuft, arms }
    enum Accessory: CaseIterable { case none, headphones, scarf, cap, antenna, glasses }
    enum Surrounding: CaseIterable { case none, clouds, sparkles, squares }

    var silhouette: Silhouette
    var accessory: Accessory
    var surrounding: Surrounding
    /// Shapes this appearance's irregular outline.
    var shape: UInt64 = 0

    /// Body box in points: a compact blob, a little wider than tall.
    var bodySize: CGSize { CGSize(width: 88, height: 76) }

    /// Pure: the same seed always gives the same style.
    static func make(seed: UInt64) -> BlobStyle {
        var state = seed
        func next(_ count: Int) -> Int {
            // SplitMix64.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(count))
        }
        return BlobStyle(silhouette: Silhouette.allCases[next(Silhouette.allCases.count)],
                         accessory: Accessory.allCases[next(Accessory.allCases.count)],
                         surrounding: Surrounding.allCases[next(Surrounding.allCases.count)],
                         shape: seed)
    }

    /// A style from `seed` that differs from `previous`.
    static func make(seed: UInt64, avoiding previous: BlobStyle?) -> BlobStyle {
        var seed = seed
        var style = make(seed: seed)
        while style == previous {
            seed &+= 1
            style = make(seed: seed)
        }
        return style
    }

    @MainActor private static var last: BlobStyle?

    /// A new outfit for a new appearance, never the one shown last.
    @MainActor static func fresh() -> BlobStyle {
        let style = make(seed: .random(in: 0 ... .max), avoiding: last)
        last = style
        return style
    }
}

/// A friendly round deep-blue blob that keeps its shape. Hops, stops, looks one way and the other,
/// blinks, and now and then takes a bigger hop; its accessory and surroundings follow with a lag.
/// Still under Reduce Motion, with its outfit drawn.
struct SkyBlob: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Chosen once per appearance; stable while on screen.
    @State private var style: BlobStyle

    init(style: BlobStyle? = nil) {
        _style = State(initialValue: style ?? BlobStyle.fresh())
    }

    struct Pose: Hashable {
        var lift: CGFloat = 0
        var look: CGFloat = 0
        var eyes: CGFloat = 1
        /// Follow-through for accessories and surroundings: positive trails below, negative overshoots.
        var trail: CGFloat = 0
        /// Jelly tremble of the outline, on take-off and landing.
        var wobble: CGFloat = 0
        var animation: Animation = .spring(duration: 0.4, bounce: 0.2)

        static func == (a: Pose, b: Pose) -> Bool {
            a.lift == b.lift && a.look == b.look && a.eyes == b.eyes && a.trail == b.trail && a.wobble == b.wobble
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(lift); hasher.combine(look); hasher.combine(eyes); hasher.combine(trail); hasher.combine(wobble)
        }
    }

    /// The loop, one pose per step; each pose's spring carries the blob into it.
    static let loop: [Pose] = [
        Pose(animation: .spring(duration: 0.6, bounce: 0.2).delay(0.8)),
        Pose(eyes: 0.75, trail: -2, animation: .spring(duration: 0.2, bounce: 0)),
        Pose(lift: 30, trail: 8, wobble: 0.5, animation: .spring(duration: 0.4, bounce: 0.1)),
        // A slight squint on landing.
        Pose(eyes: 0.7, trail: -6, wobble: 1, animation: .spring(duration: 0.22, bounce: 0)),
        Pose(animation: .spring(duration: 0.5, bounce: 0.5)),
        Pose(look: -1, animation: .spring(duration: 0.35, bounce: 0.2).delay(0.6)),
        Pose(look: 1, animation: .spring(duration: 0.4, bounce: 0.2).delay(0.7)),
        Pose(eyes: 0.1, animation: .spring(duration: 0.12, bounce: 0).delay(0.5)),
        Pose(animation: .spring(duration: 0.18, bounce: 0)),
        Pose(eyes: 0.75, trail: -3, animation: .spring(duration: 0.25, bounce: 0).delay(0.6)),
        Pose(lift: 64, trail: 14, wobble: 0.5, animation: .spring(duration: 0.55, bounce: 0.1)),
        Pose(eyes: 0.7, trail: -9, wobble: 1, animation: .spring(duration: 0.26, bounce: 0)),
    ]

    var body: some View {
        Group {
            if reduceMotion {
                figure(Pose())
            } else {
                PhaseAnimator(Self.loop) { figure($0) } animation: { $0.animation }
            }
        }
        .frame(width: 170, height: 160, alignment: .bottom)
        .accessibilityHidden(true)
    }

    func figure(_ pose: Pose) -> some View {
        let size = style.bodySize
        return ZStack(alignment: .bottom) {
            surroundings(pose)
            // A small solid ground shadow that shrinks as the blob rises.
            Ellipse()
                .fill(Theme.deep.opacity(0.14))
                // Scaled, not resized: a frame that animates lays the whole figure out on every frame.
                .frame(width: size.width * 0.8, height: 8)
                .scaleEffect(x: 1 - pose.lift / 140)
                .offset(y: 4)
            ZStack {
                if style.silhouette == .arms { arms(pose, size) }
                blobBody(pose)
                face(pose)
                accessory(pose, size)
            }
            .frame(width: size.width, height: size.height)
            .offset(y: -pose.lift)
        }
        .frame(width: 170, height: 160, alignment: .bottom)
    }

    /// The outline breathes slowly between two shapes on a spring; still under Reduce Motion.
    @ViewBuilder private func blobBody(_ pose: Pose) -> some View {
        if reduceMotion {
            BlobBody(seed: style.shape, breath: 0.5, wobble: 0, tuft: style.silhouette == .tuft).fill(Theme.accent)
        } else {
            PhaseAnimator([0.0, 1.0]) { breath in
                BlobBody(seed: style.shape, breath: breath, wobble: pose.wobble, tuft: style.silhouette == .tuft).fill(Theme.accent)
            } animation: { _ in .spring(duration: 1.9, bounce: 0) }
        }
    }

    /// Bigger, close-set eyes, no mouth: the part that is always the same.
    private func face(_ pose: Pose) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    Capsule().fill(Theme.onAccent).frame(width: 12, height: 19).scaleEffect(y: max(pose.eyes, 2.5 / 19))
                }
            }
            .offset(x: pose.look * 8)
        }
        .offset(y: 8)
    }

    private func arms(_ pose: Pose, _ size: CGSize) -> some View {
        HStack(spacing: size.width - 16) {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule().fill(Theme.accent).frame(width: 12, height: 24)
                    .rotationEffect(.degrees(side * (-50 - Double(pose.trail) * 4)), anchor: .top)
            }
        }
        .offset(y: 8)
    }

    @ViewBuilder private func accessory(_ pose: Pose, _ size: CGSize) -> some View {
        let top = BlobOutline.top(seed: style.shape, in: CGRect(origin: .zero, size: size)) - size.height / 2
        switch style.accessory {
        case .none:
            EmptyView()
        case .headphones:
            ZStack {
                Circle().trim(from: 0.55, to: 0.95)
                    .stroke(Theme.deep, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: size.width * 0.95, height: size.width * 0.95)
                    .offset(y: 8)
                HStack(spacing: size.width - 10) {
                    ForEach(0 ..< 2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5).fill(Theme.deep).frame(width: 12, height: 22)
                    }
                }
                .offset(y: -4)
            }
            .offset(y: pose.trail * 0.4)
        case .scarf:
            ZStack {
                Capsule().fill(Theme.deep).frame(width: size.width * 0.86, height: 10)
                Capsule().fill(Theme.deep).frame(width: 10, height: 24)
                    .rotationEffect(.degrees(-20 - Double(pose.trail) * 5), anchor: .top)
                    .offset(x: size.width * 0.24, y: 12)
            }
            .offset(y: size.height * 0.2)
        case .cap:
            ZStack(alignment: .bottom) {
                Capsule().fill(Theme.deep).frame(width: 46, height: 8).offset(x: 10)
                Circle().trim(from: 0.5, to: 1).fill(Theme.deep).frame(width: 40, height: 40).offset(y: 20)
            }
            .frame(height: 30)
            .offset(y: top - 6 - pose.trail * 0.8)
            .rotationEffect(.degrees(-6))
        case .antenna:
            VStack(spacing: 0) {
                Circle().fill(Theme.deep).frame(width: 12, height: 12)
                Capsule().fill(Theme.accent).frame(width: 4, height: 16)
            }
            .rotationEffect(.degrees(Double(pose.trail) * 2 + Double(pose.look) * 8), anchor: .bottom)
            .offset(y: top - 12)
        case .glasses:
            HStack(spacing: 4) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    Circle().stroke(Theme.deep, lineWidth: 3).frame(width: 24, height: 24)
                }
            }
            .offset(x: pose.look * 8, y: 8)
        }
    }

    /// Small shapes floating around; they drift with the hop's follow-through.
    @ViewBuilder private func surroundings(_ pose: Pose) -> some View {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(-62, -96, 1), (64, -110, 0.8), (70, -48, 0.6)]
        ZStack {
            ForEach(spots.indices, id: \.self) { index in
                let (x, y, scale) = spots[index]
                Group {
                    switch style.surrounding {
                    case .none: EmptyView()
                    case .clouds: CloudPuff().fill(Theme.color(Theme.Hex.blueLight)).frame(width: 34, height: 18)
                    case .sparkles: SparkleShape().fill(Theme.accentText).frame(width: 14, height: 14)
                    case .squares: Rectangle().fill(Theme.accentText).frame(width: 8, height: 8).rotationEffect(.degrees(18))
                    }
                }
                .scaleEffect(scale)
                .offset(x: x + pose.look * 3 * scale, y: y + pose.trail * scale * (index.isMultiple(of: 2) ? 1 : -1))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .offset(y: -8)
    }
}

/// The blob's outline: points around a circle pushed in and out by low-frequency noise from the
/// seed, joined with smooth curves. Pure, so it can be tested.
enum BlobOutline {
    static let count = 16

    /// The seed's small variations on the fixed drop: chubbiness, height, top tilt, base settle.
    struct Traits: Equatable {
        var chubby: CGFloat, tall: CGFloat, tilt: CGFloat, settle: CGFloat, phase: CGFloat
    }

    static func traits(seed: UInt64) -> Traits {
        var state = seed ^ 0xB10B
        func random() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return CGFloat((z ^ (z >> 31)) % 10_000) / 10_000
        }
        return Traits(chubby: 0.95 + random() * 0.07, tall: 0.94 + random() * 0.08,
                      tilt: (random() * 2 - 1) * 0.1, settle: 0.04 + random() * 0.08, phase: random() * 2 * .pi)
    }

    /// A drop: a wide round base tapering to a rounded, slightly tilted top. `breath` (0...1)
    /// undulates the edge slowly; `wobble` trembles it and swings the top with lag, like a tuft.
    static func points(seed: UInt64, breath: CGFloat, wobble: CGFloat, in r: CGRect) -> [CGPoint] {
        let t = traits(seed: seed)
        let rx = r.width / 2 * 0.9 * t.chubby, ry = r.height / 2 * 0.95 * t.tall
        let ground = r.maxY - r.height * 0.03
        return (0 ..< count).map { k in
            let a = CGFloat(k) / CGFloat(count) * 2 * .pi
            let s = sin(a) // 1 at the base, -1 at the top
            let up = (1 - s) / 2 // 0 at the base, 1 at the top
            let edge = 1 + 0.025 * sin(3 * a + t.phase + breath * .pi) + 0.03 * wobble * sin(5 * a + t.phase)
            // Narrows toward the top; the base settles wider onto the ground.
            let width = (0.62 + 0.38 * (1 - up) + t.settle * max(0, s)) * edge
            let height = (s < 0 ? 1.04 : 0.88) * edge
            let lean = (t.tilt + 0.06 * wobble) * up * up
            return CGPoint(x: r.midX + cos(a) * rx * width + lean * rx,
                           y: ground - ry * 0.88 + s * ry * height)
        }
    }

    /// The highest point of the resting outline, for accessories that sit on top.
    static func top(seed: UInt64, in r: CGRect) -> CGFloat {
        points(seed: seed, breath: 0.5, wobble: 0, in: r).map(\.y).min() ?? r.minY
    }

    /// A closed Catmull-Rom curve through the points.
    static func path(seed: UInt64, breath: CGFloat, wobble: CGFloat, in r: CGRect) -> Path {
        let p = points(seed: seed, breath: breath, wobble: wobble, in: r)
        var path = Path()
        path.move(to: p[0])
        for i in 0 ..< p.count {
            let p0 = p[(i - 1 + p.count) % p.count], p1 = p[i], p2 = p[(i + 1) % p.count], p3 = p[(i + 2) % p.count]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }
}

/// The body: the seed's drop, breathing and trembling as its values animate.
struct BlobBody: Shape {
    var seed: UInt64
    var breath: CGFloat
    var wobble: CGFloat
    var tuft = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(breath, wobble) }
        set { breath = newValue.first; wobble = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = BlobOutline.path(seed: seed, breath: breath, wobble: wobble, in: r)
        if tuft {
            // A small curl of hair on top.
            let top = BlobOutline.top(seed: seed, in: r)
            p.addEllipse(in: CGRect(x: r.midX - 4, y: top - 8, width: 14, height: 14))
        }
        return p
    }
}

private struct CloudPuff: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX, y: r.midY - r.height * 0.1, width: r.width * 0.5, height: r.height * 0.6))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.25, y: r.minY, width: r.width * 0.5, height: r.height * 0.9))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.5, y: r.midY - r.height * 0.15, width: r.width * 0.5, height: r.height * 0.65))
        return p
    }
}

private struct SparkleShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: CGPoint(x: c.x, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.maxY), control: c)
        p.addQuadCurve(to: CGPoint(x: r.minX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.minY), control: c)
        return p
    }
}
