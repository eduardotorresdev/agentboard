import SwiftUI

/// What a worktree's canvas holds, as its sidebar mark shows it.
struct WorktreeContents: Equatable {
    var hasAgents = false
    var hasRunners = false
    var runnerRunning = false
    var hasBrowsers = false

    var isEmpty: Bool { !hasAgents && !hasRunners && !hasBrowsers }
    /// An agent open, or a runner running.
    var isWorking: Bool { hasAgents || runnerRunning }
}

/// The worktree's mark, built from what its canvas holds: a rounded square per agent terminal,
/// a dot per runner, a ring per browser. One kind sits alone and large; two share the mark on a
/// diagonal; all three make a triangle. While the worktree works, it moves in a loop: the
/// square turns, the dot of a running runner pulses, the ring breathes.
struct WorktreeGlyph: View {
    let contents: WorktreeContents
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Kind { case agent, runner, browser }

    private var kinds: [Kind] {
        (contents.hasAgents ? [.agent] : []) + (contents.hasRunners ? [.runner] : []) + (contents.hasBrowsers ? [.browser] : [])
    }

    var body: some View {
        Group {
            if contents.isWorking && !reduceMotion {
                // Without a trigger, it cycles for as long as it is shown.
                PhaseAnimator([false, true]) { phase in
                    marks(phase: phase)
                } animation: { _ in
                    .smooth(duration: 0.9)
                }
            } else {
                marks(phase: false)
            }
        }
        .frame(width: 14, height: 14)
        .opacity(isSelected ? 1 : 0.8)
        .accessibilityHidden(true)
    }

    private func marks(phase: Bool) -> some View {
        let kinds = kinds
        let layout = Self.layout(kinds.count)
        return ZStack {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                mark(kind, size: layout.size, phase: phase)
                    .offset(x: layout.offsets[index].width, y: layout.offsets[index].height)
            }
        }
    }

    /// Each combination's arrangement in the 14-point mark.
    private static func layout(_ count: Int) -> (size: CGFloat, offsets: [CGSize]) {
        switch count {
        case 1: (10, [.zero])
        case 2: (6.5, [CGSize(width: -3.5, height: -3.5), CGSize(width: 3.5, height: 3.5)])
        default: (6.5, [CGSize(width: -3.5, height: -3), CGSize(width: 3.5, height: -3), CGSize(width: 0, height: 3.5)])
        }
    }

    @ViewBuilder
    private func mark(_ kind: Kind, size: CGFloat, phase: Bool) -> some View {
        switch kind {
        case .agent:
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.accent)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(phase ? 90 : 0))
                .scaleEffect(phase ? 0.82 : 1)
        case .runner:
            let running = contents.runnerRunning
            Circle()
                .fill(Theme.secondary.opacity(running ? 1 : 0.45))
                .frame(width: size, height: size)
                .scaleEffect(running && phase ? 0.6 : 1)
        case .browser:
            Circle()
                .strokeBorder(Theme.line.opacity(0.6), lineWidth: max(1.5, size * 0.2))
                .frame(width: size, height: size)
                .scaleEffect(contents.isWorking && phase ? 1.12 : 1)
        }
    }
}
