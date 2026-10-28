import SwiftUI

/// Welcome headlines under evaluation. Set in code; not a user-facing option.
/// Only the headline varies; smoke and cards are shared.
enum WelcomeStyle {
    /// "Start something epic." in ink.
    case monument
    /// "What's the next big thing?" in violet.
    case horizon
    /// "From zero to epic." in ink, left-aligned.
    case launch
}

/// First run: no projects yet, so the canvas offers the three ways to start one.
struct WelcomeView: View {
    var style: WelcomeStyle = .monument
    let onClone: () -> Void
    let onCreate: () -> Void
    let onOpen: () -> Void

    /// Bumped to play one card's icon animation; cards take turns left to right, then repeat.
    @State private var pulses = [0, 0, 0]

    var body: some View {
        ZStack {
            Smoke()
            VStack(alignment: style == .launch ? .leading : .center, spacing: 44) {
                headline
                cards
            }
            .frame(maxWidth: 720)
            .padding(40)
        }
        .task { await playIcons() }
    }

    /// One icon at a time: play it, wait for it to finish, rest 1s, then the next one.
    private func playIcons() async {
        let animation: Duration = .milliseconds(900)
        let rest: Duration = .seconds(1)
        try? await Task.sleep(for: rest)
        var index = 0
        while !Task.isCancelled {
            pulses[index] += 1
            try? await Task.sleep(for: animation + rest)
            index = (index + 1) % pulses.count
        }
    }

    @ViewBuilder
    private var headline: some View {
        switch style {
        case .monument:
            Text(L("Start something epic."))
                .font(.system(size: 56, weight: .bold))
                .tracking(-1.5)
        case .horizon:
            Text(L("What's the next big thing?"))
                .font(.system(size: 48, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.accent)
        case .launch:
            Text(L("From zero to epic."))
                .font(.system(size: 52, weight: .bold))
                .tracking(-1.4)
        }
    }

    private var options: [StartOption] {
        [
            StartOption(symbol: "sparkles", tint: Theme.accent, title: L("Start from scratch"),
                        detail: L("An empty repository with a first commit on main."), action: onCreate),
            StartOption(symbol: "arrow.down.circle", tint: Theme.secondary, bounce: .bounce.down, title: L("Clone a repository"),
                        detail: L("Copy a repository from GitHub, GitLab, or any remote."), action: onClone),
            StartOption(symbol: "folder", tint: Theme.accent, title: L("Open a folder"),
                        detail: L("Add a project that already exists on this Mac."), action: onOpen),
        ]
    }

    private var cards: some View {
        HStack(spacing: 16) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                StartCard(option: option, pulse: pulses[index])
            }
        }
        // Equal-height cards sized to their content, not to the window.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StartOption {
    let symbol: String
    let tint: Color
    /// Direction the icon bounces when its turn comes.
    var bounce: BounceSymbolEffect = .bounce.up
    let title: String
    let detail: String
    let action: () -> Void
}

/// A large start option: tinted icon badge, name, and one line on what the option does.
private struct StartCard: View {
    let option: StartOption
    let pulse: Int

    @State private var isHovered = false

    var body: some View {
        Button(action: option.action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: option.symbol)
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(option.tint)
                    .symbolEffect(option.bounce, options: .speed(0.8), value: pulse)
                    .frame(width: 64, height: 64)
                    .background(option.tint.opacity(0.12), in: .rect(cornerRadius: 18))
                    .scaleEffect(isHovered ? 1.08 : 1)
                    .rotationEffect(.degrees(isHovered ? -4 : 0))
                .padding(.bottom, 20)
                Text(option.title)
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 4)
                Text(option.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: .rect(cornerRadius: 18))
            .shadow(color: Theme.line.opacity(isHovered ? 0.14 : 0.07), radius: isHovered ? 22 : 14, y: isHovered ? 10 : 4)
            .offset(y: isHovered ? -3 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.bouncy(duration: 0.35)) { isHovered = hovering }
        }
    }
}

/// Ambient light: soft violet and orange lights wandering across the whole canvas.
/// Ambient effects must always move; a static bloom reads as a stain.
/// Each light retargets a slow spring to a new random spot before the last one settles,
/// so the motion never stops.
private struct Smoke: View {
    private struct Light {
        let color: Color
        let opacity: Double
        let size: CGFloat
    }

    private let lights = [
        Light(color: Theme.accent, opacity: 0.30, size: 560),
        Light(color: Theme.secondary, opacity: 0.20, size: 460),
        Light(color: Theme.accent, opacity: 0.18, size: 420),
    ]

    /// Unit positions (0...1) within the canvas, one per light.
    @State private var positions: [UnitPoint] = [
        UnitPoint(x: 0.25, y: 0.7), UnitPoint(x: 0.75, y: 0.75), UnitPoint(x: 0.5, y: 0.3),
    ]
    @State private var scales: [CGFloat] = [1, 1, 1]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(lights.indices, id: \.self) { index in
                    Circle()
                        .fill(lights[index].color.opacity(lights[index].opacity))
                        .frame(width: lights[index].size, height: lights[index].size)
                        .scaleEffect(scales[index])
                        .position(x: positions[index].x * proxy.size.width,
                                  y: positions[index].y * proxy.size.height)
                }
            }
            .blur(radius: 90)
        }
        .allowsHitTesting(false)
        .task {
            while !Task.isCancelled {
                withAnimation(.smooth(duration: 6)) {
                    positions = positions.map { _ in
                        UnitPoint(x: .random(in: 0.1...0.9), y: .random(in: 0.15...0.95))
                    }
                    scales = scales.map { _ in .random(in: 0.8...1.25) }
                }
                try? await Task.sleep(for: .seconds(4.5))
            }
        }
    }
}
