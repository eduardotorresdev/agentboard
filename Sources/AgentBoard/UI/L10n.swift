import Foundation

/// Localized UI string. Keys are the English text; translations live in
/// `Resources/<lang>.lproj/Localizable.strings` (Portuguese only for now).
/// SwiftPM executables keep resources in `Bundle.module`, not `Bundle.main`.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
