import SwiftUI

/// The Mac's blob (Sources/AgentBoard/Board/SkyBlob.swift), drawn on the GPU by `Blob.metal`:
/// same outline, eyes, clouds and hop loop. Springs move the pose; the shader only draws it.
/// A fixed pose under Reduce Motion and while the app isn't in front.
struct SkyBlob: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    struct Pose: Hashable {
        var lift: CGFloat = 0, look: CGFloat = 0, eyes: CGFloat = 1, trail: CGFloat = 0, wobble: CGFloat = 0
        var duration = 0.4, bounce = 0.2, delay = 0.0
        var animation: Animation { .spring(duration: duration, bounce: bounce).delay(delay) }
    }

    /// The Mac's loop, pose for pose.
    static let loop: [Pose] = [
        Pose(duration: 0.6, delay: 0.8),
        Pose(eyes: 0.75, trail: -2, duration: 0.2, bounce: 0),
        Pose(lift: 30, trail: 8, wobble: 0.5, duration: 0.4, bounce: 0.1),
        Pose(eyes: 0.7, trail: -6, wobble: 1, duration: 0.22, bounce: 0),
        Pose(duration: 0.5, bounce: 0.5),
        Pose(look: -1, duration: 0.35, delay: 0.6),
        Pose(look: 1, duration: 0.4, delay: 0.7),
        Pose(eyes: 0.1, duration: 0.12, bounce: 0, delay: 0.5),
        Pose(duration: 0.18, bounce: 0),
        Pose(eyes: 0.75, trail: -3, duration: 0.25, bounce: 0, delay: 0.6),
        Pose(lift: 64, trail: 14, wobble: 0.5, duration: 0.55, bounce: 0.1),
        Pose(eyes: 0.7, trail: -9, wobble: 1, duration: 0.26, bounce: 0),
    ]

    var body: some View {
        Group {
            if reduceMotion || scenePhase != .active {
                BlobFigure(pose: Pose(), breath: 0.5)
            } else {
                PhaseAnimator(Self.loop) { pose in
                    // The outline breathes slowly on its own spring, under the hop.
                    PhaseAnimator([0.0, 1.0]) { breath in BlobFigure(pose: pose, breath: breath) }
                        animation: { _ in .spring(duration: 1.9, bounce: 0) }
                } animation: { $0.animation }
            }
        }
        .frame(width: 170, height: 160)
        .accessibilityHidden(true)
    }
}

/// One frame of the blob: the pose as animatable values, so springs interpolate what the shader gets.
private struct BlobFigure: View, Animatable {
    var pose: SkyBlob.Pose
    var breath: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(AnimatablePair(pose.lift, pose.look), AnimatablePair(AnimatablePair(pose.eyes, pose.trail), AnimatablePair(pose.wobble, breath))) }
        set {
            (pose.lift, pose.look) = (newValue.first.first, newValue.first.second)
            (pose.eyes, pose.trail) = (newValue.second.first.first, newValue.second.first.second)
            (pose.wobble, breath) = (newValue.second.second.first, newValue.second.second.second)
        }
    }

    /// `BlobOutline.traits(seed: 0)`: the Mac's plain blob's proportions.
    static let traits: (chubby: Float, tall: Float, tilt: Float, settle: Float, phase: Float) = {
        var state: UInt64 = 0 ^ 0xB10B
        func random() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) % 10_000) / 10_000
        }
        return (0.95 + random() * 0.07, 0.94 + random() * 0.08, (random() * 2 - 1) * 0.1, 0.04 + random() * 0.08, random() * 2 * .pi)
    }()

    var body: some View {
        let t = Self.traits
        Rectangle()
            // Opaque so the effect runs on every pixel; the shader decides what shows.
            .fill(Theme.surface)
            .colorEffect(ShaderLibrary.blob(
                .float4(Float(pose.lift), Float(pose.look), Float(pose.eyes), Float(pose.trail)),
                .float2(Float(breath), Float(pose.wobble)),
                .float4(t.chubby, t.tall, t.tilt, t.settle),
                .float(t.phase),
                .color(Theme.deep), .color(.white), .color(Theme.blueLight)))
    }
}

/// The empty canvas: the blob on the sky, with what to do next.
struct SkyBlobEmptyState: View {
    var title = "Our sky is still empty"
    var message = "Add your first agent or card with the + above."

    var body: some View {
        VStack(spacing: 14) {
            SkyBlob()
            Text(title).font(Theme.Font.headline).tracking(Theme.Font.headlineTracking).foregroundStyle(Theme.ink)
            Text(message).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}
