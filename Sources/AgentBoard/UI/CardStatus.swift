import Orchestration
import AgentRuntime
import SwiftUI

/// The one state vocabulary for what runs on a canvas: the sidebar's marks use it, and cards can
/// too. Built only from states the app already tracks: the core's `SessionStatus`, the running
/// runners, and the agents waiting in Needs you.
enum CardStatus: Int, Comparable, Equatable {
    // Ordered by how much it matters: a worktree shows the most pressing of its cards.
    case stopped, running, crashed, waiting

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// An agent card: waiting when it asked for the user while its program runs; a crash beats
    /// waiting, since an agent that ended can't answer.
    static func agent(_ status: SessionStatus?, waiting: Bool) -> Self {
        let state = from(status)
        return waiting && state == .running ? .waiting : state
    }

    /// A runner card, from its session's status. `running` (the core's runner report) only
    /// counts when no status is known yet: the report says a runner has run, not that it runs.
    static func runner(_ status: SessionStatus?, running: Bool) -> Self {
        guard status != nil else { return running ? .running : .stopped }
        return from(status)
    }

    /// Running while the program is alive. Crashed when it failed to start, exited with an
    /// error code (1–127), or was killed outright (137, SIGKILL, as an out-of-memory kill) without
    /// being asked to stop. A stop the user asked for arrives as `.stopped`; other signals
    /// (Ctrl-C 130, SIGTERM 143, SIGHUP 129) count as stopped.
    static func from(_ status: SessionStatus?) -> Self {
        switch status?.state {
        case .starting, .running: return .running
        case .failed: return .crashed
        case .exited:
            let code = status?.exitCode ?? 0
            return (1 ..< 128).contains(code) || code == 137 ? .crashed : .stopped
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
        case .waiting: Theme.deep
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

/// A small dot that speaks only when there is something to say: running breathes in the
/// accent, waiting (deep blue) and crashed (red) hold still, stopped shows nothing.
struct CardStatusDot: View {
    let status: CardStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle()
            .fill(status.color)
            .frame(width: 6, height: 6)
        if status == .stopped {
            EmptyView()
        } else if status == .running && !reduceMotion {
            BreathingDot(color: status.color).frame(width: 6, height: 6)
        } else {
            dot
        }
    }
}

/// The running dot, breathing by size only (full color keeps 3:1 at every phase), as on the
/// cards. Core Animation runs it in the render server: a SwiftUI animation that never ends has
/// the whole window's view tree redrawn on every frame.
private struct BreathingDot: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> DotView { DotView() }
    func updateNSView(_ view: DotView, context: Context) { view.dot.backgroundColor = NSColor(color).cgColor }

    final class DotView: NSView {
        let dot = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        // Clicks and hover go to the row under the dot.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = bounds.width / 2
            CATransaction.commit()
        }

        // A layer loses its animations when it leaves the window, so each arrival starts it again.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            dot.removeAllAnimations()
            guard window != nil else { return }
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 1
            spring.toValue = 0.65
            spring.stiffness = 30
            spring.damping = 9
            spring.duration = spring.settlingDuration
            spring.autoreverses = true
            spring.repeatCount = .infinity
            dot.add(spring, forKey: "status")
        }
    }
}

/// Card states from the one feed (the core's statuses, the runner report, Needs you), for every
/// card of every organization: the sidebar, card frames and the organization switcher read here.
extension AgentStore {
    func cardStatus(_ record: AgentRecord) -> CardStatus {
        record.runner != nil
            ? CardStatus.runner(statuses[record.id], running: runningRunners.contains(record.id))
            : CardStatus.agent(statuses[record.id], waiting: attention.contains { $0.id == record.id && $0.needsUser })
    }

    /// The most pressing state among `organization`'s cards; nil when it has none.
    func status(ofOrganization organization: UUID) -> CardStatus? {
        agents.filter { $0.organizationID == organization }.map(cardStatus).max()
    }
}
