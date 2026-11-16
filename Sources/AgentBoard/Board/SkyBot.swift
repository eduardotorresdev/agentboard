import SwiftUI

/// The empty canvas: a small cloud robot hopping on the sky, with what to do next.
struct SkyBotEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            SkyBot()
                .frame(width: 96, height: 120)
            Text(L("Our sky is still empty"))
                // Bold 22pt is WCAG large text: white passes AA (3:1) on the sky.
                .font(.system(size: 22, weight: .bold))
                .tracking(Theme.Font.headlineTracking)
                .foregroundStyle(.white)
            Text(L("Add your first agent or card from the bar below."))
                .font(Theme.Font.body.weight(.medium))
                .foregroundStyle(Theme.onSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.cream, in: .rect(cornerRadius: Theme.Radius.control))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A robot drawn in the sky's style: a cream cloud body and head, a sky-blue visor and a yellow
/// antenna bulb. Hops in a loop with squash and stretch, and blinks; still under Reduce Motion.
struct SkyBot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Hop: CaseIterable {
        case rest, crouch, air, land

        var lift: CGFloat { self == .air ? -34 : 0 }
        var scale: CGSize {
            switch self {
            case .rest: CGSize(width: 1, height: 1)
            case .crouch, .land: CGSize(width: 1.14, height: 0.84)
            case .air: CGSize(width: 0.9, height: 1.12)
            }
        }
        var animation: Animation {
            switch self {
            case .rest: .spring(duration: 0.5, bounce: 0.3).delay(0.9)
            case .crouch: .spring(duration: 0.22, bounce: 0)
            case .air: .spring(duration: 0.42, bounce: 0.15)
            case .land: .spring(duration: 0.24, bounce: 0)
            }
        }
    }

    var body: some View {
        if reduceMotion {
            figure(eyesOpen: 1).frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            PhaseAnimator(Hop.allCases) { hop in
                PhaseAnimator([1.0, 1.0, 0.1], content: { eyes in
                    figure(eyesOpen: eyes)
                }, animation: { eyes in eyes < 1 ? .spring(duration: 0.12) : .spring(duration: 0.18).delay(1.6) })
                .scaleEffect(x: hop.scale.width, y: hop.scale.height, anchor: .bottom)
                .offset(y: hop.lift)
                .frame(maxHeight: .infinity, alignment: .bottom)
            } animation: { $0.animation }
        }
    }

    private func figure(eyesOpen: CGFloat) -> some View {
        Canvas { context, size in
            let w = size.width
            let cream = Theme.cream, paper = Theme.surface, ink = Theme.ink
            // Body: a cloud of overlapping puffs.
            // A cream rim around the union of the puffs, then the paper fill over it.
            func puffs(grow: CGFloat) -> Path {
                var path = Path()
                for (x, y, r) in [(0.30, 0.80, 0.20), (0.50, 0.74, 0.24), (0.70, 0.80, 0.20), (0.5, 0.86, 0.2)] {
                    path.addEllipse(in: CGRect(x: w * (x - r), y: w * (y - r) + 18, width: w * r * 2, height: w * r * 2)
                        .insetBy(dx: -grow, dy: -grow))
                }
                return path
            }
            context.fill(puffs(grow: 2.5), with: .color(cream))
            context.fill(puffs(grow: 0), with: .color(paper))
            // Head: a rounded square with cloud ears.
            let head = CGRect(x: w * 0.18, y: 24, width: w * 0.64, height: w * 0.52)
            context.fill(Path(ellipseIn: CGRect(x: head.minX - 9, y: head.midY - 10, width: 20, height: 20)), with: .color(cream))
            context.fill(Path(ellipseIn: CGRect(x: head.maxX - 11, y: head.midY - 10, width: 20, height: 20)), with: .color(cream))
            context.fill(Path(roundedRect: head, cornerRadius: 16), with: .color(paper))
            // Visor and eyes.
            let visor = head.insetBy(dx: 9, dy: 11)
            context.fill(Path(roundedRect: visor, cornerRadius: 10), with: .color(Theme.accent))
            let eyeH = max(10 * eyesOpen, 2)
            for x in [visor.minX + visor.width * 0.3, visor.minX + visor.width * 0.7] {
                context.fill(Path(roundedRect: CGRect(x: x - 4, y: visor.midY - eyeH / 2, width: 8, height: eyeH), cornerRadius: 4),
                             with: .color(.white))
            }
            // Antenna with a yellow bulb.
            var stem = Path()
            stem.move(to: CGPoint(x: w / 2, y: head.minY))
            stem.addLine(to: CGPoint(x: w / 2, y: 10))
            context.stroke(stem, with: .color(ink.opacity(0.5)), lineWidth: 2.5)
            context.fill(Path(ellipseIn: CGRect(x: w / 2 - 6, y: 2, width: 12, height: 12)), with: .color(Theme.secondary))
        }
        .accessibilityHidden(true)
    }
}
