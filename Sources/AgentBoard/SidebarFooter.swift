import AgentRuntime
import AppKit
import Charts
import SwiftUI

/// The sidebar's foot: caffeinate and zen, what the worktree's computer is using, the computers,
/// and what is left of the agents' plan.
struct SidebarFooter: View {
    let hosts: HostStores
    let board: BoardController
    /// The host of the worktree open on the canvas; nil is this Mac.
    let host: UUID?
    let organization: UUID

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                CaffeinateButton()
                ZenButton(board: board).frame(width: 86)
            }
            HostGauges(hosts: hosts, host: host)
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

/// What the worktree's computer is using: its processor and its memory, each with the last minute
/// of samples under it and its limit dashed at the top.
private struct HostGauges: View {
    let hosts: HostStores
    let host: UUID?
    @State private var samples: [HostStats] = []
    /// About a minute, at one sample every two seconds.
    static let history = 30

    var body: some View {
        let last = samples.last
        let gigabytes = { (bytes: UInt64, digits: Int) in
            (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(digits))) + " GB"
        }
        HStack(spacing: 8) {
            HostGauge(symbol: "cpu", title: L("CPU"),
                      value: last.map { $0.cpu.formatted(.percent.precision(.fractionLength(0))) },
                      limit: (1.0).formatted(.percent), points: samples.map(\.cpu))
                .help(L("Of every processor together."))
            HostGauge(symbol: "memorychip", title: L("Mem"),
                      value: last.map { gigabytes($0.memoryUsed, 1) },
                      limit: last.map { gigabytes($0.memoryTotal, 0) } ?? "",
                      points: samples.map { $0.memoryTotal > 0 ? Double($0.memoryUsed) / Double($0.memoryTotal) : 0 })
                .help(L("Memory in use, of what the computer has."))
        }
        // Another computer's are another history: it starts over.
        .task(id: host) {
            samples = []
            var sampler = LocalHostSampler()
            if host == nil {
                // The processor's share is of the time between two samples.
                _ = sampler.sample()
                try? await Task.sleep(for: .milliseconds(400))
            }
            while !Task.isCancelled {
                // Another computer's core reports its own; this Mac's are sampled here.
                if let stats = host == nil ? sampler.sample() : hosts[host]?.hostStats {
                    withAnimation(.smooth(duration: 0.6)) {
                        samples.append(stats)
                        if samples.count > Self.history { samples.removeFirst(samples.count - Self.history) }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// One gauge: its name, the value against its limit, and the recent samples (0 to 1) as an area.
private struct HostGauge: View {
    let symbol: String
    let title: String
    let value: String?
    let limit: String
    let points: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "–")
                    .font(Theme.Font.heading.monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if !limit.isEmpty {
                    Text(L("of \(limit)")).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            chart
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: blockShape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { L("\($0) of \(limit)") } ?? "")
    }

    /// The newest sample at the right edge; the line fills in from there as samples arrive.
    private var chart: some View {
        let start = HostGauges.history - points.count
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                AreaMark(x: .value("Sample", start + index), y: .value("Used", min(point, 1)))
                    .foregroundStyle(Theme.accent.opacity(0.14))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Sample", start + index), y: .value("Used", min(point, 1)))
                    .foregroundStyle(Theme.accentText)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            // The limit.
            RuleMark(y: .value("Limit", 1))
                .foregroundStyle(Theme.faint)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXScale(domain: 0 ... HostGauges.history - 1)
        .chartYScale(domain: 0 ... 1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 30)
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
