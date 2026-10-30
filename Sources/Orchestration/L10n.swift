import Foundation

/// Localized text the core writes where the user reads it (why a program didn't start, the
/// marker between a runner's runs). Translations live in `Resources/<lang>.lproj`.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
