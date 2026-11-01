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
