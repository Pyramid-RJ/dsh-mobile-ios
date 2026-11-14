import Foundation

/// The page zoom the user picked, kept across launches.
@MainActor
final class DisplayScaleStore {
    static let shared = DisplayScaleStore()

    private let key = "dsh.displayScalePercent"

    var percent: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            return (DisplayScalePolicy.minimum...DisplayScalePolicy.maximum).contains(stored) ? stored : 100
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    private init() {}
}
