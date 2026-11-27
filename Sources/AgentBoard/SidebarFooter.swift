import AgentRuntime
import AppKit
import Charts
import Orchestration
import SwiftUI

/// The sidebar's foot: caffeinate and zen, what the board uses on this Mac, the computers,
/// and what is left of the agents' plan.
struct SidebarFooter: View {
    let hosts: HostStores
    let board: BoardController
    let organization: UUID

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                CaffeinateButton()
                ZenButton(board: board).frame(width: 86)
            }
            AppGauges()
            HostsControl(hosts: hosts)
            AgentUsageBlock(organization: organization)
        }
    }
}

/// A footer block's shape: soft continuous corners.
private let blockShape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)

/// Keeps the Mac awake. Its fill is its state: the coffee pack's maroon while on, a plain control while off.
private struct CaffeinateButton: View {
    private let caffeinate = Caffeinate.shared
    @State private var isHovered = false
    private static let on = Bundle.module.image(forResource: "CaffeinateOn")
    private static let off = Bundle.module.image(forResource: "CaffeinateOff")

    var body: some View {
        let isOn = caffeinate.isOn
        Button { withAnimation(.snappy(duration: 0.25)) { caffeinate.isOn.toggle() } } label: {
            HStack(spacing: 8) {
                (isOn ? Self.on : Self.off).map { Image(nsImage: $0).resizable().scaledToFit() }
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text(isOn ? L("Caffeinated") : L("Relaxed"))
                    .font(Theme.Font.label)
                    .foregroundStyle(isOn ? Theme.onCaffeinate : Theme.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(isOn ? Theme.caffeinate : isHovered ? Theme.surface : Theme.surfaceDeep, in: blockShape)
            .contentShape(blockShape)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.snappy(duration: 0.15)) { isHovered = inside } }
        .help(isOn ? L("Caffeinate on: the Mac and its display stay awake. Click to let them sleep.")
            : L("Caffeinate: keeps the Mac and its display awake while agents work."))
        .accessibilityLabel(L("Caffeinate"))
        .accessibilityValue(isOn ? L("On") : L("Off"))
    }
}

/// Zen mode: everything but the canvas steps aside. Filled with the accent while on.
private struct ZenButton: View {
    let board: BoardController
    @State private var isHovered = false

    var body: some View {
        Button { board.isZen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "figure.mind.and.body").accessibilityHidden(true)
                Text(L("Zen")).lineLimit(1)
            }
            .font(Theme.Font.label)
            .foregroundStyle(board.isZen ? Theme.onAccent : Theme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(board.isZen ? Theme.accent : isHovered ? Theme.surface : Theme.surfaceDeep, in: blockShape)
            .contentShape(blockShape)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.snappy(duration: 0.15)) { isHovered = inside } }
        .help(L("Zen mode: hides everything but the canvas, its tools, and Needs you."))
        .accessibilityLabel(L("Zen mode"))
        .accessibilityAddTraits(board.isZen ? .isSelected : [])
    }
}

/// What the board itself uses on this Mac, the app and its core together (not the agents they
/// run): processor and memory, each over the last minute of samples.
private struct AppGauges: View {
    @State private var samples: [RunnerStats] = []
    /// About a minute, at one sample every two seconds.
    static let history = 30

    var body: some View {
        let last = samples.last
        HStack(spacing: 8) {
            AppGauge(symbol: "cpu", value: last?.cpu.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) },
                     points: samples.map { $0.cpu ?? 0 })
                .help(L("Processor the board uses, without its agents; 100% is one core."))
                .accessibilityLabel(L("CPU"))
            AppGauge(symbol: "memorychip", value: last.map { ByteCountFormatter.string(fromByteCount: Int64($0.memory), countStyle: .memory) },
                     points: samples.map { Double($0.memory) })
                .help(L("Memory the board uses, without its agents."))
                .accessibilityLabel(L("Memory"))
        }
        .task {
            var previous: ProcessInspector.Sample?
            let core = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentBoardCore")
            while !Task.isCancelled {
                let sample = await Task.detached { [previous] in
                    let pids = [getpid()] + (core.map(ProcessInspector.processes(running:)) ?? [])
                    return ProcessInspector.sample(processes: pids, previous: previous)
                }.value
                previous = sample
                withAnimation(.smooth(duration: 0.6)) {
                    samples.append(sample.stats)
                    if samples.count > Self.history { samples.removeFirst(samples.count - Self.history) }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// One compact gauge: its symbol and value on one line, the recent samples drawn behind them,
/// scaled to their own peak.
private struct AppGauge: View {
    let symbol: String
    let value: String?
    let points: [Double]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Theme.inkMuted).accessibilityHidden(true)
            Text(value ?? "–")
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .font(Theme.Font.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(alignment: .bottom) { chart.padding(.top, 10) }
        .background(Theme.surface, in: blockShape)
        .clipShape(blockShape)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(value ?? "")
    }

    /// The newest sample at the right edge; the line fills in from there as samples arrive.
    private var chart: some View {
        let start = AppGauges.history - points.count
        let peak = max(points.max() ?? 0, 1) * 1.15
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                AreaMark(x: .value("Sample", start + index), y: .value("Used", point))
                    .foregroundStyle(Theme.accent.opacity(0.14))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Sample", start + index), y: .value("Used", point))
                    .foregroundStyle(Theme.accentText.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0 ... AppGauges.history - 1)
        .chartYScale(domain: 0 ... peak)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

/// A thin bar of how much of something is used.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(Theme.surfaceDeep)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
    }
}

/// How much of the agents' plan is used: the 5-hour session and the week, refreshed every minute.
/// Hidden while unknown (no login, or an isolated instance).
private struct AgentUsageBlock: View {
    let organization: UUID
    @State private var usage: ClaudeUsage?
    /// The provider's official symbol.
    private static let symbol = Bundle.module.url(forResource: "ClaudeSymbol", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    private static let provider = AgentCatalog.provider(id: "claude")

    var body: some View {
        ZStack {
            if let usage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Self.symbol.map { Image(nsImage: $0).resizable().scaledToFit() }
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        Text(Self.provider?.title ?? "").font(Theme.Font.label).foregroundStyle(Theme.ink)
                        if let plan = usage.plan {
                            Text(plan.capitalized).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    // Plans without a 5-hour limit get no session from the API: only the week shows.
                    if let session = usage.session {
                        row(L("Session"), session, color: Theme.accent, help: L("Used of the current 5-hour session."))
                    }
                    row(L("Week"), usage.week, color: Theme.you, help: L("Used of this week's limit across every model."))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: blockShape)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Agent usage"))
                .transition(.opacity)
            }
        }
        // Each organization is signed in to its own account: switching restarts the polling.
        .task(id: organization) {
            withAnimation(.smooth(duration: 0.3)) { usage = nil }
            while !Task.isCancelled {
                do {
                    let fresh = try await ClaudeUsageClient.fetch(organization: organization)
                    withAnimation(.smooth(duration: 0.3)) { usage = fresh }
                } catch {
                    NSLog("Agent usage unavailable: %@", String(describing: error))
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func row(_ title: String, _ window: ClaudeUsage.Window?, color: Color, help: String) -> some View {
        let used = (window?.used ?? 0) / 100
        return HStack(spacing: 10) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).frame(width: 52, alignment: .leading)
            UsageBar(fraction: used, color: used > 0.8 ? Theme.danger : color)
            Text(used, format: .percent.precision(.fractionLength(0)))
                .font(Theme.Font.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 32, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .help(window?.resetsAt.map { help + " " + L("resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") } ?? help)
        .accessibilityElement(children: .combine)
    }
}
