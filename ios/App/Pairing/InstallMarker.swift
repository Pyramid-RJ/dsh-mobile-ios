import Foundation

/// Marks "this app has run once on this install".
///
/// `UserDefaults` is wiped when the app is deleted, the Keychain is not. So a
/// missing marker plus records in the Keychain means the phone still holds
/// credentials from a previous install (docs/06 P1-12).
enum InstallMarker {
    private static let key = "dsh.mobile.installMarker"

    /// True on the first launch after an install; writes the marker either way.
    static func consumeFirstLaunch(defaults: UserDefaults = .standard) -> Bool {
        if defaults.string(forKey: key) != nil {
            return false
        }
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: key)
        return true
    }

    /// Test hook: forget the marker so the next launch looks like a reinstall.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
