import AgentRuntime
import SwiftUI

/// The one state vocabulary for what runs on a canvas: the sidebar's marks use it, and cards can
/// too. Built only from states the app already tracks: the core's `SessionStatus`, the running
/// runners, and the agents waiting in Needs you.
enum CardStatus: Int, Comparable, Equatable {
    // Ordered by how much it matters: a worktree shows the most pressing of its cards.
    case stopped, running, crashed, waiting

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// An agent card: waiting when it asked for the user, running while its program is alive.
    static func agent(_ status: SessionStatus?, waiting: Bool) -> Self {
        if waiting { return .waiting }
        switch status?.state {
        case .starting, .running: return .running
        case .failed: return .crashed
        default: return .stopped
        }
    }

    /// A runner card: crashed when it failed to start or exited with an error, as its strip says.
    static func runner(_ status: SessionStatus?, running: Bool) -> Self {
        if running { return .running }
        switch status?.state {
        case .failed: return .crashed
        case .exited: return (status?.exitCode ?? 0) != 0 ? .crashed : .stopped
        default: return .stopped
        }
    }

    enum Kind { case agent, runner, browser }

    /// Stopped draws hollow and faint; the others solid.
    func symbol(for kind: Kind) -> String {
        switch (kind, self) {
        case (_, .waiting): "hand.raised.fill"
        case (_, .crashed): "exclamationmark.triangle.fill"
        case (.agent, .running): "terminal.fill"
        case (.agent, .stopped): "terminal"
        case (.runner, .running): "play.fill"
        case (.runner, .stopped): "stop"
        case (.browser, _): "globe"
        }
    }

    var color: Color {
        switch self {
        case .running: Theme.accent
        case .waiting: Theme.onSecondary
        case .crashed: Theme.danger
        case .stopped: Theme.inkMuted.opacity(0.45)
        }
    }

    var label: String {
        switch self {
        case .running: L("Running")
        case .waiting: L("Waiting for you")
        case .crashed: L("Crashed")
        case .stopped: L("Stopped")
        }
    }
}

/// A card kind's mark in its status: running breathes, waiting nudges, crashed and stopped hold still.
struct CardStatusIcon: View {
    let kind: CardStatus.Kind
    let status: CardStatus
    var size: CGFloat = 10
    /// Quiet ink marks without motion, for where a status bar already carries the state.
    var monochrome = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chip: Bool { status == .waiting && kind != .browser && !monochrome }

    var body: some View {
        let image = Image(systemName: status.symbol(for: kind))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(monochrome ? Theme.inkMuted.opacity(status == .stopped ? 0.6 : 1)
                             : kind == .browser ? Theme.inkMuted : status.color)
            // Waiting sits on a yellow chip, the one mark that asks for the user.
            .padding(chip ? 2 : 0)
            .background(chip ? Theme.secondary : .clear,
                        in: .rect(cornerRadius: Theme.Radius.thumb))
        Group {
            if (status == .running || status == .waiting) && kind != .browser && !reduceMotion && !monochrome {
                PhaseAnimator([false, true]) { phase in
                    image
                        .opacity(status == .running && phase ? 0.45 : 1)
                        .scaleEffect(status == .waiting && phase ? 1.18 : 1)
                } animation: { _ in
                    status == .waiting ? .bouncy(duration: 0.6) : .smooth(duration: 1.1)
                }
            } else {
                image
            }
        }
        .frame(width: size + 4, height: size + 4)
        .help(status.label)
    }
}

/// A small dot that speaks only when there is something to say: running breathes in the
/// accent, waiting and crashed hold still in their attention colors, stopped shows nothing.
struct CardStatusDot: View {
    let status: CardStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle()
            .fill(status == .waiting ? Theme.secondary : status.color)
            .frame(width: 6, height: 6)
        if status == .stopped {
            EmptyView()
        } else if status == .running && !reduceMotion {
            PhaseAnimator([false, true]) { phase in
                dot.scaleEffect(phase ? 0.6 : 1).opacity(phase ? 0.45 : 1)
            } animation: { _ in .smooth(duration: 1.1) }
        } else {
            dot
        }
    }
}
