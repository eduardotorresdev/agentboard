import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac awake (no idle sleep of system or display) while on, like `caffeinate -di`.
/// The choice survives relaunches; the power assertion dies with the process.
@MainActor @Observable
final class Caffeinate {
    static let shared = Caffeinate()
    private static let key = "caffeinate.isOn"

    @ObservationIgnored private var assertion: IOPMAssertionID = 0

    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.key)
            apply()
        }
    }

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.key)
        apply()
    }

    private func apply() {
        if isOn, assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Agents are working" as CFString,
                &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !isOn, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

import SwiftUI

/// Wisps of steam rising from the cup while caffeinate is on, drifting slowly like smoke.
struct CaffeinateSteam: View {
    var color: Color

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                canvas.addFilter(.blur(radius: 1.2))
                let t = context.date.timeIntervalSinceReferenceDate
                for i in 0..<3 {
                    let period = 2.4 + Double(i) * 0.35
                    let phase = (t / period + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let rise = CGFloat(phase)
                    let sway = CGFloat(sin(t * 1.3 + Double(i) * 2)) * 2.5 * rise
                    let x = size.width / 2 + CGFloat(i - 1) * 3 + sway
                    let y = size.height * (1 - rise)
                    let radius = 1.5 + 2.5 * rise
                    let alpha = sin(Double(rise) * .pi) * 0.55
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(color.opacity(alpha)))
                }
            }
        }
        .frame(width: 16, height: 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
