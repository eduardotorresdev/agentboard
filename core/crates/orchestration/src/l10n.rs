/// Text the core writes where the user reads it (why a program didn't start, the marker between
/// a runner's runs).
// shortcut: English only (Swift looks the key up in `Resources/<lang>.lproj`), translate when a host has a locale to follow.
pub(crate) fn l(key: &str) -> String {
    key.to_string()
}
