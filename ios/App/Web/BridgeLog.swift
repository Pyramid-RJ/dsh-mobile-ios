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

    /// One line, plus the detail that used to be lost.
    ///
    /// The list shows `text`; `detail` is the reason a reply failed (the bridge
    /// error message). Without it "reply failed" says nothing about *why*, and
    /// the only way to find out was a Mac and Console.app.
    struct Entry: Identifiable {
        let id = UUID()
        let stamp: String
        let text: String
        let detail: String?

        var line: String { stamp + "  " + text }
    }

    @Published private(set) var entries: [Entry] = []

    private init() {}

    func append(_ line: String, detail: String? = nil) {
        let entry = Entry(stamp: Self.formatter.string(from: Date()), text: line, detail: detail)
        entries.append(entry)
        if entries.count > 120 {
            entries.removeFirst(entries.count - 120)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Everything on screen as plain text, for the copy button.
    var transcript: String {
        entries.map { entry in
            if let detail = entry.detail, !detail.isEmpty {
                return entry.line + "\n    " + detail
            }
            return entry.line
        }
        .joined(separator: "\n")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
