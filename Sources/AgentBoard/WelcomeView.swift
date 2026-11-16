import SwiftUI

/// Welcome headlines under evaluation. Set in code; not a user-facing option.
/// Only the headline varies; smoke and cards are shared.
enum WelcomeStyle {
    /// "Start something epic." in ink.
    case monument
    /// "What's the next big thing?" in ink.
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
            VStack(alignment: style == .launch ? .leading : .center, spacing: 28) {
                VStack(spacing: 12) {
                    SkyBlob()
                    headline
                }
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
                .font(Theme.Font.headline)
                .tracking(Theme.Font.headlineTracking)
                .foregroundStyle(Theme.ink)
        case .horizon:
            Text(L("What's the next big thing?"))
                .font(Theme.Font.headline)
                .tracking(Theme.Font.headlineTracking)
                .foregroundStyle(Theme.ink)
        case .launch:
            Text(L("From zero to epic."))
                .font(Theme.Font.headline)
                .tracking(Theme.Font.headlineTracking)
                .foregroundStyle(Theme.ink)
        }
    }

    private var options: [StartOption] {
        [
            StartOption(symbol: "sparkles", tint: Theme.accent, title: L("Start from scratch"),
                        detail: L("An empty repository with a first commit on main."), action: onCreate),
            StartOption(symbol: "arrow.down.circle", tint: Theme.accent, bounce: .bounce.down, title: L("Clone a repository"),
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
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(option.tint)
                    .symbolEffect(option.bounce, options: .speed(0.8), value: pulse)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceDeep, in: .rect(cornerRadius: Theme.Radius.control))
                    .scaleEffect(isHovered ? 1.08 : 1)
                    .rotationEffect(.degrees(isHovered ? -4 : 0))
                .padding(.bottom, 16)
                Text(option.title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 4)
                Text(option.detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The controls' translucent material, a touch more opaque while hovered; no shadow.
            .background(isHovered ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial),
                        in: .rect(cornerRadius: Theme.Radius.card))
            .offset(y: isHovered ? -3 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.bouncy(duration: 0.35)) { isHovered = hovering }
        }
    }
}

