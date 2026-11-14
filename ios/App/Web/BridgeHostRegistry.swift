import Foundation

/// The bridge host of the web view currently on screen.
///
/// The diagnostics screen is a sheet over the web view and has no reference to
/// the coordinator, so the host registers itself here while it is alive.
@MainActor
final class BridgeHostRegistry {
    static let shared = BridgeHostRegistry()

    weak var current: BridgeHost?

    private init() {}
}
