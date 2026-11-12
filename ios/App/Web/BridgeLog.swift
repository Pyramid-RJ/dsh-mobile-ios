import Combine
import Foundation

/// In-app record of what the page told the bridge.
///
/// The device is the only place bridge behaviour can be observed, so this log is
/// how a user can hand back evidence: whether the adapter ran, when the page
/// asked for capabilities, and which actions it invoked.
@MainActor
final class BridgeLog: ObservableObject {
    static let shared = BridgeLog()

    @Published private(set) var entries: [String] = []

    private init() {}

    func append(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        entries.append(stamp + "  " + line)
        if entries.count > 120 {
            entries.removeFirst(entries.count - 120)
        }
    }

    func clear() {
        entries.removeAll()
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
