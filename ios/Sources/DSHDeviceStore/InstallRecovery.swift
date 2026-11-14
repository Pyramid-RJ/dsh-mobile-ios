import Foundation

/// Decides whether a launch should offer to recover credentials left behind by a
/// previous install.
///
/// The Keychain survives deleting the app, `UserDefaults` does not. A first
/// launch after an install that still finds records therefore means "this phone
/// has credentials from before", and the user should choose between keeping
/// them and starting clean (docs/06 P1-12).
public enum InstallRecovery {
    public static func shouldOfferRecovery(firstLaunchAfterInstall: Bool, recordCount: Int) -> Bool {
        firstLaunchAfterInstall && recordCount > 0
    }
}
